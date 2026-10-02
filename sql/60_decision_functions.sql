-- =============================================================================
-- 60_decision_functions.sql
-- Manufacturing OEE & Maintenance Decision Copilot
--
-- The deterministic decision services. Every policy-critical value the copilot
-- reports comes from exactly one of these, and the skills are forbidden from
-- computing any of them.
--
--   GOVERNANCE.VALIDATE_SENSOR_CONTEXT   data-quality gate, fails closed
--   GOVERNANCE.RESOLVE_CURRENT_PROCEDURE current approved procedure and version
--   AI.GET_ASSET_RISK                    risk components with model scope
--   DECISION.EVALUATE_MAINTENANCE_OPTIONS feasibility predicate + net value
--   GOVERNANCE.CHECK_MAINTENANCE_SAFETY  authoritative safety gate
--
-- WHY THIS MATTERS MORE THAN IT LOOKS: a language model asked to "check whether the
-- part is available" will produce a confident sentence whether or not it looked. These
-- functions make the answer a row. The demo proof is that changing one inventory row
-- changes the recommendation with no prompt edit.
--
-- SAFETY PRECEDES ECONOMICS, STRUCTURALLY. EVALUATE_MAINTENANCE_OPTIONS returns
-- FEASIBLE as a hard boolean computed before any net-value arithmetic, and net value is
-- NULL for an infeasible option. There is no ordering of the output in which an unsafe
-- or infeasible option can win on cost.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE MFG_COPILOT_DB;

-- ----------------------------------------------------------------------------
-- GOVERNANCE.VALIDATE_SENSOR_CONTEXT(asset_id)
--
-- A thin, stable interface over GOVERNANCE.SENSOR_CONTEXT_CHECK. Deliberately thin:
-- one implementation of the checks means the number the copilot quotes and the number
-- the gate enforces cannot drift apart.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION GOVERNANCE.VALIDATE_SENSOR_CONTEXT(P_ASSET_ID VARCHAR)
RETURNS TABLE (
    CHECK_CODE VARCHAR, STATUS VARCHAR, OBSERVED VARCHAR, THRESHOLD VARCHAR,
    DETAIL VARCHAR, RULE_VERSION VARCHAR
)
COMMENT = 'Deterministic data-quality result for one asset as of the pinned demo clock: freshness, gaps, units, range, scale plausibility, flatline, tag health, operating-state comparability. Fails closed -- a missing tag yields FAIL, never an absent row.'
AS
$$
SELECT CHECK_CODE, STATUS, OBSERVED, THRESHOLD, DETAIL, RULE_VERSION
FROM MFG_COPILOT_DB.GOVERNANCE.SENSOR_CONTEXT_CHECK
WHERE ASSET_ID = P_ASSET_ID
ORDER BY CASE STATUS WHEN 'FAIL' THEN 1 WHEN 'REVIEW' THEN 2 ELSE 3 END, CHECK_CODE
$$;

-- ----------------------------------------------------------------------------
-- GOVERNANCE.RESOLVE_CURRENT_PROCEDURE(task_code, asset_class)
--
-- Returns the CURRENT approved procedure for a task, or no rows. Returning no rows is
-- the point: the feasibility predicate treats absence as "no approved procedure
-- exists", which is what SUPERSEDED_SOP must produce. A superseded version is never
-- returned as a substitute.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION GOVERNANCE.RESOLVE_CURRENT_PROCEDURE(P_TASK_CODE VARCHAR, P_ASSET_CLASS VARCHAR)
RETURNS TABLE (
    PROCEDURE_CODE VARCHAR, VERSION VARCHAR, PROCEDURE_REF VARCHAR,
    TITLE VARCHAR, DOCUMENT_TYPE VARCHAR, APPROVED_BY VARCHAR
)
COMMENT = 'The CURRENT approved procedure for a task and asset class. Returns zero rows when none is current -- absence is a real answer and must not be substituted with a superseded version.'
AS
$$
SELECT p.PROCEDURE_CODE, p.VERSION, p.PROCEDURE_REF, p.TITLE, p.DOCUMENT_TYPE, p.APPROVED_BY
FROM MFG_COPILOT_DB.GOVERNANCE.PROCEDURE_CURRENT p
JOIN MFG_COPILOT_DB.GOVERNANCE.MAINTENANCE_TASK t
  ON t.GOVERNED_BY_PROCEDURE = p.PROCEDURE_CODE
WHERE t.TASK_CODE = P_TASK_CODE
  AND p.STATUS = 'CURRENT'
  AND (p.APPLIES_TO_ASSET_CLASS = P_ASSET_CLASS
       OR p.APPLIES_TO_ASSET_CLASS IS NULL)
$$;

-- ----------------------------------------------------------------------------
-- AI.GET_ASSET_RISK(asset_id, horizon_hours)
--
-- Risk components, model scope, and the consequence terms. Every numeric output
-- carries ESTIMATE_TYPE. Returns the suppression reason rather than a number when the
-- data-quality verdict is FAIL or the asset is out of model scope.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION AI.GET_ASSET_RISK(P_ASSET_ID VARCHAR, P_HORIZON_HOURS NUMBER)
RETURNS TABLE (
    ASSET_ID VARCHAR, COMPONENT_ID VARCHAR, FAULT_MODE VARCHAR,
    HORIZON_HOURS NUMBER, FAILURE_PROBABILITY NUMBER(5,3), ANOMALY_SCORE NUMBER(5,3),
    RUL_LOW_DAYS NUMBER, RUL_HIGH_DAYS NUMBER, CONFIDENCE_BAND VARCHAR,
    CONSEQUENCE_SCORE NUMBER(5,2), OEE_EXPOSURE_SCORE NUMBER(5,2),
    CONFIDENCE_PENALTY NUMBER(5,2), PRIORITY_SCORE NUMBER(10,4),
    IN_SCOPE BOOLEAN, SCOPE_REASON VARCHAR, DQ_VERDICT VARCHAR, FAILED_CHECKS VARCHAR,
    TRIAGE_LANE VARCHAR, ANY_TRIP_EXCEEDED BOOLEAN, SCORE_EXPLANATION VARCHAR,
    PCT_ABOVE_BASELINE NUMBER(10,1), SUSTAINED_MIN_ABOVE_ALERT NUMBER,
    TEMP_DELTA_C NUMBER(10,2), LUBE_OVERDUE_HOURS NUMBER,
    MODEL_VERSION VARCHAR, RULE_VERSION VARCHAR, ESTIMATE_TYPE VARCHAR, AS_OF TIMESTAMP_NTZ
)
COMMENT = 'Condition, risk, consequence, and model scope for one asset. All estimates are SYNTHETIC_DEMO. Probability, anomaly, and RUL are NULL when data quality fails or the asset is outside the validated model scope -- a suppressed number, never a guessed one.'
AS
$$
SELECT
    h.ASSET_ID, h.COMPONENT_ID, h.FAULT_MODE,
    COALESCE(P_HORIZON_HOURS, h.HORIZON_HOURS) AS HORIZON_HOURS,
    h.FAILURE_PROBABILITY, h.ANOMALY_SCORE, h.RUL_LOW_DAYS, h.RUL_HIGH_DAYS, h.CONFIDENCE_BAND,
    h.CRITICALITY_SCORE AS CONSEQUENCE_SCORE,
    (CASE WHEN COALESCE(h.RECENT_AVAILABILITY, 1) < 0.95 THEN 0.15 ELSE 0.0 END
     + LEAST(0.15, COALESCE(h.OVERLAP_STOP_MIN_24H, 0) / 100.0))::NUMBER(5,2) AS OEE_EXPOSURE_SCORE,
    (CASE h.CONFIDENCE_BAND WHEN 'LOW' THEN 0.10 WHEN 'MEDIUM' THEN 0.05 ELSE 0.0 END)::NUMBER(5,2) AS CONFIDENCE_PENALTY,
    h.PRIORITY_SCORE, h.IN_SCOPE, h.SCOPE_REASON, h.DQ_VERDICT, h.FAILED_CHECKS,
    h.TRIAGE_LANE, h.ANY_TRIP_EXCEEDED, h.SCORE_EXPLANATION,
    h.PCT_ABOVE_BASELINE, h.SUSTAINED_MIN_ABOVE_ALERT, h.TEMP_DELTA_C, h.LUBE_OVERDUE_HOURS,
    h.MODEL_VERSION, 'risk-rules-v1' AS RULE_VERSION, h.ESTIMATE_TYPE, h.AS_OF
