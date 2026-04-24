# Multi-Model Adversarial Code Review

A **GitHub Copilot CLI** plugin — a structured process for finding real bugs and security issues
by running 4 AI models independently against your codebase, reconciling their findings through
debate-to-consensus voting, and persisting dismissed findings across sessions so they never come back.

Currently in active development and dogfooding.

## What it does

1. **4 independent reviewers** run in parallel — `claude-opus-4.7`, `gpt-5.3-codex`, `gpt-5.4`, and `claude-sonnet-4.6` each review the same scope without seeing each other's output
2. **Debate-to-consensus** — in the default exhaustive profile, models share reasoning and debate until unanimous (4/4 confirm = confirmed; 0/4 confirm = dismissed); hard cap of **10 rounds per phase** with a **15-round cumulative cap per finding** and force-resolve on majority vote
3. **Skeptic / devil's advocate round** — after debate resolves, 4 models argue *against* each confirmed finding; default ON in exhaustive, OFF in fast unless explicitly requested
4. **Live-data verification** — confirmed findings with external factual claims are verified against live documentation (Microsoft Learn, `web_fetch`, and other official docs tools); default ON in exhaustive, OFF in fast unless explicitly requested
5. **Cross-session suppression** — **exhaustive** dismissals are always suppressible in future sessions; confirmed findings are suppressible in `review-only` and, in `review-and-fix`, only after they are marked `fixed=true`; **fast** findings are report-only and do not modify durable ledgers
6. **Two review modes**: `review-only` (report findings) and `review-and-fix` (find, fix, re-review until all issues are resolved)
7. **Two execution profiles**: `exhaustive` (default, authoritative) and `fast` (opt-in, advisory, `review-only` only)
8. **Four scope modes**: `full` codebase, `local` changes (including untracked files), `since+local` from a ref, or explicit `files`
9. **Audit trail** — JSONL ledgers + markdown reports in `.adversarial-review/`

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
  "known_safe_ttl_days": 365,
  "known_safe": [
    "Intentional use of dynamic SQL in stored procedure generator — reviewed 2025-01-15",
    {
      "annotation": "Auth bypass in AdminController is intentional — internal network only, reviewed 2025-03-01",
      "file": "src/controllers/AdminController.cs",
      "symbol": "BypassAuth",
      "expires": "2026-03-01"
    }
  ]
}
```

`known_safe` accepts both plain strings (legacy) and objects with optional `file`, `symbol`, and `expires` fields. Object-form entries are only injected for files in the current review scope; expired entries are skipped with a warning. Plain-string entries are injected unconditionally but subject to TTL age warnings.

`config.json` is **data-only**. Behavioral controls are prompt-only: mode, execution profile, scope, stale-check strategy, and skeptic/live-data toggles are never read from config.

Useful prompt examples:
- `"review-only, fast review"` — bounded advisory pass (no durable ledger writes)
- `"review-only, skip skeptic round"` — disables skeptic for this session
- `"review-only, include live-data verification"` — forces live-data verification on
- `"review-only git-blame stale check"` — uses the more expensive stale-dismissal check for this session

Fast mode is supported only in `review-only`. If you ask for `review-and-fix, fast`, the agent falls back to exhaustive.

Both post-debate rounds can also be toggled via prompt:
- `"review-only, skip skeptic round"` — disables skeptic round for this session
- `"review-only, skip live-data verification"` — disables live-data verification
- `"review-only, include skeptic round"` — forces skeptic round on

## Usage

**adversarial-review must be invoked as a dedicated agent session** — it is a top-level orchestrator that launches 4 independent reviewer models in parallel. Asking a general Copilot session to "use the adversarial-review agent" will not work: the orchestration pipeline won't load and only one model will run.

Use `/agent` to browse installed agents and select `adversarial-review`. This starts a dedicated session with the full orchestration pipeline loaded.

Or launch directly from your terminal:

```
copilot --agent=adversarial-review:adversarial-review
```

Once in the dedicated session, specify your mode and optional profile/scope (or leave empty to default to **review-only, exhaustive** with auto-detected scope):

```
review-only                               # authoritative exhaustive review-only pass
review-only, fast review                  # bounded advisory review-only pass
review-and-fix                            # exhaustive only: find, fix, re-review until clean
```

Both modes accept scope after a comma, and `review-only` also accepts the optional `fast review` profile modifier:

```
review-only, local changes                # staged + unstaged (auto-detected when uncommitted changes exist)
review-only, fast review, local changes   # bounded advisory pass over current changes
review-and-fix, full codebase             # review and fix the entire codebase
review-only, src/auth/TokenService.cs     # target specific files
review-only, since v2.1.0                 # compare from a ref to the working tree
```

Leave the prompt empty and the agent defaults to **review-only, exhaustive** with auto-detected scope. Mode resolution: explicit prompt → review-only fallback. Execution profile defaults to exhaustive unless the prompt explicitly requests `fast review`.

**Scope modes:**

| Mode | What is reviewed | How to trigger |
|------|-----------------|----------------|
| `local` | Staged + unstaged changes | auto-detected when uncommitted changes exist |
| `full` | Entire codebase | `"full codebase"` / `"full review"` |
| `files` | Specific files or globs | mention repo-relative file paths or glob patterns in the prompt |
| `since+local` | All changes from a ref to working tree | `"since v2.1.0"` / `"since a3f9c12"` / `"from origin/main"` |

## What you get

**Review-only, exhaustive**: A final markdown report for the run at `.adversarial-review/reports/YYYY-MM-DD-cycle-N-report.md`. Intermediate non-clean cycles emit inline progress summaries only. The run loops until a clean cycle (no new confirmed findings and no unresolved main-phase findings) or the cycle cap is hit.

**Review-only, fast**: A single bounded markdown report. Findings are advisory only and are **not** appended to the durable dismissal/confirmation ledgers.

**Review-and-fix**: The same exhaustive process, repeated across cycles. Codex implements fixes after each cycle,
all 4 models re-review from scratch, loop terminates when a clean cycle completes
(zero confirmed findings, zero `debate_unresolved` findings, and all prior findings marked fixed).

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
For any split, all 4 models see each other's full vote trajectory and revise. **Round 1 special:** any model that didn't raise a finding in blind review must re-read the cited file and symbol before voting — grounding their vote in actual code rather than the finding description alone. The same fresh-read requirement applies when a skeptic challenge or live-data contradiction triggers a re-debate. In exhaustive mode, rounds repeat until every contested finding reaches 4/4 or 0/4, up to a maximum of 10 rounds per phase with a cumulative cap of 15 total rounds per finding across all phases. In fast mode, the debate caps are much smaller and the run stays single-cycle. **Prompt efficiency:** from round 3 onward, prior-round history is compressed to a 1-sentence trajectory summary + last 2 rounds verbatim (controls token growth). **Anonymous labels:** model identities in prior-round vote displays are replaced with `Reviewer A/B/C/D` to prevent authority-based herding; model identity only appears in the final vote detail table. Force-resolved findings are marked `debate_forced: true` in the report.

**Phase 3 — Skeptic round** *(default ON in exhaustive / OFF in fast)*
All 4 models switch to devil's advocate mode and argue *against* each confirmed finding. Each skeptic **must first re-read the cited file and symbol** — challenges must be grounded in the actual code, not just the finding description. All challenged findings are batched into a single re-debate loop for efficiency. Any finding that receives a challenge is re-debated until 4/4 unanimous. This catches groupthink and false positives that survived debate.

**Phase 4 — Live-data verification** *(default ON in exhaustive / OFF in fast)*
Confirmed findings with external factual claims (library behavior, API surface, CVEs, conventions) are verified against live documentation sources. Findings are **domain-batched** (same-technology findings sent to one agent, up to 10 parallel) to eliminate redundant documentation fetches. All verification runs first, then all contradicted findings re-debate together in a single batch. Unverifiable findings are flagged as `training-data-only` in the report.

## Dismissal fingerprinting

Each **exhaustive-profile** dismissed finding gets a deterministic fingerprint:
```
fp_v1 = sha256(category | repo_path | symbol | title | evidence)[:24 hex chars]
```
Evidence is normalized, literals are canonicalized, and long evidence is middle-preserved before hashing (first 100 chars + separator + last 100 chars). This fingerprint is stored in `dismissed-findings.jsonl`. In future sessions, any finding matching a stored fingerprint is suppressed before voting — it never surfaces again unless you manually remove it from the ledger. **Fast-profile findings do not modify durable ledgers.**

Fingerprint lists injected into reviewer prompts are scope-filtered (only files in current review scope) and capped at 200 most recent entries for token efficiency. The authoritative suppression gate is always the orchestrator's reconciliation-time check.

## Accuracy guardrails

Beyond multi-model voting, the pipeline includes several accuracy protections:

- **File coverage check** — before entering debate, each reviewer that missed scoped files gets a bounded catch-up batch, preventing implicit-dismiss bias without per-file fan-out
- **Evidence plausibility** — evidence text is verified against the actual cited file; findings whose evidence can't be located are flagged and require 3/4+ explicit confirms to proceed
- **Partial output recovery** — if a reviewer's output was truncated (gap ≥ 2 findings), a recovery prompt retrieves the missing findings
- **Stale dismissal detection** — if a dismissed finding's file has been modified (or deleted/renamed) since dismissal, a warning is logged at bootstrap

## Models used

| Role | Model family |
|------|-------------|
| Implementer (primary) | `claude-opus-4.7` |
| Implementer (alternate) | `gpt-5.3-codex` |
| Challenger | `gpt-5.4` |
| Orchestrator (coordinator) | `claude-sonnet-4.6` |

No tiebreaker for ties — a 2-2 split at the round cap is marked unresolved for manual review, not auto-resolved by a casting vote. Clear majorities (3/4 or 1/4) are force-resolved at the cap.

These are pinned assignments for the current plugin revision. The orchestrator is pinned via
`model:` frontmatter and never auto-triggers (`disable-model-invocation: true`).

## Full agent spec

→ [adversarial-review.agent.md](agents/adversarial-review.agent.md)
