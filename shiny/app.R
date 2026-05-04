# =============================================================================
# app.R  -  NSF Grant Lifecycle Disruption Analysis
# EPPS 6354 Information Management - Spring 2026 - Emily Stern
#
# Reads from Neon Postgres (NEON_DB_URL) and renders a Shiny dashboard styled
# with the `stern` design-system R package. Anchored on EO 14332,
# "Improving Oversight of Federal Grantmaking" (Aug 7, 2025).
#
# Five tabs, each anchored to one stage of the disruption lifecycle:
#   1. Timing    - phase timeline + 3-yr same-month baseline
#   2. Lifecycle - per-directorate survival funnel + pre/post quadrant scatter
#   3. Impact    - topic clusters + state choropleth + top programs/recipients
#   4. Recovery  - reinstatement velocity + reversed/stuck programs
#   5. Methods   - lifecycle framing, sources, limitations
#
# Run locally:  shiny::runApp("shiny/")
# Deploy:       see shiny/README.md
# =============================================================================

# -- Packages ---------------------------------------------------------------
required <- c("shiny", "bslib", "DBI", "RPostgres", "pool", "DT", "dplyr",
              "highcharter", "scales", "stern", "jsonlite")
missing <- required[!sapply(required, requireNamespace, quietly = TRUE)]
if (length(missing) > 0) {
  cran_pkgs <- setdiff(missing, "stern")
  if (length(cran_pkgs)) install.packages(cran_pkgs)
  if ("stern" %in% missing) {
    if (!requireNamespace("remotes", quietly = TRUE)) install.packages("remotes")
    remotes::install_github("EmilyRStern/stern", upgrade = "never")
  }
}
suppressPackageStartupMessages({
  library(shiny);   library(bslib);  library(DBI);     library(RPostgres)
  library(pool);    library(DT);     library(dplyr);   library(highcharter)
  library(scales);  library(stern); library(rsconnect)
})
stern_setup_fonts()

# US states GeoJSON cached locally to avoid the highcharts CDN blocking R's
# default User-Agent (returns 403 to download.file even though the file is
# public). File pulled once via curl from
# code.highcharts.com/mapdata/countries/us/us-all.geo.json
us_states_map <- jsonlite::fromJSON("us-all.geo.json", simplifyVector = FALSE)

# -- DB pool ----------------------------------------------------------------
parse_pg_url <- function(url) {
  m <- regmatches(url, regexec(
    "^postgres(?:ql)?://([^:]+):([^@]+)@([^:/]+)(?::(\\d+))?/([^?]+)(?:\\?(.*))?$", url))[[1]]
  list(user = m[2], password = m[3], host = m[4],
       port = if (nzchar(m[5])) as.integer(m[5]) else 5432L, dbname = m[6])
}
for (cand in c(".Renviron", "../.Renviron", "../../.Renviron")) {
  if (file.exists(cand)) { readRenviron(cand); break }
}
NEON_URL <- Sys.getenv("NEON_DB_URL")
if (!nzchar(NEON_URL)) stop("NEON_DB_URL not set. Add it to .Renviron at the project root.")
P <- parse_pg_url(NEON_URL)
pool <- dbPool(drv = Postgres(),
  host = P$host, port = P$port, dbname = P$dbname,
  user = P$user, password = P$password, sslmode = "require",
  bigint = "integer",
  minSize = 1, maxSize = 4, idleTimeout = 60000)
onStop(function() poolClose(pool))

