# Multi-Model Adversarial Code Review

A **GitHub Copilot CLI** plugin — a structured process for finding real, actionable engineering defects
by running 4 AI models independently against your codebase, reconciling their findings through
debate-to-consensus voting, and persisting dismissed findings across sessions so exact or locator-matched repeats do not keep resurfacing.

Currently in active development and dogfooding.

The **agent spec** is the normative source for behavior. `skills\review-process\SKILL.md` and `skills\review-templates\SKILL.md` are incorporated by reference for reusable algorithms, prompt templates, and schemas, but if any wording ever drifts, **`agents\adversarial-review.agent.md` wins**. This README and `plugin.json` are user-facing summaries only.

## What it does

1. **4 independent reviewers** run in parallel — `claude-opus-4.7`, `gpt-5.3-codex`, `gpt-5.4`, and a separately spawned `claude-sonnet-4.6` reviewer task each review the same scope without seeing each other's output
2. **Debate-to-consensus** — in the default exhaustive profile, models share reasoning and debate in **bounded batches** until unanimous (4/4 confirm = confirmed; 0/4 confirm = dismissed); hard cap of **10 rounds per phase** with a **15-round cumulative cap per finding** and force-resolve on majority vote
3. **Skeptic / devil's advocate round** — after debate resolves, exhaustive mode routes confirmed findings that are **high-severity, force-resolved, evidence-unverified, or previously debated** into deterministic skeptic batches (or all confirmed findings if you explicitly request a broader pass); fast keeps it OFF unless explicitly requested
4. **Live-data verification** — confirmed findings with external factual claims are reduced to a **canonical claim pool**, then verified against live documentation (Microsoft Learn, `web_fetch`, and other official docs tools); the report records claim-level verification results and the live sources used
5. **Cross-session suppression** — **exhaustive** dismissals are always suppressible in future sessions; suppression uses both an exact fingerprint and, when a stable locator anchor exists, a locator-backed occurrence key so simple rewording does not re-surface the same code occurrence. Confirmed findings become cross-session suppressible only after they are marked `fixed=true`; in `review-only`, findings confirmed earlier in the same run are suppressed in later cycles to avoid duplicate re-reporting; **fast** findings are report-only and do not modify durable ledgers
6. **Two review modes**: `review-only` (report findings) and `review-and-fix` (iteratively find, fix, and re-review toward a clean cycle, subject to the cycle cap and conflict stops)
7. **Two execution profiles**: `exhaustive` (default, authoritative) and `fast` (opt-in, advisory, `review-only` only)
8. **Four scope modes**: `full` codebase, `local` changes (including untracked files), `since+local` from a ref, or explicit `files`
9. **Audit trail** — JSONL ledgers + markdown reports in `.adversarial-review/`, including process telemetry, claim-level live-data results, and explicit notes when skeptic/live-data phases are `disabled-by-profile`, `disabled-by-prompt`, `zero_candidates`, `zero_confirmed_findings`, `zero_verifiable_claims`, `all_batches_failed`, or `partial-report-before-phase`

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

Create `.adversarial-review/config.json` in your repo if you need overrides for auto-detected language/framework hints, excludes, or known-safe annotations:

