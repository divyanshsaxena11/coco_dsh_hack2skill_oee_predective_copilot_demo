# Cortex Agent specification — syntax reference

## Create syntax

Use `FROM SPECIFICATION $$...$$`. **Not** `YAML =`, **not** `SPEC =`.

```sql
CREATE OR REPLACE AGENT MFG_COPILOT_DB.SEMANTIC.MAINTENANCE_DECISION_AGENT
WITH PROFILE = '{"display_name":"Maintenance Decision Agent"}'
COMMENT = 'OEE and maintenance decision copilot over governed manufacturing context.'
FROM SPECIFICATION $$
models:
  orchestration: auto
instructions:
  response: |
    ...
  orchestration: |
    ...
tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: MaintenanceAnalyst
      description: ...
tool_resources:
  MaintenanceAnalyst:
    semantic_view: "MFG_COPILOT_DB.SEMANTIC.MAINTENANCE_DECISION_SV"
    execution_environment:
      type: "warehouse"
      warehouse: "COMPUTE_WH"
$$;
```

## The one that will cost you an hour

**`execution_environment` is mandatory on every `tool_resources` entry that runs SQL.**

Without it the create appears syntactically fine and fails with:

```
391920 (internal error)
```

The error text says nothing about the missing field. Always include:

```yaml
    execution_environment:
      type: "warehouse"
      warehouse: "COMPUTE_WH"
```

## Tool types

| Type | Purpose | `tool_resources` key |
|---|---|---|
| `cortex_analyst_text_to_sql` | Structured questions over a semantic view | `semantic_view` + `execution_environment` |
| `cortex_search` | Retrieval over an approved document corpus | `name`, `id_column`, optional `filter` |
| `generic` | A UDF or stored procedure as a deterministic tool | `identifier`, `type: procedure`/`function`, `execution_environment` |

## Deterministic tools

Register each policy-critical function as a `generic` tool so the orchestrator calls SQL
rather than reasoning about thresholds:

```yaml
  - tool_spec:
      type: generic
      name: ValidateConditionData
      description: |
        Returns the deterministic data-quality verdict for one asset as of a timestamp:
        freshness, gaps, unit consistency, range, flatline, tag health, and
        operating-state comparability.

        USE WHEN: before any condition assessment or maintenance recommendation.
        DO NOT USE: to judge asset health — this only judges whether the data is usable.
        FAIL CLOSED: if overall is FAIL, do not report risk, RUL, or failure probability.
      input_schema:
        type: object
        properties:
          asset_id: { type: string, description: "Asset code, e.g. P-204" }
          as_of:    { type: string, description: "ISO timestamp; omit to use the demo clock" }
        required: [asset_id]
tool_resources:
  ValidateConditionData:
    identifier: "MFG_COPILOT_DB.GOVERNANCE.VALIDATE_SENSOR_CONTEXT"
    type: "function"
    execution_environment:
      type: "warehouse"
      warehouse: "COMPUTE_WH"
```

Tool descriptions decide routing quality. Each one should state: what it does, what data it
covers, when to use it, when **not** to use it.

## Fail closed on inaccessible tools

Put this in `instructions.orchestration`:

```
If a required tool is unavailable or returns an error, say so and stop. Never answer a
policy-, safety-, or data-quality-dependent question from general model knowledge.
```

## Verify after create

```sql
SHOW AGENTS IN SCHEMA MFG_COPILOT_DB.SEMANTIC;
DESCRIBE AGENT MFG_COPILOT_DB.SEMANTIC.MAINTENANCE_DECISION_AGENT;
```

## Grants

```sql
GRANT USAGE ON AGENT ... TO ROLE MFG_RELIABILITY_ENGINEER;
```

The caller also needs `USAGE` on the semantic view, the search service, the functions, the
schemas, and a default warehouse. RBAC is the security boundary, not the instructions.

## Cortex Search access-control caveat

A Cortex Search service queries with the **service owner's** rights. Holding `USAGE` on the
service exposes every indexed row regardless of the caller's access to the source table.
Therefore: index only non-sensitive approved manuals and SOPs, keep differently entitled
plant content in separate services, and scope grants tightly.
