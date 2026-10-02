/**
 * Manufacturing OEE & Maintenance Decision Copilot
 * PreToolUse hook — Plant Control Boundary Gate
 *
 * WHY THIS EXISTS
 * ---------------
 * A prompt is not a security boundary. AGENTS.md tells the model never to control
 * equipment and never to write directly to the controlled outbox, but instructions can be
 * forgotten, argued with, or injected around. This hook enforces the same rules outside
 * the model, on every SQL statement the agent tries to execute.
 *
 * It is the second of three boundaries:
 *   1. Absence  — no PLC/SCADA/setpoint/interlock object exists in MFG_COPILOT_DB at all.
 *   2. This gate — blocks the SQL shapes that would reach one, or bypass a controlled write.
 *   3. RBAC     — persona roles hold USAGE on procedures, never INSERT on the outbox.
 *
 * Blocked:
 *   - Any statement referencing an equipment-control surface.
 *   - Direct DML on DECISION.WORK_ORDER_OUTBOX (must go through DECISION.STAGE_WORK_ORDER).
 *   - UPDATE / DELETE / TRUNCATE / DROP on append-only or master-data-governed tables.
 *
 * Allowed:
 *   - Reads of every table, including the ones above.
 *   - CREATE OR REPLACE during deployment.
 *   - INSERT into append-only tables (that is how append-only works).
 *   - CALL of the controlled DECISION procedures.
 *
 * Every block is appended to hooks/gate-log.jsonl so the demo can show the gate firing.
 */

const fs = require("fs");
const path = require("path");

const GATE_LOG = path.join(__dirname, "gate-log.jsonl");

/**
 * Equipment-control surfaces. Referencing any of these is prohibited outright.
 *
 * Matched against the TOKENIZED form of the statement, in which every run of
 * non-alphanumeric characters becomes a single space. That is deliberate: `\b` treats `_`
 * as a word character, so /\bPLC\b/ would NOT match `PLC_WRITE_SETPOINT` and the gate
 * would wave through exactly the call it exists to stop. Tokenizing first turns that
 * identifier into `PLC WRITE SETPOINT`, where the word boundaries are real.
 */
const CONTROL_SURFACE_PATTERNS = [
  /\bPLC\b/,
  /\bSCADA\b/,
  /\bDCS\b/,
  /\bSETPOINT\b/,
  /\bSET POINT\b/,
  /\bINTERLOCK\b/,
  /\bDERATE\b/,
  /\bHISTORIAN WRITE\b/,
  /\bWRITE TAG\b/,
  /\bTAG WRITE\b/,
  /\bCONTROL WRITE\b/,
  /\bSEND COMMAND\b/,
  /\bISSUE COMMAND\b/,
  /\bTRIP RESET\b/,
  /\bRESET TRIP\b/,
  /\bBYPASS\b/,
  /\bFORCE OUTPUT\b/,
  /\bSTART ASSET\b/,
  /\bSTOP ASSET\b/,
  /\bSHUTDOWN\b/,
  /\bRESTART ASSET\b/,
  /\bRELEASE WORK ORDER\b/,
  /\bRETURN TO SERVICE\b/,
  /\bDISPATCH WORK\b/,
  /\bCMD\b/,
];

/**
 * Tables that may only be written through a controlled procedure.
 * Any INSERT / UPDATE / DELETE / MERGE naming these is blocked.
 */
const CONTROLLED_WRITE_TABLES = [
  { name: "WORK_ORDER_OUTBOX", procedure: "DECISION.STAGE_WORK_ORDER" },
];

/**
 * Append-only and master-data-governed tables.
 * INSERT is fine. UPDATE / DELETE / TRUNCATE / DROP are not.
 */
