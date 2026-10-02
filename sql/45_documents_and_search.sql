-- =============================================================================
-- 45_documents_and_search.sql
-- Manufacturing OEE & Maintenance Decision Copilot
--
-- Chunks the approved document corpus and builds the Cortex Search service.
--
-- TWO THINGS MATTER MORE THAN RETRIEVAL QUALITY HERE:
--
-- 1. STATUS is an attribute, so retrieval can be filtered to CURRENT. The corpus
--    deliberately contains SOP-BRG-17 v3 (SUPERSEDED) alongside v4 (CURRENT), and the
--    two give CONTRADICTORY guidance -- v3 allows replacement without a confirming
--    inspection, v4 requires one. Citing v3 as authority is a demo failure, so the
--    version must be a filterable field rather than something the model infers from text.
--
-- 2. TRUST_LEVEL separates approved procedures from technician notes. Notes are
--    indexed because they carry real observations, but they are UNTRUSTED: a note
--    cannot confirm a fault mode or authorise anything. NOTE-0421 contains a
--    deliberate prompt injection for the M6 scenario.
--
-- ACCESS-CONTROL CAVEAT: a Cortex Search service queries with the SERVICE OWNER's
-- rights. Holding USAGE on the service exposes every indexed row regardless of the
-- caller's access to the source table. Only non-sensitive approved content is indexed
-- here, and differently entitled plant content would need a separate service.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE MFG_COPILOT_DB;

-- ----------------------------------------------------------------------------
-- Raw lines from the stage
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE GOVERNANCE.PROCEDURE_DOC_LINE AS
SELECT
    REGEXP_REPLACE(METADATA$FILENAME, '^.*/', '') AS FILE_NAME,
    METADATA$FILE_ROW_NUMBER                      AS LINE_NO,
    $1::VARCHAR                                   AS LINE_TEXT
FROM @GOVERNANCE.PROCEDURE_DOCS (FILE_FORMAT => 'GOVERNANCE.FF_MARKDOWN_LINE');

-- ----------------------------------------------------------------------------
-- Reassemble each file, then split into sections on markdown H2 boundaries.
-- Section-level chunks keep a procedure step with its own heading, which is what a
-- technician actually needs cited back at them.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE GOVERNANCE.PROCEDURE_CHUNK AS
WITH docs AS (
    SELECT FILE_NAME,
           LISTAGG(LINE_TEXT, '\n') WITHIN GROUP (ORDER BY LINE_NO) AS DOC_TEXT
    FROM GOVERNANCE.PROCEDURE_DOC_LINE
    GROUP BY FILE_NAME
),
-- Map each file to its register entry. The register, not the filename, is the
-- authority on status and version.
mapped AS (
    SELECT
        d.FILE_NAME, d.DOC_TEXT,
        CASE
          WHEN d.FILE_NAME ILIKE 'SOP-BRG-17-v3%'  THEN 'SOP-BRG-17'
          WHEN d.FILE_NAME ILIKE 'SOP-BRG-17-v4%'  THEN 'SOP-BRG-17'
          WHEN d.FILE_NAME ILIKE 'LOTO-PUMP-03%'   THEN 'LOTO-PUMP-03'
          WHEN d.FILE_NAME ILIKE 'SOP-ALIGN-09%'   THEN 'SOP-ALIGN-09'
          WHEN d.FILE_NAME ILIKE 'ESC-VIB-02%'     THEN 'ESC-VIB-02'
          WHEN d.FILE_NAME ILIKE 'ESC-TMP-01%'     THEN 'ESC-TMP-01'
          WHEN d.FILE_NAME ILIKE 'FG-BRG-01%'      THEN 'FG-BRG-01'
          WHEN d.FILE_NAME ILIKE 'TECHNICIAN-NOTES%' THEN 'TECHNICIAN-NOTES'
        END AS PROCEDURE_CODE,
        CASE
          WHEN d.FILE_NAME ILIKE '%-v3%' THEN 'v3'
          WHEN d.FILE_NAME ILIKE '%-v4%' THEN 'v4'
          WHEN d.FILE_NAME ILIKE '%-v7%' THEN 'v7'
          WHEN d.FILE_NAME ILIKE '%-v2%' THEN 'v2'
          WHEN d.FILE_NAME ILIKE '%-v1%' THEN 'v1'
          ELSE 'n/a'
        END AS VERSION
    FROM docs d
),
sections AS (
    SELECT
        m.FILE_NAME, m.PROCEDURE_CODE, m.VERSION,
        s.INDEX                                   AS SECTION_NO,
        -- The split consumes the '## ' marker, so put it back on every chunk after
        -- the first. Without it a retrieved chunk loses its own heading.
        CASE WHEN s.INDEX = 1 THEN s.VALUE::VARCHAR
             ELSE '## ' || s.VALUE::VARCHAR END   AS SECTION_TEXT
    FROM mapped m,
         LATERAL SPLIT_TO_TABLE(m.DOC_TEXT, '\n## ') s
)
SELECT
    sc.PROCEDURE_CODE || '-' || sc.VERSION || '#' || LPAD(sc.SECTION_NO, 2, '0') AS CHUNK_ID,
    sc.PROCEDURE_CODE,
    sc.VERSION,
    sc.PROCEDURE_CODE || '-' || sc.VERSION        AS PROCEDURE_REF,
    sc.FILE_NAME,
    sc.SECTION_NO,
    -- First markdown heading in the section becomes the section label.
    COALESCE(
      NULLIF(TRIM(REGEXP_SUBSTR(sc.SECTION_TEXT, '^#+ *([^\n]*)', 1, 1, 'e', 1)), ''),
      'Front matter')                             AS SECTION,
    -- Prepend the document identity to every chunk. Retrieval returns chunks out of
    -- context, and a procedure step without its document and version is unusable.
    '[' || sc.PROCEDURE_CODE || ' ' || sc.VERSION || ' | '
        || COALESCE(pm.TITLE, 'Technician notes') || ' | status '
        || COALESCE(pm.STATUS, 'UNTRUSTED_NOTE') || ']' || '\n' || sc.SECTION_TEXT AS CHUNK_TEXT,
    COALESCE(pm.TITLE, 'Technician notes')        AS TITLE,
    COALESCE(pm.STATUS, 'UNTRUSTED_NOTE')         AS STATUS,
    COALESCE(pm.DOCUMENT_TYPE, 'TECHNICIAN_NOTE') AS DOCUMENT_TYPE,
    COALESCE(pm.APPLIES_TO_ASSET_CLASS, '*')      AS APPLIES_TO_ASSET_CLASS,
    COALESCE(pm.APPLIES_TO_TASK_CODE, '*')        AS APPLIES_TO_TASK_CODE,
    CASE WHEN sc.PROCEDURE_CODE = 'TECHNICIAN-NOTES' THEN 'UNTRUSTED' ELSE 'APPROVED' END AS TRUST_LEVEL,
    pm.VALID_FROM, pm.VALID_TO, pm.APPROVED_BY,
    LENGTH(sc.SECTION_TEXT)                       AS CHUNK_CHARS
