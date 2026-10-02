# ESC-VIB-02 v1 — Vibration Limit Breach Escalation

**Status:** CURRENT
**Applies to:** all rotating assets
**Effective from:** 2025-01-10
**Approved by:** EHS Committee

> Synthetic demo content for a hackathon prototype. Not a real escalation procedure.

## 1. When this procedure applies

A configured **trip** value for a vibration tag has been crossed, as recorded in the safety
limit register.

This procedure does **not** apply when only the alarm value has been crossed. An alarm
condition is handled through the normal condition-monitoring and planning route.

## 2. Immediate actions

1. The control room operator notifies the shift production supervisor and the reliability
   engineer on call.
2. The production supervisor decides whether to reduce duty or stop the affected line,
   following the site operating instruction for that line. **That decision belongs to the
   accountable person, not to any analytical system.**
3. The reliability engineer attends and takes an independent reading.
4. If the trip condition is confirmed, the asset is removed from service by authorised site
   personnel and a priority work order is raised.

## 3. What must not happen

- No analytical system, dashboard, or copilot may issue a stop, start, derate, or setpoint
  change to any control system.
- No trip may be reset, bypassed, or inhibited to keep the line running.
- No return to service may occur without an inspection and the site return-to-service
  authorisation.
- Economic or schedule considerations do not reduce the response required here. Safety
  severity is not a discountable cost.

## 4. Escalation chain

| Step | Role | Trigger |
|---|---|---|
| 1 | Shift production supervisor | Immediately on trip confirmation |
| 2 | Reliability engineer on call | Immediately, in parallel |
| 3 | EHS owner | If any person was exposed, or if the trip recurs after a reset attempt |
| 4 | Maintenance manager | If the asset must remain out of service beyond one shift |

## 5. Records

Record the tag, the value, the configured trip value, the timestamp, the operating state,
who was notified, and the disposition. Retain the raw readings.
