---
title: "Modern Fortran, from the Ground Up"
subtitle: "A personal note for a Python/HPC programmer who has to read LFRic"
filters:
  - fortran-highlight.lua
execute:
  enabled: false
jupyter:
  jupytext:
    comment_magics: false
    text_representation:
      extension: .md
      format_name: markdown
      format_version: '1.3'
      jupytext_version: 1.19.5
  kernelspec:
    display_name: Python 3
    language: python
    name: python3
---

This is not a Fortran reference and not a "learn X in Y minutes". It is a rebuild of the language in dependency order, aimed at one job: **reading** the Fortran in [`lfric_core`](../lfric-core.qmd) and [`lfric_apps`](../lfric-apps.qmd) without friction, and writing enough of it to contribute. Every section either explains a mechanism or builds a bridge from something already familiar — NumPy, Numba, JAX, C, a little C++, a year of Julia.

Two consequences of that aim. First, the order is not a textbook's: arrays come before procedures, because in Fortran the array *is* the type system's opinion and everything else bends around it. Second, features get weight in proportion to how often they appear in LFRic, not how interesting they are — so derived-type polymorphism gets a long section and `equivalence` gets a footnote.[^legacy]

**The essence.** Fortran is the language in which *the array is a first-class type and the compiler is allowed to assume nothing aliases*. That single pair of decisions explains the rest: why declarations are so elaborate (the shape is part of the type), why `intent` exists (aliasing must be declared away), why whole-array expressions and 40 array intrinsics are built in (NumPy is a library reimplementing this in Python), why the standard has no dynamic dispatch by default (`type` before `class`), and why the language stayed fast enough that nobody has managed to displace it from numerical weather prediction in sixty-eight years.

[^legacy]: `equivalence`, `common`, `entry`, computed `goto`, fixed-form source, `dimension` as a standalone statement, arithmetic `if`. You will meet them in code the Met Office inherited from the Unified Model, not in LFRic, whose coding standards forbid them. If you hit one, look it up then; carrying them around now is dead weight.

---

## 0. What is running this page