# -- Helpers ----------------------------------------------------------------
section_caption <- function(text) {
  span(text, style = sprintf(
    "font-family: 'Source Sans 3', sans-serif; font-size: 0.72rem;
     text-transform: uppercase; letter-spacing: 0.07em; color: %s;",
    stern_text_muted))
}
implications <- function(...) {
  span(style = sprintf("color: %s; font-size: 0.72rem;", stern_text_muted), ...)
}
narrative_p <- function(...) {
  p(style = sprintf("font-family: 'Source Serif 4'; color: %s;
                     font-size: 0.92rem; line-height: 1.45;
                     margin-bottom: 8px;",
                     stern_text_body), ...)
}
chart_card <- function(caption, height_px, output_id, footer = NULL) {
  card(
    full_screen = TRUE,
    card_header(section_caption(caption)),
    div(style = sprintf(
      "display: block; width: 100%%; height: %dpx;
       padding: 8px 10px; box-sizing: border-box;", height_px),
      highchartOutput(output_id, width = "100%", height = "100%")),
    if (!is.null(footer)) card_footer(implications(footer))
  )
}

# -- UI ---------------------------------------------------------------------
ui <- bslib::page_navbar(
  title = "NSF Grant Lifecycle Disruption Analysis",
  theme = stern_bs_theme(),
  id    = "main_tabs",
  fillable = FALSE,

  header = tags$head(tags$style(HTML(
    ".stern-callouts-centered, .stern-callouts-centered * {
       text-align: center;
     }
     /* compact callouts but keep them legible — long labels need breathing room */
     .stern-callouts-centered [style*='1.9rem'] {
       font-size: 1.3rem !important; line-height: 1.1 !important;
     }
     .stern-callouts-centered [style*='14px 16px'] {
       padding: 12px 10px !important;
     }
     /* stretch callout row gap so the boxes don't touch */
     .stern-callouts-centered .bslib-grid,
     .stern-callouts-centered > div {
       gap: 0.85rem !important;
     }
     /* equal-height callouts so wrapping labels don't shift baselines */
     .stern-callouts-centered [style*='14px 16px'] {
       height: 100%;
       display: flex !important;
       flex-direction: column;
       justify-content: center;
     }
     .navbar-brand { font-family: 'Source Serif 4', serif;
                     font-weight: 600; font-size: 1.05rem; }
     .navbar { padding-top: 6px; padding-bottom: 6px; }
     .nav-tabs .nav-link, .navbar-nav .nav-link {
       font-family: 'Source Sans 3', sans-serif; font-size: 0.92rem; }
     h2 { font-size: 1.25rem !important; margin-top: 6px !important; }
     h3 { font-size: 1.10rem !important; }
     h4 { font-size: 1.00rem !important; margin-top: 12px !important; }
     /* tighter card chrome for embedding */
     .card-header { padding-top: 6px; padding-bottom: 6px; }
     .card-footer { padding-top: 4px; padding-bottom: 6px; }"
  ))),

    # ----- Tab 1: Timing -------------------------------------------------
    nav_panel(
      title = "Timeline",
      div(style = "padding: 8px 4px 0 4px;",
        

        uiOutput("time_stats"),
        
        narrative_p(
          "On April 30, 2025, NSF was instructed to halt new funding — the
           first observable disruption to the grant pipeline. In the year
           since, ",
          textOutput("about_n_terms", inline = TRUE),
          " awards have been terminated."),

        chart_card(
          "Monthly NSF obligations, clawbacks, and terminations with policy anchors",
          440, "phase_timeline",
          "Terminations begin shortly after the April 30 funding freeze and
           accelerate through May. EO 14332 (Aug 7) follows, coinciding with
           the annual obligation surge before FY26."
        ),

        chart_card(
          "FY26 actual vs three-year same-calendar-month baseline (mean ±1σ)",
          340, "baseline_chart",
          "Holding seasonality constant by stacking the same calendar months
           across FY23-FY25, FY26 February-March obligations land more than
           two standard deviations below baseline. The March 2026 point is
           shown with an open marker because reporting is incomplete -- the
           data was pulled April 6 2026, so March only includes transactions
           through Mar 14. Even with that caveat, the FY26 trough is
           unambiguous against three years of baseline variance."
        )
      )
    ),

    # ----- Tab 2: Lifecycle ----------------------------------------------
    nav_panel(
      title = "Lifecycle",
      div(style = "padding: 8px 4px 0 4px;",
        h2("How disruption propagates through the grant lifecycle",
           style = sprintf("color: %s; margin-top: 8px; margin-bottom: 4px;",
                           stern_text_primary)),
        narrative_p(
          "NSF grants don't fail in one place. They fail across a lifecycle:
           opportunity posted → award funded → performed → potentially
           terminated → potentially reinstated."),
        narrative_p(
          "A single 'how much got cut' number hides the structural pattern.
           Some directorates lost their NEW-obligation pipeline entirely.
           Others had existing awards terminated. A few got both."),

        uiOutput("pipeline_stats"),



        chart_card(
          "Per-directorate award outcomes (at-risk pool only)",
          320, "funnel_survival",
          "Each bar = directorate's awards with post-Apr 2025 activity or in
           the citizen tracker. Pre-disruption-completed awards are excluded.
           Grey = >$100K net deobligation post-Apr 2025 but missing from the
           citizen tracker — likely undercount of true disruption."
        ),
        
        uiOutput("directorate_glossary")
      )
    ),
  


    # ----- Tab 3: Impact -------------------------------------------------
    nav_panel(
      title = "Impact",
      div(style = "padding: 8px 4px 0 4px;",
        h2("Subject matter and geography",
           style = sprintf("color: %s; margin-top: 8px;",
                           stern_text_primary)),

        chart_card(
          "Which terminated topics recovered?",
          300, "topic_clusters",
          "DEI / broadening-participation research has the lowest
           reinstatement rate (~10%); core computing and physical sciences
           research was overwhelmingly reversed. Topic clusters are derived
           by regex on project titles — illustrative, not authoritative."
        ),

        chart_card(
          "State-level termination rate: % of state's NSF grants terminated",
          360, "state_choropleth",
          "Color encodes the share of each state's active NSF grants that
           were terminated (count-based, not dollar-based). Small-portfolio
           states surface here even when their absolute dollar losses are
           modest, since one termination is a larger fraction of a small
           base."
        ),

        layout_columns(
          col_widths = c(6, 6),
          card(
            card_header(section_caption("Top-15 most-affected NSF programs (by termination count)")),
            DTOutput("top_programs_tbl")
          ),
          card(
            card_header(section_caption("Top-15 most-affected institutions (by deobligated $)")),
            DTOutput("top_recipients_tbl")
          )
        )
      )
    ),

    # ----- Tab 4: Recovery ------------------------------------------------
    nav_panel(
      title = "Recovery",
      div(style = "padding: 8px 4px 0 4px;",
        h2("Reversal dynamics: the machinery exists, but it's selective",
           style = sprintf("color: %s; margin-top: 8px;",
                           stern_text_primary)),
        narrative_p(
          "Among NSF's 1,996 tracked terminations, 633 (32%) have been
           reinstated."),
        narrative_p(
          "But the reinstatement rate varies from 100% (MAGNETOSPHERIC
           PHYSICS, STATISTICS) to 0% (HBCU programs, Engineering Education
           Diversity Activities, Build and Broaden). Who gets reinstated is
           the political-targeting question separated from the magnitude
           question."),

        chart_card(
          "Days from termination to reinstatement (distribution)",
          280, "reinst_velocity",
          "Tight clustering around 50 days suggests the reversal process
           runs in batches rather than per-case. The minimum of 13 days
           is the floor of the citizen-science tracker's reporting cadence,
           not necessarily the minimum administrative turnaround."
        ),

        layout_columns(
          col_widths = c(6, 6),
          card(
            card_header(section_caption(
              "Programs with HIGHEST reinstatement rate (>=8 terminations)")),
            DTOutput("recovered_programs_tbl"),
            card_footer(implications(
              "These programs were terminated but the citizen-science tracker
               documents widespread reversal. Concentrated in MPS and CISE."))
          ),
          card(
            card_header(section_caption(
              "Programs with LOWEST reinstatement rate (>=15 terminations)")),
            DTOutput("stuck_programs_tbl"),
            card_footer(implications(
              "These are the programs where terminations have stuck.
               The pattern across the bottom of this list -- HBCU, HSI,
               ADVANCE, AGEP, broadening-participation alliances -- is
               consistent with politically targeted research."))
          )
        )
      )
    ),

    # ----- Tab 5: Methods ------------------------------------------------
    nav_panel(
      title = "Methods",
      div(style = "padding: 14px 18px; max-width: 760px;
                   font-family: 'Source Serif 4';
                   font-size: 0.92rem; line-height: 1.45;",
        h3("About this analysis",
           style = sprintf("color: %s;", stern_text_primary)),
        p("Lifecycle analysis of NSF grant disruption (FY23-FY26), anchored
          on EO 14332 \"Improving Oversight of Federal Grantmaking\"
          (Aug 7, 2025). Three federal data sources are joined into a
          6-table Postgres schema covering the opportunity → award →
          termination → reinstatement lifecycle:"),
        tags$ul(
          tags$li(strong("USAspending.gov"), " - transaction-level NSF
                  assistance award data, FY23-FY26 (",
                  textOutput("about_n_tx", inline = TRUE), " transactions
                  across ", textOutput("about_n_awards", inline = TRUE),
                  " awards)."),
          tags$li(strong("Grants.gov"), " - NSF opportunity listings (",
                  textOutput("about_n_opps", inline = TRUE), " records)."),
          tags$li(strong("NSF terminations dataset"), " - citizen-science
                  termination tracker (", textOutput("about_n_terms",
                  inline = TRUE), " awards).")
        ),
        p(style = sprintf("color: %s; font-size: 0.85rem;", stern_text_muted),
          "EPPS 6354 Information Management - University of Texas at Dallas
           - Spring 2026 - Emily Stern - Data current as of April 2026.")
      )
    )
)

# -- SERVER -----------------------------------------------------------------
server <- function(input, output, session) {

  # -- Reactives (cached pulls) --------------------------------------------

  termination_totals <- reactive({
    dbGetQuery(pool, "
      SELECT COUNT(*)                                            AS n_terms,
             SUM(CASE WHEN reinstated THEN 1 ELSE 0 END)         AS n_reinst,
             ABS(COALESCE(SUM(post_termination_deobligation),0)) AS deob
      FROM terminations")
  }) |> bindCache("termination_totals_v1")

  pipeline_funnel <- reactive({
    # Cast COUNT(*) to int (not bigint/integer64) so highcharter can axis-round
    # without hitting "no applicable method for round_any" errors.
    # n_unreported = awards with net post-EO deobligation > $100K but no entry
    # in the citizen-science terminations tracker — a USAspending-only signal
    # that the tracker likely undercounts true disruption.
    # per_dir restricts to the at-risk pool: awards with transactions on/after
    # the first known NSF termination (2025-04-18) OR in the terminations
    # table. Excludes pre-disruption awards that already completed.
    dbGetQuery(pool, "
      WITH per_dir AS (
        SELECT a.awarding_sub_agency_name AS directorate,
               COUNT(*)::int AS n_awards,
               SUM(a.total_obligated_amount)/1e6 AS awarded_m
        FROM awards a
        WHERE EXISTS (
          SELECT 1 FROM transactions tx
          WHERE tx.award_unique_key = a.award_unique_key
            AND tx.action_date >= '2025-04-01'
        ) OR EXISTS (
          SELECT 1 FROM terminations tm
          WHERE tm.award_id_fain = a.award_id_fain
        )
        GROUP BY 1
      ),
      term_per_dir AS (
        SELECT
          CASE COALESCE(t.directorate, a.awarding_sub_agency_name)
            WHEN 'STEM Education' THEN 'EDU'
            WHEN 'Mathematical and Physical Sciences' THEN 'MPS'
            WHEN 'Computer and Information Science and Engineering' THEN 'CISE'
            WHEN 'Engineering' THEN 'ENG'
            WHEN 'Geosciences' THEN 'GEO'
            WHEN 'Biological Sciences' THEN 'BIO'
            WHEN 'Social, Behavioral and Economic Sciences' THEN 'SBE'
            WHEN 'Technology, Innovation and Partnerships' THEN 'TIP'
            WHEN 'Office of the Director' THEN 'OD'
            ELSE 'OTHER'
          END AS directorate,
          COUNT(*)::int AS n_terms,
          SUM(CASE WHEN reinstated THEN 1 ELSE 0 END)::int AS n_reinst,
          ABS(COALESCE(SUM(t.post_termination_deobligation),0))/1e6 AS deobl_m
        FROM terminations t
        LEFT JOIN awards a ON a.award_id_fain = t.award_id_fain
        GROUP BY 1
      ),
      post_eo_deob AS (
        SELECT tx.award_unique_key,
               SUM(tx.federal_action_obligation) AS net_post_eo
        FROM transactions tx
        WHERE tx.action_date >= '2025-04-01'
        GROUP BY 1
        HAVING SUM(tx.federal_action_obligation) < -100000
      ),
      unreported AS (
        SELECT a.awarding_sub_agency_name AS directorate,
               COUNT(*)::int AS n_unreported
        FROM post_eo_deob d
        JOIN awards a ON a.award_unique_key = d.award_unique_key
        WHERE NOT EXISTS (
          SELECT 1 FROM terminations tm
          WHERE tm.award_id_fain = a.award_id_fain
        )
        GROUP BY 1
      )
      SELECT p.directorate,
             p.n_awards, ROUND(p.awarded_m::numeric, 1) AS awarded_m,
             COALESCE(t.n_terms, 0)::int     AS n_terms,
             COALESCE(t.n_reinst, 0)::int    AS n_reinst,
             COALESCE(u.n_unreported, 0)::int AS n_unreported,
             ROUND(COALESCE(t.deobl_m, 0)::numeric, 2) AS deobl_m
      FROM per_dir p
      LEFT JOIN term_per_dir t ON t.directorate = p.directorate
      LEFT JOIN unreported   u ON u.directorate = p.directorate
      WHERE p.directorate <> 'OTHER'
      ORDER BY p.n_awards DESC")
  }) |> bindCache("pipeline_funnel_v3")

  pre_post <- reactive({
    dbGetQuery(pool, "
      WITH pre AS (
        SELECT awarding_sub_agency_name AS dir,
          ROUND((100.0 * (1 - COALESCE(SUM(CASE WHEN action_date >= '2025-10-01' AND action_date < '2026-04-01'
                                              THEN federal_action_obligation END), 0)
              / NULLIF(SUM(CASE WHEN action_date >= '2023-10-01' AND action_date < '2024-04-01'
                                THEN federal_action_obligation END), 0)))::numeric, 1) AS pre_drop_pct,
          SUM(CASE WHEN action_date >= '2023-10-01' AND action_date < '2024-04-01'
                   THEN federal_action_obligation END)/1e6 AS fy24h1_m
        FROM transactions WHERE action_type_description = 'NEW' GROUP BY 1
      ),
      post AS (
        SELECT a.awarding_sub_agency_name AS dir,
               COUNT(DISTINCT a.award_unique_key)::int AS n_awards,
               COUNT(DISTINCT t.termination_id)::int   AS n_terms,
               ROUND((100.0 * COUNT(DISTINCT t.termination_id)
                     / NULLIF(COUNT(DISTINCT a.award_unique_key), 0))::numeric, 2) AS post_term_pct
        FROM awards a LEFT JOIN terminations t ON t.award_id_fain = a.award_id_fain
        WHERE EXISTS (
          SELECT 1 FROM transactions tx
          WHERE tx.award_unique_key = a.award_unique_key
            AND tx.action_date >= '2025-04-01'
        ) OR t.termination_id IS NOT NULL
        GROUP BY 1
      )
      SELECT pre.dir, pre.pre_drop_pct, ROUND(pre.fy24h1_m::numeric, 0) AS fy24h1_m,
             post.n_awards, post.n_terms, post.post_term_pct
      FROM pre LEFT JOIN post ON pre.dir = post.dir
      WHERE pre.dir <> 'OTHER' ORDER BY pre.pre_drop_pct DESC NULLS LAST")
  }) |> bindCache("pre_post_v2")

  phase_timeline_data <- reactive({
    dbGetQuery(pool, "
      WITH new_awards AS (
        SELECT date_trunc('month', action_date)::date AS month,
               COUNT(*)::int AS n_new,
               SUM(CASE WHEN federal_action_obligation > 0
                        THEN federal_action_obligation ELSE 0 END) / 1e6 AS new_m
        FROM transactions
        WHERE action_type_description = 'NEW'
          AND action_date >= '2025-01-01'
          AND action_date <  '2026-04-01'
        GROUP BY 1),
      clawbacks AS (
        SELECT date_trunc('month', action_date)::date AS month,
               ABS(SUM(federal_action_obligation)) / 1e6 AS clawback_m
        FROM transactions
        WHERE federal_action_obligation < 0
          AND action_date >= '2025-01-01'
          AND action_date <  '2026-04-01'
        GROUP BY 1),
      terms AS (
        SELECT date_trunc('month', latest_termination_date)::date AS month,
               COUNT(*)::int AS n_terms
        FROM terminations
        WHERE latest_termination_date IS NOT NULL
          AND latest_termination_date >= '2025-01-01'
          AND latest_termination_date <  '2026-04-01'
        GROUP BY 1)
      SELECT COALESCE(a.month, c.month, t.month) AS month,
             COALESCE(a.n_new,      0)::int  AS n_new,
             COALESCE(a.new_m,      0)  AS new_m,
             COALESCE(c.clawback_m, 0)  AS clawback_m,
             COALESCE(t.n_terms,    0)::int  AS n_terms
      FROM new_awards a
      FULL OUTER JOIN clawbacks c ON a.month = c.month
      FULL OUTER JOIN terms     t ON COALESCE(a.month, c.month) = t.month
      ORDER BY 1")
  }) |> bindCache("phase_timeline_v2")

  monthly_baseline <- reactive({
    raw <- dbGetQuery(pool, "
      SELECT EXTRACT(MONTH FROM action_date)::int AS cal_month,
             EXTRACT(YEAR  FROM action_date)::int AS cal_year,
             SUM(CASE WHEN federal_action_obligation >= 0
                      THEN federal_action_obligation ELSE 0 END) AS gross
      FROM transactions WHERE action_date >= '2023-01-01'
      GROUP BY 1, 2 ORDER BY 1, 2")
    base <- raw |> filter(cal_year %in% c(2023, 2024, 2025)) |>
      group_by(cal_month) |>
      summarise(mean_m = mean(gross) / 1e6,
                sd_m   = sd(gross)   / 1e6, .groups = "drop")
    fy26 <- raw |> filter(cal_year == 2026) |>
      transmute(cal_month, fy26_m = gross / 1e6)
    left_join(base, fy26, by = "cal_month") |>
      mutate(low = mean_m - sd_m, high = mean_m + sd_m,
             z   = (fy26_m - mean_m) / sd_m)
  }) |> bindCache("monthly_baseline_v1")

  topic_data <- reactive({
    dbGetQuery(pool, "
      WITH labeled AS (
        SELECT
          CASE
            WHEN LOWER(project_title) ~ 'climate|environment|sustain|carbon|emission|warming'
              THEN 'climate / environment'
            WHEN LOWER(project_title) ~ 'diversity|equity|inclusion|broadening|underrepresent|minority|hispanic|indigenous|tribal'
              THEN 'DEI / broadening'
            WHEN LOWER(project_title) ~ 'teach|teacher|education|stem|undergraduate|graduate|student|curricul|k-12|k12'
              THEN 'education / training'
            WHEN LOWER(project_title) ~ 'health|disease|covid|cancer|biomed|medical'
              THEN 'health / biomedical'
            WHEN LOWER(project_title) ~ 'social|behavior|economic|society|community|civic|public'
              THEN 'social / behavioral'
            WHEN LOWER(project_title) ~ 'quantum|computing|ai|machine learning|cyber|data|algorithm|software'
              THEN 'computing / AI'
            WHEN LOWER(project_title) ~ 'energy|battery|solar|wind|nuclear' THEN 'energy'
            WHEN LOWER(project_title) ~ 'physics|chemistry|astronomy|materials|nano' THEN 'physical sci'
            ELSE 'other / uncategorized'
          END AS topic,
          reinstated
        FROM terminations
      )
      SELECT topic, COUNT(*)::int AS n_terms,
             SUM(CASE WHEN reinstated THEN 1 ELSE 0 END)::int AS n_reinst,
             ROUND((100.0 * SUM(CASE WHEN reinstated THEN 1 ELSE 0 END)
                   / COUNT(*))::numeric, 1) AS pct_reinst
      FROM labeled GROUP BY 1 ORDER BY n_terms DESC")
  }) |> bindCache("topic_data_v1")

  state_data <- reactive({
    dbGetQuery(pool, "
      WITH t AS (
        SELECT r.state_code,
               COUNT(*)::int AS n_terms,
               ABS(COALESCE(SUM(t.post_termination_deobligation),0))/1e6 AS deobl_m
        FROM terminations t
        JOIN awards     a ON a.award_id_fain = t.award_id_fain
        JOIN recipients r ON r.recipient_uei = a.recipient_uei
        WHERE r.state_code IS NOT NULL AND r.state_code <> ''
        GROUP BY 1),
      ac AS (
        SELECT r.state_code,
               COUNT(*)::int AS n_active,
               SUM(a.total_obligated_amount)/1e6 AS active_m
        FROM awards a JOIN recipients r ON r.recipient_uei = a.recipient_uei
        WHERE a.is_active = TRUE AND r.state_code IS NOT NULL
        GROUP BY 1)
      SELECT ac.state_code,
             ac.n_active,
             ROUND(ac.active_m::numeric, 1)              AS active_m,
             COALESCE(t.n_terms, 0)                      AS n_terms,
             ROUND(COALESCE(t.deobl_m, 0)::numeric, 2)   AS deobl_m,
             ROUND((100.0 * COALESCE(t.n_terms, 0) /
                    NULLIF(ac.n_active + COALESCE(t.n_terms, 0), 0))::numeric, 2)
                                                         AS pct_terminated
      FROM ac LEFT JOIN t ON ac.state_code = t.state_code")
  }) |> bindCache("state_data_v2")

  reinst_velocity_data <- reactive({
    dbGetQuery(pool, "
      SELECT (reinstatement_date - latest_termination_date) AS days,
        CASE
          WHEN LOWER(project_title) ~ 'climate|environment|sustain|carbon|emission|warming'
            THEN 'climate / environment'
          WHEN LOWER(project_title) ~ 'diversity|equity|inclusion|broadening|underrepresent|minority|hispanic|indigenous|tribal'
            THEN 'DEI / broadening'
          WHEN LOWER(project_title) ~ 'teach|teacher|education|stem|undergraduate|graduate|student|curricul|k-12|k12'
            THEN 'education / training'
          WHEN LOWER(project_title) ~ 'health|disease|covid|cancer|biomed|medical'
            THEN 'health / biomedical'
          WHEN LOWER(project_title) ~ 'social|behavior|economic|society|community|civic|public'
            THEN 'social / behavioral'
          WHEN LOWER(project_title) ~ 'quantum|computing|ai|machine learning|cyber|data|algorithm|software'
            THEN 'computing / AI'
          WHEN LOWER(project_title) ~ 'energy|battery|solar|wind|nuclear' THEN 'energy'
          WHEN LOWER(project_title) ~ 'physics|chemistry|astronomy|materials|nano' THEN 'physical sci'
          ELSE 'other / uncategorized'
        END AS topic
      FROM terminations
      WHERE reinstated = TRUE
        AND reinstatement_date IS NOT NULL
        AND latest_termination_date IS NOT NULL")
  }) |> bindCache("reinst_velocity_v2")

  # -- Timing tab outputs --------------------------------------------------

  output$time_stats <- renderUI({
    pt <- phase_timeline_data()
    mb <- monthly_baseline()

    peak_idx   <- which.max(pt$n_terms)
    peak_month <- format(as.Date(pt$month[peak_idx]), "%b %Y")
    peak_count <- pt$n_terms[peak_idx]

    pt_d       <- as.Date(pt$month)
    fy26_h1    <- sum(pt$new_m[pt_d >= as.Date("2025-10-01") &
                               pt_d <  as.Date("2026-04-01")], na.rm = TRUE)
    fy25_h1    <- sum(pt$new_m[pt_d >= as.Date("2024-10-01") &
                               pt_d <  as.Date("2025-04-01")], na.rm = TRUE)
    yoy_pct    <- if (fy25_h1 > 0) 100 * (fy26_h1 - fy25_h1) / fy25_h1 else NA_real_

    feb_z      <- mb$z[mb$cal_month == 2]
    feb_z      <- if (length(feb_z) && !is.na(feb_z[1])) feb_z[1] else NA_real_

    div(class = "stern-callouts-centered",
      layout_columns(
        col_widths = c(3, 3, 3, 3),
        stern_stat_callout(
          label   = "NSF funding freeze",
          value   = "Apr 30, 2025",
          context = "Agency instructed to halt new funding",
          accent  = "navy"
        ),
        stern_stat_callout(
          label   = "Peak termination month",
          value   = scales::comma(peak_count),
          context = sprintf("%s NSF awards terminated", peak_month),
          accent  = "rust"
        ),
        stern_stat_callout(
          label   = "FY26 H1 obligation decline",
          value   = if (is.na(yoy_pct)) "n/a" else sprintf("%+.0f%%", yoy_pct),
          context = "NEW obligations, Oct-Mar vs FY25",
          accent  = "rust"
        ),
        stern_stat_callout(
          label   = "FY26 Feb vs 3-yr baseline",
          value   = if (is.na(feb_z)) "n/a" else sprintf("%.1fσ", feb_z),
          context = "same-month mean ±1σ",
          accent  = "rust"
        )
      )
    )
  })

  # -- Lifecycle tab outputs -----------------------------------------------

  output$pipeline_stats <- renderUI({
    tt <- termination_totals()
    pp <- pre_post()
    tip <- pp |> filter(dir == "TIP") |> head(1)
    edu_post <- pp |> filter(dir == "EDU") |> head(1)
    div(class = "stern-callouts-centered",
      layout_columns(
        col_widths = c(3, 3, 3, 3),
        stern_stat_callout(
          label   = "Awards in dataset",
          value   = scales::comma(sum(pipeline_funnel()$n_awards)),
          context = "FY23-26 NSF assistance awards (USAspending)"
        ),
        stern_stat_callout(
          label   = "Terminated",
          value   = scales::comma(tt$n_terms),
          context = sprintf("%s reinstated (%.0f%%)",
                            scales::comma(tt$n_reinst),
                            100 * tt$n_reinst / tt$n_terms),
          accent  = "mustard"
        ),
        stern_stat_callout(
          label   = "TIP pre-award disruption",
          value   = sprintf("-%.0f%%", tip$pre_drop_pct),
          context = "FY24 H1 -> FY26 H1 NEW obligations",
          accent  = "rust"
        ),
        stern_stat_callout(
          label   = "EDU post-award disruption",
          value   = sprintf("%.1f%%", edu_post$post_term_pct),
          context = "of EDU awards have been terminated",
          accent  = "rust"
        )
      )
    )
  })

  # output$scatter_pre_post <- renderHighchart({
  #   pp <- pre_post()
  #   pts <- lapply(seq_len(nrow(pp)), function(i) {
  #     list(
  #       name     = pp$dir[i],
  #       x        = pp$pre_drop_pct[i],
  #       y        = pp$post_term_pct[i],
  #       n_awards = pp$n_awards[i],
  #       n_terms  = pp$n_terms[i],
  #       color    = stern_palette[["navy"]],
  #       dataLabels = list(enabled = TRUE, format = "{point.name}",
  #                         align = "left", verticalAlign = "middle", x = 8,
  #                         style = list(fontSize = "11px",
  #                                      textOutline = "1px white"))
  #     )
  #   })
  #   highchart() |>
  #     hc_chart(type = "scatter", plotBackgroundColor = stern_bg_surface,
  #              style = list(fontFamily = "Source Sans 3", fontSize = "13px")) |>
  #     hc_xAxis(title = list(text = "Drop in NEW obligations (FY24 H1 → FY26 H1)",
  #                           style = list(fontSize = "13px", color = stern_text_body)),
  #              labels = list(style = list(fontSize = "12px", color = stern_text_body),
  #                            format = "{value}%"),
  #              min = 0, max = 100,
  #              plotLines = list(list(value = 50, color = stern_border,
  #                                    dashStyle = "ShortDot", width = 1))) |>
  #     hc_yAxis(title = list(text = "Awards terminated (% of at-risk pool)",
  #                           style = list(fontSize = "13px", color = stern_text_body)),
  #              labels = list(style = list(fontSize = "12px", color = stern_text_body),
  #                            format = "{value}%"),
  #              min = 0,
  #              plotLines = list(list(value = 5, color = stern_border,
  #                                    dashStyle = "ShortDot", width = 1))) |>
  #     hc_annotations(list(
  #       labels = list(
  #         list(point = list(x = 12,  y = 0.5, xAxis = 0, yAxis = 0),
  #              text = "Spared"),
  #         list(point = list(x = 12,  y = 9,   xAxis = 0, yAxis = 0),
  #              text = "Post-award only"),
  #         list(point = list(x = 78,  y = 0.5, xAxis = 0, yAxis = 0),
  #              text = "Pre-award only"),
  #         list(point = list(x = 78,  y = 9,   xAxis = 0, yAxis = 0),
  #              text = "Double-hit")
  #       ),
  #       labelOptions = list(
  #         backgroundColor = "rgba(255,255,255,0.85)",
  #         borderColor = stern_border, borderWidth = 0.5, borderRadius = 3,
  #         style = list(fontSize = "10px", color = stern_text_muted,
  #                      fontWeight = "normal"),
  #         padding = 4
  #       )
  #     )) |>
  #     hc_add_series(name = "Directorate", data = pts,
  #                   color = stern_palette[["navy"]],
  #                   marker = list(radius = 6,
  #                                 symbol = "circle",
  #                                 lineWidth = 1,
  #                                 lineColor = "white")) |>
  #     hc_tooltip(useHTML = TRUE, style = list(fontSize = "12px"),
  #                pointFormat = "<b>{point.name}</b><br>
  #                               Drop in NEW obligations: <b>{point.x}%</b><br>
  #                               Awards terminated: <b>{point.y}%</b><br>
  #                               Awards in dataset: {point.n_awards:,.0f}<br>
  #                               Terminations: {point.n_terms:,.0f}") |>
  #     hc_legend(enabled = FALSE) |>
  #     hc_add_theme(hc_theme_stern())
  # })

  output$directorate_glossary <- renderUI({
    items <- list(
      c("CISE", "Computer & Information Science and Engineering"),
      c("ENG",  "Engineering"),
      c("MPS",  "Mathematical and Physical Sciences"),
      c("BIO",  "Biological Sciences"),
      c("GEO",  "Geosciences"),
      c("SBE",  "Social, Behavioral and Economic Sciences"),
      c("EDU",  "STEM Education"),
      c("TIP",  "Technology, Innovation and Partnerships"),
      c("OD",   "Office of the Director")
    )
    cell <- function(code, name) {
      div(style = sprintf(
        "font-family: 'Source Sans 3', sans-serif; font-size: 0.78rem;
         color: %s; padding: 1px 0;", stern_text_body),
        tags$strong(code), " - ", name)
    }
    cells <- lapply(items, function(x) cell(x[1], x[2]))
    card(
      card_header(section_caption("NSF directorates")),
      div(style = "padding: 4px 12px 6px 12px;",
          do.call(layout_columns,
                  c(list(col_widths = c(4, 4, 4)), cells))
      )
    )
  })
  
  output$funnel_survival <- renderHighchart({
    pf <- pipeline_funnel()
    pf <- pf |>
      mutate(survived   = pmax(n_awards - n_terms - n_unreported, 0),
             unreported = n_unreported,
             stuck      = n_terms - n_reinst,
             reinst     = n_reinst) |>
      arrange(desc(n_awards))
    highchart() |>
      hc_chart(type = "bar", plotBackgroundColor = stern_bg_surface,
               style = list(fontFamily = "Source Sans 3", fontSize = "13px")) |>
      hc_xAxis(categories = pf$directorate, reversed = FALSE,
               labels = list(style = list(fontSize = "12px",
                                          color = stern_text_body))) |>
      hc_yAxis(title = list(text = NULL),
               labels = list(style = list(fontSize = "12px",
                                          color = stern_text_body)),
               reversedStacks = FALSE) |>
      hc_plotOptions(series = list(stacking = "normal", borderWidth = 0)) |>
      hc_add_series(name = "Never disrupted", data = pf$survived,
                    color = stern_palette[["olive"]]) |>
      hc_add_series(name = "Possible untracked disruption", data = pf$unreported,
                    color = "#9D9783") |>
      hc_add_series(name = "Terminated, reinstated", data = pf$reinst,
                    color = stern_palette[["mustard"]]) |>
      hc_add_series(name = "Terminated, still terminated", data = pf$stuck,
                    color = stern_palette[["rust"]]) |>
      hc_legend(itemStyle = list(fontSize = "12px"),
                align = "center", verticalAlign = "bottom",
                layout = "horizontal") |>
      hc_tooltip(shared = TRUE, style = list(fontSize = "12px")) |>
      hc_add_theme(hc_theme_stern())
  })

  # -- Timing tab outputs (charts) -----------------------------------------

  output$phase_timeline <- renderHighchart({
    df <- phase_timeline_data()
    df$ts <- datetime_to_timestamp(as.POSIXct(df$month, tz = "UTC"))
    new_dollar   <- lapply(seq_len(nrow(df)), function(i)
      list(df$ts[i], round(df$new_m[i], 1)))
    clawback_ser <- lapply(seq_len(nrow(df)), function(i)
      list(df$ts[i], round(df$clawback_m[i], 1)))
    term_series  <- lapply(seq_len(nrow(df)), function(i)
      list(df$ts[i], df$n_terms[i]))

    # Date anchors
    first_t     <- datetime_to_timestamp(as.POSIXct("2025-04-18", tz = "UTC"))
    freeze_date <- datetime_to_timestamp(as.POSIXct("2025-04-30", tz = "UTC"))
    eo_date     <- datetime_to_timestamp(as.POSIXct("2025-08-07", tz = "UTC"))
    fy26_st     <- datetime_to_timestamp(as.POSIXct("2025-10-01", tz = "UTC"))
    # Reporting-lag band: data was pulled 2026-04-06; March 2026 is partial.
    lag_from <- datetime_to_timestamp(as.POSIXct("2026-03-01", tz = "UTC"))
    lag_to   <- datetime_to_timestamp(as.POSIXct("2026-04-01", tz = "UTC"))

    # Seasonality bands within the Jan 2025 - Mar 2026 window
    aug_oct_bands <- list(
      # Reporting-lag shaded band
      list(from  = lag_from, to = lag_to,
           color = "rgba(168, 90, 75, 0.10)",
           label = list(text = "Partial reporting<br>(data pulled Apr 6 2026)",
                        style = list(color = stern_palette[["rust"]],
                                     fontSize = "11px", fontStyle = "italic"),
                        verticalAlign = "top", y = 14))
    )

    highchart() |>
      hc_chart(zoomType = "x",
               plotBackgroundColor = stern_bg_surface,
               style = list(fontFamily = "Source Sans 3", fontSize = "13px")) |>
      hc_title(text = NULL) |>
      hc_subtitle(text = NULL) |>
      hc_xAxis(type = "datetime",
        labels = list(style = list(fontSize = "12px", color = stern_text_body)),
        plotBands = aug_oct_bands,
        plotLines = list(
          list(value = freeze_date, color = stern_palette[["navy"]],
               width = 2, dashStyle = "ShortDash",
               label = list(text = "NSF funding freeze<br>Apr 30 2025",
                            style = list(color = stern_palette[["navy"]],
                                         fontSize = "11px", fontWeight = "bold"),
                            verticalAlign = "top", y = 14, rotation = 0)),
          list(value = eo_date, color = stern_palette[["navy"]],
               width = 1.5, dashStyle = "ShortDash",
               label = list(text = "EO 14332<br>Aug 7 2025",
                            style = list(color = stern_palette[["navy"]],
                                         fontSize = "11px", fontWeight = "bold"),
                            verticalAlign = "top", y = 14, rotation = 0)),
          list(value = fy26_st, color = stern_palette[["walnut"]],
               width = 1.5, dashStyle = "ShortDash",
               label = list(text = "FY26 starts<br>Oct 1 2025",
                            style = list(color = stern_palette[["walnut"]],
                                         fontSize = "11px", fontWeight = "bold"),
                            verticalAlign = "top", y = 14, rotation = 0))
        )) |>
      hc_yAxis_multiples(
        list(title = list(text = NULL),
             labels = list(style = list(fontSize = "12px", color = stern_text_body),
                           format = "${value}M"),
             min = 0, lineColor = stern_palette[["olive"]]),
        list(title = list(text = "Terminations",
                          style = list(fontSize = "13px", color = stern_text_body)),
             labels = list(style = list(fontSize = "12px", color = stern_text_body)),
             min = 0, opposite = TRUE, lineColor = stern_palette[["rust"]])) |>
      hc_add_series(name = "New obligations ($M)",
                    type = "column", data = new_dollar, yAxis = 0,
                    color = stern_palette[["olive"]],
                    pointPadding = 0.05, groupPadding = 0.05) |>
      hc_add_series(name = "Clawbacks ($M deobligated)",
                    type = "line", data = clawback_ser, yAxis = 0,
                    color = stern_palette[["mustard"]],
                    lineWidth = 2,
                    marker = list(enabled = TRUE, radius = 3)) |>
      hc_add_series(name = "Terminations (count, right axis)",
                    type = "line", data = term_series, yAxis = 1,
                    color = stern_palette[["rust"]],
                    lineWidth = 2.5,
                    marker = list(enabled = TRUE, radius = 4)) |>
      hc_legend(itemStyle = list(fontSize = "12px", fontWeight = "normal"),
                align = "center", verticalAlign = "bottom",
                layout = "horizontal") |>
      hc_tooltip(shared = TRUE, xDateFormat = "%B %Y",
                 style = list(fontSize = "12px")) |>
      hc_add_theme(hc_theme_stern())
  })

  output$baseline_chart <- renderHighchart({
    md <- monthly_baseline()
    range_data <- lapply(seq_len(nrow(md)), function(i)
      list(md$cal_month[i], round(md$low[i], 1), round(md$high[i], 1)))
    mean_data  <- lapply(seq_len(nrow(md)), function(i)
      list(md$cal_month[i], round(md$mean_m[i], 1)))
    # Split FY26 into "complete" and "partial" so March can be styled differently.
    fy26_complete <- lapply(which(!is.na(md$fy26_m) & md$cal_month %in% c(1, 2)),
      function(i) list(md$cal_month[i], round(md$fy26_m[i], 1)))
    fy26_partial  <- lapply(which(!is.na(md$fy26_m) & md$cal_month == 3),
      function(i) list(md$cal_month[i], round(md$fy26_m[i], 1)))

    highchart() |>
      hc_chart(plotBackgroundColor = stern_bg_surface,
               style = list(fontFamily = "Source Sans 3", fontSize = "13px")) |>
      hc_title(text = NULL) |>
      hc_subtitle(text = NULL) |>
      hc_xAxis(type = "linear", min = 1, max = 12, tickInterval = 1,
               categories = month.abb, title = list(text = NULL),
               labels = list(style = list(fontSize = "12px",
                                          color = stern_text_body)),
               plotBands = list(
                 list(from = 7.5, to = 8.5,
                      color = "rgba(212, 168, 67, 0.10)"),
                 list(from = 9.5, to = 10.5,
                      color = "rgba(120, 120, 120, 0.06)"))) |>
      hc_yAxis(title = list(text = NULL),
               labels = list(style = list(fontSize = "12px",
                                          color = stern_text_body),
                             format = "${value}M"),
               min = 0) |>
      hc_add_series(name = "FY23-25 baseline range (±1σ)",
                    type = "arearange", data = range_data,
                    color = stern_palette[["olive"]],
                    fillOpacity = 0.18, lineWidth = 0,
                    marker = list(enabled = FALSE), zIndex = 1) |>
      hc_add_series(name = "FY23-25 baseline mean",
                    type = "line", data = mean_data,
                    color = stern_palette[["olive"]],
                    lineWidth = 1.5, dashStyle = "ShortDash",
                    marker = list(enabled = FALSE), zIndex = 2) |>
      hc_add_series(name = "FY26 actual (complete months)",
                    type = "line", data = fy26_complete,
                    color = stern_palette[["mustard"]],
                    lineWidth = 3,
                    marker = list(enabled = TRUE, radius = 6), zIndex = 3) |>
      hc_add_series(name = "FY26 actual (partial month)",
                    type = "line", data = fy26_partial,
                    color = stern_palette[["mustard"]],
                    lineWidth = 0,
                    marker = list(enabled = TRUE, radius = 6,
                                  fillColor = "white",
                                  lineColor = stern_palette[["mustard"]],
                                  lineWidth = 2), zIndex = 3) |>
      hc_legend(itemStyle = list(fontSize = "12px"),
                align = "center", verticalAlign = "bottom",
                layout = "horizontal") |>
      hc_tooltip(shared = TRUE, valueSuffix = "M",
                 valuePrefix = "$", valueDecimals = 1,
                 style = list(fontSize = "12px")) |>
      hc_add_theme(hc_theme_stern())
  })

  # -- Impact tab outputs --------------------------------------------------

  output$topic_clusters <- renderHighchart({
    td <- topic_data() |> arrange(pct_reinst)
    total_pts  <- lapply(seq_len(nrow(td)), function(i)
      list(name = td$topic[i], y = td$n_terms[i]))
    reinst_pts <- lapply(seq_len(nrow(td)), function(i) {
      list(name = td$topic[i], y = td$n_reinst[i],
           n_terms = td$n_terms[i],
           pct_reinst = td$pct_reinst[i],
           color = if (td$pct_reinst[i] >= 50) stern_palette[["olive"]]
                   else if (td$pct_reinst[i] >= 25) stern_palette[["mustard"]]
                   else stern_palette[["rust"]])
    })
    highchart() |>
      hc_chart(type = "bar", plotBackgroundColor = stern_bg_surface,
               style = list(fontFamily = "Source Sans 3", fontSize = "13px")) |>
      hc_xAxis(categories = td$topic,
               labels = list(style = list(fontSize = "12px",
                                          color = stern_text_body))) |>
      hc_yAxis(title = list(text = NULL),
               labels = list(style = list(fontSize = "12px",
                                          color = stern_text_body)),
               min = 0) |>
      hc_plotOptions(series = list(grouping = FALSE, borderWidth = 0)) |>
      hc_add_series(name = "Total terminations", data = total_pts,
                    color = stern_bg_secondary,
                    enableMouseTracking = FALSE) |>
      hc_add_series(name = "Reinstated", data = reinst_pts) |>
      hc_legend(enabled = TRUE,
                align = "center", verticalAlign = "bottom",
                layout = "horizontal",
                itemStyle = list(fontSize = "12px")) |>
      hc_tooltip(useHTML = TRUE, style = list(fontSize = "12px"),
                 pointFormat = "<b>{point.name}</b><br>
                                {point.y:,.0f} reinstated of
                                {point.n_terms:,.0f} terminations
                                ({point.pct_reinst}%)") |>
      hc_add_theme(hc_theme_stern())
  })

  output$state_choropleth <- renderHighchart({
    sd <- state_data()
    sd$us_code <- paste0("us-", tolower(sd$state_code))
    color_max <- max(8, ceiling(max(sd$pct_terminated, na.rm = TRUE)))
    rows <- lapply(seq_len(nrow(sd)), function(i) {
      list(`hc-key` = sd$us_code[i],
           value     = sd$pct_terminated[i],
           state     = sd$state_code[i],
           n_terms   = sd$n_terms[i],
           n_active  = sd$n_active[i],
           deobl_m   = sd$deobl_m[i],
           active_m  = sd$active_m[i])
    })
    highchart(type = "map") |>
      hc_add_series(mapData = us_states_map, data = rows, value = "value",
                    joinBy = "hc-key", name = "% of state's NSF grants terminated",
                    dataLabels = list(enabled = FALSE),
                    borderColor = stern_border, borderWidth = 0.4) |>
      hc_chart(style = list(fontFamily = "Source Sans 3", fontSize = "13px")) |>
      hc_colorAxis(minColor = stern_bg_secondary,
                   maxColor = stern_palette[["rust"]],
                   min = 0, max = color_max,
                   labels = list(style = list(fontSize = "12px"),
                                 format = "{value}%")) |>
      hc_legend(itemStyle = list(fontSize = "12px"),
                align = "center", verticalAlign = "bottom",
                layout = "horizontal",
                title = list(text = "% of state's NSF grants terminated",
                             style = list(fontSize = "12px",
                                          color = stern_text_body))) |>
      hc_tooltip(useHTML = TRUE, style = list(fontSize = "12px"),
                 headerFormat = "<b>{point.name}</b><br>",
                 pointFormat = "Terminated: <b>{point.value}%</b> of state's grants<br>
                                {point.n_terms:,.0f} terminated of
                                {point.n_active:,.0f} active<br>
                                Deobligated: ${point.deobl_m:,.2f}M") |>
      hc_mapNavigation(enabled = TRUE) |>
      hc_add_theme(hc_theme_stern())
  })

  top_programs_data <- reactive({
    dbGetQuery(pool, "
      SELECT COALESCE(directorate, '(none)') AS directorate,
             COALESCE(nsf_program_name, '(none)') AS program,
             COUNT(*) AS terms,
             SUM(CASE WHEN reinstated THEN 1 ELSE 0 END) AS reinst,
             ROUND((ABS(COALESCE(SUM(post_termination_deobligation), 0))/1e6)::numeric, 2) AS deobl_m
      FROM terminations
      WHERE nsf_program_name IS NOT NULL
      GROUP BY 1, 2 HAVING COUNT(*) >= 10
      ORDER BY terms DESC LIMIT 15")
  }) |> bindCache("top_programs_v1")

  output$top_programs_tbl <- renderDT({
    datatable(top_programs_data(), rownames = FALSE,
              options = list(pageLength = 15, dom = "t", ordering = TRUE),
              colnames = c("Directorate", "Program", "Terms", "Reinst", "Deobl ($M)"))
  })

  top_recipients_data <- reactive({
    dbGetQuery(pool, "
      SELECT r.recipient_name, r.state_code,
             COUNT(*) AS terms,
             SUM(CASE WHEN t.reinstated THEN 1 ELSE 0 END) AS reinst,
             ROUND((ABS(COALESCE(SUM(t.post_termination_deobligation), 0))/1e6)::numeric, 2) AS deobl_m
      FROM terminations t
      JOIN awards a ON a.award_id_fain = t.award_id_fain
      JOIN recipients r ON r.recipient_uei = a.recipient_uei
      GROUP BY 1, 2 ORDER BY deobl_m DESC LIMIT 15")
  }) |> bindCache("top_recipients_v1")

  output$top_recipients_tbl <- renderDT({
    datatable(top_recipients_data(), rownames = FALSE,
              options = list(pageLength = 15, dom = "t", ordering = TRUE),
              colnames = c("Institution", "State", "Terms", "Reinst", "Deobl ($M)"))
  })

  # -- Recovery tab outputs ------------------------------------------------

  output$reinst_velocity <- renderHighchart({
    rv <- reinst_velocity_data()
    rv$bin <- cut(as.numeric(rv$days),
                  breaks = c(0, 30, 60, 90, 120, 180, 250),
                  labels = c("0-30d", "31-60d", "61-90d",
                             "91-120d", "121-180d", "181d+"),
                  include.lowest = TRUE)
    rv <- rv[!is.na(rv$bin) & !is.na(rv$topic), ]

    bins        <- levels(rv$bin)
    topic_order <- c("DEI / broadening", "education / training",
                     "social / behavioral", "climate / environment",
                     "health / biomedical", "computing / AI",
                     "energy", "physical sci", "other / uncategorized")
    topic_color <- c(
      "DEI / broadening"      = stern_palette[["rust"]],
      "education / training"  = stern_palette[["mustard"]],
      "social / behavioral"   = stern_palette[["walnut"]],
      "climate / environment" = stern_palette[["olive"]],
      "health / biomedical"   = stern_palette[["navy"]],
      "computing / AI"        = "#7E8E92",
      "energy"                = "#B89968",
      "physical sci"          = "#5E6F4D",
      "other / uncategorized" = "#A8A294"
    )
    topics_present <- intersect(topic_order, unique(as.character(rv$topic)))

    hc <- highchart() |>
      hc_chart(type = "column", plotBackgroundColor = stern_bg_surface,
               style = list(fontFamily = "Source Sans 3", fontSize = "13px")) |>
      hc_xAxis(categories = bins,
               title = list(text = NULL),
               labels = list(style = list(fontSize = "12px",
                                          color = stern_text_body))) |>
      hc_yAxis(title = list(text = NULL),
               labels = list(style = list(fontSize = "12px",
                                          color = stern_text_body))) |>
      hc_plotOptions(series = list(stacking = "normal", borderWidth = 0))

    for (tp in topics_present) {
      counts_per_bin <- vapply(bins, function(b)
        sum(rv$bin == b & rv$topic == tp), integer(1))
      hc <- hc |> hc_add_series(name = tp,
                                data = unname(counts_per_bin),
                                color = unname(topic_color[tp]))
    }

    hc |>
      hc_legend(itemStyle = list(fontSize = "11px"),
                align = "center", verticalAlign = "bottom",
                layout = "horizontal") |>
      hc_tooltip(shared = TRUE, style = list(fontSize = "12px")) |>
      hc_add_theme(hc_theme_stern())
  })

  recovered_programs_data <- reactive({
    dbGetQuery(pool, "
      SELECT directorate, nsf_program_name AS program,
             COUNT(*) AS terms,
             SUM(CASE WHEN reinstated THEN 1 ELSE 0 END) AS reinst,
             ROUND((100.0*SUM(CASE WHEN reinstated THEN 1 ELSE 0 END)/COUNT(*))::numeric, 1) AS pct_reinst
      FROM terminations WHERE nsf_program_name IS NOT NULL
      GROUP BY 1, 2 HAVING COUNT(*) >= 8
        AND SUM(CASE WHEN reinstated THEN 1 ELSE 0 END)*1.0/COUNT(*) >= 0.5
      ORDER BY pct_reinst DESC, reinst DESC LIMIT 12")
  }) |> bindCache("recovered_programs_v1")

  output$recovered_programs_tbl <- renderDT({
    datatable(recovered_programs_data(), rownames = FALSE,
              options = list(pageLength = 12, dom = "t"),
              colnames = c("Directorate", "Program", "Terms", "Reinst", "% Reinst"))
  })

  stuck_programs_data <- reactive({
    dbGetQuery(pool, "
      SELECT directorate, nsf_program_name AS program,
             COUNT(*) AS terms,
             SUM(CASE WHEN reinstated THEN 1 ELSE 0 END) AS reinst,
             ROUND((100.0*SUM(CASE WHEN reinstated THEN 1 ELSE 0 END)/COUNT(*))::numeric, 1) AS pct_reinst
      FROM terminations WHERE nsf_program_name IS NOT NULL
      GROUP BY 1, 2 HAVING COUNT(*) >= 15
      ORDER BY pct_reinst ASC, terms DESC LIMIT 12")
  }) |> bindCache("stuck_programs_v1")

  output$stuck_programs_tbl <- renderDT({
    datatable(stuck_programs_data(), rownames = FALSE,
              options = list(pageLength = 12, dom = "t"),
              colnames = c("Directorate", "Program", "Terms", "Reinst", "% Reinst"))
  })

  # -- About tab counts ----------------------------------------------------
  about_counts <- reactive({
    dbGetQuery(pool, "
      SELECT (SELECT COUNT(*) FROM transactions)   AS n_tx,
             (SELECT COUNT(*) FROM awards)         AS n_awards,
             (SELECT COUNT(*) FROM opportunities)  AS n_opps,
             (SELECT COUNT(*) FROM terminations)   AS n_terms")
  }) |> bindCache("about_counts_v1")

  output$about_n_tx     <- renderText({ format(about_counts()$n_tx,     big.mark = ",") })
  output$about_n_awards <- renderText({ format(about_counts()$n_awards, big.mark = ",") })
  output$about_n_opps   <- renderText({ format(about_counts()$n_opps,   big.mark = ",") })
  output$about_n_terms  <- renderText({ format(about_counts()$n_terms,  big.mark = ",") })
}

shinyApp(ui = ui, server = server)
