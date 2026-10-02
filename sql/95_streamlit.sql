-- =============================================================================
-- 95_streamlit.sql
-- Manufacturing OEE & Maintenance Decision Copilot
--
-- Deploys the OEE Command Center Streamlit app inside Snowflake.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE MFG_COPILOT_DB;

CREATE STAGE IF NOT EXISTS APP.STREAMLIT_STAGE
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Streamlit app source files.';

-- Upload happens via deploy.sh after this file runs.
-- The CREATE STREAMLIT below references the stage.

-- NOTE: If the PUT/upload hasn't happened yet, the CREATE STREAMLIT will still
-- succeed — Snowflake creates the object and it fails at runtime. The deploy.sh
-- handles the upload ordering.

CREATE OR REPLACE STREAMLIT APP.OEE_COMMAND_CENTER
    ROOT_LOCATION = '@MFG_COPILOT_DB.APP.STREAMLIT_STAGE'
    MAIN_FILE = 'streamlit_app.py'
    QUERY_WAREHOUSE = 'COMPUTE_WH'
    COMMENT = 'Manufacturing OEE & Maintenance Decision Copilot — OEE Command Center. 4 tabs: Command Center, Fleet Triage, Decision Card, Audit & Ontology.';

GRANT USAGE ON STREAMLIT APP.OEE_COMMAND_CENTER TO ROLE MFG_RELIABILITY_ENGINEER;
GRANT USAGE ON STREAMLIT APP.OEE_COMMAND_CENTER TO ROLE MFG_MAINTENANCE_PLANNER;
GRANT USAGE ON STREAMLIT APP.OEE_COMMAND_CENTER TO ROLE MFG_PRODUCTION_SUPERVISOR;

SHOW STREAMLITS IN SCHEMA MFG_COPILOT_DB.APP;
