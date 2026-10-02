---
name: validate-schema
description: Validate a Snowflake table schema against team naming conventions. Checks column names, data types, constraints, and clustering. Use when asked to validate schema, check schema, review table structure, or lint a table.
---

# Schema Validator

When the user asks to validate a table schema, follow these steps:

## Step 1: Get the schema
Run `DESCRIBE TABLE <table_name>` using snowflake_sql_execute to get all columns, types, and constraints.

## Step 2: Check naming conventions
- All column names must be SNAKE_CASE (uppercase with underscores)
- No abbreviations (use CUSTOMER_ID not CUST_ID, ORDER_DATE not ORD_DT)
- Primary keys should end with _ID or _KEY
- Date columns should end with _DATE or _AT (for timestamps)
- Boolean columns should start with IS_ or HAS_

## Step 3: Check data types
- Prefer NUMBER(38,0) over INT for integer columns
- Prefer TIMESTAMP_NTZ over TIMESTAMP or TIMESTAMP_LTZ
- Prefer VARCHAR over STRING or TEXT (they're aliases but VARCHAR is standard)
- VARIANT columns should have a comment explaining the expected JSON structure

## Step 4: Check constraints
- Primary key columns must be NOT NULL
- Every table should have at least one column that serves as a unique identifier

## Step 5: Report results
Present findings as a table with columns: Column | Issue | Severity | Suggestion
- Severity levels: ERROR (must fix), WARN (should fix), INFO (consider fixing)

## Step 6: Offer fixes
If there are fixable issues, offer to generate ALTER TABLE statements to rename columns or change types.

## Conventions Reference
These conventions follow the team standards:
- Database: ANALYTICS_DEV (dev) | ANALYTICS_PROD (prod)
- Warehouse: DEV_WH for all dev work
- Naming: snake_case for all objects
