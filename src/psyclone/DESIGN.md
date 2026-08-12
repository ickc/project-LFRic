# Design notes: the display helpers and the demo

Internals for `src/psyclone_tour/`. The README says how to run things; this
says why they are the shape they are, and where the sharp edges are.

## Why no cell magic

The Fortran page needed one: a `%%fortran` cell had to become a file, a
compile, a link and a run, with state carried between cells. None of that
applies here. PSyclone is a Python package, so a cell that transforms Fortran
is an ordinary Python cell, and the kernel's own state *is* the session state.

What is left is a presentation problem, which is what `display.py` is.

## The presentation problem

PSyclone hands back two kinds of text, and Jupyter's default rendering is
wrong for both.

**Fortran source** comes back as a `str` from `FortranWriter`. A `print()`
puts it in a `stream` output, which Quarto renders as undifferentiated grey
monospace — for a 120-line generated PSy layer, unreadable. So `show()` wraps
it in a fenced block and emits it as `display_data` with a `text/markdown`
payload. Quarto renders that as a *highlighted code block*, and Fortran gets
lexed properly with no Lua filter needed anywhere.[^lua]

[^lua]: Which is the difference from the Fortran page, where the cells
    themselves are Fortran-in-Python and needed `fortran-highlight.lua` to be
    relabelled. Here the *inputs* really are Python and the Fortran is all
    output, so the highlighting problem moves to the output side and markdown
    display solves it.

**PSyIR trees** come back from `Node.view()`, and are deliberately *not*
highlighted — no lexer improves them. The one thing that must be forced is
`colour=False`. `view()` defaults to ANSI colour codes; those would be
committed into the notebook's stored outputs and rendered as escape-sequence
litter by Quarto, on a page whose outputs are checked in.

### `show()` accepts a path, and why that is a trap worth the comment

`show()` takes a PSyIR node, a `Path`, or source text. It also reads a
single-line `str` that names an existing file, because generated code is
almost always on disk here (`psyclone -opsy /tmp/x.f90`) and
`show("/tmp/x.f90")` is what anyone would write.

That case was added after the first execution of the page rendered three
cells as a one-line code block containing the *filename*. The failure is
silent — no exception, plausible-looking output — which is exactly the kind
of thing a committed-output notebook will carry indefinitely. Hence the
newline test rather than a bare `Path(content).is_file()`: a multi-line
string is source, never a path.

### `diff()` is the main teaching device

Most cells exist to show what a transformation *changed*, and the changed
thing is two `!$omp` lines inside a hundred lines of otherwise identical
generated Fortran. So the default view is a unified diff in a ```diff
fence, with either side accepting a PSyIR node (lowered on the way in). The
usual idiom is:

```python
before = fortran(node)      # snapshot the text
SomeTrans().apply(node)     # mutates in place
diff(before, fortran(node))
```

Snapshotting the *text* matters: transformations mutate the tree, so keeping
a reference to the node gives you the "after" state twice. There is a
`node.copy()`, but the string is cheaper and cannot be got wrong.

### `run()` merges the environment rather than replacing it

Some of PSyclone's behaviour has no in-process entry point — PSyKAl mode
does algorithm rewriting and PSy-layer generation that the CLI orchestrates
— so those parts shell out. `run()` merges its `env` into `os.environ`
because the LFRic scripts read `PYTHONPATH` (to find `psyclone_tools` or
`transmute_functions`) and `COMPILER` (which `get_compiler()` uses to decide
what OpenMP to emit), while PSyclone itself still needs `PATH`. Replacing the
environment wholesale breaks all three.

`expect_failure=True` marks the cells that are supposed to fail, so a
deliberate `Generation Error` renders as intended output rather than
stopping the notebook.

## Paths, and the config file

`paths.py` walks up to the directory holding `.gitmodules`. This keeps
`../../../submodules` out of the page and makes the notebook independent of
the kernel's cwd.

`LFRIC_CONFIG` points at `lfric_core/etc/psyclone.cfg` and is passed to every
PSyKAl-mode invocation. This is not optional decoration: the config defines
the function spaces and `COMPUTE_ANNEXED_DOFS`, and the latter changes the
generated *loop bounds*. Running the LFRic API against PSyclone's default
config produces code that looks right and computes a different set of dofs.

## The demo

`demo/` is a full PSyKAl triplet at a size that fits on a screen. Two
deliberate choices:

**`GH_INC` on `W1`.** A continuous function space is the only configuration
that shows the interesting machinery — colouring, the loop running into the
level-1 halo, the `cmap` indirection. On a discontinuous space PSyclone
generates a plain threaded loop over cells and the example teaches nothing.

**Two invokes, not one.** So that the page can point at the boundary
PSyclone cannot see across, and so that exercise 4 has something to do.

Nothing in `demo/` compiles or runs, and cannot: without the LFRic
infrastructure there is no `field_type`, no mesh and no dofmap. The artifact
under study is the generated source. The runnable miniature of the same
computation is in `src/fortran/demo/`, which hand-writes the PSy layer that
PSyclone generates here.

The `-d kernel` argument is how PSyclone finds kernel *metadata*; it does not
need `field_mod` or `constants_mod` to exist, because the algorithm layer's
`use` statements are never resolved. That is why a self-contained example is
possible at all.

## Known constraints

- **The page writes to `/tmp`.** Deliberately: those files are intermediate
  results shown once and never committed, and putting them in the project
  directory would mean either gitignoring six more patterns or committing
  generated Fortran twice (`demo/build/` already holds the copies worth
  keeping). The cost is that the page is not reproducible on a machine
  without a writable `/tmp`.
- **`Config` is a process-wide singleton.** `psyclone.configuration.Config`
  caches the first configuration loaded, so a notebook that loaded the LFRic
  config in-process would silently apply it to every later cell. The page
  avoids the problem by doing all LFRic-API work through the CLI, which is
  also how LFRic does it — but it is a real trap if you start calling
  `LFRicConstants()` directly from a cell.
- **Version-sensitive output.** The generated Fortran on the page is
  PSyclone 3.3.1's. Bumping the pin will reflow parts of it, and the diffs
  will need re-reading rather than just re-running.
