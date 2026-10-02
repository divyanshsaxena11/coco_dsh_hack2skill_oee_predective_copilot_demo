-- =============================================================================
-- 30_core_views.sql
-- Manufacturing OEE & Maintenance Decision Copilot
--
-- The governed read layer. Three jobs:
--   1. Normalize source units and resolve quality flags (CORE.SENSOR_READING).
--   2. Apply the scenario overlay non-destructively (readings, inventory, windows,
--      procedures, technician skills).
--   3. Derive OEE from production events so the numbers are reconstructable.
--
-- These are VIEWS, not tables, specifically so a scenario flip is instant and
-- reversible. Nothing here mutates a seeded row.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE MFG_COPILOT_DB;

-- ----------------------------------------------------------------------------
-- CORE.SENSOR_READING -- normalized, quality-resolved, overlay-aware
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW CORE.SENSOR_READING
COMMENT = 'Canonical sensor readings: source units normalized, quality flags resolved, scenario overlay applied.'
AS
WITH clk AS (SELECT GOVERNANCE.CURRENT_AS_OF() AS as_of),
scn AS (SELECT GOVERNANCE.ACTIVE_SCENARIO() AS code),
base AS (
    SELECT
        r.TAG_ID, t.ASSET_ID, t.COMPONENT_ID, t.TAG_SUFFIX, t.OBSERVED_PROPERTY,
        r.EVENT_TS, r.INGESTED_AT, r.SOURCE_SYSTEM, r.OPERATING_STATE,
        r.SOURCE_VALUE, t.UNIT, t.VALID_MIN, t.VALID_MAX,
        r.QUALITY_FLAG AS RAW_QUALITY_FLAG,
        DATEDIFF('minute', r.EVENT_TS, c.as_of) AS mins_before,
        s.code AS scenario_code,
        -- M2B_INVALID_UNITS: the historian starts sending the hero vibration tag in
        -- in/s while still labelling it MM_S. The value is then ~25x too small, which
        -- the range check catches. Simulating the mislabel rather than corrupting the
        -- number is what makes this a units failure and not just an outlier.
        CASE
          WHEN s.code = 'M2B_INVALID_UNITS' AND r.TAG_ID = 'P-204/VIB_RMS_DE'
               AND DATEDIFF('minute', r.EVENT_TS, c.as_of) <= 180
            THEN 'MM_S_MISLABELLED'
          ELSE r.SOURCE_UNIT
        END AS EFFECTIVE_SOURCE_UNIT
    FROM RAW.SENSOR_EVENT_RAW r
    JOIN CORE.SENSOR_TAG t ON t.TAG_ID = r.TAG_ID
    CROSS JOIN clk c CROSS JOIN scn s
    -- M2_STALE_DATA: hero telemetry stops arriving ~6h before the snapshot.
    -- Suppressing rows is more honest than back-dating them: the gap is real.
    WHERE NOT (s.code = 'M2_STALE_DATA' AND t.ASSET_ID = 'P-204'
               AND DATEDIFF('minute', r.EVENT_TS, c.as_of) < 374)
)
SELECT
    b.TAG_ID, b.ASSET_ID, b.COMPONENT_ID, b.TAG_SUFFIX, b.OBSERVED_PROPERTY,
    b.EVENT_TS, b.INGESTED_AT, b.SOURCE_SYSTEM, b.OPERATING_STATE,
    b.SOURCE_VALUE, b.EFFECTIVE_SOURCE_UNIT AS SOURCE_UNIT, b.UNIT,
    ROUND(
      CASE b.EFFECTIVE_SOURCE_UNIT
        WHEN 'IN_S'  THEN b.SOURCE_VALUE * 25.4
        WHEN 'DEG_F' THEN (b.SOURCE_VALUE - 32) * 5 / 9
        -- A mislabelled unit is passed through mis-converted on purpose: that is what
        -- a real misconfiguration does, and it is what makes the range check fire.
        WHEN 'MM_S_MISLABELLED' THEN b.SOURCE_VALUE / 25.4
        ELSE b.SOURCE_VALUE
      END
      + CASE WHEN b.scenario_code = 'M5_SAFETY_TRIP'
                  AND b.TAG_ID = 'P-204/TEMP_BRG_DE' AND b.mins_before <= 45
             THEN 20.0 ELSE 0.0 END
    , 4)::NUMBER(12,4) AS VALUE_NORMALIZED,
    b.VALID_MIN, b.VALID_MAX,
    CASE
      WHEN b.RAW_QUALITY_FLAG = 'SUSPECT' THEN 'SUSPECT'
      WHEN b.EFFECTIVE_SOURCE_UNIT = 'MM_S_MISLABELLED' THEN 'BAD'
      ELSE 'GOOD'
    END AS QUALITY_FLAG,
    b.mins_before AS MINUTES_BEFORE_AS_OF,
    b.scenario_code AS ACTIVE_SCENARIO
