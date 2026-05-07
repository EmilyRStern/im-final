# `slides/`

Final-presentation deck for EPPS 6354. Quarto reveal.js, themed to match
the [`stern`](https://github.com/EmilyRStern/stern) design-system R package
the dashboard uses.

## Render

```bash
quarto render slides/final.qmd
```

Produces `slides/final.html` plus a `slides/final_files/` assets directory
(both gitignored).

## Present

Open `slides/final.html` in Chrome or Firefox; press `F` for fullscreen.

The deck has two interactive iframe slides:

- **Schema** — embeds [schema.html](schema.html) (entity-relationship
  diagram for the 6-table NSF schema)
- **The Dashboard** — embeds the live Shiny app on Posit Connect

The dashboard slide needs an internet connection. Posit Connect's free tier
sleeps after ~5 min idle, so open
<https://connect.posit.cloud/emilyrstern/content/019df1ae-8f70-b795-8b7a-2be95508a9fa>
once before presenting to warm the app.

## Publish

Pick one:

```bash
quarto publish quarto-pub slides/final.qmd   # public URL on quartopub.com
quarto publish gh-pages   slides/final.qmd   # to EmilyRStern.github.io
quarto publish connect    slides/final.qmd   # to Posit Connect
```

Quarto handles `final_files/` and `schema.html` as deploy assets
automatically.

## PDF backup

Open `slides/final.html?print-pdf` in Chrome → Print → Save as PDF. Iframe
slides render blank in PDF — useful only as a projector-failure fallback.

## Files

- `final.qmd` — the deck
- `stern.scss` — theme tokens mirrored from
  [`stern-pkg/R/palettes.R`](https://github.com/EmilyRStern/stern/blob/main/R/palettes.R)
- `schema.html` — ER diagram embedded by the schema slide
- `.gitignore` — excludes `final.html` and `final_files/` (build output)
- `README.md` — this file
