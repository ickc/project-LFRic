"""A gfortran-backed ``%%fortran`` cell magic.

Why a magic rather than a Fortran Jupyter kernel?  LFortran ships one (``xeus``
based, display name "Fortran") and it is pleasant for arithmetic, but as of
0.64 it cannot compile ``use, intrinsic :: iso_fortran_env``, ``optional``
dummy arguments, or ``allocate(p, source=...)`` on a polymorphic variable.
Those three are load-bearing in LFRic, so the notebook drives a real compiler
instead and keeps the Python kernel — which has the side benefit that a NumPy
cell and a Fortran cell can sit next to each other.

The model is a tiny build system, not a REPL:

* a cell containing a ``module``/``submodule`` is compiled to an object file
  and remembered, so later cells can ``use`` it;
* a cell containing a ``program`` is compiled, linked against every remembered
  object, run, and its output shown;
* anything else is wrapped in ``program ... end program`` and treated as above.

Everything happens inside ``.nbbuild/`` beside the notebook, and the compiler
is always invoked with a *relative* source path, so diagnostics read
``cell_07.f90:5:12`` on every machine.  That matters: the notebook's stored
outputs are what Quarto renders, and they are committed.
"""

from __future__ import annotations

import re
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

from IPython.core.magic import Magics, cell_magic, line_magic, magics_class
from IPython.core.magic_arguments import argument, magic_arguments, parse_argstring

# Quiet, debuggable, and permissive about line length: LFRic-style code with a
# column of aligned `&` continuations routinely runs past the 132-character
# free-form default.  `-fcheck=bounds` is on so the array-bounds footguns in
# the notebook actually fire; a cell can opt out with `--flags -fcheck=no-bounds`.
DEFAULT_FLAGS: tuple[str, ...] = (
    "-O0",
    "-g",
    "-fbacktrace",
    "-fcheck=bounds",
    "-ffree-line-length-none",
)

BUILD_DIR = Path(".nbbuild")
RULE = "─" * 68

# A `module` *statement* opens a program unit and is followed by nothing but
# the name.  `module procedure`, `module function` and `module subroutine`
# are separate-module-procedure syntax and must not match.
_MODULE_RE = re.compile(
    r"^[ \t]*module[ \t]+(?!procedure\b|function\b|subroutine\b)([a-z]\w*)[ \t]*$",
    re.IGNORECASE | re.MULTILINE,
)
_SUBMODULE_RE = re.compile(
    r"^[ \t]*submodule[ \t]*\([^)]*\)[ \t]*([a-z]\w*)",
    re.IGNORECASE | re.MULTILINE,
)
_PROGRAM_RE = re.compile(
    r"^[ \t]*program[ \t]+([a-z]\w*)",
    re.IGNORECASE | re.MULTILINE,
)
_USE_RE = re.compile(r"^[ \t]*use[ \t,:]", re.IGNORECASE)
_IMPLICIT_NONE_RE = re.compile(r"^[ \t]*implicit[ \t]+none\b", re.IGNORECASE)
_PROCEDURE_START_RE = re.compile(
    r"^[ \t]*(pure|elemental|impure|recursive|module|[a-z0-9_()]+[ \t]+)*"
    r"(subroutine|function)\b",
    re.IGNORECASE,
)


def _split_words(text: str) -> list[str]:
    """Split a magic argument that holds a whole command line.

    ``parse_argstring`` splits the magic's own line without honouring quotes,
    so ``--flags "-O2 -fcheck=bounds"`` arrives with the quotation marks still
    attached.  Handing that to ``shlex.split`` yields a *single* argument
    containing a space, and gfortran then reads ``-O2 -fcheck=bounds`` as
    ``-O`` with the argument ``2 -fcheck=bounds``.  Strip one layer of
    matching quotes first.
    """
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        text = text[1:-1]
    return shlex.split(text)


def _strip_comments(code: str) -> str:
    """Blank out ``!`` comments, respecting character literals.

    Only used for *detecting* program units, never for what gets compiled.
    """
    out = []
    for line in code.split("\n"):
        quote = None
        for i, ch in enumerate(line):
            if quote is not None:
                if ch == quote:
                    quote = None
            elif ch in "'\"":
                quote = ch
            elif ch == "!":
                line = line[:i]
                break
        out.append(line)
    return "\n".join(out)