FROM base b;

-- ----------------------------------------------------------------------------
-- Overlay-aware resource views
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW CORE.PART_INVENTORY
COMMENT = 'Inventory with the scenario overlay applied. M3_NO_PART zeroes the hero bearing kit without touching the seed.'
AS
SELECT
    b.INVENTORY_ID, b.SITE_ID, b.PART_CODE,
    CASE WHEN GOVERNANCE.ACTIVE_SCENARIO() = 'M3_NO_PART' AND b.PART_CODE = 'BRG-6312-C3'
         THEN 0 ELSE b.ON_HAND END AS ON_HAND,
    b.RESERVED,
    GREATEST(0,
      CASE WHEN GOVERNANCE.ACTIVE_SCENARIO() = 'M3_NO_PART' AND b.PART_CODE = 'BRG-6312-C3'
           THEN 0 ELSE b.ON_HAND END - b.RESERVED) AS AVAILABLE_QTY,
    b.REORDER_POINT, b.SNAPSHOT_TS, b.SOURCE_SYSTEM,
    m.LEAD_TIME_DAYS, m.PREFERRED_SUPPLIER, m.UNIT_COST,
    GOVERNANCE.ACTIVE_SCENARIO() AS ACTIVE_SCENARIO
FROM CORE.PART_INVENTORY_BASE b
JOIN CORE.PART_MASTER m ON m.PART_CODE = b.PART_CODE;

CREATE OR REPLACE VIEW CORE.PRODUCTION_WINDOW
COMMENT = 'Approved windows with the scenario overlay applied. M4_WINDOW_CONFLICT withdraws authorization for every window before Friday 2026-09-18.'
AS
SELECT
    b.WINDOW_ID, b.LINE_ID, b.WINDOW_START, b.WINDOW_END, b.WINDOW_TYPE,
    CASE WHEN GOVERNANCE.ACTIVE_SCENARIO() = 'M4_WINDOW_CONFLICT'
              AND b.WINDOW_START < '2026-09-18 00:00:00'::TIMESTAMP_NTZ
         THEN 'REJECTED' ELSE b.AUTHORIZATION_STATUS END AS AUTHORIZATION_STATUS,
    CASE WHEN GOVERNANCE.ACTIVE_SCENARIO() = 'M4_WINDOW_CONFLICT'
              AND b.WINDOW_START < '2026-09-18 00:00:00'::TIMESTAMP_NTZ
         THEN 0 ELSE b.ALLOWED_DOWNTIME_MIN END AS ALLOWED_DOWNTIME_MIN,
    b.PRODUCTION_ORDER, b.BUSINESS_PRIORITY, b.APPROVED_BY_ROLE,
    DATEDIFF('hour', GOVERNANCE.CURRENT_AS_OF(), b.WINDOW_START) AS HOURS_UNTIL_START,
    DATEDIFF('minute', b.WINDOW_START, b.WINDOW_END)             AS WINDOW_DURATION_MIN,
    GOVERNANCE.ACTIVE_SCENARIO() AS ACTIVE_SCENARIO
FROM CORE.PRODUCTION_WINDOW_BASE b;

CREATE OR REPLACE VIEW GOVERNANCE.PROCEDURE_CURRENT
COMMENT = 'Procedures with the scenario overlay applied. SUPERSEDED_SOP withdraws SOP-BRG-17 v4, leaving only the superseded v3 -- which must never be cited as authority.'
AS
SELECT
    p.PROCEDURE_CODE, p.VERSION, p.TITLE,
    CASE WHEN GOVERNANCE.ACTIVE_SCENARIO() = 'SUPERSEDED_SOP'
              AND p.PROCEDURE_CODE = 'SOP-BRG-17' AND p.VERSION = 'v4'
         THEN 'WITHDRAWN' ELSE p.STATUS END AS STATUS,
    p.APPLIES_TO_ASSET_CLASS, p.APPLIES_TO_TASK_CODE, p.DOCUMENT_TYPE,
    p.VALID_FROM, p.VALID_TO, p.APPROVED_BY,
    p.PROCEDURE_CODE || '-' || p.VERSION AS PROCEDURE_REF,
    GOVERNANCE.ACTIVE_SCENARIO() AS ACTIVE_SCENARIO
