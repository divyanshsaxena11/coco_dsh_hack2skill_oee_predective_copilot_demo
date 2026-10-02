-- =============================================================================
-- 15_governance_masters.sql
-- Manufacturing OEE & Maintenance Decision Copilot
--
-- Safety limits, approved procedures, authority matrix, fault modes, maintenance
-- tasks and their requirements, parts, inventory, technicians, and production
-- windows. These are the tables the feasibility predicate and the safety gate read.
--
-- Deliberate negative-path seeds live here:
--   * SOP-BRG-17 exists as v3 SUPERSEDED and v4 CURRENT -- retrieval must cite v4.
--   * S. Iyer holds the required bearing skill but the certification has EXPIRED.
--   * Only ONE compatible bearing kit is on hand, so M3_NO_PART is a one-row change.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE MFG_COPILOT_DB;

-- ----------------------------------------------------------------------------
-- Safety limits
--
-- Hero calibration: P-204 bearing temperature reaches ~60.7 C in the current window.
-- ALARM is set at 62 C so the DEFAULT story stays a genuine engineering judgement
-- call rather than an automatic escalation, and M5_SAFETY_TRIP (+20 C -> ~80.7 C)
-- decisively crosses TRIP at 75 C. Vibration peaks near 4.0 mm/s against a 4.5 mm/s
-- alarm, so the hero is flagged by rate-of-change and model evidence, not by a
-- threshold breach -- which is the realistic case and the harder one to reason about.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE GOVERNANCE.SAFETY_LIMIT (
    LIMIT_ID VARCHAR NOT NULL,
    ASSET_CLASS VARCHAR NOT NULL,
    TAG_SUFFIX  VARCHAR NOT NULL,
    ALARM_VALUE NUMBER(10,3),
    TRIP_VALUE  NUMBER(10,3),
    UNIT VARCHAR NOT NULL,
    SEVERITY VARCHAR NOT NULL COMMENT 'LOW | MEDIUM | HIGH | CRITICAL',
    REQUIRED_RESPONSE VARCHAR,
    ESCALATION_REF VARCHAR NOT NULL COMMENT 'Procedure code the copilot must return instead of improvising a response',
    OWNER_ROLE VARCHAR,
    RULE_VERSION VARCHAR,
    VALID_FROM DATE, VALID_TO DATE,
    CONSTRAINT PK_SAFETY_LIMIT PRIMARY KEY (LIMIT_ID)
) COMMENT = 'Configured alarm and trip thresholds. Evaluated deterministically; never inferred by the model.';

INSERT OVERWRITE INTO GOVERNANCE.SAFETY_LIMIT VALUES
 ('SL-PUMP-VIB', 'CENTRIFUGAL_PUMP','VIB_RMS_DE',   4.500,  7.100,'MM_S', 'HIGH',
  'Above alarm: increase monitoring frequency and schedule inspection. Above trip: follow ESC-VIB-02 immediately.',
  'ESC-VIB-02','MFG_EHS_OWNER','safety-rules-v1','2026-01-01',NULL),
 ('SL-PUMP-TMP', 'CENTRIFUGAL_PUMP','TEMP_BRG_DE', 62.000, 75.000,'DEG_C','HIGH',
  'Above alarm: verify lubrication and cooling, inspect within 24 hours. Above trip: follow ESC-TMP-01 immediately.',
  'ESC-TMP-01','MFG_EHS_OWNER','safety-rules-v1','2026-01-01',NULL),
 ('SL-PUMP-CUR', 'CENTRIFUGAL_PUMP','MOTOR_CURRENT',48.000, 55.000,'AMP','MEDIUM',
  'Above alarm: check for hydraulic overload. Above trip: follow ESC-ELE-01.',
  'ESC-ELE-01','MFG_EHS_OWNER','safety-rules-v1','2026-01-01',NULL),
 ('SL-MOT-VIB',  'AC_MOTOR','VIB_RMS_DE',          4.500,  7.100,'MM_S', 'HIGH',
  'Above alarm: increase monitoring frequency. Above trip: follow ESC-VIB-02.',
  'ESC-VIB-02','MFG_EHS_OWNER','safety-rules-v1','2026-01-01',NULL),
 ('SL-MOT-TMP',  'AC_MOTOR','TEMP_BRG_DE',        70.000, 85.000,'DEG_C','HIGH',
  'Above alarm: verify ventilation and load. Above trip: follow ESC-TMP-01.',
  'ESC-TMP-01','MFG_EHS_OWNER','safety-rules-v1','2026-01-01',NULL),
 ('SL-MOT-CUR',  'AC_MOTOR','MOTOR_CURRENT',      28.000, 33.000,'AMP','MEDIUM',
  'Above alarm: check mechanical load. Above trip: follow ESC-ELE-01.',
  'ESC-ELE-01','MFG_EHS_OWNER','safety-rules-v1','2026-01-01',NULL);

