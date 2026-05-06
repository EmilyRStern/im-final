# =============================================================================
# app.R  -  NSF Grant Lifecycle Disruption Analysis
# EPPS 6354 Information Management - Spring 2026 - Emily Stern
#
# Reads from Neon Postgres (NEON_DB_URL) and renders a Shiny dashboard styled
# with the `stern` design-system R package. Anchored on the Apr 30 2025 NSF
# funding freeze; EO 14332 (Aug 7 2025) follows and formalizes oversight.
#
# Three tabs, each anchored to one stage of the disruption lifecycle:
#   1. Overview             - headline KPIs + phase timeline + topic recovery
#                             + days-to-reinstatement + top programs
#   2. Institution Explorer - search any academic institution; donut of
#                             active funding by directorate + termination focus
#   3. Methods              - sources, definitions, and limitations
#
# Run locally:  shiny::runApp("shiny/")
# Deploy:       see shiny/README.md
# =============================================================================

# -- Packages ---------------------------------------------------------------
required <- c("shiny", "bslib", "DBI", "RPostgres", "pool", "DT", "dplyr",
              "highcharter", "scales", "stern", "jsonlite", "showtext")
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
  library(scales);  library(stern); library(rsconnect); library(showtext)
})
stern_setup_fonts()

# Shared mappings (CFDA->directorate, project-title->topic).
source("_helpers.R")

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

# Academic-only scoping. The whole tool is restricted to colleges and
# universities -- non-academic awardees (companies, foundations,
# government labs, etc.) are filtered out everywhere a query touches
# recipients/awards/transactions/terminations. The match is name-based:
# UNIVERSITY, COLLEGE, INSTITUTE OF TECHNOLOGY, and POLYTECHNIC catch
# essentially every U.S. higher-ed institution that shows up in NSF
# obligations data. Edge cases (e.g. "MITRE", "RAND") are intentionally
# excluded.
ACADEMIC_UEIS_SUBQ <- "(SELECT recipient_uei FROM recipients
  WHERE recipient_name ILIKE '%UNIVERSITY%'
     OR recipient_name ILIKE '%COLLEGE%'
     OR recipient_name ILIKE '%INSTITUTE OF TECHNOLOGY%'
     OR recipient_name ILIKE '%POLYTECHNIC%')"
