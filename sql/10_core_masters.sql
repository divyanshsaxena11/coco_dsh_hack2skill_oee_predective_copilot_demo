-- =============================================================================
-- 10_core_masters.sql
-- Manufacturing OEE & Maintenance Decision Copilot
--
-- Plant hierarchy, asset master, maintainable components, and sensor tags.
-- DDL and seed together: these are small reference tables and keeping them in one
-- file makes the hero conditions auditable in a single read.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE MFG_COPILOT_DB;

-- ----------------------------------------------------------------------------
-- DDL
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE CORE.SITE (
    SITE_ID   VARCHAR NOT NULL,
    SITE_NAME VARCHAR,
    TIMEZONE  VARCHAR,
    CONTRIBUTION_VALUE_PER_HOUR NUMBER(12,2) COMMENT 'Synthetic contribution margin per production hour, INR. Used by the value estimate.',
    CONSTRAINT PK_SITE PRIMARY KEY (SITE_ID)
) COMMENT = 'Plant sites. Synthetic.';

CREATE OR REPLACE TABLE CORE.AREA (
    AREA_ID   VARCHAR NOT NULL,
    SITE_ID   VARCHAR NOT NULL,
    AREA_NAME VARCHAR,
    CONSTRAINT PK_AREA PRIMARY KEY (AREA_ID)
) COMMENT = 'Areas within a site.';

CREATE OR REPLACE TABLE CORE.PRODUCTION_LINE (
    LINE_ID   VARCHAR NOT NULL,
    AREA_ID   VARCHAR NOT NULL,
    SITE_ID   VARCHAR NOT NULL,
    LINE_NAME VARCHAR,
    IDEAL_CYCLE_SEC   NUMBER(8,3) COMMENT 'Governed ideal cycle time standard, seconds per unit. The denominator behind the OEE performance factor.',
    BUSINESS_PRIORITY VARCHAR,
    CONSTRAINT PK_LINE PRIMARY KEY (LINE_ID)
) COMMENT = 'Production lines.';

CREATE OR REPLACE TABLE CORE.ASSET (
    ASSET_ID VARCHAR NOT NULL,
    ASSET_NAME VARCHAR,
    ASSET_CLASS VARCHAR NOT NULL,
    LINE_ID VARCHAR, AREA_ID VARCHAR, SITE_ID VARCHAR NOT NULL, PARENT_ASSET_ID VARCHAR,
    MANUFACTURER VARCHAR, MODEL VARCHAR, INSTALL_DATE DATE,
    CRITICALITY VARCHAR NOT NULL COMMENT 'A=highest consequence of failure, D=lowest',
    CRITICALITY_SCORE NUMBER(4,2) COMMENT 'Numeric consequence weight consumed by AI.GET_ASSET_RISK',
    SAFETY_CONSEQUENCE VARCHAR, QUALITY_CONSEQUENCE VARCHAR, ENV_CONSEQUENCE VARCHAR,
    OPERATIONAL_STATUS VARCHAR, VALID_FROM DATE, VALID_TO DATE,
    SOURCE_SYSTEM VARCHAR DEFAULT 'DEMO_SEED',
    CONSTRAINT PK_ASSET PRIMARY KEY (ASSET_ID)
) COMMENT = 'Canonical asset master, effective-dated. Synthetic.';

CREATE OR REPLACE TABLE CORE.COMPONENT (
    COMPONENT_ID VARCHAR NOT NULL,
    ASSET_ID VARCHAR NOT NULL,
    COMPONENT_TYPE VARCHAR NOT NULL,
    COMPONENT_NAME VARCHAR,
    IS_MAINTAINABLE BOOLEAN DEFAULT TRUE,
    LAST_LUBRICATION_TS TIMESTAMP_NTZ,
    LUBRICATION_INTERVAL_HOURS NUMBER(8,1),
    CONSTRAINT PK_COMPONENT PRIMARY KEY (COMPONENT_ID)
) COMMENT = 'Maintainable components linked to their asset.';