def _wrap_in_program(code: str, name: str) -> str:
    """Put loose statements inside a main program.

    ``use`` statements (with their ``&`` continuations) are hoisted above the
    ``implicit none`` we insert, because Fortran fixes that order.  A cell may
    still write its own ``contains`` section: it lands in the body untouched
    and becomes an internal procedure of the wrapper.
    """
    head: list[str] = []
    body: list[str] = []
    in_head = True
    continuing = False

    for line in code.split("\n"):
        stripped = line.strip()
        if in_head:
            if continuing:
                head.append(line)
                continuing = stripped.endswith("&")
                continue
            if stripped == "" or stripped.startswith("!"):
                head.append(line)
                continue
            if _USE_RE.match(line):
                head.append(line)
                continuing = stripped.endswith("&")
                continue
            if _IMPLICIT_NONE_RE.match(line):
                # We supply our own, in the right place.
                continue
            in_head = False
        body.append(line)

    parts = [f"program {name}"]
    parts.extend(head)
    parts.append("  implicit none")
    parts.extend(body)
    parts.append(f"end program {name}")
    return "\n".join(parts) + "\n"


@dataclass
class _Session:
    """Compiler state shared by every ``%%fortran`` cell in the notebook."""

    build_dir: Path = BUILD_DIR
    compiler: str = "gfortran"
    counter: int = 0
    # unit name -> object file name, in the order the units were compiled
    objects: dict[str, str] = field(default_factory=dict)

    def reset(self) -> None:
        if self.build_dir.exists():
            shutil.rmtree(self.build_dir)
        self.build_dir.mkdir(parents=True)
        self.counter = 0
        self.objects.clear()

    def ensure(self) -> None:
        if not self.build_dir.exists():
            self.build_dir.mkdir(parents=True)

    def run(self, argv: list[str], **kwargs) -> subprocess.CompletedProcess:
        return subprocess.run(
            argv,
            cwd=self.build_dir,
            capture_output=True,
            text=True,
            **kwargs,
        )


