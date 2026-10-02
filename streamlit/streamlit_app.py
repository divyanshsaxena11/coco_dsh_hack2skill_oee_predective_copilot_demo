"""
Manufacturing OEE & Maintenance Decision Copilot — Command Center
Streamlit-in-Snowflake application (5 tabs, business-user focused).

Tab 1: Executive Summary  — KPIs, OEE gauge, risk heatmap
Tab 2: OEE Deep Dive      — Trend, loss waterfall, shift comparison
Tab 3: Fleet Health        — Asset triage board with DQ, risk, condition
Tab 4: Maintenance Actions — Decision card, options, safety gates, procedures
Tab 5: Downtime & Quality  — Pareto, top reasons, quality yield
Tab 6: AI Copilot          — Chat with Cortex Analyst + Cortex Search
"""

import streamlit as st
from snowflake.snowpark.context import get_active_session
import plotly.express as px
import plotly.graph_objects as go
import pandas as pd
import json
import _snowflake

st.set_page_config(page_title="MFG Copilot Command Center", layout="wide")
session = get_active_session()

@st.cache_data(ttl=300, show_spinner=False)
def run(sql: str) -> pd.DataFrame:
    return session.sql(sql).to_pandas()

def run_no_cache(sql: str) -> pd.DataFrame:
    return session.sql(sql).to_pandas()

# ── Global context ──
ctx = run("""
    SELECT MFG_COPILOT_DB.GOVERNANCE.CURRENT_AS_OF() AS CLOCK,
           MFG_COPILOT_DB.GOVERNANCE.ACTIVE_SCENARIO() AS SCENARIO
""").iloc[0]
as_of, scenario = ctx["CLOCK"], ctx["SCENARIO"]

# ── Header ──
hdr1, hdr2, hdr3 = st.columns([4, 2, 2])
with hdr1:
    st.title("MFG Copilot Command Center")
with hdr2:
    st.metric("Plant Time", str(as_of)[:16])
with hdr3:
    st.metric("Operating Mode", scenario.replace('_', ' ').title())

st.divider()

tab1, tab2, tab3, tab4, tab5, tab6 = st.tabs([
    "Executive Summary", "OEE Deep Dive", "Fleet Health",
    "Maintenance Actions", "Downtime & Quality", "AI Copilot"
])