CREATE OR REPLACE TABLE CORE.SENSOR_TAG (
    TAG_ID VARCHAR NOT NULL,
    ASSET_ID VARCHAR NOT NULL,
    COMPONENT_ID VARCHAR,
    TAG_SUFFIX VARCHAR NOT NULL,
    OBSERVED_PROPERTY VARCHAR NOT NULL,
    SOURCE_UNIT VARCHAR NOT NULL COMMENT 'Unit as reported by the historian',
    UNIT VARCHAR NOT NULL COMMENT 'Normalized unit after conversion in CORE.SENSOR_READING',
    VALID_MIN NUMBER(10,3), VALID_MAX NUMBER(10,3),
    EXPECTED_CADENCE_MIN NUMBER(5,1) DEFAULT 5,
    FRESHNESS_TOLERANCE_MIN NUMBER(5,1) DEFAULT 30,
    TAG_STATUS VARCHAR DEFAULT 'ACTIVE',
    SOURCE_SYSTEM VARCHAR DEFAULT 'HISTORIAN',
    CONSTRAINT PK_SENSOR_TAG PRIMARY KEY (TAG_ID)
) COMMENT = 'Sensor tags. SOURCE_UNIT differing from UNIT is what makes the unit-normalization check meaningful rather than decorative.';

-- ----------------------------------------------------------------------------
-- Seed: site, area, lines
-- ----------------------------------------------------------------------------
INSERT OVERWRITE INTO CORE.SITE VALUES
    ('PLANT-01', 'Pune Packaging Plant', 'Asia/Kolkata', 4200.00);

INSERT OVERWRITE INTO CORE.AREA VALUES
    ('PACKAGING', 'PLANT-01', 'Packaging Hall'),
    ('UTILITIES', 'PLANT-01', 'Utilities Block');

INSERT OVERWRITE INTO CORE.PRODUCTION_LINE VALUES
    ('PKG-L2', 'PACKAGING', 'PLANT-01', 'Packaging Line 2', 1.800, 'HIGH'),
    ('PKG-L1', 'PACKAGING', 'PLANT-01', 'Packaging Line 1', 2.100, 'MEDIUM');

-- ----------------------------------------------------------------------------
-- Seed: assets
--
-- P-204 is the hero: criticality A, HIGH quality consequence, the main product
-- transfer pump on the line the demo opens on. M-301..M-304 are AC_MOTOR, which the
-- demo bearing model does NOT cover -- that is deliberate, so the out-of-scope path
-- is exercised by a genuinely elevated motor (M-303) rather than by contrivance.
-- ----------------------------------------------------------------------------
INSERT OVERWRITE INTO CORE.ASSET
    (ASSET_ID, ASSET_NAME, ASSET_CLASS, LINE_ID, AREA_ID, SITE_ID, PARENT_ASSET_ID,
     MANUFACTURER, MODEL, INSTALL_DATE, CRITICALITY, CRITICALITY_SCORE,
     SAFETY_CONSEQUENCE, QUALITY_CONSEQUENCE, ENV_CONSEQUENCE, OPERATIONAL_STATUS, VALID_FROM, VALID_TO)
