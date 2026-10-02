-- =============================================================================
-- 25_core_events.sql
-- Manufacturing OEE & Maintenance Decision Copilot
--
-- Downtime, production, quality, maintenance history, and work orders.
--
-- DEPENDENCY DIRECTION IS DELIBERATE:
--   DOWNTIME_EVENT  (source event, from MES)
--     -> PRODUCTION_EVENT  (15-minute intervals, downtime aggregated by overlap)
--       -> OEE_INTERVAL    (hourly, built in 30_core_views.sql)
-- Nothing is seeded at the OEE level. That means when a judge asks "where did
-- availability 91.5% come from", there is a real chain of rows to walk down.
--
-- The current-shift story on PKG-L2 (06:00 -> 08:45 snapshot):
--   availability 0.915 vs 0.975 baseline  -> -6.0 pp, the DOMINANT loss
--   performance  0.930 vs 0.955 baseline  -> -2.5 pp
--   quality      0.990 vs 0.990 baseline  ->  flat
-- So "availability has deteriorated this shift" is what the data actually says.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE MFG_COPILOT_DB;

-- ----------------------------------------------------------------------------
-- DDL
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE CORE.DOWNTIME_EVENT (
    DOWNTIME_ID VARCHAR NOT NULL,
    LINE_ID VARCHAR NOT NULL,
    START_TS TIMESTAMP_NTZ NOT NULL,
    END_TS TIMESTAMP_NTZ NOT NULL,
    DURATION_MIN NUMBER(8,2) NOT NULL,
    IS_PLANNED BOOLEAN NOT NULL,
    REASON_CODE VARCHAR NOT NULL COMMENT 'Governed classification. UNKNOWN is legitimate and must stay visible rather than being folded into an asset cause.',
    REASON_DESCRIPTION VARCHAR,
    ASSET_ID VARCHAR COMMENT 'Nullable: not every stop is attributable to an asset',
    ASSOC_METHOD VARCHAR COMMENT 'OPERATOR_CONFIRMED | TIME_OVERLAP | UNKNOWN -- the epistemic core of this demo',
    ASSET_ASSOC_CONFIDENCE NUMBER(4,2),
    CONFIRMED_BY VARCHAR,
    SHIFT_CODE VARCHAR,
    SOURCE_SYSTEM VARCHAR DEFAULT 'MES',
    CONSTRAINT PK_DOWNTIME_EVENT PRIMARY KEY (DOWNTIME_ID)
) COMMENT = 'Stop intervals. ASSOC_METHOD is a real column so "correlation, not cause" is data the copilot must report, not prose it might forget.';

CREATE OR REPLACE TABLE CORE.PRODUCTION_EVENT (
    EVENT_ID VARCHAR NOT NULL,
    LINE_ID VARCHAR NOT NULL,
    INTERVAL_START TIMESTAMP_NTZ NOT NULL,
    INTERVAL_END TIMESTAMP_NTZ NOT NULL,
    PLANNED_STATE VARCHAR NOT NULL COMMENT 'PLANNED_PRODUCTION | PLANNED_STOP | NOT_SCHEDULED',
    RUN_STATE VARCHAR NOT NULL COMMENT 'RUNNING | STOPPED | PARTIAL',
    PRODUCT_CODE VARCHAR,
    PRODUCTION_ORDER VARCHAR,
    IDEAL_CYCLE_SEC NUMBER(8,3) NOT NULL,
    RUN_MINUTES NUMBER(8,2) NOT NULL,
    DOWNTIME_MINUTES NUMBER(8,2) NOT NULL,
    TOTAL_COUNT NUMBER(12,0) NOT NULL,
    GOOD_COUNT NUMBER(12,0) NOT NULL,
    SCRAP_COUNT NUMBER(12,0) NOT NULL,
    REWORK_COUNT NUMBER(12,0) NOT NULL,
    SHIFT_CODE VARCHAR,
    SOURCE_SYSTEM VARCHAR DEFAULT 'MES',
    INGESTED_AT TIMESTAMP_NTZ,
    CONSTRAINT PK_PRODUCTION_EVENT PRIMARY KEY (EVENT_ID)
) COMMENT = '15-minute production intervals. OEE_INTERVAL is derived from this so every OEE figure is reconstructable.';