@magics_class
class FortranMagics(Magics):
    """``%%fortran``, ``%%fortran_file`` and a couple of line magics."""

    def __init__(self, shell=None):
        super().__init__(shell)
        self.session = _Session()
        self.session.reset()

    # ------------------------------------------------------------------ utils

    @staticmethod
    def _emit(header: str, text: str) -> None:
        """Print a labelled block, but only when there is something to say."""
        if not text.strip():
            return
        print(f"{RULE}\n{header}\n{RULE}")
        print(text.rstrip("\n"))

    # ------------------------------------------------------------------ magics

    @line_magic
    def fortran_info(self, line: str) -> None:
        """Report the compiler the notebook is actually using."""
        proc = subprocess.run(
            [self.session.compiler, "--version"], capture_output=True, text=True
        )
        print(proc.stdout.splitlines()[0])
        print(f"build dir: {self.session.build_dir}/")

    @line_magic
    def fortran_reset(self, line: str) -> None:
        """Throw away every compiled module and start again."""
        self.session.reset()
        print("build tree cleared")

    @magic_arguments()
    @argument("name", help="file name to create inside the build directory")
    @cell_magic
    def fortran_file(self, line: str, cell: str) -> None:
        """Write the cell verbatim into the build directory.

        For data a program has to open at run time — a namelist, say — since
        programs are executed with the build directory as their cwd.
        """
        args = parse_argstring(self.fortran_file, line)
        self.session.ensure()
        target = self.session.build_dir / args.name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(cell)
        print(f"wrote {args.name}")

    @magic_arguments()
    @argument("-n", "--name", default=None, help="base name for the generated file")
    # Quote the value: argparse reads a bare leading `-` as another option,
    # so `--flags -O2` is an error while `--flags "-O2"` is not.
    @argument("-f", "--flags", default="", help='extra compiler flags, quoted')
    @argument("--openmp", action="store_true", help="compile with -fopenmp")
    @argument("--no-run", action="store_true", help="compile but do not execute")
    @argument("--args", default="", help="command-line arguments for the program")
    @argument(
        "--expect-error",
        action="store_true",
        help="compilation is meant to fail; show the diagnostics as ordinary output",
    )
    @argument(
        "--expect-runtime-error",
        action="store_true",
        help="the program is meant to abort; show what it says",
    )
    @argument(
        "--show-wrapper",
        action="store_true",
        help="print the file that was actually compiled",
    )
    @cell_magic
    def fortran(self, line: str, cell: str) -> None:
        """Compile — and usually run — a cell of Fortran."""
        args = parse_argstring(self.fortran, line)
        session = self.session
        session.ensure()
        session.counter += 1

        bare = _strip_comments(cell)
        prog_match = _PROGRAM_RE.search(bare)
        mod_match = _MODULE_RE.search(bare) or _SUBMODULE_RE.search(bare)

        if prog_match is not None:
            kind, unit = "program", prog_match.group(1)
            source = cell if cell.endswith("\n") else cell + "\n"
        elif mod_match is not None:
            kind, unit = "module", mod_match.group(1)
            source = cell if cell.endswith("\n") else cell + "\n"
        else:
            kind = "program"
            unit = args.name or f"nb_cell_{session.counter:02d}"
            source = _wrap_in_program(cell, unit)

        stem = args.name or f"cell_{session.counter:02d}"
        src_name = f"{stem}.f90"
        (session.build_dir / src_name).write_text(source)

        if args.show_wrapper:
            self._emit(f"{src_name}", source)

        flags = list(DEFAULT_FLAGS)
        if args.openmp:
            flags.append("-fopenmp")
        flags.extend(_split_words(args.flags))

        # -J is where .mod/.smod files are written, -I where they are found.
        # Both point at the build directory, which is also the cwd, so every
        # path the compiler prints back is relative and machine-independent.
        modflags = ["-J.", "-I."]

        if kind == "module":
            obj_name = f"{stem}.o"
            proc = session.run(
                [session.compiler, *flags, *modflags, "-c", src_name, "-o", obj_name]
            )
            self._report_compile(proc, args, cell)
            if proc.returncode == 0:
                session.objects[unit] = obj_name
                # Silence is success: the module is now available to `use`.
            return

        exe_name = f"{stem}.x"
        link_objs = [o for o in session.objects.values()]
        proc = session.run(
            [
                session.compiler,
                *flags,
                *modflags,
                src_name,
                *link_objs,
                "-o",
                exe_name,
            ]
        )
        if not self._report_compile(proc, args, cell):
            return
        if args.no_run:
            return

        try:
            run = session.run(["./" + exe_name, *_split_words(args.args)], timeout=120)
        except subprocess.TimeoutExpired:
            print("timed out after 120 s", file=sys.stderr)
            return

        sys.stdout.write(run.stdout)
        if run.returncode != 0 and not args.expect_runtime_error:
            self._emit(f"program exited with status {run.returncode}", run.stderr)
        elif run.stderr:
            self._emit("stderr", run.stderr)

    # -------------------------------------------------------------- reporting

    def _report_compile(self, proc, args, cell: str) -> bool:
        """Show compiler output; return True if we should carry on and run."""
        failed = proc.returncode != 0

        if failed and args.expect_error:
            self._emit("gfortran rejects this, as intended", proc.stderr)
            return False
        if failed:
            self._emit("compilation failed", proc.stderr)
            first = next(
                (ln for ln in cell.split("\n") if ln.strip() and not ln.strip().startswith("!")),
                "",
            )
            if _PROCEDURE_START_RE.match(first):
                print(
                    "\nhint: a bare subroutine/function is not a program unit this magic "
                    "can run.\n      Put it in a `module ... contains ... end module` cell, "
                    "or below a\n      `contains` line in a cell that also has executable "
                    "statements."
                )
            return False
        if args.expect_error:
            self._emit("expected a compile error, but it compiled", proc.stderr)
            return True
        if proc.stderr.strip():
            self._emit("gfortran says", proc.stderr)
        return True


def load_ipython_extension(ipython) -> None:
    """Entry point for ``%load_ext fortran_tour``."""
    ipython.register_magics(FortranMagics)
