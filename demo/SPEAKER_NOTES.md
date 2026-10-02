# Coco demo — five-minute story and speaker notes

## Editorial direction

Tell one story: **How did we use Coco to turn an OEE loss into a trusted maintenance decision?**

Use P-204 as the thread across the recordings. Start with the business problem and solution design, demonstrate Coco executing reusable skills and use the NetworkX ontology visualization to explain the connected context, then show the resulting application, scheduled workflow, and Slack connection. Streamlit is the shared operational interface for the solution.

This is a proposed edit based on the deck and original notes. The recordings have not yet been reviewed. Screen cues are requested selections, not verified footage or source timestamps. All figures and outputs must match the selected recording. The narration is approximately 600 words; allow pauses for viewers to read results and rehearse against the final edit.

## Timeline

| Final video | Visual | Point to establish |
|---|---|---|
| 0:00–0:08 | Slide 1 | Introduce the team and solution |
| 0:08–0:25 | Slide 2 | Explain the business problem and decision gaps |
| 0:25–0:45 | Slide 3; zoom to the six-phase workflow | Explain how Coco helped build the solution |
| 0:45–1:00 | Slide 4 | Frame intended impact and proposed scale |
| 1:00–1:30 | Custom skills: detect | Turn a business question into asset priority |
| 1:30–2:10 | Custom skills: validate; all checks pass | Establish that the sensor data passes the quality checks |
| 2:10–2:40 | NetworkX ontology demo: connect | Trace the asset through faults, tasks, procedures, and resources |
| 2:40–3:10 | Custom skills: compare | Produce a feasible, explainable next step |
| 3:10–3:45 | Streamlit and Cortex questions | Show the interface Coco built for users |
| 3:45–4:15 | Coco daily-alert automation | Show repeatable scheduled execution |
| 4:15–4:45 | Slack / MCP recording | Show evidence reaching the collaboration channel |
| 4:45–5:00 | Hold final result; add closing caption | Recap Coco’s role across the lifecycle |

## Ready-to-record narration

### 0:00–0:08 — Slide 1: introduction

“Hi, we’re Team Data Superheroes. Here’s how we used Coco to build our Manufacturing OEE and Maintenance Decision Copilot.”

### 0:08–0:25 — Slide 2: the business problem

“When equipment threatens production, teams need to know what’s causing the loss and what to do next. But sensor readings, maintenance history, and available resources sit in separate systems, making a trusted decision difficult.”

### 0:25–0:45 — Slide 3: how Coco helped solve it

“We used Coco to build the data foundation, Cortex services, and an ontology connecting assets, faults, and maintenance resources. Reusable skills guide the decision: detect the loss, validate evidence, connect the context, compare actions, and require human approval before staging a work-order draft.”

### 0:45–1:00 — Slide 4: intended impact and scale

“Our targets are faster decisions, less downtime, and better OEE, with every decision traceable. We’re demonstrating this with synthetic data for one plant. Let’s now follow one asset through the workflow, starting inside Coco.”

**Screen cue:** Open on slide 1 for the introduction, then move through slides 2–4. On slide 4, focus on target outcomes and single-plant demo scope. Present improvement figures as targets, not measured results. The introduction is included in the first minute, keeping the full video at five minutes.

### 1:00–1:30 — Coco skills: identify the loss

“We ask Coco: ‘Why is OEE deteriorating on Packaging Line 2?’ Our custom OEE skill breaks the loss into availability, performance, and quality, examines downtime, and prioritizes the assets that need attention. In this scenario, availability is the main concern, and P-204 rises to the top. Coco brings these steps together as one repeatable investigation. A time overlap is evidence to investigate; it does not, by itself, confirm the cause.”

**Screen cue:** Show the question and skill invocation, then the loss breakdown and P-204 result. Cut loading time. Avoid reading every metric.

### 1:30–2:10 — Coco skills: establish trust

“Before comparing maintenance actions, we ask Coco: ‘Can we trust P-204’s data?’ Our custom validation skill runs eight data-quality checks, covering freshness, gaps, units, range, flatlining, scale plausibility, tag health, and operating-state comparability.

“Here, all eight checks pass. The result gives us a clear view of the checks completed before proceeding. We used Coco to make this validation a repeatable step in the decision workflow. Passing these checks supports using the sensor evidence in the next stage; we still need to connect that evidence to the asset’s maintenance context.”

**Screen cue:** Show the validation question and the all-pass result. Move through the eight check names, then hold the overall passing status long enough to read. Describe only this successful validation run; no scenario switch or reset is needed.

### 2:10–2:40 — NetworkX ontology: connect the evidence

“With the quality checks passed, we now need to understand how this asset connects to the maintenance decision. We used Coco to model those relationships, visualized here using NetworkX and PyVis. Starting at P-204, we can trace its component, a potential fault, and the maintenance task linked to that fault. The task connects to required parts, skills, and procedures. These relationships give the workflow context for comparing actions.”

**Screen cue:** Switch to the ontology demo. Focus on P-204, then trace asset → component → fault mode → maintenance task → parts / skills / procedure. Use the actual visible node names and relationships. Zoom or move the pointer along this path; avoid spending the scene moving unrelated nodes. If supported in the recording, show evidence or relationship labels distinguishing a possible association from a confirmed fault. A graph connection alone does not establish a diagnosis.

**On-screen caption:** “CONNECT — Asset → fault → task → resources”

