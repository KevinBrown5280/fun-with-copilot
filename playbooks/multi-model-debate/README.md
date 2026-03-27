# Multi-Model Adversarial Debate

A **GitHub Copilot CLI** playbook — a structured process for reaching high-confidence
decisions on hard technical problems by running multiple AI models against each other
across adversarial debate rounds.

Use when a single model's judgment isn't enough.

## When to use

If you explicitly invoke the debate, it runs unconditionally. Otherwise, before proactively suggesting it, confirm **both**: the problem matches a criterion below, AND the cost of getting it wrong justifies the overhead.

- Multiple valid approaches exist and the tradeoffs are non-obvious
- A decision will be expensive to reverse (architecture, schema, public API)
- A previous automated fix produced an error affecting functional behavior, performance, or safety — not style, naming, or minor behavioral nits
- You need audit-quality reasoning, not just a recommendation
- A single model gave a confident answer you want pressure-tested, and the decision is expensive to reverse or affects correctness/safety

**Don't use for:** obvious fixes, bugs with a clear root cause, decisions that are cheap to reverse, choices that official docs answer directly, or questions a quick experiment would settle.

## How to invoke

### Step 1 — one-time setup

Add this to your `~/.copilot/copilot-instructions.md`:

```markdown
## Available playbooks

- **Multi-model adversarial debate** — structured process for high-confidence decisions
  on hard technical problems (architecture, bug fixes, platform selection, feature scoping)
  where a single model's judgment is insufficient.

  Full process: `<absolute-path-to-repo>/playbooks/multi-model-debate/multi-model-debate-process.md`

  Invoke by telling Copilot CLI:
  > "Use the debate process to decide [your question]"

  **Do not proactively suggest** this process for obvious fixes, decisions that are cheap to reverse, problems a quick test or lookup would settle, or style/naming choices. If the user explicitly asks to use it, always proceed — except for trivially factual questions with a single verifiable answer, where you should confirm intent first.
```

Replace `<absolute-path-to-repo>` with the local path to your clone of this repository.

### Step 2 — invoke

```
Use the debate process to decide [your question]
```

Examples:
- *"Use the debate process to decide whether to use Redis or Cosmos DB for session storage"*
- *"Use the debate process to fix the truncation bug in the PR review skill"*

### Direct invocation (no setup required)

If you haven't configured `copilot-instructions.md`, invoke directly:

> "Follow the process in `<absolute-path-to-repo>/playbooks/multi-model-debate/multi-model-debate-process.md` to decide [your question]"

## What you get

A `consensus.md` with each model's position, the strongest arguments on each side,
explicit shift points, and a final recommendation with full rationale. Optionally
followed by implementation, peer review, and a test cycle.

## Full process

→ [multi-model-debate-process.md](multi-model-debate-process.md)
