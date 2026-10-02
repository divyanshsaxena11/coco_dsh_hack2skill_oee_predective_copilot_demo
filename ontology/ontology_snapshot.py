import csv, networkx as nx, matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.lines import Line2D

G = nx.DiGraph()
with open('c:/Users/riykhand/Downloads/ontology_edges.csv', 'r') as f:
    for row in csv.DictReader(f, delimiter='|', quotechar='"'):
        st, dt = row['SRC_KEY'], row['DST_KEY']
        G.add_node(st, node_type=row['SRC_TYPE'])
        G.add_node(dt, node_type=row['DST_TYPE'])
        G.add_edge(st, dt, rel=row['REL_TYPE'],
                   inferred=row['DERIVATION_METHOD'] not in ('FOREIGN_KEY', 'CURRENT_VERSION_RESOLUTION'))

center = 'P-204'
nodes = {center}
frontier = {center}
for _ in range(3):
    nf = set()
    for n in frontier:
        nf.update(G.successors(n))
        nf.update(G.predecessors(n))
    frontier = nf - nodes
    nodes.update(frontier)
SG = G.subgraph(nodes).copy()

COLORS = {
    'Site': '#0EA5E9', 'Area': '#38BDF8', 'Line': '#29B5E8',
    'Asset': '#1E293B', 'Component': '#475569', 'Sensor': '#94A3B8',
    'FaultMode': '#EF4444', 'MaintenanceTask': '#F59E0B',
    'Procedure': '#10B981', 'Part': '#8B5CF6', 'Tool': '#6366F1',
    'Skill': '#EC4899', 'Technician': '#DB2777', 'Supplier': '#7C3AED',
    'LossEvent': '#DC2626', 'MaintenanceEvent': '#78716C',
    'MaintenanceWindow': '#0D9488', 'WorkOrder': '#0369A1',
}
SIZES = {
    'Asset': 1800, 'Line': 1200, 'FaultMode': 1200, 'MaintenanceTask': 1100,
    'Component': 700, 'Sensor': 400, 'Part': 800, 'Tool': 600,
    'Skill': 700, 'Technician': 800, 'Supplier': 700, 'Procedure': 800,
    'LossEvent': 700, 'MaintenanceEvent': 500, 'MaintenanceWindow': 500,
    'WorkOrder': 600, 'Site': 1000, 'Area': 900,
}
EC = {
    'CONTAINS': '#94A3B8', 'HAS_COMPONENT': '#64748B', 'MONITORS': '#94A3B8',
    'SUSCEPTIBLE_TO': '#EF4444', 'MITIGATED_BY': '#F59E0B',
    'GOVERNED_BY': '#10B981', 'REQUIRES': '#6366F1',
    'COMPATIBLE_WITH': '#8B5CF6', 'SUPPLIES': '#7C3AED',
    'HOLDS_SKILL': '#DB2777', 'ADDRESSES': '#0369A1',
    'TEMPORALLY_ASSOCIATED_WITH': '#DC2626', 'CONFIRMED_CAUSED_BY': '#B91C1C',
    'PERFORMED_ON': '#78716C', 'INVESTIGATED': '#A8A29E',
    'CONFIRMS': '#059669', 'REFUTES': '#DC2626',
    'HAS_WINDOW': '#0D9488', 'RECORDED_LOSS': '#F87171',
}

pos = nx.spring_layout(SG, k=2.2, iterations=80, seed=42)
fig, ax = plt.subplots(figsize=(24, 17), facecolor='white')
ax.set_facecolor('#FAFAFA')

for u, v, d in SG.edges(data=True):
    inf = d.get('inferred', False)
    nx.draw_networkx_edges(SG, pos, edgelist=[(u, v)], ax=ax,
        edge_color=EC.get(d['rel'], '#CBD5E1'),
        style='--' if inf else '-', alpha=0.25 if inf else 0.45,
        width=0.8 if inf else 1.3, arrows=True, arrowsize=10, arrowstyle='-|>',
        connectionstyle='arc3,rad=0.08', min_source_margin=12, min_target_margin=12)

for node in SG.nodes():
    nt = SG.nodes[node].get('node_type', '?')
    nx.draw_networkx_nodes(SG, pos, nodelist=[node], ax=ax,
        node_color=COLORS.get(nt, '#94A3B8'), node_size=SIZES.get(nt, 500),
        alpha=0.9, edgecolors='#334155', linewidths=1.2)

short = {}
for n in SG.nodes():
    l = n
    if '/' in n and len(n) > 14:
        l = n.split('/')[-1][:11]
    elif len(n) > 14:
        l = n[:11] + '..'
    short[n] = l
nx.draw_networkx_labels(SG, pos, labels=short, ax=ax, font_size=6, font_color='white', font_weight='bold')

types = sorted(set(SG.nodes[n].get('node_type', '?') for n in SG.nodes()))
items = [mpatches.Patch(fc=COLORS.get(t, '#94A3B8'), ec='#334155', label=t) for t in types]
items.append(Line2D([0], [0], color='#475569', lw=1.3, ls='-', label='Structural (FK)'))
items.append(Line2D([0], [0], color='#DC2626', lw=0.8, ls='--', label='Inferred'))
ax.legend(handles=items, loc='upper left', fontsize=7, ncol=2, fancybox=True,
          edgecolor='#CBD5E1', facecolor='white', title='Entity Types', title_fontsize=8)
ax.set_title(
    f'P-204 Asset Ontology — Live Snowflake Data ({SG.number_of_nodes()} nodes, {SG.number_of_edges()} edges)\n'
    f'Source: MFG_COPILOT_DB.CONTEXT.CONTEXT_EDGE | NetworkX spring_layout',
    fontsize=14, fontweight='bold', color='#1E293B', pad=18)
ax.axis('off')
plt.tight_layout(pad=1.5)
plt.savefig('c:/Users/riykhand/Downloads/ontology_live_snapshot.png', dpi=150,
            bbox_inches='tight', facecolor='white')
print(f'Saved: {SG.number_of_nodes()} nodes, {SG.number_of_edges()} edges')
