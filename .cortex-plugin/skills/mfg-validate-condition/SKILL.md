---
name: "mfg-validate-condition"
description: >
  Deterministic data-quality gate for one asset. Reports freshness, gaps, units,
  range, scale plausibility, flatline, tag health, and operating-state comparability.
  Fails closed: if mandatory evidence is unusable, the copilot must abstain.

  Triggers: "validate", "data quality", "is the data trustworthy", "check freshness",
  "can I trust the readings".
tools:
  - SnowflakeSqlExecute
user-invocable: true
version: "1.0.0"
author: "DataSuperHeros"
tags:
  - mfg
  - data-quality
---

# mfg-validate-condition — Data Quality Gate

## Workflow

1. Call the deterministic function:
   ```sql
   SELECT * FROM TABLE(MFG_COPILOT_DB.GOVERNANCE.VALIDATE_SENSOR_CONTEXT('<ASSET_ID>'));
   ```

2. Report every check, its status, the observed value, and the threshold.

3. Get the collapsed verdict:
   ```sql
   SELECT * FROM MFG_COPILOT_DB.GOVERNANCE.SENSOR_CONTEXT_VERDICT WHERE ASSET_ID = '<ASSET_ID>';
   ```

4. **If the overall verdict is FAIL:**
   - State explicitly that condition-based recommendations are NOT available for this asset.
   - List the failing checks and what each means in practical terms.
   - Recommend: restore telemetry, or perform a manual inspection.
   - Do NOT report a risk score, RUL, or failure probability for a FAIL asset.
   - Missing telemetry is `UNKNOWN`, never `HEALTHY`.

5. **If the overall verdict is REVIEW:**
   - State which checks are in review status.
   - The model output may be used with caution and a reliability engineer should verify.

6. **If the overall verdict is PASS:**
   - Proceed normally. State that condition data passes all checks as of `CURRENT_AS_OF()`.

## This skill does NOT assess asset health

This skill answers "is the data trustworthy", not "is the asset healthy". Health assessment
uses `AI.GET_ASSET_RISK` and belongs in `mfg-copilot` stage 4. If the user asks about
health, redirect to the orchestrator.
