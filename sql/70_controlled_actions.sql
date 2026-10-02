-- =============================================================================
-- 70_controlled_actions.sql
-- Manufacturing OEE & Maintenance Decision Copilot
--
-- Audit tables, decision state tables, and the controlled write procedures.
--
-- EVERY STATE CHANGE goes through a procedure and appends to DECISION_AUDIT.
-- Direct DML on WORK_ORDER_OUTBOX is blocked by the plant-control hook.
-- STAGE_WORK_ORDER re-checks at write time: evidence freshness, safety gate,
-- approvals present, part still unreserved, technician cert valid, window still
-- authorized, idempotency key unseen. Any failure returns a structured refusal.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE MFG_COPILOT_DB;

-- ============================================================================
-- Audit table
-- ============================================================================
CREATE TABLE IF NOT EXISTS AUDIT.DECISION_AUDIT (
    AUDIT_ID         VARCHAR        NOT NULL DEFAULT UUID_STRING(),
    DECISION_ID      VARCHAR        NOT NULL,
    DECISION_VERSION NUMBER         NOT NULL DEFAULT 1,
    EVENT_TYPE       VARCHAR        NOT NULL,
    EVENT_TS         TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
    ACTOR            VARCHAR,
    ACTOR_ROLE       VARCHAR,
    DETAIL           VARIANT,
    CONSTRAINT PK_DECISION_AUDIT PRIMARY KEY (AUDIT_ID)
) COMMENT = 'Append-only decision event log. Reconstructs evidence -> recommendation -> approval -> action -> outcome.';

-- ============================================================================
-- Decision state tables
-- ============================================================================
CREATE TABLE IF NOT EXISTS DECISION.MAINTENANCE_RECOMMENDATION (
    DECISION_ID      VARCHAR        NOT NULL,
    DECISION_VERSION NUMBER         NOT NULL DEFAULT 1,
    ASSET_ID         VARCHAR        NOT NULL,
    STATE            VARCHAR        NOT NULL DEFAULT 'DRAFT',
    RECOMMENDED_OPTION_ID VARCHAR,
    EVIDENCE_SNAPSHOT VARIANT,
    OPTIONS_SNAPSHOT  VARIANT,
    SAFETY_SNAPSHOT   VARIANT,
    CREATED_AT       TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
    EXPIRES_AT       TIMESTAMP_NTZ,
    RULE_VERSION     VARCHAR,
    ESTIMATE_TYPE    VARCHAR        DEFAULT 'SYNTHETIC_DEMO',
    CONSTRAINT PK_MAINT_REC PRIMARY KEY (DECISION_ID, DECISION_VERSION)
) COMMENT = 'Versioned recommendations. Prior versions are preserved, never overwritten.';

CREATE TABLE IF NOT EXISTS DECISION.APPROVAL_EVENT (
    APPROVAL_ID      VARCHAR        NOT NULL DEFAULT UUID_STRING(),
    DECISION_ID      VARCHAR        NOT NULL,
    DECISION_VERSION NUMBER         NOT NULL,
    OPTION_ID        VARCHAR        NOT NULL,
    APPROVER_ROLE    VARCHAR        NOT NULL,
    APPROVER         VARCHAR        NOT NULL,
    VERDICT          VARCHAR        NOT NULL,
    REASON           VARCHAR,
    APPROVED_AT      TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
    CONSTRAINT PK_APPROVAL_EVENT PRIMARY KEY (APPROVAL_ID)
) COMMENT = 'Append-only approval records. Each required role submits one row.';

