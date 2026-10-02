"""Manufacturing OEE Copilot — Project Ontology Graph
Generates an interactive ontology showing entity types and their relationships.
Opens directly in your browser — drag, zoom, click nodes.

Run:  python ontology_project.py
"""

import csv
from collections import defaultdict
from pyvis.network import Network

# ─── Load live data from Snowflake export ─────────────────────────────────

DATA_FILE = "c:/Users/riykhand/Downloads/ontology_edges.csv"

# Aggregate to schema-level: count edges between each (SRC_TYPE, REL_TYPE, DST_TYPE)
type_edges = defaultdict(lambda: {"count": 0, "derivations": set(), "sample_src": set(), "sample_dst": set()})
node_counts = defaultdict(set)

with open(DATA_FILE, "r") as f:
    for row in csv.DictReader(f, delimiter="|", quotechar='"'):
        st, sk = row["SRC_TYPE"], row["SRC_KEY"]
        dt, dk = row["DST_TYPE"], row["DST_KEY"]
        rel = row["REL_TYPE"]
        deriv = row["DERIVATION_METHOD"]

        key = (st, rel, dt)
        type_edges[key]["count"] += 1
        type_edges[key]["derivations"].add(deriv)
        type_edges[key]["sample_src"].add(sk)
        type_edges[key]["sample_dst"].add(dk)
        node_counts[st].add(sk)
        node_counts[dt].add(dk)

total_nodes = sum(len(v) for v in node_counts.values())
total_edges = sum(v["count"] for v in type_edges.values())

# ─── Node type styling ────────────────────────────────────────────────────

COLORS = {
    "Site": "#0EA5E9", "Area": "#38BDF8", "Line": "#29B5E8",
    "Asset": "#1E293B", "Component": "#475569", "Sensor": "#94A3B8",
    "FaultMode": "#EF4444", "MaintenanceTask": "#F59E0B",
    "Procedure": "#10B981", "Part": "#8B5CF6", "Tool": "#6366F1",
    "Skill": "#EC4899", "Technician": "#DB2777", "Supplier": "#7C3AED",
    "LossEvent": "#DC2626", "MaintenanceEvent": "#78716C",
    "MaintenanceWindow": "#0D9488", "WorkOrder": "#0369A1",
}

GROUPS = {
    "Site": "Hierarchy", "Area": "Hierarchy", "Line": "Hierarchy",
    "Asset": "Asset", "Component": "Asset", "Sensor": "Asset",
    "FaultMode": "Failure", "MaintenanceTask": "Maintenance",
    "Procedure": "Governance", "Part": "Supply Chain", "Tool": "Supply Chain",
    "Skill": "Workforce", "Technician": "Workforce", "Supplier": "Supply Chain",
    "LossEvent": "Events", "MaintenanceEvent": "Events",
    "MaintenanceWindow": "Scheduling", "WorkOrder": "Execution",
}

SHAPES = {
    "Hierarchy": "dot", "Asset": "dot", "Failure": "triangle",
    "Maintenance": "square", "Governance": "diamond", "Supply Chain": "star",
    "Workforce": "triangleDown", "Events": "dot", "Scheduling": "dot",
    "Execution": "square",
}

# ─── Build pyvis network ─────────────────────────────────────────────────

net = Network(
    height="900px", width="100%",
    bgcolor="#FAFAFA", font_color="#1E293B",
    directed=True, notebook=False,
    heading=""
)

net.barnes_hut(
    gravity=-8000, central_gravity=0.3,
    spring_length=250, spring_strength=0.04,
    damping=0.09, overlap=0
)

# Add entity type nodes
for ntype, instances in sorted(node_counts.items()):
    count = len(instances)
    color = COLORS.get(ntype, "#94A3B8")
    group = GROUPS.get(ntype, "Other")
    shape = SHAPES.get(group, "dot")
    samples = sorted(list(instances))[:5]

    net.add_node(
        ntype,
        label=f"{ntype}\n({count})",
        title=(
            f"{ntype}\n"
            f"Group: {group}\n"
            f"Instances: {count}\n"
            f"Examples: {', '.join(samples)}"
        ),
        color=color,
        size=15 + count * 0.8,
        shape=shape,
        font={"size": 14, "color": "white", "strokeWidth": 3, "strokeColor": "#334155"},
        borderWidth=2,
        borderWidthSelected=4,
    )

