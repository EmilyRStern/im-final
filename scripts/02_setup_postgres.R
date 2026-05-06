# =============================================================================
# 02_setup_postgres.R
# Apply the 6-table NSF schema (per schema_design/schema_writeup.md) to Neon
# Postgres. Reads NEON_DB_URL from the project .Renviron.
#
# Inputs:  NEON_DB_URL (env var, set in .Renviron at the project root)
# Outputs: Tables and analytical views on Neon. Seeds the agencies table
#          with NSF + 11 directorates.
#
# Tables created (in FK-safe order):
#   agencies, opportunities, snapshots, change_log, recipients,
#   awards, transactions, terminations
#
# Analytical views created (read-only, derived from the above):
#   v_rescinded_opportunities          opportunities REMOVED with no matching award
#   v_disruption_by_directorate        terminated awards / deobligated $ per dir
#   v_disruption_by_recipient          terminated awards / deobligated $ per UEI
#   v_awards_with_quality              per-award reporting-status flags
#   v_disbursement_progress            % obligated $ disbursed (excludes NULLs)
#   v_active_funding                   active-portfolio summary by directorate
#   v_currently_open_opportunities     posted/forecasted opps with directorate
#   v_directorate_resilience           FY25-vs-FY26 H1 NEW-award retention
#   v_monthly_obligations              monthly gross obligated / deobligated
#
# Why: the Shiny app and the loader both expect this schema to already exist.
# Run this once on a fresh Neon DB, or re-run safely (every CREATE uses
# IF NOT EXISTS or OR REPLACE; the agencies seed uses ON CONFLICT DO NOTHING).
# =============================================================================

required_pkgs <- c("RPostgres", "DBI")
new_pkgs <- required_pkgs[!sapply(required_pkgs, requireNamespace, quietly = TRUE)]
if (length(new_pkgs) > 0) install.packages(new_pkgs)
suppressPackageStartupMessages({ library(RPostgres); library(DBI) })

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
source(file.path(PROJECT_ROOT, "shiny", "_helpers.R"))

url <- Sys.getenv("NEON_DB_URL")
if (!nzchar(url)) stop("NEON_DB_URL not set in .Renviron")

# Parse postgresql://user:pass@host[:port]/dbname[?...] into named parts.
parse_pg_url <- function(url) {
  m <- regmatches(url, regexec(
    "^postgres(?:ql)?://([^:]+):([^@]+)@([^:/]+)(?::(\\d+))?/([^?]+)(?:\\?(.*))?$", url))[[1]]
  list(user = m[2], password = m[3], host = m[4],
       port = if (nzchar(m[5])) as.integer(m[5]) else 5432L, dbname = m[6])
}
p <- parse_pg_url(url)
con <- dbConnect(Postgres(),
  host = p$host, port = p$port, dbname = p$dbname,
  user = p$user, password = p$password, sslmode = "require")
message("Connected to Neon: ", p$host, " / ", p$dbname,
        " (", dbGetQuery(con, "SHOW server_version")[[1]], ")")