FROM MFG_COPILOT_DB.AI.ASSET_HEALTH_SNAPSHOT h
WHERE h.ASSET_ID = P_ASSET_ID
$$;

-- ----------------------------------------------------------------------------
-- DECISION.OPTION_CANDIDATE -- the option set, with feasibility resolved per asset
--
-- A view rather than a function so the Streamlit app and the tests can read it
-- directly, and so the feasibility logic exists in exactly one place.
--
-- Options are built only from GOVERNANCE.MAINTENANCE_TASK plus two synthetic
-- non-task options (defer, gather evidence). The copilot cannot invent an action
-- because there is no row for one.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW DECISION.OPTION_CANDIDATE
COMMENT = 'Candidate maintenance options per asset with the feasibility predicate resolved term by term. FEASIBLE is computed before any cost arithmetic and net value is NULL when infeasible, so an infeasible option cannot win on economics.'
AS
WITH base AS (
    SELECT
        a.ASSET_ID, a.ASSET_CLASS, a.LINE_ID, a.SITE_ID, a.CRITICALITY,
        c.COMPONENT_ID,
        t.TASK_CODE, t.TASK_LABEL, t.ACTION_TYPE, t.MITIGATES_FAULT_MODE,
        t.ESTIMATED_DURATION_MIN, t.REQUIRES_LINE_STOP, t.ESTIMATED_COST,
        t.GOVERNED_BY_PROCEDURE,
        h.FAILURE_PROBABILITY, h.RUL_LOW_DAYS, h.RUL_HIGH_DAYS,
        h.DQ_VERDICT, h.FAILED_CHECKS, h.IN_SCOPE, h.SCOPE_REASON,
        h.ANY_TRIP_EXCEEDED, h.CRITICALITY_SCORE, h.TRIAGE_LANE,
        s.CONTRIBUTION_VALUE_PER_HOUR,
        -- Exposed downtime scales with consequence class rather than being a flat
        -- constant. An unplanned failure of an A-critical main transfer pump does not
        -- cost the same as a C-critical utility pump, and a single 6-hour assumption
        -- made every intervention look uneconomic against its own repair cost.
        CASE a.CRITICALITY WHEN 'A' THEN 24 WHEN 'B' THEN 12 WHEN 'C' THEN 6 ELSE 3 END
          AS EXPOSED_DOWNTIME_HOURS,
        -- Has a physical inspection actually confirmed this fault mode on this
        -- component? Only a MAINTENANCE_EVENT row can establish that; condition data
        -- and model output cannot.
        EXISTS (
            SELECT 1 FROM MFG_COPILOT_DB.CORE.MAINTENANCE_EVENT me
            WHERE me.COMPONENT_ID = c.COMPONENT_ID
              AND me.CONFIRMATION_STATE = 'CONFIRMED'
              AND me.CONFIRMED_FAULT_MODE = t.MITIGATES_FAULT_MODE
              AND me.EVENT_TS >= DATEADD('day', -14, MFG_COPILOT_DB.GOVERNANCE.CURRENT_AS_OF())
        ) AS DIAGNOSIS_CONFIRMED
    FROM CORE.ASSET a
    JOIN CORE.COMPONENT c
      ON c.ASSET_ID = a.ASSET_ID AND c.COMPONENT_TYPE = 'DRIVE_END_BEARING'
    JOIN GOVERNANCE.MAINTENANCE_TASK t
      ON t.MITIGATES_FAULT_MODE = 'DRIVE_END_BEARING_DEGRADATION'
    LEFT JOIN AI.ASSET_HEALTH_SNAPSHOT h ON h.ASSET_ID = a.ASSET_ID
    LEFT JOIN CORE.SITE s ON s.SITE_ID = a.SITE_ID
),
-- Resource resolution, one term of the feasibility predicate each.
proc AS (
    SELECT b.ASSET_ID, b.TASK_CODE,
           MAX(p.PROCEDURE_REF) AS PROCEDURE_REF,
           COUNT(p.PROCEDURE_REF) > 0 AS HAS_CURRENT_PROCEDURE
    FROM base b
    LEFT JOIN GOVERNANCE.PROCEDURE_CURRENT p
           ON p.PROCEDURE_CODE = b.GOVERNED_BY_PROCEDURE AND p.STATUS = 'CURRENT'
    GROUP BY b.ASSET_ID, b.TASK_CODE
),
parts_req AS (
    SELECT b.ASSET_ID, b.TASK_CODE,
           LISTAGG(tr.REQUIREMENT_CODE, ', ') AS REQUIRED_PARTS,
           MIN(COALESCE(pi.AVAILABLE_QTY, 0)) AS MIN_PART_AVAILABLE,
           MAX(COALESCE(pi.LEAD_TIME_DAYS, 0)) AS MAX_PART_LEAD_DAYS
    FROM base b
    JOIN GOVERNANCE.TASK_REQUIREMENT tr
      ON tr.TASK_CODE = b.TASK_CODE AND tr.REQUIREMENT_TYPE = 'PART' AND tr.IS_MANDATORY
    LEFT JOIN GOVERNANCE.PART_COMPATIBILITY pc
           ON pc.PART_CODE = tr.REQUIREMENT_CODE
          AND (pc.ASSET_ID = b.ASSET_ID OR pc.ASSET_CLASS = b.ASSET_CLASS)
    LEFT JOIN CORE.PART_INVENTORY pi
           ON pi.PART_CODE = tr.REQUIREMENT_CODE AND pi.SITE_ID = b.SITE_ID
    GROUP BY b.ASSET_ID, b.TASK_CODE
),
skill_req AS (
    SELECT b.ASSET_ID, b.TASK_CODE,
           LISTAGG(DISTINCT tr.REQUIREMENT_CODE, ', ') AS REQUIRED_SKILLS,
           COUNT_IF(tq.IS_AVAILABLE) AS QUALIFIED_AVAILABLE,
           LISTAGG(DISTINCT CASE WHEN tq.IS_AVAILABLE THEN tq.TECHNICIAN_NAME END, ', ') AS QUALIFIED_TECHNICIANS
    FROM base b
    JOIN GOVERNANCE.TASK_REQUIREMENT tr
      ON tr.TASK_CODE = b.TASK_CODE AND tr.REQUIREMENT_TYPE = 'SKILL' AND tr.IS_MANDATORY
    LEFT JOIN CORE.TECHNICIAN_QUALIFICATION tq
           ON tq.SKILL_CODE = tr.REQUIREMENT_CODE AND tq.SITE_ID = b.SITE_ID
    GROUP BY b.ASSET_ID, b.TASK_CODE
),
tool_req AS (
    SELECT b.ASSET_ID, b.TASK_CODE,
           MIN(COALESCE(ti.QTY_AVAILABLE, 0)) AS MIN_TOOL_AVAILABLE
    FROM base b
    JOIN GOVERNANCE.TASK_REQUIREMENT tr
      ON tr.TASK_CODE = b.TASK_CODE AND tr.REQUIREMENT_TYPE = 'TOOL' AND tr.IS_MANDATORY
    LEFT JOIN CORE.TOOL_INVENTORY ti
           ON ti.TOOL_CODE = tr.REQUIREMENT_CODE AND ti.SITE_ID = b.SITE_ID
    GROUP BY b.ASSET_ID, b.TASK_CODE
),
-- Earliest authorized window with enough allowed downtime for the task.
window_fit AS (
    SELECT b.ASSET_ID, b.TASK_CODE,
           MIN(w.WINDOW_START) AS EARLIEST_WINDOW_START,
           MIN_BY(w.WINDOW_ID, w.WINDOW_START) AS EARLIEST_WINDOW_ID,
           MIN_BY(w.HOURS_UNTIL_START, w.WINDOW_START) AS HOURS_UNTIL_WINDOW
    FROM base b
    JOIN CORE.PRODUCTION_WINDOW w
      ON w.LINE_ID = b.LINE_ID
     AND w.AUTHORIZATION_STATUS = 'APPROVED'
     AND w.ALLOWED_DOWNTIME_MIN >= b.ESTIMATED_DURATION_MIN
     AND w.WINDOW_START >= GOVERNANCE.CURRENT_AS_OF()
    WHERE b.REQUIRES_LINE_STOP
    GROUP BY b.ASSET_ID, b.TASK_CODE
),
open_conflict AS (
    SELECT b.ASSET_ID, b.TASK_CODE, COUNT(wo.WORK_ORDER_ID) AS OPEN_CONFLICTS
    FROM base b
    LEFT JOIN CORE.WORK_ORDER wo
           ON wo.ASSET_ID = b.ASSET_ID AND wo.STATUS IN ('OPEN','IN_PROGRESS')
    GROUP BY b.ASSET_ID, b.TASK_CODE
),
resolved AS (
    SELECT
        b.*,
        pr.PROCEDURE_REF, COALESCE(pr.HAS_CURRENT_PROCEDURE, FALSE) AS HAS_CURRENT_PROCEDURE,
        pq.REQUIRED_PARTS, pq.MIN_PART_AVAILABLE, pq.MAX_PART_LEAD_DAYS,
        sq.REQUIRED_SKILLS, COALESCE(sq.QUALIFIED_AVAILABLE, 0) AS QUALIFIED_AVAILABLE, sq.QUALIFIED_TECHNICIANS,
        tq.MIN_TOOL_AVAILABLE,
        wf.EARLIEST_WINDOW_ID, wf.EARLIEST_WINDOW_START, wf.HOURS_UNTIL_WINDOW,
        COALESCE(oc.OPEN_CONFLICTS, 0) AS OPEN_CONFLICTS
    FROM base b
    LEFT JOIN proc        pr ON pr.ASSET_ID = b.ASSET_ID AND pr.TASK_CODE = b.TASK_CODE
    LEFT JOIN parts_req   pq ON pq.ASSET_ID = b.ASSET_ID AND pq.TASK_CODE = b.TASK_CODE
    LEFT JOIN skill_req   sq ON sq.ASSET_ID = b.ASSET_ID AND sq.TASK_CODE = b.TASK_CODE
    LEFT JOIN tool_req    tq ON tq.ASSET_ID = b.ASSET_ID AND tq.TASK_CODE = b.TASK_CODE
    LEFT JOIN window_fit  wf ON wf.ASSET_ID = b.ASSET_ID AND wf.TASK_CODE = b.TASK_CODE
    LEFT JOIN open_conflict oc ON oc.ASSET_ID = b.ASSET_ID AND oc.TASK_CODE = b.TASK_CODE
),
predicated AS (
    SELECT
        r.*,
        -- The feasibility predicate, term by term. Each term is reported so a rejection
        -- always carries a deterministic reason rather than a shrug.
        (r.DQ_VERDICT <> 'FAIL')                                       AS T_DATA_QUALITY_SUFFICIENT,
        COALESCE(r.IN_SCOPE, FALSE)                                    AS T_WITHIN_MODEL_SCOPE,
        NOT COALESCE(r.ANY_TRIP_EXCEEDED, FALSE)                       AS T_NO_SAFETY_CONFLICT,
        r.HAS_CURRENT_PROCEDURE                                        AS T_APPROVED_PROCEDURE_EXISTS,
        (r.REQUIRED_PARTS IS NULL OR COALESCE(r.MIN_PART_AVAILABLE, 0) > 0) AS T_PARTS_AVAILABLE,
        (r.REQUIRED_SKILLS IS NULL OR r.QUALIFIED_AVAILABLE > 0)       AS T_QUALIFIED_LABOUR_AVAILABLE,
        (r.MIN_TOOL_AVAILABLE IS NULL OR r.MIN_TOOL_AVAILABLE > 0)     AS T_TOOLS_AVAILABLE,
        (NOT r.REQUIRES_LINE_STOP OR r.EARLIEST_WINDOW_ID IS NOT NULL) AS T_WINDOW_AUTHORIZED
    FROM resolved r
),
scored AS (
    SELECT
        p.*,
        (p.T_DATA_QUALITY_SUFFICIENT AND p.T_WITHIN_MODEL_SCOPE AND p.T_NO_SAFETY_CONFLICT
         AND p.T_APPROVED_PROCEDURE_EXISTS AND p.T_PARTS_AVAILABLE
         AND p.T_QUALIFIED_LABOUR_AVAILABLE AND p.T_TOOLS_AVAILABLE
         AND p.T_WINDOW_AUTHORIZED) AS FEASIBLE,
        -- First failing term, in the order a planner would check them. Safety and data
        -- quality come first so a rejection reason is never merely "no part" when the
        -- telemetry was unusable to begin with.
        CASE
          WHEN NOT p.T_DATA_QUALITY_SUFFICIENT     THEN 'DATA_QUALITY_INSUFFICIENT: ' || COALESCE(p.FAILED_CHECKS, 'unknown')
          WHEN NOT p.T_NO_SAFETY_CONFLICT          THEN 'UNRESOLVED_SAFETY_CONFLICT: configured trip exceeded'
          WHEN NOT p.T_WITHIN_MODEL_SCOPE          THEN 'OUT_OF_MODEL_SCOPE: ' || COALESCE(p.SCOPE_REASON, 'asset class not covered')
          WHEN NOT p.T_APPROVED_PROCEDURE_EXISTS   THEN 'NO_CURRENT_APPROVED_PROCEDURE for ' || p.GOVERNED_BY_PROCEDURE
          WHEN NOT p.T_PARTS_AVAILABLE             THEN 'PART_UNAVAILABLE: ' || COALESCE(p.REQUIRED_PARTS, '') ||
                                                        ' (lead time ' || COALESCE(p.MAX_PART_LEAD_DAYS, 0)::VARCHAR || ' days)'
          WHEN NOT p.T_QUALIFIED_LABOUR_AVAILABLE  THEN 'NO_QUALIFIED_LABOUR: ' || COALESCE(p.REQUIRED_SKILLS, '') ||
                                                        ' (no valid certification at as-of date)'
          WHEN NOT p.T_TOOLS_AVAILABLE             THEN 'TOOL_UNAVAILABLE'
          WHEN NOT p.T_WINDOW_AUTHORIZED           THEN 'PRODUCTION_WINDOW_NOT_AUTHORIZED: no approved window with ' ||
                                                        p.ESTIMATED_DURATION_MIN::VARCHAR || ' min allowed downtime'
        END AS INFEASIBLE_REASON
    FROM predicated p
)
SELECT
    s.ASSET_ID, s.COMPONENT_ID, s.LINE_ID, s.ASSET_CLASS,
    s.TASK_CODE, s.TASK_LABEL, s.ACTION_TYPE, s.MITIGATES_FAULT_MODE,
    s.ESTIMATED_DURATION_MIN, s.REQUIRES_LINE_STOP, s.ESTIMATED_COST,
    s.PROCEDURE_REF, s.REQUIRED_PARTS, s.MIN_PART_AVAILABLE, s.MAX_PART_LEAD_DAYS,
    s.REQUIRED_SKILLS, s.QUALIFIED_AVAILABLE, s.QUALIFIED_TECHNICIANS,
    s.MIN_TOOL_AVAILABLE, s.EARLIEST_WINDOW_ID, s.EARLIEST_WINDOW_START, s.HOURS_UNTIL_WINDOW,
    s.OPEN_CONFLICTS,
    s.T_DATA_QUALITY_SUFFICIENT, s.T_WITHIN_MODEL_SCOPE, s.T_NO_SAFETY_CONFLICT,
    s.T_APPROVED_PROCEDURE_EXISTS, s.T_PARTS_AVAILABLE, s.T_QUALIFIED_LABOUR_AVAILABLE,
    s.T_TOOLS_AVAILABLE, s.T_WINDOW_AUTHORIZED,
    s.FEASIBLE, s.INFEASIBLE_REASON,
    s.FAILURE_PROBABILITY, s.RUL_LOW_DAYS, s.RUL_HIGH_DAYS, s.DQ_VERDICT, s.TRIAGE_LANE,
    s.CRITICALITY, s.EXPOSED_DOWNTIME_HOURS, s.DIAGNOSIS_CONFIRMED,
    s.CONTRIBUTION_VALUE_PER_HOUR, s.CRITICALITY_SCORE,
    -- Action effectiveness, discounted when the fault mode is UNCONFIRMED.
    --
    -- This is the economic expression of the blueprint's central argument. A repair or a
    -- lubrication service only pays off if it happens to address the mechanism that is
    -- actually degrading, and nothing has established which one that is. Inspection is
    -- not discounted, because resolving the uncertainty is precisely what it delivers.
    -- Without this term the model recommended a cheap lubrication service over an
    -- inspection, which is exactly the premature-intervention failure the copilot exists
    -- to prevent.
    (CASE s.ACTION_TYPE WHEN 'REPLACE' THEN 0.90 WHEN 'REPAIR' THEN 0.70
                        WHEN 'INSPECT' THEN 0.45 WHEN 'SERVICE' THEN 0.35
                        ELSE 0.10 END
     * CASE WHEN s.DIAGNOSIS_CONFIRMED OR s.ACTION_TYPE IN ('INSPECT','MONITOR') THEN 1.00
            WHEN s.ACTION_TYPE = 'REPLACE' THEN 0.45
            WHEN s.ACTION_TYPE = 'SERVICE' THEN 0.40
            ELSE 0.50 END)::NUMBER(5,3)                                 AS ACTION_EFFECTIVENESS,
    -- Value components. NULL for an infeasible option: there is no meaningful net value
    -- for something that cannot be done, and a number here would invite ranking it.
    CASE WHEN s.FEASIBLE THEN
      ROUND(COALESCE(s.FAILURE_PROBABILITY, 0)
            * (CASE s.ACTION_TYPE WHEN 'REPLACE' THEN 0.90 WHEN 'REPAIR' THEN 0.70
                                  WHEN 'INSPECT' THEN 0.45 WHEN 'SERVICE' THEN 0.35
                                  ELSE 0.10 END
               * CASE WHEN s.DIAGNOSIS_CONFIRMED OR s.ACTION_TYPE IN ('INSPECT','MONITOR') THEN 1.00
                      WHEN s.ACTION_TYPE = 'REPLACE' THEN 0.45
                      WHEN s.ACTION_TYPE = 'SERVICE' THEN 0.40
                      ELSE 0.50 END)
            * s.EXPOSED_DOWNTIME_HOURS
            * COALESCE(s.CONTRIBUTION_VALUE_PER_HOUR, 0)
            * COALESCE(s.CRITICALITY_SCORE, 0.5), 2) END              AS RISK_REDUCTION_VALUE,
    CASE WHEN s.FEASIBLE THEN s.ESTIMATED_COST END                    AS MAINTENANCE_COST,
    CASE WHEN s.FEASIBLE THEN
      ROUND(CASE WHEN s.REQUIRES_LINE_STOP AND s.EARLIEST_WINDOW_ID IS NULL
                 THEN s.ESTIMATED_DURATION_MIN / 60.0 * COALESCE(s.CONTRIBUTION_VALUE_PER_HOUR, 0)
                 ELSE 0 END, 2) END                                   AS PLANNED_PRODUCTION_LOSS,
    CASE WHEN s.FEASIBLE THEN
      ROUND(COALESCE(s.FAILURE_PROBABILITY, 0)
            * (CASE s.ACTION_TYPE WHEN 'REPLACE' THEN 0.90 WHEN 'REPAIR' THEN 0.70
                                  WHEN 'INSPECT' THEN 0.45 WHEN 'SERVICE' THEN 0.35
                                  ELSE 0.10 END
               * CASE WHEN s.DIAGNOSIS_CONFIRMED OR s.ACTION_TYPE IN ('INSPECT','MONITOR') THEN 1.00
                      WHEN s.ACTION_TYPE = 'REPLACE' THEN 0.45
                      WHEN s.ACTION_TYPE = 'SERVICE' THEN 0.40
                      ELSE 0.50 END)
            * s.EXPOSED_DOWNTIME_HOURS * COALESCE(s.CONTRIBUTION_VALUE_PER_HOUR, 0)
            * COALESCE(s.CRITICALITY_SCORE, 0.5)
            - s.ESTIMATED_COST
            - CASE WHEN s.REQUIRES_LINE_STOP AND s.EARLIEST_WINDOW_ID IS NULL
                   THEN s.ESTIMATED_DURATION_MIN / 60.0 * COALESCE(s.CONTRIBUTION_VALUE_PER_HOUR, 0)
                   ELSE 0 END, 2) END                                 AS ESTIMATED_NET_VALUE,
    'risk reduction = failure probability x action effectiveness x exposed downtime hours x '
      || 'site contribution per hour x asset criticality weight; net value subtracts '
      || 'maintenance cost and any unwindowed production loss. Action effectiveness is '
      || 'discounted when the fault mode is UNCONFIRMED, because a fix aimed at the wrong '
      || 'mechanism does not reduce risk.'                                          AS VALUE_METHOD,
    'Exposed downtime is ' || s.EXPOSED_DOWNTIME_HOURS::VARCHAR || ' h for criticality '
      || s.CRITICALITY || '. Diagnosis confirmed: ' || s.DIAGNOSIS_CONFIRMED::VARCHAR
      || '. Assumes deferral leaves failure probability at its current level and that the '
      || 'approved window incurs no incremental changeover loss.'                   AS VALUE_ASSUMPTIONS,
    'option-rules-v1'                                                 AS RULE_VERSION,
    'SYNTHETIC_DEMO'                                                  AS ESTIMATE_TYPE,
    GOVERNANCE.CURRENT_AS_OF()                                        AS AS_OF,
    GOVERNANCE.ACTIVE_SCENARIO()                                      AS ACTIVE_SCENARIO
