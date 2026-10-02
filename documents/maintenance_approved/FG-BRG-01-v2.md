# FG-BRG-01 v2 — Failure Guide: Rolling Element Bearing Modes

**Status:** CURRENT
**Applies to:** CENTRIFUGAL_PUMP
**Effective from:** 2025-09-01
**Approved by:** Reliability CoE

> Synthetic demo content for a hackathon prototype.

## 1. Purpose

Reference for distinguishing bearing degradation from conditions that present similarly.
This is diagnostic guidance, not an authorisation to act.

## 2. Degradation mechanisms

| Mechanism | Typical signature | Typical P–F interval |
|---|---|---|
| Lubrication deficiency | Vibration RMS rising gradually, bearing temperature rising, both reversible on re-greasing | 30–60 days |
| Rolling element spalling | Vibration RMS rising, increasing crest factor, temperature rising in later stages | 14–28 days |
| Inner race defect | Vibration with sidebands around the ball-pass frequency | 10–21 days |
| Contamination ingress | Erratic vibration, grease discoloured or gritty | 20–45 days |
| Misalignment-induced load | Elevated vibration at twice running speed, **temperature often normal** | 45–90 days |

## 3. Distinguishing bearing degradation from misalignment

This is the most common misdiagnosis on this asset family.

| Observation | Favours bearing degradation | Favours misalignment |
|---|---|---|
| Bearing temperature | Elevated alongside vibration | Usually near baseline |
| Vibration spectrum | Broad-band and bearing-frequency content | Concentrated at 2x running speed |
| Trend shape | Progressive, accelerating | Stable after the initiating event |
| Response to re-greasing | Partial, temporary improvement | No change |
| Coupling witness marks | Unchanged | Often disturbed |

A rise in **both** vibration RMS and bearing temperature, with lubrication overdue, is
consistent with a developing drive-end bearing fault. **Consistency is not confirmation.**
Confirmation requires the physical inspection in SOP-BRG-17 v4 Section 4.

## 4. Conditions that mimic bearing degradation

- Cavitation from suction restriction: elevated broad-band vibration, no temperature rise
  at the bearing, often accompanied by flow instability.
- Impeller fouling or imbalance: elevated vibration at running speed, temperature normal.
- Sensor or mounting fault: step change in reading with no corresponding process change.
  Check the tag health and mounting before accepting the reading.
- Operating point change: a pump run far from its design duty will read differently. Compare
  only readings taken in a comparable operating state.

## 5. Interpretation limits

- An anomaly score is a measure of deviation from learned behaviour. It is not a diagnosis
  and does not identify a mechanism.
- A remaining-useful-life estimate is a range conditioned on the observed trend continuing.
  A change in duty, lubrication, or load invalidates it.
- Absence of an alarm does not indicate a healthy bearing. Absence of data indicates nothing
  at all and must not be read as healthy.