CREATE OR REPLACE TABLE CORE.QUALITY_EVENT (
    QUALITY_ID VARCHAR NOT NULL,
    LINE_ID VARCHAR NOT NULL,
    BUCKET_START TIMESTAMP_NTZ NOT NULL,
    PRODUCT_CODE VARCHAR,
    TOTAL_COUNT NUMBER(12,0),
    GOOD_COUNT NUMBER(12,0),
    SCRAP_COUNT NUMBER(12,0),
    REWORK_COUNT NUMBER(12,0),
    DEFECT_REASON VARCHAR,
    SOURCE_SYSTEM VARCHAR DEFAULT 'MES',
    CONSTRAINT PK_QUALITY_EVENT PRIMARY KEY (QUALITY_ID)
) COMMENT = 'Hourly quality roll-up with governed defect reasons.';

CREATE OR REPLACE TABLE CORE.MAINTENANCE_EVENT (
    MAINTENANCE_EVENT_ID VARCHAR NOT NULL,
    ASSET_ID VARCHAR NOT NULL,
    COMPONENT_ID VARCHAR,
    EVENT_TS TIMESTAMP_NTZ NOT NULL,
    EVENT_TYPE VARCHAR NOT NULL COMMENT 'INSPECTION | REPAIR | REPLACEMENT | FAILURE | SERVICE',
    SYMPTOM VARCHAR,
    SUSPECTED_FAULT_MODE VARCHAR,
    CONFIRMED_FAULT_MODE VARCHAR,
    CONFIRMATION_STATE VARCHAR NOT NULL COMMENT 'CONFIRMED | REFUTED | NO_FAULT_FOUND | UNCONFIRMED',
    REMEDY VARCHAR,
    FAILURE_CODE VARCHAR,
    DOWNTIME_MIN NUMBER(8,1),
    LABOUR_MIN NUMBER(8,1),
    PARTS_USED VARCHAR,
    COST NUMBER(12,2),
    PERFORMED_BY VARCHAR,
    PROCEDURE_REF VARCHAR,
    SOURCE_SYSTEM VARCHAR DEFAULT 'CMMS',
    CONSTRAINT PK_MAINTENANCE_EVENT PRIMARY KEY (MAINTENANCE_EVENT_ID)
) COMMENT = 'Maintenance history. CONFIRMED vs NO_FAULT_FOUND is preserved distinctly -- that distinction is what makes analog-case evidence trustworthy.';

CREATE OR REPLACE TABLE CORE.WORK_ORDER (
    WORK_ORDER_ID VARCHAR NOT NULL,
    ASSET_ID VARCHAR NOT NULL,
    COMPONENT_ID VARCHAR,
    TASK_CODE VARCHAR,
    STATUS VARCHAR NOT NULL COMMENT 'OPEN | IN_PROGRESS | COMPLETED | CANCELLED',
    PRIORITY VARCHAR,
    OWNER_ROLE VARCHAR,
    PLANNED_START TIMESTAMP_NTZ,
    PLANNED_END TIMESTAMP_NTZ,
    ACTUAL_START TIMESTAMP_NTZ,
    ACTUAL_END TIMESTAMP_NTZ,
    PROCEDURE_REF VARCHAR,
    FAILURE_CODE VARCHAR,
    DESCRIPTION VARCHAR,
    SOURCE_SYSTEM VARCHAR DEFAULT 'CMMS',
    CONSTRAINT PK_WORK_ORDER PRIMARY KEY (WORK_ORDER_ID)
) COMMENT = 'CMMS work orders. Open orders are checked for conflicts by the feasibility predicate.';