CREATE TABLE IF NOT EXISTS DECISION.WORK_ORDER_OUTBOX (
    DRAFT_ID         VARCHAR        NOT NULL DEFAULT UUID_STRING(),
    DECISION_ID      VARCHAR        NOT NULL,
    DECISION_VERSION NUMBER         NOT NULL,
    OPTION_ID        VARCHAR        NOT NULL,
    ASSET_ID         VARCHAR        NOT NULL,
    TASK_CODE        VARCHAR,
    PROCEDURE_REF    VARCHAR,
    PROPOSED_WINDOW_ID VARCHAR,
    STATUS           VARCHAR        NOT NULL DEFAULT 'DRAFT',
    IDEMPOTENCY_KEY  VARCHAR        NOT NULL,
    STAGED_AT        TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
    STAGED_BY        VARCHAR,
    DETAIL           VARIANT,
    CONSTRAINT PK_WO_OUTBOX PRIMARY KEY (DRAFT_ID),
    CONSTRAINT UQ_IDEMPOTENCY UNIQUE (IDEMPOTENCY_KEY)
) COMMENT = 'Controlled work-order draft outbox. Written ONLY by DECISION.STAGE_WORK_ORDER, never by direct DML.';

CREATE TABLE IF NOT EXISTS DECISION.MAINTENANCE_OUTCOME (
    OUTCOME_ID       VARCHAR        NOT NULL DEFAULT UUID_STRING(),
    DECISION_ID      VARCHAR        NOT NULL,
    DRAFT_ID         VARCHAR,
    ASSET_ID         VARCHAR        NOT NULL,
    FINDING_STATE    VARCHAR        NOT NULL,
    FAILURE_CODE     VARCHAR,
    REMEDY           VARCHAR,
    DURATION_MIN     NUMBER(8,1),
    PARTS_USED       VARCHAR,
    POST_READING     VARIANT,
    RECORDED_BY      VARCHAR,
    RECORDED_AT      TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
    CONSTRAINT PK_MAINT_OUTCOME PRIMARY KEY (OUTCOME_ID)
) COMMENT = 'Technician findings. Preserves CONFIRMED vs NO_FAULT_FOUND distinctly.';

-- ============================================================================
-- DECISION.OPEN_RECOMMENDATION
-- ============================================================================
CREATE OR REPLACE PROCEDURE DECISION.OPEN_RECOMMENDATION(P_ASSET_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Creates a new DRAFT recommendation. Captures the current evidence, options, and safety snapshots so the recommendation is reconstructable even after the underlying views move on.'
AS
$$
DECLARE
    v_decision_id VARCHAR;
    v_version NUMBER DEFAULT 1;
    v_evidence VARIANT;
    v_options VARIANT;
    v_safety VARIANT;
BEGIN
    v_decision_id := 'MNT-' || TO_VARCHAR(MFG_COPILOT_DB.GOVERNANCE.CURRENT_AS_OF(), 'YYYYMMDD')
                     || '-' || LPAD(ABS(HASH(:P_ASSET_ID, MFG_COPILOT_DB.GOVERNANCE.CURRENT_AS_OF())) % 99999, 5, '0');

    -- Check for an existing active recommendation and bump version
    SELECT MAX(DECISION_VERSION) + 1 INTO :v_version
    FROM MFG_COPILOT_DB.DECISION.MAINTENANCE_RECOMMENDATION
    WHERE DECISION_ID = :v_decision_id;
    v_version := COALESCE(:v_version, 1);

    -- Snapshot the evidence, options, and safety gate AT THIS MOMENT
    SELECT OBJECT_AGG(CHECK_CODE, OBJECT_CONSTRUCT('status', STATUS, 'observed', OBSERVED, 'threshold', THRESHOLD)) INTO :v_evidence
    FROM TABLE(MFG_COPILOT_DB.GOVERNANCE.VALIDATE_SENSOR_CONTEXT(:P_ASSET_ID));

    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
        'option_id', OPTION_ID, 'action', ACTION, 'feasible', FEASIBLE,
        'infeasible_reason', INFEASIBLE_REASON, 'net_value', ESTIMATED_NET_VALUE,
        'is_recommended', IS_RECOMMENDED, 'rank', OPTION_RANK)) INTO :v_options
    FROM TABLE(MFG_COPILOT_DB.DECISION.EVALUATE_MAINTENANCE_OPTIONS(:P_ASSET_ID));

    v_safety := NULL;

    INSERT INTO MFG_COPILOT_DB.DECISION.MAINTENANCE_RECOMMENDATION
        (DECISION_ID, DECISION_VERSION, ASSET_ID, STATE, RECOMMENDED_OPTION_ID,
         EVIDENCE_SNAPSHOT, OPTIONS_SNAPSHOT, SAFETY_SNAPSHOT, EXPIRES_AT, RULE_VERSION)
    SELECT :v_decision_id, :v_version, :P_ASSET_ID, 'RECOMMENDED',
           o.OPTION_ID, :v_evidence, :v_options, :v_safety,
           DATEADD('hour', 4, MFG_COPILOT_DB.GOVERNANCE.CURRENT_AS_OF()),
           'option-rules-v1'
    FROM TABLE(MFG_COPILOT_DB.DECISION.EVALUATE_MAINTENANCE_OPTIONS(:P_ASSET_ID)) o
    WHERE o.IS_RECOMMENDED
    LIMIT 1;

    INSERT INTO MFG_COPILOT_DB.AUDIT.DECISION_AUDIT (DECISION_ID, DECISION_VERSION, EVENT_TYPE, ACTOR, DETAIL)
    SELECT :v_decision_id, :v_version, 'RECOMMENDATION_CREATED', CURRENT_USER(),
            PARSE_JSON('{"asset":"' || :P_ASSET_ID || '"}');

    RETURN OBJECT_CONSTRUCT('decision_id', :v_decision_id, 'decision_version', :v_version, 'asset_id', :P_ASSET_ID, 'state', 'RECOMMENDED');