VALUES
    ('P-201','Filler Feed Pump 1','CENTRIFUGAL_PUMP','PKG-L2','PACKAGING','PLANT-01',NULL,'KSB','ETA-080',    '2021-04-12','B',0.60,'LOW',   'MEDIUM','LOW',   'RUNNING','2021-04-12',NULL),
    ('P-202','Filler Feed Pump 2','CENTRIFUGAL_PUMP','PKG-L2','PACKAGING','PLANT-01',NULL,'KSB','ETA-080',    '2021-04-12','B',0.60,'LOW',   'MEDIUM','LOW',   'RUNNING','2021-04-12',NULL),
    ('P-203','Capper Coolant Pump','CENTRIFUGAL_PUMP','PKG-L2','PACKAGING','PLANT-01',NULL,'Grundfos','NB-65','2020-09-30','C',0.35,'LOW',   'LOW',   'LOW',   'RUNNING','2020-09-30',NULL),
    ('P-204','Main Product Transfer Pump','CENTRIFUGAL_PUMP','PKG-L2','PACKAGING','PLANT-01',NULL,'KSB','ETA-125','2019-06-18','A',1.00,'MEDIUM','HIGH','MEDIUM','RUNNING','2019-06-18',NULL),
    ('P-205','CIP Supply Pump','CENTRIFUGAL_PUMP','PKG-L2','PACKAGING','PLANT-01',NULL,'Alfa Laval','LKH-25', '2022-01-20','B',0.60,'LOW',   'HIGH',  'MEDIUM','RUNNING','2022-01-20',NULL),
    ('P-206','Utility Water Pump','CENTRIFUGAL_PUMP','PKG-L1','PACKAGING','PLANT-01',NULL,'Grundfos','NB-50', '2020-03-05','C',0.35,'LOW',   'LOW',   'LOW',   'RUNNING','2020-03-05',NULL),
    ('M-301','Conveyor Drive Motor 1','AC_MOTOR','PKG-L2','PACKAGING','PLANT-01',NULL,'ABB','M3BP-160',      '2021-07-01','B',0.60,'LOW','MEDIUM','LOW','RUNNING','2021-07-01',NULL),
    ('M-302','Conveyor Drive Motor 2','AC_MOTOR','PKG-L2','PACKAGING','PLANT-01',NULL,'ABB','M3BP-160',      '2021-07-01','C',0.35,'LOW','LOW',   'LOW','RUNNING','2021-07-01',NULL),
    ('M-303','Shrink Wrapper Motor','AC_MOTOR','PKG-L2','PACKAGING','PLANT-01',NULL,'Siemens','1LE1-132',    '2022-11-14','B',0.60,'LOW','MEDIUM','LOW','RUNNING','2022-11-14',NULL),
    ('M-304','Palletiser Motor','AC_MOTOR','PKG-L1','PACKAGING','PLANT-01',NULL,'Siemens','1LE1-160',        '2020-08-22','C',0.35,'LOW','LOW','LOW','RUNNING','2020-08-22',NULL);

-- ----------------------------------------------------------------------------
-- Seed: components
--
-- Hero condition: P-204 drive-end bearing lubrication is overdue by exactly 120
-- operating hours against a 720-hour interval. Every other component sits inside its
-- interval, so the hero stands out for a reason a planner would recognise.
-- ----------------------------------------------------------------------------
INSERT OVERWRITE INTO CORE.COMPONENT
    (COMPONENT_ID, ASSET_ID, COMPONENT_TYPE, COMPONENT_NAME, IS_MAINTAINABLE,
     LAST_LUBRICATION_TS, LUBRICATION_INTERVAL_HOURS)
WITH ct AS (
    SELECT * FROM VALUES
        ('DRIVE_END_BEARING',     'Drive-end bearing'),
        ('NON_DRIVE_END_BEARING', 'Non-drive-end bearing'),
        ('COUPLING',              'Shaft coupling')
    AS t(COMPONENT_TYPE, COMPONENT_NAME)
)
SELECT
    a.ASSET_ID || '/' || ct.COMPONENT_TYPE,
    a.ASSET_ID,
    ct.COMPONENT_TYPE,
    a.ASSET_NAME || ' - ' || ct.COMPONENT_NAME,
    TRUE,
    CASE
      WHEN a.ASSET_ID = 'P-204' AND ct.COMPONENT_TYPE = 'DRIVE_END_BEARING'
        THEN DATEADD('hour', -(720 + 120), GOVERNANCE.CURRENT_AS_OF())
      ELSE DATEADD('hour', -(120 + (ABS(HASH(a.ASSET_ID, ct.COMPONENT_TYPE)) % 300)),
                   GOVERNANCE.CURRENT_AS_OF())
    END,
    CASE WHEN ct.COMPONENT_TYPE = 'COUPLING' THEN NULL ELSE 720.0 END