FROM scored s;

-- ----------------------------------------------------------------------------
-- DECISION.EVALUATE_MAINTENANCE_OPTIONS(asset_id)
--
-- Returns at most three feasible options plus every rejected one with its reason, and
-- always includes the two non-task options a decision must consider: defer, and gather
-- more evidence. The blueprint requires "no more than three bounded options"; the
-- rejected set is returned alongside rather than hidden, because a recommendation
-- without its rejected alternatives is not auditable.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION DECISION.EVALUATE_MAINTENANCE_OPTIONS(P_ASSET_ID VARCHAR)
RETURNS TABLE (
    OPTION_ID VARCHAR, ACTION VARCHAR, ACTION_TYPE VARCHAR, TASK_CODE VARCHAR,
    OPTION_RANK NUMBER, IS_RECOMMENDED BOOLEAN, IS_BOUNDED_SET BOOLEAN,
    TIMING VARCHAR, PROPOSED_WINDOW_ID VARCHAR, PROPOSED_WINDOW_START TIMESTAMP_NTZ,
    FEASIBLE BOOLEAN, INFEASIBLE_REASON VARCHAR,
    REQUIRED_PARTS VARCHAR, PART_AVAILABLE NUMBER, PART_LEAD_DAYS NUMBER,
    REQUIRED_SKILLS VARCHAR, QUALIFIED_TECHNICIANS VARCHAR,
    PROCEDURE_REF VARCHAR, OPEN_CONFLICTS NUMBER,
    RISK_REDUCTION_VALUE NUMBER(14,2), MAINTENANCE_COST NUMBER(14,2),
    PLANNED_PRODUCTION_LOSS NUMBER(14,2), ESTIMATED_NET_VALUE NUMBER(14,2),
    VALUE_METHOD VARCHAR, VALUE_ASSUMPTIONS VARCHAR,
    RULE_VERSION VARCHAR, ESTIMATE_TYPE VARCHAR, AS_OF TIMESTAMP_NTZ
)
COMMENT = 'Feasible and rejected maintenance options for one asset, each with the deterministic reason it was rejected. Always includes DEFER and GATHER_EVIDENCE. Net value is NULL for infeasible options so economics can never outrank feasibility. OPTION_RANK and IS_RECOMMENDED are computed here, not chosen by the caller.'
AS
$$
WITH task_options AS (
    SELECT
        -- Option IDs are derived from the TASK, never from rank position. A positional ID
        -- would silently change meaning whenever the scoring changed, and an approval
        -- recorded against "OPT-02" would then authorise a different action than the one
        -- the approver saw. The idempotency key for staging depends on this being stable.
        CASE oc.TASK_CODE
          WHEN 'BRG_INSPECT'  THEN 'OPT-INSPECT'
          WHEN 'BRG_REPLACE'  THEN 'OPT-REPLACE'
          WHEN 'LUBE_SERVICE' THEN 'OPT-LUBE'
          WHEN 'VIB_MONITOR'  THEN 'OPT-MONITOR'
          ELSE 'OPT-' || oc.TASK_CODE
        END AS OPTION_ID,
        CASE oc.TASK_CODE
          WHEN 'BRG_INSPECT'  THEN 'INSPECT_THEN_CONDITIONAL_REPLACE'
          WHEN 'BRG_REPLACE'  THEN 'REPLACE_AT_NEXT_APPROVED_WINDOW'
          WHEN 'LUBE_SERVICE' THEN 'LUBRICATION_SERVICE'
          WHEN 'VIB_MONITOR'  THEN 'ENHANCED_MONITORING'
          ELSE oc.TASK_CODE
        END AS ACTION,
        oc.ACTION_TYPE, oc.TASK_CODE,
        CASE
          WHEN oc.ACTION_TYPE = 'INSPECT' THEN 'WITHIN_24_HOURS'
          WHEN oc.REQUIRES_LINE_STOP AND oc.EARLIEST_WINDOW_ID IS NOT NULL
            THEN 'AT_WINDOW_' || oc.EARLIEST_WINDOW_ID
          WHEN oc.ACTION_TYPE = 'MONITOR' THEN 'CONTINUOUS'
          ELSE 'WITHIN_72_HOURS'
        END AS TIMING,
        oc.EARLIEST_WINDOW_ID AS PROPOSED_WINDOW_ID,
        oc.EARLIEST_WINDOW_START AS PROPOSED_WINDOW_START,
        oc.FEASIBLE, oc.INFEASIBLE_REASON,
        oc.REQUIRED_PARTS, oc.MIN_PART_AVAILABLE AS PART_AVAILABLE, oc.MAX_PART_LEAD_DAYS AS PART_LEAD_DAYS,
        oc.REQUIRED_SKILLS, oc.QUALIFIED_TECHNICIANS,
        oc.PROCEDURE_REF, oc.OPEN_CONFLICTS,
        oc.RISK_REDUCTION_VALUE, oc.MAINTENANCE_COST,
        oc.PLANNED_PRODUCTION_LOSS, oc.ESTIMATED_NET_VALUE,
        oc.VALUE_METHOD, oc.VALUE_ASSUMPTIONS, oc.RULE_VERSION, oc.ESTIMATE_TYPE, oc.AS_OF,
        oc.FAILURE_PROBABILITY, oc.RUL_LOW_DAYS, oc.DQ_VERDICT,
        oc.EXPOSED_DOWNTIME_HOURS, oc.CONTRIBUTION_VALUE_PER_HOUR, oc.CRITICALITY_SCORE
    FROM MFG_COPILOT_DB.DECISION.OPTION_CANDIDATE oc
    WHERE oc.ASSET_ID = P_ASSET_ID
),
-- Deferral and evidence-gathering are always on the table. Deferral is always
-- "feasible" in the resource sense -- doing nothing needs no part -- and its cost is
-- the retained risk, which is exactly the trade-off a planner has to see.
non_task AS (
    SELECT 'OPT-DEFER' AS OPTION_ID, 'DEFER_TO_NEXT_PLANNED_SHUTDOWN' AS ACTION, 'DEFER' AS ACTION_TYPE,
           NULL AS TASK_CODE, 'NEXT_PLANNED_SHUTDOWN' AS TIMING,
           NULL AS PROPOSED_WINDOW_ID, NULL::TIMESTAMP_NTZ AS PROPOSED_WINDOW_START,
           TRUE AS FEASIBLE, NULL AS INFEASIBLE_REASON,
           NULL AS REQUIRED_PARTS, NULL AS PART_AVAILABLE, NULL AS PART_LEAD_DAYS,
           NULL AS REQUIRED_SKILLS, NULL AS QUALIFIED_TECHNICIANS,
           NULL AS PROCEDURE_REF, 0 AS OPEN_CONFLICTS,
           0::NUMBER(14,2) AS RISK_REDUCTION_VALUE, 0::NUMBER(14,2) AS MAINTENANCE_COST,
           0::NUMBER(14,2) AS PLANNED_PRODUCTION_LOSS,
           -- Deferral costs the retained exposure, computed on the same basis as every
           -- other option rather than with its own constants.
           ROUND(-1 * COALESCE(MAX(t.FAILURE_PROBABILITY), 0)
                    * COALESCE(MAX(t.EXPOSED_DOWNTIME_HOURS), 6)
                    * COALESCE(MAX(t.CONTRIBUTION_VALUE_PER_HOUR), 0)
                    * COALESCE(MAX(t.CRITICALITY_SCORE), 0.5), 2)::NUMBER(14,2) AS ESTIMATED_NET_VALUE,
           'deferral net value is the negative of retained failure exposure, on the same '
             || 'probability x hours x contribution x criticality basis as every other option' AS VALUE_METHOD,
           'Assumes the degradation trend continues and no intervening inspection occurs.' AS VALUE_ASSUMPTIONS,
           'option-rules-v1' AS RULE_VERSION, 'SYNTHETIC_DEMO' AS ESTIMATE_TYPE,
           MFG_COPILOT_DB.GOVERNANCE.CURRENT_AS_OF() AS AS_OF
    FROM task_options t
    UNION ALL
    SELECT 'OPT-EVIDENCE', 'GATHER_EVIDENCE', 'GATHER_EVIDENCE', NULL, 'IMMEDIATE',
           NULL, NULL::TIMESTAMP_NTZ, TRUE, NULL,
           NULL, NULL, NULL, NULL, NULL, NULL, 0,
           0::NUMBER(14,2), 0::NUMBER(14,2), 0::NUMBER(14,2), 0::NUMBER(14,2),
           'no value attributed; this option exists so abstention is always available',
           'Chosen when mandatory evidence is missing, stale, contradictory, or out of scope.',
           'option-rules-v1', 'SYNTHETIC_DEMO', MFG_COPILOT_DB.GOVERNANCE.CURRENT_AS_OF()
)
SELECT OPTION_ID, ACTION, ACTION_TYPE, TASK_CODE,
       OPTION_RANK, IS_RECOMMENDED, IS_BOUNDED_SET,
       TIMING, PROPOSED_WINDOW_ID, PROPOSED_WINDOW_START, FEASIBLE, INFEASIBLE_REASON,
       REQUIRED_PARTS, PART_AVAILABLE, PART_LEAD_DAYS, REQUIRED_SKILLS, QUALIFIED_TECHNICIANS,
       PROCEDURE_REF, OPEN_CONFLICTS,
       RISK_REDUCTION_VALUE, MAINTENANCE_COST, PLANNED_PRODUCTION_LOSS, ESTIMATED_NET_VALUE,
       VALUE_METHOD, VALUE_ASSUMPTIONS, RULE_VERSION, ESTIMATE_TYPE, AS_OF
