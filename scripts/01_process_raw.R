# =============================================================================
# 01_process_raw.R
# Filter and reshape the three raw federal data sources into NSF-only files
# that the loader (03_load_postgres.R) consumes.
#
# Inputs  (data/raw/):
#   usaspending_nsf/FY{2023..2026}.zip   USAspending Assistance Full bulk
#                                        extracts, pre-filtered to NSF
#                                        (agency code 049). One CSV per zip.
#   grants_gov_all_agencies.csv          Grants.gov bulk XML extract, converted
#                                        to CSV (all agencies, ~82k rows).
#   nsf_terminations.csv                 Citizen-science NSF terminations
#                                        tracker (~2k awards).
#
# Outputs (data/final/):
#   usaspending_nsf.parquet              Concatenated NSF transactions FY23-26
#                                        + an `is_active` column
#                                        (period_of_perf_end >= today).
#   grants_gov_nsf.csv                   NSF-only opportunities (CFDA 47.x or
#                                        AgencyCode LIKE 'NSF%') + `is_active`.
#   nsf_terminations.csv                 Pass-through + `is_active`
#                                        (NOT terminated, OR reinstated).
#
# Why: the schema expects narrow NSF-only inputs with one row per transaction
# (USAspending) / opportunity (Grants.gov) / termination, plus an is_active
# flag derivable per source. Centralizing the three filters here keeps the
# loader (03_load_postgres.R) free of source-specific transformation logic.
#
# Implementation note: uses DuckDB in-memory as the transformation engine.
# Nothing is persisted to disk except the three output files.
# =============================================================================

required_pkgs <- c("DBI", "duckdb", "fs", "glue")
new_pkgs <- required_pkgs[!sapply(required_pkgs, requireNamespace, quietly = TRUE)]
if (length(new_pkgs) > 0) install.packages(new_pkgs)
suppressPackageStartupMessages({ library(DBI); library(duckdb); library(fs); library(glue) })

# Resolve project root: walk up from cwd until we find data/raw/usaspending_nsf/.
find_project_root <- function() {
  d <- normalizePath(getwd(), mustWork = FALSE)
  for (i in 1:6) {
    if (dir.exists(file.path(d, "data", "raw", "usaspending_nsf"))) return(d)
    d <- dirname(d)
  }
  stop("Cannot find project root. Run from im-final/ or its scripts/ subfolder.")
}
PROJECT_ROOT <- find_project_root()
RAW   <- file.path(PROJECT_ROOT, "data", "raw")
FINAL <- file.path(PROJECT_ROOT, "data", "final")
dir_create(FINAL)
message("Project root: ", PROJECT_ROOT)

con <- dbConnect(duckdb(), ":memory:")
dbExecute(con, "PRAGMA threads = 8;")

# -- 1. USAspending: 4 NSF zips -> single parquet ----------------------------
message("\n[1/3] USAspending NSF zips -> usaspending_nsf.parquet")
t0 <- Sys.time()

# Unzip each year's CSV into a working temp dir; DuckDB will read them all
# at once via union_by_name to handle minor schema drift across fiscal years.
extract_dir <- file.path(tempdir(), "usaspending_nsf")
dir_create(extract_dir, recurse = TRUE)
for (z in dir_ls(file.path(RAW, "usaspending_nsf"), glob = "*.zip")) {
  unzip(z, exdir = extract_dir)
}
csv_files <- dir_ls(extract_dir, glob = "*.csv")
message(glue("  unzipped {length(csv_files)} CSV(s)"))

out_parquet <- file.path(FINAL, "usaspending_nsf.parquet")
dbExecute(con, glue("
  COPY (
    SELECT *,
           (period_of_performance_current_end_date >= current_date) AS is_active
    FROM read_csv_auto('{extract_dir}/*.csv',
                       union_by_name = true,
                       sample_size  = -1,
                       ignore_errors = true)
  ) TO '{out_parquet}' (FORMAT PARQUET, COMPRESSION ZSTD);
"))
n <- dbGetQuery(con, glue("SELECT COUNT(*) AS n FROM read_parquet('{out_parquet}')"))$n
message(glue("  wrote {format(n, big.mark=',')} transaction rows ",
             "(took {round(as.numeric(difftime(Sys.time(), t0, units='secs')),1)}s)"))

# -- 2. Grants.gov: all-agency CSV -> NSF-only CSV ---------------------------
message("\n[2/3] Grants.gov all-agency CSV -> grants_gov_nsf.csv")
t0 <- Sys.time()

grants_in  <- file.path(RAW, "grants_gov_all_agencies.csv")
grants_out <- file.path(FINAL, "grants_gov_nsf.csv")

# NSF rows match any of: AgencyName mentions 'national science foundation',
# AgencyCode starts with 'NSF', or CFDANumbers contains '47.' (every NSF
# program lives under CFDA prefix 47.xxx).
dbExecute(con, glue("
  COPY (
    SELECT *,
           (LOWER(COALESCE(record_type,'')) LIKE '%synopsis%'
            OR LOWER(COALESCE(record_type,'')) LIKE '%forecast%') AS is_active
    FROM read_csv_auto('{grants_in}', sample_size = -1, ignore_errors = true)
    WHERE LOWER(AgencyName) LIKE '%national science foundation%'
       OR AgencyCode LIKE 'NSF%'
       OR CFDANumbers LIKE '47.%'
       OR CFDANumbers LIKE '%,47.%'
  ) TO '{grants_out}' (FORMAT CSV, HEADER, QUOTE '\"');
"))
n <- dbGetQuery(con, glue("SELECT COUNT(*) AS n FROM read_csv_auto('{grants_out}')"))$n
message(glue("  wrote {format(n, big.mark=',')} NSF opportunity rows ",
             "(took {round(as.numeric(difftime(Sys.time(), t0, units='secs')),1)}s)"))

# -- 3. NSF terminations: pass-through + is_active ---------------------------
message("\n[3/3] NSF terminations -> nsf_terminations.csv")
t0 <- Sys.time()

terms_in  <- file.path(RAW,   "nsf_terminations.csv")
terms_out <- file.path(FINAL, "nsf_terminations.csv")

# is_active = TRUE if the award is NOT currently terminated, OR has been
# reinstated. Source booleans arrive as strings; cast carefully.
dbExecute(con, glue("
  COPY (
    SELECT *,
           (
             COALESCE(LOWER(CAST(reinstated AS VARCHAR)),'false') = 'true'
             OR COALESCE(LOWER(CAST(terminated AS VARCHAR)),'true') = 'false'
           ) AS is_active
    FROM read_csv_auto('{terms_in}', sample_size = -1, ignore_errors = true)
  ) TO '{terms_out}' (FORMAT CSV, HEADER, QUOTE '\"');
"))
n <- dbGetQuery(con, glue("SELECT COUNT(*) AS n FROM read_csv_auto('{terms_out}')"))$n
n_active <- dbGetQuery(con, glue(
  "SELECT COUNT(*) AS n FROM read_csv_auto('{terms_out}') WHERE is_active"))$n
message(glue("  wrote {format(n, big.mark=',')} terminations ",
             "({format(n_active, big.mark=',')} currently active) ",
             "(took {round(as.numeric(difftime(Sys.time(), t0, units='secs')),1)}s)"))

dbDisconnect(con, shutdown = TRUE)

# Cleanup the unzipped CSVs so the temp dir doesn't grow over re-runs.
unlink(extract_dir, recursive = TRUE)

message("\nDone. Outputs in: ", FINAL)
