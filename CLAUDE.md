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
- `pixi run execute` (inside `src/fortran/`) re-runs the notebook, strips execution timestamps via `python -m fortran_tour.nbclean`, and syncs the pair back. Run it after editing `_pair/index.md`.
- Fortran cells use a `%%fortran` magic (`src/fortran_tour/magic.py`) that drives gfortran — a small build system, not a REPL. LFortran's Jupyter kernel was evaluated and rejected; see §0 of the page.
- `demo/` is a scratch build area with automatic module-dependency scanning (`fortdep.py`), plus a CLI example and a miniature PSyKAl stack.

## Key Institutional Context

- **Met Office** owns `lfric_core` and `lfric_apps`; contributions require signing the [Momentum CLA](https://github.com/MetOffice/Momentum/blob/main/CLA.md)
- **MetOffice GitHub org** enforces SAML SSO — SSH keys must be authorized for the org before cloning/fetching
- **Isambard3** is a UK Tier-2 HPC facility; LFRic builds there use Spack with GNU (gfortran) or NVIDIA (nvfortran) toolchains
- **XIOS** is used for parallel I/O; pinned to IPSL GitLab mirror revision 2252 (old SVN endpoint retired)
- Rose/Cylc suites use `rose stem` for CI and `cylc vip` for submission; requires SSH agent for the scheduler host

## Explainer Notes (house tone)

`src/paper-explained.qmd` is the model for personalized explainer documents; the full style spec lives in the `explain` skill (`.claude/skills/explain/SKILL.md`). Short version: ground-up rebuild in logical order (not source order); math formalism first; bridges into the reader's fields (CMB data analysis, statistics, JAX); footnotes (not blockquotes) for asides and etymology; mark interpretive claims *(gloss)* vs. source claims; summary table at the end; British spelling. Style ancestors: `~/git/private/project-ai/notes/` (`tokenization_notes.md`, `adamw_notes.md`).

## External Links

- LFRic Core docs: https://metoffice.github.io/lfric_core/
- LFRic Apps docs: https://metoffice.github.io/lfric_apps/
- Training: https://metoffice.github.io/LFRic-Atmosphere-Training
- Simulation Systems discussions: https://github.com/MetOffice/simulation-systems/discussions/categories/lfric
- Working Practices: https://metoffice.github.io/simulation-systems/index.html