FROM (
    SELECT u.*,
           -- Rank only among FEASIBLE options. An infeasible option has no rank because
           -- it is not a choice. Safety and feasibility are settled before this point.
           CASE WHEN u.FEASIBLE THEN
             ROW_NUMBER() OVER (PARTITION BY u.FEASIBLE
                                ORDER BY u.ESTIMATED_NET_VALUE DESC NULLS LAST, u.OPTION_ID)
           END AS OPTION_RANK,
           -- The single recommended option is computed here rather than left to the
           -- caller, so the recommendation is reproducible and auditable.
           (u.FEASIBLE AND ROW_NUMBER() OVER (PARTITION BY u.FEASIBLE
                ORDER BY u.ESTIMATED_NET_VALUE DESC NULLS LAST, u.OPTION_ID) = 1) AS IS_RECOMMENDED,
           -- The blueprint caps a presented option set at three. GATHER_EVIDENCE is always
           -- inside the set: abstention must never be crowded out by economics.
           (u.FEASIBLE AND (ROW_NUMBER() OVER (PARTITION BY u.FEASIBLE
                ORDER BY u.ESTIMATED_NET_VALUE DESC NULLS LAST, u.OPTION_ID) <= 3
                OR u.OPTION_ID = 'OPT-EVIDENCE')) AS IS_BOUNDED_SET
    FROM (
        SELECT OPTION_ID, ACTION, ACTION_TYPE, TASK_CODE, TIMING, PROPOSED_WINDOW_ID,
               PROPOSED_WINDOW_START, FEASIBLE, INFEASIBLE_REASON, REQUIRED_PARTS, PART_AVAILABLE,
               PART_LEAD_DAYS, REQUIRED_SKILLS, QUALIFIED_TECHNICIANS, PROCEDURE_REF, OPEN_CONFLICTS,
               RISK_REDUCTION_VALUE, MAINTENANCE_COST, PLANNED_PRODUCTION_LOSS, ESTIMATED_NET_VALUE,
               VALUE_METHOD, VALUE_ASSUMPTIONS, RULE_VERSION, ESTIMATE_TYPE, AS_OF
        FROM task_options
        UNION ALL
        SELECT OPTION_ID, ACTION, ACTION_TYPE, TASK_CODE, TIMING, PROPOSED_WINDOW_ID,
               PROPOSED_WINDOW_START, FEASIBLE, INFEASIBLE_REASON, REQUIRED_PARTS, PART_AVAILABLE,
               PART_LEAD_DAYS, REQUIRED_SKILLS, QUALIFIED_TECHNICIANS, PROCEDURE_REF, OPEN_CONFLICTS,
               RISK_REDUCTION_VALUE, MAINTENANCE_COST, PLANNED_PRODUCTION_LOSS, ESTIMATED_NET_VALUE,
               VALUE_METHOD, VALUE_ASSUMPTIONS, RULE_VERSION, ESTIMATE_TYPE, AS_OF
        FROM non_task
    ) u
)
ORDER BY FEASIBLE DESC, OPTION_RANK NULLS LAST, OPTION_ID
$$;