-- ----------------------------------------------------------------------------
-- Approved procedures
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE GOVERNANCE.PROCEDURE_METADATA (
    PROCEDURE_CODE VARCHAR NOT NULL,
    VERSION VARCHAR NOT NULL,
    TITLE VARCHAR,
    STATUS VARCHAR NOT NULL COMMENT 'CURRENT | SUPERSEDED | DRAFT | WITHDRAWN',
    APPLIES_TO_ASSET_CLASS VARCHAR,
    APPLIES_TO_TASK_CODE VARCHAR,
    DOCUMENT_TYPE VARCHAR COMMENT 'SOP | LOTO | ESCALATION | FAILURE_GUIDE',
    VALID_FROM DATE, VALID_TO DATE,
    APPROVED_BY VARCHAR,
    CONSTRAINT PK_PROCEDURE_METADATA PRIMARY KEY (PROCEDURE_CODE, VERSION)
) COMMENT = 'Approved procedure register. Both v3 and v4 of SOP-BRG-17 exist on purpose: retrieval must cite the CURRENT version, and citing the superseded one is a demo failure.';

INSERT OVERWRITE INTO GOVERNANCE.PROCEDURE_METADATA VALUES
 ('SOP-BRG-17','v3','Drive-End Bearing Inspection and Replacement','SUPERSEDED','CENTRIFUGAL_PUMP','BRG_INSPECT','SOP','2024-02-01','2026-03-31','K. Menon'),
 ('SOP-BRG-17','v4','Drive-End Bearing Inspection and Replacement','CURRENT',   'CENTRIFUGAL_PUMP','BRG_INSPECT','SOP','2026-04-01',NULL,        'K. Menon'),
 ('LOTO-PUMP-03','v7','Lockout/Tagout - Centrifugal Pump Isolation','CURRENT',  'CENTRIFUGAL_PUMP','BRG_REPLACE','LOTO','2025-11-15',NULL,       'EHS Committee'),
 ('SOP-ALIGN-09','v2','Shaft Alignment Verification','CURRENT',                 'CENTRIFUGAL_PUMP','ALIGN_CHECK','SOP','2025-06-01',NULL,       'K. Menon'),
 ('ESC-VIB-02','v1','Vibration Limit Breach Escalation','CURRENT',              NULL,'*','ESCALATION','2025-01-10',NULL,                        'EHS Committee'),
 ('ESC-TMP-01','v1','Bearing Temperature Trip Escalation','CURRENT',            NULL,'*','ESCALATION','2025-01-10',NULL,                        'EHS Committee'),
 ('FG-BRG-01','v2','Failure Guide - Rolling Element Bearing Modes','CURRENT',   'CENTRIFUGAL_PUMP',NULL,'FAILURE_GUIDE','2025-09-01',NULL,       'Reliability CoE');

