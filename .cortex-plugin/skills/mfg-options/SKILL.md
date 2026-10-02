---
name: "mfg-options"
description: >
  Checks constraints, generates ≤3 feasible maintenance options, runs the safety gate,
  and presents a decision card with the recommended action, alternatives, rejected
  options, and trade-offs. Safety gates precede cost ranking.

  Triggers: "what are my options", "recommend", "compare options", "maintenance plan",
  "is it feasible", "constraint check", "decision card", "challenge", "re-plan".
tools:
  - SnowflakeSqlExecute
user-invocable: true
version: "1.0.0"
author: "DataSuperHeros"
tags:
  - mfg
  - options
  - decision
---

# mfg-options — Constraint Check, Options, Safety, and Decision Card

## Before anything else

Read `.cortex-plugin/references/decision-contract.md`.

## Step 1: Evaluate options

```sql
SELECT OPTION_ID, ACTION, OPTION_RANK, IS_RECOMMENDED, IS_BOUNDED_SET,
       FEASIBLE, INFEASIBLE_REASON,
       TIMING, PROPOSED_WINDOW_ID, PROPOSED_WINDOW_START,
       REQUIRED_PARTS, PART_AVAILABLE, PART_LEAD_DAYS,
       REQUIRED_SKILLS, QUALIFIED_TECHNICIANS,
       PROCEDURE_REF, OPEN_CONFLICTS,
       RISK_REDUCTION_VALUE, MAINTENANCE_COST, ESTIMATED_NET_VALUE,
       VALUE_ASSUMPTIONS, ESTIMATE_TYPE
FROM TABLE(MFG_COPILOT_DB.DECISION.EVALUATE_MAINTENANCE_OPTIONS('<ASSET_ID>'))
ORDER BY FEASIBLE DESC, OPTION_RANK NULLS LAST;
```

## Step 2: Safety gate

```sql
SELECT GATE_CODE, VERDICT, REASON, REQUIRED_APPROVER_ROLES, ESCALATION_REF
FROM TABLE(MFG_COPILOT_DB.GOVERNANCE.CHECK_MAINTENANCE_SAFETY('<ASSET_ID>', '<TASK_CODE>'))
ORDER BY CASE VERDICT WHEN 'FAIL' THEN 1 WHEN 'REVIEW' THEN 2 ELSE 3 END;
```

**If any gate is FAIL:** stop economic optimization, return the escalation reference and the
accountable roles. Do NOT present a ranked option set. The only acceptable actions are
escalation, gathering evidence, or deferring to the site procedure.

## Step 3: Retrieve the current approved procedure

```sql
SELECT * FROM TABLE(MFG_COPILOT_DB.GOVERNANCE.RESOLVE_CURRENT_PROCEDURE('<TASK_CODE>', '<ASSET_CLASS>'));
```

If zero rows: the recommended action has no current approved procedure. Report this as a
hard constraint failure. Do not cite a superseded version as a substitute.

## Step 4: Retrieve document evidence (optional, for the recommended option)

Use Cortex Search with filters:
```sql
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
  'MFG_COPILOT_DB.SEMANTIC.MAINTENANCE_MANUAL_SEARCH',
  '{"query": "<relevant query>",
    "columns": ["PROCEDURE_REF","STATUS","TRUST_LEVEL","SECTION","CHUNK_TEXT"],
    "filter": {"@and": [{"@eq": {"STATUS": "CURRENT"}}, {"@eq": {"TRUST_LEVEL": "APPROVED"}}]},
    "limit": 5}'
);
```

**Always filter STATUS = 'CURRENT' and TRUST_LEVEL = 'APPROVED'.** Without the filter,
the superseded SOP-BRG-17-v3 ranks first for bearing replacement questions and its
guidance contradicts the current version.

## Step 5: Present the decision card

Present every field required by `references/decision-contract.md`. For the demo, the key
fields to highlight:

1. **Recommended action** with timing and proposed window.
2. **Why now** — cited evidence (vibration elevation, temperature, lubrication overdue).
3. **Confidence** — failure probability, RUL range, model version, ESTIMATE_TYPE.
4. **Alternatives** — at least two other feasible options with their trade-offs.
5. **Rejected options** — each with its deterministic infeasible reason.
6. **Approval** — required roles and current state.
7. **Next step** — approve, modify, inspect evidence, or reject with reason.

## Challenge / re-plan

When the user adds a constraint (e.g., "the line cannot stop before Friday"):

1. Call `GOVERNANCE.SET_SCENARIO` if appropriate, or just re-evaluate options.
2. Re-run `EVALUATE_MAINTENANCE_OPTIONS` — the overlay-aware views will produce
   different feasibility results.
3. If no safe option exists under the new constraint, **say so explicitly** rather than
   inventing one. "No safe feasible option exists under the stated constraint" is a
   correct answer.
