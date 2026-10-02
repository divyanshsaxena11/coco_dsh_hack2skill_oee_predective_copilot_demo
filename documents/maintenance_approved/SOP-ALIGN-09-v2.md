# SOP-ALIGN-09 v2 — Shaft Alignment Verification

**Status:** CURRENT
**Applies to:** CENTRIFUGAL_PUMP
**Effective from:** 2025-06-01
**Approved by:** K. Menon, Reliability CoE

> Synthetic demo content for a hackathon prototype. Not a real engineering procedure.

## 1. Scope

Verification and, where required, correction of pump-to-driver shaft alignment using a laser
alignment system.

## 2. Prerequisites

1. Lockout/tagout completed per LOTO-PUMP-03 v7.
2. Technician holding a current **MECH_ALIGN_L1** certification.
3. Laser shaft alignment system available.
4. Stainless alignment shim set available.
5. Machine at ambient temperature. Aligning a hot machine produces a cold misalignment.

## 3. Verification sequence

1. Record the existing coupling witness marks before disturbing anything.
2. Remove the coupling guard and coupling element.
3. Mount the laser heads on the driver and driven shafts.
4. Check and record soft foot at each hold-down before taking alignment readings. Correcting
   alignment over an uncorrected soft foot will not hold.
5. Record angular and offset misalignment in both the vertical and horizontal planes.
6. Compare against the tolerance table in Section 4.

## 4. Tolerance

| Speed | Offset tolerance | Angular tolerance |
|---|---|---|
| Up to 1500 rpm | 0.10 mm | 0.06 mm / 100 mm |
| 1501–3000 rpm | 0.06 mm | 0.04 mm / 100 mm |
| Above 3000 rpm | 0.03 mm | 0.02 mm / 100 mm |

A machine inside tolerance is recorded as `NO_FAULT_FOUND`. Do not shim a machine that is
already within tolerance in order to "improve" it.

## 5. Correction

1. Correct vertical misalignment with shims at the hold-downs. Use the fewest shims that
   achieve the result; stacked thin shims behave as a spring.
2. Correct horizontal misalignment by jacking, not by hammering.
3. Re-verify after every adjustment. Record the final readings.

## 6. Post-work verification

1. Refit the coupling element and guard.
2. Remove isolation per LOTO-PUMP-03 v7.
3. Run at normal duty for 30 minutes.
4. Record vibration RMS. Misalignment-induced vibration concentrates at twice running speed;
   a successful correction should reduce that component specifically.
5. Record the finding against the work order, including `NO_FAULT_FOUND` where applicable.

## 7. Interaction with bearing work

Any bearing replacement on this asset family requires an alignment verification afterwards
per SOP-BRG-17 v4 Section 6.5. Alignment verification alone does not address a confirmed
bearing defect.
