# NSF Grant Lifecycle Disruption Analysis

> EPPS 6354 — Information Management — Spring 2026
> University of Texas at Dallas — Emily Stern

A relational database, ingestion pipeline, and Shiny dashboard that
quantify how National Science Foundation grant funding has been
disrupted since the **April 30, 2025 funding freeze** and the
subsequent **EO 14332** (*Improving Oversight of Federal Grantmaking*,
Aug 7, 2025). Three federal data sources are joined into a single
6-table Postgres schema and visualized through five lifecycle-themed
tabs (Timeline, Lifecycle, Impact, Recovery, Methods).

## Research question

> How has NSF grant activity changed since the April 30, 2025 funding
> freeze — across the full lifecycle of opportunities posted, awards
> obligated, awards terminated, and terminations reinstated — and which
> directorates, programs, and recipients absorbed the largest share of
> the disruption?

## Data sources

| Source | What it provides | Acquired |
|---|---|---|
| **USAspending.gov** | Transaction-level NSF assistance award data, FY23–FY26 | Bulk Assistance Full extracts, agency code 049, downloaded 2026-04-06 |
| **Grants.gov** | NSF opportunity listings (posted, forecasted, archived) | Bulk XML extract from grants.gov, downloaded 2026-04-29 |
| **Grant Watch (NSF terminations)** | Citizen-science tracker of awards terminated, frozen, or reinstated under the new administration; maintained by Noam Ross (rOpenSci) and Scott Delaney (Harvard) | CSV export |

## Stack

```
R pipeline ──► data/final/ files ──► Neon Postgres ──► Shiny on shinyapps.io
```

- **Pipeline:** R scripts in [scripts/](scripts/) using DuckDB in-memory
  for CSV/parquet transformation
- **Database:** [Neon](https://neon.tech) Postgres (free tier,
  auto-pauses after ~5 min idle)
- **Dashboard:** Shiny app in [shiny/](shiny/), themed with the
  [`stern`](https://github.com/EmilyRStern/stern) design-system R
  package and deployed to [shinyapps.io](https://www.shinyapps.io)

## Repository layout

```
im-final/
├── README.md                       this file
├── .Renviron                       (gitignored) NEON_DB_URL
├── .gitignore
├── data/
│   ├── README.md                   raw vs. final data conventions
│   ├── raw/                        (gitignored) as-downloaded source files
│   └── final/                      (gitignored) filtered NSF-only loader inputs
├── scripts/
│   ├── README.md                   pipeline overview
│   ├── 01_process_raw.R            raw → final (per-source filter / shape)
│   ├── 02_setup_postgres.R         apply 6-table schema + views to Neon
│   ├── 03_load_postgres.R          load data/final/ → Neon
│   └── 99_run_pipeline.R           orchestrator
├── schema_design/                  ER diagram, schema writeup, sample queries
├── shiny/
│   ├── README.md                   how to run / deploy
│   ├── app.R                       the dashboard
│   └── us-all.geo.json             cached US states GeoJSON for choropleth
├── SternProposal.pdf               original project proposal
├── SternProposalPresentation.pdf
└── epps6354_26s_syllabus.pdf
```

## Setup

1. Install R (≥ 4.3) and the packages each script lists at the top
   (the scripts auto-install missing packages on first run).
2. Create a free Neon Postgres database at <https://neon.tech>.
3. Save the connection string to `.Renviron` at the project root:
   ```
   NEON_DB_URL=postgresql://user:pass@host.neon.tech/dbname?sslmode=require
   ```
4. Acquire the raw data files into `data/raw/` (see
   [data/README.md](data/README.md) for source URLs and filtering).
   The `data/raw/` directory is gitignored because the bulk extracts
   are too large for GitHub.

## Running the pipeline

```r
# from the project root, in R
source("scripts/99_run_pipeline.R")
```

This will:
1. Filter and reshape every raw source into NSF-only files in `data/final/`
2. Apply the 6-table schema (and analytical views) to Neon
3. Load `data/final/` into the Neon tables

A timestamped log lands in `data/pipeline_log_*.txt` (also gitignored).

## Running the dashboard

```r
shiny::runApp("shiny/")
```

See [shiny/README.md](shiny/README.md) for deployment to shinyapps.io.

## Schema

Six tables: `agencies`, `recipients`, `opportunities`, `awards`,
`transactions`, `terminations`, plus a `change_log` audit table for
future Grants.gov snapshot diffs. See
[schema_design/schema_writeup.md](schema_design/schema_writeup.md) for
the full design rationale and
[schema_design/er_diagram.html](schema_design/er_diagram.html) for the
visual.

## Methodology notes

- **Anchored on Apr 30, 2025 funding freeze.** EO 14332 (Aug 7, 2025)
  follows the operational shock and formalizes oversight; the freeze
  itself is the first observable disruption to the grant pipeline.
- **At-risk pool denominators.** Lifecycle-tab rates are computed
  against awards with USAspending activity post-Apr 2025 or in the
  citizen tracker — pre-disruption-completed awards are excluded.
- **Positive vs. negative obligations are kept separate.** USAspending
  records deobligations as negative `federal_action_obligation`. Net
  obligation can hide disruption (e.g., $100M new + $50M clawback ≠
  "$50M"). Views split `gross_obligated` from `gross_deobligated`.
- **Same-month FY23–25 baseline.** The Timeline tab compares FY26
  monthly totals against the mean ±1σ of the same calendar month in
  FY23, FY24, and FY25 — controlling for NSF's annual August-spike,
  October-trough cycle.
- **Citizen-tracker undercount detection.** The Lifecycle tab's
  "possible untracked disruption" segment cross-references USAspending
  transactions to flag awards with >$100K post-Apr 2025 net
  deobligation but no termination record in the tracker.

## Differentiating contribution

This dashboard builds on Grant Watch (Ross + Delaney) and the Urban
Institute's July 2025 keyword-cancellation breakdown
([article](https://www.urban.org/urban-wire/nsf-has-canceled-more-1500-grants-nearly-90-percent-were-related-dei)).
It extends both with: (1) the NEW-obligation pre-award drop per
directorate; (2) a same-month FY23–25 seasonal baseline; (3)
reinstatement dynamics post-cancellation; (4) USAspending
cross-validation surfacing likely tracker undercount.
