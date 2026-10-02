# Snowflake Semantic View DDL — syntax reference

Read this **before** writing any `CREATE SEMANTIC VIEW`. Clause-order and alias-direction
errors are the number-one time sink here, and the compiler messages are unhelpful.

## Clause order is fixed

```sql
CREATE OR REPLACE SEMANTIC VIEW <db>.<schema>.<name>
  TABLES ( ... )
  RELATIONSHIPS ( ... )
  FACTS ( ... )
  DIMENSIONS ( ... )
  METRICS ( ... )
  COMMENT = '...'
  AI_SQL_GENERATION '...'            -- bare clause, NOT "WITH AI_SQL_GENERATION"
  AI_QUESTION_CATEGORIZATION '...'
  AI_VERIFIED_QUERIES ( ... )        -- after COMMENT, before COPY GRANTS
  COPY GRANTS
;
```

Verified against the official grammar. Two things that are easy to get wrong:

- `AI_SQL_GENERATION` takes a bare quoted string. There is no `WITH` keyword and it is **not**
  the last clause — `AI_VERIFIED_QUERIES` follows it.
- `COMMENT` goes after `METRICS`, not next to the view name.

`FACTS` must precede `DIMENSIONS`, which must precede `METRICS`. Within a clause you may
reference an expression defined later.

## Alias goes BEFORE `AS`

```sql
-- CORRECT
TABLES (
  assets AS MFG_COPILOT_DB.CORE.ASSET PRIMARY KEY (ASSET_ID),
  oee    AS MFG_COPILOT_DB.CORE.OEE_INTERVAL PRIMARY KEY (OEE_INTERVAL_ID)
)

-- WRONG — this is the intuitive direction and it does not work
TABLES ( MFG_COPILOT_DB.CORE.ASSET AS assets )
```

No `WITH COLUMNS (...)` in `TABLES`. Columns are implicitly available.

## Relationships

```sql
RELATIONSHIPS (
  components_to_assets AS components (ASSET_ID) REFERENCES assets,
  readings_to_tags     AS readings   (TAG_ID)   REFERENCES tags
)
```

The referenced table must declare a `PRIMARY KEY` in `TABLES`. Many-to-many needs a bridge
table declared as its own logical table.

## Facts, dimensions, metrics

```sql
FACTS (
  readings.reading_value AS VALUE_NORMALIZED
    COMMENT = 'Sensor value in the tag normalized unit',
  oee.run_time_minutes AS RUN_TIME_MIN
)

DIMENSIONS (
  assets.asset_code AS ASSET_ID COMMENT = 'Asset tag, e.g. P-204'
    WITH SYNONYMS = ('asset','equipment','machine','pump'),
  assets.criticality AS CRITICALITY_CLASS
)

METRICS (
  oee.availability AS SUM(oee.RUN_TIME_MIN) / NULLIF(SUM(oee.PLANNED_PRODUCTION_MIN), 0)
    COMMENT = 'Run time divided by planned production time'
)
```

- Format is `table_alias.semantic_name AS <sql_expr>`.
- Metrics use `AS <aggregate_expr>`, **not** `= <expr>`.
- Dimensions and facts reference physical columns of their own logical table.

## Traps that cost real time

| Trap | Symptom | Fix |
|---|---|---|
| **Cyclic reference** | `Cyclic reference detected` on a valid-looking view | A `FACT` column name matches a `METRIC` name case-insensitively. Rename one. This is why facts here are suffixed `_MIN`, `_CNT`, `_VAL` |
| Alias direction reversed | `invalid identifier` on the table name | Alias first, then `AS`, then the fully qualified name |
| `COMMENT` misplaced | Generic syntax error near `TABLES` | Move `COMMENT` after `METRICS` |
| Missing `PRIMARY KEY` | Relationship fails to resolve | Declare `PRIMARY KEY` on the referenced logical table |
| Reserved word as alias | `unexpected 'ORDER'` | Quote it, or rename. Avoid `ORDER`, `VALUE`, `START`, `END`, `LEFT` |
| Division by zero in a metric | Nulls or errors at query time | Always `NULLIF(denominator, 0)` |
| Cross-table dimension | Only works in DDL, not YAML | `table_a.dim_x AS table_b.dim_y` resolves through a declared relationship |

## Verified queries

Attach verified queries so Cortex Analyst has grounded exemplars:

```sql
  AI_VERIFIED_QUERIES (
    oee_loss_factor_by_shift AS (
      QUESTION 'Which factor drove Line 2 OEE loss this shift?'
      VERIFIED_AT 1773388800
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = reliability_coe)'
      SQL 'SELECT ... FROM oee_intervals ...'
    )
  )
```

Notes that cost time:

- `SQL` takes a **single-quoted** string, not `$$...$$`. Internal single quotes must be
  doubled (`''`), which makes string literals inside a verified query awkward — prefer
  queries that filter on parameters the caller supplies.
- `VERIFIED_AT` is **seconds since the Unix epoch**, an integer. Not a timestamp literal.
- `VERIFIED_BY` has the shape `'( <purpose> = <contact> )'`.
- The `SQL` body is written against the **logical table aliases**, not the physical tables.

Each `SQL` must be correct. Validate every one before shipping — an incorrect verified query
is worse than none, because Analyst will imitate it.

## Validate before you execute

Compile first, then run:

1. `snowflake_sql_execute` with `only_compile: true`.
2. Fix clause order and alias direction until it compiles.
3. Execute.
4. `SHOW SEMANTIC VIEWS IN SCHEMA <schema>` and `DESCRIBE SEMANTIC VIEW <name>` to confirm.
5. Run each verified query standalone and diff against a hand-written control query.

## Querying a semantic view

```sql
SELECT * FROM SEMANTIC_VIEW(
  MFG_COPILOT_DB.SEMANTIC.MAINTENANCE_DECISION_SV
  DIMENSIONS assets.ASSET_ID, lines.LINE_ID
  METRICS oee.availability, oee.oee
)
WHERE lines.LINE_ID = 'PKG-L2';
```

`DIMENSIONS` and `METRICS` are separate keywords inside `SEMANTIC_VIEW(...)`, and the object
name is not followed by a comma.
