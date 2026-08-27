---
name: explain
description: Write a personalized, ground-up explainer note for a paper, concept, or system. Use when the user asks to explain something in depth, write study notes, or create a pedagogical companion to a paper ("explain X to me", "help me understand Y", "write a note on Z"). Produces a standalone Quarto/Markdown note in the house style.
---

# Personalized explainer notes

Write a standalone note that *complements* the source rather than summarising it — the user will read the source themselves. Rebuild the subject from the ground up in logical dependency order, not the source's order. Aim for the essence, not coverage: every paragraph either explains a mechanism or builds a bridge to something the reader already knows.

## The reader

Math + Physics bachelor, Physics PhD in CMB data analysis. Fluent (possibly rusty) in: measure theory, topology, differential geometry/forms, functional analysis, statistics (random variables, estimators, likelihood, Fisher information, Gaussian conditioning), and the numerical linear algebra of CMB pipelines (PCG map-making, destriping, Wiener filtering, pseudo-Cℓ coupling matrices, HEALPix). Also knows JAX (jit/jaxpr/remat). Rusty is not naive: define terms once, precisely; never hand-hold arithmetic.

## Form

- Title + italic subtitle: *A personal note for the mathematically conversant but possibly rusty.*
- Numbered `##` sections separated by `---` rules; display math; notation defined at first use.
- **Footnotes, not blockquotes**, for asides, etymology, history, and cross-field terminology bridges. Footnotes may be substantial mini-paragraphs.
- A **summary table** at the end (Concept ↔ Formal representation ↔ Bridge), plus, for paper companions, a note-section ↔ source-section reading map.
- British spelling. Single-line paragraphs (no hard wrapping).

## Pedagogy

- General case first, then specialise. State the unifying idea in one sentence early ("The essence").
- **Bridge terminology across fields** — probability ↔ statistics ↔ physics ↔ ML. Bridges that have landed: softmax ↔ Boltzmann; Adam ↔ Fisher/inverse-variance weighting; halo exchange ↔ Markov blanket; Schur complement ↔ Gaussian marginalisation; preconditioning ↔ whitening; mesh colouring ↔ chromatic Gibbs sampling; code generation ↔ JAX jit/jaxpr.
- **Attribute precisely.** Distinguish the source's claims from your own readings: mark interpretive arithmetic and analogies *(gloss)*. Attribute simplifications exactly (e.g. "W = I", not "d_model = V").
- Explain jargon via math, not code; show code only when the artifact itself is code, and then walk through it.
- Note etymology on first use of named things (logit, Krylov, CFL, …) — in footnotes.

## Conventions

- Iverson bracket $[P]$ (Knuth), not $\mathbb{1}[P]$.
- $J$ for cost/loss (avoid clash with likelihood $L$); $\ell$ for log-likelihood.
- "Array"/"matrix", not "tensor", unless a geometric transformation law applies.
- Physicist index notation is welcome (upper coordinate indices, lower time indices).

## Style references

- `tokenization_notes.md` and `adamw_notes.md`, in the user's notes repo outside this project — the canonical examples.
- `src/paper-explained.qmd` in this repo — a full paper companion in this style.