ACADEMIC_FAINS_SUBQ <- paste0(
  "(SELECT a.award_id_fain FROM awards a WHERE a.recipient_uei IN ",
  ACADEMIC_UEIS_SUBQ, ")")

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
     .card-footer { padding-top: 4px; padding-bottom: 6px; }
     /* data-vintage badge pinned in the navbar */
     .data-vintage {
       font-family: 'Source Sans 3', sans-serif; font-size: 0.72rem;
       color: #6b6457; padding: 6px 14px 0 12px; letter-spacing: 0.02em;
       white-space: nowrap;
     }"
  ))),

    # ----- Tab 1: Overview -----------------------------------------------
    nav_panel(
      title = "Overview",
      div(style = "padding: 8px 4px 0 4px;",
        h2("Disruption and recovery across academic NSF funding",
           style = sprintf("color: %s; margin-top: 8px;",
                           stern_text_primary)),

        uiOutput("pipeline_stats"),

        chart_card(
          "Monthly NSF obligations, clawbacks, and terminations with policy anchors",
          440, "phase_timeline",
          "Terminations begin shortly after the April 30 funding freeze and
           accelerate through May. EO 14332 (Aug 7) follows, coinciding with
           the annual obligation surge before FY26."
        ),

        chart_card(
          "Which terminated topics recovered?",
          300, "topic_clusters",
          "Bars sorted ascending by count of reinstatements. Gray
           background is total terminations in that topic; the olive
           bar is how many of those were reinstated. Tooltip carries
           the reinstatement rate. Topic clusters are derived by regex
           on project titles — illustrative, not authoritative."
        ),

        chart_card(
          "Days from termination to reinstatement, by topic",
          340, "reinst_velocity",
          "Boxes show median and IQR of days-to-reinstatement; whiskers
           reach the most extreme value within 1.5x IQR. Outlier dots
           sit beyond. Wider boxes mean more variable recovery times
           within a topic. The 13-day floor is the citizen-tracker's
           reporting cadence, not the minimum administrative turnaround."
        ),

        card(
          card_header(section_caption("Top-15 most-affected NSF programs (by termination count)")),
          DTOutput("top_programs_tbl")
        )
      )
    ),

    # ----- Tab 2: Institution Explorer -----------------------------------
    nav_panel(
      title = "Institution Explorer",
      div(style = "padding: 8px 4px 0 4px;",
        h2("Institution Explorer",
           style = sprintf("color: %s; margin-top: 8px;",
                           stern_text_primary)),
        narrative_p(
          "Pick a state (or leave at \"All states\") and start typing
           any part of an institution's name. Active funding spans the
           full portfolio; termination metrics use the at-risk pool
           (awards live on Apr 30, 2025) as denominator."),

        div(style = "max-width: 1000px; margin-bottom: 14px;",
          layout_columns(
            col_widths = c(3, 3, 4, 2),
            selectInput("inst_state", label = NULL,
                        choices = c("All states" = "ALL"),
                        selected = "ALL"),
            div(style = "padding-top: 6px;",
              checkboxInput("inst_terms_only",
                            "With terminations only",
                            value = FALSE)),
            selectizeInput("inst_uei", label = NULL, choices = NULL,
              options = list(
                placeholder = "Type any part of the institution's name...",
                maxOptions   = 25,
                openOnFocus  = FALSE,
                loadThrottle = 300)),
            actionButton("inst_search_go", "Search",
                         class = "btn-primary",
                         style = "width: 100%;"))),

        layout_columns(
          col_widths = c(5, 7),
          row_heights = "420px",
          uiOutput("inst_overview"),
          card(
            full_screen = TRUE,
            height = "420px",
            card_header(
              div(style = "display: flex; align-items: center;
                          justify-content: space-between;",
                section_caption("Active NSF funding by directorate"),
                actionLink(
                  "dir_glossary_show", "ⓘ",
                  style = sprintf(
                    "color: %s; cursor: pointer;
                     text-decoration: none; font-size: 1.05rem;",
                    stern_text_muted),
                  title = "What do these directorate codes mean?")
              )
            ),
            # flex-fill + min-height: 0 lets the chart claim every
            # remaining pixel of the card body. height = "100%" on the
            # highchartOutput then resolves to a real pixel value, so
            # Highcharts can render the donut at full size instead of
            # falling back to its default 400 px.
            div(style = "flex: 1 1 auto; min-height: 0;
                         padding: 4px 8px 8px 8px;",
              highchartOutput("inst_funding_donut",
                              width = "100%", height = "100%"))
          )
        ),

        uiOutput("inst_callouts"),

        div(style = "margin-top: 18px;",
            section_caption("Where this institution has been most affected")),
        narrative_p(
          "Awards flagged by the citizen-science termination tracker.
           Click 'read abstract' to view program description. If the
           institution has no terminations on record, this table will
           be empty."),
        card(
          DTOutput("inst_term_tbl"),
          card_footer(
            implications(
              "Project title, division, and abstract are populated from
               the termination tracker; active awards do not carry these
               fields."))
        )
      )
    ),

    # ----- Tab 3: Methods ------------------------------------------------
    nav_panel(
      title = "Methods",
      div(style = "padding: 14px 18px; max-width: 760px;
                   font-family: 'Source Serif 4';
                   font-size: 0.92rem; line-height: 1.45;",
        h3("About this analysis",
           style = sprintf("color: %s;", stern_text_primary)),
        p("Lifecycle analysis of NSF grant disruption in universities (FY23-FY26), anchored
          on the April 30, 2025 NSF funding freeze. EO 14332
          \"Improving Oversight of Federal Grantmaking\" (Aug 7, 2025)
          follows the operational shock and formalizes oversight. Three
          federal data sources are joined into a 6-table Postgres schema
          covering the opportunity → award → termination → reinstatement
          lifecycle:"),
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

        h4("Limitations",
           style = sprintf("color: %s; margin-top: 16px;", stern_text_primary)),
        tags$ul(
          tags$li(strong("Descriptive only."), " This is a comparison
                  against historical baselines, not a causal estimate.
                  No interrupted-time-series, regression, or
                  synthetic-control analysis is reported. Patterns
                  consistent with policy targeting are noted as
                  patterns, not as caused by any specific action."),
          tags$li(strong("Citizen-tracker undercount."), " The
                  terminations dataset is volunteer-maintained
                  (Ross / Delaney). Coverage of small-dollar or
                  obscure-program terminations is uneven. The
                  \"possible untracked disruption\" segment in the
                  Lifecycle funnel uses a >$100K USAspending
                  net-deobligation threshold to flag likely undercount."),
          tags$li(strong("Reporting lag."), " USAspending typically lags
                  federal action by 30-60 days. The data was pulled
                  Apr 6, 2026, so March 2026 transactions only include
                  through Mar 14. The March marker is shown open to flag
                  this.")
        ),

        p(style = sprintf("color: %s; font-size: 0.85rem;", stern_text_muted),
          "EPPS 6354 Information Management - University of Texas at Dallas
           - Spring 2026 - Emily Stern - Data through 2026-04-06.")
      )
    ),

  # Pin the data-vintage badge in the navbar (right side, after all tabs)
  # so a reader landing on any tab sees it without clicking Methods.
  nav_spacer(),
  nav_item(span(class = "data-vintage",
                "Data through 2026-04-06 — March 2026 partial"))
)

# -- SERVER -----------------------------------------------------------------
server <- function(input, output, session) {

  # -- Reactives (cached pulls) --------------------------------------------

  termination_totals <- reactive({
    dbGetQuery(pool, paste0("
      SELECT COUNT(*)                                            AS n_terms,
             SUM(CASE WHEN reinstated THEN 1 ELSE 0 END)         AS n_reinst,
             ABS(COALESCE(SUM(post_termination_deobligation),0)) AS deob
      FROM terminations
      WHERE award_id_fain IN ", ACADEMIC_FAINS_SUBQ))
  }) |> bindCache("termination_totals_acad_v1")

  pre_post <- reactive({
    # Pre-period = FY25 H1 (Oct 2024 - Mar 2025): the closest-in-time
    # half-year that is entirely pre-freeze. Earlier this used FY24 H1,
    # which had two problems: (1) further from the disruption, so a
    # noisier baseline, and (2) it included the Feb 2024 TIP $151M
    # administrative re-obligation, inflating the TIP denominator and
    # exaggerating its drop. FY25 H1 has neither issue.
    #
    # At-risk pool for the post side = awards whose period of performance
    # spanned Apr 30, 2025 (the freeze date) -- i.e. awards that were
    # actually live on the day of the disruption. Earlier this was
    # "awards with post-Apr 2025 transactions or in the tracker," which
    # was endogenous to the disruption itself.
    dbGetQuery(pool, paste0("
      WITH pre AS (
        SELECT awarding_sub_agency_name AS dir,
          ROUND((100.0 * (1 - COALESCE(SUM(CASE WHEN action_date >= '2025-10-01' AND action_date < '2026-04-01'
                                              THEN federal_action_obligation END), 0)
              / NULLIF(SUM(CASE WHEN action_date >= '2024-10-01' AND action_date < '2025-04-01'
                                THEN federal_action_obligation END), 0)))::numeric, 1) AS pre_drop_pct,
          SUM(CASE WHEN action_date >= '2024-10-01' AND action_date < '2025-04-01'
                   THEN federal_action_obligation END)/1e6 AS fy25h1_m
        FROM transactions
        WHERE action_type_description = 'NEW'
          AND recipient_uei IN ", ACADEMIC_UEIS_SUBQ, "
        GROUP BY 1
      ),
      post AS (
        SELECT a.awarding_sub_agency_name AS dir,
               COUNT(DISTINCT a.award_unique_key)::int AS n_awards,
               COUNT(DISTINCT t.termination_id)::int   AS n_terms,
               ROUND((100.0 * COUNT(DISTINCT t.termination_id)
                     / NULLIF(COUNT(DISTINCT a.award_unique_key), 0))::numeric, 2) AS post_term_pct
        FROM awards a LEFT JOIN terminations t ON t.award_id_fain = a.award_id_fain
        WHERE a.period_of_perf_start <= '2025-04-30'
          AND a.period_of_perf_end   >= '2025-04-30'
          AND a.recipient_uei IN ", ACADEMIC_UEIS_SUBQ, "
        GROUP BY 1
      )
      SELECT pre.dir, pre.pre_drop_pct, ROUND(pre.fy25h1_m::numeric, 0) AS fy25h1_m,
             post.n_awards, post.n_terms, post.post_term_pct
      FROM pre LEFT JOIN post ON pre.dir = post.dir
      WHERE pre.dir <> 'OTHER' ORDER BY pre.pre_drop_pct DESC NULLS LAST"))
  }) |> bindCache("pre_post_acad_v1")

  phase_timeline_data <- reactive({
    dbGetQuery(pool, paste0("
      WITH new_awards AS (
        SELECT date_trunc('month', action_date)::date AS month,
               COUNT(*)::int AS n_new,
               SUM(CASE WHEN federal_action_obligation > 0
                        THEN federal_action_obligation ELSE 0 END) / 1e6 AS new_m
        FROM transactions
        WHERE action_type_description = 'NEW'
          AND action_date >= '2025-01-01'
          AND action_date <  '2026-04-01'
          AND recipient_uei IN ", ACADEMIC_UEIS_SUBQ, "
        GROUP BY 1),
      clawbacks AS (
        SELECT date_trunc('month', action_date)::date AS month,
               ABS(SUM(federal_action_obligation)) / 1e6 AS clawback_m
        FROM transactions
        WHERE federal_action_obligation < 0
          AND action_date >= '2025-01-01'
          AND action_date <  '2026-04-01'
          AND recipient_uei IN ", ACADEMIC_UEIS_SUBQ, "
        GROUP BY 1),
      terms AS (
        SELECT date_trunc('month', latest_termination_date)::date AS month,
               COUNT(*)::int AS n_terms
        FROM terminations
        WHERE latest_termination_date IS NOT NULL
          AND latest_termination_date >= '2025-01-01'
          AND latest_termination_date <  '2026-04-01'
          AND award_id_fain IN ", ACADEMIC_FAINS_SUBQ, "
        GROUP BY 1)
      SELECT COALESCE(a.month, c.month, t.month) AS month,
             COALESCE(a.n_new,      0)::int  AS n_new,
             COALESCE(a.new_m,      0)  AS new_m,
             COALESCE(c.clawback_m, 0)  AS clawback_m,
             COALESCE(t.n_terms,    0)::int  AS n_terms
      FROM new_awards a
      FULL OUTER JOIN clawbacks c ON a.month = c.month
      FULL OUTER JOIN terms     t ON COALESCE(a.month, c.month) = t.month
      ORDER BY 1"))
  }) |> bindCache("phase_timeline_acad_v1")

  topic_data <- reactive({
    dbGetQuery(pool, paste0("
      WITH labeled AS (
        SELECT ", topic_case_sql("project_title"), " AS topic, reinstated
        FROM terminations
        WHERE award_id_fain IN ", ACADEMIC_FAINS_SUBQ, "
      )
      SELECT topic, COUNT(*)::int AS n_terms,
             SUM(CASE WHEN reinstated THEN 1 ELSE 0 END)::int AS n_reinst,
             ROUND((100.0 * SUM(CASE WHEN reinstated THEN 1 ELSE 0 END)
                   / COUNT(*))::numeric, 1) AS pct_reinst
      FROM labeled GROUP BY 1 ORDER BY n_terms DESC"))
  }) |> bindCache("topic_data_acad_v1")

  reinst_velocity_data <- reactive({
    dbGetQuery(pool, paste0("
      SELECT (reinstatement_date - latest_termination_date) AS days,
             ", topic_case_sql("project_title"), " AS topic
      FROM terminations
      WHERE reinstated = TRUE
        AND reinstatement_date IS NOT NULL
        AND latest_termination_date IS NOT NULL
        AND award_id_fain IN ", ACADEMIC_FAINS_SUBQ))
  }) |> bindCache("reinst_velocity_acad_v1")

  # -- Impact tab KPIs -----------------------------------------------------

  output$pipeline_stats <- renderUI({
    tt <- termination_totals()
    pp <- pre_post()
    edu_post <- pp |> filter(dir == "EDU") |> head(1)

    pt      <- phase_timeline_data()
    pt_d    <- as.Date(pt$month)
    fy26_h1 <- sum(pt$new_m[pt_d >= as.Date("2025-10-01") &
                            pt_d <  as.Date("2026-04-01")], na.rm = TRUE)
    fy25_h1 <- sum(pt$new_m[pt_d >= as.Date("2024-10-01") &
                            pt_d <  as.Date("2025-04-01")], na.rm = TRUE)
    yoy_pct <- if (fy25_h1 > 0) 100 * (fy26_h1 - fy25_h1) / fy25_h1 else NA_real_

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
          label   = "Terminated",
          value   = scales::comma(tt$n_terms),
          context = sprintf("%s reinstated (%.0f%%)",
                            scales::comma(tt$n_reinst),
                            100 * tt$n_reinst / tt$n_terms),
          accent  = "rust"
        ),
        stern_stat_callout(
          label   = "FY26 H1 obligation decline",
          value   = if (is.na(yoy_pct)) "n/a" else sprintf("%+.0f%%", yoy_pct),
          context = "NEW obligations, Oct-Mar vs FY25",
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

  # -- Impact tab outputs --------------------------------------------------

  output$topic_clusters <- renderHighchart({
    # Sort topics ascending by count of reinstatements so the bars grow
    # in one direction. All reinstated bars are colored olive (green) --
    # the previous tri-color encoding (olive/mustard/rust by reinstate-
    # ment rate) double-encoded the same dimension as the bar length.
    td <- topic_data() |> arrange(n_reinst)
    total_pts  <- lapply(seq_len(nrow(td)), function(i)
      list(name = td$topic[i], y = td$n_terms[i]))
    reinst_pts <- lapply(seq_len(nrow(td)), function(i) {
      list(name = td$topic[i], y = td$n_reinst[i],
           n_terms = td$n_terms[i],
           pct_reinst = td$pct_reinst[i])
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
      hc_add_series(name = "Reinstated", data = reinst_pts,
                    color = stern_palette[["olive"]]) |>
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

  top_programs_data <- reactive({
    dbGetQuery(pool, paste0("
      SELECT COALESCE(directorate, '(none)') AS directorate,
             COALESCE(nsf_program_name, '(none)') AS program,
             COUNT(*) AS terms,
             SUM(CASE WHEN reinstated THEN 1 ELSE 0 END) AS reinst,
             ROUND((ABS(COALESCE(SUM(post_termination_deobligation), 0))/1e6)::numeric, 2) AS deobl_m
      FROM terminations
      WHERE nsf_program_name IS NOT NULL
        AND award_id_fain IN ", ACADEMIC_FAINS_SUBQ, "
      GROUP BY 1, 2 HAVING COUNT(*) >= 10
      ORDER BY terms DESC LIMIT 15"))
  }) |> bindCache("top_programs_acad_v1")

  output$top_programs_tbl <- renderDT({
    datatable(top_programs_data(), rownames = FALSE,
              options = list(pageLength = 15, dom = "t", ordering = TRUE),
              colnames = c("Directorate", "Program", "Terms", "Reinst", "Deobl ($M)"))
  })

  # -- Institution Explorer tab -------------------------------------------

  # One row per (canonical_name, state_code). canonical_name strips
  # leading "THE", trailing common boilerplate ("DISTRICT", "INC",
  # "LLC", etc.), and normalizes whitespace -- so "Alamo Community
  # College" and "Alamo Community College District" merge into a single
  # row. ueis is the comma-joined list of UEIs that map into the group;
  # it's also used as the dropdown's selected value. n_terminations
  # surfaces in the dropdown label so users can spot the affected
  # institutions even before selecting them.
  inst_choices <- reactive({
    dbGetQuery(pool, "
      WITH cleaned AS (
        SELECT DISTINCT
               r.recipient_uei,
               COALESCE(r.state_code, '?') AS state_code,
               a.award_id_fain,
               TRIM(REGEXP_REPLACE(INITCAP(r.recipient_name), '\\s+', ' ', 'g'))
                 AS display_name,
               UPPER(TRIM(REGEXP_REPLACE(
                 REGEXP_REPLACE(
                   REGEXP_REPLACE(r.recipient_name,
                                  '^\\s*THE\\s+', '', 'i'),
                   '\\s*[,\\.]?\\s*(DISTRICT|DISTRICTS|INC|LLC|LLP|FOUNDATION|CORPORATION|CORP|COMPANY|CO|LIMITED|LTD)\\.?\\s*$',
                   '', 'i'),
                 '\\s+', ' ', 'g')))
                 AS canonical_name
        FROM recipients r
        JOIN awards a ON a.recipient_uei = r.recipient_uei
        WHERE r.recipient_name IS NOT NULL
          AND TRIM(r.recipient_name) <> ''
          AND (r.recipient_name ILIKE '%UNIVERSITY%'
            OR r.recipient_name ILIKE '%COLLEGE%'
            OR r.recipient_name ILIKE '%INSTITUTE OF TECHNOLOGY%'
            OR r.recipient_name ILIKE '%POLYTECHNIC%')
      )
      SELECT c.canonical_name,
             c.state_code,
             MIN(c.display_name)                                AS display_name,
             string_agg(DISTINCT c.recipient_uei, ',' ORDER BY c.recipient_uei)
                                                                AS ueis,
             COUNT(DISTINCT c.recipient_uei)                    AS n_variants,
             COUNT(DISTINCT t.termination_id)                   AS n_terminations
      FROM cleaned c
      LEFT JOIN terminations t ON t.award_id_fain = c.award_id_fain
      WHERE c.canonical_name <> ''
      GROUP BY c.canonical_name, c.state_code
      ORDER BY MIN(c.display_name)")
  }) |> bindCache("inst_choices_acad_v1")

  # Populate the state filter dropdown once the choices land.
  observe({
    ic <- inst_choices()
    states <- sort(unique(ic$state_code))
    updateSelectInput(session, "inst_state",
      choices = c("All states" = "ALL", setNames(states, states)))
  })

  # Whenever the state filter or "with terminations" toggle changes,
  # repopulate the institution search box. Clears any prior selection
  # so an out-of-state / now-filtered-out institution doesn't linger.
  # Server-side selectize so only the top 25 matches per keystroke
  # ship to the browser -- scales to tens of thousands of recipients.
  observe({
    ic <- inst_choices()
    state <- input$inst_state
    if (isTruthy(state) && state != "ALL") {
      ic <- ic[ic$state_code == state, ]
    }
    if (isTRUE(input$inst_terms_only)) {
      ic <- ic[ic$n_terminations > 0, ]
    }
    labels <- ifelse(ic$n_terminations > 0,
      sprintf("%s — %s (%d terminated)",
              ic$display_name, ic$state_code, ic$n_terminations),
      sprintf("%s — %s",
              ic$display_name, ic$state_code))
    updateSelectizeInput(session, "inst_uei",
      choices  = setNames(ic$ueis, labels),
      selected = character(0),
      server   = TRUE)
  })

  # Per-institution awards: full portfolio (no Apr-30 POP filter),
  # joined to any termination record. Carries termination-only
  # enrichments (project_title, division, abstract) that are NULL for
  # active rows. input$inst_uei is a comma-joined list of UEIs (one
  # canonical institution may map to several after merging); each is
  # shape-validated before inlining into the IN clause so RPostgres's
  # parameterized-query edge cases don't bite.
  #
  # Gated on the Search button (eventReactive) so picking an institution
  # in the dropdown does NOT auto-query; the user has to commit by
  # pressing Search. ignoreInit = TRUE keeps it from firing on session
  # start.
  inst_awards <- eventReactive(input$inst_search_go, {
    req(input$inst_uei, nzchar(input$inst_uei))
    uei_list <- strsplit(input$inst_uei, ",", fixed = TRUE)[[1]]
    if (!length(uei_list) ||
        !all(grepl("^[A-Z0-9]{12}$", uei_list))) return(data.frame())
    uei_in <- paste0("'", uei_list, "'", collapse = ", ")
    dbGetQuery(pool, sprintf("
      SELECT
        a.award_id_fain                                         AS fain,
        t.project_title                                         AS project_title,
        a.awarding_sub_agency_name                              AS dir,
        t.division                                              AS division,
        COALESCE(t.nsf_program_name, a.cfda_title, '(unknown)') AS program,
        CASE
          WHEN t.termination_id IS NULL THEN 'Active'
          WHEN t.reinstated              THEN 'Reinstated'
          ELSE                                'Terminated'
        END                                                     AS status,
        a.period_of_perf_start                                  AS pop_start,
        a.period_of_perf_end                                    AS pop_end,
        a.action_date                                           AS action_date,
        a.total_obligated_amount                                AS obligated,
        ABS(COALESCE(t.post_termination_deobligation, 0))       AS deobligated,
        t.latest_termination_date                               AS terminated_on,
        t.reinstatement_date                                    AS reinstated_on,
        t.abstract                                              AS abstract,
        (a.period_of_perf_start <= '2025-04-30'
         AND a.period_of_perf_end >= '2025-04-30')              AS live_apr30
      FROM awards a
      LEFT JOIN terminations t ON t.award_id_fain = a.award_id_fain
      WHERE a.recipient_uei IN (%s)
      ORDER BY
        CASE
          WHEN t.termination_id IS NULL THEN 3
          WHEN t.reinstated              THEN 2
          ELSE                                1
        END,
        a.total_obligated_amount DESC NULLS LAST", uei_in))
  }, ignoreInit = TRUE)

  # Computed once per institution selection; consumed by callouts,
  # charts, and narrative.
  inst_summary <- reactive({
    df <- inst_awards()
    if (nrow(df) == 0) return(NULL)

    is_term      <- df$status %in% c("Terminated", "Reinstated")
    is_active    <- df$status %in% c("Active", "Reinstated")
    n_at_risk    <- sum(df$live_apr30, na.rm = TRUE)
    n_term_atrisk<- sum(df$live_apr30 & is_term, na.rm = TRUE)

    # Most-affected directorate by termination count (ties: largest dir).
    most_dir <- if (any(is_term)) {
      tab <- sort(table(df$dir[is_term]), decreasing = TRUE)
      list(name = names(tab)[1], n = unname(tab[1]))
    } else list(name = "None", n = 0L)

    list(
      n_total       = nrow(df),
      active_funding= sum(df$obligated[is_active], na.rm = TRUE),
      n_active      = sum(is_active),
      n_at_risk     = n_at_risk,
      at_risk_oblig = sum(df$obligated[df$live_apr30], na.rm = TRUE),
      latest_action = suppressWarnings(max(as.Date(df$action_date), na.rm = TRUE)),
      n_term        = sum(is_term),
      n_reinst      = sum(df$status == "Reinstated"),
      term_funding  = sum(df$obligated[is_term], na.rm = TRUE),
      net_deob      = sum(df$deobligated, na.rm = TRUE),
      pct_term      = if (n_at_risk > 0) 100 * n_term_atrisk / n_at_risk else 0,
      most_dir      = most_dir
    )
  })

  output$inst_callouts <- renderUI({
    if (is.null(input$inst_search_go) || input$inst_search_go == 0) {
      return(div(style = sprintf("color: %s; padding: 18px 6px;",
                                 stern_text_muted),
                 "Pick a state, type an institution name, then press Search."))
    }
    if (!isTruthy(input$inst_uei)) {
      return(div(style = sprintf("color: %s; padding: 18px 6px;",
                                 stern_text_muted),
                 "Pick an institution above and press Search."))
    }
    s <- inst_summary()
    if (is.null(s)) {
      return(div(style = sprintf("color: %s; padding: 18px 6px;",
                                 stern_text_muted),
                 "No NSF awards on file for this institution."))
    }
    # Two cards focused on termination exposure (active funding $ is
    # already the headline number in the donut center above).
    div(class = "stern-callouts-centered",
      layout_columns(
        col_widths = c(6, 6),
        stern_stat_callout(
          label   = "Terminated awards",
          value   = scales::comma(s$n_term),
          context = if (s$n_term == 0) "none on record"
                    else sprintf("%s reinstated since",
                                 scales::comma(s$n_reinst)),
          accent  = "rust"),
        stern_stat_callout(
          label   = "Most affected directorate",
          value   = s$most_dir$name,
          context = if (s$most_dir$n > 0)
                      sprintf("%s terminations", scales::comma(s$most_dir$n))
                    else "no terminations recorded",
          accent  = "mustard")
      )
    )
  })

  # General portfolio overview, rendered as the LEFT column of a
  # two-column row whose right side is the donut chart. The headline
  # $ amount lives here as a big number so the donut can stay clean.
  # When there are terminations, a follow-up sentence calls out the
  # largest single loss by program + obligated amount.
  output$inst_overview <- renderUI({
    if (is.null(input$inst_search_go) || input$inst_search_go == 0) {
      return(NULL)
    }
    s <- inst_summary()
    if (is.null(s) || s$n_total == 0) return(NULL)

    ic <- inst_choices()
    nm    <- ic$display_name[ic$ueis == input$inst_uei]
    state <- ic$state_code  [ic$ueis == input$inst_uei]
    nm    <- if (length(nm))    nm[1]    else "This institution"
    state <- if (length(state)) state[1] else "?"

    # Largest single termination -- by obligated amount (the size of
    # the award that was cut), not deobligation $ (which is often $0
    # if NSF hasn't processed the clawback yet but the loss is real).
    largest_loss_txt <- NULL
    if (s$n_term > 0) {
      td <- inst_terminated_awards()
      if (nrow(td) > 0) {
        i <- which.max(td$obligated)
        largest_loss_txt <- sprintf(
          "Largest single termination: %s ($%.2fM obligated).",
          td$program[i], td$obligated[i] / 1e6)
      }
    }

    summary_txt <- if (s$n_term == 0) {
      "No terminations recorded for this institution since the
       Apr 30 2025 funding freeze."
    } else {
      sprintf(
        "%s awards (%.1f%% of awards live on the freeze date) have
         been terminated since the Apr 30 2025 freeze, concentrated
         in %s.",
        scales::comma(s$n_term), s$pct_term, s$most_dir$name)
    }

    card(
      height = "420px",
      card_body(
        class = "d-flex flex-column",
        h3(nm,
           style = sprintf("color: %s; margin-top: 0;
                            margin-bottom: 2px;", stern_text_primary)),
        div(style = sprintf("color: %s; font-family: 'Source Sans 3';
                             font-size: 0.78rem;
                             text-transform: uppercase;
                             letter-spacing: 0.05em;
                             margin-bottom: 14px;", stern_text_muted),
            sprintf("%s — academic NSF awardee", state)),
        div(style = sprintf(
              "color: %s; font-family: 'Source Serif 4';
               font-size: 2.3rem; font-weight: 600;
               line-height: 1.05;", stern_text_primary),
            sprintf("$%.1fM", s$active_funding / 1e6)),
        div(style = sprintf("color: %s; font-family: 'Source Sans 3';
                             font-size: 0.85rem;
                             margin-bottom: 16px;",
                             stern_text_muted),
            sprintf("active NSF funding across %s awards",
                    scales::comma(s$n_active))),
        narrative_p(summary_txt),
        if (!is.null(largest_loss_txt)) narrative_p(largest_loss_txt)
      )
    )
  })

  # Donut: active funding by directorate, with the dollar total in the
  # center. Returns an empty highchart before Search is pressed so the
  # static chart_card chrome doesn't crash.
  output$inst_funding_donut <- renderHighchart({
    req(input$inst_uei, nzchar(input$inst_uei))
    df <- inst_awards()
    if (nrow(df) == 0) return(highchart())

    # Active = currently active OR reinstated (anything not terminated)
    active <- df[df$status %in% c("Active", "Reinstated"), , drop = FALSE]
    if (nrow(active) == 0) return(highchart())

    by_dir <- aggregate(
      data.frame(amt = active$obligated, n = 1L),
      by = list(dir = active$dir),
      FUN = sum)
    by_dir <- by_dir[order(-by_dir$amt), , drop = FALSE]

    # Stable color cycle from stern_palette + neutral fallbacks for the
    # 9th+ directorate so a wide-portfolio institution still renders.
    dir_colors <- c(stern_palette[["navy"]], stern_palette[["olive"]],
                    stern_palette[["mustard"]], stern_palette[["walnut"]],
                    stern_palette[["rust"]], "#7E8E92", "#B89968",
                    "#5E6F4D", "#A8A294")
    pts <- lapply(seq_len(nrow(by_dir)), function(i) {
      list(name  = by_dir$dir[i],
           y     = round(by_dir$amt[i] / 1e6, 2),
           n     = by_dir$n[i],
           color = dir_colors[((i - 1) %% length(dir_colors)) + 1])
    })

    highchart() |>
      hc_chart(type = "pie", plotBackgroundColor = stern_bg_surface,
               style = list(fontFamily = "Source Sans 3", fontSize = "13px")) |>
      hc_plotOptions(pie = list(
        innerSize = "65%", borderWidth = 2,
        borderColor = stern_bg_surface,
        dataLabels = list(
          enabled = TRUE,
          format = "{point.name}",
          style = list(fontSize = "12px", fontWeight = "normal",
                       color = stern_text_body, textOutline = "none")))) |>
      hc_add_series(name = "Active funding", data = pts) |>
      hc_legend(enabled = FALSE) |>
      hc_tooltip(useHTML = TRUE, style = list(fontSize = "12px"),
                 pointFormat = "<b>{point.name}</b><br>
                                ${point.y:,.2f}M
                                across {point.n:,.0f} awards") |>
      hc_add_theme(hc_theme_stern())
  })

  # Termination-only awards filtered from the full-portfolio reactive.
  inst_terminated_awards <- reactive({
    df <- inst_awards()
    if (nrow(df) == 0) return(df)
    df[df$status %in% c("Terminated", "Reinstated"), , drop = FALSE]
  })

  # Termination table: empty data frame when no termination rows; DT
  # handles the empty state gracefully ("No data available in table").
  output$inst_term_tbl <- renderDT({
    df <- inst_terminated_awards()
    if (nrow(df) == 0) {
      empty <- data.frame(
        Note = "No terminations recorded for this institution.",
        check.names = FALSE)
      return(datatable(empty, rownames = FALSE,
        options = list(dom = "t", ordering = FALSE)))
    }
    df <- df[order(-df$deobligated), , drop = FALSE]

    # Abstract column renders as a "Read abstract" link that pops the
    # full text in a modal via Shiny.setInputValue. Avoids an inline
    # expansion that crowds the row, and lets us format the abstract
    # nicely (preserves paragraph breaks via white-space: pre-wrap).
    abstract_cell <- ifelse(
      is.na(df$abstract),
      "<span style=\"color:#9c9686;\">(none)</span>",
      paste0(
        "<a href=\"#\" onclick=\"Shiny.setInputValue(",
        "'inst_term_show_abs', {fain: '", df$fain,
        "', nonce: Math.random()}, {priority:'event'}); return false;\" ",
        "style=\"color:#5b6069; text-decoration:underline; cursor:pointer;\">",
        "Read abstract</a>"))

    show <- data.frame(
      FAIN             = df$fain,
      `Project`        = ifelse(is.na(df$project_title), "—", df$project_title),
      Directorate      = df$dir,
      Division         = ifelse(is.na(df$division), "—", df$division),
      Program          = df$program,
      Status           = df$status,
      `Obligated $K`   = round(df$obligated   / 1e3, 0),
      `Deobligated $K` = round(df$deobligated / 1e3, 0),
      Terminated       = format(as.Date(df$terminated_on)),
      Reinstated       = ifelse(is.na(df$reinstated_on), "—",
                                format(as.Date(df$reinstated_on))),
      Abstract         = abstract_cell,
      check.names      = FALSE,
      stringsAsFactors = FALSE
    )

    datatable(
      show, rownames = FALSE,
      # Escape every column except the Abstract one (last), which is
      # already HTML-safe (we escaped its text content above).
      escape = -ncol(show),
      options = list(
        pageLength = 15, dom = "tip", ordering = TRUE,
        autoWidth = FALSE
      )
    )
  })

  # When a "Read abstract" link in inst_term_tbl is clicked, show the
  # full abstract in a modal. The link's JS calls Shiny.setInputValue
  # with the FAIN; we look that up in the current termination-only
  # data and pop a modalDialog. white-space: pre-wrap preserves the
  # paragraph breaks that NSF abstracts include.
  observeEvent(input$inst_term_show_abs, {
    fain <- input$inst_term_show_abs$fain
    req(fain)
    df <- inst_terminated_awards()
    row <- df[df$fain == fain, , drop = FALSE]
    if (nrow(row) == 0) return()

    title_txt <- if (is.na(row$project_title[1])) row$fain[1] else row$project_title[1]
    body_txt  <- if (is.na(row$abstract[1])) "(no abstract recorded)" else row$abstract[1]

    showModal(modalDialog(
      title     = title_txt,
      easyClose = TRUE,
      fade      = TRUE,
      size      = "l",
      footer    = modalButton("Close"),
      div(style = sprintf(
            "font-family: 'Source Serif 4'; font-size: 0.94rem;
             line-height: 1.55; color: %s;
             white-space: pre-wrap; max-height: 60vh; overflow-y: auto;",
            stern_text_body),
          body_txt)
    ))
  })

  # Directorate glossary modal: opened by the small ⓘ link in the
  # donut card header. NSF directorate codes aren't self-explanatory
  # (CISE, MPS, TIP, OIA, etc.); this expands them in one place.
  observeEvent(input$dir_glossary_show, {
    items <- list(
      c("CISE", "Computer & Information Science and Engineering"),
      c("ENG",  "Engineering"),
      c("MPS",  "Mathematical and Physical Sciences"),
      c("BIO",  "Biological Sciences"),
      c("GEO",  "Geosciences"),
      c("SBE",  "Social, Behavioral and Economic Sciences"),
      c("EDU",  "STEM Education"),
      c("TIP",  "Technology, Innovation and Partnerships"),
      c("OD",   "Office of the Director"),
      c("OIA",  "Office of Integrative Activities"),
      c("OPP",  "Office of Polar Programs"))
    rows <- lapply(items, function(x) {
      div(style = sprintf(
            "padding: 4px 0; font-family: 'Source Sans 3';
             font-size: 0.92rem; color: %s;", stern_text_body),
          tags$strong(x[1]),
          span(style = sprintf("color: %s;", stern_text_muted),
               " — ", x[2]))
    })
    showModal(modalDialog(
      title     = "NSF directorate glossary",
      easyClose = TRUE,
      fade      = TRUE,
      size      = "m",
      footer    = modalButton("Close"),
      do.call(tagList, rows)))
  })

  # -- Recovery tab outputs ------------------------------------------------

  output$reinst_velocity <- renderHighchart({
    rv <- reinst_velocity_data()
    rv <- rv[!is.na(rv$days) & !is.na(rv$topic), , drop = FALSE]
    rv$days <- as.numeric(rv$days)

    # Topic order keeps stern's palette assignment stable across categories
    # and groups the politically-targeted ones near the rust end of the
    # spectrum. Drop topics with <3 reinstatements: too few points to
    # produce a meaningful five-number summary.
    topic_order <- c("DEI / broadening", "education / training",
                     "social / behavioral", "climate / environment",
                     "health / biomedical", "computing / AI",
                     "energy", "physical sci", "other / uncategorized")
    counts <- table(rv$topic)
    keep   <- names(counts)[counts >= 3]
    topics <- intersect(topic_order, keep)
    if (length(topics) == 0) return(highchart())

    box_data <- lapply(topics, function(tp) {
      d  <- rv$days[rv$topic == tp]
      bs <- boxplot.stats(d)$stats   # min, Q1, median, Q3, max
      list(low    = unname(round(bs[1], 1)),
           q1     = unname(round(bs[2], 1)),
           median = unname(round(bs[3], 1)),
           q3     = unname(round(bs[4], 1)),
           high   = unname(round(bs[5], 1)))
    })

    # Outliers: any point outside [Q1 - 1.5*IQR, Q3 + 1.5*IQR].
    out_pts <- list()
    for (i in seq_along(topics)) {
      d  <- rv$days[rv$topic == topics[i]]
      bs <- boxplot.stats(d)
      if (length(bs$out) > 0) {
        for (v in bs$out) {
          out_pts[[length(out_pts) + 1]] <-
            list(x = i - 1L, y = unname(v))
        }
      }
    }

    highchart() |>
      hc_chart(type = "boxplot", plotBackgroundColor = stern_bg_surface,
               style = list(fontFamily = "Source Sans 3", fontSize = "13px")) |>
      hc_xAxis(categories = topics,
               title = list(text = NULL),
               labels = list(style = list(fontSize = "12px",
                                          color = stern_text_body))) |>
      hc_yAxis(title = list(text = "Days from termination to reinstatement",
                            style = list(fontSize = "12px",
                                         color = stern_text_body)),
               labels = list(style = list(fontSize = "12px",
                                          color = stern_text_body)),
               min = 0) |>
      hc_add_series(name = "Days to reinstatement",
                    data = box_data,
                    color = stern_palette[["walnut"]],
                    fillColor = stern_palette[["olive"]],
                    medianColor = stern_palette[["navy"]],
                    lineWidth = 1.5,
                    whiskerLength = "55%") |>
      hc_add_series(name = "Outlier",
                    type = "scatter",
                    data = out_pts,
                    color = stern_palette[["rust"]],
                    marker = list(radius = 3, fillOpacity = 0.7),
                    showInLegend = length(out_pts) > 0) |>
      hc_legend(itemStyle = list(fontSize = "11px"),
                align = "center", verticalAlign = "bottom",
                layout = "horizontal") |>
      hc_tooltip(useHTML = TRUE, style = list(fontSize = "12px")) |>
      hc_add_theme(hc_theme_stern())
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
