# Design notes: `%%fortran` and the highlighting filter

Internals for `src/fortran_tour/magic.py` and `fortran-highlight.lua`. The
README says how to run things; this says how they work and where the sharp
edges are.

## Why a magic, not a Fortran kernel

LFortran ships a Jupyter kernel (`xeus`-based), but as of 0.64 it cannot
compile `use, intrinsic :: iso_fortran_env`, `optional` dummy arguments, or
`allocate(p, source=...)` on a polymorphic variable — all load-bearing in
LFRic. So the notebook keeps the Python kernel and drives a real compiler
(`gfortran`) from a cell magic instead. Side benefit: a NumPy cell and a
Fortran cell sit next to each other on the same kernel.

## The model: a tiny build system, not a REPL

State lives in one `_Session` dataclass, constructed once when
`%load_ext fortran_tour` registers the magics, and reset by
`%fortran_reset`. It holds:

- `build_dir` — always `.nbbuild/`, relative to the kernel's cwd (the
  notebook's directory).
- `counter` — cells compiled so far, used to name files (`cell_01.f90`, …).
- `objects` — `dict[unit_name, object_file]`, insertion-ordered, for every
  `module`/`submodule` compiled so far in this kernel session.

On each `%%fortran` cell:

1. **Classify.** Comments are blanked out (respecting string literals) and
   the result is regexed for `program NAME`, `module NAME`, or
   `submodule (...) NAME`. Three outcomes:
   - has `program` → compile-and-run.
   - has `module`/`submodule` → compile-only, remembered in `session.objects`.
   - neither (bare statements) → wrapped in a synthesized
     `program nb_cell_NN ... end program` (`_wrap_in_program`), hoisting any
     `use` lines above an inserted `implicit none` and dropping any
     `implicit none` the cell wrote itself.
2. **Write** the source to `.nbbuild/cell_NN.f90` (or `--name`-given stem).
   Always a *relative* path — diagnostics read `cell_07.f90:5:12` on every
   machine, which matters because notebook outputs are committed.
3. **Compile** with `gfortran`, `-J. -I.` (so `.mod`/`.smod` land in and are
   found from the same build dir), plus `DEFAULT_FLAGS`
   (`-O0 -g -fbacktrace -fcheck=bounds -ffree-line-length-none`) and anything
   from `--flags`/`--openmp`.
   - Module cells: `-c cell_NN.f90 -o cell_NN.o`; success adds
     `objects[unit] = "cell_NN.o"` so later cells can `use` it.
   - Program cells: linked against *every* object in `session.objects` in
     the order they were compiled, producing `cell_NN.x`.
4. **Run.** Unless `--no-run`, `./cell_NN.x` is executed (cwd = build dir,
   120 s timeout, `--args` forwarded), and its captured stdout/stderr is
   written into the cell's Jupyter output. That capture is the *only*
   channel back to Python — there is no FFI/ctypes/f2py bridge, so Fortran
   results never become Python objects. If you need that, this magic is the
   wrong tool; it's scoped for teaching, not interop.

`--expect-error`/`--expect-runtime-error` mark cells that are deliberately
supposed to fail, so the compiler/runtime diagnostics are shown as intended
output rather than reported as a failure. `--show-wrapper` prints the
synthesized `program ... end program` for a bare-statement cell.

`%%fortran_file NAME` writes a cell verbatim to `.nbbuild/NAME` with no
compilation — for data a program reads at runtime (e.g. a namelist), since
programs run with the build directory as their cwd.

## Known constraints

- **One notebook per `.nbbuild`-owning directory.** `BUILD_DIR` is the bare
  relative path `.nbbuild`, with no notebook name folded in, and each
  kernel's `counter`/`objects` start independently at 0/`{}`. Two notebooks
  sharing a working directory would both write `.nbbuild/cell_01.f90`, race
  on the same files, and could link against `.o` files the *other*
  notebook produced. There is currently only one notebook in this
  directory (`index.ipynb`), so this is a latent constraint, not an active
  bug — worth knowing before adding a second notebook here, rather than
  something to pre-emptively engineer around.
- **The `cell_NN` counter does not wrap at 99.** `f"cell_{counter:02d}"` is a
  *minimum*-width format: it zero-pads up to 2 digits but does not truncate,
  so cell 123 becomes `cell_123.f90`. No collision risk from a long
  notebook.
- **No results as Python objects.** Output is text captured from the
  compiled program's stdout/stderr, not marshalled data. Getting an actual
  value back into Python (arrays, structs, …) would need `iso_c_binding` +
  `ctypes`, or f2py — out of scope for what this magic is for.

## The highlighting filter (`fortran-highlight.lua`)

Quarto's Jupyter engine labels every code cell with the *kernel* language,
which is Python here — `%%fortran` is an IPython cell magic on a Python
kernel, not a separate language. So Fortran cells arrive tagged
`.python`, and Pandoc's highlighter gets `!` comments and Fortran keywords
wrong.

The filter's `CodeBlock` runs on every `.python`-classed block and checks
the raw cell text:

- starts with `%%fortran_file` → drop the `python` class entirely (it's
  usually a namelist, not code any lexer fits).
- starts with `%%fortran` (not `_file`) → swap `python` for `fortran`.

It's declared from the notebook's own front matter, so it only affects this
page.