FROM sections sc
LEFT JOIN GOVERNANCE.PROCEDURE_METADATA pm
       ON pm.PROCEDURE_CODE = sc.PROCEDURE_CODE AND pm.VERSION = sc.VERSION
WHERE LENGTH(TRIM(sc.SECTION_TEXT)) > 40;   -- drop separator-only fragments

-- ----------------------------------------------------------------------------
-- Cortex Search service
-- ----------------------------------------------------------------------------
CREATE OR REPLACE CORTEX SEARCH SERVICE SEMANTIC.MAINTENANCE_MANUAL_SEARCH
    ON CHUNK_TEXT
    ATTRIBUTES PROCEDURE_CODE, VERSION, PROCEDURE_REF, STATUS, DOCUMENT_TYPE,
               APPLIES_TO_ASSET_CLASS, APPLIES_TO_TASK_CODE, TRUST_LEVEL, SECTION, TITLE
    WAREHOUSE = COMPUTE_WH
    TARGET_LAG = '1 hour'
    COMMENT = 'Approved maintenance corpus. Filter STATUS = CURRENT for authority; TRUST_LEVEL = APPROVED excludes technician notes. Queries run with the service owner rights, so only non-sensitive content is indexed.'
    AS
SELECT CHUNK_ID, CHUNK_TEXT, PROCEDURE_CODE, VERSION, PROCEDURE_REF, STATUS,
       DOCUMENT_TYPE, APPLIES_TO_ASSET_CLASS, APPLIES_TO_TASK_CODE,
       TRUST_LEVEL, SECTION, TITLE
FROM GOVERNANCE.PROCEDURE_CHUNK;

-- ----------------------------------------------------------------------------
-- Verification
-- ----------------------------------------------------------------------------
SELECT PROCEDURE_REF, STATUS, TRUST_LEVEL, COUNT(*) AS chunks,
       MIN(CHUNK_CHARS) AS min_chars, MAX(CHUNK_CHARS) AS max_chars
FROM GOVERNANCE.PROCEDURE_CHUNK
GROUP BY PROCEDURE_REF, STATUS, TRUST_LEVEL
ORDER BY PROCEDURE_REF;