# ═════════════════════════════════════════════════════════════════════════════
# TAB 1 — EXECUTIVE SUMMARY
# ═════════════════════════════════════════════════════════════════════════════
with tab1:
    # KPI row
    kpi = run("""
        SELECT ROUND(AVG(OEE)*100,1) AS OEE,
               ROUND(AVG(AVAILABILITY)*100,1) AS AVAIL,
               ROUND(AVG(PERFORMANCE)*100,1) AS PERF,
               ROUND(AVG(QUALITY)*100,1) AS QUAL,
               ROUND(SUM(DOWNTIME_MIN),0) AS DT_MIN
        FROM MFG_COPILOT_DB.CORE.OEE_INTERVAL
        WHERE LINE_ID = 'PKG-L2'
          AND BUCKET_START >= DATEADD('hour', -8, MFG_COPILOT_DB.GOVERNANCE.CURRENT_AS_OF())
          AND PLANNED_PRODUCTION_MIN > 0
    """).iloc[0]

    fleet_summary = run("""
        SELECT COUNT(*) AS TOTAL,
               SUM(CASE WHEN TRIAGE_LANE = 'ACTION_CANDIDATE' THEN 1 ELSE 0 END) AS ACTION,
               SUM(CASE WHEN TRIAGE_LANE = 'SAFETY_ESCALATION' THEN 1 ELSE 0 END) AS SAFETY,
               SUM(CASE WHEN DQ_VERDICT = 'FAIL' THEN 1 ELSE 0 END) AS DQ_FAIL,
               SUM(CASE WHEN TRIAGE_LANE = 'MONITOR' THEN 1 ELSE 0 END) AS MONITOR
        FROM MFG_COPILOT_DB.AI.ASSET_HEALTH_SNAPSHOT
    """).iloc[0]

    c1, c2, c3, c4, c5, c6 = st.columns(6)
    c1.metric("OEE (8h)", f"{kpi['OEE']}%")
    c2.metric("Availability", f"{kpi['AVAIL']}%")
    c3.metric("Performance", f"{kpi['PERF']}%")
    c4.metric("Quality", f"{kpi['QUAL']}%")
    c5.metric("Downtime (8h)", f"{int(kpi['DT_MIN'])} min")
    c6.metric("Assets at Risk", f"{int(fleet_summary['ACTION'] + fleet_summary['SAFETY'])}")

    st.divider()

    # OEE Gauge + Fleet risk side by side
    left, right = st.columns(2)

    with left:
        st.subheader("OEE Gauge — Current Shift")
        oee_val = float(kpi['OEE'])
        fig_gauge = go.Figure(go.Indicator(
            mode="gauge+number",
            value=oee_val,
            number={"suffix": "%"},
            gauge={
                "axis": {"range": [0, 100]},
                "bar": {"color": "#3b82f6"},
                "steps": [
                    {"range": [0, 60], "color": "#fee2e2"},
                    {"range": [60, 80], "color": "#fef3c7"},
                    {"range": [80, 100], "color": "#dcfce7"}
                ],
                "threshold": {"line": {"color": "red", "width": 4}, "thickness": 0.75, "value": 85}
            }
        ))
        fig_gauge.update_layout(height=280, margin=dict(t=40, b=20, l=40, r=40))
        st.plotly_chart(fig_gauge, use_container_width=True)

    with right:
        st.subheader("Fleet Triage Distribution")
        triage = run("""
            SELECT TRIAGE_LANE, COUNT(*) AS CNT
            FROM MFG_COPILOT_DB.AI.ASSET_HEALTH_SNAPSHOT
            GROUP BY TRIAGE_LANE ORDER BY CNT DESC
        """)
        if not triage.empty:
            color_map = {
                "NORMAL": "#22c55e", "MONITOR": "#f59e0b",
                "ACTION_CANDIDATE": "#ef4444", "SAFETY_ESCALATION": "#dc2626",
                "DATA_UNUSABLE": "#6b7280", "OUT_OF_MODEL_SCOPE": "#a3a3a3"
            }
            fig_triage = px.pie(triage, names="TRIAGE_LANE", values="CNT",
                                color="TRIAGE_LANE", color_discrete_map=color_map,
                                hole=0.4)
            fig_triage.update_layout(height=280, margin=dict(t=30, b=20))
            st.plotly_chart(fig_triage, use_container_width=True)

    # Recent alerts
    st.subheader("Recent Downtime Alerts (24h)")
    alerts = run("""
        SELECT d.DOWNTIME_ID,
               COALESCE(d.ASSET_ID, 'Unassigned') AS ASSET_ID,
               d.REASON_DESCRIPTION,
               d.DURATION_MIN, d.ASSOC_METHOD, d.SHIFT_CODE,
               d.START_TS, d.IS_PLANNED
        FROM MFG_COPILOT_DB.CORE.DOWNTIME_EVENT d
        WHERE d.START_TS >= DATEADD('hour', -24, MFG_COPILOT_DB.GOVERNANCE.CURRENT_AS_OF())
        ORDER BY d.START_TS DESC
    """)
    if not alerts.empty:
        st.dataframe(alerts, use_container_width=True, hide_index=True)
    else:
        st.info("No downtime events in the last 24 hours.")