# -- 1. agencies (NSF top + 11 directorates) ---------------------------------
dbExecute(con, "
CREATE TABLE IF NOT EXISTS agencies (
  agency_id          INTEGER PRIMARY KEY,
  agency_code        VARCHAR NOT NULL UNIQUE,
  agency_name        VARCHAR NOT NULL,
  agency_level       VARCHAR,
  parent_agency_id   INTEGER REFERENCES agencies(agency_id)
);
")
# Seed NSF top first (self-FK target) then directorates.
dbExecute(con, "
INSERT INTO agencies (agency_id, agency_code, agency_name, agency_level, parent_agency_id)
VALUES (1, 'NSF', 'National Science Foundation', 'top', NULL)
ON CONFLICT (agency_id) DO NOTHING;
")
dbExecute(con, "
INSERT INTO agencies (agency_id, agency_code, agency_name, agency_level, parent_agency_id) VALUES
  (2,  'NSF-BIO', 'Biological Sciences',                                'sub', 1),
  (3,  'NSF-CSE', 'Computer and Information Science and Engineering',   'sub', 1),
  (4,  'NSF-EDU', 'STEM Education',                                     'sub', 1),
  (5,  'NSF-ENG', 'Engineering',                                        'sub', 1),
  (6,  'NSF-GEO', 'Geosciences',                                        'sub', 1),
  (7,  'NSF-MPS', 'Mathematical and Physical Sciences',                 'sub', 1),
  (8,  'NSF-SBE', 'Social, Behavioral, and Economic Sciences',          'sub', 1),
  (9,  'NSF-TIP', 'Technology, Innovation, and Partnerships',           'sub', 1),
  (10, 'NSF-OIA', 'Integrative Activities',                             'sub', 1),
  (11, 'NSF-OPP', 'Polar Programs',                                     'sub', 1),
  (12, 'NSF-OD',  'Office of the Director',                             'sub', 1)
ON CONFLICT (agency_id) DO NOTHING;
")

# -- 2. opportunities --------------------------------------------------------
dbExecute(con, "
CREATE TABLE IF NOT EXISTS opportunities (
  opportunity_id            VARCHAR PRIMARY KEY,
  agency_id                 INTEGER REFERENCES agencies(agency_id),
  opportunity_number        VARCHAR,
  title                     VARCHAR NOT NULL,
  cfda_numbers              VARCHAR,        -- comma-separated; multiple CFDAs ok
  post_date                 DATE,
  close_date                DATE,
  archive_date              DATE,
  estimated_total_funding   DOUBLE PRECISION,
  award_ceiling             DOUBLE PRECISION,
  award_floor               DOUBLE PRECISION,
  description               TEXT,
  is_active                 BOOLEAN DEFAULT TRUE,
  first_seen_snapshot_id    INTEGER,
  last_seen_snapshot_id     INTEGER
);
")

# -- 3. snapshots + change_log (audit pair, populated by future diff runs) ---
dbExecute(con, "
CREATE TABLE IF NOT EXISTS snapshots (
  snapshot_id    INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  snapshot_date  TIMESTAMPTZ NOT NULL DEFAULT now(),
  source         VARCHAR DEFAULT 'grants.gov',
  record_count   INTEGER,
  notes          VARCHAR
);
")
dbExecute(con, "
CREATE TABLE IF NOT EXISTS change_log (
  change_id      INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  opportunity_id VARCHAR NOT NULL REFERENCES opportunities(opportunity_id),
  snapshot_id    INTEGER REFERENCES snapshots(snapshot_id),
  snapshot_date  TIMESTAMPTZ DEFAULT now(),
  change_type    VARCHAR NOT NULL CHECK (change_type IN ('ADDED','REMOVED','MODIFIED')),
  field_changed  VARCHAR,
  old_value      VARCHAR,
  new_value      VARCHAR,
  detected_at    TIMESTAMPTZ DEFAULT now()
);
")

# -- 4. recipients -----------------------------------------------------------
dbExecute(con, "
CREATE TABLE IF NOT EXISTS recipients (
  recipient_uei  VARCHAR PRIMARY KEY,
  recipient_name VARCHAR,
  parent_uei     VARCHAR REFERENCES recipients(recipient_uei),
  state_code     VARCHAR,
  city_name      VARCHAR,
  county_name    VARCHAR,
  zip_code       VARCHAR
);
")

# -- 5. awards (one row per assistance_award_unique_key) ---------------------
dbExecute(con, "
CREATE TABLE IF NOT EXISTS awards (
  award_unique_key            VARCHAR PRIMARY KEY,
  award_id_fain               VARCHAR UNIQUE,
  recipient_uei               VARCHAR REFERENCES recipients(recipient_uei),
  awarding_agency_id          INTEGER REFERENCES agencies(agency_id),
  awarding_sub_agency_name    VARCHAR,        -- NSF directorate (BIO, CISE, ENG, ...)
  cfda_number                 VARCHAR,
  cfda_title                  VARCHAR,
  total_obligated_amount      DOUBLE PRECISION,
  total_outlayed_amount       DOUBLE PRECISION,
  period_of_perf_start        DATE,
  period_of_perf_end          DATE,
  action_date                 DATE,           -- max action_date across the award's transactions
  description                 TEXT,
  is_active                   BOOLEAN,        -- period_of_perf_end >= today
  pulled_at                   TIMESTAMPTZ DEFAULT now()
);
")

# -- 6. transactions (one row per assistance_transaction_unique_key) ---------
dbExecute(con, "
CREATE TABLE IF NOT EXISTS transactions (
  transaction_unique_key      VARCHAR PRIMARY KEY,
  award_unique_key            VARCHAR REFERENCES awards(award_unique_key),
  award_id_fain               VARCHAR,
  recipient_uei               VARCHAR,
  cfda_number                 VARCHAR,
  awarding_sub_agency_name    VARCHAR,
  action_date                 DATE,
  action_type_description     VARCHAR,        -- 'NEW' / 'CONTINUATION' / 'REVISION' / ...
  federal_action_obligation   DOUBLE PRECISION,  -- positive = new $; negative = clawback
  assistance_type_description VARCHAR,
  transaction_description     TEXT,
  pulled_at                   TIMESTAMPTZ DEFAULT now()
);
")
dbExecute(con, "CREATE INDEX IF NOT EXISTS ix_tx_action_date  ON transactions(action_date);")
dbExecute(con, "CREATE INDEX IF NOT EXISTS ix_tx_directorate  ON transactions(awarding_sub_agency_name);")
dbExecute(con, "CREATE INDEX IF NOT EXISTS ix_tx_action_type  ON transactions(action_type_description);")

# Add pulled_at to transactions if it's missing (CREATE TABLE IF NOT EXISTS
# above is a no-op when the table already exists, so a new column added
# to the DDL won't propagate to existing databases without this).
dbExecute(con, "ALTER TABLE transactions
                ADD COLUMN IF NOT EXISTS pulled_at TIMESTAMPTZ DEFAULT now();")

# -- 7. terminations ---------------------------------------------------------
dbExecute(con, "
CREATE TABLE IF NOT EXISTS terminations (
  termination_id                 INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  award_id_fain                  VARCHAR REFERENCES awards(award_id_fain),
  project_title                  VARCHAR,
  current_status                 VARCHAR,
  latest_termination_date        DATE,
  reinstated                     BOOLEAN,
  reinstatement_date             DATE,
  post_termination_deobligation  DOUBLE PRECISION,  -- THE headline metric
  nsf_total_budget               DOUBLE PRECISION,
  estimated_remaining            DOUBLE PRECISION,
  directorate                    VARCHAR,
  division                       VARCHAR,
  nsf_program_name               VARCHAR,
  abstract                       TEXT,
  is_active                      BOOLEAN
);
")
dbExecute(con, "ALTER TABLE terminations
                ADD COLUMN IF NOT EXISTS abstract TEXT;")

# -- 8. Analytical views -----------------------------------------------------
# Each view is named v_<thing> and is read-only. Keep these here (next to the
# DDL) so the schema and its derived objects ship together.
#
# Drop first, then create. Postgres's CREATE OR REPLACE VIEW refuses to drop
# or rename columns of an existing view, so an iterating schema needs an
# explicit DROP. CASCADE catches any dependent views (e.g. v_directorate_
# resilience depends on v_currently_open_opportunities).
for (v in c("v_monthly_obligations", "v_directorate_resilience",
            "v_currently_open_opportunities", "v_active_funding",
            "v_disbursement_progress", "v_awards_with_quality",
            "v_disruption_by_recipient", "v_disruption_by_directorate",
            "v_rescinded_opportunities")) {
  dbExecute(con, sprintf("DROP VIEW IF EXISTS %s CASCADE;", v))
}

# Opportunities REMOVED from Grants.gov with no matching award (rescissions).
# Empty until a second Grants.gov snapshot has populated change_log.
dbExecute(con, "
CREATE OR REPLACE VIEW v_rescinded_opportunities AS
SELECT
  c.opportunity_id, o.opportunity_number, o.title,
  o.estimated_total_funding, o.cfda_numbers,
  c.detected_at AS removed_date,
  EXISTS (
    SELECT 1 FROM awards a
    WHERE a.cfda_number = ANY(string_to_array(o.cfda_numbers, ','))
       OR a.cfda_number = ANY(SELECT TRIM(unnest(string_to_array(o.cfda_numbers, ','))))
  ) AS has_matching_award
FROM change_log c
JOIN opportunities o ON c.opportunity_id = o.opportunity_id
WHERE c.change_type = 'REMOVED';
")

# Disruption summary by directorate. ABS the deobligation column for display
# (USAspending records deobligations as negative numbers).
dbExecute(con, "
CREATE OR REPLACE VIEW v_disruption_by_directorate AS
SELECT
  COALESCE(t.directorate, a.awarding_sub_agency_name) AS directorate,
  COUNT(*)                                            AS n_terminated_awards,
  ABS(COALESCE(SUM(t.post_termination_deobligation), 0)) AS total_deobligated,
  COALESCE(SUM(t.nsf_total_budget), 0)                AS total_at_risk_budget,
  SUM(CASE WHEN t.reinstated THEN 1 ELSE 0 END)       AS n_reinstated
FROM terminations t
LEFT JOIN awards a ON a.award_id_fain = t.award_id_fain
GROUP BY 1
ORDER BY total_deobligated DESC NULLS LAST;
")

# Disruption summary by recipient institution.
dbExecute(con, "
CREATE OR REPLACE VIEW v_disruption_by_recipient AS
SELECT
  r.recipient_uei, r.recipient_name, r.state_code,
  COUNT(t.termination_id)                                AS n_terminated_awards,
  ABS(COALESCE(SUM(t.post_termination_deobligation), 0)) AS total_deobligated
FROM terminations t
JOIN awards     a ON a.award_id_fain = t.award_id_fain
JOIN recipients r ON r.recipient_uei = a.recipient_uei
GROUP BY 1,2,3
ORDER BY total_deobligated DESC NULLS LAST;
")

# Per-award data-quality flags. NULL outlays = reporting lag, not $0.
dbExecute(con, "
CREATE OR REPLACE VIEW v_awards_with_quality AS
SELECT
  a.*,
  CASE WHEN a.total_outlayed_amount IS NULL THEN 'not_yet_reported'
       ELSE 'reported' END AS outlay_reporting_status,
  CASE
    WHEN a.period_of_perf_end IS NULL                              THEN 'unknown'
    WHEN a.period_of_perf_start > current_date                     THEN 'not_yet_started'
    WHEN a.period_of_perf_end >= current_date                      THEN 'in_progress'
    WHEN a.period_of_perf_end <  current_date - INTERVAL '1 year'  THEN 'ended_over_1yr'
    ELSE                                                                'ended_under_1yr'
  END AS pop_status,
  (a.action_date >= current_date - INTERVAL '90 days') AS action_in_reporting_lag_window
FROM awards a;
")

# % of obligation disbursed. Drops NULL outlays so the denominator is honest;
# clamps tiny rounding noise above 100%.
dbExecute(con, "
CREATE OR REPLACE VIEW v_disbursement_progress AS
SELECT
  award_unique_key, award_id_fain, awarding_sub_agency_name,
  total_obligated_amount,
  LEAST(total_outlayed_amount, total_obligated_amount) AS effective_outlay,
  CASE WHEN total_obligated_amount > 0 THEN
    LEAST(100, ROUND((100.0 *
      LEAST(total_outlayed_amount, total_obligated_amount)
      / total_obligated_amount)::numeric, 1))
  END AS pct_disbursed
FROM awards
WHERE total_outlayed_amount IS NOT NULL
  AND total_obligated_amount IS NOT NULL
  AND total_obligated_amount > 0;
")

# Active-portfolio summary by directorate (in-progress awards only).
dbExecute(con, "
CREATE OR REPLACE VIEW v_active_funding AS
SELECT
  awarding_sub_agency_name AS directorate,
  COUNT(*)                                                              AS n_active_awards,
  SUM(total_obligated_amount)                                           AS total_obligated_active,
  COUNT(*) FILTER (WHERE total_outlayed_amount IS NOT NULL)             AS n_with_outlay_reported,
  SUM(total_outlayed_amount)                                            AS total_outlaid_reported,
  ROUND((100.0 * COUNT(*) FILTER (WHERE total_outlayed_amount IS NOT NULL)
              / NULLIF(COUNT(*), 0))::numeric, 1)                       AS pct_outlay_reported
FROM awards
WHERE is_active = true
GROUP BY 1
ORDER BY total_obligated_active DESC NULLS LAST;
")

# Currently-open opportunities (posted/forecasted), with directorate inferred
# from the first CFDA number.
dbExecute(con, sprintf("
CREATE OR REPLACE VIEW v_currently_open_opportunities AS
SELECT
  o.opportunity_id, o.opportunity_number, o.title, o.cfda_numbers,
  %s AS directorate,
  o.post_date, o.close_date, o.estimated_total_funding,
  o.award_ceiling, o.award_floor, o.description
FROM opportunities o
WHERE o.is_active = TRUE
  AND (o.close_date >= current_date
       OR (o.close_date IS NULL AND o.post_date >= current_date - INTERVAL '18 months'));
",
  cfda_directorate_case_sql("split_part(o.cfda_numbers, ',', 1)")
))

# Directorate resilience: FY25 vs FY26 first-half NEW-award activity, joined
# to currently-open opportunities count.
dbExecute(con, "
CREATE OR REPLACE VIEW v_directorate_resilience AS
WITH fy25 AS (
  SELECT awarding_sub_agency_name AS directorate,
         COUNT(*) AS fy25_new_count, SUM(federal_action_obligation) AS fy25_new_oblig
  FROM transactions
  WHERE action_type_description = 'NEW'
    AND action_date >= '2024-10-01' AND action_date < '2025-04-01'
  GROUP BY 1
), fy26 AS (
  SELECT awarding_sub_agency_name AS directorate,
         COUNT(*) AS fy26_new_count, SUM(federal_action_obligation) AS fy26_new_oblig
  FROM transactions
  WHERE action_type_description = 'NEW'
    AND action_date >= '2025-10-01' AND action_date < '2026-04-01'
  GROUP BY 1
), open_opps AS (
  SELECT directorate, COUNT(*) AS n_open_opportunities,
         SUM(estimated_total_funding) AS open_funding
  FROM v_currently_open_opportunities GROUP BY 1
)
SELECT
  f25.directorate,
  COALESCE(o.n_open_opportunities, 0) AS n_open_opportunities,
  COALESCE(o.open_funding, 0)         AS open_advertised_funding,
  f25.fy25_new_count, COALESCE(f26.fy26_new_count, 0) AS fy26_new_count,
  ROUND((100.0 * COALESCE(f26.fy26_new_count, 0)
        / NULLIF(f25.fy25_new_count, 0))::numeric, 1) AS pct_count_retained,
  f25.fy25_new_oblig, COALESCE(f26.fy26_new_oblig, 0) AS fy26_new_oblig,
  ROUND((100.0 * COALESCE(f26.fy26_new_oblig, 0)
        / NULLIF(f25.fy25_new_oblig, 0))::numeric, 1) AS pct_dollar_retained
FROM fy25 f25
LEFT JOIN fy26      f26 ON f26.directorate = f25.directorate
LEFT JOIN open_opps o   ON o.directorate   = f25.directorate
ORDER BY pct_dollar_retained DESC NULLS LAST;
")

# Monthly obligations by directorate. Always splits gross_obligated (positives)
# from gross_deobligated (absolute value of negatives) so callers can show new
# spending and clawbacks as separate categories rather than netting them.
dbExecute(con, "
CREATE OR REPLACE VIEW v_monthly_obligations AS
SELECT
  date_trunc('month', action_date)::date                AS month,
  awarding_sub_agency_name                              AS directorate,
  COUNT(*)                                              AS n_transactions,
  SUM(federal_action_obligation)                        AS net_obligation,
  SUM(CASE WHEN federal_action_obligation >= 0
           THEN federal_action_obligation ELSE 0 END)   AS gross_obligated,
  ABS(SUM(CASE WHEN federal_action_obligation < 0
           THEN federal_action_obligation ELSE 0 END))  AS gross_deobligated,
  COUNT(*) FILTER (WHERE federal_action_obligation < 0) AS n_deobligations
FROM transactions
WHERE action_date IS NOT NULL
GROUP BY 1, 2
ORDER BY 1, 2;
")

# -- Summary -----------------------------------------------------------------
tabs <- dbGetQuery(con, "SELECT table_name FROM information_schema.tables
                         WHERE table_schema = 'public' ORDER BY table_name")$table_name
message("\n=== Schema ready on Neon ===")
for (t in tabs) {
  cols <- dbGetQuery(con, sprintf(
    "SELECT column_name FROM information_schema.columns
     WHERE table_schema='public' AND table_name='%s'", t))
  message(sprintf("  %-32s %2d cols", t, nrow(cols)))
}

dbDisconnect(con)
message("Connection closed.")