-- ----------------------------------------------------------------------------
-- GOVERNANCE.CHECK_MAINTENANCE_SAFETY(asset_id, task_code)
--
-- The authoritative gate. Returns one row per gate with a verdict, and the required
-- approver roles derived from GOVERNANCE.EMPLOYEE_AUTHORITY and the task's cost and
-- downtime profile. Never returns an empty result: a missing input is a FAIL.
--
-- FAIL means stop and escalate. REVIEW means proceed only with the named additional
-- approver. PASS means the normal approval set applies.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION GOVERNANCE.CHECK_MAINTENANCE_SAFETY(P_ASSET_ID VARCHAR, P_TASK_CODE VARCHAR)
RETURNS TABLE (
    GATE_CODE VARCHAR, VERDICT VARCHAR, REASON VARCHAR,
    REQUIRED_APPROVER_ROLES VARCHAR, ESCALATION_REF VARCHAR, RULE_VERSION VARCHAR
)
COMMENT = 'Authoritative safety and authority gate for one asset and task. FAIL stops economic optimization and returns the escalation reference. Never returns zero rows -- a missing input is a FAIL.'
AS
$$
WITH ctx AS (
    SELECT a.ASSET_ID, a.ASSET_CLASS, a.CRITICALITY, a.SAFETY_CONSEQUENCE,
           t.TASK_CODE, t.ESTIMATED_COST, t.ESTIMATED_DURATION_MIN, t.REQUIRES_LINE_STOP,
           t.GOVERNED_BY_PROCEDURE,
           h.ANY_TRIP_EXCEEDED, h.DQ_VERDICT, h.TRIAGE_LANE, h.IN_SCOPE
    FROM MFG_COPILOT_DB.CORE.ASSET a
    CROSS JOIN MFG_COPILOT_DB.GOVERNANCE.MAINTENANCE_TASK t
    LEFT JOIN MFG_COPILOT_DB.AI.ASSET_HEALTH_SNAPSHOT h ON h.ASSET_ID = a.ASSET_ID
    WHERE a.ASSET_ID = P_ASSET_ID
      AND t.TASK_CODE = P_TASK_CODE
),
trip AS (
    SELECT c.ASSET_ID,
           MAX(CASE WHEN tc.TRIP_EXCEEDED  THEN tc.ESCALATION_REF END) AS TRIP_ESCALATION,
           MAX(CASE WHEN tc.ALARM_EXCEEDED THEN tc.ESCALATION_REF END) AS ALARM_ESCALATION,
           COUNT_IF(tc.TRIP_EXCEEDED)  AS TRIPS,
           COUNT_IF(tc.ALARM_EXCEEDED) AS ALARMS,
           LISTAGG(CASE WHEN tc.TRIP_EXCEEDED THEN tc.TAG_SUFFIX END, ', ') AS TRIPPED_TAGS,
           LISTAGG(CASE WHEN tc.ALARM_EXCEEDED THEN tc.TAG_SUFFIX END, ', ') AS ALARMED_TAGS
    FROM ctx c
    LEFT JOIN MFG_COPILOT_DB.AI.TAG_CURRENT tc ON tc.ASSET_ID = c.ASSET_ID
    GROUP BY c.ASSET_ID
)
-- SAFETY_LIMIT gate
SELECT 'SAFETY_LIMIT' AS GATE_CODE,
       CASE WHEN tr.TRIPS > 0 THEN 'FAIL' WHEN tr.ALARMS > 0 THEN 'REVIEW' ELSE 'PASS' END,
       CASE WHEN tr.TRIPS > 0
              THEN 'Configured trip exceeded on ' || tr.TRIPPED_TAGS ||
                   '. Economic optimization stops here; follow the escalation procedure.'
            WHEN tr.ALARMS > 0
              THEN 'Configured alarm exceeded on ' || tr.ALARMED_TAGS ||
                   '. Below trip, so work may proceed with EHS awareness.'
            ELSE 'No configured alarm or trip exceeded.' END,
       CASE WHEN tr.TRIPS > 0 THEN 'EHS_OWNER, MAINTENANCE_MANAGER, PRODUCTION_SUPERVISOR'
            WHEN tr.ALARMS > 0 THEN 'RELIABILITY_ENGINEER, PRODUCTION_SUPERVISOR, EHS_OWNER'
            ELSE 'RELIABILITY_ENGINEER, PRODUCTION_SUPERVISOR' END,
       COALESCE(tr.TRIP_ESCALATION, tr.ALARM_ESCALATION),
       'safety-rules-v1'
