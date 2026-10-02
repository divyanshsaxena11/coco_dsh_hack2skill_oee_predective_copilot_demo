-- =============================================================================
-- 20_raw_telemetry.sql
-- Manufacturing OEE & Maintenance Decision Copilot
--
-- Generates 14 days of 5-minute condition monitoring data for 30 tags
-- (~121k rows) entirely in SQL, anchored to the pinned demo clock.
--
-- DETERMINISM: noise comes from HASH(tag, sequence), never RANDOM(). RANDOM() with
-- a seed is not reliably stable across query plans, and a demo whose hero number
-- moves between rebuilds is not demonstrable. Every value here is reproducible.
--
-- The seeded fleet signature, measured against the governed 7-14 day reference
-- baseline, comes out as:
--   P-204 VIB +37.8%  <- hero, criticality A, pump, IN model scope
--   M-303 VIB +25.0%  <- AC_MOTOR, OUT of model scope on purpose
--   P-202 VIB +18.3%  <- credible #2, misalignment signature
--   P-204 TEMP +8.7 C <- below the 62 C alarm, so the default story is a judgement call
--   P-205 TEMP stale  <- stopped reporting 3h ago, a stale case that is NOT the hero
--   all others flat
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE MFG_COPILOT_DB;

CREATE OR REPLACE TABLE RAW.SENSOR_EVENT_RAW
COMMENT = 'Source-aligned historian events. SOURCE_VALUE is in SOURCE_UNIT, which is imperial for some tags. Stop windows match CORE.DOWNTIME_EVENT exactly so historian state and MES downtime cannot contradict each other.'
AS
WITH clk AS (SELECT GOVERNANCE.CURRENT_AS_OF() AS as_of),
seq AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS n
    FROM TABLE(GENERATOR(ROWCOUNT => 4032))   -- 14 days at 5-minute cadence
),
grid AS (
    SELECT t.TAG_ID, t.ASSET_ID, t.TAG_SUFFIX, t.SOURCE_UNIT, t.UNIT,
           a.ASSET_CLASS, a.LINE_ID, s.n,
           (5 * s.n + 5) AS mins_before,
           DATEADD('minute', -(5 * s.n + 5), c.as_of) AS EVENT_TS
    FROM CORE.SENSOR_TAG t
    JOIN CORE.ASSET a ON a.ASSET_ID = t.ASSET_ID
    CROSS JOIN seq s CROSS JOIN clk c
),
shaped AS (
    SELECT g.*,
        -- Operating state. A RUNNING reading may only be baselined against other
        -- RUNNING readings; that is what makes the state-comparability check real.
        CASE
          WHEN DAYNAME(g.EVENT_TS) = 'Sun' AND HOUR(g.EVENT_TS) BETWEEN 2 AND 5 THEN 'PLANNED_STOP'
          WHEN g.LINE_ID = 'PKG-L2' AND g.mins_before BETWEEN 120 AND 128 THEN 'STOPPED'  -- DT-CURR-01
          WHEN g.LINE_ID = 'PKG-L2' AND g.mins_before BETWEEN 75  AND 81  THEN 'STOPPED'  -- DT-CURR-02
          ELSE 'RUNNING'
        END AS OPERATING_STATE,
        CASE g.TAG_SUFFIX
          WHEN 'VIB_RMS_DE'    THEN CASE g.ASSET_ID WHEN 'P-204' THEN 2.80 WHEN 'P-202' THEN 3.10
                                      ELSE 2.20 + (ABS(HASH(g.ASSET_ID)) % 80) / 100.0 END
          WHEN 'TEMP_BRG_DE'   THEN CASE g.ASSET_ID WHEN 'P-204' THEN 52.0
                                      ELSE 45.0 + (ABS(HASH(g.ASSET_ID)) % 100) / 10.0 END
          WHEN 'MOTOR_CURRENT' THEN CASE WHEN g.ASSET_CLASS = 'CENTRIFUGAL_PUMP' THEN 38.0 ELSE 22.0 END
        END AS base_val,
        -- Every degradation window is shorter than 7 days so the governed reference
        -- baseline period (7-14 days back) stays clear of the rise it measures against.
        -- P-204: a 36-hour gradual ramp to 1.30x makes the story credible to a
        -- reliability engineer; the final 45 minutes at 1.38x produces the exact
        -- "38% above baseline, sustained 45 minutes" claim.
        CASE
          WHEN g.TAG_ID = 'P-204/VIB_RMS_DE' AND g.mins_before <= 45   THEN 1.38
          WHEN g.TAG_ID = 'P-204/VIB_RMS_DE' AND g.mins_before <= 2160 THEN 1.00 + 0.30 * (2160 - g.mins_before) / 2115.0
          WHEN g.TAG_ID = 'P-202/VIB_RMS_DE' AND g.mins_before <= 7200 THEN 1.18
          WHEN g.TAG_ID = 'M-303/VIB_RMS_DE' AND g.mins_before <= 4320 THEN 1.25
          ELSE 1.00
        END AS mult,
        CASE
          WHEN g.TAG_ID = 'P-204/TEMP_BRG_DE' AND g.mins_before <= 45   THEN 9.0
          WHEN g.TAG_ID = 'P-204/TEMP_BRG_DE' AND g.mins_before <= 2160 THEN 6.0 * (2160 - g.mins_before) / 2115.0
          ELSE 0.0
        END AS addend,
        ((ABS(HASH(g.TAG_ID, g.n)) % 2001) - 1000) / 1000.0 AS noise
    FROM grid g
),
valued AS (
    SELECT s.*,
        CASE WHEN s.OPERATING_STATE IN ('STOPPED','PLANNED_STOP') THEN
               CASE s.TAG_SUFFIX
                 WHEN 'VIB_RMS_DE'    THEN 0.08 + 0.05 * ABS(s.noise)
                 WHEN 'MOTOR_CURRENT' THEN 0.60 + 0.40 * ABS(s.noise)
                 WHEN 'TEMP_BRG_DE'   THEN s.base_val * 0.60 + 1.5 * s.noise
               END
             ELSE
               CASE s.TAG_SUFFIX
                 WHEN 'VIB_RMS_DE'    THEN s.base_val * s.mult * (1 + 0.040 * s.noise)
                 WHEN 'MOTOR_CURRENT' THEN s.base_val * s.mult * (1 + 0.030 * s.noise)
                 WHEN 'TEMP_BRG_DE'   THEN s.base_val + s.addend + 1.5 * s.noise
               END
        END AS norm_val
    FROM shaped s
)
SELECT v.TAG_ID, v.EVENT_TS,
    -- Store the value the historian would actually have sent, in SOURCE_UNIT.
    ROUND(CASE v.SOURCE_UNIT
            WHEN 'IN_S'  THEN v.norm_val / 25.4        -- mm/s  -> in/s
            WHEN 'DEG_F' THEN v.norm_val * 9 / 5 + 32  -- deg C -> deg F
            ELSE v.norm_val END, 4)::NUMBER(12,4) AS SOURCE_VALUE,
    v.SOURCE_UNIT, v.OPERATING_STATE,
    -- A deterministic sprinkle of SUSPECT readings (~0.25%) so the quality-flag path
    -- is exercised by baseline data rather than only by a scenario flip.
    CASE WHEN ABS(HASH(v.TAG_ID, v.n, 'q')) % 400 = 0 THEN 'SUSPECT' ELSE 'GOOD' END AS QUALITY_FLAG,
    DATEADD('second', 20 + (ABS(HASH(v.TAG_ID, v.n, 'i')) % 40), v.EVENT_TS) AS INGESTED_AT,
    'HISTORIAN' AS SOURCE_SYSTEM
FROM valued v
-- P-205 bearing temperature stopped reporting three hours ago. This puts a genuine
-- stale-tag case in the BASELINE data on an asset that is NOT the hero, so the
-- "which high-criticality assets have stale condition data" question returns a row
-- without needing a scenario flip.
WHERE NOT (v.TAG_ID = 'P-205/TEMP_BRG_DE' AND v.mins_before < 180);

-- ----------------------------------------------------------------------------
-- Verification
-- ----------------------------------------------------------------------------
SELECT COUNT(*) AS rows_generated,
       COUNT(DISTINCT TAG_ID) AS tags,
       MIN(EVENT_TS) AS oldest,
       MAX(EVENT_TS) AS newest,
       (SELECT MAX(EVENT_TS) FROM RAW.SENSOR_EVENT_RAW WHERE TAG_ID = 'P-205/TEMP_BRG_DE') AS p205_temp_last_seen
FROM RAW.SENSOR_EVENT_RAW;
