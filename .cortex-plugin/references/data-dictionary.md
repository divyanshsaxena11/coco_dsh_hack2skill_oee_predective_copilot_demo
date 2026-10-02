# Data dictionary — `MFG_COPILOT_DB`

Authoritative grains, units, and versioning rules. The DDL in `sql/` implements this; if the
two disagree, this file is the spec and the DDL is the bug.

> All values are **synthetic and illustrative**. Every estimate carries `ESTIMATE_TYPE`.

## Reference baseline window

Elevation is always measured against a **governed reference period: 7–14 days before the
snapshot** (`BASELINE_WINDOW_START_MIN` = 10080, `BASELINE_WINDOW_END_MIN` = 20160 in
`GOVERNANCE.ANALYSIS_CONSTANT`).

This is not arbitrary. The P-202 misalignment signature runs 5 days and the M-303 signature
3 days, so a 2–14 day window is contaminated by the very rise it is meant to measure
against — it understated P-202 as +13.1% instead of +18.3%. Every seeded degradation window
is shorter than 7 days for exactly this reason.

## Verified seeded signature

Measured on deployment, against the reference baseline, RUNNING state, GOOD quality only:

| Asset | Tag | Reference baseline | Current (last 45 min) | Elevation | Role in the demo |
|---|---|---|---|---|---|
| `P-204` | `VIB_RMS_DE` | 2.798 mm/s | 3.857 mm/s | **+37.8%** | Hero. Sustained above the 1.30× alert threshold for exactly **45 minutes** |
| `P-204` | `TEMP_BRG_DE` | 52.0 °C | 60.69 °C | **+8.7 °C** | Below the 62 °C alarm and the 75 °C trip — a judgement call, not an automatic escalation |
| `M-303` | `VIB_RMS_DE` | 2.36 mm/s | 2.95 mm/s | +25.0% | `AC_MOTOR` — **out of model scope**, must not be ranked |
| `P-202` | `VIB_RMS_DE` | 3.10 mm/s | 3.67 mm/s | +18.3% | Credible #2, misalignment signature |
| `P-205` | `TEMP_BRG_DE` | 48.9 °C | *no data* | — | Stale 3 h — a stale case that is **not** the hero |
| all others | — | — | — | within ±1% | Flat |

`P-204` drive-end bearing lubrication is overdue by exactly **120 operating hours** against a
720-hour interval.

## Verified OEE story — `PKG-L2`

| Factor | Trailing baseline | Current shift | Delta |
|---|---|---|---|
| Availability | 0.9802 | 0.9222 | **−5.80 pp** ← dominant loss |
| Performance | 0.9545 | 0.9300 | −2.45 pp |
| Quality | 0.9888 | 0.9893 | +0.05 pp (flat) |
| **OEE** | **0.9251** | **0.8484** | **−7.67 pp** |

Current-shift downtime is 14 minutes across two stops: `DT-CURR-01` (8 min, reason
`UNKNOWN`, no asset association) and `DT-CURR-02` (6 min, `FLOW_INTERRUPTION`,
`TIME_OVERLAP` to `P-204` at 0.55 confidence). So "availability deteriorated this shift" is
what the data says, and the asset link is explicitly correlation.

## Row counts on a clean deploy

| Object | Rows |
|---|---|
| `RAW.SENSOR_EVENT_RAW` / `CORE.SENSOR_READING` | 120,925 |
| `CORE.PRODUCTION_EVENT` | 2,688 |
| `CORE.OEE_INTERVAL` / `CORE.QUALITY_EVENT` | 674 |
| `CORE.DOWNTIME_EVENT` | 54 |
| `CORE.ASSET` / `CORE.COMPONENT` / `CORE.SENSOR_TAG` | 10 / 30 / 30 |
| `CORE.MAINTENANCE_EVENT` | 6 (3 `CONFIRMED` analogs, 1 `NO_FAULT_FOUND`) |

## Universal columns

Every fact-bearing table carries provenance:

| Column | Meaning |
|---|---|
| `EVENT_TS` | When the thing happened (`TIMESTAMP_NTZ`, plant local, naive) |
| `INGESTED_AT` | When it landed in Snowflake |
| `SOURCE_SYSTEM` | `HISTORIAN` / `MES` / `CMMS` / `INVENTORY` / `HR` / `DEMO_SEED` |
| `SOURCE_UNIT` | Unit as supplied by the source |
| `UNIT` | Normalized unit after conversion |
| `QUALITY_FLAG` | `GOOD` / `SUSPECT` / `BAD` / `STALE` / `MISSING` |

Time is naive `TIMESTAMP_NTZ` throughout, anchored to `GOVERNANCE.DEMO_CLOCK`. Never
`CURRENT_TIMESTAMP()` in a query the copilot runs.