-- ----------------------------------------------------------------------------
-- Seed: downtime events
--
-- Two current-shift stops carry the whole epistemic argument:
--   DT-CURR-01  reason UNKNOWN, no asset association at all  -> must stay unknown
--   DT-CURR-02  reason FLOW_INTERRUPTION, TIME_OVERLAP to P-204 at 0.55 confidence
--               -> correlation the copilot must NOT upgrade to a confirmed cause
-- Historical stops include OPERATOR_CONFIRMED associations for contrast, so the
-- copilot has to distinguish the two rather than treat all associations alike.
-- ----------------------------------------------------------------------------
INSERT OVERWRITE INTO CORE.DOWNTIME_EVENT
WITH clk AS (SELECT GOVERNANCE.CURRENT_AS_OF() AS as_of),
days AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS d FROM TABLE(GENERATOR(ROWCOUNT => 14))),
slots AS (SELECT * FROM VALUES (1),(2) AS t(slot)),
reasons AS (
    SELECT * FROM VALUES
      (0,'MATERIAL_SHORTAGE',       'Infeed material starvation',      FALSE,'UNKNOWN',           NULL),
      (1,'JAM_INFEED',              'Bottle jam at infeed guide',      FALSE,'OPERATOR_CONFIRMED',NULL),
      (2,'CHANGEOVER_OVERRUN',      'Format changeover ran long',      FALSE,'UNKNOWN',           NULL),
      (3,'LABEL_MISFEED',           'Labeller misfeed',                FALSE,'OPERATOR_CONFIRMED',NULL),
      (4,'UNKNOWN',                 'Stop recorded without a reason',  FALSE,'UNKNOWN',           NULL),
      (5,'SEAL_LEAK',               'Pump seal weep, wiped and ran on',FALSE,'OPERATOR_CONFIRMED','P-203'),
      (6,'OPERATOR_UNAVAILABLE',    'Break not covered',               FALSE,'UNKNOWN',           NULL)
    AS t(r, REASON_CODE, REASON_DESCRIPTION, IS_PLANNED, ASSOC_METHOD, ASSET_ID)
),
hist AS (
    SELECT
        'DT-' || l.LINE_ID || '-' || LPAD(d.d, 2, '0') || '-' || s.slot        AS DOWNTIME_ID,
        l.LINE_ID,
        DATEADD('minute',
            (ABS(HASH(l.LINE_ID, d.d, s.slot, 'off')) % 300),
            DATEADD('hour', CASE s.slot WHEN 1 THEN 10 ELSE 18 END,
                DATEADD('day', -d.d, DATE_TRUNC('day', c.as_of)))
        )                                                                      AS START_TS,
        5 + (ABS(HASH(l.LINE_ID, d.d, s.slot, 'dur')) % 21)                    AS DURATION_MIN,
        ABS(HASH(l.LINE_ID, d.d, s.slot, 'rsn')) % 7                           AS r
    FROM CORE.PRODUCTION_LINE l CROSS JOIN days d CROSS JOIN slots s CROSS JOIN clk c
    -- Keep history strictly before the current shift so the current-shift story is
    -- driven only by the two explicitly authored stops.
    WHERE d.d > 0
)
SELECT h.DOWNTIME_ID, h.LINE_ID, h.START_TS,
       DATEADD('minute', h.DURATION_MIN, h.START_TS)  AS END_TS,
       h.DURATION_MIN, rs.IS_PLANNED, rs.REASON_CODE, rs.REASON_DESCRIPTION,
       rs.ASSET_ID, rs.ASSOC_METHOD,
       CASE rs.ASSOC_METHOD WHEN 'OPERATOR_CONFIRMED' THEN 1.00
                            WHEN 'TIME_OVERLAP'       THEN 0.55 END            AS ASSET_ASSOC_CONFIDENCE,
       CASE rs.ASSOC_METHOD WHEN 'OPERATOR_CONFIRMED' THEN 'Line Operator' END  AS CONFIRMED_BY,
       CASE WHEN HOUR(h.START_TS) BETWEEN 6 AND 13 THEN 'A'
            WHEN HOUR(h.START_TS) BETWEEN 14 AND 21 THEN 'B' ELSE 'C' END       AS SHIFT_CODE,
       'MES'                                                                    AS SOURCE_SYSTEM
FROM hist h JOIN reasons rs ON rs.r = h.r
UNION ALL
SELECT 'DT-CURR-01','PKG-L2',
       DATEADD('minute',-128, c.as_of), DATEADD('minute',-120, c.as_of), 8, FALSE,
       'UNKNOWN','Line stopped, no reason code entered by the operator',
       NULL,'UNKNOWN',NULL,NULL,'A','MES'
FROM clk c
UNION ALL
SELECT 'DT-CURR-02','PKG-L2',
       DATEADD('minute',-81, c.as_of), DATEADD('minute',-75, c.as_of), 6, FALSE,
       'FLOW_INTERRUPTION','Product flow interruption at transfer, cause not established',
       'P-204','TIME_OVERLAP',0.55,NULL,'A','MES'
FROM clk c;