FROM CORE.ASSET a CROSS JOIN ct;

-- ----------------------------------------------------------------------------
-- Seed: sensor tags
--
-- P-206 and M-304 sit on an older historian that reports imperial units, so the
-- normalization step in CORE.SENSOR_READING has real work to do.
-- VALID_MIN/VALID_MAX are expressed in the NORMALIZED unit because the range check
-- runs after conversion.
--
-- VALID_MIN IS ZERO FOR VIBRATION AND CURRENT ON PURPOSE. A stopped machine
-- legitimately reads near-zero vibration and near-zero current, and roughly 48 such
-- readings per tag land inside every trailing-24h window because the demo clock sits
-- on a Sunday with a 02:00-06:00 planned stop. A 0.1 floor flagged all of them as
-- out-of-range and failed the data-quality gate for the entire fleet. The range check
-- exists to catch impossible values, not idle equipment. Unit/scaling faults are
-- caught by the UNITS and SCALE_PLAUSIBILITY checks instead.
-- ----------------------------------------------------------------------------
INSERT OVERWRITE INTO CORE.SENSOR_TAG
    (TAG_ID, ASSET_ID, COMPONENT_ID, TAG_SUFFIX, OBSERVED_PROPERTY,
     SOURCE_UNIT, UNIT, VALID_MIN, VALID_MAX, EXPECTED_CADENCE_MIN,
     FRESHNESS_TOLERANCE_MIN, TAG_STATUS, SOURCE_SYSTEM)
WITH tagdef AS (
    SELECT * FROM VALUES
        ('VIB_RMS_DE',    'VIBRATION_RMS', 'MM_S',  0.0, 45.0,  TRUE),
        ('TEMP_BRG_DE',   'BEARING_TEMP',  'DEG_C', 5.0, 140.0, TRUE),
        ('MOTOR_CURRENT', 'MOTOR_CURRENT', 'AMP',   0.0, 200.0, FALSE)
    AS t(TAG_SUFFIX, OBSERVED_PROPERTY, UNIT, VALID_MIN, VALID_MAX, ON_DRIVE_END)
)
SELECT
    a.ASSET_ID || '/' || d.TAG_SUFFIX,
    a.ASSET_ID,
    CASE WHEN d.ON_DRIVE_END THEN a.ASSET_ID || '/DRIVE_END_BEARING' END,
    d.TAG_SUFFIX,
    d.OBSERVED_PROPERTY,
    CASE
      WHEN a.ASSET_ID IN ('P-206','M-304') AND d.TAG_SUFFIX = 'VIB_RMS_DE'  THEN 'IN_S'
      WHEN a.ASSET_ID IN ('P-206','M-304') AND d.TAG_SUFFIX = 'TEMP_BRG_DE' THEN 'DEG_F'
      ELSE d.UNIT
    END,
    d.UNIT, d.VALID_MIN, d.VALID_MAX, 5, 30, 'ACTIVE', 'HISTORIAN'
FROM CORE.ASSET a CROSS JOIN tagdef d;

-- ----------------------------------------------------------------------------
-- Verification
-- ----------------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM CORE.ASSET)      AS assets,
    (SELECT COUNT(*) FROM CORE.COMPONENT)  AS components,
    (SELECT COUNT(*) FROM CORE.SENSOR_TAG) AS tags,
    (SELECT DATEDIFF('hour', LAST_LUBRICATION_TS, GOVERNANCE.CURRENT_AS_OF()) - LUBRICATION_INTERVAL_HOURS
       FROM CORE.COMPONENT WHERE COMPONENT_ID = 'P-204/DRIVE_END_BEARING') AS hero_lube_overdue_hours;
