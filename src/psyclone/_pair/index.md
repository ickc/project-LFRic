---
title: "PSyclone, from the Ground Up"
subtitle: "A personal note for a Python/HPC programmer who has to optimise LFRic"
execute:
  enabled: false
jupyter:
  jupytext:
    comment_magics: false
    formats: ipynb,_pair//md
    text_representation:
      extension: .md
      format_name: markdown
      format_version: '1.3'
      jupytext_version: 1.19.5
  kernelspec:
    display_name: Python (Pixi)
    language: python
    name: pixi-kernel-python3
---

The [Fortran note](../fortran/index.ipynb) ended with a hand-written PSy layer and the claim that PSyclone is "a tracing JIT that rewrites source ahead of time". This note cashes that claim. It is a rebuild of PSyclone in dependency order, aimed at two jobs: **reading** the generated Fortran in an LFRic build tree without treating it as magic, and **writing** the optimisation scripts that produce it — which is what a performance ticket against [`lfric_apps`](../lfric-apps.qmd) actually consists of.

The order is deliberate. PSyclone is usually taught from its DSL, because that is the historical entry point; here the DSL comes *fourth*, after the intermediate representation it is built on. That is the right order for someone who already knows what an IR and a compiler pass are, and it is also the order in which the tool now factors: PSyIR is the substrate, and the LFRic DSL is one client of it.

**The essence.** PSyclone is *a compiler whose output has to be maintainable Fortran*. Every design decision follows from that one constraint. It explains why the IR is unusually high-level (a `Loop` node, not a basic-block CFG — you cannot print a CFG back out as readable `do` loops); why there is an escape hatch node for constructs it cannot model (`CodeBlock`, because refusing to parse a 3,000-line physics routine over one `write` statement would make the tool useless); why transformations *refuse* rather than silently miscompile (a wrong `!$omp` in a checked-in file is a bug with a two-year half-life); and why the whole apparatus is driven by a Python script you commit next to the source, instead of compiler flags — because the optimisation *is* source, and gets reviewed like source.[^why-not-flags]