# ═════════════════════════════════════════════════════════════════════════════
# TAB 2 — OEE DEEP DIVE
# ═════════════════════════════════════════════════════════════════════════════
with tab2:
    st.header("OEE Trend — Packaging Line 2")

    lookback = st.selectbox("Lookback period", ["24 hours", "3 days", "7 days", "14 days", "All"], index=2)
    hours_map = {"24 hours": 24, "3 days": 72, "7 days": 168, "14 days": 336, "All": 9999}

    oee = run(f"""
        SELECT BUCKET_START, AVAILABILITY, PERFORMANCE, QUALITY, OEE,
               DOWNTIME_MIN, SHIFT_CODE
        FROM MFG_COPILOT_DB.CORE.OEE_INTERVAL
        WHERE LINE_ID = 'PKG-L2' AND PLANNED_PRODUCTION_MIN > 0
          AND BUCKET_START >= DATEADD('hour', -{hours_map[lookback]},
              MFG_COPILOT_DB.GOVERNANCE.CURRENT_AS_OF())
        ORDER BY BUCKET_START
    """)

    if not oee.empty:
        # Trend chart
        fig_oee = go.Figure()
        colors = {"AVAILABILITY": "#ef4444", "PERFORMANCE": "#f59e0b",
                  "QUALITY": "#22c55e", "OEE": "#3b82f6"}
        for col_name, color in colors.items():
            fig_oee.add_trace(go.Scatter(
                x=oee["BUCKET_START"], y=oee[col_name],
                mode="lines", name=col_name.title(),
                line=dict(width=3 if col_name == "OEE" else 1.5, color=color)))
        fig_oee.add_hline(y=0.85, line_dash="dash", line_color="gray",
                          annotation_text="85% Target")
        fig_oee.update_layout(height=380, margin=dict(t=30, b=30),
                              yaxis_tickformat=".0%",
                              legend=dict(orientation="h", y=1.12))
        st.plotly_chart(fig_oee, use_container_width=True)

        # Loss waterfall
        st.subheader("Current Shift Loss Decomposition")
        loss = run("""
            WITH cur AS (
                SELECT AVG(AVAILABILITY) a, AVG(PERFORMANCE) p, AVG(QUALITY) q
                FROM MFG_COPILOT_DB.CORE.OEE_INTERVAL
                WHERE LINE_ID='PKG-L2'
                  AND BUCKET_START >= DATE_TRUNC('day',
                      MFG_COPILOT_DB.GOVERNANCE.CURRENT_AS_OF()) + INTERVAL '6 hours'
                  AND PLANNED_PRODUCTION_MIN > 0
            )
            SELECT 'Availability' AS FACTOR, ROUND((1-a)*100,2) AS LOSS_PP FROM cur
            UNION ALL SELECT 'Performance', ROUND((1-p)*100,2) FROM cur
            UNION ALL SELECT 'Quality', ROUND((1-q)*100,2) FROM cur
        """)
        if not loss.empty:
            fig_loss = px.bar(loss, x="FACTOR", y="LOSS_PP", color="FACTOR",
                              color_discrete_map={"Availability": "#ef4444",
                                                  "Performance": "#f59e0b",
                                                  "Quality": "#22c55e"},
                              labels={"LOSS_PP": "Loss (percentage points)"})
            fig_loss.update_layout(height=300, showlegend=False,
                                   margin=dict(t=20, b=20))
            st.plotly_chart(fig_loss, use_container_width=True)

        # Daily OEE summary
        st.subheader("Daily OEE Summary")
        daily = run("""
            SELECT DATE_TRUNC('day', BUCKET_START) AS DAY,
                   ROUND(AVG(OEE)*100,1) AS AVG_OEE,
                   ROUND(AVG(AVAILABILITY)*100,1) AS AVG_AVAIL,
                   ROUND(SUM(DOWNTIME_MIN),0) AS TOTAL_DT_MIN,
                   COUNT(*) AS INTERVALS
            FROM MFG_COPILOT_DB.CORE.OEE_INTERVAL
            WHERE LINE_ID = 'PKG-L2' AND PLANNED_PRODUCTION_MIN > 0
            GROUP BY DAY ORDER BY DAY DESC
        """)
        if not daily.empty:
            st.dataframe(daily, use_container_width=True, hide_index=True)


