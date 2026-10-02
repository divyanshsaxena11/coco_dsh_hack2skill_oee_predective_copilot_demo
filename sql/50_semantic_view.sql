-- =============================================================================
-- 50_semantic_view.sql
-- Manufacturing OEE & Maintenance Decision Copilot
--
-- MAINTENANCE_DECISION_SV -- the structured grounding layer for Cortex Analyst.
--
-- TWO MODELLING DECISIONS WORTH DEFENDING:
--
-- 1. There is NO relationship from downtime_events to assets, even though
--    DOWNTIME_EVENT.ASSET_ID exists. Two reasons. First, assets already reach lines,
--    so adding a direct edge creates a multi-path ambiguity that makes any query
--    mixing asset and downtime dimensions fail. Second and more important: that
--    association is often merely a TIME_OVERLAP inference at 0.55 confidence.
--    Promoting it to a join path in the semantic layer would invite Analyst to
--    aggregate downtime "by asset" as though the attribution were established fact.
--    ASSOC_METHOD and the associated asset are exposed as DIMENSIONS instead, so a
--    user can see the association and its basis without the model silently trusting it.
--
-- 2. Facts are suffixed `_f`. Snowflake raises "Cyclic reference" when a fact name
--    matches a metric name case-insensitively, and this view defines both a
--    `downtime_min_f` fact and an `unplanned_downtime_min` metric over it. The suffix
--    makes the collision structurally impossible rather than a thing to remember.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE MFG_COPILOT_DB;

