# Provider logomarks sourced for this deploy

Patch `0011-provider-icons.patch` adds 54 provider logos plus the `KNOWN_SVGS` /
`KNOWN_PNGS` entries that make `ProviderIcon.tsx` use them.

## Why this exists

v3.8.50 added 55 providers but shipped icon assets for only 7 of them. Counting
every tier `ProviderIcon` can resolve from — `KNOWN_SVGS`, `KNOWN_PNGS`,
`THEMED_SVGS`, `PROVIDER_ICON_ALIASES` and `LOBE_PROVIDER_ALIASES` — the deploy
went from **50 iconless providers out of 220** on v3.8.49 to **78 out of 270**.

Those 78 fell through to tier 5, an external request to
`https://thesvg.org/icons/<id>/default.svg`, which 404s for every one of them,
and then to tier 6's grey circle-with-plus. Two consequences: a third of the
provider list rendered as identical grey placeholders, and every dashboard load
leaked the deploy's provider ids to a third-party CDN.

## Sourcing policy

Ordered by how defensible the provenance is. Nothing is used that fails both:

1. **Simple Icons (CC0-1.0)** — only via the explicit slug map in
   `fetch_icons.py`, never a guessed slug, so a wrong company's mark cannot be
   shipped silently. 5 icons.
2. **The provider's own site** — `<link rel="icon">` from the homepage, then
   `/favicon.svg`, `/icon.svg`, `/logo.svg`, `/apple-touch-icon.png`,
   `/favicon.ico`. 49 icons.

Anything that cannot be sourced this way is **left alone** and keeps rendering
the generic icon. An unattributed or wrong logo is worse than no logo.

These are third-party trademarks used nominatively, to identify the provider each
row routes to. That is the same basis upstream OmniRoute ships its own 225 logos
on — but note upstream is actively *retiring* provider art it cannot attribute
(#11735, #11743, #11750, and the GPL-derived Raycast/Hailuo retirements), so
**expect this patch to conflict with that direction and re-review it at each
upgrade** rather than reapplying blindly.

## Results

| | count |
|---|---|
| iconless on v3.8.50 | 78 |
| fetched | 59 |
| rejected in QC | 5 |
| **shipped** | **54** (32 SVG, 22 PNG) |
| still iconless | 24 |

`icon-provenance.tsv` records the source URL and licence basis for every file,
including the rejections.

### The 5 QC rejections — why automated fetching needs a check

- `chenzk`, `tabitoken` — both `/logo.png`, **byte-identical**. Two unrelated
  vendors serving the same file means it is the default artwork of the gateway
  panel template they both run, not either company's mark.
- `meganova-ai`, `promptql`, `zylo-api` — soft-404s: the site returned its HTML
  index page for `/logo.svg`. The fetcher's original guard only checked that
  `<svg` appeared somewhere in the body, and these pages carry inline SVG. The
  validator now requires the parsed XML **root** element to be `<svg>`.

`g4f-*` (5 files) and `naga-ac`/`naga-ai` are also byte-identical, but legitimately
so — each group shares one origin and one brand.

### The 24 still iconless

Mostly providers with no website to fetch from: CLI/local transports
(`codex-app-server`, `devin-cli-agentic`, `zcode`, `mlx-gemma`, `mlx-qwen`,
`muse-code`), and sites that served no usable icon (`aihorde`, `freeinference`,
`hailuo-web`, `helixmind`, `literouter`, `mixlayer`, `navy`, `sealion`, `speka`,
`tinycms-web`, `void-ai`, `volcengine-*`). They render the generic icon, which is
the correct outcome.

## Re-running

    python3 /var/www/omniroute/tools/provider-icons/fetch_icons.py

Reads `iconless-urls.tsv` (provider id + registry `baseUrl`), writes into
`src/public/providers/` and rewrites `icon-provenance.tsv`. It **overwrites**
existing files, so regenerate `iconless-urls.tsv` from the current registry first
and re-run the QC in this README's "rejections" section afterwards — the fetcher
cannot tell a template default from a real logo on its own.

Allowed without prompting via `Bash(python3 /var/www/omniroute/tools/provider-icons/fetch_icons.py*)`
in `.claude/settings.local.json`.

## Still worth doing

This patch does not remove the tier-5 `thesvg.org` call — the remaining 24
providers still reach it, so the CDN leak is reduced, not closed. Making tier 6
render a coloured two-letter badge and deleting tier 5 outright would fix both
the remaining placeholders and the leak, with no third-party assets at all.