FROM GOVERNANCE.PROCEDURE_METADATA p;

CREATE OR REPLACE VIEW CORE.TECHNICIAN_QUALIFICATION
COMMENT = 'Technician skills joined to roster, with certification validity resolved against the demo clock. EXPIRED_CERT lapses R. Kulkarni so no valid bearing technician remains.'
AS
SELECT
    t.TECHNICIAN_ID, t.TECHNICIAN_NAME, t.SITE_ID, t.SHIFT_CODE, t.IS_ON_ROSTER,
    s.SKILL_CODE, s.SKILL_LABEL, s.CERT_VALID_FROM,
    CASE WHEN GOVERNANCE.ACTIVE_SCENARIO() = 'EXPIRED_CERT'
              AND s.TECHNICIAN_ID = 'T-001' AND s.SKILL_CODE = 'MECH_BEARING_L2'
         THEN '2026-08-15'::DATE ELSE s.CERT_VALID_TO END AS CERT_VALID_TO,
    (   s.CERT_VALID_FROM <= GOVERNANCE.CURRENT_AS_OF()::DATE
    AND COALESCE(
          CASE WHEN GOVERNANCE.ACTIVE_SCENARIO() = 'EXPIRED_CERT'
                    AND s.TECHNICIAN_ID = 'T-001' AND s.SKILL_CODE = 'MECH_BEARING_L2'
               THEN '2026-08-15'::DATE ELSE s.CERT_VALID_TO END,
          '9999-12-31'::DATE) >= GOVERNANCE.CURRENT_AS_OF()::DATE
    ) AS IS_CERT_VALID,
    t.IS_ON_ROSTER AND (
        s.CERT_VALID_FROM <= GOVERNANCE.CURRENT_AS_OF()::DATE
    AND COALESCE(
          CASE WHEN GOVERNANCE.ACTIVE_SCENARIO() = 'EXPIRED_CERT'
                    AND s.TECHNICIAN_ID = 'T-001' AND s.SKILL_CODE = 'MECH_BEARING_L2'
               THEN '2026-08-15'::DATE ELSE s.CERT_VALID_TO END,
          '9999-12-31'::DATE) >= GOVERNANCE.CURRENT_AS_OF()::DATE
    ) AS IS_AVAILABLE,
    GOVERNANCE.ACTIVE_SCENARIO() AS ACTIVE_SCENARIO
FROM CORE.TECHNICIAN t
JOIN CORE.TECHNICIAN_SKILL s ON s.TECHNICIAN_ID = t.TECHNICIAN_ID;

