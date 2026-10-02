# Deployment and validation guide

This guide describes the supplied source archive. It does not certify a fresh deployment. Commands run from the repository root.

## Prerequisites

- A Snowflake demo account and a named Snowflake CLI connection.
- Permissions for the setup SQL, which explicitly selects `ACCOUNTADMIN` in several files.
- Cortex Analyst, Cortex Search, Cortex Agent, and Streamlit availability in the target account.
- Coco Desktop or CLI with project skills configured.
- Node.js for the local hook tests.
- Python with `networkx`, `matplotlib`, and `pyvis` for local ontology rendering.

The source targets `MFG_COPILOT_DB` and `COMPUTE_WH`; they are not parameterized by the connection argument. Review the account AI probe in `sql/00_account_prereqs.sql` because its model identifier is account-dependent. Use a dedicated environment: `CREATE OR REPLACE` and seed operations may replace prior demo state.

## Deploy Snowflake objects

```bash
bash sql/deploy.sh YOUR_CONNECTION
snow stage copy streamlit/ '@MFG_COPILOT_DB.APP.STREAMLIT_STAGE' --overwrite -c YOUR_CONNECTION
```

The default batch deployment runs the numbered SQL in order, uploads the document corpus between scripts 42 and 45, and creates the Streamlit object. The extra command uploads its source.

**Current archive caveat:** `deploy.sh` does not upload Streamlit source in batch mode. Its `--per-file` branch references `app/streamlit/`, but the supplied directory is `streamlit/`. Correct that path before using per-file deployment; the two commands above document the batch-mode workaround.

Open `MFG_COPILOT_DB.APP.OEE_COMMAND_CENTER` in Snowsight and verify the app dependencies and access for the intended role. The source imports Streamlit, Snowpark, pandas, Plotly, and Snowflake's hosted runtime module. The archive does not include a Streamlit dependency manifest.

## Load Coco skills

The supplied project has overlapping skill layouts:

| Location | Contents |
|---|---|
| `.cortex-plugin/skills/` | Nine manufacturing skills, including setup and demo |
| `plugins/mfg-copilot/skills/` | The same nine skill names plus Slack reporting |
| `skills/` | Project copies plus additional helpers |

Choose one intended installation layout in your Coco environment. The old README describes copying project skills to `.snowflake/cortex/skills/` or the packaged plugin to `~/.snowflake/cortex/plugins/mfg-copilot/`; verify discovery in your installed Coco version before relying on these paths.

The original `.cortex-plugin/plugin.json` declares a `PreToolUse` hook for named SQL tools. The packaged plugin manifest does not declare the same hook. Installing one layout does not prove the other layout's guardrails are active. Confirm loaded skills and hook configuration explicitly.

Start with the orchestrator for an end-to-end decision:

```text
/mfg-copilot
Investigate OEE deterioration on Packaging Line 2 and explain the next maintenance decision.
```

The recorded validation segment demonstrates passing quality checks. Use `mfg-demo` only when intentionally running its broader scenario-changing runbook.

## Generate the ontology views

Both supplied visualization scripts contain an author-specific Windows Downloads path. Make these substitutions before running them:

```python
from pathlib import Path
ONTOLOGY_DIR = Path(__file__).resolve().parent
```

- In `ontology_project.py`, use `DATA_FILE = ONTOLOGY_DIR / "ontology_edges.csv"` and `output = str(ONTOLOGY_DIR / "ontology_project.html")`.
- In `ontology_snapshot.py`, read `ONTOLOGY_DIR / "ontology_edges.csv"` and save to `ONTOLOGY_DIR / "ontology_snapshot.png"`.
- Change the snapshot title's “Live Snowflake Data” wording to “Synthetic demo export” when rendering the committed CSV.

```bash
python -m pip install networkx matplotlib pyvis
python ontology/ontology_project.py
python ontology/ontology_snapshot.py
```

The interactive view aggregates entity types. The static snapshot centers on P-204. Both read the committed pipe-delimited export; neither script queries Snowflake directly.

## Slack and automation

The supplied `.mcp.json` is under `plugins/mfg-copilot/`, rather than the Slack-only directory referenced by the original README. Configure the required Slack connection privately in the intended environment; do not commit populated credentials.

Before executing the reporting skill, align its queries with this archive:

| Reporting skill reference | Supplied SQL definition |
|---|---|
| `CORE.OEE_INTERVAL.INTERVAL_START` | The view exposes `BUCKET_START` |
| `CORE.DOWNTIME_EVENT.STOP_START` | The table exposes `START_TS` |
| `CORE.DOWNTIME_EVENT.STOP_CATEGORY` | Review `REASON_CODE` / `REASON_DESCRIPTION` for the intended grouping |
| `CORE.ASSET_HEALTH_SNAPSHOT` | The view is in `AI` |
| `RISK_TIER`, `HEADLINE` | These fields are not exposed by the supplied `AI.ASSET_HEALTH_SNAPSHOT`; adapt the report using its actual fields, such as `TRIAGE_LANE`, `DQ_VERDICT`, and `SCORE_EXPLANATION` |

Apply any chosen corrections consistently across the duplicate report skills. Verify the read-only report queries before enabling delivery.

The delivered email recording is a Snowflake CoWork automation output. Neither that automation configuration nor a complete email delivery implementation is exported in this source archive. Recreate the schedule and delivery configuration in the relevant environment and verify a completed run. Treat it separately from Slack MCP reporting.

## Validate

```bash
node .cortex-plugin/hooks/gate-test.js
snow sql -c YOUR_CONNECTION -f tests/scenarios.sql
```

The SQL suite changes scenario state and resets it at the end. Run it in the demo environment; check both assertion details and summary. It explicitly invokes seven scenarios, while the scenario engine defines a broader set. Do not describe all configured scenarios as tested without matching assertions and run evidence.

No cloud tests or deployment were executed during this documentation review.
