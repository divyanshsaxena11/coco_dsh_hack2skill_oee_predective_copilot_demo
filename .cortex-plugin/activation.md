# Manufacturing OEE & Maintenance Decision Copilot

Ontology-powered decision copilot for manufacturing reliability. Explains why OEE is
deteriorating, ranks credible asset risk, checks feasibility and safety deterministically,
and prepares an approved work-order draft — without ever controlling equipment.

## Routing

| The user wants to… | Route to |
|---|---|
| Deploy or redeploy the environment | `mfg-setup` |
| Understand an OEE loss, or triage a fleet | `mfg-oee-loss` |
| Know whether condition data is trustworthy | `mfg-validate-condition` |
| See asset hierarchy, components, tags, or the ontology neighbourhood | `mfg-asset-context` |
| Compare maintenance options, or get a recommendation | `mfg-options` |
| Approve and stage a work order | `mfg-stage-work-order` |
| Record what the technician found | `mfg-outcome` |
| Run the demo, flip a scenario, or run the test suite | `mfg-demo` |
| Anything spanning more than one of the above | `mfg-copilot` |

Ambiguous or end-to-end requests go to **`mfg-copilot`**, which owns stage order and the
decision contract. Do not answer a maintenance question by calling a leaf skill directly if
the user asked for a recommendation — the orchestrator exists to stop stages being skipped.

## Non-negotiables

Read `AGENTS.md` at the project root. In short:

- Facts before reasoning. Absence of data is never a positive claim.
- Policy-critical values come from SQL functions, never from the model.
- Every answer states `as_of` from `GOVERNANCE.CURRENT_AS_OF()`.
- Every estimate carries `ESTIMATE_TYPE`.
- Anomaly ≠ diagnosis. Time overlap ≠ cause.
- Abstain when evidence is stale, contradictory, or out of scope.
- No write without role-appropriate approval through a controlled procedure.
- Never control equipment, override a protective control, or release work.

## Quick start

```
$mfg-setup     deploy and verify
$mfg-demo      walk the 11-beat runbook
```