-- ----------------------------------------------------------------------------
-- Authority matrix
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE GOVERNANCE.EMPLOYEE_AUTHORITY (
    ROLE_CODE VARCHAR NOT NULL,
    ROLE_LABEL VARCHAR,
    CAN_CONFIRM_DIAGNOSIS BOOLEAN DEFAULT FALSE,
    CAN_APPROVE_TECHNICAL BOOLEAN DEFAULT FALSE,
    CAN_APPROVE_PRODUCTION_DOWNTIME BOOLEAN DEFAULT FALSE,
    IS_SAFETY_APPROVER BOOLEAN DEFAULT FALSE,
    MAX_COST_APPROVAL NUMBER(12,2),
    MAX_DOWNTIME_MIN NUMBER(8,0),
    CONSTRAINT PK_EMPLOYEE_AUTHORITY PRIMARY KEY (ROLE_CODE)
) COMMENT = 'Who may approve what. Read by CHECK_MAINTENANCE_SAFETY to compute required approver roles.';

INSERT OVERWRITE INTO GOVERNANCE.EMPLOYEE_AUTHORITY VALUES
 ('RELIABILITY_ENGINEER', 'Reliability Engineer',  TRUE,  TRUE,  FALSE, FALSE, 200000.00,  240),
 ('MAINTENANCE_PLANNER',  'Maintenance Planner',   FALSE, FALSE, FALSE, FALSE, 100000.00,  120),
 ('PRODUCTION_SUPERVISOR','Production Supervisor', FALSE, FALSE, TRUE,  FALSE, 150000.00,  240),
 ('EHS_OWNER',            'EHS / Safety Owner',    FALSE, FALSE, FALSE, TRUE,       0.00,    0),
 ('MAINTENANCE_MANAGER',  'Maintenance Manager',   TRUE,  TRUE,  TRUE,  FALSE,2000000.00, 1440),
 ('TECHNICIAN',           'Maintenance Technician',FALSE, FALSE, FALSE, FALSE,      0.00,    0);

-- ----------------------------------------------------------------------------
-- Fault modes, tasks, and task requirements
-- These three tables give the ontology its route from symptom to resource.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE GOVERNANCE.FAULT_MODE (
    FAULT_MODE VARCHAR NOT NULL,
    FAULT_LABEL VARCHAR,
    APPLIES_TO_COMPONENT_TYPE VARCHAR,
    APPLIES_TO_ASSET_CLASS VARCHAR,
    TYPICAL_PF_INTERVAL_DAYS NUMBER(6,1) COMMENT 'Detectable potential failure to functional failure, days',
    PRIMARY_SYMPTOM VARCHAR,
    FAILURE_GUIDE_REF VARCHAR,
    CONSTRAINT PK_FAULT_MODE PRIMARY KEY (FAULT_MODE)
) COMMENT = 'Degradation mechanisms in scope for the demo.';

INSERT OVERWRITE INTO GOVERNANCE.FAULT_MODE VALUES
 ('DRIVE_END_BEARING_DEGRADATION','Drive-end rolling element bearing degradation','DRIVE_END_BEARING','CENTRIFUGAL_PUMP',21.0,'Rising vibration RMS with bearing temperature increase','FG-BRG-01'),
 ('SHAFT_MISALIGNMENT','Shaft/coupling misalignment','COUPLING','CENTRIFUGAL_PUMP',45.0,'Elevated vibration at 2x running speed without temperature rise','FG-BRG-01');

CREATE OR REPLACE TABLE GOVERNANCE.MAINTENANCE_TASK (
    TASK_CODE VARCHAR NOT NULL,
    TASK_LABEL VARCHAR,
    ACTION_TYPE VARCHAR COMMENT 'INSPECT | REPAIR | REPLACE | SERVICE | MONITOR',
    MITIGATES_FAULT_MODE VARCHAR,
    ESTIMATED_DURATION_MIN NUMBER(8,0),
    REQUIRES_LINE_STOP BOOLEAN,
    ESTIMATED_COST NUMBER(12,2),
    GOVERNED_BY_PROCEDURE VARCHAR,
    CONSTRAINT PK_MAINTENANCE_TASK PRIMARY KEY (TASK_CODE)
) COMMENT = 'Approved maintenance tasks. The copilot may only propose options built from these.';

