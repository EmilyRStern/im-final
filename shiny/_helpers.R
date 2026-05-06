# =============================================================================
# _helpers.R
# CFDA-to-directorate and project-title-to-topic mappings, used by both the
# pipeline scripts and the Shiny app. Each is exposed as a small function that
# returns a SQL CASE string, so the mapping lives in one place instead of
# being duplicated inline in three queries.
#
# Lives in shiny/ so it ships with the rsconnect deploy bundle. The pipeline
# scripts source it via the project root.
# =============================================================================

# CFDA assistance code -> NSF directorate.
cfda_directorate <- c(
  "47.041" = "ENG",  "47.049" = "MPS",  "47.050" = "GEO",
  "47.070" = "CISE", "47.074" = "BIO",  "47.075" = "SBE",
  "47.076" = "EDU",  "47.078" = "OPP",  "47.079" = "OD",
  "47.083" = "OIA",  "47.084" = "TIP"
)

# Build a SQL CASE that maps `column` (a CFDA number) to a directorate code.
# Standard CASE syntax — same in DuckDB and Postgres.
cfda_directorate_case_sql <- function(column) {
  whens <- paste0("    WHEN '", names(cfda_directorate),
                  "' THEN '",   cfda_directorate, "'",
                  collapse = "\n")
  paste0("CASE ", column, "\n", whens, "\n    ELSE 'OTHER'\n  END")
}

# Topic classifier on terminations.project_title (Postgres only — uses ~).
# Order matters: first matching pattern wins, so list specific patterns first.
# This is a title-text heuristic; the Methods tab notes it is illustrative.
topic_label <- c(
  "climate / environment",
  "DEI / broadening",
  "education / training",
  "health / biomedical",
  "social / behavioral",
  "computing / AI",
  "energy",
  "physical sci"
)
topic_regex <- c(
  "climate|environment|sustain|carbon|emission|warming",
  "diversity|equity|inclusion|broadening|underrepresent|minority|hispanic|indigenous|tribal",
  "teach|teacher|education|stem|undergraduate|graduate|student|curricul|k-12|k12",
  "health|disease|covid|cancer|biomed|medical",
  "social|behavior|economic|society|community|civic|public",
  "quantum|computing|ai|machine learning|cyber|data|algorithm|software",
  "energy|battery|solar|wind|nuclear",
  "physics|chemistry|astronomy|materials|nano"
)

topic_case_sql <- function(column) {
  whens <- paste0("    WHEN LOWER(", column, ") ~ '", topic_regex,
                  "' THEN '", topic_label, "'",
                  collapse = "\n")
  paste0("CASE\n", whens, "\n    ELSE 'other / uncategorized'\n  END")
}
