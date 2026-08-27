# lfric.kolen.dev

A personal wiki and workspace for LFRic RSE work in collaboration with the Met
Office, published at <https://lfric.kolen.dev>.

The site is a [Quarto](https://quarto.org) website built from `src/`, with
[pixi](https://pixi.sh) providing the toolchain, and deployed to
[Cloudflare Pages](https://pages.cloudflare.com) by GitHub Actions.

```bash
git submodule update --init --recursive   # only needed to re-run the notebooks
pixi run serve                            # live preview on http://localhost:8042
pixi run build                            # render src/ into docs/
pixi run linkcheck                        # build, then check every link
```

See [CLAUDE.md](CLAUDE.md) for the layout, the submodules, and how deployment
works.