# ═════════════════════════════════════════════════════════════════════════════
# TAB 3 — FLEET HEALTH
# ═════════════════════════════════════════════════════════════════════════════
with tab3:
    st.header("Asset Fleet Health Board")

    fleet = run("""
        SELECT ASSET_ID, ASSET_NAME, CRITICALITY, TRIAGE_LANE, DQ_VERDICT,
               ROUND(FAILURE_PROBABILITY*100,1) AS FAIL_PROB_PCT,
               ROUND(PCT_ABOVE_BASELINE*100,1) AS PCT_ABOVE_BL,
               RUL_LOW_DAYS, RUL_HIGH_DAYS,
               ROUND(PRIORITY_SCORE, 3) AS PRIORITY,
               IN_SCOPE, SCORE_EXPLANATION
        FROM MFG_COPILOT_DB.AI.ASSET_HEALTH_SNAPSHOT
        ORDER BY PRIORITY_SCORE DESC NULLS LAST
    """)

    if not fleet.empty:
        # Triage filter
        lanes = ["All"] + fleet["TRIAGE_LANE"].unique().tolist()
        selected_lane = st.selectbox("Filter by Triage Lane", lanes)
        filtered = fleet if selected_lane == "All" else fleet[fleet["TRIAGE_LANE"] == selected_lane]

        st.dataframe(
            filtered.style.applymap(
                lambda v: "background-color: #fee2e2" if v == "ACTION_CANDIDATE"
                else ("background-color: #fef3c7" if v == "MONITOR"
                      else ("background-color: #e5e7eb" if v in ("DATA_UNUSABLE", "FAIL")
                            else "")),
                subset=["TRIAGE_LANE", "DQ_VERDICT"]
            ),
            use_container_width=True, hide_index=True, height=400
        )

        # Failure probability bar chart
        st.subheader("Failure Probability by Asset")
        prob_data = fleet[fleet["FAIL_PROB_PCT"].notna()].sort_values("FAIL_PROB_PCT", ascending=True)
        if not prob_data.empty:
            fig_prob = px.bar(prob_data, x="FAIL_PROB_PCT", y="ASSET_ID",
                              orientation="h", color="TRIAGE_LANE",
                              color_discrete_map={
                                  "NORMAL": "#22c55e", "MONITOR": "#f59e0b",
                                  "ACTION_CANDIDATE": "#ef4444",
                                  "OUT_OF_MODEL_SCOPE": "#a3a3a3"
                              },
                              labels={"FAIL_PROB_PCT": "Failure Probability %"})
            fig_prob.update_layout(height=max(250, len(prob_data)*25),
                                   margin=dict(t=20, b=20))
            st.plotly_chart(fig_prob, use_container_width=True)

        # Data quality summary
        st.subheader("Data Quality Verdicts")
        dq = run("""
            SELECT DQ_VERDICT, COUNT(*) AS ASSETS
            FROM MFG_COPILOT_DB.AI.ASSET_HEALTH_SNAPSHOT
            GROUP BY DQ_VERDICT
        """)
        dq1, dq2 = st.columns(2)
        with dq1:
            st.dataframe(dq, use_container_width=True, hide_index=True)
        with dq2:
            p204_dq = run("""
                SELECT * FROM TABLE(MFG_COPILOT_DB.GOVERNANCE.VALIDATE_SENSOR_CONTEXT('P-204'))
            """)
            st.caption("P-204 DQ Checks (8 gates)")
            st.dataframe(p204_dq[["CHECK_CODE", "STATUS", "OBSERVED"]],
                         use_container_width=True, hide_index=True)


