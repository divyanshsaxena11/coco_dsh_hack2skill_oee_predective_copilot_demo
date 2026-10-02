# SOP-BRG-17 v4 — Drive-End Bearing Inspection and Replacement

**Status:** CURRENT
**Applies to:** CENTRIFUGAL_PUMP
**Supersedes:** SOP-BRG-17 v3 (withdrawn 2026-03-31)
**Effective from:** 2026-04-01
**Approved by:** K. Menon, Reliability CoE

> This document is synthetic demo content created for a hackathon prototype. It is not a
> real engineering procedure and must not be used to perform work on real equipment.

## 1. Scope

Inspection and, where the inspection confirms a defect, replacement of the drive-end
rolling element bearing on centrifugal pumps of the ETA and NB families.

## 2. Prerequisites

1. A valid lockout/tagout isolation completed per **LOTO-PUMP-03 v7**. This procedure does
   not authorise isolation; it assumes isolation is already complete and verified.
2. Technician holding a current **MECH_BEARING_L2** certification.
3. Vibration analyser available for the pre- and post-work readings.
4. For replacement: a compatible bearing kit confirmed against the asset BOM, and a
   hydraulic puller kit.

## 3. Change from v3

Version 3 permitted a bearing replacement decision on a single vibration reading above the
alarm threshold. **Version 4 requires a physical inspection to confirm the defect before
replacement is authorised**, except where a configured trip value has been crossed, in
which case ESC-VIB-02 or ESC-TMP-01 governs and no maintenance decision is taken locally.

This change followed three cases in 2025 where bearings were replaced on vibration
evidence alone and the removed bearings showed no confirmable defect.

## 4. Inspection sequence

1. Record the pre-work vibration RMS and bearing temperature with the operating state noted.
   A reading taken while the pump is stopped is not comparable to a running baseline.
2. Confirm the lubrication record. A bearing overdue for lubrication may present elevated
   vibration and temperature without a defect being present.
3. Listen and feel for roughness through the bearing housing with the pump running, if the
   isolation state permits.
4. Isolate per LOTO-PUMP-03 v7.
5. Remove the coupling guard and inspect the coupling condition and alignment witness marks.
6. Remove the bearing end cover. Inspect the grease condition for discolouration, metal
   particles, or carbonisation.
7. Rotate the shaft by hand and assess roughness, drag, and axial play.

## 5. Findings classification

Record exactly one of the following. Do not record a confirmed defect on indirect evidence.

| Finding | Meaning | Action |
|---|---|---|
| `CONFIRMED_DEFECT` | Visible spalling, brinelling, metal in grease, or measurable roughness | Proceed to replacement in Section 6 |
| `LUBRICATION_DEFICIENT` | Grease degraded or insufficient, no bearing damage found | Perform LUBE_SERVICE; do not replace |
| `NO_FAULT_FOUND` | Bearing condition acceptable | Reassemble; record NO_FAULT_FOUND against the originating work order |
| `INCONCLUSIVE` | Inspection could not be completed | Escalate to the reliability engineer; do not replace |

`NO_FAULT_FOUND` is a valid and useful outcome. It must be recorded, not quietly reclassified.

## 6. Replacement sequence

1. Confirm the bearing kit part number against the asset BOM before removal begins.
2. Withdraw the bearing with the hydraulic puller. Do not apply heat to the shaft.
3. Inspect the shaft journal and housing bore for scoring or ovality. Record any finding.
4. Fit the replacement bearing to the manufacturer's stated interference and grease charge.
5. Reassemble and verify shaft alignment per SOP-ALIGN-09 v2.
6. Remove isolation per LOTO-PUMP-03 v7.

## 7. Post-work verification

1. Run the pump at normal duty for a minimum of 30 minutes.
2. Record vibration RMS and bearing temperature under a running operating state.
3. Post-work vibration RMS should return to within 10% of the asset's established running
   baseline. If it does not, do not return the asset to unrestricted service; escalate to
   the reliability engineer.
4. Record the confirmed failure code, the actual remedy, parts consumed, and the post-work
   readings against the work order.

## 8. Return to service

Return to service is authorised by site personnel following the site return-to-service
process. Completion of this procedure is not by itself an authorisation to return the asset
to service.