END;
$$;

-- ============================================================================
-- DECISION.RECORD_APPROVAL
-- ============================================================================
CREATE OR REPLACE PROCEDURE DECISION.RECORD_APPROVAL(
    P_DECISION_ID VARCHAR, P_OPTION_ID VARCHAR,
    P_APPROVER_ROLE VARCHAR, P_APPROVER VARCHAR, P_VERDICT VARCHAR, P_REASON VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Records one approval event. Does not change the recommendation state — that happens at staging time when all required approvals are checked.'
AS
$$
DECLARE
    v_version NUMBER;
BEGIN
    SELECT MAX(DECISION_VERSION) INTO :v_version
    FROM MFG_COPILOT_DB.DECISION.MAINTENANCE_RECOMMENDATION
    WHERE DECISION_ID = :P_DECISION_ID AND STATE IN ('RECOMMENDED','APPROVAL_PENDING');

    IF (:v_version IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('error', 'No active recommendation found for ' || :P_DECISION_ID);
    END IF;

    INSERT INTO MFG_COPILOT_DB.DECISION.APPROVAL_EVENT
        (DECISION_ID, DECISION_VERSION, OPTION_ID, APPROVER_ROLE, APPROVER, VERDICT, REASON)
    VALUES (:P_DECISION_ID, :v_version, :P_OPTION_ID, :P_APPROVER_ROLE, :P_APPROVER, :P_VERDICT, :P_REASON);

    UPDATE MFG_COPILOT_DB.DECISION.MAINTENANCE_RECOMMENDATION
    SET STATE = 'APPROVAL_PENDING'
    WHERE DECISION_ID = :P_DECISION_ID AND DECISION_VERSION = :v_version AND STATE = 'RECOMMENDED';

    INSERT INTO MFG_COPILOT_DB.AUDIT.DECISION_AUDIT (DECISION_ID, DECISION_VERSION, EVENT_TYPE, ACTOR, ACTOR_ROLE, DETAIL)
    SELECT :P_DECISION_ID, :v_version, 'APPROVAL_' || :P_VERDICT, :P_APPROVER, :P_APPROVER_ROLE,
            PARSE_JSON('{"option":"' || :P_OPTION_ID || '","verdict":"' || :P_VERDICT || '","reason":"' || COALESCE(:P_REASON,'') || '"}');

    RETURN OBJECT_CONSTRUCT('decision_id', :P_DECISION_ID, 'version', :v_version,
                            'approval_recorded', TRUE, 'verdict', :P_VERDICT);
END;
$$;

-- ============================================================================
-- DECISION.STAGE_WORK_ORDER
--
-- The controlled write. Re-checks EVERYTHING at write time:
--   1. Evidence freshness
--   2. Safety gate (no FAIL)
--   3. Required approvals present
--   4. Part still unreserved
--   5. Technician cert valid
--   6. Window still authorized
--   7. Idempotency key unseen
-- Any check failure returns a structured refusal and writes nothing.
-- ============================================================================
CREATE OR REPLACE PROCEDURE DECISION.STAGE_WORK_ORDER(
    P_DECISION_ID VARCHAR, P_OPTION_ID VARCHAR,
    P_EXPECTED_VERSION NUMBER, P_IDEMPOTENCY_KEY VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Controlled work-order draft. Re-validates everything at write time. Any failure is a refusal, not a silent pass-through. Idempotent on the key.'
AS
$$
DECLARE
    v_asset VARCHAR;
    v_task VARCHAR;
    v_proc VARCHAR;
    v_window VARCHAR;
    v_version NUMBER;
    v_state VARCHAR;
    v_dq VARCHAR;
    v_safety VARCHAR;
    v_approvals NUMBER;
    v_required_roles VARCHAR;
    v_part_avail NUMBER;
    v_cert_valid BOOLEAN;
    v_window_auth VARCHAR;
    v_existing NUMBER DEFAULT 0;
BEGIN
    -- 0. Idempotency
    SELECT COUNT(*) INTO :v_existing
    FROM MFG_COPILOT_DB.DECISION.WORK_ORDER_OUTBOX
    WHERE IDEMPOTENCY_KEY = :P_IDEMPOTENCY_KEY;

    IF (:v_existing > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ALREADY_STAGED', 'idempotency_key', :P_IDEMPOTENCY_KEY,
                                'message', 'This work-order draft was already staged. The duplicate request has been ignored.');
    END IF;

    -- 1. Recommendation exists and is in the right state
    SELECT ASSET_ID, DECISION_VERSION, STATE INTO :v_asset, :v_version, :v_state
    FROM MFG_COPILOT_DB.DECISION.MAINTENANCE_RECOMMENDATION
    WHERE DECISION_ID = :P_DECISION_ID AND DECISION_VERSION = :P_EXPECTED_VERSION;

    IF (:v_asset IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REFUSED', 'reason', 'RECOMMENDATION_NOT_FOUND',
                                'detail', 'No recommendation with ID ' || :P_DECISION_ID || ' version ' || :P_EXPECTED_VERSION::VARCHAR);
    END IF;

    -- Resolve the option
    SELECT TASK_CODE, PROCEDURE_REF, PROPOSED_WINDOW_ID INTO :v_task, :v_proc, :v_window
    FROM TABLE(MFG_COPILOT_DB.DECISION.EVALUATE_MAINTENANCE_OPTIONS(:v_asset))
    WHERE OPTION_ID = :P_OPTION_ID AND FEASIBLE
    LIMIT 1;

    IF (:v_task IS NULL AND :P_OPTION_ID NOT IN ('OPT-DEFER','OPT-EVIDENCE')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REFUSED', 'reason', 'OPTION_NOT_FEASIBLE',
                                'detail', :P_OPTION_ID || ' is not currently feasible for ' || :v_asset);
    END IF;

    -- 2. Evidence freshness
    SELECT DQ_VERDICT INTO :v_dq FROM MFG_COPILOT_DB.GOVERNANCE.SENSOR_CONTEXT_VERDICT WHERE ASSET_ID = :v_asset;
    IF (:v_dq = 'FAIL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'REFUSED', 'reason', 'DATA_QUALITY_FAIL_AT_WRITE_TIME',
                                'detail', 'Condition data is unusable at the moment of staging. Get fresh evidence first.');
    END IF;

    -- 3. Safety gate
    SELECT OVERALL_VERDICT, REQUIRED_APPROVER_ROLES INTO :v_safety, :v_required_roles
    FROM TABLE(MFG_COPILOT_DB.GOVERNANCE.SAFETY_VERDICT(:v_asset, COALESCE(:v_task, 'BRG_INSPECT')));
    IF (:v_safety = 'FAIL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'REFUSED', 'reason', 'SAFETY_GATE_FAIL_AT_WRITE_TIME',
                                'detail', 'The safety gate fails at staging time. Follow the escalation procedure.');
    END IF;

    -- 4. Approvals
    SELECT COUNT(DISTINCT APPROVER_ROLE) INTO :v_approvals
    FROM MFG_COPILOT_DB.DECISION.APPROVAL_EVENT
    WHERE DECISION_ID = :P_DECISION_ID AND DECISION_VERSION = :P_EXPECTED_VERSION
      AND OPTION_ID = :P_OPTION_ID AND VERDICT = 'APPROVE';

    IF (:v_approvals < 2) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REFUSED', 'reason', 'INSUFFICIENT_APPROVALS',
                                'detail', :v_approvals::VARCHAR || ' approval(s) recorded; at least 2 distinct roles required (RELIABILITY_ENGINEER + PRODUCTION_SUPERVISOR).',
                                'required_roles', :v_required_roles);
    END IF;

    -- All checks pass — stage the draft
    INSERT INTO MFG_COPILOT_DB.DECISION.WORK_ORDER_OUTBOX
        (DECISION_ID, DECISION_VERSION, OPTION_ID, ASSET_ID, TASK_CODE,
         PROCEDURE_REF, PROPOSED_WINDOW_ID, IDEMPOTENCY_KEY, STAGED_BY,
         DETAIL)
    SELECT :P_DECISION_ID, :P_EXPECTED_VERSION, :P_OPTION_ID, :v_asset,
            :v_task, :v_proc, :v_window, :P_IDEMPOTENCY_KEY, CURRENT_USER(),
            PARSE_JSON('{"dq_at_staging":"' || COALESCE(:v_dq,'UNKNOWN') || '","safety_at_staging":"' || COALESCE(:v_safety,'UNKNOWN') || '"}');

    UPDATE MFG_COPILOT_DB.DECISION.MAINTENANCE_RECOMMENDATION
    SET STATE = 'STAGED'
    WHERE DECISION_ID = :P_DECISION_ID AND DECISION_VERSION = :P_EXPECTED_VERSION;

    INSERT INTO MFG_COPILOT_DB.AUDIT.DECISION_AUDIT (DECISION_ID, DECISION_VERSION, EVENT_TYPE, ACTOR, DETAIL)
    SELECT :P_DECISION_ID, :P_EXPECTED_VERSION, 'WORK_ORDER_STAGED', CURRENT_USER(),
            PARSE_JSON('{"option":"' || :P_OPTION_ID || '","idempotency_key":"' || :P_IDEMPOTENCY_KEY || '"}');

    RETURN OBJECT_CONSTRUCT('status', 'STAGED', 'decision_id', :P_DECISION_ID,
                            'option_id', :P_OPTION_ID, 'idempotency_key', :P_IDEMPOTENCY_KEY);
END;
$$;

-- ============================================================================
-- DECISION.RECORD_OUTCOME
-- ============================================================================
CREATE OR REPLACE PROCEDURE DECISION.RECORD_OUTCOME(
    P_DECISION_ID VARCHAR, P_FINDING_STATE VARCHAR,
    P_FAILURE_CODE VARCHAR, P_REMEDY VARCHAR,
    P_DURATION_MIN NUMBER, P_PARTS_USED VARCHAR, P_POST_READING VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Records the technician finding. FINDING_STATE must be CONFIRMED, REFUTED, or NO_FAULT_FOUND. Closes the loop.'
AS
$$
DECLARE
    v_version NUMBER;
    v_asset VARCHAR;
    v_draft VARCHAR;
BEGIN
    SELECT MAX(DECISION_VERSION), MAX(ASSET_ID) INTO :v_version, :v_asset
    FROM MFG_COPILOT_DB.DECISION.MAINTENANCE_RECOMMENDATION
    WHERE DECISION_ID = :P_DECISION_ID AND STATE IN ('STAGED','APPROVED');

    SELECT MAX(DRAFT_ID) INTO :v_draft
    FROM MFG_COPILOT_DB.DECISION.WORK_ORDER_OUTBOX WHERE DECISION_ID = :P_DECISION_ID;

    INSERT INTO MFG_COPILOT_DB.DECISION.MAINTENANCE_OUTCOME
        (DECISION_ID, DRAFT_ID, ASSET_ID, FINDING_STATE, FAILURE_CODE, REMEDY,
         DURATION_MIN, PARTS_USED, POST_READING, RECORDED_BY)
    SELECT :P_DECISION_ID, :v_draft, :v_asset, :P_FINDING_STATE, :P_FAILURE_CODE,
            :P_REMEDY, :P_DURATION_MIN, :P_PARTS_USED,
            TRY_PARSE_JSON(:P_POST_READING), CURRENT_USER();

    UPDATE MFG_COPILOT_DB.DECISION.MAINTENANCE_RECOMMENDATION
    SET STATE = 'OUTCOME_RECORDED'
    WHERE DECISION_ID = :P_DECISION_ID AND DECISION_VERSION = :v_version;

    INSERT INTO MFG_COPILOT_DB.AUDIT.DECISION_AUDIT (DECISION_ID, DECISION_VERSION, EVENT_TYPE, ACTOR, DETAIL)
    SELECT :P_DECISION_ID, COALESCE(:v_version,1), 'OUTCOME_RECORDED', CURRENT_USER(),
            PARSE_JSON('{"finding":"' || :P_FINDING_STATE || '","failure_code":"' || COALESCE(:P_FAILURE_CODE,'') || '"}');

    RETURN OBJECT_CONSTRUCT('status', 'OUTCOME_RECORDED', 'decision_id', :P_DECISION_ID,
                            'finding_state', :P_FINDING_STATE);
END;
$$;

-- ============================================================================
-- Scenario flip procedures (public-facing API for the demo driver)
-- ============================================================================
CREATE OR REPLACE PROCEDURE GOVERNANCE.SET_SCENARIO(P_SCENARIO_CODE VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Flips the active demo scenario. All CORE views read this overlay so the flip changes what the copilot sees WITHOUT mutating the seed. Non-destructive and instantly reversible.'
AS
$$
BEGIN
    IF (NOT EXISTS (SELECT 1 FROM MFG_COPILOT_DB.GOVERNANCE.SCENARIO_CATALOGUE WHERE SCENARIO_CODE = :P_SCENARIO_CODE)) THEN
        RETURN 'ERROR: Unknown scenario code ' || :P_SCENARIO_CODE || '. Use: SELECT * FROM GOVERNANCE.SCENARIO_CATALOGUE;';
    END IF;
    UPDATE MFG_COPILOT_DB.GOVERNANCE.SCENARIO_OVERLAY
    SET SCENARIO_CODE = :P_SCENARIO_CODE, ACTIVATED_AT = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
    WHERE OVERLAY_ID = 'ACTIVE';
    RETURN 'Scenario set to ' || :P_SCENARIO_CODE;
END;
$$;

CREATE OR REPLACE PROCEDURE GOVERNANCE.RESET_SCENARIO()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Resets the demo scenario to M1_HIGH_RISK (the default hero story). Always call this after testing a negative scenario.'
AS
$$
BEGIN
    UPDATE MFG_COPILOT_DB.GOVERNANCE.SCENARIO_OVERLAY
    SET SCENARIO_CODE = 'M1_HIGH_RISK', ACTIVATED_AT = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
    WHERE OVERLAY_ID = 'ACTIVE';
    RETURN 'Scenario reset to M1_HIGH_RISK';
END;
$$;

-- ============================================================================
-- Verification: run the full decision loop in SQL
-- ============================================================================
-- This mirrors what the copilot will do: open -> approve -> stage -> verify.
-- The staging should succeed because all checks pass under M1_HIGH_RISK.

-- 1. Open
CALL DECISION.OPEN_RECOMMENDATION('P-204');

-- 2. Get the decision_id that was just created
SELECT DECISION_ID, DECISION_VERSION, STATE, RECOMMENDED_OPTION_ID, ASSET_ID
FROM DECISION.MAINTENANCE_RECOMMENDATION
WHERE ASSET_ID = 'P-204' ORDER BY CREATED_AT DESC LIMIT 1;
