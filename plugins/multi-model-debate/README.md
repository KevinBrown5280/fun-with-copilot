# Multi-Model Adversarial Debate

A structured process for reaching high-confidence technical decisions using 4 AI models in adversarial debate. Designed for enterprise-level decisions — architecture, implementation choices, platform selection, feature scoping, bug fixes — where accuracy is more important than speed.

## What it does

- **4 models debate independently** across multiple rounds with genuinely different reasoning styles
- **Orchestrator synthesizes** positions each round and tracks vote changes (argument refinement without a vote change = no movement)
- **Consensus thresholds**: **4-of-4** = immediate consensus (skips directly to polish); **3-of-4** = near-consensus only (requires explicit rebuttal of dissenter's strongest objection plus 2 consecutive stuck rounds to confirm)
- **Polish round** validates the exact proposed output against 10 mandatory criteria
- **Implementer writes** production-ready artifact; a separate reviewer verifies
- **Full audit trail** in workspace files — every vote, position change, and synthesis is preserved

## Install

Add the marketplace source:
```
/plugin marketplace add KevinBrown5280/fun-with-copilot
```

Install the plugin:
```
/plugin install multi-model-debate@fun-with-copilot
```

Or from a local clone:

```bash
git clone https://github.com/KevinBrown5280/fun-with-copilot
```
Then inside the CLI:
```
/plugin install ./fun-with-copilot/plugins/multi-model-debate
```

That's it — the agent is installed and available immediately as `multi-model-debate`.

### Update

```
/plugin update multi-model-debate@fun-with-copilot
```

### Uninstall

```
/plugin uninstall multi-model-debate
```

To remove the marketplace source entirely:

```
/plugin marketplace remove fun-with-copilot
```

## Usage

**multi-model-debate must be invoked as a dedicated agent session** — it is an orchestrator that launches 4 independent model debaters in parallel. Asking a general Copilot session to "use the multi-model-debate agent" will not work: the orchestration pipeline won't load and only one model will run.

Use `/agent` to browse installed agents and select `multi-model-debate`. This starts a dedicated session with the full orchestration pipeline loaded.

Or launch directly from your terminal:

```
copilot --agent=multi-model-debate:multi-model-debate
```

Once in the dedicated session, type your question to begin:

```
Should we use Option A or Option B?
```

Leave the prompt empty and the agent will ask for your question.

## When to use

- Multiple valid approaches exist and tradeoffs are non-obvious
- A decision is expensive to reverse (architecture, public API, schema)
- You need audit-quality reasoning, not just a recommendation
- A single model's confident answer needs pressure-testing on a high-stakes decision

**Do not use for:** trivially factual questions, bugs with clear stack traces, style/naming choices, or decisions cheap to reverse.

## Architecture

This plugin uses the **E2 pattern** — thin orchestrator + phase subagents + shared knowledge skills:

1. **Orchestrator** (`multi-model-debate`) — pipeline sequencing and delegation only
2. **Setup subagent** (`debate-setup`) — creates workspace, selects models, writes context.md with verified facts
3. **Round subagent** (`debate-round`) — launches 4 model debaters in parallel per round
4. **Synthesizer subagent** (`debate-synthesizer`) — reads all positions, writes synthesis, detects consensus

Shared process knowledge lives in two skills:
- `debate-rules` — process rules, 10 mandatory criteria, convergence logic, model selection
- `debate-templates` — prompt templates for Round 1, Round 2+, and Polish rounds

Typical convergence: 2–4 rounds.

## How consensus works

**Movement = vote change.** A model refining its arguments without changing its vote has not moved. This keeps convergence signals objective.

| Outcome | Rule |
|---------|------|
| **4-of-4** | Consensus immediately — proceed to polish |
| **3-of-4** | Near-consensus — dissenter keeps debating under normal convergence rules. Confirmed after 2 consecutive rounds with no vote changes, provided the majority has explicitly rebutted the dissenter's strongest objection. Not valid before round 2. |
| **Stuck** | Synthesizer injects targeted questions each round. At round 6+, surfaces a check-in to you: current tally, core disagreement, continue or stop. Debate is also bounded by the orchestrator hard cap (`max_rounds`, default 10, configurable). |
| **Genuinely irreconcilable** | After 5 consecutive rounds with no vote changes in any non-2/2 split → fires a forcing-function round first (each camp must name one falsifiable criterion). If the split persists after the forcing function → writes `split-positions.md` automatically with each side's best case and a recommended next step (DEFER / ESCALATE / TEST) |

Hard round cap: `max_rounds` (default 10, configurable). No tiebreaker vote. Debates run until the evidence resolves the question, the cap force-resolves, or the split is documented for you to decide.

## Models

| Role | Model family | Strength |
|------|-------------|----------|
| Implementer (primary) | claude-opus (latest) | Deep reasoning, concedes when evidence is clear |
| Implementer (alternate) | gpt-codex (latest) | Strong code + empirical arguments |
| Challenger | gpt flagship (latest, non-codex) | Broad architectural perspective |
| Synthesizer | claude-sonnet (latest) | Reads all positions, writes synthesis, detects consensus |

No tiebreaker role — consensus is reached through debate, not a casting vote.

## Workspace output

A completed debate produces:
```
<workspace>/
  context.md                  ← master briefing
  round-1-opus.md             ← each model's Round 1 position
  round-1-codex.md
  round-1-gpt.md
  round-1-sonnet.md
  round-1-synthesis.md
  round-2-*.md                ← Round 2 positions + synthesis
  consensus.md                ← final decision with rationale
  polish-*.md                 ← validation verdicts
  implementation-notes.md     ← implementer's change description
  <reviewer>-review.md        ← reviewer's verdict
  split-positions.md          ← (if irreconcilable): each side's best case + recommended next step
```

## Relationship to process doc

The original human-readable process document remains at `playbooks/multi-model-debate/multi-model-debate-process.md` as a standalone reference. This plugin adapts that process into an invokable Copilot CLI agent with some material differences: no tiebreaker vote, plus an orchestrator-enforced hard round cap (`max_rounds`, default 10, configurable). Convergence rules and stuck-detection thresholds extend the process doc, including degraded-round paths (`degraded_unanimous_pending`, `present_count`-based near-consensus). For the authoritative convergence specification, refer to the [debate-rules skill file](skills/debate-rules/./SKILL.md) for core rules. **Degraded-round convergence paths** (`degraded_unanimous_pending`, `present_count`-based near-consensus) are now defined in `skills/debate-rules/SKILL.md` §5.1, with implementation details also in the orchestrator agent spec ([`agents/multi-model-debate.agent.md`](agents/multi-model-debate.agent.md), Step 2).
