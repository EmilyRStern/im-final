# =============================================================================
# 03_load_postgres.R
# Load the NSF-filtered files in data/final/ into the Neon Postgres tables
# created by 02_setup_postgres.R.
#
# Inputs (data/final/):
#   usaspending_nsf.parquet    one row per USAspending transaction (FY23-26)
#   grants_gov_nsf.csv         one row per NSF Grants.gov opportunity
#   nsf_terminations.csv       one row per NSF termination event
#
# Outputs: populated tables on Neon (recipients, opportunities, awards,
#          transactions, terminations). agencies is left alone (seeded by DDL).
#
# Load order respects FKs:
#   1. recipients     (distinct UEIs from the parquet)
#   2. opportunities  (from the Grants.gov CSV)
#   3. awards         (transactions aggregated to one row per award)
#   4. transactions   (full transaction-level rows, FK -> awards)
#   5. terminations   (FK -> awards.award_id_fain; non-matches stored with NULL FK)
#
# Why a DuckDB in-memory step: the parquet/CSV reads + GROUP BY + window
# functions used to build the awards aggregate are an order of magnitude
# faster in DuckDB than in dplyr, and the SQL is more compact. Nothing is
# persisted to disk; DuckDB is purely a transformation engine here.
#
# Safe to re-run: TRUNCATE ... RESTART IDENTITY CASCADE clears the data tables
# (NOT agencies) before each insert.
# =============================================================================

required_pkgs <- c("RPostgres", "DBI", "duckdb", "glue", "dplyr")
new_pkgs <- required_pkgs[!sapply(required_pkgs, requireNamespace, quietly = TRUE)]
if (length(new_pkgs) > 0) install.packages(new_pkgs)
suppressPackageStartupMessages({
  library(RPostgres); library(DBI); library(duckdb); library(glue); library(dplyr)
})

# Resolve project root and load .Renviron from there.
find_project_root <- function() {
  d <- normalizePath(getwd(), mustWork = FALSE)
  for (i in 1:6) {
    if (file.exists(file.path(d, ".Renviron"))) return(d)
    d <- dirname(d)
  }
  stop("Cannot find .Renviron. Run from im-final/ or its scripts/ subfolder.")
}
PROJECT_ROOT <- find_project_root()
readRenviron(file.path(PROJECT_ROOT, ".Renviron"))

FINAL   <- file.path(PROJECT_ROOT, "data", "final")
PARQUET <- file.path(FINAL, "usaspending_nsf.parquet")
GRANTS  <- file.path(FINAL, "grants_gov_nsf.csv")
TERMS   <- file.path(FINAL, "nsf_terminations.csv")
stopifnot(file.exists(PARQUET), file.exists(GRANTS), file.exists(TERMS))

# Connect to Neon.
parse_pg_url <- function(url) {
  m <- regmatches(url, regexec(
    "^postgres(?:ql)?://([^:]+):([^@]+)@([^:/]+)(?::(\\d+))?/([^?]+)(?:\\?(.*))?$", url))[[1]]
  list(user = m[2], password = m[3], host = m[4],
       port = if (nzchar(m[5])) as.integer(m[5]) else 5432L, dbname = m[6])
}
p <- parse_pg_url(Sys.getenv("NEON_DB_URL"))
pg <- dbConnect(Postgres(), host = p$host, port = p$port, dbname = p$dbname,
                user = p$user, password = p$password, sslmode = "require")
message("Connected to Neon: ", p$host, " / ", p$dbname)

# In-memory DuckDB for the heavy reads + transformations.
duck <- dbConnect(duckdb(), ":memory:")
dbExecute(duck, "PRAGMA threads = 8;")