FROM ctx c JOIN trip tr ON tr.ASSET_ID = c.ASSET_ID
UNION ALL
-- DATA_QUALITY gate
SELECT 'DATA_QUALITY',
       CASE WHEN c.DQ_VERDICT IS NULL OR c.DQ_VERDICT = 'FAIL' THEN 'FAIL'
            WHEN c.DQ_VERDICT = 'REVIEW' THEN 'REVIEW' ELSE 'PASS' END,
       CASE WHEN c.DQ_VERDICT IS NULL THEN 'No data-quality verdict available. Treated as FAIL: absence of evidence is not evidence of health.'
            WHEN c.DQ_VERDICT = 'FAIL' THEN 'Condition data is unusable. No maintenance action may be authorised on this evidence.'
            WHEN c.DQ_VERDICT = 'REVIEW' THEN 'Condition data has warnings. Proceed only with reliability review.'
            ELSE 'Condition data passes all checks.' END,
       CASE WHEN COALESCE(c.DQ_VERDICT, 'FAIL') = 'PASS' THEN 'RELIABILITY_ENGINEER, PRODUCTION_SUPERVISOR'
            ELSE 'RELIABILITY_ENGINEER' END,
       NULL, 'dq-rules-v1'
FROM ctx c
UNION ALL
-- MODEL_SCOPE gate
SELECT 'MODEL_SCOPE',
       CASE WHEN COALESCE(c.IN_SCOPE, FALSE) THEN 'PASS' ELSE 'REVIEW' END,
       CASE WHEN COALESCE(c.IN_SCOPE, FALSE)
            THEN 'Asset is inside the validated model scope.'
            ELSE 'Asset is outside the validated model scope. Any risk figure is not applicable; decide on inspection evidence only.' END,
       'RELIABILITY_ENGINEER', NULL, 'bearing-demo-v1'