# ═════════════════════════════════════════════════════════════════════════════
# TAB 4 — MAINTENANCE ACTIONS
# ═════════════════════════════════════════════════════════════════════════════
with tab4:
    st.header("Maintenance Decision Support")

    asset_pick = st.selectbox("Select Asset", ["P-204", "P-205", "P-201", "P-202", "P-203"])

    # Asset snapshot
    snap = run_no_cache(f"""
        SELECT ASSET_ID, ASSET_NAME, CRITICALITY, TRIAGE_LANE, DQ_VERDICT,
               ROUND(FAILURE_PROBABILITY*100,1) AS FAIL_PROB_PCT,
               OVERLAP_STOPS_24H, OVERLAP_STOP_MIN_24H
        FROM MFG_COPILOT_DB.AI.ASSET_HEALTH_SNAPSHOT
        WHERE ASSET_ID = '{asset_pick}'
    """)

    if not snap.empty:
        s = snap.iloc[0]
        m1, m2, m3, m4 = st.columns(4)
        m1.metric("Triage Lane", s["TRIAGE_LANE"])
        m2.metric("DQ Verdict", s["DQ_VERDICT"])
        m3.metric("Failure Prob", f"{s['FAIL_PROB_PCT']}%" if pd.notna(s['FAIL_PROB_PCT']) else "N/A")
        m4.metric("Downtime Overlaps (24h)", f"{int(s['OVERLAP_STOPS_24H'])} stops")

    st.divider()

    # Maintenance options
    st.subheader("Recommended Maintenance Options")
    options = run_no_cache(f"""
        SELECT OPTION_ID, ACTION, TIMING, FEASIBLE, INFEASIBLE_REASON,
               IS_RECOMMENDED, TASK_CODE, PROCEDURE_REF,
               ROUND(ESTIMATED_NET_VALUE, 0) AS NET_VALUE,
               ROUND(MAINTENANCE_COST, 0) AS COST,
               ROUND(RISK_REDUCTION_VALUE, 0) AS RISK_REDUCTION,
               REQUIRED_PARTS, PART_AVAILABLE, QUALIFIED_TECHNICIANS
        FROM TABLE(MFG_COPILOT_DB.DECISION.EVALUATE_MAINTENANCE_OPTIONS('{asset_pick}'))
        ORDER BY OPTION_RANK NULLS LAST
    """)

    if not options.empty:
        rec = options[options["IS_RECOMMENDED"] == True]
        if not rec.empty:
            r = rec.iloc[0]
            st.success(f"**Recommended: {r['ACTION']}** — Net value ${r['NET_VALUE']:,.0f} | "
                       f"Cost ${r['COST']:,.0f} | Risk reduction ${r['RISK_REDUCTION']:,.0f} | "
                       f"Timing: {r['TIMING']}")

        st.dataframe(options[["OPTION_ID", "ACTION", "TIMING", "FEASIBLE",
                              "NET_VALUE", "COST", "RISK_REDUCTION",
                              "REQUIRED_PARTS", "PART_AVAILABLE"]],
                     use_container_width=True, hide_index=True)

        infeasible = options[options["FEASIBLE"] == False]
        if not infeasible.empty:
            st.warning("**Infeasible options:**")
            for _, row in infeasible.iterrows():
                st.caption(f"{row['OPTION_ID']}: {row['INFEASIBLE_REASON']}")

    # Safety gates
    st.subheader("Safety Gate Results")
    gates = run_no_cache(f"""
        SELECT GATE_CODE, VERDICT, REASON
        FROM TABLE(MFG_COPILOT_DB.GOVERNANCE.CHECK_MAINTENANCE_SAFETY('{asset_pick}', 'BRG_INSPECT'))
    """)
    if not gates.empty:
        for _, g in gates.iterrows():
            icon = "white_check_mark" if g["VERDICT"] == "PASS" else "x"
            st.markdown(f":{icon}: **{g['GATE_CODE']}** — {g['REASON']}")

    # Ontology neighbourhood
    st.subheader("Asset Ontology Neighbourhood")
    edges = run_no_cache(f"""
        SELECT SRC_TYPE, SRC_KEY, REL_TYPE, DST_TYPE, DST_KEY, DERIVATION_METHOD
        FROM MFG_COPILOT_DB.CONTEXT.CONTEXT_EDGE
        WHERE SRC_KEY = '{asset_pick}' OR DST_KEY = '{asset_pick}'
        ORDER BY DERIVATION_METHOD, REL_TYPE
    """)
    if not edges.empty:
        st.dataframe(edges, use_container_width=True, hide_index=True)
        st.caption(f"{len(edges)} edges connected to {asset_pick}")


