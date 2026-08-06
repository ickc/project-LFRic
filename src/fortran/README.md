# Modern Fortran, from the Ground Up

A self-contained pixi project holding one Quarto page — a tour of modern
Fortran aimed at reading LFRic — plus the tooling that makes it runnable.

```
index.ipynb            the page. Quarto renders this, using its stored outputs
_pair/index.md         the jupytext pair. Edit this, not the .ipynb
src/fortran_tour/      the %%fortran cell magic that drives gfortran
demo/                  multi-file examples + a scratch build area
fortran-highlight.lua  relabels %%fortran cells so Quarto highlights them
DESIGN.md              how the magic and the highlighting filter work
```

## Running it

```bash
pixi run execute    # re-run the notebook and refresh its stored outputs
pixi run sync       # reconcile index.ipynb <-> _pair/index.md
pixi run demo       # build demo/ programs
pixi run demo-clean
```

There is no JupyterLab in this environment. Open the notebook from a
JupyterLab installed elsewhere that has [`pixi-kernel`](https://github.com/renan-r-santos/pixi-kernel)
available: it discovers this directory's pixi project and launches the kernel
inside this environment, which is why the notebook's recorded kernelspec is
`pixi-kernel-python3`. `pixi run execute` needs no frontend at all — it drives
the kernel headlessly through `nbclient`.

## Editing

Edit `_pair/index.md`, then `pixi run execute`. That syncs the markdown into
the notebook, runs every cell, strips the execution timestamps that would
otherwise churn in git, and syncs back.

The `.ipynb` is committed *with* its outputs on purpose: Quarto does not
execute a notebook that already has them, so `pixi run build` at the top of
the repository keeps working with nothing installed but Quarto.

## Fortran of your own

Drop a `.f90` into `demo/` and run `make -C demo`. The build order is worked
out by `demo/fortdep.py`, so files can `use` each other in any arrangement.
Every file containing a `program` becomes an executable in `demo/build/`.
