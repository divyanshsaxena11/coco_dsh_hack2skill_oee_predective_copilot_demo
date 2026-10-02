---
name: "mfg-asset-context"
description: >
  Resolves the asset hierarchy, components, sensors, safety limits, compatible parts,
  open work, maintenance history, and the ontology neighbourhood for one asset.

  Triggers: "asset context", "tell me about asset", "hierarchy", "ontology",
  "what is connected to", "graph neighbourhood", "P-204 context".
tools:
  - SnowflakeSqlExecute
user-invocable: true
version: "1.0.0"
author: "DataSuperHeros"
tags:
  - mfg
  - context
---

# mfg-asset-context — Asset Context and Ontology Neighbourhood

## Step 1: Compact context

```sql
SELECT * FROM MFG_COPILOT_DB.CONTEXT.ASSET_CONTEXT_V WHERE ASSET_ID = '<ASSET_ID>';
```

Present: site, area, line, criticality, consequence classification, drive-end component,
lubrication status, tags, safety limits, compatible parts, open work orders, confirmed
fault history, and last maintenance.

## Step 2: Ontology neighbourhood (2 hops default)

```sql
SELECT HOP, SRC_TYPE, SRC_KEY, REL_TYPE, DST_TYPE, DST_KEY, DST_LABEL,
       CONFIDENCE, DERIVATION_METHOD
FROM TABLE(MFG_COPILOT_DB.CONTEXT.GET_CONTEXT_NEIGHBOURHOOD('<ASSET_ID>', 2))
ORDER BY HOP, SRC_KEY, REL_TYPE;
```

For a deeper chain (e.g., asset to part or skill), use 5 hops.

## Step 3: Present

- Show the hierarchy: Site → Area → Line → Asset → Component → Sensor.
- For each edge, state the `DERIVATION_METHOD`. A `TIME_OVERLAP` edge is not the same as
  a `FOREIGN_KEY` edge, and a `TECHNICIAN_CONFIRMATION` edge is not the same as a
  `RULE_COMPONENT_TYPE_MATCH` edge.
- Highlight any edge with `CONFIDENCE < 1.00`.
- State `as_of` from `GOVERNANCE.CURRENT_AS_OF()`.
