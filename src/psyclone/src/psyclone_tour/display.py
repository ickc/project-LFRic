"""Turn PSyclone's output into something a rendered page can be read from.

Three kinds of thing get shown on the page, and each wants different
treatment:

``show``
    Fortran source -- from the ``FortranWriter`` backend, or read off disk.
    Pushed through ``IPython.display.Markdown`` inside a fenced block so
    that Quarto highlights it.  A ``print()`` would render as grey
    monospace, which for hundred-line generated PSy layers is unreadable.

``tree``
    A PSyIR tree, from ``Node.view()``.  Deliberately *not* highlighted --
    it is not Fortran, and no lexer improves it.  Colour is forced off:
    ``view()`` defaults to ANSI colour codes, which would be committed into
    the notebook's stored output and then rendered as escape-sequence
    garbage by Quarto.

``diff``
    The point of most cells is not the generated code but the *delta* a
    transformation made.  A hundred lines of PSy layer with two new
    ``!$omp`` lines buried in it does not make that point; eight lines of
    unified diff does.
"""

from __future__ import annotations

import difflib
import os
import subprocess
from pathlib import Path

from IPython.display import Markdown, display
from psyclone.psyir.backend.fortran import FortranWriter
from psyclone.psyir.frontend.fortran import FortranReader
from psyclone.psyir.nodes import Node

#: One writer, reused.  Constructing a ``FortranWriter`` is not free (it
#: builds the operator-precedence tables), and nothing here needs a
#: per-call configuration.
_WRITER = FortranWriter()


def psyir(source: str | Path) -> Node:
    """Parse Fortran into PSyIR. Accepts source text or a path to a file."""
    reader = FortranReader()
    if isinstance(source, Path):
        return reader.psyir_from_file(str(source))
    return reader.psyir_from_source(source)


def fortran(node: Node) -> str:
    """Lower a PSyIR node back to Fortran source text.

    Works on any node, not just a whole file: handing it a single ``Loop``
    prints just that loop, which is what most of the before/after
    comparisons on the page actually want.
    """
    return _WRITER(node)


def show(content: str | Path | Node, lang: str = "fortran") -> None:
    """Display Fortran (or any other source) as a highlighted code block."""
    if isinstance(content, Node):
        text = fortran(content)
    elif isinstance(content, Path):
        text = content.read_text()
    else:
        text = content
    display(Markdown(f"```{lang}\n{text.rstrip()}\n```"))


def tree(node: Node, depth: int = 0) -> None:
    """Print a PSyIR tree, without the ANSI colour that ``view()`` defaults to."""
    print(node.view(depth=depth, colour=False).rstrip())


def diff(
    before: str | Node,
    after: str | Node,
    before_label: str = "before",
    after_label: str = "after",
    context: int = 3,
) -> None:
    """Display a unified diff of two pieces of Fortran, highlighted as a diff.

    Either side may be a PSyIR node, in which case it is lowered first --
    which is the usual case: capture ``fortran(sched)`` before applying a
    transformation, then pass the same (now mutated) node as *after*.
    """
    old = fortran(before) if isinstance(before, Node) else before
    new = fortran(after) if isinstance(after, Node) else after
    lines = difflib.unified_diff(
        old.splitlines(),
        new.splitlines(),
        fromfile=before_label,
        tofile=after_label,
        lineterm="",
        n=context,
    )
    body = "\n".join(lines)
    if not body.strip():
        display(Markdown("*(no change)*"))
        return
    display(Markdown(f"```diff\n{body}\n```"))


def run(
    *argv: str | Path,
    env: dict[str, str] | None = None,
    cwd: str | Path | None = None,
    expect_failure: bool = False,
) -> str:
    """Run a command, print its combined output, and return it.

    Used for the parts of the page that must go through PSyclone's *command
    line* rather than its API -- the PSyKAl route, where ``psyclone -api
    lfric`` does algorithm rewriting and PSy-layer generation that no public
    Python entry point exposes as one call.

    ``env`` is merged into the current environment rather than replacing it,
    because PSyclone needs ``PATH`` and the LFRic scripts read ``PYTHONPATH``
    and ``COMPILER``.
    """
    result = subprocess.run(
        [str(arg) for arg in argv],
        capture_output=True,
        text=True,
        env={**os.environ, **(env or {})},
        cwd=None if cwd is None else str(cwd),
    )
    output = result.stdout + result.stderr
    print(output.rstrip())
    if result.returncode != 0 and not expect_failure:
        raise RuntimeError(
            f"command failed with exit code {result.returncode}: "
            f"{' '.join(str(a) for a in argv)}"
        )
    return output