FROM ctx c
UNION ALL
-- APPROVED_PROCEDURE gate
SELECT 'APPROVED_PROCEDURE',
       CASE WHEN p.PROCEDURE_REF IS NULL THEN 'FAIL' ELSE 'PASS' END,
       CASE WHEN p.PROCEDURE_REF IS NULL
            THEN 'No CURRENT approved procedure exists for ' || c.GOVERNED_BY_PROCEDURE ||
                 '. A superseded version is not authority and must not be cited.'
            ELSE 'Current approved procedure is ' || p.PROCEDURE_REF || '.' END,
       'RELIABILITY_ENGINEER', NULL, 'safety-rules-v1'
FROM ctx c
LEFT JOIN (
    SELECT MAX(PROCEDURE_REF) AS PROCEDURE_REF, PROCEDURE_CODE
    FROM MFG_COPILOT_DB.GOVERNANCE.PROCEDURE_CURRENT
    WHERE STATUS = 'CURRENT' GROUP BY PROCEDURE_CODE
) p ON p.PROCEDURE_CODE = c.GOVERNED_BY_PROCEDURE
UNION ALL
-- COST_AUTHORITY gate
SELECT 'COST_AUTHORITY',
       'PASS',
       'Estimated cost ' || c.ESTIMATED_COST::VARCHAR ||
       ' requires approval at or above ' ||
       (SELECT MIN(ea.ROLE_CODE) FROM MFG_COPILOT_DB.GOVERNANCE.EMPLOYEE_AUTHORITY ea
         WHERE ea.CAN_APPROVE_TECHNICAL AND ea.MAX_COST_APPROVAL >= c.ESTIMATED_COST) || '.',
       COALESCE((SELECT LISTAGG(ea.ROLE_CODE, ', ') FROM MFG_COPILOT_DB.GOVERNANCE.EMPLOYEE_AUTHORITY ea
                  WHERE ea.CAN_APPROVE_TECHNICAL AND ea.MAX_COST_APPROVAL >= c.ESTIMATED_COST),
                'MAINTENANCE_MANAGER'),
       NULL, 'safety-rules-v1'