# ═════════════════════════════════════════════════════════════════════════════
# TAB 5 — DOWNTIME & QUALITY
# ═════════════════════════════════════════════════════════════════════════════
with tab5:
    st.header("Downtime Analysis & Quality Metrics")

    left5, right5 = st.columns(2)

    with left5:
        st.subheader("Top Downtime Reasons (All Time)")
        pareto = run("""
            SELECT REASON_DESCRIPTION, COUNT(*) AS OCCURRENCES,
                   ROUND(SUM(DURATION_MIN), 0) AS TOTAL_MIN
            FROM MFG_COPILOT_DB.CORE.DOWNTIME_EVENT
            WHERE REASON_DESCRIPTION IS NOT NULL
            GROUP BY REASON_DESCRIPTION
            ORDER BY TOTAL_MIN DESC
            LIMIT 10
        """)
        if not pareto.empty:
            fig_pareto = px.bar(pareto, x="TOTAL_MIN", y="REASON_DESCRIPTION",
                                orientation="h", color="OCCURRENCES",
                                color_continuous_scale="Reds",
                                labels={"TOTAL_MIN": "Total Minutes",
                                        "REASON_DESCRIPTION": "Reason"})
            fig_pareto.update_layout(height=400, margin=dict(t=20, b=20),
                                     yaxis={"categoryorder": "total ascending"})
            st.plotly_chart(fig_pareto, use_container_width=True)

    with right5:
        st.subheader("Downtime by Association Method")
        assoc = run("""
            SELECT ASSOC_METHOD, COUNT(*) AS STOPS,
                   ROUND(SUM(DURATION_MIN), 0) AS TOTAL_MIN
            FROM MFG_COPILOT_DB.CORE.DOWNTIME_EVENT
            GROUP BY ASSOC_METHOD ORDER BY TOTAL_MIN DESC
        """)
        if not assoc.empty:
            fig_assoc = px.pie(assoc, names="ASSOC_METHOD", values="TOTAL_MIN",
                               hole=0.4,
                               color_discrete_sequence=["#3b82f6", "#f59e0b", "#22c55e", "#6b7280"])
            fig_assoc.update_layout(height=400, margin=dict(t=30, b=20))
            st.plotly_chart(fig_assoc, use_container_width=True)

    st.divider()

    # Quality metrics
    st.subheader("Quality Yield Trend")
    quality = run("""
        SELECT DATE_TRUNC('day', BUCKET_START) AS DAY,
               ROUND(AVG(QUALITY)*100, 1) AS AVG_QUALITY_PCT,
               SUM(GOOD_COUNT) AS GOOD,
               SUM(SCRAP_COUNT) AS SCRAP,
               SUM(REWORK_COUNT) AS REWORK
        FROM MFG_COPILOT_DB.CORE.OEE_INTERVAL
        WHERE LINE_ID = 'PKG-L2' AND PLANNED_PRODUCTION_MIN > 0
        GROUP BY DAY ORDER BY DAY
    """)
    if not quality.empty:
        fig_q = go.Figure()
        fig_q.add_trace(go.Bar(x=quality["DAY"], y=quality["GOOD"],
                                name="Good", marker_color="#22c55e"))
        fig_q.add_trace(go.Bar(x=quality["DAY"], y=quality["SCRAP"],
                                name="Scrap", marker_color="#ef4444"))
        fig_q.add_trace(go.Bar(x=quality["DAY"], y=quality["REWORK"],
                                name="Rework", marker_color="#f59e0b"))
        fig_q.update_layout(barmode="stack", height=350,
                            margin=dict(t=30, b=30),
                            legend=dict(orientation="h", y=1.12))
        st.plotly_chart(fig_q, use_container_width=True)

    # Planned vs unplanned
    st.subheader("Planned vs Unplanned Downtime")
    planned = run("""
        SELECT CASE WHEN IS_PLANNED THEN 'Planned' ELSE 'Unplanned' END AS TYPE,
               COUNT(*) AS STOPS, ROUND(SUM(DURATION_MIN), 0) AS TOTAL_MIN
        FROM MFG_COPILOT_DB.CORE.DOWNTIME_EVENT
        GROUP BY IS_PLANNED
    """)
    if not planned.empty:
        p1, p2 = st.columns(2)
        for _, row in planned.iterrows():
            col = p1 if row["TYPE"] == "Planned" else p2
            col.metric(f"{row['TYPE']} Stops", f"{int(row['STOPS'])} events")
            col.metric(f"{row['TYPE']} Duration", f"{int(row['TOTAL_MIN'])} min")