-- ----------------------------------------------------------------------------
-- Seed: production events at 15-minute grain
-- ----------------------------------------------------------------------------
INSERT OVERWRITE INTO CORE.PRODUCTION_EVENT
WITH clk AS (SELECT GOVERNANCE.CURRENT_AS_OF() AS as_of),
seq AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS n FROM TABLE(GENERATOR(ROWCOUNT => 1344))),
grid AS (
    SELECT l.LINE_ID, l.IDEAL_CYCLE_SEC, s.n, c.as_of,
           DATEADD('minute', -15 * (s.n + 1), c.as_of) AS INTERVAL_START,
           DATEADD('minute', -15 * s.n,       c.as_of) AS INTERVAL_END
    FROM CORE.PRODUCTION_LINE l CROSS JOIN seq s CROSS JOIN clk c
),
classified AS (
    SELECT g.*,
        CASE WHEN DAYNAME(g.INTERVAL_START) = 'Sun' AND HOUR(g.INTERVAL_START) BETWEEN 2 AND 5
             THEN 'PLANNED_STOP' ELSE 'PLANNED_PRODUCTION' END AS PLANNED_STATE,
        CASE WHEN HOUR(g.INTERVAL_START) BETWEEN 6 AND 13 THEN 'A'
             WHEN HOUR(g.INTERVAL_START) BETWEEN 14 AND 21 THEN 'B' ELSE 'C' END AS SHIFT_CODE,
        -- Current shift on PKG-L2 also carries a speed loss, but a smaller one than
        -- the availability loss, so availability is genuinely the dominant factor.
        CASE
          WHEN g.LINE_ID = 'PKG-L2' AND g.INTERVAL_START >= DATE_TRUNC('day', g.as_of) + INTERVAL '6 hours'
            THEN 0.930
          ELSE 0.955 + ((ABS(HASH(g.LINE_ID, g.n, 'spd')) % 21) - 10) / 1000.0
        END AS speed_factor,
        0.990 + ((ABS(HASH(g.LINE_ID, g.n, 'qly')) % 11) - 5) / 1000.0 AS good_rate
    FROM grid g
),
-- Downtime minutes are pre-aggregated per (line, interval) and then joined.
-- A correlated scalar subquery with an aggregate over an inequality join is not
-- supported by Snowflake ("Unsupported subquery type cannot be evaluated").
dt AS (
    SELECT c.LINE_ID, c.n,
           SUM(GREATEST(0, DATEDIFF('second',
                 GREATEST(d.START_TS, c.INTERVAL_START),
                 LEAST(d.END_TS,   c.INTERVAL_END))) / 60.0) AS DOWNTIME_MINUTES
    FROM classified c
    JOIN CORE.DOWNTIME_EVENT d
      ON d.LINE_ID  = c.LINE_ID
     AND d.START_TS < c.INTERVAL_END
     AND d.END_TS   > c.INTERVAL_START
    GROUP BY c.LINE_ID, c.n
),
withdt AS (
    SELECT c.*, COALESCE(dt.DOWNTIME_MINUTES, 0) AS DOWNTIME_MINUTES
    FROM classified c
    LEFT JOIN dt ON dt.LINE_ID = c.LINE_ID AND dt.n = c.n
),
computed AS (
    SELECT w.*,
        CASE WHEN w.PLANNED_STATE = 'PLANNED_PRODUCTION'
             THEN GREATEST(0, 15 - w.DOWNTIME_MINUTES) ELSE 0 END AS RUN_MINUTES
    FROM withdt w
),
counted AS (
    SELECT c.*,
        FLOOR(c.RUN_MINUTES * 60 / c.IDEAL_CYCLE_SEC * c.speed_factor)::NUMBER(12,0) AS TOTAL_COUNT
    FROM computed c
)
SELECT
    'PE-' || c.LINE_ID || '-' || LPAD(c.n, 4, '0')                     AS EVENT_ID,
    c.LINE_ID, c.INTERVAL_START, c.INTERVAL_END, c.PLANNED_STATE,
    CASE WHEN c.PLANNED_STATE = 'PLANNED_STOP'     THEN 'STOPPED'
         WHEN c.DOWNTIME_MINUTES >= 15             THEN 'STOPPED'
         WHEN c.DOWNTIME_MINUTES > 0               THEN 'PARTIAL'
         ELSE 'RUNNING' END                                            AS RUN_STATE,
    CASE WHEN c.LINE_ID = 'PKG-L2' THEN 'SKU-500ML' ELSE 'SKU-1L' END  AS PRODUCT_CODE,
    CASE WHEN c.LINE_ID = 'PKG-L2' THEN 'PO-88421' ELSE 'PO-88310' END AS PRODUCTION_ORDER,
    c.IDEAL_CYCLE_SEC,
    ROUND(c.RUN_MINUTES, 2), ROUND(c.DOWNTIME_MINUTES, 2),
    c.TOTAL_COUNT,
    FLOOR(c.TOTAL_COUNT * c.good_rate)::NUMBER(12,0)                            AS GOOD_COUNT,
    GREATEST(0, c.TOTAL_COUNT - FLOOR(c.TOTAL_COUNT * c.good_rate)
               - FLOOR(c.TOTAL_COUNT * 0.003))::NUMBER(12,0)                    AS SCRAP_COUNT,
    FLOOR(c.TOTAL_COUNT * 0.003)::NUMBER(12,0)                                  AS REWORK_COUNT,
    c.SHIFT_CODE, 'MES',
    DATEADD('second', 45, c.INTERVAL_END)                                       AS INGESTED_AT
