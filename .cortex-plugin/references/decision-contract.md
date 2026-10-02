# Maintenance Decision Contract

Canonical response shape. Any answer that recommends an action must satisfy this, even when
presented conversationally. **The model may narrate the contract. It may not populate a
policy-critical field itself** — those come from the functions named in the Source column.

## Fields

| Field | Source | Notes |
|---|---|---|
| `decision_id` | `DECISION.OPEN_RECOMMENDATION` | Stable, idempotent |
| `decision_version` | `DECISION.OPEN_RECOMMENDATION` | Increments on re-evaluation; prior versions preserved |
| `decision_type` | literal | `MAINTENANCE_PLAN` |
| `subject` | `CORE.ASSET` / `CORE.PRODUCTION_LINE` | Only what the caller's role may see |
| `as_of` | `GOVERNANCE.CURRENT_AS_OF()` | Never `CURRENT_TIMESTAMP()` |
| `objective` | skill | Business outcome being optimized |
| `recommended_action` | `DECISION.EVALUATE_MAINTENANCE_OPTIONS` | Must be one of the returned feasible options |
| `deadline_or_timing` | `DECISION.EVALUATE_MAINTENANCE_OPTIONS` | When the action stops being useful |
| `why_now` | evidence rows | Concise, each clause cited |
| `data_quality_and_safety_checks` | `GOVERNANCE.VALIDATE_SENSOR_CONTEXT` + `GOVERNANCE.CHECK_MAINTENANCE_SAFETY` | `PASS` / `FAIL` / `REVIEW` with reason |
| `expected_impact` | `DECISION.EVALUATE_MAINTENANCE_OPTIONS` | Estimate, units, assumptions, method |
| `confidence` | `AI.GET_ASSET_RISK` | Score/band + model version + `estimate_type` |
| `alternatives` | `DECISION.EVALUATE_MAINTENANCE_OPTIONS` | Includes no-action and gather-more-evidence |
| `rejected_options` | `DECISION.EVALUATE_MAINTENANCE_OPTIONS` | Option + deterministic `infeasible_reason` |
| `data_gaps` | `GOVERNANCE.VALIDATE_SENSOR_CONTEXT` | Stale, missing, contradictory, out-of-scope |
| `approval` | `GOVERNANCE.CHECK_MAINTENANCE_SAFETY` | Required roles, state, reason |
| `next_step` | skill | approve / modify / reject / inspect evidence / gather data |
| `evidence_refs` | `DECISION.EVIDENCE_REF` | Rows and documents with observation timestamps |

## Template

