# ESC-TMP-01 v1 — Bearing Temperature Trip Escalation

**Status:** CURRENT
**Applies to:** all rotating assets
**Effective from:** 2025-01-10
**Approved by:** EHS Committee

> Synthetic demo content for a hackathon prototype. Not a real escalation procedure.

## 1. When this procedure applies

A configured **trip** value for a bearing temperature tag has been crossed, as recorded in
the safety limit register. For centrifugal pumps the configured trip is 75 °C and the alarm
is 62 °C.

An alarm-only condition is handled through the normal condition-monitoring route and does
not invoke this procedure.

## 2. Immediate actions

1. The control room operator notifies the shift production supervisor and the reliability
   engineer on call.
2. Verify the reading against a second source where one exists: a handheld pyrometer at the
   bearing housing, or the companion vibration tag. A single-source trip on a tag with a
   recent health fault is treated as suspect until verified, but the asset is **not** assumed
   healthy while verification is pending.
3. The production supervisor decides on duty reduction or line stop per the site operating
   instruction for that line.
4. Do not re-grease a bearing at trip temperature. Introducing grease to an overheated
   bearing can accelerate failure and presents a burn hazard.

## 3. What must not happen

- No analytical system, dashboard, or copilot may issue a stop, start, derate, or setpoint
  change to any control system.
- No trip may be reset, bypassed, or inhibited to keep the line running.
- No maintenance option may be ranked on cost while a trip condition is live. Safety severity
  is not converted into a financial term.

## 4. Escalation chain

| Step | Role | Trigger |
|---|---|---|
| 1 | Shift production supervisor | Immediately on trip confirmation |
| 2 | Reliability engineer on call | Immediately, in parallel |
| 3 | EHS owner | Confirmed trip, or any burn exposure |
| 4 | Maintenance manager | Asset out of service beyond one shift |

## 5. Records

Record the tag, value, configured trip value, timestamp, operating state, verification
source, who was notified, and the disposition.