INSERT OVERWRITE INTO GOVERNANCE.MAINTENANCE_TASK VALUES
 ('BRG_INSPECT','Drive-end bearing inspection','INSPECT','DRIVE_END_BEARING_DEGRADATION', 60, FALSE,  18000.00,'SOP-BRG-17'),
 ('BRG_REPLACE','Drive-end bearing replacement','REPLACE','DRIVE_END_BEARING_DEGRADATION',120, TRUE,  145000.00,'SOP-BRG-17'),
 ('ALIGN_CHECK','Shaft alignment verification','INSPECT','SHAFT_MISALIGNMENT',             90, TRUE,   32000.00,'SOP-ALIGN-09'),
 ('LUBE_SERVICE','Bearing lubrication service','SERVICE','DRIVE_END_BEARING_DEGRADATION',  30, FALSE,   6000.00,'SOP-BRG-17'),
 ('VIB_MONITOR','Enhanced vibration monitoring','MONITOR','DRIVE_END_BEARING_DEGRADATION',  0, FALSE,   2000.00,'SOP-BRG-17');

CREATE OR REPLACE TABLE GOVERNANCE.TASK_REQUIREMENT (
    REQUIREMENT_ID VARCHAR NOT NULL,
    TASK_CODE VARCHAR NOT NULL,
    REQUIREMENT_TYPE VARCHAR NOT NULL COMMENT 'PART | TOOL | SKILL | PERMIT',
    REQUIREMENT_CODE VARCHAR NOT NULL,
    QUANTITY NUMBER(8,0) DEFAULT 1,
    IS_MANDATORY BOOLEAN DEFAULT TRUE,
    CONSTRAINT PK_TASK_REQUIREMENT PRIMARY KEY (REQUIREMENT_ID)
) COMMENT = 'What each task needs. The feasibility predicate cannot silently assume an unavailable resource because every requirement is a row here.';

INSERT OVERWRITE INTO GOVERNANCE.TASK_REQUIREMENT VALUES
 ('RQ-001','BRG_INSPECT','SKILL', 'MECH_BEARING_L2',1,TRUE),
 ('RQ-002','BRG_INSPECT','TOOL',  'VIB_ANALYSER',   1,TRUE),
 ('RQ-003','BRG_INSPECT','PERMIT','LOTO-PUMP-03',   1,TRUE),
 ('RQ-004','BRG_REPLACE','SKILL', 'MECH_BEARING_L2',1,TRUE),
 ('RQ-005','BRG_REPLACE','PART',  'BRG-6312-C3',    1,TRUE),
 ('RQ-006','BRG_REPLACE','TOOL',  'PULLER_KIT',     1,TRUE),
 ('RQ-007','BRG_REPLACE','PERMIT','LOTO-PUMP-03',   1,TRUE),
 ('RQ-008','ALIGN_CHECK','SKILL', 'MECH_ALIGN_L1',  1,TRUE),
 ('RQ-009','ALIGN_CHECK','TOOL',  'LASER_ALIGN',    1,TRUE),
 ('RQ-010','ALIGN_CHECK','PERMIT','LOTO-PUMP-03',   1,TRUE),
 ('RQ-011','LUBE_SERVICE','SKILL','MECH_BEARING_L2',1,TRUE),
 ('RQ-012','LUBE_SERVICE','PART', 'LUBE-EP2',       1,TRUE),
 ('RQ-013','VIB_MONITOR','SKILL', 'COND_MON_L1',    1,TRUE);

-- ----------------------------------------------------------------------------
-- Parts, compatibility, inventory
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE CORE.PART_MASTER (
    PART_CODE VARCHAR NOT NULL,
    PART_NAME VARCHAR,
    PART_CATEGORY VARCHAR,
    UNIT_COST NUMBER(12,2),
    LEAD_TIME_DAYS NUMBER(6,0),
    PREFERRED_SUPPLIER VARCHAR,
    CONSTRAINT PK_PART_MASTER PRIMARY KEY (PART_CODE)
) COMMENT = 'Part master.';