CREATE OR REPLACE SEMANTIC VIEW SEMANTIC.MAINTENANCE_DECISION_SV

  TABLES (
    lines AS MFG_COPILOT_DB.CORE.PRODUCTION_LINE
      PRIMARY KEY (LINE_ID)
      WITH SYNONYMS = ('production line', 'packaging line', 'line')
      COMMENT = 'Production lines. IDEAL_CYCLE_SEC is the governed standard behind the performance factor.',
    assets AS MFG_COPILOT_DB.CORE.ASSET
      PRIMARY KEY (ASSET_ID)
      WITH SYNONYMS = ('equipment', 'machine', 'pump', 'motor')
      COMMENT = 'Canonical asset master with criticality and consequence classification.',
    components AS MFG_COPILOT_DB.CORE.COMPONENT
      PRIMARY KEY (COMPONENT_ID)
      WITH SYNONYMS = ('maintainable component', 'bearing', 'coupling')
      COMMENT = 'Maintainable components, including lubrication schedule.',
    oee_intervals AS MFG_COPILOT_DB.CORE.OEE_INTERVAL
      PRIMARY KEY (OEE_INTERVAL_ID)
      WITH SYNONYMS = ('oee', 'overall equipment effectiveness', 'availability performance quality')
      COMMENT = 'Hourly OEE derived from production events. Retains every calculation input.',
    downtime_events AS MFG_COPILOT_DB.CORE.DOWNTIME_EVENT
      PRIMARY KEY (DOWNTIME_ID)
      WITH SYNONYMS = ('stops', 'downtime', 'loss events')
      COMMENT = 'Stop intervals with governed reason codes. ASSOC_METHOD records how firmly a stop is attributed to an asset.',
    asset_health AS MFG_COPILOT_DB.AI.ASSET_HEALTH_SNAPSHOT
      PRIMARY KEY (ASSET_ID)
      WITH SYNONYMS = ('asset risk', 'condition', 'health', 'fleet triage')
      COMMENT = 'Decision-ready condition and risk per asset. All estimates are SYNTHETIC_DEMO.',
    work_orders AS MFG_COPILOT_DB.CORE.WORK_ORDER
      PRIMARY KEY (WORK_ORDER_ID)
      WITH SYNONYMS = ('work order', 'wo', 'maintenance order')
      COMMENT = 'CMMS work orders.',
    prod_windows AS MFG_COPILOT_DB.CORE.PRODUCTION_WINDOW
      PRIMARY KEY (WINDOW_ID)
      WITH SYNONYMS = ('maintenance window', 'production window', 'slot')
      COMMENT = 'Authorized maintenance and changeover windows with allowed downtime.',
    part_inventory AS MFG_COPILOT_DB.CORE.PART_INVENTORY
      PRIMARY KEY (INVENTORY_ID)
      WITH SYNONYMS = ('spares', 'parts', 'stock', 'inventory')
      COMMENT = 'Site part inventory with supplier lead time.',
    maint_events AS MFG_COPILOT_DB.CORE.MAINTENANCE_EVENT
      PRIMARY KEY (MAINTENANCE_EVENT_ID)
      WITH SYNONYMS = ('maintenance history', 'past repairs', 'failures')
      COMMENT = 'Maintenance history. CONFIRMATION_STATE distinguishes a confirmed fault from no-fault-found.'
  )

  RELATIONSHIPS (
    assets_to_lines      AS assets        (LINE_ID)  REFERENCES lines,
    components_to_assets AS components    (ASSET_ID) REFERENCES assets,
    oee_to_lines         AS oee_intervals (LINE_ID)  REFERENCES lines,
    downtime_to_lines    AS downtime_events (LINE_ID) REFERENCES lines,
    health_to_assets     AS asset_health  (ASSET_ID) REFERENCES assets,
    wo_to_assets         AS work_orders   (ASSET_ID) REFERENCES assets,
    windows_to_lines     AS prod_windows  (LINE_ID)  REFERENCES lines,
    maint_to_assets      AS maint_events  (ASSET_ID) REFERENCES assets
  )

  FACTS (
    oee_intervals.planned_min_f   AS PLANNED_PRODUCTION_MIN
      COMMENT = 'Planned production minutes. The OEE availability denominator. Planned stops are excluded, not charged.',
    oee_intervals.run_min_f       AS RUN_TIME_MIN
      COMMENT = 'Actual run minutes. The OEE availability numerator.',
    oee_intervals.downtime_min_f  AS DOWNTIME_MIN
      COMMENT = 'Unplanned downtime minutes inside the bucket.',
    oee_intervals.excluded_min_f  AS EXCLUDED_MIN
      COMMENT = 'Minutes excluded from the planned-production calendar.',
    oee_intervals.total_cnt_f     AS TOTAL_COUNT   COMMENT = 'Units produced, good and bad.',
    oee_intervals.good_cnt_f      AS GOOD_COUNT    COMMENT = 'Units meeting specification first time.',
    oee_intervals.scrap_cnt_f     AS SCRAP_COUNT   COMMENT = 'Units scrapped.',
    oee_intervals.rework_cnt_f    AS REWORK_COUNT  COMMENT = 'Units sent for rework.',
    oee_intervals.ideal_cycle_f   AS IDEAL_CYCLE_SEC
      COMMENT = 'Governed ideal cycle standard in seconds per unit.',
    downtime_events.duration_min_f AS DURATION_MIN COMMENT = 'Stop duration in minutes.',
    downtime_events.assoc_confidence_f AS ASSET_ASSOC_CONFIDENCE
      COMMENT = 'Confidence that this stop is attributable to the named asset. 1.00 only when operator-confirmed.',
    asset_health.failure_probability_f AS FAILURE_PROBABILITY
      COMMENT = 'SYNTHETIC probability of the fault mode within the horizon. NULL when data quality fails or the asset is out of model scope.',
    asset_health.anomaly_score_f  AS ANOMALY_SCORE
      COMMENT = 'Deviation from learned normal behaviour. A measure of deviation, not a diagnosis.',
    asset_health.priority_score_f AS PRIORITY_SCORE
      COMMENT = 'Composite triage score. NULL where data quality does not support one.',
    asset_health.rul_low_f        AS RUL_LOW_DAYS  COMMENT = 'Lower bound of the SYNTHETIC remaining-useful-life range, days.',
    asset_health.rul_high_f       AS RUL_HIGH_DAYS COMMENT = 'Upper bound of the SYNTHETIC remaining-useful-life range, days.',
    asset_health.pct_above_baseline_f AS PCT_ABOVE_BASELINE
      COMMENT = 'Percent above the governed 7-14 day reference baseline, comparable operating state only.',
    asset_health.staleness_min_f  AS VIB_STALENESS_MIN
      COMMENT = 'Age in minutes of the newest vibration reading, against the pinned as-of time.',
    asset_health.lube_overdue_f   AS LUBE_OVERDUE_HOURS COMMENT = 'Operating hours past the lubrication interval.',
    asset_health.criticality_f    AS CRITICALITY_SCORE  COMMENT = 'Numeric consequence weight, 1.00 highest.',
    part_inventory.available_qty_f AS AVAILABLE_QTY     COMMENT = 'On hand minus reserved.',
    part_inventory.lead_time_f    AS LEAD_TIME_DAYS     COMMENT = 'Supplier lead time in days if the part must be ordered.',
    prod_windows.allowed_downtime_f AS ALLOWED_DOWNTIME_MIN
      COMMENT = 'Downtime minutes production has authorized in this window. Zero means maintenance is not permitted.',
    prod_windows.hours_until_f    AS HOURS_UNTIL_START  COMMENT = 'Hours from the as-of time until the window opens.',
    maint_events.downtime_min_f   AS DOWNTIME_MIN       COMMENT = 'Downtime caused by this maintenance event.',
    maint_events.cost_f           AS COST               COMMENT = 'Recorded cost of this maintenance event.'
  )

  DIMENSIONS (
    lines.line_id      AS LINE_ID   WITH SYNONYMS = ('line', 'line code') COMMENT = 'Production line identifier, for example PKG-L2.',
    lines.line_name    AS LINE_NAME COMMENT = 'Human-readable line name.',
    lines.line_priority AS BUSINESS_PRIORITY COMMENT = 'Business priority of the line.',

    assets.asset_id    AS ASSET_ID  WITH SYNONYMS = ('asset', 'tag number', 'equipment id') COMMENT = 'Asset identifier, for example P-204.',
    assets.asset_name  AS ASSET_NAME COMMENT = 'Human-readable asset name.',
    assets.asset_class AS ASSET_CLASS
      WITH SYNONYMS = ('equipment type', 'class')
      COMMENT = 'Asset class. The demo bearing model covers CENTRIFUGAL_PUMP only.'
      SAMPLE_VALUES ('CENTRIFUGAL_PUMP', 'AC_MOTOR') IS_ENUM,
    assets.criticality AS CRITICALITY
      COMMENT = 'Consequence-of-failure class. A is highest.'
      SAMPLE_VALUES ('A', 'B', 'C', 'D') IS_ENUM,
    assets.site_id     AS SITE_ID COMMENT = 'Plant site.',
    assets.quality_consequence AS QUALITY_CONSEQUENCE COMMENT = 'Quality consequence of failure.',
    assets.safety_consequence  AS SAFETY_CONSEQUENCE  COMMENT = 'Safety consequence of failure.',

    components.component_id   AS COMPONENT_ID COMMENT = 'Maintainable component identifier.',
    components.component_type AS COMPONENT_TYPE
      COMMENT = 'Component type.'
      SAMPLE_VALUES ('DRIVE_END_BEARING', 'NON_DRIVE_END_BEARING', 'COUPLING') IS_ENUM,

    oee_intervals.bucket_start AS BUCKET_START COMMENT = 'Start of the hourly OEE bucket.',
    oee_intervals.bucket_day   AS DATE_TRUNC('day', BUCKET_START) COMMENT = 'Calendar day of the OEE bucket.',
    oee_intervals.bucket_hour  AS HOUR(BUCKET_START) COMMENT = 'Hour of day of the OEE bucket.',
    oee_intervals.shift_code   AS SHIFT_CODE
      COMMENT = 'Shift. A is 06:00-14:00, B is 14:00-22:00, C is 22:00-06:00.'
      SAMPLE_VALUES ('A', 'B', 'C') IS_ENUM,
    oee_intervals.product_code AS PRODUCT_CODE COMMENT = 'Product running in the bucket.',
    oee_intervals.calc_version AS CALC_VERSION COMMENT = 'Version of the OEE calculation definition.',
    oee_intervals.dominant_factor AS CASE
        WHEN (1 - COALESCE(RUN_TIME_MIN / NULLIF(PLANNED_PRODUCTION_MIN, 0), 1))
          >= (1 - COALESCE((IDEAL_CYCLE_SEC * TOTAL_COUNT) / NULLIF(RUN_TIME_MIN * 60, 0), 1))
         AND (1 - COALESCE(RUN_TIME_MIN / NULLIF(PLANNED_PRODUCTION_MIN, 0), 1))
          >= (1 - COALESCE(GOOD_COUNT / NULLIF(TOTAL_COUNT, 0), 1)) THEN 'AVAILABILITY'
        WHEN (1 - COALESCE((IDEAL_CYCLE_SEC * TOTAL_COUNT) / NULLIF(RUN_TIME_MIN * 60, 0), 1))
          >= (1 - COALESCE(GOOD_COUNT / NULLIF(TOTAL_COUNT, 0), 1)) THEN 'PERFORMANCE'
        ELSE 'QUALITY' END
      COMMENT = 'Which OEE factor contributed the largest loss in this bucket. Computed from the retained calculation inputs rather than from the pre-computed AVAILABILITY / PERFORMANCE / QUALITY columns: those column names collide with the metric names below, and referencing them here would create a cyclic expression reference.',

    downtime_events.reason_code AS REASON_CODE
      WITH SYNONYMS = ('stop reason', 'downtime reason')
      COMMENT = 'Governed stop classification. UNKNOWN is legitimate and must stay visible.',
    downtime_events.assoc_method AS ASSOC_METHOD
      COMMENT = 'How firmly this stop is attributed to an asset. Only OPERATOR_CONFIRMED may be described as an established cause; TIME_OVERLAP is correlation.'
      SAMPLE_VALUES ('OPERATOR_CONFIRMED', 'TIME_OVERLAP', 'UNKNOWN') IS_ENUM,
    downtime_events.associated_asset AS ASSET_ID
      COMMENT = 'Asset the stop is associated with, if any. Read together with ASSOC_METHOD -- there is deliberately no join path here.',
    downtime_events.is_planned  AS IS_PLANNED COMMENT = 'TRUE for an approved planned stop.',
    downtime_events.stop_start  AS START_TS   COMMENT = 'Stop start timestamp.',
    downtime_events.stop_shift  AS SHIFT_CODE COMMENT = 'Shift in which the stop occurred.',

    asset_health.triage_lane AS TRIAGE_LANE
      COMMENT = 'Triage disposition. DATA_UNUSABLE and OUT_OF_MODEL_SCOPE assets carry no risk score and must not be ranked against scored assets.'
      SAMPLE_VALUES ('ACTION_CANDIDATE', 'MONITOR', 'NORMAL', 'DATA_UNUSABLE', 'OUT_OF_MODEL_SCOPE', 'SAFETY_ESCALATION') IS_ENUM,
    asset_health.dq_verdict  AS DQ_VERDICT
      COMMENT = 'Deterministic data-quality verdict. FAIL suppresses all model output.'
      SAMPLE_VALUES ('PASS', 'REVIEW', 'FAIL') IS_ENUM,
    asset_health.failed_checks AS FAILED_CHECKS COMMENT = 'Names of the data-quality checks that failed.',
    asset_health.fault_mode  AS FAULT_MODE COMMENT = 'Hypothesised fault mode. A hypothesis, not a confirmed diagnosis.',
    asset_health.confidence_band AS CONFIDENCE_BAND COMMENT = 'Confidence band for the probability estimate.',
    asset_health.in_scope    AS IN_SCOPE COMMENT = 'TRUE when the asset is inside the validated model scope.',
    asset_health.model_version AS MODEL_VERSION COMMENT = 'Version of the model that produced the estimate.',
    asset_health.estimate_type AS ESTIMATE_TYPE
      COMMENT = 'Provenance of every numeric estimate on this row. SYNTHETIC_DEMO means illustrative, not model-validated.'
      SAMPLE_VALUES ('SYNTHETIC_DEMO') IS_ENUM,
    asset_health.score_explanation AS SCORE_EXPLANATION
      COMMENT = 'Term-by-term arithmetic behind the probability, generated from the same coefficients that produced it.',

    work_orders.wo_status AS STATUS
      COMMENT = 'Work order status.'
      SAMPLE_VALUES ('OPEN', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED') IS_ENUM,
    work_orders.wo_task   AS TASK_CODE COMMENT = 'Maintenance task on the work order.',
    work_orders.wo_priority AS PRIORITY COMMENT = 'Work order priority.',
    work_orders.wo_planned_start AS PLANNED_START COMMENT = 'Planned start of the work order.',

    prod_windows.window_id AS WINDOW_ID COMMENT = 'Window identifier.',
    prod_windows.window_type AS WINDOW_TYPE COMMENT = 'Window purpose.',
    prod_windows.window_status AS AUTHORIZATION_STATUS
      COMMENT = 'Whether production has authorized this window.'
      SAMPLE_VALUES ('APPROVED', 'PENDING', 'REJECTED') IS_ENUM,
    prod_windows.window_start AS WINDOW_START COMMENT = 'Window start timestamp.',

    part_inventory.part_code AS PART_CODE COMMENT = 'Part number.',
    part_inventory.part_site AS SITE_ID   COMMENT = 'Stocking site.',
    part_inventory.supplier  AS PREFERRED_SUPPLIER COMMENT = 'Preferred supplier.',

    maint_events.confirmation_state AS CONFIRMATION_STATE
      COMMENT = 'Whether a physical inspection confirmed the suspected fault. Only CONFIRMED establishes a fault.'
      SAMPLE_VALUES ('CONFIRMED', 'REFUTED', 'NO_FAULT_FOUND', 'UNCONFIRMED') IS_ENUM,
    maint_events.confirmed_fault AS CONFIRMED_FAULT_MODE COMMENT = 'Fault mode confirmed by inspection, if any.',
    maint_events.event_type AS EVENT_TYPE COMMENT = 'Kind of maintenance event.',
    maint_events.event_ts   AS EVENT_TS   COMMENT = 'When the maintenance event occurred.',
    maint_events.failure_code AS FAILURE_CODE COMMENT = 'Recorded failure code.',
    maint_events.procedure_ref AS PROCEDURE_REF COMMENT = 'Procedure and version followed.'
  )

  METRICS (
    oee_intervals.availability AS SUM(oee_intervals.run_min_f) / NULLIF(SUM(oee_intervals.planned_min_f), 0)
      WITH SYNONYMS = ('uptime', 'availability factor')
      COMMENT = 'Run time divided by planned production time. Planned stops are excluded from the denominator.',
    oee_intervals.performance AS (MAX(oee_intervals.ideal_cycle_f) * SUM(oee_intervals.total_cnt_f))
                                 / NULLIF(SUM(oee_intervals.run_min_f) * 60, 0)
      WITH SYNONYMS = ('speed factor', 'performance factor')
      COMMENT = 'Ideal cycle time times units produced, divided by run time in seconds.',
    oee_intervals.quality AS SUM(oee_intervals.good_cnt_f) / NULLIF(SUM(oee_intervals.total_cnt_f), 0)
      WITH SYNONYMS = ('quality factor', 'first pass yield')
      COMMENT = 'Good units divided by total units.',
    oee_intervals.oee AS (SUM(oee_intervals.run_min_f) / NULLIF(SUM(oee_intervals.planned_min_f), 0))
                       * ((MAX(oee_intervals.ideal_cycle_f) * SUM(oee_intervals.total_cnt_f))
                          / NULLIF(SUM(oee_intervals.run_min_f) * 60, 0))
                       * (SUM(oee_intervals.good_cnt_f) / NULLIF(SUM(oee_intervals.total_cnt_f), 0))
      WITH SYNONYMS = ('overall equipment effectiveness', 'oee percent')
      COMMENT = 'Availability times performance times quality.',
    oee_intervals.unplanned_downtime_min AS SUM(oee_intervals.downtime_min_f)
      COMMENT = 'Total unplanned downtime minutes.',
    oee_intervals.total_planned_production_min AS SUM(oee_intervals.planned_min_f)
      COMMENT = 'Total planned production minutes. Named with a total_ prefix because a metric may not share a name with a physical column that a fact references -- PLANNED_PRODUCTION_MIN is the expression behind planned_min_f.',
    oee_intervals.units_produced AS SUM(oee_intervals.total_cnt_f) COMMENT = 'Total units produced.',
    oee_intervals.units_scrapped AS SUM(oee_intervals.scrap_cnt_f) COMMENT = 'Total units scrapped.',

    downtime_events.stop_minutes AS SUM(downtime_events.duration_min_f) COMMENT = 'Total stop minutes.',
    downtime_events.stop_count   AS COUNT(DOWNTIME_ID) COMMENT = 'Number of stops.',
    downtime_events.unknown_reason_minutes AS
        SUM(CASE WHEN REASON_CODE = 'UNKNOWN' THEN DURATION_MIN ELSE 0 END)
      COMMENT = 'Stop minutes with no recorded reason. Kept as its own quantity so it is never absorbed into an asset cause.',
    downtime_events.confirmed_assoc_minutes AS
        SUM(CASE WHEN ASSOC_METHOD = 'OPERATOR_CONFIRMED' THEN DURATION_MIN ELSE 0 END)
      COMMENT = 'Stop minutes attributed to an asset by operator confirmation.',
    downtime_events.overlap_assoc_minutes AS
        SUM(CASE WHEN ASSOC_METHOD = 'TIME_OVERLAP' THEN DURATION_MIN ELSE 0 END)
      COMMENT = 'Stop minutes associated with an asset only by time overlap. Correlation, not cause.',

    asset_health.max_failure_probability AS MAX(asset_health.failure_probability_f)
      COMMENT = 'Highest SYNTHETIC failure probability in the group.',
    asset_health.max_priority_score AS MAX(asset_health.priority_score_f)
      COMMENT = 'Highest triage priority score in the group.',
    asset_health.min_rul_days AS MIN(asset_health.rul_low_f)
      COMMENT = 'Shortest lower-bound remaining useful life in the group, days.',
    asset_health.max_staleness_min AS MAX(asset_health.staleness_min_f)
      COMMENT = 'Oldest newest-reading age in the group, minutes.',
    asset_health.asset_count AS COUNT(ASSET_ID) COMMENT = 'Number of assets.',
    asset_health.assets_needing_action AS
        SUM(CASE WHEN TRIAGE_LANE IN ('ACTION_CANDIDATE', 'SAFETY_ESCALATION') THEN 1 ELSE 0 END)
      COMMENT = 'Assets in an action-requiring triage lane.',
    asset_health.assets_with_unusable_data AS
        SUM(CASE WHEN DQ_VERDICT = 'FAIL' THEN 1 ELSE 0 END)
      COMMENT = 'Assets whose condition data cannot support a decision.',

    part_inventory.parts_available AS SUM(part_inventory.available_qty_f)
      COMMENT = 'Unreserved quantity on hand.',
    part_inventory.max_lead_time_days AS MAX(part_inventory.lead_time_f)
      COMMENT = 'Longest supplier lead time in the group, days.',

    prod_windows.window_count AS COUNT(WINDOW_ID) COMMENT = 'Number of windows.',
    prod_windows.authorized_downtime_min AS SUM(prod_windows.allowed_downtime_f)
      COMMENT = 'Total downtime minutes production has authorized.',

    work_orders.work_order_count AS COUNT(WORK_ORDER_ID) COMMENT = 'Number of work orders.',
    work_orders.open_work_orders AS
        SUM(CASE WHEN STATUS IN ('OPEN', 'IN_PROGRESS') THEN 1 ELSE 0 END)
      COMMENT = 'Work orders not yet completed.',

    maint_events.maintenance_event_count AS COUNT(MAINTENANCE_EVENT_ID) COMMENT = 'Number of maintenance events.',
    maint_events.confirmed_fault_count AS
        SUM(CASE WHEN CONFIRMATION_STATE = 'CONFIRMED' THEN 1 ELSE 0 END)
      COMMENT = 'Maintenance events where inspection confirmed the suspected fault.',
    maint_events.no_fault_found_count AS
        SUM(CASE WHEN CONFIRMATION_STATE = 'NO_FAULT_FOUND' THEN 1 ELSE 0 END)
      COMMENT = 'Inspections that did not confirm the predicted fault. An honest analog set includes these.',
    maint_events.maintenance_cost AS SUM(maint_events.cost_f) COMMENT = 'Total recorded maintenance cost.',
    maint_events.maintenance_downtime_min AS SUM(maint_events.downtime_min_f)
      COMMENT = 'Total downtime caused by maintenance.'
  )

  COMMENT = 'Manufacturing OEE and maintenance decision context. All values synthetic. Every numeric estimate carries ESTIMATE_TYPE.'

  AI_SQL_GENERATION 'Round ratios to 4 decimal places and percentages to 1. Always return ESTIMATE_TYPE alongside any of FAILURE_PROBABILITY, ANOMALY_SCORE, RUL_LOW_DAYS, RUL_HIGH_DAYS, or PRIORITY_SCORE, because those are synthetic and must never be presented as validated. Always return DQ_VERDICT alongside any risk or condition figure. Never filter out rows where DQ_VERDICT = ''FAIL'' or TRIAGE_LANE = ''DATA_UNUSABLE'' unless the user explicitly asks only for scored assets: those rows are the ones a reliability engineer most needs to see, and hiding them turns missing data into apparent health. When a question asks which asset caused a stop, return ASSOC_METHOD with the answer and do not treat TIME_OVERLAP as an established cause. Treat REASON_CODE = ''UNKNOWN'' as its own category; never redistribute it across known reasons.'

  AI_QUESTION_CATEGORIZATION 'Answer questions about OEE, downtime, asset condition, risk, maintenance history, work orders, windows, and parts. If asked to command, stop, start, derate, or otherwise control equipment, refuse and state that this model is read-only analytical context and that plant control follows the site procedure. If asked whether a fault is confirmed, answer only from CONFIRMATION_STATE in maintenance history; if asked for a diagnosis from condition data alone, answer with the hypothesis and state that it is unconfirmed. If a question does not name a line, asset, or time window and the answer would differ materially by scope, consider it UNCLEAR and ask which line or asset is meant.'

  -- Verified queries are written against the LOGICAL table aliases, and SQL takes a
  -- single-quoted string, so every internal literal is doubled ('' not ').
  -- VERIFIED_AT is seconds since the Unix epoch: 1789257600 = 2026-09-13.
  AI_VERIFIED_QUERIES (

    oee_loss_factor_by_shift AS (
      QUESTION 'Which factor drove Packaging Line 2 OEE loss this shift?'
      VERIFIED_AT 1789257600
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = reliability_coe)'
      SQL 'SELECT o.SHIFT_CODE,
                  SUM(o.RUN_TIME_MIN) / NULLIF(SUM(o.PLANNED_PRODUCTION_MIN), 0) AS availability,
                  (MAX(o.IDEAL_CYCLE_SEC) * SUM(o.TOTAL_COUNT)) / NULLIF(SUM(o.RUN_TIME_MIN) * 60, 0) AS performance,
                  SUM(o.GOOD_COUNT) / NULLIF(SUM(o.TOTAL_COUNT), 0) AS quality,
                  SUM(o.DOWNTIME_MIN) AS unplanned_downtime_min,
                  MAX(o.CALC_VERSION) AS calc_version
             FROM oee_intervals AS o
            WHERE o.LINE_ID = ''PKG-L2''
            GROUP BY o.SHIFT_CODE
            ORDER BY availability ASC'
    ),

    assets_requiring_action_seven_days AS (
      QUESTION 'Which Packaging Line 2 assets require action in the next seven days?'
      VERIFIED_AT 1789257600
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = reliability_coe)'
      SQL 'SELECT h.ASSET_ID, a.CRITICALITY, h.TRIAGE_LANE, h.FAULT_MODE,
                  h.FAILURE_PROBABILITY, h.RUL_LOW_DAYS, h.RUL_HIGH_DAYS,
                  h.DQ_VERDICT, h.IN_SCOPE, h.ESTIMATE_TYPE, h.PRIORITY_SCORE
             FROM asset_health AS h
             JOIN assets AS a ON a.ASSET_ID = h.ASSET_ID
            WHERE a.LINE_ID = ''PKG-L2''
              AND (h.TRIAGE_LANE IN (''ACTION_CANDIDATE'', ''SAFETY_ESCALATION'')
                   OR h.RUL_LOW_DAYS <= 7
                   OR h.DQ_VERDICT = ''FAIL'')
            ORDER BY h.PRIORITY_SCORE DESC NULLS LAST'
    ),

    high_criticality_stale_condition_data AS (
      QUESTION 'Which high-criticality assets have stale condition data?'
      VERIFIED_AT 1789257600
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = reliability_coe)'
      SQL 'SELECT h.ASSET_ID, a.CRITICALITY, h.DQ_VERDICT, h.FAILED_CHECKS,
                  h.VIB_STALENESS_MIN, h.VIB_LAST_READING_TS, h.TRIAGE_LANE
             FROM asset_health AS h
             JOIN assets AS a ON a.ASSET_ID = h.ASSET_ID
            WHERE a.CRITICALITY IN (''A'', ''B'')
              AND h.DQ_VERDICT <> ''PASS''
            ORDER BY h.VIB_STALENESS_MIN DESC NULLS LAST'
    ),

    downtime_attribution_quality AS (
      QUESTION 'How much Line 2 downtime has no recorded reason, and how much is only associated with an asset by time overlap?'
      VERIFIED_AT 1789257600
      ONBOARDING_QUESTION FALSE
      VERIFIED_BY '(STEWARD = reliability_coe)'
      SQL 'SELECT d.LINE_ID,
                  SUM(d.DURATION_MIN) AS total_stop_min,
                  SUM(CASE WHEN d.REASON_CODE = ''UNKNOWN'' THEN d.DURATION_MIN ELSE 0 END) AS unknown_reason_min,
                  SUM(CASE WHEN d.ASSOC_METHOD = ''OPERATOR_CONFIRMED'' THEN d.DURATION_MIN ELSE 0 END) AS confirmed_cause_min,
                  SUM(CASE WHEN d.ASSOC_METHOD = ''TIME_OVERLAP'' THEN d.DURATION_MIN ELSE 0 END) AS overlap_only_min
             FROM downtime_events AS d
            WHERE d.LINE_ID = ''PKG-L2''
            GROUP BY d.LINE_ID'
    ),

    parts_with_no_unreserved_stock AS (
      QUESTION 'Which parts have no unreserved stock, and what is the supplier lead time?'
      VERIFIED_AT 1789257600
      ONBOARDING_QUESTION FALSE
      VERIFIED_BY '(STEWARD = maintenance_planning)'
      SQL 'SELECT p.PART_CODE, p.AVAILABLE_QTY, p.LEAD_TIME_DAYS, p.PREFERRED_SUPPLIER, p.SITE_ID
             FROM part_inventory AS p
            WHERE p.AVAILABLE_QTY = 0
            ORDER BY p.LEAD_TIME_DAYS DESC'
    )
  )
;

-- ----------------------------------------------------------------------------
-- Verification
-- ----------------------------------------------------------------------------
SHOW SEMANTIC VIEWS IN SCHEMA MFG_COPILOT_DB.SEMANTIC;
