---
name: "mfg-oee-loss"
description: >
  Governed OEE decomposition and credible-risk ranking. Explains which factor
  drove the loss, which stops overlap the window, and which assets carry the
  highest triage priority — without upgrading correlation to a confirmed cause.

  Triggers: "why is OEE deteriorating", "OEE loss", "which factor", "fleet triage",
  "which assets need attention", "what caused the downtime".
tools:
  - SnowflakeSqlExecute
user-invocable: true
version: "1.0.0"
author: "DataSuperHeros"
tags:
  - mfg
  - oee
---

# mfg-oee-loss — OEE Loss Decomposition and Fleet Triage

## Before anything else

Read `AGENTS.md` §2 (time discipline) and §5 (evidence and epistemic honesty).

## Step 1: Decompose OEE

```sql
SELECT * FROM SEMANTIC_VIEW(
  MFG_COPILOT_DB.SEMANTIC.MAINTENANCE_DECISION_SV
  DIMENSIONS lines.line_id, oee_intervals.shift_code
  METRICS oee_intervals.availability, oee_intervals.performance, oee_intervals.quality,
          oee_intervals.oee, oee_intervals.unplanned_downtime_min
)
WHERE line_id = '<LINE_ID>'
ORDER BY shift_code;
```

Identify the **dominant loss factor** (availability, performance, or quality) by comparing
each factor against its trailing baseline. Report the delta in percentage points.

## Step 2: Examine the stops in the loss window

```sql
SELECT * FROM SEMANTIC_VIEW(
  MFG_COPILOT_DB.SEMANTIC.MAINTENANCE_DECISION_SV
  DIMENSIONS downtime_events.reason_code, downtime_events.assoc_method,
             downtime_events.associated_asset, downtime_events.is_planned
  METRICS downtime_events.stop_minutes, downtime_events.stop_count
)
WHERE line_id = '<LINE_ID>'
ORDER BY stop_minutes DESC;
```

**ASSOC_METHOD matters more than the association itself.**
- `OPERATOR_CONFIRMED` may be described as an established cause.
- `TIME_OVERLAP` is correlation only. Never upgrade it.
- `UNKNOWN` must remain visible as its own category. Never redistribute unknown minutes
  across known reasons.

## Step 3: Rank the fleet

```sql
SELECT ASSET_ID, CRITICALITY, TRIAGE_LANE, DQ_VERDICT, FAILED_CHECKS,
       FAILURE_PROBABILITY, PCT_ABOVE_BASELINE, RUL_LOW_DAYS, RUL_HIGH_DAYS,
       PRIORITY_SCORE, ESTIMATE_TYPE, IN_SCOPE, SCORE_EXPLANATION
FROM MFG_COPILOT_DB.AI.ASSET_HEALTH_SNAPSHOT
WHERE LINE_ID = '<LINE_ID>'
ORDER BY PRIORITY_SCORE DESC NULLS LAST, ASSET_ID;
```

- Assets with `DQ_VERDICT = 'FAIL'` or `IN_SCOPE = FALSE` carry **no priority score** and
  must not be ranked against scored assets. Show them in a separate section.
- Every probability and RUL value must be accompanied by `ESTIMATE_TYPE`.
- Cite `SCORE_EXPLANATION` when presenting the top-ranked asset.

## Step 4: Present the result

For each significant finding:
1. State the OEE factor, the delta, and the calculation version.
2. List the stops with their reason codes and association methods.
3. List the ranked assets with their triage lane and key risk numbers.
4. State `as_of` from `GOVERNANCE.CURRENT_AS_OF()`.
5. Flag any asset whose data is stale or out of model scope.

Do not assert causality beyond what `ASSOC_METHOD` supports. If the dominant loss
is availability and the most credible asset risk is only a `TIME_OVERLAP` association,
say so explicitly rather than presenting them as one story.
