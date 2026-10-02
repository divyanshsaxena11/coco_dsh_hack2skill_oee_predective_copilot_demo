/**
 * Gate self-test. Run: node .cortex-plugin/hooks/gate-test.js
 *
 * Verifies the plant-control gate blocks what AGENTS.md prohibits and allows the
 * legitimate deploy/read/call traffic the project needs. Cases are defined in JS so
 * shell quoting cannot distort the SQL under test.
 */

const { execFileSync } = require("child_process");
const path = require("path");

const GATE = path.join(__dirname, "plant-control-gate.js");

const cases = [
  // --- must be ALLOWED ---
  ["allow", "SELECT * FROM CORE.ASSET WHERE ASSET_ID = 'P-204'"],
  ["allow", "WITH x AS (SELECT 1) SELECT * FROM x"],
  ["allow", "SHOW TABLES IN SCHEMA MFG_COPILOT_DB.CORE"],
  ["allow", "CREATE OR REPLACE TABLE AUDIT.DECISION_AUDIT (X INT)"],
  ["allow", "CREATE OR REPLACE TABLE DECISION.WORK_ORDER_OUTBOX (X INT)"],
  ["allow", "INSERT INTO AUDIT.DECISION_AUDIT (X) VALUES (1)"],
  ["allow", "INSERT INTO DECISION.APPROVAL_EVENT (X) VALUES (1)"],
  ["allow", "CALL DECISION.STAGE_WORK_ORDER('MNT-1','OPT-02',1,'k1')"],
  ["allow", "CALL GOVERNANCE.SET_SCENARIO('M2_STALE_DATA')"],
  ["allow", "GRANT USAGE ON SCHEMA CORE TO ROLE MFG_RELIABILITY_ENGINEER"],
  ["allow", "SELECT REQUIRED_RESPONSE FROM GOVERNANCE.SAFETY_LIMIT"],
  // a row value that merely mentions a prohibited word is data, not an action
  ["allow", "INSERT INTO GOVERNANCE.SAFETY_LIMIT (RESP) VALUES ('Follow LOTO interlock checklist and do not bypass')"],
  // a procedure body is dollar-quoted and therefore opaque to the gate
  ["allow", "CREATE OR REPLACE PROCEDURE DECISION.STAGE_WORK_ORDER() RETURNS STRING LANGUAGE SQL AS $$ BEGIN INSERT INTO DECISION.WORK_ORDER_OUTBOX SELECT 1; END; $$"],
  ["allow", "-- UPDATE GOVERNANCE.SAFETY_LIMIT SET TRIP_VALUE = 999\nSELECT 1"],

  // --- must be BLOCKED: equipment control ---
  ["block", "CALL PLC_WRITE_SETPOINT('P-204', 0)"],
  ["block", "SELECT * FROM SCADA_TAG_WRITE"],
  ["block", "CALL MFG.STOP_ASSET('P-204')"],
  ["block", "CALL SHUTDOWN_ASSET('P-204')"],
  ["block", "UPDATE ASSET_SETPOINT SET VALUE = 0"],
  ["block", "CALL BYPASS_INTERLOCK('LOTO-PUMP-03')"],
  ["block", "CALL DERATE_ASSET('P-204', 60)"],
  ["block", "CALL RESET_TRIP('P-204')"],
  ["block", "CALL RELEASE_WORK_ORDER('WO-1')"],
  ["block", "CALL RETURN_TO_SERVICE('P-204')"],
  ["block", "INSERT INTO ASSET_CMD_QUEUE VALUES ('P-204','STOP')"],

  // --- must be BLOCKED: controlled-write bypass ---
  ["block", "INSERT INTO DECISION.WORK_ORDER_OUTBOX (ID) VALUES (1)"],
  ["block", "MERGE INTO DECISION.WORK_ORDER_OUTBOX t USING s ON t.id=s.id WHEN MATCHED THEN UPDATE SET t.a=s.a"],
  ["block", "DELETE FROM DECISION.WORK_ORDER_OUTBOX"],

  // --- must be BLOCKED: immutable / master-data-governed ---
  ["block", "UPDATE GOVERNANCE.SAFETY_LIMIT SET TRIP_VALUE = 999"],
  ["block", "DELETE FROM AUDIT.DECISION_AUDIT WHERE 1=1"],
  ["block", "TRUNCATE TABLE DECISION.APPROVAL_EVENT"],
  ["block", "UPDATE DECISION.MAINTENANCE_RECOMMENDATION SET STATE = 'APPROVED'"],
  ["block", "UPDATE GOVERNANCE.PROCEDURE_METADATA SET STATUS = 'CURRENT'"],
  ["block", "DROP TABLE AUDIT.DECISION_AUDIT"],

  // --- must be BLOCKED: out-of-scope destructive ---
  ["block", "DROP DATABASE SAP_DEMO_DB"],
];

let pass = 0;
const failures = [];

for (const [expected, sql] of cases) {
  const payload = JSON.stringify({
    tool_name: "snowflake_sql_execute",
    tool_input: { sql },
  });
  const out = execFileSync("node", [GATE], { input: payload, encoding: "utf8" });
  const actual = JSON.parse(out).decision;
  if (actual === expected) {
    pass++;
  } else {
    failures.push({ expected, actual, sql });
  }
}

console.log(`Plant Control Gate: ${pass}/${cases.length} cases passed`);
if (failures.length) {
  console.log("\nFAILURES:");
  for (const f of failures) {
    console.log(`  expected=${f.expected} actual=${f.actual}\n    ${f.sql.replace(/\n/g, " ")}`);
  }
  process.exit(1);
}