# Fresh load: clear the data tables (keep agencies + its seed rows).
message("Clearing data tables (keeping agencies)...")
dbExecute(pg, "TRUNCATE transactions, terminations, awards, change_log,
                       snapshots, opportunities, recipients
               RESTART IDENTITY CASCADE;")

# CFDA number -> NSF directorate lookup, used in the awards aggregate and the
# transactions select below. Inlined in both places (rather than DRY'd) to
# keep each SQL statement readable on its own.
# Reference: NSF Assistance Listings catalog.

# -- 1. recipients -----------------------------------------------------------
message("\n[1/5] recipients")
t0 <- Sys.time()
recipients_df <- dbGetQuery(duck, glue("
  SELECT DISTINCT
    recipient_uei,
    FIRST(recipient_name        ORDER BY action_date DESC) AS recipient_name,
    NULL::VARCHAR                                          AS parent_uei,
    FIRST(recipient_state_code  ORDER BY action_date DESC) AS state_code,
    FIRST(recipient_city_name   ORDER BY action_date DESC) AS city_name,
    FIRST(recipient_county_name ORDER BY action_date DESC) AS county_name,
    FIRST(recipient_zip_code    ORDER BY action_date DESC) AS zip_code
  FROM read_parquet('{PARQUET}')
  WHERE recipient_uei IS NOT NULL AND recipient_uei <> ''
  GROUP BY recipient_uei
"))
dbWriteTable(pg, "recipients", recipients_df, append = TRUE, row.names = FALSE)
message(glue("  {format(nrow(recipients_df), big.mark=',')} rows ",
             "({round(as.numeric(difftime(Sys.time(), t0, units='secs')), 1)}s)"))

# -- 2. opportunities --------------------------------------------------------
message("\n[2/5] opportunities")
t0 <- Sys.time()
opps_df <- dbGetQuery(duck, glue("
  SELECT
    CAST(OpportunityID AS VARCHAR)                   AS opportunity_id,
    1                                                AS agency_id,
    OpportunityNumber                                AS opportunity_number,
    OpportunityTitle                                 AS title,
    CFDANumbers                                      AS cfda_numbers,
    PostDate                                         AS post_date,
    TRY_CAST(CloseDate    AS DATE)                   AS close_date,
    TRY_CAST(ArchiveDate  AS DATE)                   AS archive_date,
    TRY_CAST(EstimatedTotalProgramFunding AS DOUBLE) AS estimated_total_funding,
    TRY_CAST(AwardCeiling AS DOUBLE)                 AS award_ceiling,
    TRY_CAST(AwardFloor   AS DOUBLE)                 AS award_floor,
    Description                                      AS description,
    is_active,
    NULL::INTEGER                                    AS first_seen_snapshot_id,
    NULL::INTEGER                                    AS last_seen_snapshot_id
  FROM read_csv_auto('{GRANTS}', sample_size=-1, ignore_errors=true)
  WHERE OpportunityID IS NOT NULL
  -- An opportunity may exist as both a Forecast and a Synopsis row; keep the
  -- synopsis copy (the binding version) and otherwise the most-recently-updated.
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY OpportunityID
    ORDER BY CASE WHEN LOWER(record_type) LIKE '%synopsis%' THEN 0 ELSE 1 END,
             LastUpdatedDate DESC NULLS LAST
  ) = 1
"))
dbWriteTable(pg, "opportunities", opps_df, append = TRUE, row.names = FALSE)
message(glue("  {format(nrow(opps_df), big.mark=',')} rows ",
             "({round(as.numeric(difftime(Sys.time(), t0, units='secs')), 1)}s)"))

# -- 3. awards (aggregate transactions -> one row per award) -----------------
message("\n[3/5] awards")
t0 <- Sys.time()
awards_df <- dbGetQuery(duck, glue("
  WITH tx AS (
    SELECT * FROM read_parquet('{PARQUET}')
    WHERE assistance_award_unique_key IS NOT NULL
      AND recipient_uei IS NOT NULL AND recipient_uei <> ''
  )
  SELECT
    assistance_award_unique_key                  AS award_unique_key,
    ANY_VALUE(award_id_fain)                     AS award_id_fain,
    ANY_VALUE(recipient_uei)                     AS recipient_uei,
    1                                            AS awarding_agency_id,
    CASE ANY_VALUE(cfda_number)
      WHEN '47.041' THEN 'ENG' WHEN '47.049' THEN 'MPS'
      WHEN '47.050' THEN 'GEO' WHEN '47.070' THEN 'CISE'
      WHEN '47.074' THEN 'BIO' WHEN '47.075' THEN 'SBE'
      WHEN '47.076' THEN 'EDU' WHEN '47.078' THEN 'OPP'
      WHEN '47.079' THEN 'OD'  WHEN '47.083' THEN 'OIA'
      WHEN '47.084' THEN 'TIP' ELSE 'OTHER'
    END                                          AS awarding_sub_agency_name,
    ANY_VALUE(cfda_number)                       AS cfda_number,
    ANY_VALUE(cfda_title)                        AS cfda_title,
    MAX(total_obligated_amount)                  AS total_obligated_amount,
    MAX(total_outlayed_amount_for_overall_award) AS total_outlayed_amount,
    MIN(period_of_performance_start_date)        AS period_of_perf_start,
    MAX(period_of_performance_current_end_date)  AS period_of_perf_end,
    MAX(action_date)                             AS action_date,
    ANY_VALUE(transaction_description)           AS description,
    (MAX(period_of_performance_current_end_date) >= current_date) AS is_active
  FROM tx
  GROUP BY assistance_award_unique_key
  HAVING ANY_VALUE(award_id_fain) IS NOT NULL
"))

# Defensive: dedup on the FAIN unique-key before insert; drop awards whose
# recipient_uei isn't in the recipients table (FK).
awards_df <- awards_df |> distinct(award_id_fain, .keep_all = TRUE)
recipient_uei_set <- dbGetQuery(pg, "SELECT recipient_uei FROM recipients")$recipient_uei
n_before <- nrow(awards_df)
awards_df <- awards_df |> filter(recipient_uei %in% recipient_uei_set)
if (nrow(awards_df) < n_before)
  message(glue("  dropped {n_before - nrow(awards_df)} awards with no matching recipient"))
awards_df$pulled_at <- Sys.time()
dbWriteTable(pg, "awards", awards_df, append = TRUE, row.names = FALSE)
message(glue("  {format(nrow(awards_df), big.mark=',')} rows ",
             "({round(as.numeric(difftime(Sys.time(), t0, units='secs')), 1)}s)"))

# -- 4. transactions ---------------------------------------------------------
message("\n[4/5] transactions")
t0 <- Sys.time()
tx_df <- dbGetQuery(duck, glue("
  SELECT
    assistance_transaction_unique_key AS transaction_unique_key,
    assistance_award_unique_key       AS award_unique_key,
    award_id_fain,
    recipient_uei,
    cfda_number,
    CASE cfda_number
      WHEN '47.041' THEN 'ENG' WHEN '47.049' THEN 'MPS'
      WHEN '47.050' THEN 'GEO' WHEN '47.070' THEN 'CISE'
      WHEN '47.074' THEN 'BIO' WHEN '47.075' THEN 'SBE'
      WHEN '47.076' THEN 'EDU' WHEN '47.078' THEN 'OPP'
      WHEN '47.079' THEN 'OD'  WHEN '47.083' THEN 'OIA'
      WHEN '47.084' THEN 'TIP' ELSE 'OTHER'
    END                               AS awarding_sub_agency_name,
    action_date,
    action_type_description,
    federal_action_obligation,
    assistance_type_description,
    transaction_description
  FROM read_parquet('{PARQUET}')
  WHERE assistance_transaction_unique_key IS NOT NULL
"))
award_keys <- dbGetQuery(pg, "SELECT award_unique_key FROM awards")$award_unique_key
n_before <- nrow(tx_df)
tx_df <- tx_df |> filter(award_unique_key %in% award_keys) |>
                  distinct(transaction_unique_key, .keep_all = TRUE)
if (nrow(tx_df) < n_before)
  message(glue("  dropped {n_before - nrow(tx_df)} transactions with no matching award or duplicate key"))
dbWriteTable(pg, "transactions", tx_df, append = TRUE, row.names = FALSE)
message(glue("  {format(nrow(tx_df), big.mark=',')} rows ",
             "({round(as.numeric(difftime(Sys.time(), t0, units='secs')), 1)}s)"))

# -- 5. terminations ---------------------------------------------------------
message("\n[5/5] terminations")
t0 <- Sys.time()
terms_df <- dbGetQuery(duck, glue("
  SELECT
    CAST(grant_id AS VARCHAR)                         AS award_id_fain,
    project_title,
    status                                            AS current_status,
    termination_date                                  AS latest_termination_date,
    reinstated,
    TRY_CAST(reinstatement_date AS DATE)              AS reinstatement_date,
    TRY_CAST(post_termination_deobligation AS DOUBLE) AS post_termination_deobligation,
    TRY_CAST(nsf_total_budget AS DOUBLE)              AS nsf_total_budget,
    TRY_CAST(estimated_remaining AS DOUBLE)           AS estimated_remaining,
    directorate, division, nsf_program_name,
    is_active
  FROM read_csv_auto('{TERMS}', sample_size=-1, ignore_errors=true)
"))
# FK to awards.award_id_fain: NULL out non-matches so the FK accepts the row.
fain_set <- dbGetQuery(pg, "SELECT award_id_fain FROM awards")$award_id_fain
n_match  <- sum(terms_df$award_id_fain %in% fain_set, na.rm = TRUE)
terms_df$award_id_fain[!terms_df$award_id_fain %in% fain_set] <- NA
dbWriteTable(pg, "terminations", terms_df, append = TRUE, row.names = FALSE)
message(glue("  {format(nrow(terms_df), big.mark=',')} rows ",
             "({format(n_match, big.mark=',')} matched to an award) ",
             "({round(as.numeric(difftime(Sys.time(), t0, units='secs')), 1)}s)"))

# -- Summary -----------------------------------------------------------------
counts <- dbGetQuery(pg, "
  SELECT 'agencies'      AS tbl, COUNT(*) AS n FROM agencies      UNION ALL
  SELECT 'recipients',         COUNT(*)        FROM recipients    UNION ALL
  SELECT 'opportunities',      COUNT(*)        FROM opportunities UNION ALL
  SELECT 'awards',             COUNT(*)        FROM awards        UNION ALL
  SELECT 'transactions',       COUNT(*)        FROM transactions  UNION ALL
  SELECT 'terminations',       COUNT(*)        FROM terminations  UNION ALL
  SELECT 'change_log',         COUNT(*)        FROM change_log    UNION ALL
  SELECT 'snapshots',          COUNT(*)        FROM snapshots
  ORDER BY tbl;")
message("\n=== Final row counts on Neon ===")
print(counts)

dbDisconnect(duck, shutdown = TRUE)
dbDisconnect(pg)
message("Done.")