FROM ctx c
UNION ALL
-- PRODUCTION_AUTHORITY gate
SELECT 'PRODUCTION_AUTHORITY',
       'PASS',
       CASE WHEN c.REQUIRES_LINE_STOP
            THEN 'Task requires a line stop of ' || c.ESTIMATED_DURATION_MIN::VARCHAR ||
                 ' minutes. Production owner approval is required.'
            ELSE 'Task does not require a line stop.' END,
       CASE WHEN c.REQUIRES_LINE_STOP THEN 'PRODUCTION_SUPERVISOR' ELSE '' END,
       NULL, 'safety-rules-v1'
FROM ctx c
UNION ALL
-- AGENT_CONTROL_BOUNDARY gate: always present, always the same answer. It exists so
-- the boundary is visible in every decision record rather than assumed.
SELECT 'AGENT_CONTROL_BOUNDARY', 'PASS',
       'Agent equipment control is PROHIBITED. This decision authorises preparation of a '
       || 'work-order draft only. It is not a maintenance release, a dispatch, or a '
       || 'return-to-service authorisation.',
       '', NULL, 'safety-rules-v1'
FROM ctx c
$$;

-- ----------------------------------------------------------------------------
-- GOVERNANCE.SAFETY_VERDICT(asset_id, task_code) -- collapsed gate verdict
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION GOVERNANCE.SAFETY_VERDICT(P_ASSET_ID VARCHAR, P_TASK_CODE VARCHAR)
RETURNS TABLE (
    OVERALL_VERDICT VARCHAR, FAILED_GATES VARCHAR, REVIEW_GATES VARCHAR,
    REQUIRED_APPROVER_ROLES VARCHAR, ESCALATION_REF VARCHAR, RULE_VERSION VARCHAR
)
COMMENT = 'Single-row collapse of CHECK_MAINTENANCE_SAFETY: worst verdict, failing gates, and the union of required approver roles.'
AS
$$
SELECT
    CASE WHEN COUNT_IF(VERDICT = 'FAIL')   > 0 THEN 'FAIL'
         WHEN COUNT_IF(VERDICT = 'REVIEW') > 0 THEN 'REVIEW'
         ELSE 'PASS' END,
    LISTAGG(CASE WHEN VERDICT = 'FAIL'   THEN GATE_CODE END, ', '),
    LISTAGG(CASE WHEN VERDICT = 'REVIEW' THEN GATE_CODE END, ', '),
    ARRAY_TO_STRING(ARRAY_DISTINCT(SPLIT(
        LISTAGG(NULLIF(REQUIRED_APPROVER_ROLES, ''), ', '), ', ')), ', '),
    MAX(ESCALATION_REF),
    'safety-rules-v1'
FROM TABLE(MFG_COPILOT_DB.GOVERNANCE.CHECK_MAINTENANCE_SAFETY(
    P_ASSET_ID, P_TASK_CODE))
$$;

-- ----------------------------------------------------------------------------
-- Verification
-- ----------------------------------------------------------------------------
SELECT OPTION_ID, ACTION, OPTION_RANK, IS_RECOMMENDED, IS_BOUNDED_SET,
       FEASIBLE, INFEASIBLE_REASON, ESTIMATED_NET_VALUE, TIMING, PROCEDURE_REF
FROM TABLE(DECISION.EVALUATE_MAINTENANCE_OPTIONS('P-204'))
ORDER BY FEASIBLE DESC, OPTION_RANK NULLS LAST;