The notebook is a Python kernel. Fortran cells are handled by a cell magic that writes the cell to a file, compiles it with `gfortran`, links it against everything previous cells defined, runs it, and shows the output. It is a few hundred lines and lives in [`src/fortran_tour/magic.py`](https://github.com/ickc/project-LFRic/blob/main/src/fortran/src/fortran_tour/magic.py).

```python
%load_ext fortran_tour
%fortran_info
```

**Why not the LFortran kernel.** [LFortran](https://lfortran.org) ships a genuine Jupyter kernel — `pixi run lab` in this directory will offer it, it is stateful across cells, and it is a pleasure for arithmetic. I tried it first and rejected it. As of 0.64 the kernel cannot compile `use, intrinsic :: iso_fortran_env`, cannot handle `optional` dummy arguments, and cannot do `allocate(p, source=...)` on a polymorphic variable. LFRic's entire kind system — `r_def`, `i_def`, `r_solver` — is `iso_fortran_env` with a rename, so the kernel cannot run the material that matters here. It is worth keeping installed anyway: `lfortran --show-asr` prints a resolved semantic tree, which is a good way to settle an argument about what a declaration means.

Driving a real compiler also buys three things a kernel would not. Compiler *diagnostics* become teaching material — several cells below are meant to fail. Python and Fortran can sit side by side, so a NumPy expression and its Fortran equivalent are one screen apart. And the build model is honest: modules compile to object files and interface files, exactly as in a real build.

Three cell forms appear below. A cell containing a `module` is compiled and remembered; a cell containing a `program` is compiled, linked and run; anything else is wrapped in `program … end program` for you, with `use` statements hoisted above an inserted `implicit none`. Deliberately broken cells are marked `--expect-error` so the page still renders green.

---

## 1. Same idea, two languages

Start with the bridge, because it is load-bearing for everything after.

```python
import numpy as np

a = np.array([1.0, 2.0, 3.0, 4.0])
b = np.array([10.0, 20.0, 30.0, 40.0])
print(a @ b, (a * b).sum(), a[1:3], np.where(a > 2, a, 0.0))
```

```python
%%fortran
real :: a(4), b(4)
a = [1.0, 2.0, 3.0, 4.0]
b = [10.0, 20.0, 30.0, 40.0]
print *, dot_product(a, b), sum(a*b)
print *, a(2:3)
print *, merge(a, 0.0, a > 2.0)
```

Read the differences, not the similarities.

`real :: a(4)` puts the *shape* in the declaration. In NumPy the shape is a runtime attribute of a heap object; here it is part of the variable's type, known to the compiler, and the compiler will refuse to conform two arrays of different shape. The nearest thing you already write is a Numba signature: `float64[::1]` is a promise to a compiler in exactly the same spirit, and for exactly the same payoff.

`a = [1.0, 2.0, 3.0, 4.0]` is a *whole-array assignment*, not a rebinding. Python's `a = ...` makes the name point at a new object; Fortran's copies four values into storage that already exists. There is no object, no reference count, no identity — `a` is a name for a region of memory with a shape.

`a(2:3)` uses parentheses, is inclusive at both ends, and starts at 1. Three separate irritations, each with a reason: parentheses because arrays and functions are deliberately indistinguishable at the call site;[^brackets] inclusive because the bounds are the dof indices you would write in the mathematics; 1-based because Backus counted from one, and so do Julia, MATLAB and every FEM paper you will read.

`merge(a, 0.0, a > 2.0)` is `np.where`. `dot_product`, `sum`, `matmul`, `transpose`, `reshape`, `pack`, `spread`, `cshift`, `maxloc` are all intrinsic, all older than NumPy, and are where NumPy's vocabulary came from.[^numpy]

[^brackets]: Fortran writes `f(x)` for a function call and `a(i)` for an index, and there is no way to tell them apart by looking. This is not an oversight; it is a deliberate abstraction, sometimes called the *uniform reference principle*. It means an array can be replaced by a function without changing any caller — and it is also why the compiler must have seen a declaration for every name, which is why §2's `implicit none` matters so much.

[^numpy]: Not fancifully: NumPy descends from Numeric, whose design was explicitly informed by Fortran 90's array features and by APL. The `axis=` argument is Fortran's `dim=`; `np.newaxis` broadcasting is a generalisation of `spread`; `order='F'` is column-major because that is what LAPACK, written in Fortran, wanted.

---

## 2. The shape of a file

Fortran's compilation unit is the **program unit**: a `program`, a `module`, a `submodule`, or an external procedure. LFRic uses the first two and, rarely, the third.

```python
%%fortran
program hello
  implicit none
  integer :: i
  do i = 1, 3
    print '("layer ",I0)', i
  end do
end program hello
```

Free-form source since Fortran 90: `!` starts a comment, `&` at end of line continues it, case is insignificant (`REAL`, `Real` and `real` are the same token, and so are `myVar` and `myvar`), and a line can be up to 132 characters by default. Statements are terminated by end-of-line, not `;` — though `;` does separate statements on one line.

### 2.1 `implicit none`, and what it is protecting you from

Without it, Fortran declares variables for you: any undeclared name beginning with `i`–`n` is an `integer`, anything else is a `real`. This is the single most destructive default in the language's history, and it is still the default.

```python
%%fortran --flags "-finit-real=nan"
program implicit_typing
  ! No `implicit none` here, so the old rules apply: names starting with
  ! i-n are integers, everything else is real.
  total = 0.0
  do i = 1, 10
    total = total + i
  end do
  print *, 'total =', total
  ! A typo silently invents a new variable, never assigned to:
  print *, 'totl  =', totl
end program implicit_typing
```

The typo compiles. It prints `NaN` here only because the cell asked for `-finit-real=nan`; the default is to print whatever happened to be in that stack slot, which is frequently a plausible-looking number. `implicit none` turns both the convenience and the catastrophe off, and LFRic's coding standards require it in **every module and every procedure inside it** — the repetition is deliberate, because a nested procedure does not inherit it in older standards and the standard hosts do not all agree.

```python
%%fortran --expect-error
program caught
  implicit none
  real :: total
  total = 0.0
  print *, totl
end program caught
```

### 2.2 Modules, and why there are no header files

A module is a namespace plus an interface. `use` imports; `only:` restricts.

```python
%%fortran
module geometry_mod

  use, intrinsic :: iso_fortran_env, only : real64

  implicit none

  private                                   ! everything below is module-local ...
  public :: point_type, distance, EARTH_RADIUS   ! ... except these

  integer,     parameter :: r_def = real64
  real(r_def), parameter :: EARTH_RADIUS = 6371229.0_r_def

  type :: point_type
    real(r_def) :: x = 0.0_r_def
    real(r_def) :: y = 0.0_r_def
  end type point_type

contains

  pure function distance(a, b) result(d)
    type(point_type), intent(in) :: a, b
    real(r_def) :: d
    d = hypot(a%x - b%x, a%y - b%y)
  end function distance

end module geometry_mod
```

```python
%%fortran
use geometry_mod, only : point_type, distance, EARTH_RADIUS
type(point_type) :: p, q
p = point_type(0.0d0, 0.0d0)
q = point_type(3.0d0, 4.0d0)
print *, distance(p, q), EARTH_RADIUS
```

`private` as a bare statement flips the module's default; LFRic requires it, then an explicit `public ::` list. Read that list first when you open an unfamiliar module — it is the module's API, and everything else is implementation.

Here is the part with no C or Python analogue. Compiling a module **emits a binary interface file** — `geometry_mod.mod` with gfortran — and every `use` of that module *reads* it. There is no header, no forward declaration, no textual inclusion. The interface is generated by the compiler, from the source, as a side effect of compiling it.

```python
import pathlib
print(sorted(p.name for p in pathlib.Path(".nbbuild").glob("*.mod")))
```

Three consequences you will feel:

1. **Objects have a build order, and it is invisible in the file names.** `foo.f90` must be compiled before `bar.f90` if `bar` uses `foo`'s module, and nothing about the names says so. Every Fortran build system therefore ships a source scanner; LFRic's is [fab](https://github.com/MetOffice/fab), and [`demo/fortdep.py`](https://github.com/ickc/project-LFRic/blob/main/src/fortran/demo/fortdep.py) here is a forty-line version so the mechanism is not mysterious.
2. **`.mod` files are compiler- and version-specific**, not a distribution format. This is why "just link the library" does not work across compilers, and why Spack builds the whole LFRic stack per toolchain.
3. **Touching a module recompiles everything downstream** — the avalanche that `submodule` (§6.9) exists to stop.

LFRic adds a naming rule on top: one module per file, and *the file name must be the module name*. `field_parent_mod.f90` contains `field_parent_mod` and nothing else. That is not aesthetics; it is what lets the build system resolve a `use` to a file without parsing.[^suffix]

[^suffix]: The `_mod` suffix is likewise mechanical. LFRic's conventions: `_mod` for a module, `_type` for a derived type, `_kernel_mod` for a kernel, `_alg_mod` for an algorithm, `_constructor`/`_initialiser` for the things a C++ programmer would call constructors. Extensions carry meaning too: `.f90` is plain source, `.F90` is source that goes through the C preprocessor (capital F, capital difference), `.x90`/`.X90` is algorithm-layer source that PSyclone will rewrite, `.t90` is a template expanded at build time, `.pf` is a pFUnit test.

---

## 3. Declarations

Every declaration has the same grammar:

```
type-spec [, attribute]... :: name [, name]...
```

which reads left to right as *"a `real` of kind `r_def`, which is `allocatable` and `private`, called `data`, of rank one"*:

```fortran
real(kind=r_def), allocatable, private :: data(:)
integer(i_def),   parameter            :: NLAYERS = 30
type(mesh_type),  pointer              :: mesh => null()
character(len=:), allocatable          :: name
class(field_type), intent(inout)       :: self
procedure(write_interface), pointer, nopass :: write_method => null()
```

Learn to parse this and half of reading Fortran is done. The attributes you will actually meet: `parameter`, `allocatable`, `pointer`, `target`, `intent(in|out|inout)`, `optional`, `save`, `dimension(...)`, `public`, `private`, `contiguous`, `value`, `protected`.

### 3.1 Kinds, and why LFRic writes `r_def` everywhere

`real` alone means "the default real", whose size the standard does not fix. A **kind parameter** pins it:

```python
%%fortran
use, intrinsic :: iso_fortran_env, only : real32, real64, real128, int32, int64
real(real32)  :: s
real(real64)  :: d
real(real128) :: q
print '("bytes: ",3(I0,1X))', storage_size(s)/8, storage_size(d)/8, storage_size(q)/8
print '("digits: ",3(I0,1X))', precision(s), precision(d), precision(q)
print '("kind numbers are opaque tokens: ",3(I0,1X))', real32, real64, real128
```

The kind *number* is not a byte count and not portable — it is an opaque token that happens to be 4, 8, 16 in gfortran and is different in other compilers. Always name it. LFRic names them once, in [`constants_mod`](https://github.com/MetOffice/lfric_core/blob/main/infrastructure/source/utilities/constants_mod.F90), and then never writes a bare `real` again:

```fortran
integer, parameter :: r_def    = real64   ! the model's working precision
integer, parameter :: r_solver = real64   ! the iterative solver's precision
integer, parameter :: r_tran   = real64   ! the transport scheme's precision
integer, parameter :: i_def    = int32
integer, parameter :: l_def    = int32    ! yes, logicals have kinds too
```

each guarded by `#if (RDEF_PRECISION == 32)` so a build-time switch moves the whole model. That is why `constants_mod.F90` has a capital F: it is preprocessed. And it is why mixed-precision experiments in LFRic are a build flag rather than a rewrite — the same trick as JAX's `jax_enable_x64`, done with the preprocessor instead of a global.

**The literal-suffix rule.** A literal without a suffix has *default* kind, whatever the surrounding declaration says:

```python
%%fortran
use, intrinsic :: iso_fortran_env, only : real64
integer, parameter :: r_def = real64
real(r_def) :: a, b, c
a = 0.1_r_def                ! literal parsed at double precision
b = 0.1                      ! literal parsed at single, then widened
c = real(0.1, r_def)         ! same disaster, spelled differently
print '(3(ES23.16,/))', a, b, c
print *, 'a == b?', a == b
```

`b` and `c` are wrong in the eighth significant figure, because `0.1` was rounded to single precision *before* anything widened it. Hence the LFRic standard: **every real literal carries a kind suffix**, and `real(1.23, r_def)` is explicitly called out as the wrong fix. The Python analogue is `np.float32(0.1)` vs `np.float64(0.1)` — the difference is that here the narrowing is silent and the declaration two lines up looks correct.

### 3.2 `save`, and Fortran's mutable default argument

A local variable normally vanishes when a procedure returns. `save` makes it persist — the `static` of C. Fine, except for one rule:

> **Initialising a local variable in its declaration implies `save`.**

```python
%%fortran
module counter_mod
  implicit none
contains
  subroutine tick(label)
    character(*), intent(in) :: label
    integer :: n = 0          ! initialised here => implicitly `save`d
    n = n + 1
    print '(A,": n = ",I0)', label, n
  end subroutine tick
end module counter_mod
```

```python
%%fortran
use counter_mod, only : tick
call tick('first ')
call tick('second')
call tick('third ')
```

`n` is not reset. It is one variable, shared by every call, for the life of the program — and therefore shared by every *thread* that calls the procedure. In an OpenMP region this is a data race with no syntax to warn you.

You already know this bug in another dress: Python's mutable default argument. `def f(x, seen=[])` evaluates `[]` once, at definition, and every call shares it. Same trap, same cause — an initialiser that looks per-call but is evaluated once.

This is why LFRic's coding standards say, flatly, that procedure-local pointers must not be initialised at declaration, and must be `nullify`'d in the body instead:

```fortran
type(my_type), pointer :: my_pointer => null()   ! Wrong: now saved, now shared
```
```fortran
type(my_type), pointer :: my_pointer
nullify(my_pointer)                              ! Right
```

Components of a derived type are exempt — initialising those is per-object and safe, which is why you see `=> null()` inside `type` definitions all over LFRic and nowhere inside a `subroutine`.

### 3.3 Characters are fixed-length and blank-padded

A `character(len=n)` variable is *always* exactly `n` characters. Assignment pads with blanks or truncates; it never resizes.

```python
%%fortran
character(10) :: name
character(3)  :: short
name  = 'W2'
short = 'broadband'
print '("[",A,"]")', name              ! padded to 10
print '("[",A,"]")', trim(name)        ! trailing blanks removed
print '("[",A,"]")', short             ! silently truncated
print '(2(I0,1X))', len(name), len_trim(name)
print '("[",A,"]")', 'W' // '2' // 'h' ! // is concatenation
```

You have met these semantics before: a FITS header card is fixed-width and blank-padded for exactly the same reason — the storage is a fixed record, not a variable-length object. NumPy's `'S10'` dtype behaves the same way.

Deferred-length strings (Fortran 2003) restore sanity, at the cost of an allocation:

```python
%%fortran
character(:), allocatable :: name
name = 'W2broken'          ! allocated to exactly 8 on assignment
print '(I0,": [",A,"]")', len(name), name
name = 'W3'                ! reallocated to 2
print '(I0,": [",A,"]")', len(name), name
```

Two LFRic rules follow. Dummy arguments of `intent(in)`/`intent(inout)` character type must be declared `character(*)` — assumed length — so the procedure accepts any length rather than silently truncating. And `trim` should be used when *passing* a character variable, because otherwise the padding travels with it.

---

## 4. Arrays

This is the language's centre of gravity. Everything here has a NumPy counterpart; the differences are where the interest lies.

### 4.1 Shape lives in the declaration

```python
%%fortran
real    :: a(5)              ! explicit shape, bounds 1:5
real    :: b(0:4)            ! same size, bounds 0:4
real    :: c(-1:1, 2)        ! rank 2, shape (3,2)
real, allocatable :: d(:,:)  ! deferred shape, allocated later
integer :: i

a = [(real(i), i = 1, 5)]    ! implied-do: a list comprehension
b = a
allocate(d(2,3), source=0.0)

print '("a: lbound ",I0," ubound ",I0)', lbound(a,1), ubound(a,1)
print '("b: lbound ",I0," ubound ",I0)', lbound(b,1), ubound(b,1)
print '("c: shape ",2(I0,1X)," size ",I0," rank ",I0)', shape(c), size(c), rank(c)
print '("d: shape ",2(I0,1X))', shape(d)
print *, b(0), b(4)
```

**Arbitrary lower bounds have no NumPy analogue** and are used in earnest. A stencil array declared `real :: w(-1:1)` lets you write `w(-1)`, `w(0)`, `w(1)` for the left, centre and right weights, which is what the mathematics says. A halo-aware array declared `(1-halo : n+halo)` puts the halo in negative and over-range indices where it belongs. Note the trap that follows: passing such an array to an assumed-shape dummy `real :: x(:)` **renumbers it to start at 1** unless the dummy is declared `x(lbound:)`.

`[(real(i), i = 1, 5)]` is an *implied-do* array constructor — Fortran's list comprehension, and older than Python's by three decades.

### 4.2 Column-major, and why it matters more here than in NumPy

```python
%%fortran --flags "-O2 -fcheck=no-bounds"
use, intrinsic :: iso_fortran_env, only : int64, real64
integer, parameter :: n = 3000, nrep = 3
real(real64), allocatable :: m(:,:)
real(real64) :: total, best_col, best_row, elapsed, keep
integer :: i, j, rep
integer(int64) :: t0, t1, rate

allocate(m(n,n))
call random_number(m)
call system_clock(count_rate=rate)
best_col = huge(best_col)
best_row = huge(best_row)
! `keep` exists only so that `total` is observably used. Without it the
! compiler notices the sums are dead and deletes both loops, and the
! benchmark measures nothing -- which is how this cell read on its first
! draft, at a very convincing 1.00x.
keep = 0.0_real64

do rep = 1, nrep
  ! Fast: the first index varies fastest, so this walks memory in order.
  call system_clock(t0)
  total = 0.0_real64
  do j = 1, n
    do i = 1, n
      total = total + m(i,j)
    end do
  end do
  call system_clock(t1)
  keep = keep + total
  elapsed = real(t1-t0, real64)/rate
  best_col = min(best_col, elapsed)

  ! Slow: strides by n doubles, so every load is a fresh cache line.
  call system_clock(t0)
  total = 0.0_real64
  do i = 1, n
    do j = 1, n
      total = total + m(i,j)
    end do
  end do
  call system_clock(t1)
  keep = keep + total
  elapsed = real(t1-t0, real64)/rate
  best_row = min(best_row, elapsed)
end do

print '("column-inner (good): ",F7.4," s")', best_col
print '("row-inner     (bad): ",F7.4," s")', best_row
print '("penalty for getting it backwards: ",F5.2,"x")', best_row/best_col
print '("(checksum ",ES12.5,")")', keep
```

Fortran is **column-major**: the *leftmost* index varies fastest. So the innermost loop should run over the *first* index — the exact opposite of C and of NumPy's default. `np.asfortranarray` and `order='F'` exist because LAPACK is Fortran.

The measured penalty is about a factor of two, not the order of magnitude you might expect, and the reason is worth knowing: a modern prefetcher copes well with a constant stride, so even the wrong order achieves a decent fraction of peak bandwidth on a reduction this simple. The penalty grows sharply once the stride outruns what the prefetcher tracks, once the loop body does more work per element, or once the array is being written rather than read.

Note also the `keep` variable, and why it is there. An ahead-of-time compiler will delete a loop whose result nothing reads, and at `-O2` gfortran does exactly that — the first draft of this cell reported a penalty of 1.00x because both loops had been optimised away entirely. Anything you time in a compiled language needs its result to escape. It is the same discipline as returning the value from a `%timeit` body, or `block_until_ready()` in JAX, except that here the work does not merely finish late, it never happens.

Why it matters more here: in NumPy you rarely write the loop, so the library gets the order right for you. In Fortran you write the loop, and the compiler will not reorder it for you if there is any chance the arrays alias.

For LFRic specifically, the layout decision that follows from this is the vertical one. The mesh is horizontally unstructured but vertically structured — every column has the same number of layers — and field data is laid out with **the vertical index contiguous**, so a column is a contiguous run. Every kernel then works on one column, walking memory in order, and the horizontal indirection through the dofmap happens once per column rather than once per point.

### 4.3 Conformability is not broadcasting

```python
%%fortran --expect-error
real :: a(3,4), v(3)
a = 1.0
v = 2.0
a = a + v          ! NumPy would broadcast v across the second axis. Fortran will not.
print *, sum(a)
```

Fortran requires operands to be *conformable*: same shape, or one of them scalar. There is no broadcasting, no implicit axis insertion, no `np.newaxis`. Say it explicitly with `spread`:

```python
%%fortran
real :: a(3,4), v(3)
a = 1.0
v = [1.0, 2.0, 3.0]
a = a + spread(v, dim=2, ncopies=4)     ! ≈ v[:, None]
print '(4(F5.1,1X))', (a(1,:))
print '("sum = ",F6.1)', sum(a)
```

This is a real ergonomic loss and worth knowing about in advance, because it changes how you read numerical code: a Fortran expression that looks elementwise *is* elementwise, with no hidden shape algebra. What you lose in convenience you gain in there being no such thing as an accidental broadcast.

### 4.4 The intrinsic vocabulary

| NumPy | Fortran | note |
|---|---|---|
| `a.sum()`, `a.sum(axis=0)` | `sum(a)`, `sum(a, dim=1)` | `dim` is 1-based |
| `a.prod()`, `a.max()`, `a.min()` | `product(a)`, `maxval(a)`, `minval(a)` | |
| `a.argmax()` | `maxloc(a)` | returns a rank-1 array of indices |
| `np.count_nonzero(m)` | `count(m)` | `m` a logical array |
| `m.any()`, `m.all()` | `any(m)`, `all(m)` | |
| `a @ b` | `matmul(a, b)` | `dot_product` for rank-1 · rank-1 |
| `a.T` | `transpose(a)` | rank 2 only |
| `a.reshape(...)` | `reshape(a, [n,m])` | column-major fill order |
| `np.where(m, a, b)` | `merge(a, b, m)` | note the argument order |
| `a[m]` | `pack(a, m)` | `unpack` goes back |
| `np.roll(a, k)` | `cshift(a, -k)` | `eoshift` shifts in a fill value |
| `v[:, None] * ones(n)` | `spread(v, 2, n)` | |
| `np.sum(a, where=m)` | `sum(a, mask=m)` | most reductions take a `mask` |
| `a[::2]` | `a(1:n:2)` | stride is the third colon field |

```python
%%fortran
integer :: v(6), i
logical :: m(6)
v = [(i, i = 1, 6)]
m = mod(v, 2) == 0

print '("v         ",6(I3))', v
print '("pack even ",3(I3))', pack(v, m)
print '("merge     ",6(I3))', merge(v, -v, m)
print '("cshift +2 ",6(I3))', cshift(v, 2)
print '("eoshift   ",6(I3))', eoshift(v, 2, boundary=0)
print '("reverse   ",6(I3))', v(6:1:-1)
print '("maxloc    ",I0,"  count ",I0,"  any ",L1)', maxloc(v, 1), count(m), any(m)
```

Note `cshift(v, 2)` shifts *left* — `np.roll` shifts right for a positive argument. Fortran's sign convention is "move element `i+k` to position `i`".

### 4.5 `where`, and masked assignment

```python
%%fortran
real :: t(6)
integer :: i
t = [(real(i)*10.0 - 25.0, i = 1, 6)]
print '(6(F7.1))', t

where (t < 0.0)
  t = 0.0                       ! clamp, in place, only where the mask holds
elsewhere (t > 20.0)
  t = 20.0
end where
print '(6(F7.1))', t
```

`where` is masked *assignment*: it evaluates the right-hand side and stores only under the mask. Two things it is not. It is not control flow — you cannot call a subroutine in a `where` block, and the mask is evaluated once, up front. And it does not protect the right-hand side from being evaluated where the mask is false, so `where (x /= 0.0) y = 1.0/x` may still divide by zero (harmlessly, into a discarded lane, unless you have trapping enabled).[^wheretrap]

[^wheretrap]: This is exactly the `jnp.where` gotcha — `jnp.where(x != 0, 1/x, 0)` still evaluates `1/x` everywhere and produces `nan` in the gradient. Same shape of problem, same fix: perturb the operand rather than mask the result.

### 4.6 `elemental` — Fortran's ufunc

Declare a scalar procedure `elemental` and the compiler generates the array-valued version for you, at any rank.

```python
%%fortran
module physics_mod
  implicit none
contains
  !> Saturation vapour pressure, Tetens' formula. Scalar in, scalar out.
  elemental function e_sat(t_celsius) result(e)
    real, intent(in) :: t_celsius
    real :: e
    e = 610.78*exp(17.27*t_celsius/(t_celsius + 237.3))
  end function e_sat
end module physics_mod
```

```python
%%fortran
use physics_mod, only : e_sat
real :: t(4), profile(2,3)
t = [-10.0, 0.0, 15.0, 30.0]
profile = 20.0

print '(4(F9.2))', e_sat(t)          ! rank 1 in, rank 1 out
print '(F9.2)',    e_sat(15.0)       ! scalar in, scalar out
print '("rank 2 works too: ",I0)', size(e_sat(profile))
```

This is `@np.vectorize` done properly, or `jax.vmap` over a scalar function — except that it is compiled to a real loop with no Python-level overhead, and the compiler may vectorise it into SIMD.

The price is a set of restrictions that make the generation sound: an `elemental` procedure is implicitly `pure`, all arguments must be scalar and `intent(in)` (except one `intent(out)` result), and it may not do I/O or be recursive. `impure elemental` (Fortran 2008) relaxes purity when you need a side effect, and gives up the parallelism guarantee with it.

### 4.7 `pure`, and what it promises

`pure` means: no I/O, no `stop`, no modification of anything outside the argument list, no `save`d state, and every dummy argument `intent(in)` (for a function). In exchange, the compiler is allowed to call it inside `do concurrent`, `forall`, and in specification expressions.

The bridge is exact: this is JAX's functional-purity requirement, and for the same reason. `jax.jit` needs purity to be free to reorder, fuse and replay; `do concurrent` needs it to be free to run iterations in any order or simultaneously. Both languages made purity a *declaration* rather than an inference because inferring it across a whole program is intractable.

### 4.8 Descriptors: the difference that governs kernel signatures

There are two ways to receive an array, and the distinction is the single most consequential thing in this section for reading LFRic.

```fortran
subroutine assumed_shape(x)          ! Fortran 90 style
  real, intent(in) :: x(:,:)         ! shape comes with the argument
end subroutine

subroutine explicit_shape(n, m, x)   ! Fortran 77 style
  integer, intent(in) :: n, m
  real, intent(in) :: x(n,m)         ! caller promises the shape
end subroutine
```

**Assumed shape** passes a *descriptor* — a small struct holding the base address, and the extent and stride of each dimension.[^dope] It is a NumPy view: the callee can be handed a non-contiguous slice and will stride correctly. It requires an explicit interface (§5.3), which in practice means the procedure must live in a module.

**Explicit shape** passes a bare address. The callee assumes the elements are contiguous in the declared shape; the caller is responsible for making that true, and the compiler will silently insert a **copy-in/copy-out** temporary if the actual argument is a non-contiguous slice.

```python
%%fortran --flags "-fcheck=array-temps"
module shapes_mod
  implicit none
contains
  subroutine takes_explicit(n, x)
    integer, intent(in) :: n
    real, intent(inout) :: x(n)
    x = x*2.0
  end subroutine takes_explicit
end module shapes_mod
```

```python
%%fortran --flags "-fcheck=array-temps"
use shapes_mod, only : takes_explicit
real :: a(6)
integer :: i
a = [(real(i), i = 1, 6)]
call takes_explicit(3, a(1:5:2))   ! a stride-2 slice into a contiguous dummy
print '(6(F5.1))', a
```

gfortran reports the temporary at run time when asked. The copy is correct but costs two passes over the data, and in a kernel called once per column it would be a disaster. This is the same phenomenon as NumPy silently calling `np.ascontiguousarray` before handing a slice to a C routine.

Now look at a real LFRic kernel signature and it decodes itself:

```fortran
subroutine matrix_vector_code(cell, nlayers, lhs, x, ncell_3d, matrix, &
                              ndf1, undf1, map1, ndf2, undf2, map2)
  integer(kind=i_def),                  intent(in)    :: cell, nlayers, ncell_3d
  integer(kind=i_def),                  intent(in)    :: undf1, ndf1
  integer(kind=i_def), dimension(ndf1), intent(in)    :: map1
  real(kind=r_double), dimension(undf1),              intent(inout) :: lhs
  real(kind=r_double), dimension(undf2),              intent(in)    :: x
  real(kind=r_double), dimension(ncell_3d,ndf1,ndf2), intent(in)    :: matrix
```

Every array is **explicit shape**, and every extent is passed as a separate integer argument. That is not legacy style; it is a deliberate choice, and PSyclone generates the call sites to match. Explicit shape means no descriptor to dereference, guaranteed contiguity, and a signature that an OpenACC or CUDA back end can map onto a device kernel. It is the same bargain as annotating a Numba signature `float64[::1]` instead of `float64[:]`: you give up flexibility at the boundary and get addressing the compiler can reason about.

The `contiguous` attribute (Fortran 2008) is the middle road — an assumed-shape dummy plus a promise:

```fortran
real, intent(in), contiguous :: x(:)     ! descriptor, but guaranteed unit stride
```

[^dope]: Historically called a *dope vector* — 1960s compiler jargon for the metadata that "dopes out" where an element lives. Fortran 2018 standardised its layout as `CFI_cdesc_t` in `ISO_Fortran_binding.h`, so C can now construct one; before that, passing an assumed-shape array to C was compiler-specific.

### 4.9 Allocatable and automatic arrays

```python
%%fortran
module work_mod
  implicit none
contains
  subroutine solve(n, x)
    integer, intent(in) :: n
    real, intent(inout) :: x(n)
    real :: scratch(n)                    ! automatic: sized at entry, on the stack
    real, allocatable :: big(:)           ! allocatable: on the heap, explicit
    scratch = x*2.0
    allocate(big(2*n))
    big(1:n)     = scratch
    big(n+1:2*n) = -scratch
    x = big(1:n) - big(n+1:2*n)      ! = 2*scratch = 4*x
    deallocate(big)                       ! optional here: it would go out of scope
  end subroutine solve
end module work_mod
```

```python
%%fortran
use work_mod, only : solve
real :: x(4)
x = [1.0, 2.0, 3.0, 4.0]
call solve(4, x)
print '(4(F6.1))', x
```

An **automatic array** is sized from an expression at procedure entry and lives on the stack. Convenient, and the classic HPC segfault: a kernel with `real :: work(nlayers, ndf, ndf)` on a thread whose stack is 8 MB by default. If an LFRic run dies at scale with no message, `ulimit -s unlimited` and `OMP_STACKSIZE` are the first two things to try.

An **allocatable** is heap, owning, and automatically deallocated when it goes out of scope — it is `std::vector`/`unique_ptr`, with move semantics via `move_alloc`. LFRic's standard nevertheless says every `allocate` must have a matching `deallocate`; the scope rule makes that redundant for locals but explicit for components and long-lived state, and reviewers apply it uniformly.

---

## 5. Procedures

A `subroutine` is invoked with `call` and returns nothing; a `function` returns a value and is invoked in an expression. LFRic uses subroutines for anything that modifies state and functions for anything that computes, which is a good habit rather than a rule.

### 5.1 `intent` is the most useful thing on the line

```python
%%fortran
module transport_mod
  implicit none
contains
  subroutine advect(dt, u, theta, flux)
    real, intent(in)    :: dt        ! read only; assigning to it will not compile
    real, intent(in)    :: u(:)
    real, intent(inout) :: theta(:)  ! read and written
    real, intent(out)   :: flux(:)   ! written; on entry its value is undefined
    integer :: n
    n = size(theta)
    flux  = u*theta
    theta = theta - dt*(flux - cshift(flux, -1))
  end subroutine advect
end module transport_mod
```

```python
%%fortran
use transport_mod, only : advect
real :: u(5), theta(5), flux(5)
u = 1.0
theta = [1.0, 2.0, 3.0, 4.0, 5.0]
flux = -999.0                     ! this value never reaches the subroutine
call advect(0.1, u, theta, flux)
print '("theta ",5(F7.3))', theta
print '("flux  ",5(F7.3))', flux
```

Three things `intent` buys, in increasing order of importance.

It is documentation the compiler enforces — assigning to an `intent(in)` dummy is a compile error, so the annotation cannot rot. It is optimisation licence: `intent(out)` says the incoming value is dead, so the compiler need not load it, and `intent(in)` combined with Fortran's no-aliasing rule says the callee may cache it in a register across a write through another argument.[^alias] And it is the vocabulary the rest of LFRic's tooling is written in: PSyclone's kernel metadata (`GH_READ`, `GH_WRITE`, `GH_INC`) is `intent` lifted to the level of whole fields, and Doxygen's `@param[in]`/`@param[out]` mirrors it in the comments.

The trap: **`intent(out)` on a derived type re-initialises it**. Any component with a default initialiser is reset to that default on entry, and any `allocatable` component is deallocated. If you meant "I will fill this in", say `intent(out)`; if you meant "this already holds something I will add to", `intent(out)` will silently destroy it. This is precisely why LFRic requires kernel output arguments to be `intent(inout)`: a `CELL_COLUMN` kernel is called once per cell and each call touches only part of the field, so `intent(out)` would license the compiler to treat the rest as garbage.

[^alias]: Fortran's aliasing rule is stronger than C's and predates `restrict` by decades: if two dummy arguments are associated with the same storage and either is written, the program is *invalid* — not implementation-defined, invalid. The compiler assumes it never happens. That assumption is a large part of why Fortran benchmarks well against C on numerical loops, and also why passing overlapping slices of the same array to a procedure is a genuine bug rather than a slow path.

### 5.2 Optional arguments and keyword calls

```python
%%fortran
module log_mod
  implicit none
contains
  subroutine log_event(message, level, unit)
    character(*), intent(in) :: message
    integer, intent(in), optional :: level
    integer, intent(in), optional :: unit
    integer :: this_level, this_unit
    ! `present` is the only legal question to ask about an absent argument.
    this_level = 1
    if (present(level)) this_level = level
    this_unit = 6
    if (present(unit)) this_unit = unit
    write(this_unit, '("[",I0,"] ",A)') this_level, message
  end subroutine log_event
end module log_mod
```

```python
%%fortran
use log_mod, only : log_event
call log_event('mesh built')
call log_event('solver diverged', 3)
call log_event('using keyword form', unit=6, level=2)      ! order is free
call log_event(message='skipping the middle argument', unit=6)
```

Keyword arguments work exactly as in Python and are required as soon as you skip an optional. Reading an absent argument's *value* is undefined behaviour; `present()` first, always. Note also that an optional argument can be passed straight through to another optional argument without unwrapping — passing an absent argument along keeps it absent, which is how LFRic's initialiser chains stay readable.

### 5.3 Explicit interfaces, and why everything lives in a module

When the compiler can see a procedure's interface, it checks the call: argument count, types, ranks, intents, keyword names. When it cannot, it checks nothing.

A procedure gets an **explicit interface** if it is a module procedure, an internal procedure (after `contains` inside a program or another procedure), or is described by an `interface` block. Anything else — a bare `subroutine` in its own file, the Fortran 77 way — has an **implicit interface**, and the compiler will happily emit a call passing a real where an integer was expected.

```python
%%fortran --expect-error
use transport_mod, only : advect
real :: theta(5), flux(5)
integer :: wrong_u(5)
theta = 1.0
wrong_u = 1
call advect(0.1, wrong_u, theta, flux)     ! integer where real(:) is wanted
```

That diagnostic exists only because `advect` lives in a module. The same subroutine compiled as a free-standing file would link and produce nonsense.[^extern] This is the whole reason LFRic mandates one module per file: not tidiness, but making the compiler's type checker reach every call site.

`interface` blocks are for the cases where you cannot put the callee in a module — chiefly C bindings (§8.5) and legacy libraries:

```fortran
interface
  subroutine dgemm(transa, transb, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc) &
       bind(c, name='dgemm_')
    ...
  end subroutine dgemm
end interface
```

[^extern]: gfortran will often catch it anyway *within a single file*, because it can see both definitions and applies a heuristic check. Across files it cannot, and that is where the bug lives. `-Wimplicit-interface` will flag every call through an implicit interface if you want to audit inherited code.

### 5.4 Generic interfaces: overloading, and the closest thing to templates

Fortran has no generics.[^f2023] What it has is the ability to give several distinct procedures one name, resolved at compile time by argument type, kind and rank.

```python
%%fortran
module norm_mod
  use, intrinsic :: iso_fortran_env, only : real32, real64
  implicit none
  private
  public :: norm2sq

  interface norm2sq
    module procedure norm2sq_r32
    module procedure norm2sq_r64
  end interface norm2sq

contains

  pure function norm2sq_r32(x) result(s)
    real(real32), intent(in) :: x(:)
    real(real32) :: s
    s = sum(x**2)
  end function norm2sq_r32

  pure function norm2sq_r64(x) result(s)
    real(real64), intent(in) :: x(:)
    real(real64) :: s
    s = sum(x**2)
  end function norm2sq_r64

end module norm_mod
```

```python
%%fortran
use, intrinsic :: iso_fortran_env, only : real32, real64
use norm_mod, only : norm2sq
real(real32) :: a(3)
real(real64) :: b(3)
a = [1.0_real32, 2.0_real32, 3.0_real32]
b = [1.0_real64, 2.0_real64, 3.0_real64]
print '("single: ",ES14.7)', norm2sq(a)
print '("double: ",ES23.16)', norm2sq(b)
```

This is `functools.singledispatch`, resolved statically, and it is exactly what LFRic's `matrix_vector_kernel_mod` does — one `interface matrix_vector_code` over `matrix_vector_code_r_single` and `matrix_vector_code_r_double`, with the two bodies character-for-character identical apart from the kind. The duplication is real, and LFRic's answer to it is §6.10.

The resolution rules are worth one sentence: candidates must be distinguishable by the type, kind and rank of their non-optional arguments alone. Not by return type, not by value, not by intent. If two specifics could match the same call, it is a compile error rather than an ambiguity resolved by ordering.

[^f2023]: Fortran 2023 adds templates (generic programming with `template`/`instantiate`). As of 2026 no production compiler implements them, and LFRic will not be able to use them for years. Treat them as a rumour.

### 5.5 Procedure pointers

```python
%%fortran
module callback_mod
  implicit none
  abstract interface
    pure function scalar_op(x) result(y)
      real, intent(in) :: x
      real :: y
    end function scalar_op
  end interface
contains
  pure function square(x) result(y)
    real, intent(in) :: x
    real :: y
    y = x*x
  end function square

  pure function halve(x) result(y)
    real, intent(in) :: x
    real :: y
    y = 0.5*x
  end function halve

  subroutine apply(op, a)
    procedure(scalar_op) :: op
    real, intent(inout) :: a(:)
    integer :: i
    do i = 1, size(a)
      a(i) = op(a(i))
    end do
  end subroutine apply
end module callback_mod
```

```python
%%fortran
use callback_mod, only : apply, square, halve, scalar_op
procedure(scalar_op), pointer :: chosen => null()
real :: a(4)

a = [1.0, 2.0, 3.0, 4.0]
call apply(square, a)
print '(4(F7.2))', a

chosen => halve                   ! `=>`, not `=`: pointer association
call apply(chosen, a)
print '(4(F7.2))', a
```

`abstract interface` names a *signature*; `procedure(name)` declares something with that signature. This is how LFRic makes field I/O pluggable — `field_parent_mod` declares `write_interface`, `read_interface`, `checkpoint_write_interface`, and a field holds procedure pointers to whichever implementation the I/O layer installed. A Python reader should see a callback with a type annotation; a C reader, a function pointer with a checked prototype.

---

## 6. Derived types and object orientation

LFRic is written in Fortran 2003 object-oriented style throughout, so this section carries the most weight. The vocabulary maps onto Python and C++ cleanly enough, with two genuine surprises: `class` does not mean what you think, and there are no constructors.

### 6.1 Types and their components

```python
%%fortran
module mesh_mod
  use, intrinsic :: iso_fortran_env, only : real64, int32
  implicit none
  private
  public :: mesh_type

  integer, parameter :: r_def = real64, i_def = int32

  type :: mesh_type
    private
    integer(i_def) :: ncell = 0                     !< default initialiser
    integer(i_def) :: nlayers = 0
    real(r_def), allocatable :: cell_area(:)        !< owned, deep-copied
    character(:), allocatable :: name
  contains
    procedure, public :: initialise => mesh_initialiser
    procedure, public :: get_ncell
    procedure, public :: total_area
  end type mesh_type

contains

  subroutine mesh_initialiser(self, name, ncell, nlayers)
    class(mesh_type), intent(inout) :: self
    character(*),     intent(in)    :: name
    integer(i_def),   intent(in)    :: ncell, nlayers
    self%name    = name
    self%ncell   = ncell
    self%nlayers = nlayers
    allocate(self%cell_area(ncell), source=1.0_r_def/real(ncell, r_def))
  end subroutine mesh_initialiser

  pure function get_ncell(self) result(n)
    class(mesh_type), intent(in) :: self
    integer(i_def) :: n
    n = self%ncell
  end function get_ncell

  pure function total_area(self) result(a)
    class(mesh_type), intent(in) :: self
    real(r_def) :: a
    a = sum(self%cell_area)
  end function total_area

end module mesh_mod
```

```python
%%fortran
use mesh_mod, only : mesh_type
type(mesh_type) :: m, copy
call m%initialise('C24', 3456, 30)
print '("ncell ",I0,"  area ",F8.5)', m%get_ncell(), m%total_area()

copy = m                              ! intrinsic assignment: a deep copy
print '("copy  ",I0,"  area ",F8.5)', copy%get_ncell(), copy%total_area()
```

`%` is the component selector — Fortran's `.`, which was taken by `.and.` and friends. `private` inside the type body hides the components while leaving the type itself public: the LFRic pattern, and the reason `field_type` can be passed around by algorithm code that physically cannot index into it.

Note what `copy = m` did. Intrinsic assignment of a derived type is **component-wise and deep for `allocatable` components** — `copy%cell_area` is a fresh array, not an alias. (It is *shallow* for `pointer` components: those are pointer-assigned.) So the default is value semantics, unlike Python and like C++.

### 6.2 `class` versus `type`: the distinction that matters

```fortran
type(mesh_type)  :: a     ! exactly a mesh_type. Static. Storage known at compile time.
class(mesh_type) :: b     ! a mesh_type or anything extending it. Dynamic dispatch.
```

`type(T)` is a C++ value: `T a;`. `class(T)` is a C++ reference or pointer to a polymorphic base: `T& b;` — and calls through it are virtual. A `class(T)` entity must be a dummy argument, an `allocatable`, or a `pointer`, because its size is not known until run time.

The `self` argument of a type-bound procedure is declared `class(T)`, not `type(T)`, and this is the *only* way inheritance works: it is what allows the procedure to be invoked on an extension. A Python reader will recognise the explicit `self` immediately — Fortran and Python agree here, and C++ disagrees with both by hiding `this`.

### 6.3 Inheritance, abstract types, deferred bindings

The LFRic field hierarchy, in miniature. Its real shape is `linked_list_data_type` → `pure_abstract_field_type` → `field_parent_type` → `field_real64_type`, and the top of it exists solely so fields can be put in a container (§6.8).

```python
%%fortran
module field_hierarchy_mod
  use, intrinsic :: iso_fortran_env, only : real64
  implicit none
  private
  public :: abstract_field_type, scalar_field_type, vector_field_type

  integer, parameter, public :: r_def = real64

  !> Nothing can be an abstract_field_type; things can only extend it.
  type, abstract :: abstract_field_type
    character(:), allocatable :: name
  contains
    !> `deferred` = pure virtual. Every extension must supply one.
    procedure(l2_norm_interface), deferred :: l2_norm
    !> A non-deferred binding: inherited as-is unless overridden.
    procedure :: describe
  end type abstract_field_type

  abstract interface
    pure function l2_norm_interface(self) result(n)
      !> `import` drags the host module's names into the interface body,
      !> which otherwise sees nothing.
      import :: abstract_field_type, r_def
      class(abstract_field_type), intent(in) :: self
      real(r_def) :: n
    end function l2_norm_interface
  end interface

  type, extends(abstract_field_type) :: scalar_field_type
    real(r_def), allocatable :: data(:)
  contains
    procedure :: l2_norm => scalar_l2_norm
  end type scalar_field_type

  type, extends(abstract_field_type) :: vector_field_type
    real(r_def), allocatable :: data(:,:)
  contains
    procedure :: l2_norm => vector_l2_norm
    procedure :: describe => vector_describe      !> overrides the parent's
  end type vector_field_type

contains

  subroutine describe(self)
    class(abstract_field_type), intent(in) :: self
    ! self%l2_norm() dispatches to the actual type at run time.
    print '(A,": |f| = ",F10.6)', self%name, self%l2_norm()
  end subroutine describe

  subroutine vector_describe(self)
    class(vector_field_type), intent(in) :: self
    print '(A,": |f| = ",F10.6,"  (",I0," components)")', &
         self%name, self%l2_norm(), size(self%data, 2)
  end subroutine vector_describe

  pure function scalar_l2_norm(self) result(n)
    class(scalar_field_type), intent(in) :: self
    real(r_def) :: n
    n = sqrt(sum(self%data**2))
  end function scalar_l2_norm

  pure function vector_l2_norm(self) result(n)
    class(vector_field_type), intent(in) :: self
    real(r_def) :: n
    n = sqrt(sum(self%data**2))
  end function vector_l2_norm

end module field_hierarchy_mod
```

```python
%%fortran
use field_hierarchy_mod
type(scalar_field_type) :: rho
type(vector_field_type) :: u

rho%name = 'rho'
rho%data = [3.0_r_def, 4.0_r_def]
call rho%describe()

u%name = 'u'
allocate(u%data(2,3), source=1.0_r_def)
call u%describe()                       ! the override runs
```

`extends` is single inheritance — Fortran has no multiple inheritance and no interfaces-as-mixins. The parent is accessible as a component named after the parent type: inside `scalar_field_type`, `self%abstract_field_type%name` names the inherited component explicitly, which matters when a name is shadowed.

Three C++ correspondences, since they are almost exact: `type, abstract` is a class with a pure virtual; `procedure(iface), deferred` is `virtual f() = 0;`; `procedure :: f => g` in an extension is an override. What Fortran does *not* have is a way to make a binding non-virtual — every type-bound procedure dispatches when called through `class`.

### 6.4 Run-time type inspection: `select type`

```python
%%fortran
use field_hierarchy_mod
class(abstract_field_type), allocatable :: f
integer :: which

do which = 1, 2
  if (allocated(f)) deallocate(f)
  if (which == 1) then
    allocate(scalar_field_type :: f)
  else
    allocate(vector_field_type :: f)
  end if
  f%name = 'probe'

  select type (f)
  type is (scalar_field_type)               ! exactly this type
    f%data = [1.0_r_def, 1.0_r_def]
    print '("scalar, ",I0," values")', size(f%data)
  class is (vector_field_type)              ! this type or an extension
    allocate(f%data(2,2), source=1.0_r_def)
    print '("vector, ",I0," components")', size(f%data, 2)
  class default
    print *, 'something else'
  end select

  call f%describe()
end do
```

Inside each branch, `f` is *re-declared* with the narrower type — this is a type-safe downcast with the cast implicit in the branch, closer to Rust's `match` or a structural `isinstance` chain than to C++'s `dynamic_cast`. `type is` matches exactly; `class is` matches extensions too; the first matching branch wins with `type is` taking priority.

`allocate(scalar_field_type :: f)` is the type-spec form of allocate: allocate `f` *as* that dynamic type. The other form, `allocate(f, source=other)`, allocates and copies, taking the dynamic type from `other` — Fortran's clone.

`associate` is the non-polymorphic cousin, and worth knowing because LFRic uses it to shorten deep component chains:

```python
%%fortran
use mesh_mod, only : mesh_type
type(mesh_type) :: m
call m%initialise('C48', 13824, 30)
associate (n => m%get_ncell())
  print '("cells: ",I0,"  per panel: ",I0)', n, n/6
end associate
```

### 6.5 There are no constructors

Fortran gives every derived type a **structure constructor** with the same name as the type, taking its components positionally or by keyword:

```python
%%fortran
type :: config_type
  integer :: nlayers = 30
  real    :: dt = 300.0
  logical :: verbose = .false.
end type config_type

type(config_type) :: c1, c2

c1 = config_type(70, 60.0, .true.)
c2 = config_type(dt=1200.0, verbose=.true.)      ! keyword form; nlayers defaults
print '(2(I0,1X),2(F7.1,1X),2(L1,1X))', c1%nlayers, c2%nlayers, c1%dt, c2%dt, c1%verbose, c2%verbose
```

That is all the language gives you: no user code runs, no invariants are established, and it does not work at all once the components are `private`. The universal idiom is therefore a **generic interface with the type's name**, shadowing the structure constructor with a function:

```python
%%fortran
module timer_mod
  implicit none
  private
  public :: timer_type

  type :: timer_type
    private
    character(:), allocatable :: label
    integer :: calls = 0
  contains
    procedure, public :: tick
    procedure, public :: report
  end type timer_type

  !> Shadows the structure constructor: `timer_type('x')` now calls this.
  interface timer_type
    module procedure timer_constructor
  end interface timer_type

contains

  function timer_constructor(label) result(self)
    character(*), intent(in) :: label
    type(timer_type) :: self
    if (len_trim(label) == 0) then
      self%label = '<unnamed>'          ! an invariant the structure form cannot enforce
    else
      self%label = trim(label)
    end if
    self%calls = 0
  end function timer_constructor

  subroutine tick(self)
    class(timer_type), intent(inout) :: self
    self%calls = self%calls + 1
  end subroutine tick

  subroutine report(self)
    class(timer_type), intent(in) :: self
    print '(A,": ",I0," calls")', self%label, self%calls
  end subroutine report

end module timer_mod
```

```python
%%fortran
use timer_mod, only : timer_type
type(timer_type) :: t
t = timer_type('   ')
call t%tick(); call t%tick(); call t%tick()
call t%report()
```

LFRic uses both this idiom (`linked_list_constructor`, `operator_constructor`) and a plainer one — a type-bound `initialise`/`_initialiser` subroutine called on an already-declared object, as in `call field%initialise(fs)`. The second is more common for the big objects because it can take `optional` arguments and return status without a function's constraints. LFRic's standards fix the naming: `_constructor`, `_destructor`, `_init`, `_final`, with a further suffix for variants (`url_constructor_copy`).

### 6.6 `final`: destructors, and their limits

```python
%%fortran
module resource_mod
  implicit none
  private
  public :: resource_type

  type :: resource_type
    integer :: id = 0
    real, allocatable :: buffer(:)
  contains
    final :: resource_destructor
  end type resource_type

contains

  subroutine resource_destructor(self)
    !> A finaliser takes `type`, never `class`, and is never called explicitly.
    type(resource_type), intent(inout) :: self
    print '("finalising resource ",I0)', self%id
  end subroutine resource_destructor

end module resource_mod
```

```python
%%fortran
use resource_mod, only : resource_type
call scope()
print *, 'back in the main program'
contains
  subroutine scope()
    type(resource_type) :: r
    r%id = 7
    allocate(r%buffer(10))
    print *, 'inside scope'
  end subroutine scope
```

Finalisers run when an object goes out of scope, is deallocated, or is overwritten by intrinsic assignment. They are *not* RAII: the standard leaves gaps (notably for objects that are still allocated when the program stops), compiler support has historically been patchy, and there is no guaranteed ordering between finalisers of components. LFRic's `linked_list_type` has one, but the codebase leans on explicit `deallocate` far more than on `final`.

### 6.7 Operator overloading

```python
%%fortran
module vec2_mod
  implicit none
  private
  public :: vec2_type, operator(+), operator(*), assignment(=), operator(.dot.)

  type :: vec2_type
    real :: x = 0.0, y = 0.0
  end type vec2_type

  interface operator(+)
    module procedure vec2_add
  end interface

  interface operator(*)
    module procedure vec2_scale
  end interface

  interface operator(.dot.)          !> a user-defined operator, name in dots
    module procedure vec2_dot
  end interface

  interface assignment(=)
    module procedure vec2_from_scalar
  end interface

contains

  pure function vec2_add(a, b) result(c)
    type(vec2_type), intent(in) :: a, b
    type(vec2_type) :: c
    c = vec2_type(a%x + b%x, a%y + b%y)
  end function vec2_add

  pure function vec2_scale(s, a) result(c)
    real, intent(in) :: s
    type(vec2_type), intent(in) :: a
    type(vec2_type) :: c
    c = vec2_type(s*a%x, s*a%y)
  end function vec2_scale

  pure function vec2_dot(a, b) result(d)
    type(vec2_type), intent(in) :: a, b
    real :: d
    d = a%x*b%x + a%y*b%y
  end function vec2_dot

  pure subroutine vec2_from_scalar(a, s)
    type(vec2_type), intent(out) :: a
    real, intent(in) :: s
    a = vec2_type(s, s)
  end subroutine vec2_from_scalar

end module vec2_mod
```

```python
%%fortran
use vec2_mod
type(vec2_type) :: a, b, c
a = vec2_type(1.0, 2.0)
b = vec2_type(3.0, 4.0)
c = a + 2.0*b
print '(2(F6.2))', c%x, c%y
print '("dot = ",F6.2)', a .dot. b
c = 5.0                        ! the overloaded assignment
print '(2(F6.2))', c%x, c%y
```

Alternatively, and more commonly in modern code, bind the operator inside the type with `generic :: operator(+) => add`, which keeps the association with the type rather than the module. Note that overloading `=` for a derived type is legal but rarely wise: it displaces the intrinsic component-wise copy, and every reader now has to check.

### 6.8 Unlimited polymorphism, and the container problem

Fortran's `class(*)` is `void*` with a run-time type tag — Python's `Any`, or C++'s `std::any`.

```python
%%fortran
module box_mod
  implicit none
contains
  subroutine show(item)
    class(*), intent(in) :: item
    select type (item)
    type is (integer)
      print '("integer: ",I0)', item
    type is (real)
      print '("real:    ",F6.2)', item
    type is (character(*))
      print '("string:  ",A)', item
    class default
      print '("something else")'
    end select
  end subroutine show
end module box_mod
```

```python
%%fortran
use box_mod, only : show
call show(42)
call show(3.14)
call show('W2broken')
```

It works, and LFRic does not use it for containers. Its generic `linked_list_type` instead holds a `class(linked_list_data_type), pointer` — a common *abstract base* that everything storable must extend:

```fortran
type, abstract, public :: linked_list_data_type
  private
  integer(i_def) :: id
contains
  procedure, public :: get_id
  procedure, public :: set_id
end type linked_list_data_type
```

This is Java's `Object`, or a Rust trait object, rather than `void*`. The trade is deliberate: `class(*)` would accept anything and force a `select type` at every retrieval, whereas a common base guarantees the container can at least ask for an `id`, which is what `get_item(id)` needs. It is also why `pure_abstract_field_type` exists and is empty — its whole job is to sit between `linked_list_data_type` and the field hierarchy so that fields are storable.

### 6.9 Submodules: breaking the recompilation avalanche

Recall that `use` reads a `.mod` file emitted from the module's source. Change *anything* in a module — including a comment inside a procedure body — and the `.mod` may change, and everything downstream recompiles. For a module used by three hundred files this dominates the build.

`submodule` (Fortran 2008) splits the module into an interface and one or more implementations. Only the interface produces the `.mod` that others read; changing a submodule's body recompiles the submodule alone.

```python
%%fortran
module solver_mod
  implicit none
  private
  public :: solve

  interface
    !> Declared here, defined elsewhere. This is the whole public interface.
    module subroutine solve(x, iterations)
      real, intent(inout) :: x
      integer, intent(in) :: iterations
    end subroutine solve
  end interface

end module solver_mod
```

```python
%%fortran
submodule (solver_mod) solver_impl
contains
  !> `module subroutine`, matching the interface. No repetition of the
  !> argument declarations is required, though it is permitted.
  module subroutine solve(x, iterations)
    real, intent(inout) :: x
    integer, intent(in) :: iterations
    integer :: i
    do i = 1, iterations
      x = 0.5*(x + 2.0/x)          ! Newton on x^2 = 2
    end do
  end subroutine solve
end submodule solver_impl
```

```python
%%fortran
use solver_mod, only : solve
real :: x
x = 1.0
call solve(x, 5)
print '("sqrt(2) ~ ",F12.9)', x
```

The C++ reader's picture is the header/implementation split — but with the interface *checked* against the implementation by the compiler rather than by convention, and with no textual inclusion. Submodules also solve the circular-dependency problem: two modules whose implementations need each other can each `use` the other's interface.

### 6.10 What LFRic does instead of generics

Two strategies, both visible in the source tree.

**Generic interfaces per kind**, as in §5.4: write the body twice, once for `r_single` and once for `r_double`, and hide both behind one name. Cheap, ugly, and used for kernels.

**Templates expanded at build time.** `infrastructure/source/field/field_mod.t90` is not Fortran; it is Fortran with holes:

```fortran
module field_{{kind}}_mod
  use, intrinsic :: iso_fortran_env, only : {{kind}}
  use constants_mod, only: i_def, l_def, str_def, {{type}}_type, ...
  type, extends(field_parent_type), public :: field_{{kind}}_type
    {{type}}({{kind}}), allocatable :: data( : )
    ...
```

The build system instantiates it once per `(type, kind)` pair, producing `field_real32_mod.f90`, `field_real64_mod.f90`, `integer_field_mod.F90` and so on, and then `field_mod.F90` renames the chosen one:

```fortran
#if (RDEF_PRECISION == 32)
  use field_real32_mod, only: field_type => field_real32_type, ...
#else
  use field_real64_mod, only: field_type => field_real64_type, ...
#endif
```

So `field_type` — the name you see everywhere in LFRic algorithm code — is a preprocessor alias for a generated monomorphisation of a template. That is C++'s model with the instantiation moved from the compiler to the build system, and Julia's parametric types with the specialisation moved from run time to build time. Knowing this saves confusion the first time you grep for `field_type` and cannot find its definition.

The `use ..., only : new_name => old_name` rename syntax is worth noting in its own right; it is common in LFRic wherever two modules would otherwise collide, and there is no Python equivalent to importing *and* renaming under a restriction list in one statement.

---

## 7. Allocatable versus pointer

Fortran has two kinds of indirection and they are not interchangeable. Choosing wrongly is the commonest source of memory bugs in modern Fortran.

```python
%%fortran
real, allocatable, target :: owner(:)
real, pointer             :: view(:)

allocate(owner(5))
owner = [1.0, 2.0, 3.0, 4.0, 5.0]

view => owner(2:4)                ! aliases; no copy; carries its own bounds
print '("view    ",3(F5.1))', view
view = -1.0                       ! writes through into `owner`
print '("owner   ",5(F5.1))', owner
print '("assoc?  ",L1,"  bounds ",I0,":",I0)', associated(view), lbound(view,1), ubound(view,1)

nullify(view)
print '("assoc?  ",L1)', associated(view)
```

| | `allocatable` | `pointer` |
|---|---|---|
| owns its memory | yes | no |
| freed on scope exit | yes, automatically | no — leaks silently |
| assignment `a = b` | deep copy of the values | copies values into the target |
| association `a => b` | not allowed | aliases `b` |
| can alias a strided slice | no | yes |
| can be undefined | no (`allocated()` is definite) | yes (`associated()` may be garbage) |
| optimiser assumes no aliasing | yes | no |

`allocatable` is `std::unique_ptr`/`std::vector`: owning, scope-bound, and the compiler knows nothing else points at it. `pointer` is a raw alias — but a *smart* one, because a Fortran pointer to an array carries a full descriptor and can therefore point at `a(1:n:2)` and stride correctly. That makes it much closer to a NumPy view than to a C pointer.

**Default to `allocatable`.** Reach for `pointer` only when you genuinely need aliasing (LFRic's `type(mesh_type), pointer :: mesh => null()` inside a field is a non-owning back-reference), a linked structure, or optional-argument-like "may or may not be present" semantics on a component.

The LFRic rules follow directly: nullify pointers early because an unassociated pointer's `associated()` result is undefined until it is nullified or assigned; never initialise a procedure-local pointer at its declaration (§3.2); and every `allocate` gets a matching `deallocate`.

### 7.1 Automatic reallocation on assignment

Fortran 2003 changed the meaning of `a = expr` when `a` is allocatable: if `a` is unallocated, or allocated to the wrong shape, it is (re)allocated to fit.

```python
%%fortran
real, allocatable :: a(:)
a = [1.0, 2.0, 3.0]              ! allocated to 3 by the assignment
print '(I0,": ",3(F5.1))', size(a), a
a = [1.0, 2.0, 3.0, 4.0, 5.0]    ! silently reallocated to 5
print '(I0,": ",5(F5.1))', size(a), a
```

Convenient, and a performance trap in a hot loop: every assignment must *check* the shape, and may free and allocate. In a kernel that runs once per column per timestep, that check is not free. gfortran's `-fno-realloc-lhs` turns the feature off (restoring Fortran 95 semantics, where the shapes must already match); several HPC codes build with it. Know that the flag exists, because code compiled with it behaves differently from the standard.

`move_alloc` transfers ownership without copying — a move, in C++ terms:

```python
%%fortran
real, allocatable :: from(:), to(:)
allocate(from(3), source=7.0)
call move_alloc(from, to)         ! `to` takes the allocation; `from` becomes unallocated
print '("to allocated: ",L1,"  from allocated: ",L1,"  to(1) = ",F5.1)', &
     allocated(to), allocated(from), to(1)
```

---

## 8. Input, output, and the command line

### 8.1 `write` and format strings

```python
%%fortran
real    :: x = 3.14159265
integer :: n = 42
character(8) :: label = 'exner'

print *, 'list-directed: ', n, x            ! compiler chooses the layout
write(*, '(A,I0,2X,F8.4)') 'formatted:     ', n, x
write(*, '(A,": ",ES12.5," / ",EN12.4)') trim(label), x, x*1.0e6
write(*, '("repeat: ",3(I3,1X))') n, n+1, n+2
write(*, '("logical ",L1,"  hex ",Z8.8)') .true., n
```

The format mini-language, in the amount you need to read LFRic:

| edit descriptor | meaning |
|---|---|
| `A`, `A10` | character, natural width or exactly 10 |
| `I5`, `I0` | integer in 5 columns; `I0` is minimum width |
| `F8.3` | fixed point, 8 columns, 3 decimals |
| `ES12.5` | scientific, one digit before the point (`1.23456E+03`) |
| `EN12.4` | engineering, exponent a multiple of 3 |
| `L1` | logical, `T` or `F` |
| `Z8.8` | hexadecimal |
| `3(...)` | repeat the group three times |
| `2X`, `/` | two spaces; newline |
| `*` (as the whole format) | list-directed: let the compiler decide |

`print *, x` is list-directed output. It is what every example in this note uses and what LFRic forbids: science code must go through the **logger** (`log_event(message, LOG_LEVEL_INFO)` from `log_mod`), so that output is rank-aware, level-filtered, and does not interleave across MPI processes.

### 8.2 Files, units, and `iostat`

```python
%%fortran
integer :: u, ios
character(64) :: line

open(newunit=u, file='scratch.txt', status='replace', action='write')
write(u, '(A)') 'C24'
write(u, '(A)') '30 layers'
close(u)

open(newunit=u, file='scratch.txt', status='old', action='read')
do
  read(u, '(A)', iostat=ios) line
  if (ios /= 0) exit                    ! non-zero on end-of-file or error
  print '("read: ",A)', trim(line)
end do
close(u)
```

`newunit=` (Fortran 2008) asks the runtime for a free unit number instead of the old practice of picking one and hoping. `iostat=` returns a status instead of aborting; without it, an end-of-file *stops the program*. The three predefined units — 5, 6, 0 — have portable names in `iso_fortran_env`: `input_unit`, `output_unit`, `error_unit`.

### 8.3 Namelists, which are how LFRic is configured

A `namelist` is a declared group of variables with a matching text format. It is the closest thing Fortran has to a config file parser, it is in the standard, and every LFRic run is driven by one.

```python
%%fortran_file configuration.nml
&finite_element
  element_order_h = 1
  element_order_v = 1
  coord_order     = 2
/
&timestepping
  dt          = 300.0
  timestep_end = 'PT6H'
/
```

```python
%%fortran
integer :: element_order_h, element_order_v, coord_order
real    :: dt
character(16) :: timestep_end
integer :: u, ios

namelist /finite_element/ element_order_h, element_order_v, coord_order
namelist /timestepping/   dt, timestep_end

open(newunit=u, file='configuration.nml', status='old', action='read')
read(u, nml=finite_element, iostat=ios)
rewind(u)
read(u, nml=timestepping, iostat=ios)
close(u)

print '("element order (h,v): ",2(I0,1X))', element_order_h, element_order_v
print '("dt = ",F6.1,"  end = ",A)', dt, trim(timestep_end)
```

Note what this costs you: the variable names in the file are the variable names in the source, so the config schema *is* a set of declarations. LFRic layers `rose-meta` metadata on top to get validation, defaults, upgrade macros between versions and a GUI, and generates the reader modules with a `configurator` tool rather than writing `namelist` statements by hand. But the bottom layer is this.

### 8.4 The command line needs no C

The belief that Fortran cannot parse a command line without an FFI shim is common, and was true — until Fortran 2003. Since then `command_argument_count`, `get_command_argument` and `get_environment_variable` are intrinsic.

```python
%%fortran --args "--levels 30 --verbose C24.nml"
integer :: i, n, length, status
character(:), allocatable :: arg
character(0) :: probe

n = command_argument_count()
print '("argc = ",I0)', n
do i = 1, n
  ! The two-call dance: ask for the length with a zero-length buffer,
  ! allocate to fit, ask again. `get_command_argument` fills a fixed-length
  ! buffer, so there is no other way to receive an argument of unknown size.
  call get_command_argument(i, probe, length, status)
  allocate(character(length) :: arg)
  call get_command_argument(i, arg, length, status)
  print '("  argv[",I0,"] = ",A)', i, arg
  deallocate(arg)
end do
```

That is the whole mechanism. There is no `argparse` in the standard library — there is no standard library — so a project either writes fifty lines or takes a dependency.[^cliargs] LFRic writes fifty lines: [`cli_mod.f90`](https://github.com/MetOffice/lfric_core/blob/main/infrastructure/source/utilities/cli_mod.f90) does exactly the dance above, handles `-h`/`--help`, and expects one positional argument (the master namelist). Its deliberate minimalism is a design position: an LFRic executable is launched by Rose/Cylc, and configuration belongs in namelists, not in flags.

A slightly friendlier parser is in [`demo/cli_args_mod.f90`](https://github.com/ickc/project-LFRic/blob/main/src/fortran/demo/cli_args_mod.f90) here, with `--key value`, `--key=value`, bare flags and positionals, in about 150 lines including comments.

[^cliargs]: If you want one off the shelf: `FLAP`, `f90getopt`, or `fpm`'s own argument handling. None is a de facto standard, which is itself informative about the ecosystem — Fortran has no PyPI, and `fpm` (2020) is the first credible package manager.

### 8.5 Calling C, properly

When you do need C — and LFRic does, for XIOS, NetCDF and YAXT — the standard way is `iso_c_binding`, and LFRic's coding standards require it exclusively.

```python
%%fortran
use, intrinsic :: iso_c_binding, only : c_double, c_int, c_char, c_null_char

interface
  !> Bind to C's strlen. `bind(c)` fixes the symbol name and the calling
  !> convention; `value` makes an argument pass by value, which is C's default
  !> and Fortran's exception.
  function c_strlen(s) bind(c, name='strlen') result(n)
    import :: c_char, c_int
    character(kind=c_char), intent(in) :: s(*)
    integer(c_int) :: n
  end function c_strlen
end interface

real(c_double)  :: x
integer(c_int)  :: n

x = 2.0_c_double
n = c_strlen('cubed sphere' // c_null_char)
print '("c_double is ",I0," bytes; strlen = ",I0)', storage_size(x)/8, n
```

The pieces: `c_double`, `c_int`, `c_ptr`, `c_funptr` are kind parameters guaranteed to match the C types; `bind(c, name=...)` controls the linker symbol (and stops the compiler appending an underscore); `value` requests pass-by-value; `c_null_char` terminates strings; `c_f_pointer` turns a `c_ptr` plus a shape into a Fortran array pointer. Going the other way, a Fortran procedure marked `bind(c)` is callable from C, which is how `pybind11`- and `ctypes`-style wrappers reach Fortran.

---

## 9. Parallelism, as you will meet it in LFRic

Here is the thing to internalise before reading any LFRic kernel: **the science code contains no parallelism at all**. No MPI, no OpenMP, no directives, no rank checks, no barriers. All of it lives in the generated PSy layer and in the infrastructure. What follows is therefore less "how to write parallel Fortran" and more "what these constructs are, when you meet them in generated or infrastructure code".

### 9.1 `do concurrent`

```python
%%fortran --flags "-O2"
integer, parameter :: n = 8
real :: a(n), b(n)
integer :: i

b = [(real(i), i = 1, n)]

! An assertion, not a directive: the iterations have no dependencies and may
! be executed in any order, or simultaneously. The compiler may or may not
! act on it; with -fopenmp or -ftree-parallelize-loops it can.
do concurrent (i = 1:n)
  a(i) = sqrt(b(i))
end do

print '(8(F6.3,1X))', a
```

`do concurrent` (Fortran 2008, much extended in 2018 and 2023) is a *promise about semantics*, not a request for threads. Everything it calls must be `pure`; there must be no cross-iteration dependency; branching out of the block is forbidden. That is why §4.7's `pure` matters, and it is the same contract as `jax.vmap`: declare independence, and let the implementation choose the mapping. NVIDIA's `nvfortran` compiles `do concurrent` straight to GPU kernels, which is why it is the current favourite for portable acceleration.

### 9.2 OpenMP

```python
%%fortran --openmp --flags "-O2"
use omp_lib, only : omp_get_max_threads
integer, parameter :: n = 1000000
real(kind(1.0d0)) :: total
integer :: i

total = 0.0d0
!$omp parallel do default(shared), private(i), reduction(+:total), schedule(static)
do i = 1, n
  total = total + 1.0d0/real(i, kind(1.0d0))**2
end do
!$omp end parallel do

print '("threads      : ",I0)', omp_get_max_threads()
print '("sum 1/i^2    : ",F12.9)', total
print '("pi^2/6       : ",F12.9)', acos(-1.0d0)**2/6.0d0
```

Directives are *comments* beginning `!$omp`, invisible without `-fopenmp` — the same trick as C's `#pragma`, and the reason a serial build of an OpenMP code is always available. Conditional compilation of ordinary statements uses the `!$` sentinel, which becomes two blanks when OpenMP is on.

### 9.3 MPI, and the halo

LFRic decomposes the horizontal mesh across MPI ranks and surrounds each partition with **halo** cells — copies of the neighbours' edge data, refreshed by a halo exchange before any kernel that reads across a cell boundary. Fields track a `halo_dirty` flag per depth so exchanges can be skipped when nothing has changed, and PSyclone inserts the exchanges by reading kernel metadata.

Modern MPI from Fortran is `use mpi_f08`, which gives real derived types (`type(MPI_Comm)`) instead of bare integers and therefore actual type checking; LFRic wraps it further in `lfric_mpi_mod` so that the model never calls MPI directly. Coarrays — Fortran's own PGAS parallelism, where `a(i)[j]` reads element `i` from image `j` — are in the standard, are elegant, and are not used by LFRic; implementations are uneven and MPI is what the ecosystem is built on.

### 9.4 The bridge: PSyclone is a tracing JIT

This is the framing that makes the whole architecture click if you know JAX.

| JAX | LFRic |
|---|---|
| a pure Python function of arrays | a **kernel**: pure, one cell column, intrinsic types only |
| the traced program you write | the **algorithm layer** (`.x90`): whole fields, no indices |
| `jax.jit` tracing the call | **PSyclone** reading `invoke` plus kernel metadata |
| the jaxpr | the generated **PSy layer** (`.f90`) |
| `vmap` adding a batch axis | the generated loop over cells |
| `pmap`/sharding | the domain decomposition and halo exchanges |
| XLA fusion | PSyclone's loop fusion and redundant-computation elision |
| donated buffers | `GH_INC`/`GH_READWRITE` access metadata |
| `jax.ShapeDtypeStruct` | `arg_type(GH_FIELD, GH_REAL, GH_INC, W3)` |
| an optimisation script for XLA flags | the per-site `optimisation/*/psykal/global.py` scripts |

Both systems make the same bet: forbid the science code from expressing *how*, force it to declare *what*, and let a compiler that understands the target choose the how. The difference is that JAX traces at run time in the host language, whereas PSyclone rewrites source ahead of time — which is why LFRic's `invoke` can be a call to a subroutine that does not exist yet.

The colouring story in [`demo/mini_psy_mod.f90`](https://github.com/ickc/project-LFRic/blob/main/src/fortran/demo/mini_psy_mod.f90) is worth reading for the same reason: `GH_INC` means neighbouring cells increment a shared degree of freedom, so a plain `!$omp parallel do` over cells is a data race. PSyclone's fix is to colour the mesh — partition cells so that no two of the same colour share a dof — and run one colour at a time. That is chromatic Gibbs sampling, with the conditional-independence graph replaced by the dof-sharing graph.

---

## 10. Reading LFRic

Everything above, applied.

### 10.1 The file extensions carry meaning

| extension | what it is | who processes it |
|---|---|---|
| `.f90` | plain Fortran source | the compiler |
| `.F90` | source needing the C preprocessor | `cpp`, then the compiler |
| `.x90`, `.X90` | **algorithm layer**: contains `call invoke(...)` | PSyclone, which emits `.f90` |
| `.t90` | a **template** with `{{kind}}` holes | the build system, which emits `.f90` |
| `.pf` | a **pFUnit** unit test with `@test` annotations | the pFUnit preprocessor |

If you grep for a symbol and cannot find its definition, it is almost certainly generated: from a `.t90`, by PSyclone, or by the `configurator` that turns `rose-meta` into namelist readers.

### 10.2 Anatomy of a kernel

Here is the real thing, trimmed — `lfric_core/components/science/source/kernel/algebra/matrix_vector_kernel_mod.F90`:

```fortran
module matrix_vector_kernel_mod
  use argument_mod,  only : arg_type,                 &
                            GH_FIELD, GH_OPERATOR,    &
                            GH_REAL, GH_READ, GH_INC, &
                            ANY_SPACE_1, ANY_SPACE_2, &
                            CELL_COLUMN
  use constants_mod, only : i_def, r_single, r_double
  use kernel_mod,    only : kernel_type

  implicit none
  private

  type, public, extends(kernel_type) :: matrix_vector_kernel_type
    private
    type(arg_type) :: meta_args(3) = (/                                    &
         arg_type(GH_FIELD,    GH_REAL, GH_INC,  ANY_SPACE_1),             &
         arg_type(GH_FIELD,    GH_REAL, GH_READ, ANY_SPACE_2),             &
         arg_type(GH_OPERATOR, GH_REAL, GH_READ, ANY_SPACE_1, ANY_SPACE_2) &
         /)
    integer :: operates_on = CELL_COLUMN
  end type

  public :: matrix_vector_code

  interface matrix_vector_code
    module procedure matrix_vector_code_r_single, &
                     matrix_vector_code_r_double
  end interface

contains
  subroutine matrix_vector_code_r_double(cell, nlayers, lhs, x, ncell_3d, &
                                         matrix, ndf1, undf1, map1,       &
                                         ndf2, undf2, map2)
    integer(kind=i_def),                  intent(in) :: cell, nlayers, ncell_3d
    integer(kind=i_def), dimension(ndf1), intent(in) :: map1
    real(kind=r_double), dimension(undf1),              intent(inout) :: lhs
    real(kind=r_double), dimension(undf2),              intent(in)    :: x
    real(kind=r_double), dimension(ncell_3d,ndf1,ndf2), intent(in)    :: matrix
    integer(kind=i_def) :: df, ik, df2, i1, i2, nl

    nl = nlayers-1
    ik = (cell-1)*nlayers + 1
    do df2 = 1, ndf2
      i2 = map2(df2)
      do df = 1, ndf1
        i1 = map1(df)
        lhs(i1:i1+nl) = lhs(i1:i1+nl) + matrix(ik:ik+nl,df,df2)*x(i2:i2+nl)
      end do
    end do
  end subroutine matrix_vector_code_r_double
  ...
end module matrix_vector_kernel_mod
```

Read it in this order.

**The derived type is metadata, not data.** `matrix_vector_kernel_type` is never instantiated and its components are never read at run time. It is a statement, written in compilable Fortran, of what the kernel does to each argument: increment a field on some space, read a field on another, read an operator between the two, and operate on one cell column. PSyclone parses it out of the source. The enumerator values are deliberately arbitrary (`GH_FIELD = 507`) to make clear that nothing depends on them numerically. This is a DSL hosted in the type system — the same manoeuvre as a Python decorator that a code generator reads, or `jax.ShapeDtypeStruct`.

**Extending `kernel_type` is a marker.** `kernel_type` is an empty abstract type. Extending it carries no behaviour; it is how PSyclone recognises that this derived type is kernel metadata.

**The `_code` subroutine is the science, and it is deliberately impoverished.** Only intrinsic types cross the boundary — no derived types, no fields, no objects. Every array is explicit shape with its extents passed alongside (§4.8). There is no `use` of model state, no allocation, no I/O, no `stop`, no logging, no branching worth the name. Each restriction is there so the body can be inlined, offloaded to a GPU, or run on any thread. They are enforced by review, not by the compiler.

**`intent(inout)` on the output, not `intent(out)`.** Because the kernel is called once per cell and touches only the dofs in `map1`.

**The vertical slice is the vectorisable dimension.** `lhs(i1:i1+nl)` operates on a whole column at once, contiguously, for each horizontal dof. The indirection through `map1` happens once per column, not once per point — the payoff for the layout decision in §4.2.

### 10.3 Anatomy of an algorithm

`lfric_core/applications/skeleton/source/algorithm/skeleton_alg_mod.x90`, trimmed:

```fortran
subroutine skeleton_alg(modeldb, field_1)
  type(modeldb_type), intent(in)    :: modeldb
  type(field_type),   intent(inout) :: field_1
  type(field_type)                  :: field_2
  type(mesh_type),           pointer :: mesh
  type(operator_type),       pointer :: divergence
  type(function_space_type), pointer :: fs
  real(r_def)    :: s
  integer(i_def) :: order_h, order_v

  call log_event( "skeleton: Running algorithm", log_level_info )

  order_h = modeldb%config%finite_element%element_order_h()
  mesh       => field_1%get_mesh()
  divergence => get_div(mesh)
  fs => function_space_collection%get_fs(mesh, order_h, order_v, W2)
  call field_2%initialise(fs)

  s = 2.0_r_def
  call invoke( name = "compute_divergence",  &
               setval_c(field_2, s        ), &
               setval_c(field_1, 0.0_r_def), &
               matrix_vector_kernel_type(field_1, field_2, divergence) )

  call log_field_minmax( LOG_LEVEL_INFO, 'field_1', field_1 )
end subroutine skeleton_alg
```

What is *absent* is the content: no loop over cells, no dofmap, no index, no `!$omp`, no halo exchange, no rank. Whole fields go in and out.

`call invoke(...)` is a call to a procedure that does not exist. PSyclone reads this file, matches each argument against the corresponding kernel's metadata, and writes both a `skeleton_alg_mod.f90` in which `invoke` has become `call invoke_compute_divergence(...)` and a PSy module containing that subroutine. `setval_c` is a **built-in** — a kernel PSyclone knows how to write itself.

Two coding standards visible here, both with real consequences. Kernels are grouped into *one* `invoke`, because PSyclone can only fuse loops and elide halo exchanges within a single invoke — it cannot see across two. And fields passed to an invoke must be declared locally, never fetched inline from a module or a function call, because PSyclone needs to find the declaration to know the type.

Everything the algorithm holds is a `pointer`: `mesh`, `divergence`, `fs`. These are non-owning references into collections that own the objects (`function_space_collection` is a module-level singleton keyed by mesh and order). That is §7's rule applied: the collection is `allocatable` and owns, the algorithm is a `pointer` and borrows.

### 10.4 The proxy pattern

`field_type` has private data; the PSy layer needs raw arrays. The bridge is a second type:

```fortran
type, extends(field_parent_proxy_type), public :: field_real64_proxy_type
  private
  real(real64), public, pointer :: data( : ) => null()
  ...
end type

type(field_real64_proxy_type) function get_proxy(self)
  class(field_real64_type), target, intent(in) :: self
  get_proxy%data => self%data
end function get_proxy
```

Every generated PSy routine begins by calling `get_proxy` on each field, then works through the proxy. So the encapsulation hole is real, deliberate, and punched in exactly one named place — and note that it hands out a writable pointer to the components of an `intent(in)` argument, which is legal outside a `pure` procedure and is the point. A C++ reader should think `friend` accessor; a Python reader, `__array_interface__`.

### 10.5 A working miniature

[`demo/`](https://github.com/ickc/project-LFRic/tree/main/src/fortran/demo) has the whole stack at a scale that fits on a screen: algorithm over PSy over kernel, on a field/proxy pair, with a function space and a dofmap. The problem is applying a one-dimensional continuous piecewise-linear mass matrix cell by cell; the driver checks the assembled result against a dense `matmul`, and runs the threaded, colour-partitioned PSy routine as well as the serial one.

```python
import subprocess

def run(*argv):
    print(subprocess.run(argv, capture_output=True, text=True).stdout)

# From scratch, so the build order fortdep.py works out is visible: every
# module before anything that `use`s it, and the two programs last.
run("make", "-C", "demo", "--no-print-directory", "clean")
run("make", "-C", "demo", "--no-print-directory")
run("./demo/build/psykal_demo")
```

```python
run("./demo/build/cli_demo", "--levels=70", "-v", "mesh_C48.nc")
```

### 10.6 The standards, distilled

What a reviewer will actually pull you up on, from [`fortran_coding_standards.rst`](https://github.com/MetOffice/lfric_core/blob/main/documentation/source/how_to_contribute/coding_standards/fortran_coding_standards.rst):

- `implicit none` in every module *and* every procedure inside it.
- `use` always with `only:`, listing only what is used.
- One module per file; the file name is the module name; `_mod` and `_type` suffixes.
- `private` by default in modules and in type bodies; an explicit `public ::` list.
- A `kind` on every real variable, every real literal (`1.23_r_def`), and every literal argument whose dummy has a kind. Never `real(1.23, r_def)`.
- Doxygen `@brief` on every program unit, `@param[in]`/`@param[out]` on every argument.
- Lower case for all code; underscores between words; British spellings (`initialise`, and `halos` not `haloes`).
- Lines within 80 characters; no trailing whitespace, comments included.
- Every `allocate` matched by a `deallocate`; pointers nullified early; never initialise a procedure-local pointer at its declaration.
- `character(*)` for character dummies with `intent(in)`/`intent(inout)`; `trim` when passing.
- No module-level variables or objects — they prevent two concurrent configurations of the same module.
- No `write`/`print` in science code; use `log_event`.
- In kernels: no `use` of other modules, no logging, no `stop`, no complex control flow, `intent(inout)` for outputs, everything through the argument list.
- Copyright header on every new file.

The linter, [`fortitude`](https://github.com/PlasmaFAIR/fortitude), is configured in `fortitude.toml` at the root of both repositories and checks a subset of these mechanically. Run it before you push.

---

## 11. Tooling

**Compiler flags worth having in muscle memory.** For gfortran:

```text
-Wall -Wextra                 # and mean it; Fortran's warnings are good
-std=f2018                    # reject extensions; catches accidental legacy
-fimplicit-none               # belt and braces over `implicit none`
-fcheck=all -fbacktrace -g    # bounds, pointers, array temporaries, with a traceback
-ffpe-trap=invalid,zero,overflow   # stop at the first NaN rather than at the output
-J<dir> -I<dir>               # where .mod files are written / found
-cpp                          # force preprocessing regardless of extension
-fno-realloc-lhs              # Fortran 95 assignment semantics (see §7.1)
```

The debug set costs a factor of a few and finds nearly everything. LFRic's build has `fast-debug` and `full-debug` profiles for exactly this. For `nvfortran`, the corresponding flags are `-Minfo=all -Mbounds -traceback`, and `-stdpar=gpu` is what turns `do concurrent` into device code.

**Linting and formatting.** `fortitude` is the linter LFRic uses (Rust, Ruff-shaped, configured in `fortitude.toml`). `fprettify` and `findent` reformat. `flint` and `i-Code CNES` exist and are heavier.

**Build systems.** `fpm`, the Fortran Package Manager, is the right choice for anything personal — a `fpm.toml` and a `src/` directory, and dependency scanning is automatic. LFRic uses [fab](https://github.com/MetOffice/fab), a Python build system written by the Met Office for exactly this (its predecessor `fcm-make` is still in places), with Spack managing the external stack on Isambard3. The `Makefile` in [`demo/`](https://github.com/ickc/project-LFRic/tree/main/src/fortran/demo) here is a third option for scratch work: drop a `.f90` in and it works out the build order.

**Debugging.** `gdb` handles gfortran binaries with array printing (`p arr(1:10)`), though descriptors of assumed-shape arrays can confuse it. `valgrind` works. For floating-point archaeology, `-ffpe-trap` plus a backtrace beats print statements.

**LLM-assisted reading.** Since reading is the job here: the two things a model will get wrong on LFRic are (i) that `invoke` is a real procedure — it is not, it is rewritten by PSyclone, so asking "where is `invoke` defined" produces confident nonsense; and (ii) that a symbol it cannot find must be missing, when in fact it is generated from a `.t90` or by the configurator. Both are worth stating in the prompt.

---

## 12. Exercises

No answers here on purpose. Most can be checked by pasting into a cell.

**Reading.**

1. In `matrix_vector_code`, what would go wrong if `lhs` were declared `intent(out)`? Describe the failure concretely, in terms of which values end up wrong. Then say why the compiler cannot catch it.

2. `field_parent_type` declares `integer(kind=i_def), allocatable :: halo_dirty(:)`. Why an array rather than a scalar flag, and why `allocatable` rather than a fixed size?

3. Given `type, extends(field_parent_type), public :: field_real64_type`, what is the type of `self` in a procedure bound to `field_real64_type`, and why is it not `type(field_real64_type)`?

4. In `skeleton_alg_mod.x90`, `mesh`, `divergence` and `fs` are `pointer`s but `field_2` is not. State the ownership rule that explains the difference.

5. LFRic's standards forbid module-level variables. Give a scenario, involving two nested model configurations in one executable, in which a module-level variable produces a wrong answer rather than a crash.

**Spot the bug.** Each of these compiles. Say what is wrong and what it does at run time.

```fortran
subroutine accumulate(x, total)
  real, intent(in)  :: x(:)
  real, intent(out) :: total
  integer :: i
  do i = 1, size(x)
    total = total + x(i)
  end do
end subroutine accumulate
```

```fortran
subroutine setup(config)
  type(config_type), intent(inout) :: config
  type(mesh_type), pointer :: mesh => null()
  mesh => config%get_mesh()
  call mesh%partition()
end subroutine setup
```

```fortran
real(r_def) function pressure(theta, rho)
  real(r_def), intent(in) :: theta, rho
  pressure = (rho*theta*287.05/100000.0)**(1.0/(1.0 - 0.2857))
end function pressure
```

```fortran
character(8) :: space_name
space_name = 'W2broken'
if (space_name == 'W2broken   ') then
  call log_event('matched', LOG_LEVEL_INFO)
end if
```

```fortran
do cell = 1, ncell
  !$omp parallel do private(df)
  do df = 1, ndf
    lhs(map(df, cell)) = lhs(map(df, cell)) + rhs(df)
  end do
  !$omp end parallel do
end do
```

**Writing.**

6. Write an `elemental` function `theta_to_temperature(theta, exner)` returning `theta*exner`, with a kind parameter, and demonstrate it on a rank-2 array in one cell.

7. Extend `demo/mini_matvec_kernel_mod.f90` with a second kernel `mini_axpy_kernel_mod` computing `y = a*x + y` over a whole field (`operates_on = DOF` rather than `CELL_COLUMN` — think about what that changes in the PSy layer), and add the corresponding hand-written invoke. Check it against NumPy.

8. Take `demo/mini_psy_mod.f90` and deliberately break the colouring — parallelise the raw cell loop instead. Run it a few hundred times at `ncell = 10000` and report how often the answer is wrong. Then explain why the failure rate is what it is rather than 100%.

9. Write a module `stats_mod` exposing a generic `mean` over `real32`, `real64`, rank 1 and rank 2 — four specific procedures behind one name. Then say what stops you from adding a fifth for `integer` arrays returning `real64`.

10. Convert `demo/cli_args_mod.f90`'s `option_value` from returning `character(:), allocatable` to a subroutine with an `intent(out)` allocatable argument. Which is better here, and why might a kernel-adjacent code base prefer the subroutine form?

---

## 13. Summary

### Fortran through Python-shaped eyes

| you know | Fortran | note |
|---|---|---|
| `import numpy as np` | `use constants_mod, only : r_def` | `only:` is mandatory in LFRic |
| `from x import y as z` | `use x, only : z => y` | rename and restrict in one statement |
| `__all__` | `private` + explicit `public ::` | read the `public` list first |
| `a = np.zeros(n)` | `real(r_def), allocatable :: a(:)` then `allocate` | shape is in the type |
| `a.shape`, `a.ndim` | `shape(a)`, `rank(a)`, `size(a, dim)` | |
| `a[1:3]` | `a(2:3)` | 1-based, inclusive, parentheses |
| `a[::2]` | `a(1:n:2)` | |
| `np.where(m, a, b)` | `merge(a, b, m)` | argument order differs |
| `a[m]` | `pack(a, m)` | |
| `np.roll(a, k)` | `cshift(a, -k)` | sign convention differs |
| `v[:, None]` | `spread(v, 2, n)` | no broadcasting; be explicit |
| `@np.vectorize` | `elemental` | compiled, and implicitly `pure` |
| Numba `float64[::1]` | explicit-shape dummy, or `contiguous` | same promise, same payoff |
| a NumPy view | assumed-shape dummy `x(:)`, or a `pointer` | both carry a descriptor |
| `np.ascontiguousarray` at a boundary | copy-in/copy-out into an explicit-shape dummy | silent; `-fcheck=array-temps` reveals it |
| `order='F'` | the default | innermost loop over the *first* index |
| `def f(x, y=None)` | `optional` + `present()` | keyword calls work as in Python |
| `functools.singledispatch` | `interface` + `module procedure` | resolved at compile time |
| `self` | `class(t), intent(inout) :: self` | explicit, as in Python |
| `isinstance` dispatch | `select type` | `type is` exact, `class is` inclusive |
| `Any` / `object` | `class(*)` | LFRic prefers a common abstract base |
| `def __init__` | a generic interface named like the type | or an `initialise` binding |
| `__del__` | `final` | weaker guarantees; do not rely on it |
| `weakref` / borrowed reference | `pointer` | but with strides, so more like a view |
| `list`/`unique_ptr` ownership | `allocatable` | freed on scope exit |
| mutable default argument | initialiser at declaration implies `save` | same bug, same cause |
| a `.pyi` stub | the `.mod` file | compiler-generated, not hand-written |
| `argparse` | `get_command_argument` + fifty lines | in the standard since 2003 |
| a TOML config | a `namelist` | schema is the declaration list |
| `jax.jit` on a pure function | PSyclone on a kernel | ahead of time, on source |
| `jax.vmap` | the generated cell loop, or `do concurrent` | declare independence, let it choose |
| `ctypes` / `pybind11` | `iso_c_binding`, `bind(c)` | the only sanctioned route in LFRic |

### Traps, in order of how much time they cost

| trap | symptom | fix |
|---|---|---|
| missing `implicit none` | a typo becomes a new variable | `implicit none` everywhere; `-fimplicit-none` |
| unsuffixed real literal | wrong in the 8th digit | `1.23_r_def` on every literal |
| initialiser implies `save` | state persists across calls; races under OpenMP | assign in the body; `nullify` pointers |
| `intent(out)` on a derived type | components silently reset, allocatables freed | `intent(inout)` when adding to existing state |
| fixed-length string comparison | `'W2' == 'W2  '` is *true*, `len` is not what you think | `trim`, `len_trim`, `character(*)` dummies |
| assumed-shape renumbering | `lbound` becomes 1 inside the callee | declare `x(lb:)` or pass bounds |
| copy-in/copy-out | mysterious slowdown at a call | `contiguous`, or pass whole arrays |
| automatic array on the stack | segfault at scale, no message | `ulimit -s unlimited`, `OMP_STACKSIZE` |
| reallocation on assignment | a shape check in a hot loop | preallocate; `-fno-realloc-lhs` |
| unassociated pointer | `associated()` is garbage before nullification | `nullify` early |
| no broadcasting | shape-mismatch compile error | `spread` |
| `cshift` sign | off-by-one in the wrong direction | `cshift(a, -k)` for `np.roll(a, k)` |
| implicit interface | wrong argument types link fine | put everything in a module |

---

## 14. Where to go next

**Read, in this order.** The [`skeleton` application](https://github.com/MetOffice/lfric_core/tree/main/applications/skeleton) in `lfric_core` is the smallest complete LFRic program: driver, algorithm, namelists, and a `rose-stem` suite, about 400 lines total. Then a real kernel or two from `components/science/source/kernel/`. Then [`field_mod.t90`](https://github.com/MetOffice/lfric_core/blob/main/infrastructure/source/field/field_mod.t90) and `field_parent_mod.f90` together, which is where the OOP is densest. Then an application in `lfric_apps`.

**Reference.** [Fortran-lang.org](https://fortran-lang.org/learn/) is the modern community documentation and is genuinely good; its [Quickstart](https://fortran-lang.org/learn/quickstart/) is the "learn X in Y minutes" done properly. [Metcalf, Reid & Cohen, *Modern Fortran Explained*](https://global.oup.com/academic/product/modern-fortran-explained-9780198876571) is the standard reference and is written by people on the committee. [`sebastian-mutz/c3`](https://github.com/sebastian-mutz/c3) is a compact, opinionated tour worth an hour once the above is familiar. The [gfortran manual](https://gcc.gnu.org/onlinedocs/gfortran/) is the place to settle "is this standard or an extension" arguments — as is `lfortran --show-asr`, which is in this environment.

**LFRic-specific.** The [Core documentation](https://metoffice.github.io/lfric_core/) (its source is in `documentation/source/` in the submodule, so you can grep it), the [PSyclone LFRic API reference](https://psyclone.readthedocs.io/), the [Working Practices](https://metoffice.github.io/simulation-systems/), and the [simulation-systems discussions](https://github.com/MetOffice/simulation-systems/discussions/categories/lfric) where the maintainers answer questions.

**In this repository.** [The LFRic paper, from the ground up](../paper-explained.qmd) covers the numerics and the software architecture at the level of ideas; [Formulation, from first principles](../formulation-explained.qmd) derives the equations; the [glossary](../glossary.qmd) is for term lookup. This page is their code-level companion.
