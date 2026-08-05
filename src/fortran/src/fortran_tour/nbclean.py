"""Strip volatile metadata from an executed notebook.

``jupyter execute`` stamps every cell with ``metadata.execution`` timestamps.
The notebook is committed — it is the file Quarto renders — so those timestamps
would show up as a diff on every re-run, and Quarto copies them into the HTML
as ``data-quarto-private`` attributes.  Neither is wanted.

Usage::

    python -m fortran_tour.nbclean index.ipynb
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

# Cell metadata keys that change from run to run, or that only an editor cares
# about.
VOLATILE = ("execution", "vscode", "collapsed", "scrolled")


def clean(path: Path) -> bool:
    """Rewrite *path* in place; return True if anything changed."""
    original = path.read_text()
    nb = json.loads(original)

    for cell in nb.get("cells", []):
        meta = cell.get("metadata", {})
        for key in VOLATILE:
            meta.pop(key, None)
        # Output-bearing cells keep their execution_count so Quarto can show
        # the In[n] ordering, but any output-level metadata is noise.
        for output in cell.get("outputs", []):
            output.get("metadata", {}).pop("execution", None)

    # `signature` and `widgets` are the other usual sources of churn.
    nb.get("metadata", {}).pop("widgets", None)

    cleaned = json.dumps(nb, indent=1, ensure_ascii=False) + "\n"
    if cleaned == original:
        return False
    path.write_text(cleaned)
    return True


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if not args:
        print(__doc__, file=sys.stderr)
        return 2
    for name in args:
        path = Path(name)
        changed = clean(path)
        print(f"{path}: {'cleaned' if changed else 'already clean'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
