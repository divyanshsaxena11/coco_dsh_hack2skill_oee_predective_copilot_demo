-- =============================================================================
-- 00_account_prereqs.sql
-- Manufacturing OEE & Maintenance Decision Copilot
--
-- Account-level grants required before anything else works. Run as ACCOUNTADMIN.
--
-- WHY THIS FILE EXISTS: on a fresh account, SNOWFLAKE.CORTEX.AI_COMPLETE and the
-- Cortex Search service both fail with a missing-privilege error that does NOT
-- mention Cortex. Granting AI function usage up front avoids losing an hour to it
-- on the day the semantic/search layer goes in.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- ----------------------------------------------------------------------------
-- AI function privileges
-- ----------------------------------------------------------------------------
GRANT USE AI FUNCTIONS ON ACCOUNT TO ROLE ACCOUNTADMIN;

-- ----------------------------------------------------------------------------
-- Warehouse
-- X-Small is ample: the largest table is ~121k rows.
-- ----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS COMPUTE_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND   = 300
  AUTO_RESUME    = TRUE
  INITIALLY_SUSPENDED = FALSE
  COMMENT = 'Manufacturing copilot demo compute';

USE WAREHOUSE COMPUTE_WH;

-- ----------------------------------------------------------------------------
-- Verification
--
-- NOTE ON MODELS: 'claude-4-sonnet' is in legacy state on this account and returns
-- a 400 from the remote service. Verified working: 'claude-sonnet-4-5'. Re-probe
-- before the demo -- model availability changes without notice.
-- ----------------------------------------------------------------------------
SELECT
    SNOWFLAKE.CORTEX.AI_COMPLETE('claude-sonnet-4-5', 'Reply with exactly: OK') AS ai_probe,
    CURRENT_ACCOUNT()   AS account,
    CURRENT_ROLE()      AS role,
    CURRENT_WAREHOUSE() AS warehouse,
    CURRENT_REGION()    AS region;
