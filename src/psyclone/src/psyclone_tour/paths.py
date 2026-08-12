"""Where the submodules live, found by walking up from this file.

The notebook quotes and processes real source out of ``submodules/``, so it
needs absolute paths to them.  Deriving those by walking up to the directory
holding ``.gitmodules`` keeps the notebook free of ``../../..`` chains and
keeps it working whether the kernel's cwd is ``src/psyclone`` (which is what
``pixi run execute`` gives) or somewhere else.
"""

from __future__ import annotations

from pathlib import Path


def _repo_root() -> Path:
    for candidate in Path(__file__).resolve().parents:
        if (candidate / ".gitmodules").is_file():
            return candidate
    raise RuntimeError(
        "cannot locate the repository root: no .gitmodules above "
        f"{Path(__file__).resolve()}"
    )


REPO = _repo_root()

SUBMODULES = REPO / "submodules"
LFRIC_CORE = SUBMODULES / "lfric_core"
LFRIC_APPS = SUBMODULES / "lfric_apps"
PSYCLONE_SRC = SUBMODULES / "PSyclone"

#: The LFRic PSyclone configuration file.  It is not optional for the LFRic
#: API: it defines the function spaces, the valid annexed-dof behaviour and
#: the ``COMPUTE_ANNEXED_DOFS`` setting that decides how far the generated
#: loops run.  PSyclone ships a default config, but LFRic's differs.
LFRIC_CONFIG = LFRIC_CORE / "etc" / "psyclone.cfg"

#: ``psyclone_tools.py`` -- the shared transformation library that every
#: LFRic application's ``optimisation/*/psykal/global.py`` imports.
LFRIC_PSYCLONE_TOOLS = LFRIC_CORE / "infrastructure" / "build" / "psyclone"

#: ``transmute_functions.py`` -- the equivalent for the generic
#: (non-PSyKAl) route through ordinary physics source in lfric_apps.
LFRIC_TRANSMUTE_TOOLS = LFRIC_APPS / "interfaces" / "build"


def check() -> None:
    """Raise if the submodules are not checked out.

    Called at the top of the notebook so that a missing ``git submodule
    update --init`` fails with a sentence rather than with a stack trace
    forty cells later.
    """
    missing = [
        str(path.relative_to(REPO))
        for path in (LFRIC_CORE, LFRIC_APPS, PSYCLONE_SRC)
        if not any(path.iterdir()) if path.is_dir()
    ] + [
        str(path.relative_to(REPO))
        for path in (LFRIC_CORE, LFRIC_APPS, PSYCLONE_SRC)
        if not path.is_dir()
    ]
    if missing:
        raise RuntimeError(
            f"submodules not checked out: {', '.join(sorted(missing))}. "
            "Run `git submodule update --init --recursive` at the "
            "repository root."
        )