const IMMUTABLE_TABLES = [
  { name: "DECISION_AUDIT", reason: "AGENTS.md §9 — the audit trail is append-only." },
  { name: "APPROVAL_EVENT", reason: "AGENTS.md §7 — approvals are append-only; supersede, never edit." },
  { name: "TOOL_CALL_LOG", reason: "AGENTS.md §9 — tool-call log is append-only." },
  { name: "MAINTENANCE_RECOMMENDATION", reason: "AGENTS.md §7 — recommendations are versioned, never overwritten." },
  { name: "MAINTENANCE_OUTCOME", reason: "AGENTS.md §7 — recorded outcomes are immutable." },
  { name: "SAFETY_LIMIT", reason: "AGENTS.md §8 — safety limits change only via the controlled master-data workflow." },
  { name: "PROCEDURE_METADATA", reason: "AGENTS.md §8 — procedure status/version changes only via the controlled master-data workflow." },
  { name: "PART_COMPATIBILITY", reason: "AGENTS.md §8 — BOM compatibility changes only via the controlled master-data workflow." },
  { name: "EMPLOYEE_AUTHORITY", reason: "AGENTS.md §8 — authority matrix changes only via the controlled master-data workflow." },
];

/** Strip comments and string literals so a payload inside quotes cannot trigger a match,
 *  and a commented-out keyword cannot either. Collapse whitespace for stable matching.
 *  Literals are stripped BEFORE keyword matching so that a row value like 'Follow the LOTO
 *  interlock checklist' does not read as an attempt to touch an interlock. */
function normalize(sql) {
  return sql
    .replace(/--[^\n]*/g, " ")            // line comments
    .replace(/\/\*[\s\S]*?\*\//g, " ")    // block comments
    .replace(/\$\$[\s\S]*?\$\$/g, " '' ") // dollar-quoted bodies (procedure definitions)
    .replace(/'(?:[^']|'')*'/g, " '' ")   // single-quoted literals
    .replace(/\s+/g, " ")
    .toUpperCase()
    .trim();
}

/** Collapse every non-alphanumeric run to a space so `\b` boundaries behave on identifiers
 *  like PLC_WRITE_SETPOINT, ASSET.CMD, or "STOP-ASSET". */
function tokenize(normalizedSql) {
  return normalizedSql.replace(/[^A-Z0-9]+/g, " ").trim();
}

function isReadOnly(sql) {
  return /^(SELECT|WITH|SHOW|DESC|DESCRIBE|EXPLAIN|LIST|GET)\b/.test(sql);
}

/** Which DML verb, if any, is this statement? */
function dmlVerb(sql) {
  const m = sql.match(/^(INSERT|UPDATE|DELETE|MERGE|TRUNCATE|DROP|CREATE|ALTER|CALL|GRANT|REVOKE|USE|PUT|COPY|BEGIN|COMMIT|ROLLBACK|SET|EXECUTE)\b/);
  return m ? m[1] : null;
}

/** Does the statement reference this table name as a DML target (not merely in a subquery)? */
function referencesTable(sql, table) {
  return new RegExp(`\\b${table}\\b`).test(sql);
}

