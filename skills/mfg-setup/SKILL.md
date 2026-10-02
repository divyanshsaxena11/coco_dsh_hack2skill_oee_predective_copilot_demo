---
name: mfg-setup
description: Idempotent deployment of the Manufacturing OEE & Maintenance Decision Copilot into a Snowflake account. Runs all sql/*.sql files in order and verifies the result. Triggers: "deploy", "setup", "install", "redeploy", "mfg-setup".
---

# mfg-setup — Deploy the Manufacturing Copilot

## Workflow

1. Read `AGENTS.md` and confirm you are not creating any equipment-control object.
2. Check the Snowflake connection:
   ```sql
   SELECT CURRENT_ACCOUNT() AS account, CURRENT_ROLE() AS role, CURRENT_WAREHOUSE() AS wh;
   ```
3. Run the deploy script:
   ```bash
   cd /Users/divyanshsaxena/Documents/projects/local-setup/tredence/tredence-mfg-copilot
   ./sql/deploy.sh HACK2SKILL_DEMO
   ```
   If resuming from a specific file, pass the prefix: `./sql/deploy.sh HACK2SKILL_DEMO 60`
4. Verify the deployment:
   ```sql
   SELECT CURRENT_ACCOUNT() AS acct,
          MFG_COPILOT_DB.GOVERNANCE.ACTIVE_SCENARIO() AS scenario,
          MFG_COPILOT_DB.GOVERNANCE.CURRENT_AS_OF() AS as_of,
          (SELECT COUNT(*) FROM MFG_COPILOT_DB.INFORMATION_SCHEMA.TABLES
           WHERE TABLE_SCHEMA NOT IN ('INFORMATION_SCHEMA')) AS total_objects;
   ```
5. Run the plant-control gate self-test:
   ```bash
   node .cortex-plugin/hooks/gate-test.js
   ```
6. Report the result: object count, demo clock value, active scenario, and gate test status.

## What you must not create

No PLC, SCADA, DCS, setpoint, interlock, command-queue, dispatch, or return-to-service
object. The schema list in `01_roles_and_schemas.sql` is CLOSED and that absence is the
strongest safety boundary.
