-- =============================================================================
-- 42_document_stage.sql
-- Manufacturing OEE & Maintenance Decision Copilot
--
-- Internal stage and file format for the approved document corpus.
--
-- Split out from 45 on purpose: deploy.sh uploads documents/maintenance_approved/
-- into this stage AFTER this file runs and BEFORE 45 reads from it. The stage has to
-- exist before the upload, and the files have to exist before the chunking query.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE MFG_COPILOT_DB;

-- Whole-line ingest: FIELD_DELIMITER = NONE puts each source line in $1 untouched,
-- which is what we want for markdown. A comma delimiter would shred every table row.
CREATE OR REPLACE FILE FORMAT GOVERNANCE.FF_MARKDOWN_LINE
    TYPE = CSV
    FIELD_DELIMITER = NONE
    RECORD_DELIMITER = '\n'
    SKIP_HEADER = 0
    FIELD_OPTIONALLY_ENCLOSED_BY = NONE
    ESCAPE_UNENCLOSED_FIELD = NONE
    TRIM_SPACE = FALSE
    EMPTY_FIELD_AS_NULL = FALSE
    COMMENT = 'Reads a markdown file one line per row with no field parsing.';

CREATE STAGE IF NOT EXISTS GOVERNANCE.PROCEDURE_DOCS
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Approved procedure corpus: SOPs, LOTO, escalations, failure guides, and untrusted technician notes.';

SELECT 'stage ready' AS status;
