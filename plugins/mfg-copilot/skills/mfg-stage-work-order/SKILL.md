---
name: mfg-stage-work-order
description: Approval collection and controlled work-order staging. Requires explicit role-appropriate human approval before the controlled write, then calls DECISION.STAGE_WORK_ORDER which re-validates everything at write time. Triggers: "approve", "stage work order", "draft the work order", "proceed with", "I approve", "reliability approves", "production approves".
---

# mfg-stage-work-order — Approval and Controlled Draft

## Step 1: Open the recommendation (if not already open)

```sql
CALL MFG_COPILOT_DB.DECISION.OPEN_RECOMMENDATION('<ASSET_ID>');
```

Note the returned `decision_id` and `decision_version`.

## Step 2: Collect approvals

The user must state which role they are approving as and which option they approve.
For each approval:

```sql
CALL MFG_COPILOT_DB.DECISION.RECORD_APPROVAL(
    '<DECISION_ID>', '<OPTION_ID>',
    '<APPROVER_ROLE>', '<APPROVER_NAME>', '<VERDICT>', '<REASON>');
```

At minimum, two distinct roles are required: `RELIABILITY_ENGINEER` and `PRODUCTION_SUPERVISOR`.
The safety gate may require additional roles (e.g., `EHS_OWNER` when an alarm is exceeded).

## Step 3: Preview before staging

Before calling the staging procedure, present a summary of what will be written:
- Decision ID and version
- Option being staged
- Asset, task, procedure, and proposed window
- Approvals on record
- Ask for explicit confirmation: "Shall I proceed with staging this draft?"

## Step 4: Stage the work order

```sql
CALL MFG_COPILOT_DB.DECISION.STAGE_WORK_ORDER(
    '<DECISION_ID>', '<OPTION_ID>',
    <DECISION_VERSION>, '<IDEMPOTENCY_KEY>');
```

The idempotency key format is `<decision_id>-<option_id>-v<version>`.

The procedure re-checks at write time:
- Evidence freshness → Safety gate → Approvals present → Part unreserved →
  Technician cert valid → Window authorized → Idempotency key unseen

If any check fails, the procedure returns a structured refusal and writes nothing.
Report the refusal verbatim — do not paraphrase or suppress it.

## Step 5: Confirm

```sql
SELECT DRAFT_ID, DECISION_ID, OPTION_ID, ASSET_ID, TASK_CODE,
       PROCEDURE_REF, PROPOSED_WINDOW_ID, STATUS, IDEMPOTENCY_KEY
FROM MFG_COPILOT_DB.DECISION.WORK_ORDER_OUTBOX
WHERE DECISION_ID = '<DECISION_ID>';
```

## What this skill does NOT do

- It does not release, dispatch, or assign work. That follows the site workflow.
- It does not return the asset to service. That requires site authorization.
- It does not control equipment. There is no object in the database for that.