## Schemas

| Schema | Role |
|---|---|
| `RAW` | Source-aligned, minimally changed |
| `CORE` | Canonical entities, normalized units, production and maintenance history |
| `CONTEXT` | Ontology nodes/edges and compact decision views |
| `AI` | Condition features and precomputed model outputs |
| `DECISION` | Options, recommendations, approvals, staged work, outcomes |
| `GOVERNANCE` | Safety limits, procedures, authority, compatibility, rule versions, demo clock, scenario overlay |
| `SEMANTIC` | Semantic view and Cortex Search service |
| `AUDIT` | Append-only decision/tool/deploy logs and KPI views |
| `APP` | Streamlit stage and object |

## The plant

| Level | Values |
|---|---|
| Site | `PLANT-01` (Pune) |
| Area | `PACKAGING`, `UTILITIES` |
| Line | `PKG-L2` (hero), `PKG-L1` (contrast) |
| Asset | `P-201`…`P-206` centrifugal pumps, `M-301`…`M-304` motors |
| Hero asset | **`P-204`**, component `DRIVE_END_BEARING` |

Asset classes: `CENTRIFUGAL_PUMP`, `AC_MOTOR`.
Components per asset: `DRIVE_END_BEARING`, `NON_DRIVE_END_BEARING`, `COUPLING`.
Fault modes: `DRIVE_END_BEARING_DEGRADATION`, `SHAFT_MISALIGNMENT`.

## Sensor tags

Three per asset, so 30 tags total.

| Tag suffix | Observed property | `UNIT` | Expected cadence | Valid range |
|---|---|---|---|---|
| `VIB_RMS_DE` | Vibration RMS, drive end | `MM_S` | 5 min | 0.1 – 45.0 |
| `TEMP_BRG_DE` | Bearing temperature, drive end | `DEG_C` | 5 min | 5.0 – 140.0 |
| `MOTOR_CURRENT` | Motor current | `AMP` | 5 min | 0.5 – 200.0 |

Tag id format: `<ASSET_ID>/<TAG_SUFFIX>`, e.g. `P-204/VIB_RMS_DE`.

Freshness tolerance is per tag in `SENSOR_TAG.FRESHNESS_TOLERANCE_MIN` (default 30).

## Grains

| Table | Grain |
|---|---|
| `CORE.SENSOR_READING` | one tag × 5-minute event timestamp |
| `AI.CONDITION_FEATURE` | one component × 1-hour window × feature × `FEATURE_VERSION` |
| `AI.MODEL_PREDICTION` | one model run × component × fault mode × horizon |
| `AI.ASSET_HEALTH_SNAPSHOT` | one asset, latest as of the demo clock |
| `CORE.PRODUCTION_EVENT` | one line × event interval |
| `CORE.OEE_INTERVAL` | one line × 1-hour bucket, plus a shift roll-up |
| `CORE.DOWNTIME_EVENT` | one stop interval |
| `CORE.QUALITY_EVENT` | one line × product × 1-hour bucket |
| `CORE.MAINTENANCE_EVENT` | one inspection, repair, or failure |
| `CORE.WORK_ORDER` | one order |
| `CORE.PRODUCTION_WINDOW` | one line × time window |
| `CORE.PART_INVENTORY` | one site × part snapshot |
| `CORE.TECHNICIAN_SKILL` | one person × skill, effective-dated |

History depth: **14 days** ending at the demo clock.

## OEE — governed definition

```
availability = run_time_min / planned_production_min
performance  = (ideal_cycle_sec * total_count) / (run_time_min * 60)
quality      = good_count / total_count
oee          = availability * performance * quality
```

`CORE.OEE_INTERVAL` retains every input so the number is reconstructable:

`PLANNED_PRODUCTION_MIN`, `RUN_TIME_MIN`, `DOWNTIME_MIN`, `EXCLUDED_MIN`,
`IDEAL_CYCLE_SEC`, `TOTAL_COUNT`, `GOOD_COUNT`, `SCRAP_COUNT`, `REWORK_COUNT`,
`CALENDAR_CODE`, `EXCLUSION_REASON`, `CALC_VERSION`.

`CALC_VERSION` starts at `oee-calc-v1`. Never change a definition in place — add a version.

`OEE_INTERVAL` is **derived from** `PRODUCTION_EVENT` and `QUALITY_EVENT`, not seeded
independently, so beat 1 can answer "where did availability come from".

## Downtime → asset association

The epistemic core of the demo. Association is **data**, not prose.