```json
{
  "primary_language": "C#",
  "framework": "ASP.NET Core",
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
- `"review-only, include skeptic round"` — forces a broader/full skeptic pass on

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
review-and-fix                            # exhaustive only: iterative fix loop; stops when clean, capped, or conflict-aborted
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

**Review-only, exhaustive**: A final markdown report for the run at `.adversarial-review/reports/YYYY-MM-DD-cycle-N-report.md`. `cycle-N` is the **terminal cycle number**, but the file is the **run-final aggregate report** for the whole invocation. Intermediate non-clean cycles emit inline progress summaries only. The run loops until a clean cycle (zero new confirmed findings and either zero `debate_unresolved` findings or only auto-escalated carry-forward unresolveds), or the cycle cap is hit.

**Review-only, fast**: A single bounded markdown report. Findings are advisory only and are **not** appended to the durable dismissal/confirmation ledgers.

**Review-and-fix**: The same exhaustive process, repeated across cycles. Codex implements fixes after cycles that still have open confirmed findings,
all 4 models re-review from scratch only when another fix pass is actually needed, and the loop stops when a clean cycle completes
(zero confirmed findings, zero `debate_unresolved` findings, and all prior findings marked fixed),
the 5-cycle cap is reached, or a fix-conflict abort produces a partial report.

## Output files

```
.adversarial-review/
├── dismissed-findings.jsonl   # append-only, cross-session dismissal ledger
├── confirmed-findings.jsonl   # append-only, confirmed findings with fix status
├── config.json                # optional repo-specific config (you create this)
├── session-state.json         # ephemeral in-run checkpoint
├── fetch-cache/               # cached external fetches reused across runs
├── scope-manifest-cycle-N.txt # canonical file manifest for the cycle
├── scope-receipts-cycle-N.json # deterministic review receipt batches for coverage accounting
└── reports/
    ├── 2025-07-14-cycle-1-report.md
    └── ...