```yaml
decision_id: MNT-20260913-00031
decision_version: 1
decision_type: MAINTENANCE_PLAN
subject:
  asset: P-204
  component: DRIVE_END_BEARING
  line: PKG-L2
as_of: 2026-09-13T08:45:00
objective: Reduce failure exposure without unnecessary production disruption

recommended_action:
  option_id: OPT-02
  action: INSPECT_THEN_CONDITIONAL_REPLACE
  inspection_deadline: WITHIN_24_HOURS
  proposed_window: 2026-09-15T14:00:00/2026-09-15T16:00:00

fault_hypothesis:
  mode: DRIVE_END_BEARING_DEGRADATION
  state: UNCONFIRMED          # UNCONFIRMED | CONFIRMED | REFUTED

why_now:
  - claim: Vibration RMS 38% above comparable-state baseline for 45 minutes
    evidence_ref: EV-0001
  - claim: Bearing temperature 9 C above comparable-state baseline, below configured trip
    evidence_ref: EV-0002
  - claim: Lubrication overdue by 120 operating hours
    evidence_ref: EV-0003

confidence:
  failure_probability_72h: 0.82
  rul_range_days: [7, 12]
  estimate_type: SYNTHETIC_DEMO      # never omit
  model_version: bearing-demo-v1
  in_scope: true

data_quality_and_safety_checks:
  overall: PASS
  freshness: PASS
  units: PASS
  missing_intervals: PASS
  flatline: PASS
  tag_health: PASS
  operating_state_comparable: PASS
  safety_gate: PASS
  rule_version: safety-rules-v1

expected_impact:
  avoided_downtime_hours: 6.0
  contribution_value_per_hour: 4200
  method: change_in_failure_probability x exposed_downtime_hours x contribution_value_per_hour - incremental_maintenance_cost
  estimate_type: SYNTHETIC_DEMO
  assumptions:
    - Deferral leaves failure probability at its current 72h level
    - Planned window incurs no incremental changeover loss

resources:
  compatible_part: { part: BRG-6312-C3, on_hand: 1, reserved: 0 }
  qualified_technician: { name: R. Kulkarni, cert_valid_to: 2027-03-31 }
  approved_procedure: SOP-BRG-17-v4
  loto_checklist: LOTO-PUMP-03-v7

alternatives:
  - option_id: OPT-01
    action: INSPECT_AND_MONITOR
    tradeoff: Lower immediate disruption; retains higher failure exposure
  - option_id: OPT-04
    action: DEFER_TO_NEXT_PLANNED_SHUTDOWN
    tradeoff: No production impact now; highest failure exposure

rejected_options:
  - option_id: OPT-03
    action: REPLACE_IMMEDIATELY
    infeasible_reason: PRODUCTION_WINDOW_NOT_AUTHORIZED

data_gaps: []

safety:
  configured_trip_crossed: false
  agent_equipment_control: PROHIBITED
  escalation: Follow site procedure ESC-VIB-02 if any configured limit is crossed

approval:
  required_roles: [RELIABILITY_ENGINEER, PRODUCTION_SUPERVISOR]
  state: PENDING

next_step: Approve, modify, inspect evidence, or reject with reason

evidence_refs:
  - { ref: EV-0001, source: CORE.SENSOR_READING, key: "P-204/VIB_RMS_DE", observed_at: 2026-09-13T08:40:00 }
  - { ref: EV-0002, source: CORE.SENSOR_READING, key: "P-204/TEMP_BRG_DE", observed_at: 2026-09-13T08:40:00 }
  - { ref: EV-0003, source: CORE.MAINTENANCE_EVENT, key: "ME-00218", observed_at: 2026-09-08T06:00:00 }
```

## Abstention shape

When mandatory evidence is unusable, the contract still applies — but `recommended_action`
must be a gather-evidence action, not a maintenance action:

```yaml
decision_id: MNT-20260913-00032
decision_version: 1
as_of: 2026-09-13T08:45:00
subject: { asset: P-204 }

recommended_action:
  option_id: OPT-00
  action: GATHER_EVIDENCE
  detail: Restore telemetry and re-run validation before any maintenance decision

data_quality_and_safety_checks:
  overall: FAIL
  freshness: FAIL          # latest VIB_RMS_DE reading is 6h14m old, tolerance 30m

data_gaps:
  - Telemetry for P-204/VIB_RMS_DE is stale as of 2026-09-13T08:45:00

confidence:
  suppressed: true
  reason: DATA_QUALITY_FAIL — model evidence not used

rejected_options:
  - { option_id: OPT-02, infeasible_reason: DATA_QUALITY_INSUFFICIENT }
  - { option_id: OPT-03, infeasible_reason: DATA_QUALITY_INSUFFICIENT }

next_step: Restore telemetry or perform a manual inspection, then re-run
```

Do not report a risk score, RUL, or failure probability when
`data_quality_and_safety_checks.overall = FAIL`. Missing telemetry is `UNKNOWN`, not healthy.

## Rendering rules

- Lead with the recommendation and its deadline. Judges and engineers both read top-down.
- Every number carries its unit and its `estimate_type`.
- Never present `rejected_options` without the deterministic reason.
- Never present a `CONFIRMED` fault state unless a `CORE.MAINTENANCE_EVENT` row confirms it.