# Edge colors by relationship type
EDGE_COLORS = {
    "CONTAINS": "#94A3B8", "HAS_COMPONENT": "#64748B", "MONITORS": "#94A3B8",
    "SUSCEPTIBLE_TO": "#EF4444", "MITIGATED_BY": "#F59E0B",
    "GOVERNED_BY": "#10B981", "REQUIRES": "#6366F1",
    "COMPATIBLE_WITH": "#8B5CF6", "SUPPLIES": "#7C3AED",
    "HOLDS_SKILL": "#DB2777", "ADDRESSES": "#0369A1",
    "TEMPORALLY_ASSOCIATED_WITH": "#DC2626", "CONFIRMED_CAUSED_BY": "#B91C1C",
    "PERFORMED_ON": "#78716C", "INVESTIGATED": "#A8A29E",
    "CONFIRMS": "#059669", "REFUTES": "#DC2626",
    "HAS_WINDOW": "#0D9488", "RECORDED_LOSS": "#F87171",
}

# Add relationship edges
for (st, rel, dt), info in sorted(type_edges.items()):
    count = info["count"]
    derivations = ", ".join(sorted(info["derivations"]))
    is_inferred = "FOREIGN_KEY" not in info["derivations"] and "CURRENT_VERSION_RESOLUTION" not in info["derivations"]
    color = EDGE_COLORS.get(rel, "#CBD5E1")

    net.add_edge(
        st, dt,
        label=f"{rel} ({count})",
        title=(
            f"{st}  -->  {rel}  -->  {dt}\n"
            f"Edge count: {count}\n"
            f"Derivation: {derivations}\n"
            f"Sample sources: {', '.join(sorted(list(info['sample_src']))[:3])}\n"
            f"Sample targets: {', '.join(sorted(list(info['sample_dst']))[:3])}"
        ),
        color={"color": color, "opacity": 0.4 if is_inferred else 0.7},
        width=1 + count * 0.05,
        arrows={"to": {"enabled": True, "scaleFactor": 0.8}},
        dashes=is_inferred,
        font={"size": 10, "color": "#64748B", "align": "middle"},
        smooth={"type": "curvedCW", "roundness": 0.15},
    )

# ─── Save and open ────────────────────────────────────────────────────────

output = "c:/Users/riykhand/Downloads/ontology_project.html"
net.save_graph(output)

# Inject title banner into the HTML
with open(output, "r", encoding="utf-8") as f:
    html = f.read()

banner = """
<div style="background:#1E293B; color:white; padding:16px 24px; font-family:system-ui,sans-serif; margin-bottom:0;">
  <h2 style="margin:0 0 4px 0; font-size:20px;">Manufacturing OEE Copilot — Project Ontology</h2>
  <p style="margin:0; font-size:13px; color:#94A3B8;">
    {total_nodes} instances across {num_types} entity types, connected by {total_edges} edges ({num_rels} relationship types)<br>
    Source: <code>MFG_COPILOT_DB.CONTEXT.CONTEXT_EDGE</code> | Generated with NetworkX + pyvis
  </p>
  <p style="margin:8px 0 0 0; font-size:12px; color:#64748B;">
    Drag nodes to rearrange. Scroll to zoom. Click a node to see its connections. Hover for details.
  </p>
</div>
""".format(
    total_nodes=total_nodes,
    num_types=len(node_counts),
    total_edges=total_edges,
    num_rels=len(type_edges),
)

html = html.replace("<body>", "<body style='margin:0;padding:0;'>" + banner, 1)

with open(output, "w", encoding="utf-8") as f:
    f.write(html)

print(f"Project ontology: {len(node_counts)} entity types, {len(type_edges)} relationship types")
print(f"Full graph: {total_nodes} instances, {total_edges} edges")
print(f"Saved: {output}")
print("Opening in browser...")

import webbrowser
webbrowser.open("file:///" + output.replace("\\", "/"))