FROM counted c;

-- ----------------------------------------------------------------------------
-- Seed: hourly quality roll-up, derived from production events
-- ----------------------------------------------------------------------------
INSERT OVERWRITE INTO CORE.QUALITY_EVENT
SELECT
    'QE-' || pe.LINE_ID || '-' || TO_VARCHAR(DATE_TRUNC('hour', pe.INTERVAL_START), 'YYYYMMDDHH24') AS QUALITY_ID,
    pe.LINE_ID,
    DATE_TRUNC('hour', pe.INTERVAL_START) AS BUCKET_START,
    MAX(pe.PRODUCT_CODE),
    SUM(pe.TOTAL_COUNT), SUM(pe.GOOD_COUNT), SUM(pe.SCRAP_COUNT), SUM(pe.REWORK_COUNT),
    CASE WHEN SUM(pe.SCRAP_COUNT) = 0 THEN NULL
         WHEN ABS(HASH(pe.LINE_ID, DATE_TRUNC('hour', pe.INTERVAL_START))) % 2 = 0
           THEN 'FILL_VOLUME_LOW' ELSE 'LABEL_SKEW' END,
    'MES'
FROM CORE.PRODUCTION_EVENT pe
GROUP BY pe.LINE_ID, DATE_TRUNC('hour', pe.INTERVAL_START);

-- ----------------------------------------------------------------------------
-- Seed: maintenance history
--
-- ME-A01..A03 are CONFIRMED drive-end bearing degradation cases on sister pumps.
-- These are the analog cases the copilot cites as comparable confirmed evidence.
-- ME-N01 is a NO_FAULT_FOUND inspection, kept deliberately: an honest analog set
-- has to include the time the prediction did not pan out.
-- ----------------------------------------------------------------------------
INSERT OVERWRITE INTO CORE.MAINTENANCE_EVENT
WITH clk AS (SELECT GOVERNANCE.CURRENT_AS_OF() AS as_of)
SELECT * FROM (
  SELECT 'ME-A01' AS a, 'P-201' AS b, 'P-201/DRIVE_END_BEARING' AS c, DATEADD('day',-96, as_of) AS d,
         'REPLACEMENT' AS e, 'Rising vibration RMS with bearing temperature increase' AS f,
         'DRIVE_END_BEARING_DEGRADATION' AS g, 'DRIVE_END_BEARING_DEGRADATION' AS h, 'CONFIRMED' AS i,
         'Replaced drive-end bearing, re-greased, alignment verified' AS j, 'BRG-SPALL' AS k,
         115.0 AS l, 140.0 AS m, 'BRG-6310-C3' AS n, 96000.00 AS o, 'R. Kulkarni' AS p, 'SOP-BRG-17-v3' AS q, 'CMMS' AS r FROM clk
  UNION ALL SELECT 'ME-A02','P-203','P-203/DRIVE_END_BEARING',DATEADD('day',-58, as_of),
         'REPLACEMENT','Vibration RMS 31% above baseline, audible noise',
         'DRIVE_END_BEARING_DEGRADATION','DRIVE_END_BEARING_DEGRADATION','CONFIRMED',
         'Replaced drive-end bearing; inner race spalling found','BRG-SPALL',
         98.0,125.0,'BRG-6310-C3',88000.00,'A. Deshpande','SOP-BRG-17-v3','CMMS' FROM clk
  UNION ALL SELECT 'ME-A03','P-205','P-205/DRIVE_END_BEARING',DATEADD('day',-31, as_of),
         'REPAIR','Vibration trend rising over 4 days, temperature +7C',
         'DRIVE_END_BEARING_DEGRADATION','DRIVE_END_BEARING_DEGRADATION','CONFIRMED',
         'Re-greased and replaced bearing; lubrication interval shortened','BRG-LUBE',
         70.0,95.0,'BRG-6310-C3',74000.00,'R. Kulkarni','SOP-BRG-17-v4','CMMS' FROM clk
  UNION ALL SELECT 'ME-N01','P-202','P-202/COUPLING',DATEADD('day',-19, as_of),
         'INSPECTION','Elevated vibration at 2x running speed',
         'SHAFT_MISALIGNMENT',NULL,'NO_FAULT_FOUND',
         'Alignment within tolerance; no corrective action taken',NULL,
         0.0,75.0,NULL,12000.00,'A. Deshpande','SOP-ALIGN-09-v2','CMMS' FROM clk
  UNION ALL SELECT 'ME-L01','P-204','P-204/DRIVE_END_BEARING',DATEADD('hour',-840, as_of),
         'SERVICE','Scheduled lubrication service',
         NULL,NULL,'UNCONFIRMED',
         'Lubrication service completed',NULL,
         0.0,30.0,'LUBE-EP2',6000.00,'S. Iyer','SOP-BRG-17-v4','CMMS' FROM clk
  UNION ALL SELECT 'ME-H01','P-204','P-204/DRIVE_END_BEARING',DATEADD('day',-210, as_of),
         'INSPECTION','Routine condition inspection',
         NULL,NULL,'NO_FAULT_FOUND',
         'Bearing condition acceptable at inspection',NULL,
         0.0,60.0,NULL,15000.00,'R. Kulkarni','SOP-BRG-17-v3','CMMS' FROM clk
);

