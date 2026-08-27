# project-LFRic

Personal wiki and workspace for LFRic RSE work in collaboration with the Met Office.

## What This Repo Is

A Quarto website + submodule collection serving as a personal knowledge base around LFRic. The site is rendered to `docs/` and can be served locally or published to GitHub Pages.

## Submodules (`submodules/`)

| Path | Remote | Purpose |
|------|--------|---------|
| `submodules/arXiv-1809.07267` | `git@github.com:ickc/arXiv-1809.07267.git` | LaTeX source of the Adams et al. 2019 LFRic paper |
| `submodules/lfric_core` | `git@github.com:MetOffice/lfric_core.git` | Core infrastructure library (Fortran); mesh, fields, PSyclone, XIOS |
| `submodules/lfric_apps` | `git@github.com:MetOffice/lfric_apps.git` | Science applications: Momentum® Atm model, GungHo dynamical core |
| `submodules/LFRic-Atmosphere-Training` | `git@github.com:MetOffice/LFRic-Atmosphere-Training.git` | Self-learning training materials (Sphinx + Jupyter notebooks) |
| `submodules/Isambard3-LFRic-Env-Science-Suites` | `git@github.com:UniExeterRSE/Isambard3-LFRic-Env-Science-Suites.git` | Spack environments (GNU/NVIDIA) + Rose/Cylc suites for Isambard3 HPC |
| `submodules/PSyclone` | `git@github.com:stfc/PSyclone.git` | The source-to-source compiler; pinned to the release LFRic builds against (currently `v3.3.1`) |

After cloning: `git submodule update --init --recursive`

## LFRic Architecture

- **LFRic Core** — shared infrastructure: mesh (cubed-sphere), field types, halo exchanges, I/O (XIOS), PSyclone integration
  - Key components: `coupling`, `driver`, `inventory`, `lfric-xios`, `science`, `infrastructure`
- **LFRic Apps** — science layer on top of Core: Momentum® Atmosphere model (NWP/climate), GungHo dynamical core
- **PSyclone** — domain-specific compiler that separates science (kernel) code from parallelisation; generates MPI+OpenMP/OpenACC/CUDA code
- **Rose/Cylc** — workflow manager for running model suites; suites live in `rose-stem/` directories
- **Spack** — HPC package manager used for building LFRic on Isambard3

## Building the Website

Quarto source lives in `src/`; output is rendered to `docs/`. Uses [pixi](https://pixi.sh) for environment management:

```bash
pixi run serve    # live-reload preview at http://localhost:8042
pixi run build    # render src/ to docs/
pixi run clean    # remove docs/
```

Without pixi, requires `quarto` on PATH:

```bash
quarto preview src --port 8042
quarto render src
```

### `src/fortran/` — a nested pixi project

The Fortran tutorial page is its own pixi workspace inside the Quarto tree, because it needs a compiler and a notebook stack that the site build must not depend on.

- `_pair/index.md` is the source to edit; `index.ipynb` is generated from it by jupytext and is **committed with its outputs**, because Quarto does not execute a notebook that already has them. So `pixi run build` at the repo root still needs nothing but Quarto.
- `pixi run execute` (inside `src/fortran/`) syncs the pair in, re-runs the notebook, strips execution timestamps via `python -m fortran_tour.nbclean`, and syncs back. Run it after editing `_pair/index.md`.
- The environment holds no Jupyter frontend. The notebook is opened from a JupyterLab installed elsewhere via [`pixi-kernel`](https://github.com/renan-r-santos/pixi-kernel), hence the recorded kernelspec `pixi-kernel-python3`; `pixi run execute` overrides it with `python3`, which is what `ipykernel` registers inside the environment.
- Fortran cells use a `%%fortran` magic (`src/fortran_tour/magic.py`) that drives gfortran — a small build system, not a REPL. LFortran's Jupyter kernel was evaluated and rejected; see §0 of the page.
- `demo/` is a scratch build area with automatic module-dependency scanning (`fortdep.py`), plus a CLI example and a miniature PSyKAl stack.

### `src/psyclone/` — a second nested pixi project

The PSyclone tutorial page, same arrangement as `src/fortran/` (edit `_pair/index.md`, `pixi run execute`, `.ipynb` committed with outputs) but no cell magic: PSyclone is a Python package, so the notebook drives it in-process.

- `psyclone = "3.3.*"` is a deliberate pin, not a floor. The page runs LFRic's *real* optimisation scripts unmodified, and PSyclone's Python API moves between minor releases — 3.3 shifted `OMPParallelTrans` and renamed every `Dynamo0p3*Trans` to `LFRic*Trans`. Bump only when `lfric_apps` does, then re-run and re-read the diffs.
- `src/psyclone_tour/` is presentation only: `show` emits Fortran as fenced markdown so Quarto highlights it, `tree` forces `Node.view(colour=False)`, `diff` shows what a transformation changed, `run` shells out for the CLI-only parts. See `DESIGN.md`.
- The page processes real source from `submodules/{lfric_core,lfric_apps}`, so it depends on submodule state; `psyclone_tour.paths.check()` in the first cell fails loudly if they are absent.
- `demo/` is a self-contained PSyKAl triplet (kernel, `.x90` algorithm, optimisation script). `GH_INC` on `W1` on purpose — a continuous function space is what makes colouring, the halo-depth loop bound and the `cmap` indirection appear. Nothing in it compiles; the artifact is the generated source.
- PSyKAl-mode invocations must pass `--config submodules/lfric_core/etc/psyclone.cfg`. It is not decoration: `COMPUTE_ANNEXED_DOFS` in it changes the generated loop bounds.

## Key Institutional Context

- **Met Office** owns `lfric_core` and `lfric_apps`; contributions require signing the [Momentum CLA](https://github.com/MetOffice/Momentum/blob/main/CLA.md)
- **MetOffice GitHub org** enforces SAML SSO — SSH keys must be authorized for the org before cloning/fetching
- **Isambard3** is a UK Tier-2 HPC facility; LFRic builds there use Spack with GNU (gfortran) or NVIDIA (nvfortran) toolchains
- **XIOS** is used for parallel I/O; pinned to IPSL GitLab mirror revision 2252 (old SVN endpoint retired)
- Rose/Cylc suites use `rose stem` for CI and `cylc vip` for submission; requires SSH agent for the scheduler host

## Explainer Notes (house tone)

`src/paper-explained.qmd` is the model for personalized explainer documents; the full style spec lives in the `explain` skill (`.claude/skills/explain/SKILL.md`). Short version: ground-up rebuild in logical order (not source order); math formalism first; bridges into the reader's fields (CMB data analysis, statistics, JAX); footnotes (not blockquotes) for asides and etymology; mark interpretive claims *(gloss)* vs. source claims; summary table at the end; British spelling. Style ancestors: earlier notes of the same kind kept outside this repo (`tokenization_notes.md`, `adamw_notes.md`).

## External Links

- LFRic Core docs: https://metoffice.github.io/lfric_core/
- LFRic Apps docs: https://metoffice.github.io/lfric_apps/
- Training: https://metoffice.github.io/LFRic-Atmosphere-Training
- Simulation Systems discussions: https://github.com/MetOffice/simulation-systems/discussions/categories/lfric
- Working Practices: https://metoffice.github.io/simulation-systems/index.html