```

Do **not** commit the full `.adversarial-review/` directory by default in shared or public repositories: reports and ledgers can contain unfixed findings, file paths, and code-derived evidence snippets. A safer default is to commit only `.adversarial-review/config.json` and keep the rest ignored, or store the full audit trail only in a private security-restricted repository when you intentionally want that history.

## How the voting works

Every finding goes through up to four phases:

**Phase 1 — Blind review**
Each model reviews independently. A model that raised a finding = **explicit confirm**; a model that reviewed the file and did not raise it = **explicit dismiss**; a model that did not cover the file = **abstain** (not counted as a dismiss).

| Initial tally | Decision |
|--------------|----------|
| 4/4 confirm | Confirmed immediately ✓ |
| 4/4 dismiss | Dismissed immediately ✗ |
| Any abstain or split | Proceed to debate |

**Phase 2 — Debate rounds**
For any split, all 4 models see each other's full vote trajectory and revise. **Round 1 special:** any model that didn't raise a finding in blind review must re-read the cited file and symbol before voting — grounding their vote in actual code rather than the finding description alone. The same fresh-read requirement applies when a skeptic challenge or live-data contradiction triggers a re-debate. In exhaustive mode, contested findings are processed in **bounded deterministic batches** until they reach 4/4 or 0/4, up to a maximum of 10 rounds per phase with a cumulative cap of 15 total rounds per finding across all phases. In fast mode, the debate caps and batch sizes are much smaller and the run stays single-cycle. **Prompt efficiency:** from round 3 onward, prior-round history is compressed to a 1-sentence trajectory summary + last 2 rounds verbatim (controls token growth). **Anonymous labels:** model identities in prior-round vote displays are replaced with `Reviewer A/B/C/D` to prevent authority-based herding; model identity only appears in the final vote detail table. Force-resolved findings are marked `debate_forced: true` in the report.

**Phase 3 — Skeptic round** *(default ON in exhaustive / OFF in fast)*
Exhaustive mode sends confirmed findings that are high severity, force-resolved, evidence-unverified, or that required prior debate into the skeptic pass by default. Each skeptic **must first re-read the cited file and symbol** — challenges must be grounded in the actual code, not just the finding description. Challenged findings re-enter bounded re-debate batches. This catches groupthink and false positives that survived the main debate.

**Phase 4 — Live-data verification** *(default ON in exhaustive / OFF in fast)*
Confirmed findings with external factual claims (library behavior, API surface, CVEs, conventions) are reduced to a **canonical claim pool** and then verified against live documentation sources. Claims are **domain-batched** (same-technology claims sent to one agent, up to 10 parallel) to eliminate redundant documentation fetches across related findings. All verification runs first, then contradicted findings re-debate in bounded batches. Unverifiable claims are retained as claim-level verification results with `verdict = unverifiable`; findings whose linked claims are all unverifiable are flagged as `training-data-only`, and the report shows **Live Data Claim Results** rows when claim verdicts exist, otherwise an explicit not-run reason.

## Suppression identity

Each **exhaustive-profile** dismissed or confirmed finding stores two deterministic identities:
```
fp_v1 = sha256(category | repo_path | symbol | title | evidence)[:24 hex chars]
occ_v1 = sha256(category | repo_path | symbol | locator_anchor)[:24 hex chars]
```
`fp_v1` is the collision-safe exact-match key. `occ_v1` is the locator-backed occurrence key used when the same code occurrence is described with slightly different title/evidence text in later runs. Evidence is normalized, literals are canonicalized, and long evidence is middle-preserved before hashing (first 100 chars + separator + last 100 chars). `locator_anchor` comes from reviewer-provided line locators or a unique orchestrator-inferred line span. Legacy ledger rows that predate `occ_v1` continue to participate via `fp_v1` only. **Fast-profile findings do not modify durable ledgers.**

Fingerprint lists injected into reviewer prompts are scope-filtered (only files in current review scope) and capped at 200 most recent entries for token efficiency. The authoritative suppression gate is always the orchestrator's reconciliation-time check.

## Accuracy guardrails

Beyond multi-model voting, the pipeline includes several accuracy protections:

- **Deterministic coverage receipts** — before entering debate, each reviewer must return receipt IDs for the exact file batches they completed; missing receipt batches trigger bounded catch-up review
- **Evidence plausibility** — evidence text is verified against the actual cited file, using optional line locators when available; deleted/renamed diff-only paths skip current-file matching instead of being auto-dismissed, while findings whose evidence still can't be located are flagged, auto-dismiss pre-debate if fewer than 3 reviewers raised them, and otherwise proceed through the normal profile-specific debate rules with an explicit evidence warning
- **Occurrence-aware suppression** — durable ledgers store both exact fingerprints and locator-backed occurrence keys so the same code occurrence can be suppressed or deduplicated even when reviewers phrase it differently
- **Stale dismissal unsuppression** — if a dismissed finding's file changes (or is deleted/renamed), that ledger entry is kept for audit but removed from active suppression for the current session so changed code is re-reviewable
- **Partial output recovery** — blind review, debate, skeptic, and live-data phases validate declared counts and send one recovery prompt whenever structured output is truncated or missing
- **Stale dismissal detection** — if a dismissed finding's file has been modified (or deleted/renamed) since dismissal, a warning is logged at bootstrap
- **Process telemetry** — the report summarizes retries, catch-up work, debate batches/rounds, and live-data activity so tuning decisions can be evidence-based

## Models used

| Role | Model family |
|------|-------------|
| Implementer (primary) | `claude-opus-4.7` |
| Implementer (alternate) | `gpt-5.3-codex` |
| Challenger | `gpt-5.4` |
| Orchestrator-Reviewer | `claude-sonnet-4.6` |
| Orchestrator (coordinator) | `claude-sonnet-4.6` |

The first four rows are the **4 independent reviewer/debater slots**. `Orchestrator-Reviewer` uses the same model ID as the coordinator, but it is a separately spawned reviewer task with no access to the orchestrator's private reasoning or in-memory state.

No tiebreaker for ties — a **main-debate** 2-2 split at the round cap is marked unresolved, carried forward automatically until auto-escalation or the cycle cap, and then surfaced for manual review; a **skeptic/live-data re-debate** 2-2 split remains confirmed with `debate_unresolved=true`. Clear majorities (3/4 or 1/4) are force-resolved at the cap.

These are pinned assignments for the current plugin revision. The orchestrator is pinned via
`model:` frontmatter and never auto-triggers (`disable-model-invocation: true`).

## Full agent spec

→ [adversarial-review.agent.md](agents/adversarial-review.agent.md)
