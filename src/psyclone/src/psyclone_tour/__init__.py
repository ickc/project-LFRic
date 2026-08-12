"""Helpers for the PSyclone tour notebook.

The page is a Python notebook driving PSyclone's own API, so unlike the
Fortran tour there is no cell magic here and no compiler to shell out to --
everything happens in-process.  What is needed instead is *presentation*:
PSyclone hands back Fortran source and PSyIR trees as plain strings, and a
plain string in a notebook output is unhighlighted grey text.

So the helpers here mostly exist to push output back through Jupyter's
display system as fenced markdown, which Quarto then highlights as Fortran.
That is the whole trick; the rest is path bookkeeping for the submodules.
"""

from __future__ import annotations

from .display import diff, fortran, psyir, run, show, tree
from .paths import LFRIC_APPS, LFRIC_CORE, PSYCLONE_SRC, REPO

__all__ = [
    "LFRIC_APPS",
    "LFRIC_CORE",
    "PSYCLONE_SRC",
    "REPO",
    "diff",
    "fortran",
    "psyir",
    "run",
    "show",
    "tree",
]