INSERT OVERWRITE INTO CORE.PART_MASTER VALUES
 ('BRG-6312-C3','Bearing kit 6312 C3 (ETA-125 drive end)','BEARING', 42000.00,12,'SKF India'),
 ('BRG-6310-C3','Bearing kit 6310 C3 (ETA-080 drive end)','BEARING', 28000.00, 9,'SKF India'),
 ('SEAL-KIT-125','Mechanical seal kit ETA-125','SEAL',              18500.00,14,'KSB Spares'),
 ('COUPL-EL-80','Elastomeric coupling element 80','COUPLING',        9200.00, 7,'Rexnord'),
 ('LUBE-EP2','EP2 lithium grease cartridge','CONSUMABLE',             850.00, 2,'Shell'),
 ('ALIGN-SHIM-SET','Stainless alignment shim set','CONSUMABLE',       3400.00, 5,'Local');

CREATE OR REPLACE TABLE GOVERNANCE.PART_COMPATIBILITY (
    COMPATIBILITY_ID VARCHAR NOT NULL,
    PART_CODE VARCHAR NOT NULL,
    ASSET_ID VARCHAR,
    ASSET_CLASS VARCHAR,
    COMPONENT_TYPE VARCHAR,
    IS_APPROVED_SUBSTITUTE BOOLEAN DEFAULT FALSE,
    APPROVED_BY VARCHAR,
    VALID_FROM DATE, VALID_TO DATE,
    CONSTRAINT PK_PART_COMPATIBILITY PRIMARY KEY (COMPATIBILITY_ID)
) COMMENT = 'Which part fits which asset/component. Master-data governed: the copilot may never change this.';

INSERT OVERWRITE INTO GOVERNANCE.PART_COMPATIBILITY VALUES
 ('PC-001','BRG-6312-C3','P-204',NULL,'DRIVE_END_BEARING',FALSE,'Reliability CoE','2019-06-18',NULL),
 ('PC-002','BRG-6310-C3','P-201',NULL,'DRIVE_END_BEARING',FALSE,'Reliability CoE','2021-04-12',NULL),
 ('PC-003','BRG-6310-C3','P-202',NULL,'DRIVE_END_BEARING',FALSE,'Reliability CoE','2021-04-12',NULL),
 ('PC-004','BRG-6310-C3','P-203',NULL,'DRIVE_END_BEARING',FALSE,'Reliability CoE','2020-09-30',NULL),
 ('PC-005','BRG-6310-C3','P-205',NULL,'DRIVE_END_BEARING',FALSE,'Reliability CoE','2022-01-20',NULL),
 ('PC-006','SEAL-KIT-125','P-204',NULL,'DRIVE_END_BEARING',FALSE,'Reliability CoE','2019-06-18',NULL),
 ('PC-007','COUPL-EL-80',NULL,'CENTRIFUGAL_PUMP','COUPLING',FALSE,'Reliability CoE','2020-01-01',NULL),
 ('PC-008','LUBE-EP2',NULL,'CENTRIFUGAL_PUMP','DRIVE_END_BEARING',FALSE,'Reliability CoE','2020-01-01',NULL),
 ('PC-009','ALIGN-SHIM-SET',NULL,'CENTRIFUGAL_PUMP','COUPLING',FALSE,'Reliability CoE','2020-01-01',NULL);

CREATE OR REPLACE TABLE CORE.PART_INVENTORY_BASE (
    INVENTORY_ID VARCHAR NOT NULL,
    SITE_ID VARCHAR NOT NULL,
    PART_CODE VARCHAR NOT NULL,
    ON_HAND NUMBER(8,0) NOT NULL,
    RESERVED NUMBER(8,0) NOT NULL DEFAULT 0,
    REORDER_POINT NUMBER(8,0),
    SNAPSHOT_TS TIMESTAMP_NTZ,
    SOURCE_SYSTEM VARCHAR DEFAULT 'INVENTORY',
    CONSTRAINT PK_PART_INVENTORY_BASE PRIMARY KEY (INVENTORY_ID)
) COMMENT = 'Base inventory snapshot. CORE.PART_INVENTORY is a view over this that applies the scenario overlay, so M3_NO_PART never mutates the seed.';

INSERT OVERWRITE INTO CORE.PART_INVENTORY_BASE
SELECT 'INV-' || LPAD(ROW_NUMBER() OVER (ORDER BY v.PART_CODE), 3, '0'),
       'PLANT-01', v.PART_CODE, v.ON_HAND, v.RESERVED, v.REORDER_POINT,
       GOVERNANCE.CURRENT_AS_OF(), 'INVENTORY'
