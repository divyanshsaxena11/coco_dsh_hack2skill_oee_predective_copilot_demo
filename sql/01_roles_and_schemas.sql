-- =============================================================================
-- 01_roles_and_schemas.sql
-- Manufacturing OEE & Maintenance Decision Copilot
--
-- Creates MFG_COPILOT_DB, its nine schemas, the persona roles from the blueprint's
-- §3.3, and the deploy log used for idempotent redeployment.
--
-- THE SCHEMA LIST IS CLOSED ON PURPOSE. There is no schema for equipment control,
-- setpoints, command queues, dispatch, or return-to-service. That absence is the
-- strongest of the three safety boundaries: you cannot call what does not exist.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;

CREATE DATABASE IF NOT EXISTS MFG_COPILOT_DB
  COMMENT = 'Manufacturing OEE & Maintenance Decision Copilot. All data synthetic.';

USE DATABASE MFG_COPILOT_DB;

-- ----------------------------------------------------------------------------
-- Schemas
-- ----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS RAW        COMMENT = 'Source-aligned data, minimally changed.';
CREATE SCHEMA IF NOT EXISTS CORE       COMMENT = 'Canonical entities, normalized units, production and maintenance history.';
CREATE SCHEMA IF NOT EXISTS CONTEXT    COMMENT = 'Ontology nodes/edges and compact decision views.';
CREATE SCHEMA IF NOT EXISTS AI         COMMENT = 'Condition features and precomputed model outputs. All synthetic.';
CREATE SCHEMA IF NOT EXISTS DECISION   COMMENT = 'Options, recommendations, approvals, staged work, outcomes.';
CREATE SCHEMA IF NOT EXISTS GOVERNANCE COMMENT = 'Safety limits, procedures, authority, compatibility, rule versions, demo clock.';
CREATE SCHEMA IF NOT EXISTS SEMANTIC   COMMENT = 'Semantic view and Cortex Search service.';
CREATE SCHEMA IF NOT EXISTS AUDIT      COMMENT = 'Append-only decision, tool-call, and deploy logs; KPI views.';
CREATE SCHEMA IF NOT EXISTS APP        COMMENT = 'Streamlit stage and application object.';

DROP SCHEMA IF EXISTS PUBLIC;

-- ----------------------------------------------------------------------------
-- Persona roles
-- These mirror the blueprint's personas so the RBAC story is real rather than
-- illustrative. Grants are applied in 85_governance_rbac.sql once objects exist.
-- ----------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS MFG_COPILOT_ADMIN        COMMENT = 'Deploys and owns the copilot objects.';
CREATE ROLE IF NOT EXISTS MFG_RELIABILITY_ENGINEER COMMENT = 'Validates degradation, selects the technical response.';
CREATE ROLE IF NOT EXISTS MFG_MAINTENANCE_PLANNER  COMMENT = 'Builds the executable plan.';
CREATE ROLE IF NOT EXISTS MFG_PRODUCTION_SUPERVISOR COMMENT = 'Protects output; approves production windows.';
CREATE ROLE IF NOT EXISTS MFG_TECHNICIAN           COMMENT = 'Executes approved work, records findings.';
CREATE ROLE IF NOT EXISTS MFG_EHS_OWNER            COMMENT = 'Enforces safe work; required for safety-critical work.';

GRANT ROLE MFG_COPILOT_ADMIN         TO ROLE ACCOUNTADMIN;
GRANT ROLE MFG_RELIABILITY_ENGINEER  TO ROLE MFG_COPILOT_ADMIN;
GRANT ROLE MFG_MAINTENANCE_PLANNER   TO ROLE MFG_COPILOT_ADMIN;
GRANT ROLE MFG_PRODUCTION_SUPERVISOR TO ROLE MFG_COPILOT_ADMIN;
GRANT ROLE MFG_TECHNICIAN            TO ROLE MFG_COPILOT_ADMIN;
GRANT ROLE MFG_EHS_OWNER             TO ROLE MFG_COPILOT_ADMIN;

GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE MFG_COPILOT_ADMIN;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE MFG_RELIABILITY_ENGINEER;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE MFG_MAINTENANCE_PLANNER;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE MFG_PRODUCTION_SUPERVISOR;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE MFG_TECHNICIAN;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE MFG_EHS_OWNER;

-- ----------------------------------------------------------------------------
-- Deploy log — lets mfg-setup skip completed steps on redeploy
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS AUDIT.DEPLOY_LOG (
    DEPLOY_STEP     VARCHAR        NOT NULL,
    STATUS          VARCHAR        NOT NULL,   -- RUNNING | COMPLETE | FAILED
    ROWS_AFFECTED   NUMBER,
    DETAIL          VARCHAR,
    STARTED_AT      TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
    FINISHED_AT     TIMESTAMP_NTZ,
    CONSTRAINT PK_DEPLOY_LOG PRIMARY KEY (DEPLOY_STEP)
)
COMMENT = 'One row per deploy step. Deploy-time bookkeeping, not decision audit.';

-- ----------------------------------------------------------------------------
-- Rule version registry — every deterministic gate stamps its version here so a
-- recommendation stays reconstructable after the rules move on.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS GOVERNANCE.RULE_VERSION (
    RULE_SET        VARCHAR       NOT NULL,
    VERSION         VARCHAR       NOT NULL,
    DESCRIPTION     VARCHAR,
    EFFECTIVE_FROM  TIMESTAMP_NTZ NOT NULL,
    EFFECTIVE_TO    TIMESTAMP_NTZ,
    CONSTRAINT PK_RULE_VERSION PRIMARY KEY (RULE_SET, VERSION)
)
COMMENT = 'Versioned deterministic rule sets referenced by recommendations.';

MERGE INTO GOVERNANCE.RULE_VERSION t
USING (
    SELECT * FROM VALUES
        ('oee-calc',        'oee-calc-v1',        'Availability x performance x quality, hourly grain, planned-calendar denominator.'),
        ('data-quality',    'dq-rules-v1',        'Freshness, gaps, units, range, flatline, tag health, operating-state comparability.'),
        ('safety-gate',     'safety-rules-v1',    'Trip/alarm evaluation, required approver roles, escalation routing.'),
        ('option-eval',     'option-rules-v1',    'Feasibility predicate and net-value ranking. Safety precedes economics.'),
        ('risk-score',      'risk-rules-v1',      'Priority score: probability x consequence + exposure - confidence penalty.'),
        ('bearing-model',   'bearing-demo-v1',    'SYNTHETIC demo bearing degradation predictor. Pumps only.')
    AS v(RULE_SET, VERSION, DESCRIPTION)
) s
ON t.RULE_SET = s.RULE_SET AND t.VERSION = s.VERSION
WHEN NOT MATCHED THEN INSERT (RULE_SET, VERSION, DESCRIPTION, EFFECTIVE_FROM)
    VALUES (s.RULE_SET, s.VERSION, s.DESCRIPTION, '2026-01-01 00:00:00'::TIMESTAMP_NTZ);

-- ----------------------------------------------------------------------------
-- Verification
-- ----------------------------------------------------------------------------
SELECT SCHEMA_NAME, COMMENT
FROM MFG_COPILOT_DB.INFORMATION_SCHEMA.SCHEMATA
WHERE SCHEMA_NAME NOT IN ('INFORMATION_SCHEMA')
ORDER BY SCHEMA_NAME;