### 2:40–3:10 — Coco skills: compare feasible actions

“Using that connected context, we ask Coco for maintenance options. The skill compares actions against parts, qualified technicians, production windows, and safety constraints. Here, inspection is recommended, while replacement is blocked by the production-window constraint. We can see what is feasible and why. The wider workflow requires human approval before staging a work-order draft.”

**Screen cue:** Return from the graph to the options result. Highlight the recommended inspection and the reason replacement is blocked. Treat approval as a description of the wider workflow unless an approval and staging sequence is actually shown.

### 3:10–3:45 — Streamlit: the operational interface Coco built

“Coco also built the Streamlit command center, giving teams a shared view of OEE, fleet priorities, and data quality. Its embedded copilot uses Cortex Analyst for manufacturing metrics and Cortex Search for maintenance guidance. Here are a line-OEE question and a bearing-inspection question. Coco helped us build and configure these services and their routing, making the evidence accessible during a shift.”

**Screen cue:** Briefly show the summary and fleet status, then the two questions and their answers. Keep this to selected results rather than a six-tab tour. Show routing evidence if claiming that a particular recorded answer used Analyst or Search.

### 3:45–4:15 — Automation: repeat the workflow

“We then used Coco’s automation capability to schedule the daily reporting workflow. The scheduled task checks the manufacturing data, summarizes OEE and downtime, and highlights assets that need attention. This makes the investigation repeatable without someone manually starting the same sequence each day. Here we can see the automation setup and its recorded result.”

**Screen cue:** Show the schedule, configured task, and completed run if available. If only setup is recorded, replace the final sentence with: “Here we can see how that daily run is configured.”

### 4:15–4:45 — Slack: deliver the result

“The Slack demo shows how MCP connectivity extends this workflow into the team’s collaboration channel. Coco brings the manufacturing findings into a shared update, so people can review the line status and the assets requiring attention. This is the final handoff: the evidence investigated through Coco becomes information the production and maintenance team can use together.”

**Screen cue:** Show the MCP interaction and resulting Slack message. Confirm the direction of the integration before recording the voiceover. A Snowflake query followed by a Slack post demonstrates reporting through MCP; a Slack question answered through Cortex demonstrates a different, conversational flow. Describe only the flow actually recorded.

### 4:45–5:00 — Closing: Coco across the lifecycle

“We used Coco to design, build, test, and run this workflow—from manufacturing evidence to a governed maintenance recommendation, a shared application, and scheduled updates. That is the outcome: a repeatable decision process with evidence and human accountability built in.”

## Editing guidance

- Keep the introduction and slides 2–4 within one minute: eight seconds on the title page, then business problem, solution workflow, and intended impact and scale. On slide 3, focus on the six phases; do not read the full architecture.
- Start the demo in Coco, where the custom skills directly demonstrate its role in solving the problem.
- Use short captions: “Coco investigates,” “Coco validates,” “Coco connects the context,” “Coco compares,” “Coco builds the interface,” “Coco schedules,” and “MCP connects to Slack.”
- Give the ontology its own 30-second scene between validation and comparison. Trace one decision path through the graph so viewers understand how relationships inform the options.
- Preserve prompt → key result → explanation in each clip. Trim waiting and typing; keep important outputs at readable speed.
- Hold the all-pass validation result and the rejected replacement option long enough to read. Use them to explain how data quality and feasibility checks support the decision.
- Use a small “Synthetic demo scenario” label during the demo. Avoid calling an illustrative score a calibrated failure probability.
- If screen values differ between recordings, omit numeric narration and avoid edits that imply they are one continuous live run.
- Keep the closing over the final result rather than adding a dense capabilities slide.

## Claims to reconcile before final recording

1. **Skill count:** Slides 7 and 10 describe seven domain skills, including the orchestrator. The original notes say nine, adding deployment and demo utilities. Use “reusable custom skills” in the voiceover until the packaging is confirmed.
2. **Risk score:** The deck describes illustrative risk rules and synthetic data. Do not narrate “81.7% failure probability” as a validated prediction without evidence of calibration.
3. **Business impact:** Slide 4 presents targets; slide 5 contains stronger figures such as four hours to under fifteen minutes and 20–30% downtime reduction. Neither should be presented as a demonstrated result without measurement evidence.
4. **Agent routing:** Attribute runtime question routing to Cortex Agent / Analyst / Search, and explain that Coco helped build and configure it. Do not imply every Cortex runtime operation is performed by Coco itself.
5. **Slack flow:** The original notes describe Snowflake querying and posting to Slack; the request describes MCP connectivity with Cortex. Review the actual clip to establish the tool path and direction before choosing more specific narration.
6. **Scheduled execution:** A saved schedule proves configuration. A completed run and delivered message support a claim of execution. Daily scheduling should not be described as continuous monitoring.
7. **Guardrail count and scope:** The old notes say seven safety gates but enumerate six categories. The new narration avoids the count. Only describe a SQL hook's precise coverage if the implementation or recording supports it.

## Footage needed for the final cut

Provide the recordings or their local file paths: Streamlit, custom skills, NetworkX ontology visualization, daily-alert automation, and Slack/MCP. The ontology footage can be a segment within the Streamlit recording or a separate clip. After review, replace these screen cues with exact source in/out timestamps and adjust the narration to the visible outputs. This script does not require rerecording merely to follow the old tab order.