FROM (
    SELECT * FROM VALUES
      -- Exactly one compatible hero bearing kit, unreserved. M3_NO_PART flips this to zero.
      ('BRG-6312-C3',   1, 0, 1),
      ('BRG-6310-C3',   3, 1, 2),
      ('SEAL-KIT-125',  2, 0, 1),
      ('COUPL-EL-80',   0, 0, 1),
      ('LUBE-EP2',     24, 2, 6),
      ('ALIGN-SHIM-SET',5, 0, 2)
    AS t(PART_CODE, ON_HAND, RESERVED, REORDER_POINT)
) v;

-- ----------------------------------------------------------------------------
-- Technicians and skills
--
-- S. Iyer holds MECH_BEARING_L2 but the certification lapsed on 2026-08-31, before
-- the demo clock. That makes EXPIRED_CERT a scenario that needs no data change at
-- all -- the copilot simply must not count him as available.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE CORE.TECHNICIAN (
    TECHNICIAN_ID VARCHAR NOT NULL,
    TECHNICIAN_NAME VARCHAR,
    SITE_ID VARCHAR,
    SHIFT_CODE VARCHAR COMMENT 'A = 06:00-14:00, B = 14:00-22:00, C = 22:00-06:00',
    IS_ON_ROSTER BOOLEAN DEFAULT TRUE,
    CONSTRAINT PK_TECHNICIAN PRIMARY KEY (TECHNICIAN_ID)
) COMMENT = 'Maintenance crew.';

INSERT OVERWRITE INTO CORE.TECHNICIAN VALUES
 ('T-001','R. Kulkarni','PLANT-01','A',TRUE),
 ('T-002','S. Iyer','PLANT-01','A',TRUE),
 ('T-003','A. Deshpande','PLANT-01','B',TRUE),
 ('T-004','N. Rao','PLANT-01','C',TRUE);

CREATE OR REPLACE TABLE CORE.TECHNICIAN_SKILL (
    SKILL_ASSIGNMENT_ID VARCHAR NOT NULL,
    TECHNICIAN_ID VARCHAR NOT NULL,
    SKILL_CODE VARCHAR NOT NULL,
    SKILL_LABEL VARCHAR,
    CERT_VALID_FROM DATE,
    CERT_VALID_TO DATE COMMENT 'NULL means no expiry. A date in the past means the certification has lapsed.',
    CONSTRAINT PK_TECHNICIAN_SKILL PRIMARY KEY (SKILL_ASSIGNMENT_ID)
) COMMENT = 'Effective-dated qualifications. Expiry is checked against the demo clock, not wall-clock time.';

INSERT OVERWRITE INTO CORE.TECHNICIAN_SKILL VALUES
 ('TS-001','T-001','MECH_BEARING_L2','Mechanical - bearing replacement L2','2024-04-01','2027-03-31'),
 ('TS-002','T-001','COND_MON_L1','Condition monitoring L1','2024-04-01','2027-03-31'),
 ('TS-003','T-002','MECH_BEARING_L2','Mechanical - bearing replacement L2','2023-09-01','2026-08-31'),
 ('TS-004','T-003','MECH_ALIGN_L1','Mechanical - shaft alignment L1','2025-01-15','2027-12-31'),
 ('TS-005','T-003','MECH_BEARING_L2','Mechanical - bearing replacement L2','2025-01-15','2028-01-14'),
 ('TS-006','T-004','ELEC_L1','Electrical L1','2024-06-01','2027-05-31'),
 ('TS-007','T-004','COND_MON_L1','Condition monitoring L1','2024-06-01','2027-05-31');

CREATE OR REPLACE TABLE CORE.TOOL_INVENTORY (
    TOOL_CODE VARCHAR NOT NULL,
    TOOL_NAME VARCHAR,
    SITE_ID VARCHAR,
    QTY_AVAILABLE NUMBER(6,0),
    CONSTRAINT PK_TOOL_INVENTORY PRIMARY KEY (TOOL_CODE)
) COMMENT = 'Tool availability.';

