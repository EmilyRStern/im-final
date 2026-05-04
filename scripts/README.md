# `scripts/`

Four R scripts that take raw federal data and end with a populated Neon
Postgres database. Each script is self-contained: it has a header
explaining what it consumes, what it produces, and why it exists.

| Script | Inputs | Outputs |
|---|---|---|
| `01_process_raw.R` | `data/raw/usaspending_nsf/*.zip`, `data/raw/grants_gov_all_agencies.csv`, `data/raw/nsf_terminations.csv` | `data/final/usaspending_nsf.parquet`, `data/final/grants_gov_nsf.csv`, `data/final/nsf_terminations.csv` |
| `02_setup_postgres.R` | `NEON_DB_URL` (env var) | 6 tables + 9 analytical views on Neon; agencies seeded |
| `03_load_postgres.R` | the three files in `data/final/`, `NEON_DB_URL` | populated tables on Neon |
| `99_run_pipeline.R` | — | runs steps 1->2->3 in order; logs to `data/pipeline_log_*.txt` |

## Running

From the project root:

```r
source("scripts/99_run_pipeline.R")   # full rebuild
```

Or run any one step on its own:

```r
source("scripts/02_setup_postgres.R") # reapply schema only
```

Each script can be re-run safely:

- `01_process_raw.R` overwrites the three files in `data/final/`
- `02_setup_postgres.R` uses `CREATE TABLE IF NOT EXISTS` and
  `CREATE OR REPLACE VIEW` throughout
- `03_load_postgres.R` does `TRUNCATE ... RESTART IDENTITY CASCADE` on the
  data tables before each insert (it leaves `agencies` alone)

## Why this shape

The pipeline used to also write to a local DuckDB file as an intermediate
"staging" database. That step has been removed: Neon is now the single
source of truth, and DuckDB is used only as an in-memory transformation
engine inside the scripts (it scans CSVs and parquet faster than dplyr,
nothing more).

The original pipeline also pulled from the live Grants.gov and USAspending
APIs. With NSF scope and bulk extracts available, API ingestion was
removed in favor of the simpler bulk-file path.

## Future work

- A `04_diff_snapshots.R` step that compares the current Grants.gov pull
  against the prior snapshot and appends `ADDED`/`REMOVED`/`MODIFIED`
  rows to `change_log`. The schema already supports this; a recurring
  pipeline run would populate the `v_rescinded_opportunities` view.
