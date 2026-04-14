# Multi-Model Adversarial Code Review

A **GitHub Copilot CLI** plugin — a structured process for finding real bugs and security issues
by running 4 AI models independently against your codebase, reconciling their findings with a
transparent voting system, and persisting dismissed findings across sessions so they never come back.

Currently in active development and dogfooding.

## What it does

1. **4 independent reviewers** run in parallel — claude-opus (latest), gpt-codex (latest), gpt flagship (latest), and claude-sonnet (latest) each review the same scope without seeing each other's output
2. **Debate-to-consensus** — models share reasoning and debate until unanimous (all completing reviewers confirm = confirmed; none confirm = dismissed); hard cap of 10 rounds with force-resolve on majority vote (configurable)
3. **Cross-session dismissal suppression** — findings you've dismissed are fingerprinted (sha256) and never re-raised in future sessions
4. **Two review modes**: `review-only` (loop: find and report; stops when a cycle surfaces no new findings) and `review-and-fix` (loop: find, fix, re-review until all issues are resolved)
5. **Four scope modes**: `full` codebase, `local` changes, `since+local` from a ref, or specific `files` — auto-detects from git state
6. **Durable audit trail** — JSONL ledgers + per-cycle markdown reports in `.adversarial-review/`

## Install

Add the marketplace source:
```
/plugin marketplace add KevinBrown5280/fun-with-copilot
```

Install the plugin:
```
/plugin install adversarial-review@fun-with-copilot
```

Or from a local clone:

```bash
git clone https://github.com/KevinBrown5280/fun-with-copilot
```
Then inside the CLI:
```
/plugin install ./fun-with-copilot/plugins/adversarial-review
```

That's it — the agent is installed and available immediately as `adversarial-review`.

### Update

```
/plugin update adversarial-review@fun-with-copilot
```

### Uninstall

```
/plugin uninstall adversarial-review
```

To remove the marketplace source entirely:

```
/plugin marketplace remove fun-with-copilot
```

### Optional: configure per-repo

Create `.adversarial-review/config.json` in your repo if you need overrides (the agent auto-detects language/framework and scope without it):

```json
{
  "primary_language": "csharp",
  "framework": "aspnet-core",
  "exclude_patterns": ["*.env", "*.pfx", "migrations/", "node_modules/"],
  "default_mode": "review-only",
  "scope": "full",
  "scope_ref": "v2.1.0",
  "scope_files": [],
  "known_safe": [
    "Intentional use of dynamic SQL in stored procedure generator — reviewed 2025-01-15"
  ]
}
```

`scope` auto-detects by default: uncommitted changes → `local`; else → `full`.

## Usage

**adversarial-review must be invoked as a dedicated agent session** — it is a top-level orchestrator that launches 4 independent reviewer models in parallel. Asking a general Copilot session to "use the adversarial-review agent" will not work: the orchestration pipeline won't load and only one model will run.

Use `/agent` to browse installed agents and select `adversarial-review`. This starts a dedicated session with the full orchestration pipeline loaded.

Or launch directly from your terminal:

```
copilot --agent=adversarial-review:adversarial-review
```

Once in the dedicated session, type your mode and optional scope to begin:

```
review-only                               # report findings only; loops until a cycle surfaces nothing new
review-and-fix                            # find, fix, re-review until clean
```

Both modes accept any scope after a comma:

```
review-only, local changes                # staged + unstaged (auto-detected when uncommitted changes exist)
review-and-fix, full codebase             # review and fix the entire codebase
review-only, src/auth/TokenService.cs     # target specific files
```

Leave the prompt empty and the agent auto-detects scope and asks for mode.

**Scope modes:**

| Mode | What is reviewed | How to trigger |
|------|-----------------|----------------|
| `local` | Staged + unstaged changes | auto-detected when uncommitted changes exist |
| `full` | Entire codebase | "full codebase" or config `scope: "full"` |
| `files` | Specific files or globs | mention file paths in prompt or config `scope_files` |
| `since+local` | All changes from a ref to working tree | "since v2.1.0" / "since a3f9c12" or config `scope: "since+local"` + `scope_ref` (accepts tags, branches, or commit SHAs) |

## What you get

**Review-only**: A markdown report per cycle at `.adversarial-review/reports/YYYY-MM-DD-cycle-N-report.md`. Each cycle suppresses already-confirmed findings and only surfaces new issues. Loops until a clean cycle (no new findings).

**Review-and-fix**: The same, repeated across cycles. Codex implements fixes after each cycle,
all 4 models re-review from scratch, loop terminates when a clean cycle completes
(zero confirmed findings, all prior findings marked fixed).

## Output files

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

Every finding goes through two phases:

**Phase 1 — Blind review**
Each model reviews independently. A model that raised a finding = implicit confirm; a model that didn't = implicit dismiss.

| Initial tally | Decision |
|--------------|----------|
| All completing reviewers confirm | Confirmed immediately ✓ |
| No completing reviewers confirm | Dismissed immediately ✗ |
| Any split | Proceed to debate |

**Phase 2 — Debate rounds**
For any split, all 4 models see each other's votes and reasoning, then revise. Rounds repeat until every contested finding reaches 4/4 or 0/4, up to a maximum of 10 rounds (configurable via `max_rounds` in `config.json`). If a finding remains split at the round cap, it is force-resolved: 3/4 or 4/4 confirm = confirmed, 0/4 or 1/4 confirm = dismissed, 2-2 tie = unresolved (flagged for manual review as `debate_unresolved`). Force-resolved findings are marked `debate_forced: true` in the report.

## Dismissal fingerprinting

Each dismissed finding gets a deterministic fingerprint:
```
fp_v1 = sha256(category | repo_path | symbol | title | evidence)[:16]
```
This fingerprint is stored in `dismissed-findings.jsonl`. In future sessions, any finding matching
a stored fingerprint is suppressed before voting — it never surfaces again unless you manually
remove it from the ledger.

## Models used

| Role | Model family |
|------|-------------|
| Implementer (primary) | claude-opus (latest) |
| Implementer (alternate) | gpt-codex (latest) |
| Challenger | gpt flagship (latest, non-codex) |
| Orchestrator (coordinator) | claude-sonnet (latest) |

No tiebreaker for ties — a 2-2 split at the round cap is marked unresolved for manual review, not auto-resolved by a casting vote. Clear majorities (3/4 or 1/4) are force-resolved at the cap.

Always uses the latest available version within each model family. The orchestrator is pinned via
`model:` frontmatter and never auto-triggers (`disable-model-invocation: true`).

## Full agent spec

→ [adversarial-review.agent.md](agents/adversarial-review.agent.md)