INSERT OVERWRITE INTO CORE.TOOL_INVENTORY VALUES
 ('VIB_ANALYSER','Portable vibration analyser','PLANT-01',2),
 ('PULLER_KIT','Hydraulic bearing puller kit','PLANT-01',1),
 ('LASER_ALIGN','Laser shaft alignment system','PLANT-01',1);

-- ----------------------------------------------------------------------------
-- Production windows
--
-- The hero window is 2026-09-15 14:00-16:00, which opens ~53 hours after the
-- snapshot. The Friday window (2026-09-18 22:00) is what M4_WINDOW_CONFLICT forces
-- the copilot back to when production refuses an earlier stop.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE CORE.PRODUCTION_WINDOW_BASE (
    WINDOW_ID VARCHAR NOT NULL,
    LINE_ID VARCHAR NOT NULL,
    WINDOW_START TIMESTAMP_NTZ NOT NULL,
    WINDOW_END TIMESTAMP_NTZ NOT NULL,
    WINDOW_TYPE VARCHAR COMMENT 'PLANNED_MAINTENANCE | CHANGEOVER | PLANNED_STOP',
    AUTHORIZATION_STATUS VARCHAR NOT NULL COMMENT 'APPROVED | PENDING | REJECTED',
    ALLOWED_DOWNTIME_MIN NUMBER(8,0) NOT NULL,
    PRODUCTION_ORDER VARCHAR,
    BUSINESS_PRIORITY VARCHAR,
    APPROVED_BY_ROLE VARCHAR,
    CONSTRAINT PK_PRODUCTION_WINDOW_BASE PRIMARY KEY (WINDOW_ID)
) COMMENT = 'Base window schedule. CORE.PRODUCTION_WINDOW is a view that applies the scenario overlay.';

INSERT OVERWRITE INTO CORE.PRODUCTION_WINDOW_BASE VALUES
 ('W-001','PKG-L2','2026-09-13 22:00:00','2026-09-13 23:00:00','CHANGEOVER',        'APPROVED',  0,'PO-88421','HIGH','PRODUCTION_SUPERVISOR'),
 ('W-002','PKG-L2','2026-09-15 14:00:00','2026-09-15 16:00:00','PLANNED_MAINTENANCE','APPROVED',120,NULL,      'HIGH','PRODUCTION_SUPERVISOR'),
 ('W-003','PKG-L2','2026-09-18 22:00:00','2026-09-19 02:00:00','PLANNED_MAINTENANCE','APPROVED',240,NULL,      'MEDIUM','PRODUCTION_SUPERVISOR'),
 ('W-004','PKG-L2','2026-09-20 02:00:00','2026-09-20 06:00:00','PLANNED_STOP',       'APPROVED',240,NULL,      'LOW','PRODUCTION_SUPERVISOR'),
 ('W-005','PKG-L1','2026-09-16 02:00:00','2026-09-16 05:00:00','PLANNED_MAINTENANCE','APPROVED',180,NULL,      'LOW','PRODUCTION_SUPERVISOR');

-- ----------------------------------------------------------------------------
-- Verification
-- ----------------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM GOVERNANCE.SAFETY_LIMIT)       AS safety_limits,
    (SELECT COUNT(*) FROM GOVERNANCE.PROCEDURE_METADATA WHERE STATUS='CURRENT') AS current_procedures,
    (SELECT COUNT(*) FROM GOVERNANCE.PROCEDURE_METADATA WHERE STATUS='SUPERSEDED') AS superseded_procedures,
    (SELECT COUNT(*) FROM GOVERNANCE.TASK_REQUIREMENT)   AS task_requirements,
    (SELECT ON_HAND - RESERVED FROM CORE.PART_INVENTORY_BASE WHERE PART_CODE='BRG-6312-C3') AS hero_part_available,
    (SELECT COUNT(*) FROM CORE.TECHNICIAN_SKILL
      WHERE SKILL_CODE='MECH_BEARING_L2' AND CERT_VALID_TO < GOVERNANCE.CURRENT_AS_OF()) AS expired_bearing_certs;
