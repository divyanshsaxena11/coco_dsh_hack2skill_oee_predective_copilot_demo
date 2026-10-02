-- =============================================================================
-- 90_cortex_agent.sql
-- Manufacturing OEE & Maintenance Decision Copilot
--
-- Multi-Agent Architecture using Snowflake Agent Toolsets:
--   1. ANALYTICS_AGENT   — Cortex Analyst over semantic view (OEE, fleet data)
--   2. KNOWLEDGE_AGENT   — Cortex Search over maintenance manuals
--   3. MFG_COPILOT_AGENT — Master orchestrator using agent_toolset
--      Inherits all tools from both sub-agents at runtime.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE MFG_COPILOT_DB;

-- ─────────────────────────────────────────────────────────────────────────────
-- SUB-AGENT 1: Analytics Agent (Cortex Analyst + Semantic View)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE AGENT AI.ANALYTICS_AGENT
  COMMENT = 'Sub-agent: Cortex Analyst for OEE metrics, asset health, and fleet data queries.'
  FROM SPECIFICATION $$
models:
  orchestration: auto

instructions:
  response: "Return precise numbers with units. When discussing assets, include triage lane and data quality verdict."
  orchestration: "Use the analyst tool to answer all data questions about OEE, asset health, downtime, failure probabilities, and fleet triage."

tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: plant_analyst
      description: "Converts natural language questions into SQL queries against manufacturing plant data — OEE intervals, asset health snapshots, downtime events, failure probabilities, triage lanes, and maintenance context."

tool_resources:
  plant_analyst:
    semantic_view: MFG_COPILOT_DB.SEMANTIC.MAINTENANCE_DECISION_SV
    execution_environment:
      type: warehouse
      warehouse: COMPUTE_WH
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- SUB-AGENT 2: Knowledge Agent (Cortex Search + Maintenance Manuals)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE AGENT AI.KNOWLEDGE_AGENT
  COMMENT = 'Sub-agent: Cortex Search for maintenance procedures, SOPs, safety guidelines, and checklists.'
  FROM SPECIFICATION $$
models:
  orchestration: auto

instructions:
  response: "Always cite the procedure code and section. Summarize key steps clearly."
  orchestration: "Use the manual search tool to find maintenance procedures, SOPs, safety guidelines, checklists, and technical instructions."

tools:
  - tool_spec:
      type: cortex_search
      name: manual_search
      description: "Searches the approved maintenance manual corpus for SOPs, bearing inspection procedures, safety checklists, lubrication guidelines, and technical instructions. Filter by STATUS=CURRENT for authoritative content."

tool_resources:
  manual_search:
    search_service: MFG_COPILOT_DB.SEMANTIC.MAINTENANCE_MANUAL_SEARCH
    max_results: 5
    title_column: TITLE
    id_column: CHUNK_ID
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- MASTER AGENT: MFG Copilot (agent_toolset orchestration)
-- Inherits all tools from ANALYTICS_AGENT and KNOWLEDGE_AGENT at runtime.
-- The master has ZERO tools of its own — pure orchestrator via agent_toolset.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE AGENT AI.MFG_COPILOT_AGENT
  COMMENT = 'Master agent: orchestrates Analytics and Knowledge sub-agents via agent_toolset for multi-agent manufacturing operations.'
  PROFILE = '{"display_name": "MFG Copilot", "color": "blue"}'
  FROM SPECIFICATION $$
models:
  orchestration: auto

instructions:
  response: "You are the MFG Copilot — a manufacturing operations assistant for a packaging plant. Be concise and data-driven. When referencing data, include specific numbers. When referencing procedures, cite the procedure code."
  orchestration: |
    You have access to two specialist toolsets inherited from sub-agents:
    1. Analytics tools (plant_analyst) — for OEE data, asset health metrics, downtime events, failure probabilities, and fleet triage status. Use for any quantitative or data question.
    2. Knowledge tools (manual_search) — for maintenance procedures, SOPs, safety guidelines, checklists, and technical instructions. Use for any procedural or knowledge question.
    For questions that span both data and procedures (e.g. 'What is P-204 failure probability and what safety steps are needed?'), use both tools and synthesize a unified answer.
  sample_questions:
    - question: "What is the current OEE for Packaging Line 2?"
    - question: "What is the bearing inspection procedure for pump P-204?"
    - question: "Which assets have the highest failure probability and what maintenance is recommended?"

tools:
  - tool_spec:
      type: agent_toolset
      name: analytics_tools
  - tool_spec:
      type: agent_toolset
      name: knowledge_tools

tool_resources:
  analytics_tools:
    agent_name: MFG_COPILOT_DB.AI.ANALYTICS_AGENT
  knowledge_tools:
    agent_name: MFG_COPILOT_DB.AI.KNOWLEDGE_AGENT
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- GRANTS
-- ─────────────────────────────────────────────────────────────────────────────
GRANT USAGE ON AGENT AI.ANALYTICS_AGENT TO ROLE MFG_RELIABILITY_ENGINEER;
GRANT USAGE ON AGENT AI.KNOWLEDGE_AGENT TO ROLE MFG_RELIABILITY_ENGINEER;
GRANT USAGE ON AGENT AI.MFG_COPILOT_AGENT TO ROLE MFG_RELIABILITY_ENGINEER;

-- Verification
SHOW AGENTS IN SCHEMA MFG_COPILOT_DB.AI;
