---
name: mfg-demo
description: Demo runbook driver, scenario flipper, and test scoreboard. Walks the 11-beat demo, flips scenarios live, and runs the M0-M7 test suite. Triggers: "run the demo", "demo", "flip scenario", "set scenario", "reset", "test suite", "M2", "M3", "M5", "stale data", "no part".
---

# mfg-demo — Demo Driver and Scenario Flipper

## Scenario management

List available scenarios:
```sql
SELECT SCENARIO_CODE, TITLE, EXPECTED_BEHAVIOUR
FROM MFG_COPILOT_DB.GOVERNANCE.SCENARIO_CATALOGUE
ORDER BY SCENARIO_CODE;
```

Flip a scenario:
```sql
CALL MFG_COPILOT_DB.GOVERNANCE.SET_SCENARIO('<SCENARIO_CODE>');
```

Reset to the default hero story:
```sql
CALL MFG_COPILOT_DB.GOVERNANCE.RESET_SCENARIO();
```

**Always announce the active scenario before answering any question.** The same question
produces different answers under different scenarios — that is the point of the demo — and
not announcing the scenario makes the difference look like instability.

**Always reset to M1_HIGH_RISK after demonstrating a negative scenario.**

## The 11-beat demo runbook

| Beat | User prompt | Expected demonstration |
|---|---|---|
| 1 | "Why is OEE deteriorating on Packaging Line 2?" | Governed decomposition: availability −5.8pp dominant, 14 min downtime |
| 2 | "Which assets require attention this week?" | P-204 first (0.817, RUL 7-12d), M-303 held out of scope, P-205 data-unusable |
| 3 | "Validate the condition data for P-204" | All 8 checks PASS |
| 4 | "Show me the ontology neighbourhood for P-204" | 5-hop chain: LossEvent→Asset→Component→FaultMode→Task→Part/Skill/Procedure |
| 5 | "What are my maintenance options for P-204?" | OPT-INSPECT recommended, decision card with contract |
| 6 | "Compare the options and show the trade-offs" | 3 bounded feasible + defer + evidence; rejected shows reason |
| 7 | "The line cannot stop before Friday. Re-plan." | `SET_SCENARIO('M4_WINDOW_CONFLICT')` then re-evaluate |
| 8 | *Make vibration data stale* | `SET_SCENARIO('M2_STALE_DATA')` → copilot abstains, requests fresh evidence |
| 9 | "Reliability and production approve OPT-INSPECT" | Two RECORD_APPROVAL calls, then preview |
| 10 | "Stage the work order" | STAGE_WORK_ORDER, verify exactly one draft, test duplicate |
| 11 | "Technician found spalling, replaced the bearing" | RECORD_OUTCOME with CONFIRMED, post-work readings, complete audit trail |

## Three moments that decide the judging

1. **`SET_SCENARIO('M3_NO_PART')`** → same question, different recommendation. Part gone.
2. **`SET_SCENARIO('M2_STALE_DATA')`** → copilot refuses to recommend. Fails closed.
3. **Direct `INSERT INTO DECISION.WORK_ORDER_OUTBOX`** → blocked by the hook with rule cited.

## Running the gate test

```bash
cd /Users/divyanshsaxena/Documents/projects/local-setup/tredence/tredence-mfg-copilot
node .cortex-plugin/hooks/gate-test.js
```

Expected: 35/35 cases passed.