-- ----------------------------------------------------------------------------
-- CORE.OEE_INTERVAL -- DERIVED, hourly
--
-- Every input to the calculation is retained on the row: numerator, denominator,
-- calendar, exclusions, ideal-cycle standard, counts, and CALC_VERSION. That is what
-- lets the copilot answer "where did availability 91.5% come from" with rows rather
-- than assertion.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW CORE.OEE_INTERVAL
COMMENT = 'Hourly OEE derived from CORE.PRODUCTION_EVENT. Retains numerator, denominator, calendar, exclusions, ideal cycle, counts, and CALC_VERSION so every figure is reconstructable.'
AS
SELECT
    pe.LINE_ID || '-' || TO_VARCHAR(DATE_TRUNC('hour', pe.INTERVAL_START), 'YYYYMMDDHH24') AS OEE_INTERVAL_ID,
    pe.LINE_ID,
    DATE_TRUNC('hour', pe.INTERVAL_START)                     AS BUCKET_START,
    DATEADD('hour', 1, DATE_TRUNC('hour', pe.INTERVAL_START))  AS BUCKET_END,
    MAX(pe.SHIFT_CODE)                                        AS SHIFT_CODE,
    MAX(pe.PRODUCT_CODE)                                      AS PRODUCT_CODE,
    MAX(pe.PRODUCTION_ORDER)                                  AS PRODUCTION_ORDER,
    MAX(pe.IDEAL_CYCLE_SEC)                                   AS IDEAL_CYCLE_SEC,
    -- Denominator: only PLANNED_PRODUCTION time counts. Planned stops are excluded
    -- from the calendar rather than charged as downtime.
    SUM(CASE WHEN pe.PLANNED_STATE = 'PLANNED_PRODUCTION' THEN 15 ELSE 0 END)::NUMBER(10,2) AS PLANNED_PRODUCTION_MIN,
    SUM(CASE WHEN pe.PLANNED_STATE <> 'PLANNED_PRODUCTION' THEN 15 ELSE 0 END)::NUMBER(10,2) AS EXCLUDED_MIN,
    SUM(pe.RUN_MINUTES)::NUMBER(10,2)                         AS RUN_TIME_MIN,
    SUM(pe.DOWNTIME_MINUTES)::NUMBER(10,2)                    AS DOWNTIME_MIN,
    SUM(pe.TOTAL_COUNT)                                       AS TOTAL_COUNT,
    SUM(pe.GOOD_COUNT)                                        AS GOOD_COUNT,
    SUM(pe.SCRAP_COUNT)                                       AS SCRAP_COUNT,
    SUM(pe.REWORK_COUNT)                                      AS REWORK_COUNT,
    'PLANNED_PRODUCTION_CALENDAR'                             AS CALENDAR_CODE,
    'PLANNED_STOP excluded from denominator'                  AS EXCLUSION_REASON,
    -- availability = run_time / planned_production_time
    ROUND(SUM(pe.RUN_MINUTES)
          / NULLIF(SUM(CASE WHEN pe.PLANNED_STATE = 'PLANNED_PRODUCTION' THEN 15 ELSE 0 END), 0), 4) AS AVAILABILITY,
    -- performance = (ideal_cycle_sec * total_count) / (run_time_min * 60)
    ROUND((MAX(pe.IDEAL_CYCLE_SEC) * SUM(pe.TOTAL_COUNT))
          / NULLIF(SUM(pe.RUN_MINUTES) * 60, 0), 4)           AS PERFORMANCE,
    -- quality = good_count / total_count
    ROUND(SUM(pe.GOOD_COUNT) / NULLIF(SUM(pe.TOTAL_COUNT), 0), 4) AS QUALITY,
    ROUND(
      (SUM(pe.RUN_MINUTES) / NULLIF(SUM(CASE WHEN pe.PLANNED_STATE = 'PLANNED_PRODUCTION' THEN 15 ELSE 0 END), 0))
    * ((MAX(pe.IDEAL_CYCLE_SEC) * SUM(pe.TOTAL_COUNT)) / NULLIF(SUM(pe.RUN_MINUTES) * 60, 0))
    * (SUM(pe.GOOD_COUNT) / NULLIF(SUM(pe.TOTAL_COUNT), 0))
    , 4)                                                      AS OEE,
    'oee-calc-v1'                                             AS CALC_VERSION
FROM CORE.PRODUCTION_EVENT pe
GROUP BY pe.LINE_ID, DATE_TRUNC('hour', pe.INTERVAL_START);

-- ----------------------------------------------------------------------------
-- Verification: the current shift on PKG-L2 must show availability as the
-- dominant loss against the trailing baseline.
-- ----------------------------------------------------------------------------
WITH cur AS (
    SELECT AVG(AVAILABILITY) a, AVG(PERFORMANCE) p, AVG(QUALITY) q
    FROM CORE.OEE_INTERVAL
    WHERE LINE_ID = 'PKG-L2'
      AND BUCKET_START >= DATE_TRUNC('day', GOVERNANCE.CURRENT_AS_OF()) + INTERVAL '6 hours'
),
base AS (
    SELECT AVG(AVAILABILITY) a, AVG(PERFORMANCE) p, AVG(QUALITY) q
    FROM CORE.OEE_INTERVAL
    WHERE LINE_ID = 'PKG-L2'
      AND BUCKET_START <  DATE_TRUNC('day', GOVERNANCE.CURRENT_AS_OF())
      AND PLANNED_PRODUCTION_MIN > 0
)
SELECT ROUND(base.a,4) AS baseline_availability, ROUND(cur.a,4) AS current_availability,
       ROUND((cur.a-base.a)*100,2) AS availability_delta_pp,
       ROUND((cur.p-base.p)*100,2) AS performance_delta_pp,
       ROUND((cur.q-base.q)*100,2) AS quality_delta_pp
FROM cur CROSS JOIN base;