[^why-not-flags]: The alternative — pragmas in the science code — was tried by everyone and is what LFRic is deliberately escaping. A `!$omp parallel do collapse(2) schedule(dynamic)` in a physics routine is a statement about one machine, welded to code that has to run on five. Ticket [#813](https://code.metoffice.gov.uk/trac/lfric_apps/ticket/813), the case study in §6, is partly the story of *removing* such hand-rolled machinery (`omp_block`) and replacing it with a script.

---

## 0. What is running this page

Everything below is executed. There is no cell magic this time and no compiler in the loop for most of the page: PSyclone is a Python library, so the notebook imports it and drives it in-process. The small helper module ([`src/psyclone_tour/`](https://github.com/ickc/project-LFRic/tree/main/src/psyclone/src/psyclone_tour)) exists for presentation only — `show` prints Fortran as a highlighted block, `tree` prints a PSyIR tree, `diff` prints the delta a transformation made, `run` shells out for the parts that only exist as a command line.

```python
from importlib.metadata import version

from psyclone_tour import LFRIC_APPS, LFRIC_CORE, PSYCLONE_SRC, diff, fortran, psyir, run, show, tree
from psyclone_tour.paths import LFRIC_CONFIG, LFRIC_PSYCLONE_TOOLS, LFRIC_TRANSMUTE_TOOLS, check

check()  # fails with a sentence, not a stack trace, if the submodules are absent
print("psyclone", version("psyclone"), "| fparser", version("fparser"))
```

**Which version, and why it matters.** PSyclone's Python API is not stable across minor releases, and LFRic tracks it closely rather than pinning far behind. `lfric_apps` main currently builds with 3.3.1 (`spack load py-psyclone@3.3.1` in the ESNZ cascade suite), having migrated in "Updates needed to support psyclone 3.3"; that migration moved `OMPParallelTrans` into `psyclone.psyir.transformations` and renamed every `Dynamo0p3*Trans` to `LFRic*Trans`. This environment therefore pins the 3.3 series, so that the real optimisation scripts quoted below import and run unmodified. If you read an older script — or an older ticket — expect the import lines to have moved.[^stale-docs]

[^stale-docs]: Two places in the submodules still disagree with reality, both worth a patch. `lfric_core/documentation/source/getting_started/installation/software_dependencies.rst` still says "PSyclone (3.2.2)" and "fparser (0.2.1)" — the latter is impossible, since psyclone 3.3.1 requires exactly `fparser==0.2.4`. And `lfric_apps/rose-stem/site/azngarch/common/suite_config_sandbox.cylc` still loads `py-psyclone/3.1.0`.

---

## 1. What PSyclone is

A **source-to-source Fortran compiler**, distributed as a Python package, that reads Fortran, builds a tree, lets you mutate the tree from a script, and writes Fortran back out. It generates no object code and owns no runtime. The compiler you already use runs afterwards, on its output.

```
        Fortran in
            │
            ▼
      fparser2  ──────────►  a faithful, low-level parse tree
            │                (every comma and keyword, no semantics)
            ▼
        PSyIR   ──────────►  a semantic tree: Loops, Assignments,
            │                Symbols, and CodeBlocks where it gave up
            ▼
    your trans(psyir)  ────►  mutation, in place, validated
            │
            ▼
     FortranWriter  ───────►  Fortran out
```

Four stages, and the practical consequences of each are different, so it is worth being precise about who is responsible for what:

| stage | what it owns | how it fails you |
|---|---|---|
| fparser2 | syntax | a syntax error, or a construct it cannot parse at all |
| PSyIR frontend | meaning: symbols, types, control flow | silently produces a `CodeBlock` — parsed, but opaque |
| transformations | legality and the rewrite itself | raises `TransformationError` and changes nothing |
| FortranWriter | printing | reformats aggressively; drops comments unless told not to |

### 1.1 The two faces

PSyclone is really two tools sharing an IR, and LFRic uses both. Keeping them apart is the single most useful thing to fix early, because almost every confusing error message is a symptom of being in one mode while thinking in the other.

| | **PSyKAl mode** (`-api lfric`) | **transformation mode** (no `-api`) |
|---|---|---|
| input | a `.x90` algorithm layer with `call invoke(...)` | any Fortran file |
| PSyclone *generates* code | yes — the whole PSy layer, from metadata | no — it only rewrites what you gave it |
| what the script sees | the PSy layer PSyclone just invented | the routine you wrote |
| parallelism knows about | function spaces, dofs, halos, colouring | loops, arrays, dependences |
| in LFRic | `lfric_core`, `gungho`, anything `.x90` | UM-inherited physics, via "transmute" |
| the makefile | `psyclone_psykal.mk` | `psyclone_transmute.mk` |
| in this note | §5 | §6 |

Both are driven the same way: `psyclone -s script.py`, where the script defines exactly one function, `trans(psyir)`.

### 1.2 The bridge you already have

The Fortran note gave the JAX correspondence for the PSyKAl layers. Here is the one for the *tool*, which is a different and more exact analogy — PSyclone is much closer to Numba's and JAX's internals than to a preprocessor.

| you know | PSyclone | where it differs |
|---|---|---|
| `jaxpr` / Numba IR | PSyIR | must print back out as readable Fortran, so it stays statement-shaped: no SSA, no CFG, no basic blocks |
| tracing a function | `FortranReader.psyir_from_source` | it is *parsing*, not tracing: no values, so no constant folding for free, and control flow survives intact |
| a JAX transform (`vmap`, `grad`) | a `Transformation` subclass | mutates one tree in place rather than returning a new function; and it *validates* first, refusing when illegal |
| `jax.jit` lowering to XLA | `FortranWriter` | the target is text a human will read in a code review |
| XLA fusion decisions | `LoopFuseTrans` and friends, applied by hand from your script | nothing is automatic; PSyclone applies exactly the transformations your script names |
| `jax.grad` | PSyAD (§7) | source-to-source reverse mode, ahead of time |
| `numba.objmode` | `CodeBlock` | the escape hatch for what the IR cannot model |

The last row of the "differs" column is the one to internalise. **PSyclone has no optimiser.** It has a library of legal rewrites and a script in which you choose them. There is no `-O2`. Ticket #813 is 124 lines of Python because someone had to decide, loop by loop, what to do — and the deciding, not the typing, is the work.

---

## 2. PSyIR, concretely

Start where everything starts: text in, tree out.

```python
source = """
module diffuse_mod
  use constants_mod, only : r_def, i_def
  implicit none
contains
  subroutine diffuse(field, kappa, n, nlayers)
    integer(i_def), intent(in) :: n, nlayers
    real(r_def), intent(in) :: kappa
    real(r_def), intent(inout) :: field(n, nlayers)
    integer(i_def) :: i, k
    do k = 1, nlayers
      do i = 2, n - 1
        field(i,k) = field(i,k) + kappa * (field(i-1,k) - 2.0_r_def*field(i,k) + field(i+1,k))
      end do
    end do
  end subroutine diffuse
end module diffuse_mod
"""

tree(psyir(source))
```

Read that tree structurally, because four things about its shape are load-bearing.

**It is a tree of statements, not of blocks.** `Loop` is a node with a body, the way it is in the source. A conventional optimising compiler would have destroyed this by now — lowered the loop to a comparison, a branch and a back-edge over basic blocks in SSA form, which is the right representation for register allocation and the wrong one for printing `do k = 1, nlayers` back out. PSyIR's job is to survive a round trip through a human, so it keeps the structure the human wrote.[^psyir-level]

**A `Loop` has exactly four children**: start, stop, step, body — in that order, positionally. Not a `bounds` object, not keywords.

**`Schedule` is the body.** It exists so that a loop body is a node, and therefore something a transformation can wrap a directive around. When you see `Schedule[]` in a tree view, read "block".

**Nothing is typed yet, quite.** `Literal[value:'1', Scalar<INTEGER, UNDEFINED>]` — the kind is `UNDEFINED` because the literal `1` has no kind suffix, while `2.0_r_def` carries `Scalar<REAL, Reference[name:'r_def']>`: the kind is a *reference to a symbol*, not a number, because PSyclone has not read `constants_mod` and does not know what `r_def` is. It does not need to.

[^psyir-level]: This is the standard trade-off in source-to-source tools and the reason they are a distinct genre. ROSE, Coccinelle and clang's AST-matcher refactorings sit in the same place; LLVM IR and jaxpr sit on the other side of the line. The tell is whether the IR can be printed back out as something a maintainer would accept in a pull request.

### 2.1 Symbols

Every scope carries a symbol table, and it is the part of PSyIR you will actually query in a script — "is this name a local, an argument, or an import?" decides whether a variable can be made `private`.

```python
from psyclone.psyir.nodes import Routine

routine = psyir(source).walk(Routine)[0]
table = routine.symbol_table

for symbol in table.symbols:
    print(f"{symbol.name:8s} {type(symbol.interface).__name__:20s} {symbol.datatype}")

print("\nargument order:", [s.name for s in table.argument_list])
print("r_def is:", table.lookup("r_def").interface)
```

Three interfaces, three meanings. `ArgumentInterface` — a dummy argument, and the table's `argument_list` preserves the order, which is how PSyclone knows how to *call* the routine. `AutomaticInterface` — an ordinary local, and therefore the class of thing that can be privatised for OpenMP. `ImportInterface` — brought in by `use`, so it lives in another file that PSyclone may never have read; `r_def` resolves to `Import(container='constants_mod')` and nothing more.

That last one is why LFRic's kind system is invisible to PSyclone, and why that is fine. `real(r_def)` is `Scalar<REAL, Reference['r_def']>`: enough to know it is a real, enough to print it back out identically, not enough to know it is 64-bit. Almost no transformation needs to know.

### 2.2 `CodeBlock`: the most important node

Here is the one that will actually bite you. PSyIR does not model all of Fortran. When the frontend meets something it has no node for, it does not fail — it wraps the raw fparser2 subtree in a `CodeBlock` and carries on.

```python
from psyclone.psyir.nodes import CodeBlock

mixed = psyir("""
subroutine report(a, n)
  integer, intent(in) :: n
  real, intent(inout) :: a(n)
  integer :: i
  do i = 1, n
    a(i) = a(i) * 2.0
  end do
  write(*,*) 'total ', sum(a)
end subroutine report
""")

for block in mixed.walk(CodeBlock):
    print(block.structure, "->", block.get_fortran_lines())
```

The loop is fully modelled; the `write` is a black box that PSyclone can move but not look inside. This is a good trade — it is what lets a 943-line physics routine be transformed when one statement in it is exotic — but it has a hard consequence: **a `CodeBlock` inside a region blocks transformations of that region.**

```python
from psyclone.psyir.nodes import Loop
from psyclone.psyir.transformations import OMPParallelLoopTrans, TransformationError

blocked = psyir("""
subroutine noisy(a, n)
  integer, intent(in) :: n
  real, intent(inout) :: a(n)
  integer :: i
  do i = 1, n
    a(i) = a(i) * 2.0
    write(*,*) i
  end do
end subroutine noisy
""")

try:
    OMPParallelLoopTrans().apply(blocked.walk(Loop)[0])
except TransformationError as err:
    print(err)
```

PSyclone cannot know what that `write` touches, so it will not certify the loop as parallel. The message names the escape hatch (`node-type-check: False`) and you should almost never take it: here you would be promising that a `write` from many threads at once is fine, which it is not.

**This is the first thing to check when a transformation mysteriously does nothing** in a real routine. Print the `CodeBlock`s, find out which statement lost you the loop, and consider whether the *source* should change — which is frequently the right answer, and is part of what ticket #813 did.

### 2.3 The backend is not a pretty-printer

Round-tripping is lossy, on purpose, and you need to know exactly how, because you will diff generated code against generated code for the rest of your career.

```python
show(psyir(source))
```

Compare with the input. Declarations are split one per line; the `only :` list is alphabetised; `dimension(n,nlayers)` replaces `field(n,nlayers)`; `intent(in)` is spelled out on each; `do k = 1, nlayers` gains an explicit `, 1` step; `end do` becomes `enddo`; `public` is stated; blank lines are normalised. All semantically identical, all diff noise.

And the big one:

```python
gw_source = LFRIC_APPS / "science/physics_schemes/source/gravity_wave_drag/gw_ussp_mod.F90"

run("psyclone", "-l", "all", "-o", "/tmp/gw_plain.f90", gw_source)
run("psyclone", "-l", "all", "--keep-comments", "--keep-directives",
    "-o", "/tmp/gw_commented.f90", gw_source)

def comment_count(path):
    return sum(1 for line in open(path) if line.lstrip().startswith("!"))

print("source comments :", comment_count(gw_source))
print("default output  :", comment_count("/tmp/gw_plain.f90"))
print("--keep-comments :", comment_count("/tmp/gw_commented.f90"))
```

By default **every comment is deleted**. 377 of them, from a routine whose comments are the only documentation of a fairly deep piece of gravity-wave physics. `--keep-comments` and `--keep-directives` were added in 3.3 and recover almost all of them; LFRic's `psyclone_transmute.mk` does not yet pass either flag, which is a small and worthwhile patch.[^keep-comments]

Two more flags worth knowing now. `-l all` limits output lines to 132 characters — LFRic passes it everywhere, because PSyclone's writer happily emits a 400-character line that no Fortran compiler will accept in free form. `-o` names the output file; without it, output goes to stdout, which is what makes PSyclone pleasant to explore from a shell.

[^keep-comments]: With the caveat that a comment's *position* after a transformation is guesswork — a comment attached to a loop that has been fused, colored or wrapped in a directive can end up describing the wrong thing. That is presumably why the flag is opt-in.

---

## 3. Transformations

A transformation is an object with two methods: `validate`, which raises `TransformationError` if the rewrite would be illegal, and `apply`, which validates and then mutates the tree in place. That is the whole interface, and the asymmetry in how much you care about each is worth stating: **`apply` is the boring half.**

```python
one_loop = psyir("""
subroutine scale_column(field, kappa, n, nlayers)
  integer, intent(in) :: n, nlayers
  real, intent(in) :: kappa
  real, intent(inout) :: field(n, nlayers)
  integer :: i, k
  do k = 1, nlayers
    do i = 1, n
      field(i,k) = kappa * field(i,k)
    end do
  end do
end subroutine scale_column
""")

before = fortran(one_loop)
OMPParallelLoopTrans(omp_schedule="static").apply(one_loop.walk(Loop)[0])
diff(before, fortran(one_loop))
```

Note what PSyclone worked out for itself: `private(i,k)` — including `k`, the loop variable of the parallelised loop, and `i`, the inner one — and `default(shared)`. Getting a private list wrong by hand is the classic OpenMP bug, silent and load-dependent, and deriving it from the tree is most of the value on offer here.

### 3.1 The refusal is the feature

```python
carried = psyir("""
subroutine prefix_sum(a, n)
  integer, intent(in) :: n
  real, intent(inout) :: a(n)
  integer :: i
  do i = 2, n
    a(i) = a(i-1) + 1.0
  end do
end subroutine prefix_sum
""")

try:
    OMPParallelLoopTrans().apply(carried.walk(Loop)[0])
except TransformationError as err:
    print(err)
```

A loop-carried dependence, found by comparing the subscripts of the write and the read, and reported with both. `sed` would have parallelised this and produced a program that gives a different answer on every run.

The two hints in that message are the ones you will reach for on real code, and they are promises, not requests:

- `ignore_dependencies_for=[...]` — "this dependence is spurious, take my word for it". Usually because the *real* index relationship is beyond PSyclone's analysis (an indirection through a dofmap, say).
- `array_privatisation` — for a write-write dependence on scratch space, where each iteration wants its own copy.

Getting either wrong buys you a race condition, checked into a model that runs on 384 ranks. The dependence analysis is also available directly, which is how a script can make its own decisions:

```python
loop = carried.walk(Loop)[0]
print(loop.loop_body[0].reference_accesses())
```

`a: READ+WRITE, i: READ`. That map — signature to access type — is the primitive under most of the LFRic helper functions in §6.

### 3.2 Loop fusion, and its refusal

```python
two_passes = """
subroutine two_passes(a, b, n)
  integer, intent(in) :: n
  real, intent(inout) :: a(n), b(n)
  integer :: i
  do i = 1, n
    a(i) = a(i) * 2.0
  end do
  do i = 1, n
    b(i) = b(i) + a(i)
  end do
end subroutine two_passes
"""

from psyclone.psyir.transformations import LoopFuseTrans

fused = psyir(two_passes)
before = fortran(fused)
loops = fused.walk(Loop)
LoopFuseTrans().apply(loops[0], loops[1])
diff(before, fortran(fused))
```

One pass over memory instead of two — the same win as fusing two NumPy expressions, for the same reason, and worth the same amount: on a memory-bound stencil, most of it.

Now shift one index and ask again:

```python
illegal = psyir(two_passes.replace("b(i) = b(i) + a(i)", "b(i) = b(i) + a(i+1)"))
loops = illegal.walk(Loop)

try:
    LoopFuseTrans().apply(loops[0], loops[1])
except TransformationError as err:
    print(err)
```

Correct: after fusion, iteration `i` would read `a(i+1)` before the first loop's iteration `i+1` had written it. The analysis is deliberately conservative — "used with different indices" is a *syntactic* test, and it will refuse fusions that happen to be legal. That is the right bias for a tool whose mistakes get committed.

### 3.3 Where the names live

The one genuinely annoying thing about the API. There are three transformation modules and the split is historical, not logical:

| module | holds | notes |
|---|---|---|
| `psyclone.psyir.transformations` | the generic ones: `OMPParallelTrans`, `LoopFuseTrans`, `LoopSwapTrans`, `InlineTrans`, `ChunkLoopTrans`, `ProfileTrans` | where new work lands |
| `psyclone.transformations` | the top-level re-export, plus the PSyKAl-aware ones: `LFRicColourTrans`, `LFRicOMPLoopTrans`, `ACCParallelTrans` | re-exports shift between releases |
| `psyclone.domain.lfric.transformations` | LFRic-specific: `LFRicRedundantComputationTrans`, `LFRicLoopFuseTrans`, `LFRicExtractTrans` | |

Some names are importable from two of them, which is exactly how a script ends up working on one release and failing on the next. In 3.3, `OMPParallelTrans` left `psyclone.transformations`, and `Dynamo0p3ColourTrans`/`Dynamo0p3OMPLoopTrans`/`Dynamo0p3RedundantComputationTrans` became `LFRicColourTrans`/`LFRicOMPLoopTrans`/`LFRicRedundantComputationTrans`.[^dynamo] When an LFRic optimisation script raises `ImportError`, that is the first thing to check, and the fix is mechanical.

[^dynamo]: "Dynamo" was the name of the project that became LFRic's dynamical core, and `dynamo0.3` was the API name for a decade — long enough that it is still what much of the PSyclone test suite and documentation calls it. If you grep for it, that is why.

---

## 4. The PSyKAl route

Now the DSL, with the IR already in hand.

**PSyKAl** = **P**arallel **Sy**stem, **K**ernel, **Al**gorithm: three layers with a rule about what each may contain. The rule is the entire idea.

| layer | file | written by | may contain | may **not** contain |
|---|---|---|---|---|
| Algorithm | `.x90` | a scientist | whole fields, `call invoke(...)` | loops over cells, indices, MPI, OpenMP |
| PSy | generated `_psy.f90` | **PSyclone** | loops, dofmaps, halo exchanges, directives | science |
| Kernel | `_kernel_mod.F90` | a scientist | one column's arithmetic, intrinsic types | fields, `use` of anything global, I/O |

The middle layer is the only one anybody generates, and it is where every decision about *how* the model runs is expressed. The two human layers are written once and retargeted for free — that is the bet.

### 4.1 A kernel is a type declaration with a table in it

```python
kernel = LFRIC_CORE / "components/science/source/kernel/algebra/matrix_vector_kernel_mod.F90"
show("".join(open(kernel).readlines()[24:45]))
```

The declaration is the interface. `meta_args` is an array of `arg_type` in the order the algorithm layer passes them, each naming three or four things: what kind of argument (`GH_FIELD`, `GH_OPERATOR`, `GH_SCALAR`), of what data type (`GH_REAL`), accessed how (`GH_READ`, `GH_INC`, `GH_WRITE`, `GH_READWRITE`), on which function space (`W1`, `W3`, `ANY_SPACE_1`). Then `operates_on` says what one call is handed: `CELL_COLUMN` for almost everything, `DOF` for pointwise work, `DOMAIN` for the rare kernel that wants the lot.

The access descriptor is the load-bearing part, and it is the same information as a JAX donation annotation, doing more work:

| descriptor | means | what PSyclone must then do |
|---|---|---|
| `GH_READ` | read only | may need a halo exchange first |
| `GH_WRITE` | overwrite, no read | nothing; safe to thread |
| `GH_READWRITE` | read and write, own dofs only | discontinuous spaces only |
| `GH_INC` | *increment* a shared dof | **colour the mesh**, or race; and loop into the halo |

`GH_INC` on a continuous function space is the interesting case, and the source of most of the generated complexity below: continuous means neighbouring cells share degrees of freedom, so two threads on adjacent cells increment the same array entry.

### 4.2 Run it

`demo/` holds a self-contained example built for exactly this — a kernel with `GH_INC` on `W1`, an algorithm with two invokes, and an optimisation script. Start with no script at all:

```python
run("psyclone", "-api", "lfric", "--config", LFRIC_CONFIG,
    "-d", "demo/kernel",
    "-oalg", "/tmp/mini_alg.f90", "-opsy", "/tmp/mini_psy.f90",
    "demo/algorithm/mini_alg_mod.x90")

show("/tmp/mini_alg.f90")
```

The algorithm layer has been *rewritten*: each `invoke` became a call to a generated subroutine, and a `use` of a module that did not exist a second ago. Note `invoke_apply_mini_matvec` took its name from the `name=` argument in the source, while the anonymous second invoke became `invoke_1` — a good reason to always name invokes, since these are the symbols that will appear in a profile.

And the layer that call lands in:

```python
show("/tmp/mini_psy.f90")
```

Read it in order, because it is the same order every generated PSy routine follows:

1. **Proxies.** `lhs_proxy = lhs%get_proxy()` then `lhs_data => lhs_proxy%data`. The [proxy pattern from the Fortran note](../fortran/index.ipynb): `field_type` keeps its data private, the PSy layer needs a raw array, and `get_proxy` is the one sanctioned hole through the encapsulation.
2. **Sizes and maps.** `nlayers`, `ndf_w1` (dofs per cell), `undf_w1` (unique dofs on this partition), `map_w1 => ...get_whole_dofmap()`.
3. **Loop bounds.** `loop1_stop = mesh%get_last_halo_cell(1)`. Not `ncells` — the loop runs *into the level-1 halo*, because `GH_INC` means owned dofs on the partition boundary are only complete once the neighbouring halo cell has contributed too.
4. **Halo exchange.** `if (rhs_proxy%is_dirty(depth=1)) then` guarding `call rhs_proxy%halo_exchange(depth=1)` — inserted because the kernel reads `rhs` in cells that include halo cells, and guarded so that a clean halo costs nothing. Nobody wrote that; it was derived from `GH_READ` plus the loop bound.
5. **The kernel call**, with `map_w1(:,cell)` — the dofmap column for this cell.
6. **Dirty flags.** `call lhs_proxy%set_dirty()`, because the loop wrote `lhs` and its halo copies elsewhere are now stale.

That is the whole distributed-memory protocol, generated from three lines of metadata. The two `setval_c`/`inc_a_times_X` loops have no kernel file anywhere — they are **builtins**, whose bodies PSyclone writes itself.

### 4.3 The optimisation script, and colouring

Now with `demo/optimisation/global.py`, which colours continuous-space cell loops and then threads them:

```python
show(open("demo/optimisation/global.py").read(), lang="python")
```

```python
run("psyclone", "-api", "lfric", "--config", LFRIC_CONFIG,
    "-d", "demo/kernel", "-s", "./demo/optimisation/global.py",
    "-oalg", "/tmp/mini_alg_opt.f90", "-opsy", "/tmp/mini_psy_opt.f90",
    "demo/algorithm/mini_alg_mod.x90")

diff(open("/tmp/mini_psy.f90").read(), open("/tmp/mini_psy_opt.f90").read(),
     "psy layer, no script", "psy layer, colour + omp")
```

The shape to recognise:

```fortran
do colour = loop1_start, loop1_stop, 1
  !$omp parallel do default(shared) private(cell) schedule(static)
  do cell = loop2_start, last_halo_cell_all_colours(colour,1), 1
    call mini_matvec_code(..., map_w1(:,cmap(colour,cell)), ...)
```

Colours outside, threads inside, and cell indices reached through `cmap`. The mesh has been partitioned so that no two cells of the same colour share a degree of freedom, so within one colour the increments cannot collide; the implicit barrier at the end of each `!$omp parallel do` separates colour from colour. This is **chromatic Gibbs sampling** with the conditional-independence graph replaced by the dof-sharing graph — the same algorithm, the same reason, and if you have written a blocked Gibbs sampler you have already had this idea.[^colouring-cost]

Note the price, which is why colouring is applied only where required: `cmap(colour,cell)` is an indirection, so cells visited consecutively are no longer contiguous in memory, and the prefetcher suffers. On a discontinuous space (`W3`, `Wtheta`) no dof is shared, no colouring is needed, and the script must not add it — which is exactly the `VALID_DISCONTINUOUS_NAMES` test in the script.

[^colouring-cost]: LFRic can also *tile* the colouring (`options={"tiling": True}` on `LFRicColourTrans`), which recovers some locality by colouring blocks of cells rather than single cells. `psyclone_tools.colour_loops` takes an `enable_tiling` flag for exactly this.

### 4.4 The real thing

Everything above was a miniature. Here is the actual production script — `lfric_core/infrastructure/build/psyclone/psyclone_tools.py`, imported by every application's `global.py` — run over a real algorithm from `lfric_core`:

```python
alg = LFRIC_CORE / "applications/simple_diffusion/source/algorithm/simple_diffusion_alg_mod.x90"
script = LFRIC_CORE / "applications/simple_diffusion/optimisation/meto-ex1a/psykal/global.py"

run("psyclone", "-api", "lfric", "--config", LFRIC_CONFIG,
    "-d", LFRIC_CORE / "applications/simple_diffusion/source",
    "-s", script,
    "-oalg", "/tmp/sd_alg.f90", "-opsy", "/tmp/sd_psy.f90", alg,
    env={"PYTHONPATH": str(LFRIC_PSYCLONE_TOOLS)})
```

That output is the script's own `view_transformed_schedule` talking — production LFRic scripts print the transformed schedule into the build log, which is how you find out what happened to your loops without reading 400 lines of generated Fortran. Worth reading closely:

- `HaloExchange[field='field_in', type='cross', depth=stencil_depth, check_dirty=True]` — a *stencil* exchange, depth taken from a variable in the algorithm layer, guarded by a dirty check.
- `Loop[type='dof', it_space='dof', upper_bound='nannexed']` for the builtins, versus `it_space='cell_column'` for the kernel.
- `upper_bound='nannexed'`: annexed dofs are dofs owned by another rank but sitting on cells this rank touches. Whether they are computed is a *config file* setting (`COMPUTE_ANNEXED_DOFS`), not a script setting — which is one reason `--config` is not optional for the LFRic API.

The three passes in `psyclone_tools.py` are worth naming since you will read them in every ticket:

`redundant_computation_setval` extends `setval_*` builtins to compute into the level-1 halo. Deliberately doing *extra* arithmetic to avoid a communication — because the alternative is a halo exchange, and on 384 ranks arithmetic is free and messages are not. `colour_loops` as above. `openmp_parallelise_loops` wraps each remaining loop in a parallel region and adds `!$omp do`, with `reprod=True` — reproducible reductions, meaning a fixed summation order at some cost in speed, so that the model gives bit-identical answers on the same rank count. In a model validated by checksums, that is not negotiable.

The ordering constraints between them are real, and `psyclone_tools.py` enforces them by raising: colour before profile, profile before OpenMP. A `ProfileNode` inserted first would be in the way of the colouring transformation, and a profiling caliper inside a parallel region measures something other than what you meant.

### 4.5 `psyclone-kern`: checking a kernel against its own metadata

A kernel's argument list is not free — it is dictated by the metadata, in a fixed order. Getting it wrong gives you a link error at best and silent garbage at worst, so PSyclone will print the interface the metadata implies:

```python
run("psyclone-kern", "-gen", "stub", "-api", "lfric",
    "demo/kernel/mini_matvec_kernel_mod.F90")
```

Compare with the hand-written subroutine in the same file: same arguments, same order, same shapes. This is the first thing to run when a new kernel does not work, and the fastest way to learn the argument-order convention — `nlayers`, then field arrays in `meta_args` order, then per-function-space `ndf`, `undf`, `map`.

### 4.6 The rules PSyclone enforces on the algorithm layer

The `.x90` is a DSL, and violating its rules gets you an error at build time rather than a wrong answer at run time. Two you will hit:

```python
bad = """
module bad_alg_mod
  use constants_mod, only : r_def
  use field_mod, only : field_type
  implicit none
contains
  subroutine bad_alg(lhs)
    type(field_type), intent(inout) :: lhs
    call invoke( inc_X_times_Y(lhs, lhs) )
  end subroutine bad_alg
end module bad_alg_mod
"""
open("/tmp/bad_alg_mod.x90", "w").write(bad)

run("psyclone", "-api", "lfric", "--config", LFRIC_CONFIG,
    "-oalg", "/tmp/bad_alg.f90", "-opsy", "/tmp/bad_psy.f90",
    "/tmp/bad_alg_mod.x90", expect_failure=True)
```

The same field twice in one builtin — refused, because the generated loop would alias. The other rules worth knowing, from LFRic's coding standards rather than from PSyclone's checks:

- **Fields passed to an `invoke` must be declared locally.** Not fetched inline from a module, not returned from a function call in the argument list. PSyclone has to *find the declaration* to know the type, and it does not chase across files.
- **Group kernels into one `invoke` where you can.** PSyclone can fuse loops and elide halo exchanges within an invoke and cannot see across two. `demo/algorithm/mini_alg_mod.x90` has two on purpose; joining them would let the `setval_c` and the kernel loop be considered together.

---

## 5. The transmute route

LFRic did not start from nothing. The atmosphere model inherits a large body of physics from the Unified Model — gravity-wave drag, boundary layer, microphysics, radiation — written years before PSyKAl existed, in ordinary Fortran, with ordinary loops over `i`, `j` and `k`. Rewriting it all as kernels is a decade of work that nobody has funded.

So `lfric_apps` runs PSyclone over that source in **transformation mode**: no `invoke`, no metadata, no generated PSy layer. Just "here is a routine, here is a script, add the OpenMP". The name for this in the build system is **transmute**.

The wiring is worth knowing, because it tells you where to put a script:

| piece | what it does |
|---|---|
| `PSYCLONE_PHYSICS_FILES` in `applications/*/build/psyclone_transmute_file_list.mk` | the opt-in list, by module name. A file not named here is compiled untouched |
| `.xu90` | the preprocessed intermediate; the physics is `.F90` with real `#if`s, and PSyclone will not run `cpp` for you |
| `interfaces/build/psyclone_transmute.mk` | the rules. Looks for `<optimisation>/transmute/<subdir>/<module>.py`, then `local.py`, then `global.py`, then falls back to a bare pass |
| `interfaces/build/transmute_psytrans/` | the shared helper library, `transmute_functions.py` |

Note that last fallback: **a file on the list with no script still goes through PSyclone**, and comes out reformatted with its comments deleted and its existing OpenMP stripped (`"Psyclone pass with no optimisation applied, OMP removed"`). That is intentional — it guarantees that hand-written directives cannot survive into a build where the script is meant to own parallelism.

---

## 6. Case study: ticket #813, spectral gravity-wave drag

[Ticket #813](https://code.metoffice.gov.uk/trac/lfric_apps/ticket/813) applies PSyclone-driven OpenMP to `gw_ussp_mod.F90`, the Ultra-Simple Spectral Parametrization of gravity-wave drag. It is the best worked example available of what a performance ticket looks like end to end, so it is worth reproducing rather than summarising. The [Exeter NG-ARCH wiki](https://github.com/UniExeterRSE/NG-ARCH/wiki/Spectral-GWD) has the analysis behind it.

The script is 124 lines and the whole of its judgement is in three constants:

```python
ticket_script = LFRIC_APPS / "applications/lfric_atm/optimisation/meto-ex1a/transmute/gravity_wave_drag/gw_ussp_mod.py"
show(open(ticket_script).read(), lang="python")
```

`HEAVY_VARS_K` and `HEAVY_VARS_I` are lists of *variable names*. A loop is worth parallelising if it writes to one of them. That is the ticket's whole model of the routine, and it came from a profiler: these are the variables the hot loops write.

**The experiment to run.** Comparing the transformed output against the original source is useless — the diff drowns in reformatting and deleted comments. Compare it instead against PSyclone's output with *no script*, which isolates exactly what the script did:

```python
run("psyclone", "-l", "all", "-o", "/tmp/gw_baseline.f90", gw_source)

run("psyclone", "-l", "all", "-s", ticket_script, "-o", "/tmp/gw_ticket.f90", gw_source,
    env={"PYTHONPATH": str(LFRIC_TRANSMUTE_TOOLS), "COMPILER": "cce"})
```

```python
diff(open("/tmp/gw_baseline.f90").read(), open("/tmp/gw_ticket.f90").read(),
     "psyclone, no script", "psyclone, ticket #813 script", context=2)
```

Everything the ticket did, in about 110 lines of diff. Four things in it repay close reading.

**One parallel region, many worksharing loops.** The first hunk opens `!$omp parallel` and then issues a series of `!$omp do` / `!$omp end do` pairs across *adjacent* loops, closing the region only at the end. That is `parallel_regions_for_clustered_loops`, and the point is amortisation: entering a parallel region costs a thread-team synchronisation, and doing it once for eight loops instead of eight times is most of the win on short loops. The clustering is purely positional — "adjacent top-level loops under the same parent" — which is why the helper is 90 lines of index bookkeeping.

**Worksharing inside a sequential loop.** Look at this shape:

```fortran
do k = tdims%k_end, tkfix1start + 1, -1
  !$omp do schedule(static)
  do i = tdims%i_start, tdims%i_end, 1
    ...
    nbv(i,j,k - 1) = nbv(i,j,k)
```

The `k` loop is *not* parallel — it walks downward and each level reads the level above, a loop-carried dependence. So the `k` loop is executed redundantly by every thread, and only the `i` loop is shared out. This is correct, and it is correct because of the implicit barrier at the end of `!$omp do`: every thread finishes level `k` before any starts `k-1`. It is also the kind of code nobody writes by hand, and a good demonstration that the machine-generated version can be better than the hand-rolled one it replaced.

**`firstprivate`, and a compiler-specific branch.** The second hunk is the interesting one:

```fortran
jdir = 0
k = 0
!$omp parallel do default(shared) private(i,ii,jj,s_fptot,...) &
!$omp& firstprivate(jdir,k) schedule(dynamic)
do i = 1, meta_segments%num_segments, 1
```

Three things at once. The schedule is `dynamic`, alone in this file, because segments contain different numbers of launch levels and the work per iteration varies — classic load imbalance, and the one place where dynamic scheduling earns its overhead. The private list is explicit, supplied by the script, because it includes per-segment allocatables that PSyclone's analysis would not privatise on its own. And `jdir = 0; k = 0` were inserted *before* the region — the script initialises them so that the `firstprivate` PSyclone emits has a defined value to copy.

That `firstprivate` is also why the script branches on the compiler:

```python
run("psyclone", "-l", "all", "-s", ticket_script, "-o", "/tmp/gw_gnu.f90", gw_source,
    env={"PYTHONPATH": str(LFRIC_TRANSMUTE_TOOLS), "COMPILER": "gnu"})

print("dynamic PARALLEL DO present under CCE:",
      "schedule(dynamic)" in open("/tmp/gw_ticket.f90").read())
print("dynamic PARALLEL DO present under GNU:",
      "schedule(dynamic)" in open("/tmp/gw_gnu.f90").read())
```

Under GNU the whole `meta_segments` pass is skipped — "GCC currently has issues with firstprivated indexes", says the script — so the same source, the same PSyclone and the same script produce *differently parallelised code for different compilers*. `get_compiler()` reads `FC`, `CC` or the loaded module list to decide. This is the thing to hold on to about optimisation scripts: they are not a description of the program, they are a description of the program *on a machine*, and the machine is a parameter.

**What is not there.** No `collapse()`. The ticket says so explicitly: `collapse` helped GCC and hurt CCE, and with only one script shared between them, the loss on the production compiler decided it. The ticket also *deleted* the routine's hand-rolled `omp_block` machinery, which had been 0.5% slower than nothing at all. Both are worth noting as the normal outcome of this work: a ticket's value is often a removal plus a decision not to use a feature.

### 6.1 The reusable half

`transmute_functions.py` is the general-purpose part, and it is a good model for how these scripts are actually built — a predicate over the tree, then a transformation applied where the predicate holds:

```python
show(open(LFRIC_TRANSMUTE_TOOLS / "transmute_psytrans/transmute_functions.py").read().split("def get_outer_loops")[0], lang="python")
```

`is_heavy_loop` is eight lines and is the entire targeting mechanism: walk the loop's `Assignment` nodes, look at the left-hand side, ask whether its name is in a set. Crude — it cannot tell a hot loop from a cold one, only a loop that touches a variable a human already identified — and exactly the right amount of machinery, because the profiler did the analysis and the script only has to encode the conclusion.

These helpers are being upstreamed into [PSyTran](https://github.com/MetOffice/PSyTran) ([issue #118](https://github.com/MetOffice/PSyTran/issues/118)), with ticket [#906](https://code.metoffice.gov.uk/trac/lfric_apps/ticket/906) tracking deletion of the local copies. If you write generic tree predicates, that is where they should end up.

---

## 7. PSyAD: the adjoint, generated

The one part of PSyclone that is not about parallelism. **PSyAD** reads a tangent-linear kernel and writes its adjoint.

The mathematics first, since it is the shortest route in. A nonlinear model step is $M: \mathbb{R}^n \to \mathbb{R}^n$. Linearising about a state $\bar{x}$ gives the **tangent-linear** operator $L = \partial M/\partial x|_{\bar{x}}$, a matrix acting on perturbations: $\delta y = L\,\delta x$. Its **adjoint** is $L^{*}$, defined by

$$\langle L\,\delta x, \delta y\rangle = \langle \delta x, L^{*}\,\delta y\rangle \quad \forall\, \delta x, \delta y.$$

In real arithmetic $L^{*} = L^{\mathsf{T}}$. You know both of these as `jax.jvp` and `jax.vjp`: the tangent-linear is forward mode, the adjoint is reverse mode, and the identity above is the statement that makes backpropagation work. Variational data assimilation needs $L^{*}$ for the same reason training needs a gradient — 4D-Var minimises a cost function over the initial state, and the gradient of that cost comes back through the adjoint of the whole forecast.

The difference from JAX is *when*. JAX differentiates a traced computation at run time, in Python. PSyAD reads Fortran and writes Fortran, ahead of time, and what gets compiled into the model is an ordinary subroutine that a Fortran programmer can read and profile.

```python
tl_kernel = """
module tl_mix_mod
  implicit none
contains
  subroutine tl_mix_code(nlayers, ls_theta, theta, rho, dz)
    integer, intent(in) :: nlayers
    real, intent(in) :: ls_theta(nlayers)
    real, intent(inout) :: theta(nlayers)
    real, intent(in) :: rho(nlayers)
    real, intent(in) :: dz
    integer :: k
    do k = 2, nlayers
      theta(k) = theta(k) + dz * ls_theta(k) * (rho(k) - rho(k-1))
    end do
  end subroutine tl_mix_code
end module tl_mix_mod
"""
open("/tmp/tl_mix_mod.f90", "w").write(tl_kernel)

run("psyad", "-a", "theta", "rho",
    "-oad", "/tmp/adj_mix_mod.f90", "-otest", "/tmp/adj_test.f90",
    "/tmp/tl_mix_mod.f90")

show("/tmp/adj_mix_mod.f90")
```

Read the reversal, because it is the whole algorithm in four lines:

| tangent-linear | adjoint |
|---|---|
| `do k = 2, nlayers` | `do k = nlayers, 2, -1` |
| `theta` is `intent(inout)` | `theta` is `intent(in)` |
| `rho` is `intent(in)` | `rho` is `intent(inout)` |
| `theta(k) += dz*ls_theta(k)*(rho(k) - rho(k-1))` | `rho(k) += dz*ls_theta(k)*theta(k)`; `rho(k-1) -= dz*ls_theta(k)*theta(k)` |

The loop runs backwards; the roles of input and output swap; and each *read* in the forward code becomes an *increment* in the reverse code, with the sign it had. Transposition of a matrix, expressed as a statement reordering.

Note `ls_theta` — the "linearisation state" — is untouched: it is a **passive** variable, part of $\bar{x}$ rather than of $\delta x$. `-a theta rho` declared the active ones, and that list is the one thing PSyAD cannot infer for you. Getting it wrong is the classic PSyAD error: name too few and the adjoint is incomplete, too many and you get an adjoint of something you did not mean.

### 7.1 The test that makes it trustworthy

`-otest` generated a harness alongside the adjoint. It applies $L$ to random $\delta x$, applies $L^{*}$ to the result, and checks the inner-product identity numerically. That is the standard adjoint correctness test, and it is a genuinely strong one — an adjoint with a sign error or a missing term fails it immediately.

```python
show("/tmp/adj_test.f90")
```

```python
run("gfortran", "-o", "/tmp/adj_test",
    "/tmp/tl_mix_mod.f90", "/tmp/adj_mix_mod.f90", "/tmp/adj_test.f90")
run("/tmp/adj_test")
```

Two inner products agreeing to single-precision tolerance. The whole chain — generate the adjoint, generate its test, compile, run — is four commands, and `lfric_apps` runs the LFRic-flavoured version of it in `science/adjoint` as part of its test suite.

---

## 8. Debugging, and where things go wrong

The failure modes have a short tail, and knowing which layer failed tells you what to do.

| symptom | layer | usual cause |
|---|---|---|
| `TransformationError: ... cannot be enclosed by ...` | transformation | a `CodeBlock` in the region — print them |
| `TransformationError: ... are dependent and cannot be parallelised` | dependence analysis | a real dependence, or an indirection it cannot see through |
| transformation silently applied to nothing | your script | the predicate never matched; `walk()` found no loop of that name |
| `ImportError` on a `*Trans` | version skew | see §3.3; names moved in 3.3 |
| `Generation Error: ...` in PSyKAl mode | the DSL's own rules | metadata/algorithm mismatch, or a rule like the double-argument one in §4.6 |
| unresolved symbol in generated code | frontend | a `use` PSyclone could not follow; `-d` and `-I` tell it where to look |
| wrong loop bounds in a PSy layer | config, not script | `--config`, and `COMPUTE_ANNEXED_DOFS` in it |

Three tools for the middle column. `tree(node)` — the tree as PSyclone sees it, which is the ground truth about what your predicate is matching against. `node.debug_string()` — the Fortran for one node, without needing a whole valid file, and it works on trees mid-transformation that the backend would refuse to write. And a plain `breakpoint()` in your `trans` function: it is imported Python, so the debugger works normally, and stepping through a script on a real file is the fastest way to learn the API.

```python
loop = psyir(two_passes).walk(Loop)[0]
print(loop.debug_string())
print("position:", loop.position, "| depth:", loop.depth, "| parent:", type(loop.parent).__name__)
print("ancestor Routine:", loop.ancestor(Routine).name)
```

`position`, `depth`, `parent`, `ancestor`, `walk` and `detach` are the six methods most of a script is made of.

---

## 9. Exercises

No answers. Each is a few lines in a cell above, or a `psyclone` invocation.

1. Take the `diffuse` routine from §2 and parallelise the `k` loop. Then try the `i` loop instead, and explain the refusal in terms of the stencil.
2. Add a `write(*,*)` statement to the middle of the `diffuse` loop nest and find out which transformations you have just lost. Then move it out and check you have them back.
3. `LoopSwapTrans` swaps a loop nest. Apply it to `diffuse` and decide, from the Fortran note's column-major discussion, which order you want and by how much.
4. In `demo/algorithm/mini_alg_mod.x90`, join the two invokes into one. Diff the generated PSy layer against the two-invoke version. What did PSyclone gain by seeing them together, and did the halo exchange move?
5. Change `GH_INC` to `GH_READWRITE` in the demo kernel and regenerate. The colouring should disappear — and so should something else in the loop bounds. Why is `GH_READWRITE` on `W1` a lie?
6. Write a `trans` that finds every loop in `gw_ussp_mod.F90` writing to a variable of your choice, and reports the loop variable and nesting depth without transforming anything. This is the reconnaissance half of a real ticket.
7. Run the ticket #813 script with `--keep-comments`. Do the comments end up attached to the right statements after the OpenMP is inserted?
8. Give `psyad` a tangent-linear kernel with a `where` construct, or a division by an active variable, and see what it does. Then check whether the generated harness still passes.
9. `psyclone -p routines` inserts profiling hooks. Add it to the demo and read what the instrumentation costs in generated code.
10. Find, in `lfric_core`, a kernel whose `operates_on` is not `CELL_COLUMN`. Generate its stub and account for every argument.

---

## 10. Summary

### PSyclone through Python-shaped eyes

| you know | PSyclone | the difference that matters |
|---|---|---|
| jaxpr | PSyIR | statement-shaped, because it must print back out as reviewable Fortran |
| `objmode` | `CodeBlock` | opaque, and it silently blocks transformations of any region containing it |
| `vmap`/`pmap` | the generated PSy layer | ahead of time, from metadata, into a file you can read |
| `jax.vjp` | PSyAD | source-to-source, with a generated correctness test |
| `-O2` | nothing | there is no optimiser; a script names every rewrite |
| a compiler flag | `optimisation/<site>/<dsl>/*.py` | reviewed, versioned, and per-site |
| a race condition | `TransformationError` | refusal is the product |

### The two modes, one line each

**PSyKAl** (`-api lfric`): metadata plus an `invoke` is enough for PSyclone to *write* the loops, halo exchanges and dirty flags, and your script decides how they are parallelised.

**Transmute** (no `-api`): PSyclone rewrites the loops you already have, and your script has to identify them itself — usually from a profile.

### Traps, in order of how much time they cost

1. **A `CodeBlock` you did not know was there.** Transformations refuse, or worse, apply to a smaller region than you meant. Print them first.
2. **Version skew in imports.** `psyclone.transformations` versus `psyclone.psyir.transformations`, and `Dynamo0p3*` versus `LFRic*`.
3. **Diffing against the wrong baseline.** Always compare script output against no-script output, never against the original source.
4. **Forgetting `--config`** in PSyKAl mode, and getting loop bounds derived from PSyclone's defaults instead of LFRic's.
5. **Comments deleted.** Silent, permanent in the build tree, and fixable with `--keep-comments`.
6. **A private list you supplied by hand.** The one part PSyclone cannot check for you, and the classic source of a race that appears only at 384 ranks.
7. **Assuming the script is portable.** It branches on the compiler, and #813 shows why.

---

## 11. Where to go next

- The [PSyclone user guide](https://psyclone.readthedocs.io/en/stable/) — the reference. Its "transformations" chapter is the catalogue you will live in.
- [`submodules/PSyclone/tutorial/`](https://github.com/stfc/PSyclone/tree/master/tutorial) — the official hands-on tutorial, with notebooks for the fparser2 and PSyIR layers and practicals for both the generic and LFRic routes. Complementary to this note: it teaches the tool on its own terms, at more length.
- [`submodules/PSyclone/examples/lfric/`](https://github.com/stfc/PSyclone/tree/master/examples/lfric) — twenty numbered examples, each a minimal `.x90` plus a script, covering builtins, stencils, operators, kernel transformations and GPU offload.
- [`lfric_core/infrastructure/build/psyclone/psyclone_tools.py`](https://github.com/MetOffice/lfric_core/blob/main/infrastructure/build/psyclone/psyclone_tools.py) and the `optimisation/` tree of any `lfric_apps` application — the production scripts, and the best guide to house style.
- [PSyTran](https://github.com/MetOffice/PSyTran) — where the generic helpers are being consolidated.
- The [Momentum working practices](https://metoffice.github.io/simulation-systems/index.html) for what a ticket like #813 has to contain before review: correctness evidence at several rank counts, performance graphs, and a statement of the technical debt taken on.
