# Multi-Model Adversarial Code Review

A **GitHub Copilot CLI** playbook — a structured process for finding real bugs and security issues
by running 4 AI models independently against your codebase, reconciling their findings with a
transparent voting system, and persisting dismissed findings across sessions so they never come back.

Validated across 16 fix cycles on a production codebase (83 confirmed issues found, 13 dismissed).

## What it does

1. **4 independent reviewers** run in parallel — Opus, Codex, GPT-5.4, and Sonnet each review your entire codebase without seeing each other's output
2. **Voting reconciliation** — 3/4 confirm = confirmed; 3/4 dismiss = dismissed; 2-2 split = orchestrator resolves by reasoning quality
3. **Cross-session dismissal suppression** — findings you've dismissed are fingerprinted (sha256) and never re-raised in future sessions
4. **Two modes**: `review-only` (find and report) and `review-and-fix` (find, fix, re-review until clean)
5. **Durable audit trail** — JSONL ledgers + per-cycle markdown reports in `.adversarial-review/`

## Setup — one time

### Step 1 — install the agent

Copy `adversarial-review.agent.md` to `~/.copilot/agents/`:

**macOS/Linux:**
```bash
mkdir -p ~/.copilot/agents
cp adversarial-review.agent.md ~/.copilot/agents/
```

**Windows (PowerShell):**
```powershell
New-Item -ItemType Directory -Path "$env:USERPROFILE\.copilot\agents" -Force
Copy-Item adversarial-review.agent.md "$env:USERPROFILE\.copilot\agents\"
```

### Step 2 — add to custom instructions

Add this to `~/.copilot/copilot-instructions.md`:

```markdown
- **Multi-model adversarial code review** — invoke with `copilot --agent=adversarial-review`
  for 4-model independent review with voting reconciliation. Supports review-only and
  review-and-fix modes. Durable state stored in `.adversarial-review/` at the repo root.
```

### Step 3 — initialize a repo (optional but recommended)

In your target repo, create the `.adversarial-review/` directory:

**macOS/Linux:**
```bash
mkdir -p .adversarial-review/reports
touch .adversarial-review/dismissed-findings.jsonl
touch .adversarial-review/confirmed-findings.jsonl
```

**Windows (PowerShell):**
```powershell
New-Item -ItemType Directory -Path ".adversarial-review\reports" -Force
New-Item -ItemType File -Path ".adversarial-review\dismissed-findings.jsonl" -Force
New-Item -ItemType File -Path ".adversarial-review\confirmed-findings.jsonl" -Force
```

Or copy from the template in this repo:
```bash
cp -r .adversarial-review-template/ /path/to/your-repo/.adversarial-review/
```

The agent creates this directory automatically on first run if it doesn't exist — this step is optional.

### Step 4 — optionally configure per-repo

Copy `config.json.example` from `.adversarial-review-template/` to `.adversarial-review/config.json`
in your repo and customize it:

```json
{
  "primary_language": "csharp",
  "framework": "aspnet-core",
  "exclude_patterns": ["*.env", "*.pfx", "migrations/", "node_modules/"],
  "min_severity": "low",
  "default_mode": "review-only",
  "known_safe": [
    "Intentional use of dynamic SQL in stored procedure generator — reviewed 2025-01-15"
  ]
}
```

This file is optional. Without it, the agent auto-detects language/framework and uses sensible defaults.

## Usage

From your repo directory in Copilot CLI:

```
copilot --agent=adversarial-review                            # uses default_mode from config
copilot --agent=adversarial-review --prompt "review-only"    # find and report only
copilot --agent=adversarial-review --prompt "review-and-fix" # find, fix, re-review until clean
```

Or in conversation:
```
Run adversarial code review — review only
Run adversarial code review — review and fix
```

## What you get

**Review-only**: A markdown report at `.adversarial-review/reports/YYYY-MM-DD-cycle-1-report.md`
with all confirmed findings (by severity), all dismissed findings (with reasons), vote detail,
and cross-reference tables by file and category.

**Review-and-fix**: The same, repeated across cycles. Codex implements fixes after each cycle,
all 4 models re-review from scratch, loop terminates when a clean cycle completes
(zero confirmed findings, all prior findings marked fixed).

## Repo state

```
.adversarial-review/
├── dismissed-findings.jsonl   # append-only, cross-session dismissal ledger
├── confirmed-findings.jsonl   # append-only, confirmed findings with fix status
├── config.json                # optional repo-specific config (you create this)
└── reports/
    ├── 2025-07-14-cycle-1-report.md
    └── ...
```

Commit `.adversarial-review/` to git for a full audit trail and to survive machine changes.
Add it to `.gitignore` if you prefer ephemeral state.

## How the voting works

| Vote tally | Decision |
|-----------|----------|
| 3 or 4 confirm | Confirmed ✓ |
| 0 or 1 confirm | Dismissed ✗ |
| 2 confirm, 2 dismiss | Orchestrator resolves by reasoning quality |

A model that didn't raise a finding counts as an implicit dismiss vote. No separate second-pass adjudication.

## Dismissal fingerprinting

Each dismissed finding gets a deterministic fingerprint:
```
fp_v1 = sha256(category | repo_path | scope | title | evidence)[:16]
```
This fingerprint is stored in `dismissed-findings.jsonl`. In future sessions, any finding matching
a stored fingerprint is suppressed before voting — it never surfaces again unless you manually
remove it from the ledger.

## Models used

| Role | Model |
|------|-------|
| Implementer | `claude-opus-4.6` |
| Implementer Alternate | `gpt-5.3-codex` |
| Challenger | `gpt-5.4` |
| Orchestrator (coordinator + tie-breaker) | `claude-sonnet-4.6` |

The orchestrator pins to `claude-sonnet-4.6` via `model:` frontmatter and never auto-triggers
(`disable-model-invocation: true`).

## Phase evolution

| Phase | Trigger | What changes |
|-------|---------|--------------|
| Phase 1 (current) | — | Single agent file, all process in body |
| Phase 2 | Agent body > 20,000 chars | Refactor to thin agent + `~/.copilot/skills/adversarial-review/SKILL.md` |
| Phase 3 | Team distribution needed | Wrap as a Copilot plugin |

## Full agent spec

→ [adversarial-review.agent.md](adversarial-review.agent.md)
