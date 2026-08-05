# Modern Fortran, from the Ground Up

A self-contained pixi project holding one Quarto page — a tour of modern
Fortran aimed at reading LFRic — plus the tooling that makes it runnable.

```
index.ipynb            the page. Quarto renders this, using its stored outputs
_pair/index.md         the jupytext pair. Edit this, not the .ipynb
src/fortran_tour/      the %%fortran cell magic that drives gfortran
demo/                  multi-file examples + a scratch build area
fortran-highlight.lua  relabels %%fortran cells so Quarto highlights them
```

## Running it

```bash
pixi run lab        # JupyterLab, using this environment's kernel
pixi run execute    # re-run the notebook and refresh its stored outputs
pixi run sync       # reconcile index.ipynb <-> _pair/index.md
pixi run demo       # build demo/ programs
pixi run demo-clean
```

`pixi run lab` starts JupyterLab inside this environment, so the notebook's
`python3` kernel is the right one and nothing needs registering. If you would
rather open the notebook from a JupyterLab installed elsewhere, run
`pixi run kernel` once: it registers this environment as **Python
(fortran_tour)** under `~/.local/share/jupyter/kernels/`, and you then pick
that kernel by hand.

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

## About LFortran

`lfortran` is in this environment but the notebook does not use it — §0 of the
page explains why, and having it installed means you can check the claim. It
is also useful on its own: `lfortran --show-asr file.f90` prints a resolved
semantic tree, which settles arguments about what a declaration means.
