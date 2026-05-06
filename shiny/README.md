# `shiny/`

The NSF Grant Lifecycle Disruption Analysis dashboard. Reads from Neon
Postgres at runtime and renders five tabs (Timeline, Lifecycle, Impact,
Recovery, Methods) themed with the `stern` design-system R package.

## Run locally

```r
# from the project root
shiny::runApp("shiny/")
```

The app reads `NEON_DB_URL` from `.Renviron` at the project root. That
file is gitignored — see the project root's [README.md](../README.md)
for how to set it up.

## Deploy to shinyapps.io

```r
# 1. one-time auth (token from https://www.shinyapps.io/admin/#/tokens)
rsconnect::setAccountInfo(name="<account>", token="<token>", secret="<secret>")

# 2. forward the env var to the deploy target as a server-side secret
Sys.setenv(NEON_DB_URL = readRenviron("../.Renviron")["NEON_DB_URL"])

# 3. deploy
rsconnect::deployApp(
  appDir       = "shiny/",
  appName      = "nsf-disruption",
  appTitle     = "NSF Grant Lifecycle Disruption Analysis",
  appFiles     = c("app.R", "_helpers.R", "us-all.geo.json"),  # don't push .Renviron
  forceUpdate  = TRUE,
  envVars      = "NEON_DB_URL"
)
```

`envVars = "NEON_DB_URL"` tells rsconnect to forward the value of that
env var to shinyapps.io as a server-side secret. It is not visible in the
deployed app code, only available to the running R process.

After the first deploy, the env var can also be set in the shinyapps.io
dashboard: **Applications → nsf-disruption → Settings → Variables**.

## Files

- `app.R` — the dashboard
- `_helpers.R` — CFDA-to-directorate and project-title-to-topic
  mappings, also sourced by the pipeline scripts in [`scripts/`](../scripts/)
- `us-all.geo.json` — US states GeoJSON for the choropleth (cached
  locally because the highcharts CDN blocks R's default User-Agent)
- `README.md` — this file

## Common issues

**"NEON_DB_URL not set."** — `.Renviron` is not being found. Make sure it
sits at the project root (one level up from `shiny/`) and contains
`NEON_DB_URL=postgresql://...`.

**Slow first load** — Neon's free tier auto-pauses after ~5 min idle.
The first request after a pause waits 2–5 s for the database to spin
back up. Subsequent queries are cached cross-session via `bindCache`.

**`stern` not found on deploy** — The package needs to be installable
from the same source on shinyapps.io as locally. It's hosted on GitHub
and `app.R` already calls `remotes::install_github("EmilyRStern/stern",
upgrade = "never")` if missing. Alternatively, commit a `renv.lock`
that pins the source.
