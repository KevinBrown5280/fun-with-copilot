# Multi-Model Adversarial Code Review

A **GitHub Copilot CLI** plugin — a structured process for finding real bugs and security issues
by running 4 AI models independently against your codebase, reconciling their findings through
debate-to-consensus voting, and persisting dismissed findings across sessions so they never come back.

Currently in active development and dogfooding.

## What it does

1. **4 independent reviewers** run in parallel — claude-opus (latest), gpt-codex (latest), gpt flagship (latest), and claude-sonnet (latest) each review the same scope without seeing each other's output
2. **Debate-to-consensus** — models share reasoning and debate until unanimous (4/4 confirm = confirmed; 0/4 confirm = dismissed); hard cap of 10 rounds with force-resolve on majority vote (configurable)
3. **Skeptic / devil's advocate round** — after debate resolves, 4 models argue *against* each confirmed finding; any challenge triggers re-debate until 4/4 unanimous (default ON, configurable)
4. **Live-data verification** — confirmed findings with external factual claims are verified against live documentation (Microsoft Learn, web sources) to catch stale training-data assumptions (default ON, configurable)
5. **Cross-session suppression** — dismissed and confirmed findings are fingerprinted (sha256) and suppressed in future sessions
6. **Two review modes**: `review-only` (loop: find and report; stops when a cycle surfaces no new findings) and `review-and-fix` (loop: find, fix, re-review until all issues are resolved)
7. **Four scope modes**: `full` codebase, `local` changes (including untracked files), `since+local` from a ref, or specific `files` — auto-detects from git state
8. **Durable audit trail** — JSONL ledgers + per-cycle markdown reports in `.adversarial-review/`

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
  "enable_skeptic_round": true,
  "enable_livedata_verify": true,
  "known_safe": [
    "Intentional use of dynamic SQL in stored procedure generator — reviewed 2025-01-15"
  ]
}
```

`scope` auto-detects by default: uncommitted changes → `local`; else → `full`.

Both post-debate rounds can also be toggled via prompt (overrides config):
- `"review-only, skip skeptic round"` — disables skeptic round for this session
- `"review-only, skip live-data verification"` — disables live-data verification
- `"review-only, include skeptic round"` — forces skeptic round on even if config says false

## Usage

**adversarial-review must be invoked as a dedicated agent session** — it is a top-level orchestrator that launches 4 independent reviewer models in parallel. Asking a general Copilot session to "use the adversarial-review agent" will not work: the orchestration pipeline won't load and only one model will run.

Use `/agent` to browse installed agents and select `adversarial-review`. This starts a dedicated session with the full orchestration pipeline loaded.

Or launch directly from your terminal:

```
copilot --agent=adversarial-review:adversarial-review
```

Once in the dedicated session, specify your mode and optional scope (or leave empty to default to **review-only** with auto-detected scope):

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

Leave the prompt empty and the agent defaults to **review-only** mode with auto-detected scope. Mode resolution: explicit prompt → `default_mode` from config.json → review-only fallback.

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

Every finding goes through up to four phases:

**Phase 1 — Blind review**
Each model reviews independently. A model that raised a finding = implicit confirm; a model that didn't = implicit dismiss.

| Initial tally | Decision |
|--------------|----------|
| 4/4 confirm | Confirmed immediately ✓ |
| 0/4 confirm | Dismissed immediately ✗ |
| Any split | Proceed to debate |

**Phase 2 — Debate rounds**
For any split, all 4 models see each other's full vote trajectory across all prior rounds and revise. Rounds repeat until every contested finding reaches 4/4 or 0/4, up to a maximum of 10 rounds per phase (configurable via `max_rounds` in `config.json`). A cumulative cap of **15 total debate rounds per finding** across all phases (debate + skeptic re-debate + live-data re-debate) prevents pathological cases. If a finding remains split at any cap, it is force-resolved: 3/4 or 4/4 confirm = confirmed, 0/4 or 1/4 confirm = dismissed, 2-2 tie = unresolved (flagged for manual review as `debate_unresolved`). Force-resolved findings are marked `debate_forced: true` in the report.

**Phase 3 — Skeptic round** *(default ON)*
All 4 models switch to devil's advocate mode and argue *against* each confirmed finding. All challenged findings are batched into a single re-debate loop (not per-finding) for efficiency. Any finding that receives a challenge is re-debated until 4/4 unanimous. This catches groupthink and false positives that survived debate.

**Phase 4 — Live-data verification** *(default ON)*
Confirmed findings with external factual claims (library behavior, API surface, CVEs, conventions) are verified against live documentation sources. All verification runs first, then all contradicted findings re-debate together in a single batch. Unverifiable findings are flagged as `training-data-only` in the report.

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
