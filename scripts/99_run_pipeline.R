# =============================================================================
# 99_run_pipeline.R
# Run the full data pipeline end-to-end:
#   1. process raw sources -> data/final/
#   2. apply schema to Neon (idempotent)
#   3. load data/final/ -> Neon
#
# Inputs:  data/raw/ + NEON_DB_URL (.Renviron)
# Outputs: populated Neon Postgres database; the Shiny app can be deployed.
#
# Use this for a clean rebuild from scratch. Each step's full output is
# written to data/pipeline_log_YYYYMMDD_HHMMSS.txt.
# =============================================================================

# Resolve scripts directory: the directory this file lives in.
SCRIPT_DIR <- tryCatch(
  dirname(normalizePath(rstudioapi::getSourceEditorContext()$path, mustWork = FALSE)),
  error = function(e) file.path(getwd(), "scripts")
)

log_file <- file.path(SCRIPT_DIR, "..", "data",
                      paste0("pipeline_log_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".txt"))
con_log <- file(log_file, open = "wt")
sink(con_log, split = TRUE)

message("=== NSF Grant Disruption pipeline ===")
message("Started: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))

run_step <- function(label, script_name) {
  message("\n--- ", label, " ---")
  t0 <- proc.time()
  source(file.path(SCRIPT_DIR, script_name), local = new.env())
  message(sprintf("--- %s done in %.1fs ---", label,
                  (proc.time() - t0)["elapsed"]))
}

run_step("Step 1/3: process raw sources", "01_process_raw.R")
run_step("Step 2/3: apply schema to Neon", "02_setup_postgres.R")
run_step("Step 3/3: load data into Neon",  "03_load_postgres.R")

message("\nFinished: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
message("Log: ", log_file)
message("\nNext: launch the Shiny app  ->  shiny::runApp('shiny/')")

sink()
close(con_log)
