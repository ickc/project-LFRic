# PSyclone, from the Ground Up

A self-contained pixi project holding one Quarto page — a tour of PSyclone
aimed at optimising LFRic — plus the example it processes.

```
index.ipynb            the page. Quarto renders this, using its stored outputs
_pair/index.md         the jupytext pair. Edit this, not the .ipynb
src/psyclone_tour/     display helpers and submodule paths
demo/                  a self-contained PSyKAl example: kernel, algorithm, script
DESIGN.md              why the helpers exist and what they work around
```

Unlike [`../fortran`](../fortran), there is no cell magic: PSyclone is a Python
library, so the notebook drives it in-process and the helpers are for
presentation only.

## Running it

```bash
pixi run execute    # re-run the notebook and refresh its stored outputs
pixi run sync       # reconcile index.ipynb <-> _pair/index.md
pixi run demo       # run PSyclone over demo/ (plain, optimised, and kernel stub)
pixi run demo-clean
```

The page processes real source out of `submodules/lfric_core`,
`submodules/lfric_apps` and `submodules/PSyclone`, so those must be checked
out (`git submodule update --init --recursive` at the repository root). The
first cell fails with a sentence rather than a stack trace if they are not.

There is no JupyterLab in this environment; see [`../fortran/README.md`](../fortran/README.md)
for the `pixi-kernel` arrangement, which is identical here. `pixi run execute`
needs no frontend at all.

## Editing

Edit `_pair/index.md`, then `pixi run execute`. That syncs the markdown into
the notebook, runs every cell, strips execution timestamps, and syncs back.
The `.ipynb` is committed *with* its outputs on purpose: Quarto does not
execute a notebook that already has them, so `pixi run build` at the top of
the repository keeps working with nothing installed but Quarto.

## The PSyclone version is a pin, not a floor

`psyclone = "3.3.*"`. Two reasons. The page commits PSyclone's generated
Fortran as notebook output, and a new minor release reflows it. More
importantly, PSyclone's Python API moves between minor releases — 3.3 shifted
`OMPParallelTrans` and renamed every `Dynamo0p3*Trans` — and the page runs
LFRic's *real* optimisation scripts unmodified, so it has to agree with what
LFRic builds against. That is currently 3.3.1.

If a future `lfric_apps` moves to 3.4, bump the pin, re-run, and expect some
of the generated output on the page to change.

## PSyclone of your own

`demo/` is the place. It is wired for the LFRic API, so it needs LFRic's
`psyclone.cfg`, which the Makefile already points at:

```bash
make -C demo optimised      # regenerate with demo/optimisation/global.py
make -C demo stub           # the argument list the kernel metadata implies
```

Edit `demo/optimisation/global.py` and re-run to see the effect on the
generated PSy layer. For the generic (non-PSyKAl) route, no scaffolding is
needed at all — write a `trans(psyir)` in a file and run
`psyclone -s yours.py -o out.f90 in.f90`.