| Column | Values |
|---|---|
| `ASSOC_METHOD` | `OPERATOR_CONFIRMED` / `TIME_OVERLAP` / `UNKNOWN` |
| `ASSET_ASSOC_CONFIDENCE` | 0.00 – 1.00 |
| `IS_PLANNED` | boolean |
| `REASON_CODE` | governed classification, includes `UNKNOWN` |
| `CONFIRMED_BY` | nullable |

Rules:
- `OPERATOR_CONFIRMED` may be described as an established cause.
- `TIME_OVERLAP` is correlation only. Never upgrade it.
- `UNKNOWN` stays visible. Never fold it into an asset cause to make a total tidy.

## Model outputs

`AI.MODEL_PREDICTION` columns: `MODEL_VERSION`, `FAULT_MODE`, `HORIZON_HOURS`,
`FAILURE_PROBABILITY`, `ANOMALY_SCORE`, `RUL_LOW_DAYS`, `RUL_HIGH_DAYS`,
`CONFIDENCE_BAND`, `IN_SCOPE`, `SCOPE_REASON`, **`ESTIMATE_TYPE`**.

`ESTIMATE_TYPE` is `SYNTHETIC_DEMO` for everything in this project. It is a real column, not
a caption, so a value cannot reach the user unlabelled.

`IN_SCOPE = FALSE` for `AC_MOTOR` assets — the demo model covers pumps only. This exercises
the out-of-scope path.

## Safety limits

`GOVERNANCE.SAFETY_LIMIT`: `ASSET_CLASS`, `TAG_SUFFIX`, `ALARM_VALUE`, `TRIP_VALUE`,
`UNIT`, `SEVERITY`, `REQUIRED_RESPONSE`, `ESCALATION_REF`, `OWNER_ROLE`, `RULE_VERSION`,
`VALID_FROM`, `VALID_TO`.

Hero design: `P-204` `TEMP_BRG_DE` sits above baseline but **below** `TRIP_VALUE`, so the
default story is a genuine judgement call rather than an automatic escalation. Scenario
`M5_SAFETY_TRIP` pushes it over.

## Procedures

`GOVERNANCE.PROCEDURE_METADATA`: `PROCEDURE_CODE`, `VERSION`, `STATUS`
(`CURRENT` / `SUPERSEDED` / `DRAFT`), `APPLIES_TO_ASSET_CLASS`, `APPLIES_TO_TASK_CODE`,
`VALID_FROM`, `VALID_TO`, `TITLE`.

| Code | Version | Status |
|---|---|---|
| `SOP-BRG-17` | v3 | `SUPERSEDED` |
| `SOP-BRG-17` | v4 | `CURRENT` |
| `LOTO-PUMP-03` | v7 | `CURRENT` |
| `SOP-ALIGN-09` | v2 | `CURRENT` |
| `ESC-VIB-02` | v1 | `CURRENT` |

Both v3 and v4 are indexed in Cortex Search. Retrieval must cite **v4**. Citing v3 is a
demo failure, and `SUPERSEDED_SOP` is the scenario that tests it.

## Resources

`CORE.PART_MASTER` / `CORE.ASSET_BOM` / `CORE.PART_INVENTORY`.

Hero: `BRG-6312-C3`, `ON_HAND = 1`, `RESERVED = 0`, at `PLANT-01`, lead time 12 days.
`M3_NO_PART` sets `ON_HAND = 0`.

`CORE.TECHNICIAN_SKILL`: 4 technicians. `R. Kulkarni` holds `MECH_BEARING_L2` valid through
2027-03-31. `S. Iyer` holds the same skill but **expired**, exercising `EXPIRED_CERT`.

## Versioning

Every deterministic output stamps its version so a recommendation is reconstructable:

| Version | Lives in |
|---|---|
| `CALC_VERSION` | `CORE.OEE_INTERVAL` |
| `FEATURE_VERSION` | `AI.CONDITION_FEATURE` |
| `MODEL_VERSION` | `AI.MODEL_PREDICTION` |
| `RULE_VERSION` | `GOVERNANCE.SAFETY_LIMIT`, `GOVERNANCE.RULE_VERSION` |
| `DECISION_VERSION` | `DECISION.MAINTENANCE_RECOMMENDATION` |

Idempotency key for controlled writes: `decision_id + action_type + decision_version`.

## Decision state machine

```
DRAFT → RECOMMENDED → APPROVAL_PENDING → APPROVED → STAGED → EXECUTED → OUTCOME_RECORDED
  └──────────────→ REJECTED
  └──────────────→ EXPIRED
```

A recommendation `EXPIRED`s when its evidence goes stale or a relevant condition changes.
Each transition appends to `AUDIT.DECISION_AUDIT`; nothing is overwritten. Re-evaluation
creates a new `DECISION_VERSION` and preserves the prior one.