# ═════════════════════════════════════════════════════════════════════════════
# TAB 6 — AI COPILOT (Cortex Analyst + Cortex Search)
# ═════════════════════════════════════════════════════════════════════════════
with tab6:
    st.header("AI Copilot — Ask Questions About Your Plant")
    st.caption("Powered by Cortex Analyst (text-to-SQL) and Cortex Search (procedure retrieval)")

    # Initialize chat history
    if "messages" not in st.session_state:
        st.session_state.messages = []

    # Suggested questions
    st.markdown("**Try asking:**")
    suggestions = [
        "What is the current OEE for Packaging Line 2?",
        "Which assets have the highest failure probability?",
        "How many downtime events happened in the last 24 hours?",
        "What is the bearing inspection procedure for P-204?",
        "Show me the top 5 downtime reasons by total minutes",
        "What safety precautions are needed for bearing replacement?"
    ]
    scols = st.columns(3)
    for i, s in enumerate(suggestions):
        if scols[i % 3].button(s, key=f"sug_{i}", use_container_width=True):
            st.session_state.messages.append({"role": "user", "content": s})

    st.divider()

    # Display chat history
    for msg in st.session_state.messages:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"])
            if "data" in msg:
                st.dataframe(pd.DataFrame(msg["data"]), use_container_width=True, hide_index=True)

    # Chat input
    if user_input := st.chat_input("Ask about OEE, assets, maintenance, or procedures..."):
        st.session_state.messages.append({"role": "user", "content": user_input})
        with st.chat_message("user"):
            st.markdown(user_input)

        with st.chat_message("assistant"):
            with st.spinner("Thinking..."):
                # Determine if this is a data question or a procedure question
                lower_q = user_input.lower()
                is_procedure_q = any(kw in lower_q for kw in [
                    "procedure", "sop", "safety", "precaution", "step",
                    "instruction", "manual", "how to", "guideline", "checklist"
                ])

                response_parts = []
                response_data = None

                # Cortex Analyst — text-to-SQL via semantic view
                if not is_procedure_q:
                    try:
                        analyst_resp = _snowflake.send_snow_api_request(
                            "POST",
                            "/api/v2/cortex/analyst/message",
                            {},
                            {},
                            {
                                "messages": [{"role": "user", "content": [{"type": "text", "text": user_input}]}],
                                "semantic_model": "@MFG_COPILOT_DB.SEMANTIC.MAINTENANCE_DECISION_SV"
                            },
                            {},
                            30000
                        )
                        resp_json = json.loads(analyst_resp["content"])
                        msg_content = resp_json.get("message", {}).get("content", [])

                        for block in msg_content:
                            if block.get("type") == "text":
                                response_parts.append(block["text"])
                            elif block.get("type") == "sql":
                                sql_text = block["statement"]
                                response_parts.append(f"```sql\n{sql_text}\n```")
                                try:
                                    result_df = run(sql_text)
                                    if not result_df.empty:
                                        st.dataframe(result_df, use_container_width=True, hide_index=True)
                                        response_data = result_df.to_dict("records")
                                except Exception as sql_err:
                                    response_parts.append(f"Query execution error: {sql_err}")
                    except Exception as e:
                        response_parts.append(f"Cortex Analyst returned an error. Falling back to Cortex Search.")
                        is_procedure_q = True

                # Cortex Search — procedure retrieval
                if is_procedure_q:
                    try:
                        search_resp = _snowflake.send_snow_api_request(
                            "POST",
                            f"/api/v2/databases/MFG_COPILOT_DB/schemas/SEMANTIC/cortex-search-services/MAINTENANCE_MANUAL_SEARCH:query",
                            {},
                            {},
                            {
                                "query": user_input,
                                "columns": ["CHUNK_TEXT", "PROCEDURE_CODE", "SECTION", "TITLE", "DOCUMENT_TYPE"],
                                "filter": {"@eq": {"STATUS": "CURRENT"}},
                                "limit": 3
                            },
                            {},
                            30000
                        )
                        search_json = json.loads(search_resp["content"])
                        results = search_json.get("results", [])

                        if results:
                            response_parts.append("**Relevant Maintenance Procedures:**\n")
                            for i, r in enumerate(results, 1):
                                proc = r.get("PROCEDURE_CODE", "Unknown")
                                section = r.get("SECTION", "")
                                title = r.get("TITLE", "")
                                text = r.get("CHUNK_TEXT", "")
                                doc_type = r.get("DOCUMENT_TYPE", "")
                                response_parts.append(
                                    f"**{i}. {proc}** — {title}\n"
                                    f"*Section: {section} | Type: {doc_type}*\n\n"
                                    f"{text[:500]}{'...' if len(text) > 500 else ''}\n\n---"
                                )
                        else:
                            response_parts.append("No matching procedures found.")
                    except Exception as e:
                        response_parts.append(f"Cortex Search error: {e}")

                full_response = "\n".join(response_parts) if response_parts else "I couldn't find an answer. Try rephrasing your question."
                st.markdown(full_response)

                msg_entry = {"role": "assistant", "content": full_response}
                if response_data:
                    msg_entry["data"] = response_data
                st.session_state.messages.append(msg_entry)

# ── Footer ──
st.divider()
st.caption(f"MFG Copilot Command Center · Powered by Snowflake Cortex · {str(as_of)[:16]}")