function decide(sql) {
  const verb = dmlVerb(sql);
  const tokens = tokenize(sql);

  // 1. Equipment-control surfaces — prohibited in any statement, read or write.
  //    There is nothing legitimate to select from a setpoint table that does not exist.
  for (const pattern of CONTROL_SURFACE_PATTERNS) {
    if (pattern.test(tokens)) {
      return {
        decision: "block",
        rule: "PLANT_CONTROL_BOUNDARY",
        message:
          `Plant Control Gate: BLOCKED. This statement references an equipment-control surface ` +
          `(matched ${pattern}). AGENTS.md §8 prohibits any command to a PLC, SCADA, DCS, drive, or ` +
          `interlock, and any shutdown, restart, derate, bypass, maintenance release, work dispatch, ` +
          `or return-to-service action.\n\n` +
          `No such object exists in MFG_COPILOT_DB by design. The copilot advises accountable humans ` +
          `and prepares execution artifacts; it never takes control of the plant.\n\n` +
          `If a configured limit has been breached, return the escalation reference from ` +
          `GOVERNANCE.SAFETY_LIMIT instead. Do not invent a safe operating instruction.`,
      };
    }
  }

  if (isReadOnly(sql)) {
    return { decision: "allow" };
  }

  // 2. Controlled-write tables — writes must go through the procedure that revalidates.
  if (verb && ["INSERT", "UPDATE", "DELETE", "MERGE", "TRUNCATE"].includes(verb)) {
    for (const t of CONTROLLED_WRITE_TABLES) {
      if (referencesTable(sql, t.name)) {
        return {
          decision: "block",
          rule: "CONTROLLED_WRITE_BYPASS",
          message:
            `Plant Control Gate: BLOCKED. Direct ${verb} on ${t.name} is prohibited.\n\n` +
            `AGENTS.md §7 requires every controlled write to go through ${t.procedure}, which ` +
            `re-checks evidence freshness, the safety gate, required approvals, part availability, ` +
            `technician certification, and window authorization at write time, then applies the ` +
            `idempotency key.\n\n` +
            `A direct INSERT would bypass all of it. Call the procedure instead:\n` +
            `  CALL ${t.procedure}(<decision_id>, <option_id>, <expected_version>, <idempotency_key>);`,
        };
      }
    }
  }

  // 3. Append-only / master-data-governed tables.
  if (verb && ["UPDATE", "DELETE", "TRUNCATE", "DROP"].includes(verb)) {
    for (const t of IMMUTABLE_TABLES) {
      if (referencesTable(sql, t.name)) {
        return {
          decision: "block",
          rule: "IMMUTABLE_RECORD",
          message:
            `Plant Control Gate: BLOCKED. ${verb} on ${t.name} is prohibited.\n\n` +
            `${t.reason}\n\n` +
            `Append a superseding row instead, or use the controlled procedure for this object. ` +
            `If you are redeploying the project, CREATE OR REPLACE is permitted; ` +
            `${verb} against live records is not.`,
        };
      }
    }
  }

  // 4. Unqualified destructive statements outside this project's namespace.
  if (verb === "DROP" && /\bDROP\s+(DATABASE|SCHEMA)\b/.test(sql) && !/MFG_COPILOT_DB/.test(sql)) {
    return {
      decision: "block",
      rule: "OUT_OF_SCOPE_DESTRUCTIVE",
      message:
        `Plant Control Gate: BLOCKED. This statement drops a database or schema outside ` +
        `MFG_COPILOT_DB. This project only ever creates objects inside MFG_COPILOT_DB. ` +
        `Confirm with the user before touching anything else in the account.`,
    };
  }

  return { decision: "allow" };
}

function logBlock(entry) {
  try {
    fs.appendFileSync(GATE_LOG, JSON.stringify(entry) + "\n", "utf8");
  } catch (_) {
    // Never let logging failure change the gate verdict.
  }
}

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { input += chunk; });
process.stdin.on("end", () => {
  try {
    const event = JSON.parse(input);
    const toolName = event.tool_name || "";
    const params = event.tool_input || {};

    if (toolName !== "SnowflakeSqlExecute" && toolName !== "snowflake_sql_execute") {
      process.stdout.write(JSON.stringify({ decision: "allow" }));
      process.exit(0);
    }

    const raw = params.sql || "";
    const sql = normalize(raw);
    const verdict = decide(sql);

    if (verdict.decision === "block") {
      logBlock({
        ts: new Date().toISOString(),
        rule: verdict.rule,
        sql: raw.slice(0, 600),
      });
      process.stdout.write(JSON.stringify({
        decision: "block",
        message: verdict.message,
      }));
      process.exit(0);
    }

    process.stdout.write(JSON.stringify({ decision: "allow" }));
    process.exit(0);
  } catch (err) {
    // Fail open on a malformed event rather than deadlocking the session. The other two
    // boundaries (absence of control objects, RBAC) still hold.
    process.stdout.write(JSON.stringify({ decision: "allow" }));
    process.exit(0);
  }
});