-- ----------------------------------------------------------------------------
-- Seed: work orders
--
-- WO-2041 is an OPEN unrelated order on P-202 in the same window family, so the
-- open-work conflict check has something real to find.
-- ----------------------------------------------------------------------------
INSERT OVERWRITE INTO CORE.WORK_ORDER
WITH clk AS (SELECT GOVERNANCE.CURRENT_AS_OF() AS as_of)
SELECT * FROM (
  SELECT 'WO-2041' AS a,'P-202' AS b,'P-202/COUPLING' AS c,'ALIGN_CHECK' AS d,'OPEN' AS e,'MEDIUM' AS f,
         'MAINTENANCE_PLANNER' AS g,'2026-09-15 14:00:00'::TIMESTAMP_NTZ AS h,'2026-09-15 15:30:00'::TIMESTAMP_NTZ AS i,
         NULL::TIMESTAMP_NTZ AS j, NULL::TIMESTAMP_NTZ AS k,'SOP-ALIGN-09-v2' AS l, NULL AS m,
         'Alignment re-check following elevated 2x vibration' AS n,'CMMS' AS o FROM clk
  UNION ALL SELECT 'WO-2038','P-201','P-201/DRIVE_END_BEARING','BRG_REPLACE','COMPLETED','HIGH',
         'MAINTENANCE_PLANNER',DATEADD('day',-96,as_of),DATEADD('day',-96,as_of),
         DATEADD('day',-96,as_of),DATEADD('day',-96,as_of),'SOP-BRG-17-v3','BRG-SPALL',
         'Drive-end bearing replacement','CMMS' FROM clk
  UNION ALL SELECT 'WO-2039','P-203','P-203/DRIVE_END_BEARING','BRG_REPLACE','COMPLETED','HIGH',
         'MAINTENANCE_PLANNER',DATEADD('day',-58,as_of),DATEADD('day',-58,as_of),
         DATEADD('day',-58,as_of),DATEADD('day',-58,as_of),'SOP-BRG-17-v3','BRG-SPALL',
         'Drive-end bearing replacement','CMMS' FROM clk
  UNION ALL SELECT 'WO-2040','P-205','P-205/DRIVE_END_BEARING','BRG_REPLACE','COMPLETED','MEDIUM',
         'MAINTENANCE_PLANNER',DATEADD('day',-31,as_of),DATEADD('day',-31,as_of),
         DATEADD('day',-31,as_of),DATEADD('day',-31,as_of),'SOP-BRG-17-v4','BRG-LUBE',
         'Bearing re-grease and replacement','CMMS' FROM clk
);

-- ----------------------------------------------------------------------------
-- Verification
-- ----------------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM CORE.DOWNTIME_EVENT)   AS downtime_events,
    (SELECT COUNT(*) FROM CORE.PRODUCTION_EVENT) AS production_events,
    (SELECT COUNT(*) FROM CORE.QUALITY_EVENT)    AS quality_events,
    (SELECT COUNT(*) FROM CORE.MAINTENANCE_EVENT WHERE CONFIRMATION_STATE='CONFIRMED') AS confirmed_analogs,
    (SELECT COUNT(*) FROM CORE.WORK_ORDER WHERE STATUS='OPEN') AS open_work_orders;
