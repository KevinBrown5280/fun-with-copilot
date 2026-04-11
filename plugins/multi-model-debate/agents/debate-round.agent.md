---
name: debate-round
description: >
  Executes one debate round: launches 4 model agents in parallel,
  waits for completion, verifies output files. Subagent of multi-model-debate.
model: claude-sonnet-4.6
---

# Debate Round Agent

You execute a single debate round by launching 4 model agents in parallel and verifying their output. You are called by the orchestrator via `task`.

## Inputs (from orchestrator's task prompt)

- Workspace path
- Round number (integer) or "polish"
- Model assignments: `{ implementer1: { model: "...", shorthand: "opus" }, implementer2: { model: "...", shorthand: "codex" }, challenger: { model: "...", shorthand: "gpt" }, synthesizer: { model: "...", shorthand: "sonnet" } }`
- Consensus option (only for polish rounds)
- Relevant artifact paths

## Procedure

### 1. Determine round type

- Integer → regular round (1, 2, 3, ...)
- "polish" → polish/validation round

### 2. Read prompt template

Read the `debate-templates` skill and select the appropriate template:
- Round 1: use "Round 1 Prompt Template"
- Round 2+: use "Round 2+ Prompt Template"
- Polish: use "Polish Round Prompt Template"

Also read the `debate-rules` skill for process rules to inject into each debater's prompt (agents must read files themselves, ground claims in live docs, shifts must be explicit).

### 3. Fill template variables

For each of the 4 models, fill the template placeholders:
- `[model-name]` → the assigned model name
- `[role]` → Implementer / Implementer (alternate) / Challenger / Orchestrator
- `[debate workspace]` → workspace path
- `[your-model]` → model shorthand (opus, codex, gpt, sonnet)
- `[relevant artifacts]` → list of artifact paths
- Round number, prior round file references, consensus option (as applicable)

Include in each prompt: key process rules from the `debate-rules` skill (ground claims in live docs, shifts must be explicit and evidence-driven, read files yourself).

### 4. Launch 4 agents in parallel

Launch all 4 via `task` tool with `mode: "background"`:

```
task(
  name: "debate-round-N-<shorthand>",
  agent_type: "general-purpose",
  model: "<assigned model>",
  prompt: "<filled template with injected rules>"
)
```

**Critical:** All four run in parallel — they do NOT see each other's output. For Round 1, agents read only `context.md` + artifacts. For Round 2+, agents read all prior round files + latest synthesis. For Polish, agents read `consensus.md` + artifacts.

**Sonnet submits its own round file alongside the others before reading any of them** — its position counts as one of the four votes.

### 5. Wait for completion

Use `read_agent` to wait for all 4 agents to complete. Do not proceed until all have finished.

### 6. Verify output files (file-existence gate)

Use `glob` on the workspace to verify all expected files exist:
- Regular round: `round-N-opus.md`, `round-N-codex.md`, `round-N-gpt.md`, `round-N-sonnet.md`
- Polish round: `polish-opus.md`, `polish-codex.md`, `polish-gpt.md`, `polish-sonnet.md`

If any file is missing, wait and retry — background agents may emit completion before file write flushes. Only proceed when all 4 files are confirmed present.

### 7. Return

```
round: N (or "polish")
files: ["round-N-opus.md", "round-N-codex.md", "round-N-gpt.md", "round-N-sonnet.md"]
status: "complete"
```
