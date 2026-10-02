---
name: mfg-outcome
description: Records the technician finding and closes the decision loop. Preserves CONFIRMED vs NO_FAULT_FOUND distinctly. Updates the KPI context. Triggers: "record outcome", "technician found", "close the loop", "bearing was", "inspection result", "no fault found".
---

# mfg-outcome — Record Maintenance Outcome

## Step 1: Collect the finding

Ask the user for:
- **FINDING_STATE**: `CONFIRMED`, `REFUTED`, or `NO_FAULT_FOUND`
- **FAILURE_CODE**: e.g., `BRG-SPALL`, `BRG-LUBE`, or NULL if no fault found
- **REMEDY**: what was done
- **DURATION_MIN**: actual work duration
- **PARTS_USED**: e.g., `BRG-6312-C3` or NULL
- **POST_READING**: JSON with post-work vibration and temperature, e.g.,
  `{"vib_rms_de_mm_s": 2.4, "temp_brg_de_c": 48.5}`

## Step 2: Record the outcome

```sql
CALL MFG_COPILOT_DB.DECISION.RECORD_OUTCOME(
    '<DECISION_ID>', '<FINDING_STATE>',
    '<FAILURE_CODE>', '<REMEDY>',
    <DURATION_MIN>, '<PARTS_USED>', '<POST_READING_JSON>');
```

## Step 3: Verify the audit trail is complete

```sql
SELECT EVENT_TYPE, ACTOR, ACTOR_ROLE, EVENT_TS
FROM MFG_COPILOT_DB.AUDIT.DECISION_AUDIT
WHERE DECISION_ID = '<DECISION_ID>'
ORDER BY EVENT_TS;
```

The trail should show:
`RECOMMENDATION_CREATED → APPROVAL(s) → WORK_ORDER_STAGED → OUTCOME_RECORDED`

## Step 4: Report the closed loop

State:
1. The original fault hypothesis and whether it was confirmed, refuted, or not found.
2. The actual remedy and duration.
3. The post-work readings and how they compare to the pre-work condition.
4. Whether the decision was a true positive (confirmed) or a false alarm (no fault found).

**NO_FAULT_FOUND is a valid and useful outcome.** It must be reported, not hidden or
reclassified. An honest track record includes the times the prediction did not pan out.
