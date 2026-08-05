#!/usr/bin/env python3
"""Emit make dependency rules for a tree of Fortran source files.

Fortran has no header files.  A ``module`` is compiled into a binary interface
file (``.mod`` with gfortran) that the compiler emits as a *side effect* of
compiling the module, and that every ``use`` of it then reads.  So the object
files of a Fortran program have a build order, that order is a DAG derived from
the source, and `make` cannot see it: nothing in ``foo.f90``'s file name says it
must be compiled after ``bar.f90``.

Every serious Fortran build system therefore ships a scanner.  LFRic's is
`fab <https://github.com/MetOffice/fab>`_ (and ``fcm-make`` before it); the
Fortran Package Manager has one built in; this is the forty-line version, so
the mechanism is not a black box.

Scanning is *lexical*, not semantic: find the ``module``/``submodule`` each file
defines and the modules each file ``use``s, then join the two on module name.
That is all a real scanner does either — which is also why a stray ``use`` of a
module that no file in the tree defines shows up as a link error rather than a
build-order error.

Usage::

    python3 fortdep.py build src/*.f90 > build/deps.mk
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# `module foo` opens a program unit; `module procedure`, `module function` and
# `module subroutine` are separate-module-procedure syntax and define nothing.
MODULE_RE = re.compile(
    r"^\s*module\s+(?!procedure\b|function\b|subroutine\b)([a-z]\w*)\s*(?:!.*)?$",
    re.IGNORECASE,
)
SUBMODULE_RE = re.compile(r"^\s*submodule\s*\(\s*([a-z]\w*)", re.IGNORECASE)
USE_RE = re.compile(r"^\s*use\s*(?:,\s*intrinsic\s*)?(?:::)?\s*([a-z]\w*)", re.IGNORECASE)
PROGRAM_RE = re.compile(r"^\s*program\s+([a-z]\w*)", re.IGNORECASE)

# Modules the compiler provides; they have no source file in the tree.
INTRINSIC = {"iso_fortran_env", "iso_c_binding", "ieee_arithmetic",
             "ieee_exceptions", "ieee_features", "omp_lib", "omp_lib_kinds",
             "mpi", "mpi_f08"}


def scan(path: Path) -> tuple[set[str], set[str], bool]:
    """Return (modules defined, modules used, is a main program)."""
    defines: set[str] = set()
    uses: set[str] = set()
    is_program = False
    for line in path.read_text().splitlines():
        line = line.split("!", 1)[0]
        if m := MODULE_RE.match(line):
            defines.add(m.group(1).lower())
        elif m := SUBMODULE_RE.match(line):
            # A submodule needs its parent's interface, but does not define it.
            uses.add(m.group(1).lower())
        elif m := USE_RE.match(line):
            uses.add(m.group(1).lower())
        elif PROGRAM_RE.match(line):
            is_program = True
    return defines, uses, is_program


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    build = argv[0]
    sources = [Path(p) for p in argv[1:]]

    owner: dict[str, Path] = {}
    info: dict[Path, tuple[set[str], set[str], bool]] = {}
    for src in sources:
        defines, uses, is_program = scan(src)
        info[src] = (defines, uses, is_program)
        for name in defines:
            owner[name] = src

    programs = []
    for src, (_defines, uses, is_program) in sorted(info.items()):
        obj = f"{build}/{src.stem}.o"
        needed = sorted(
            {
                f"{build}/{owner[u].stem}.o"
                for u in uses
                if u in owner and owner[u] != src and u not in INTRINSIC
            }
        )
        if needed:
            print(f"{obj}: {' '.join(needed)}")
        if is_program:
            # A program links its whole reachable subgraph, so close over it.
            closure: set[str] = set()
            frontier = set(uses)
            while frontier:
                name = frontier.pop()
                if name in INTRINSIC or name not in owner:
                    continue
                dep = owner[name]
                if dep in closure or dep == src:
                    continue
                closure.add(dep)
                frontier |= info[dep][1]
            objs = " ".join(sorted(f"{build}/{p.stem}.o" for p in closure))
            exe = f"{build}/{src.stem}"
            print(f"{exe}: {obj} {objs}")
            programs.append(exe)

    print(f"PROGRAMS := {' '.join(sorted(programs))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
