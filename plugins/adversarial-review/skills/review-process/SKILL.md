---
name: review-process
description: >
  Fingerprint algorithm, reconciliation rules, and report template
  for the adversarial-review plugin.
---

# Review Process

## Fingerprint Computation (`fp_v1`)

Compute the fingerprint for every finding before reconciliation. This is the deduplication and suppression mechanism.

### Algorithm

```
fp_v1 = sha256(normalized_category + "|" + normalized_repo_path + "|" + normalized_scope + "|" + normalized_title + "|" + normalized_evidence)
```

Truncate the hex digest to the first **16 characters**.

### Normalization rules

| Field | Rule |
|-------|------|
| `normalized_category` | Lowercase. Must be one of: security, correctness, reliability, performance, maintainability, accessibility, documentation, testing, configuration |
| `normalized_repo_path` | Repo-relative path, lowercase, forward-slash normalized. Example: `src/api/controllers/workoutcontroller.cs` |
| `normalized_scope` | Symbol/function/class name if known, lowercase. If no symbol applies, use `"<file>"`. Example: `getworkoutplan` |
| `normalized_title` | Lowercase, punctuation collapsed (replace sequences of non-alphanumeric chars with single space), trimmed. Example: `missing input validation on workout id` |
| `normalized_evidence` | Lowercase, all whitespace collapsed to single space, trimmed, numeric literals → `<NUM>`, string literals → `<STR>`. Apply all substitutions first, then truncate to the **last 200 characters** of the result (tail truncation — preserves the most specific evidence). *(F-c9-015)* |

> **Implementation note — prefer PowerShell (no extra dependencies):**
> ```powershell
> $sha = [System.Security.Cryptography.SHA256]::Create()
> $bytes = [System.Text.Encoding]::UTF8.GetBytes($input_string)
> $fp_v1 = ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-','').ToLower().Substring(0,16)
> ```
> Python (`hashlib.sha256`) or any other platform tool producing identical hex output is also acceptable. The algorithm is tool-agnostic; only the normalization rules and field ordering matter.

### Suppression check

> **NOTE:** All vote and finding tracking is in-memory only — do NOT create SQL tables.  
> State is rebuilt from JSONL files on each bootstrap. The pseudocode below uses  
> Python-style dict/list notation to describe in-memory operations only. *(F-c1-010)*

After computing `fp_v1` for a new finding, query `dismissed_findings`:
```python
fp_v1 in dismissed_fps  # check if fingerprint is in the in-memory dismissed_fps set  # F-c1-010, F-c2-003
```

- **Match found — same canonical_fields:** Mark finding as `suppressed`. Do not include in voting.
- **Match found — different canonical_fields:** Hash collision. Do NOT suppress. Flag the finding with `collision = true` and include it in normal voting.
- **No match:** Proceed to reconciliation.

**Canonical format for `canonical_fields`:** A pipe-delimited string matching the `fp_v1` input order: `category|repo_path|scope|title|evidence` (all values normalized per the `fp_v1` rules above). This deterministic format ensures equality comparison is reliable across sessions and serialization boundaries. Both the §7 dismissal ledger write and the suppression check here must use this exact format.

---

## Reconciliation Rules

**Reviewer output validation (before reconciliation):** *(F-c9-009)*
After all 4 reviewer agents complete, for each reviewer:
1. Count the number of JSON objects successfully parsed from the output (valid finding lines with required fields).
2. Extract the `REVIEW_COMPLETE: N` count from the end of the output.
3. If `parsed_count < declared_count`: log `"WARN: Reviewer {model} declared {declared_count} findings but only {parsed_count} were parseable ({declared_count - parsed_count} malformed/missing lines)."`
4. If `parsed_count == 0` AND `declared_count > 0`: log `"ERROR: Reviewer {model} returned 0 parseable findings vs declared {declared_count} — output may be entirely malformed."` and attempt one retry of that reviewer agent. If retry also yields 0 parseable findings, proceed with 0 for that reviewer and flag in the §10 report.

The reconciliation set is the **union of all non-suppressed findings** raised by any of the 4 reviewers.

**Only record findings that were actually raised in reviewer output with explicit evidence.** Do not infer, interpolate, or add findings that no reviewer raised. If a finding lacks an `evidence` field citing exact code, treat it as invalid and discard it before voting.

### Deduplication before voting

Group findings by fingerprint. Findings with the same fingerprint from different reviewers are treated as the **same finding**. Merge them: use the most detailed description, combine evidence, note all raising models.

### Semantic dedup (post-fingerprint)

After fingerprint-based dedup, perform a secondary semantic check:

1. Group remaining findings by `(file, category)`.
2. Within each group, compare titles pairwise. If two findings target the same file, same category, and have substantially overlapping titles or descriptions (e.g., both reference the same code construct or configuration value), flag them as **candidate duplicates**.
3. The orchestrator reviews candidate duplicates and decides whether to merge. Merging rules:
   - Use the most detailed description from either finding.
   - Combine evidence from both findings.
   - Use the higher severity if they differ.
   - Record all raising models from both findings.
   - Keep the fingerprint and ID of the finding raised by more models (or the first-encountered if tied).
   - Log the merge: `"Semantic merge: {id_kept} absorbed {id_dropped} (same file/category, overlapping title)"`
4. This step is performed by the orchestrator (not automated) — it requires judgment about whether two findings are truly the same issue or distinct issues in the same file/category.

### Debate-to-consensus

Findings are decided by **unanimous agreement only**: 4/4 confirm = **Confirmed**, 0/4 confirm = **Dismissed**. Any split triggers debate rounds where models see each other's reasoning and revise their position.

**Round 1 — Blind review (§4 output)**

A model's initial vote is:
- **explicit confirm** — model raised the finding (was in its output)
- **implicit dismiss** — model did not raise the finding during its independent review

For each finding, tally initial votes:
```
confirm_count = number of models that raised this finding
dismiss_count = 4 - confirm_count
```

- 4/4 confirm → **Confirmed** (skip debate)
- 0/4 confirm → **Dismissed** (skip debate)
- Any other result → **proceed to debate** (this includes 1/4, 2/4, and 3/4 — only unanimous agreement in either direction skips debate)

**Debate rounds — parallel algorithm**

After initial tally, partition findings:

```
resolved  = findings where confirm_count == 4 (Confirmed) or confirm_count == 0 (Dismissed)
contested = findings where 0 < confirm_count < 4
```

If `contested` is empty, skip to §7/§8 ledger writes.

**Constants (configurable in `config.json` — see §14):**

```
MAX_ROUNDS      = 10    # hard cap; force-resolves remaining findings
AGENT_TIMEOUT   = 600   # seconds to wait per agent before treating as failed  # F-c2-001
```

**Round loop:**

```
round = 1

while contested is not empty AND round <= MAX_ROUNDS:

    # --- Stuck detection (check before launching) ---
    if round >= 4:
        for finding in contested:
            current_vector  = vote_vector(finding, round - 1)
            previous_vector = vote_vector(finding, round - 2)
            two_rounds_ago  = vote_vector(finding, round - 3)
            if current_vector == previous_vector == two_rounds_ago:
                log: "Finding {id} stalled — identical vote vector for 3 consecutive rounds. Force-resolving."
                apply majority-vote rule (see Force-resolve below — 3/4+ → confirmed, 1/4 or 0/4 → dismissed, 2/4 → debate_unresolved)
                confirm_count = count(v for v in current_vector if v == 'confirm')
                # F-c2-005: only set debate_forced when outcome is confirmed/dismissed, not on 2-2 ties
                if confirm_count >= 3 or confirm_count <= 1:
                    findings[id]["status"] = "confirmed" if confirm_count >= 3 else "dismissed"  # F-c6-004
                    findings[id]["debate_forced"] = True  # F-c2-005
                else:
                    # 2-2 tie: set debate_unresolved only, do NOT set debate_forced
                    findings[id]["status"] = "pending"  # F-c1-010
                    findings[id]["debate_unresolved"] = True  # F-c1-010
                remove from contested
        if contested is empty: break

    # F-c1-011: launch one agent per role (4 total), each receives ALL contested findings
    # Every agent receives the frozen input snapshot:
    #   all contested finding details + all votes and reasoning from prior rounds
    # Use the debate round prompt template from the review-templates skill
    # agent_type: "code-review", mode: "background"
    # model: assigned model for each of the 4 roles
    # CRITICAL: set model: explicitly on each task call
    Launch exactly 4 task agents in parallel (one per model role)

    # Wait for ALL 4 agents for this round before tallying any finding
    Wait (blocking) for all 4 agents; timeout each at AGENT_TIMEOUT seconds

    # --- Failure handling (round-level — before per-finding tally) ---  *(F-c8-001)*
    # Agents serve ALL findings per round, so retries are round-scoped, not per-finding.
    # Retrying inside the per-finding loop would relaunch the same failed agent once per
    # contested finding (N relaunches for N findings) instead of once per round.
    failed_agents = [a for a in this_round_agents if not a.succeeded]
    if failed_agents:
        log: "WARN: {len(failed_agents)} agent(s) failed/timed-out in round {round}"
        for each failed_agent:
            retry_result = retry_agent(failed_agent, timeout=AGENT_TIMEOUT)
            if retry_result.ok:
                replace failed_agent with retry_result in this_round_agents
            else:
                log: "ERROR: Agent {model} failed retry in round {round}"

    for finding in contested:
        # round_votes: list of {model, vote, reasoning} dicts returned by this round's agents
        # Distinct from the global `votes` dict-of-lists ledger (keyed by finding_id)
        round_votes = collect_votes(finding, this_round_agents)  # F-c3-001

        if len(round_votes) == 4:
            confirm_count = count(v for v in round_votes if v["vote"] == 'confirm')
            for v in round_votes:  # F-c3-001: append each collected vote to the global ledger
                votes[finding_id].append({"model": v["model"], "round": round, "vote": v["vote"], "reasoning": v["reasoning"]})
            if confirm_count == 4:
                findings[id]["status"] = "confirmed"  # F-c1-010
                move from contested to resolved
            elif confirm_count == 0:
                findings[id]["status"] = "dismissed"  # F-c1-010
                move from contested to resolved
            # else: still split — remains in contested for round+1

        elif len(round_votes) >= 2:
            # 2-3 votes after retry — mark unresolved, do not tally partial results
            log: "ERROR: Only {len(round_votes)}/4 votes for finding {id} round {round}. Marking debate_unresolved."
            findings[id]["status"] = "pending"  # F-c2-004, F-c1-010
            findings[id]["debate_unresolved"] = True  # F-c1-010
            for v in round_votes:  # F-c3-001
                votes[finding_id].append({"model": v["model"], "round": round, "vote": v["vote"], "reasoning": v["reasoning"], "debate_unresolved": True})
            remove from contested
            # NOT written to §7/§8 ledgers; reported in §10

        else:
            # 0-1 votes — catastrophic failure
            log: "ERROR: <2 votes for finding {id} round {round}. Marking debate_unresolved."
            findings[id]["status"] = "pending"  # F-c2-004, F-c1-010, F-c9-005
            findings[id]["debate_unresolved"] = True  # F-c1-010
            for v in round_votes:  # F-c9-006: record any received votes to preserve audit trail
                votes[finding_id].append({"model": v["model"], "round": round, "vote": v["vote"], "reasoning": v["reasoning"], "debate_unresolved": True})
            remove from contested

    round += 1

# --- Force-resolve: MAX_ROUNDS cap ---
if contested is not empty:
    log: "WARN: MAX_ROUNDS={MAX_ROUNDS} reached. {len(contested)} finding(s) still contested."
    for finding in contested:
        latest_votes = finding.votes_by_round[round - 1]
        confirm_count = count(v for v in latest_votes if v == 'confirm')
        if confirm_count >= 3:
            resolved_status = 'confirmed'
        elif confirm_count <= 1:
            resolved_status = 'dismissed'
        else:
            # 2-2 tie — no tiebreaker; flag for manual review
            resolved_status = 'debate_unresolved'
        if resolved_status == 'debate_unresolved':
            findings[id]["status"] = "pending"  # F-c1-010
            findings[id]["debate_unresolved"] = True  # F-c1-010
            log: "Finding {id} force-unresolved — 2-2 tie, flagged for manual review"
        else:
            findings[id]["status"] = resolved_status
            findings[id]["debate_forced"] = True
            log: "Finding {id} force-resolved — majority {confirm_count}/4 → {resolved_status}"
        move from contested to resolved
```

**Wait rationale:** All 4 agents must complete before any finding is tallied. This guarantees round-`r` votes are written only after all round-`r` agents return — preserving a consistent input snapshot for round-`r+1`.

**Stuck detection rationale:** If a finding has the same vote vector for 3 consecutive rounds, no new reasoning is entering the debate. Force-resolve applies the same majority-vote rule as the MAX_ROUNDS cap.

**`debate_unresolved` findings:** Agent failures prevented a valid 4/4 tally. NOT written to §7/§8 ledgers. Appear in §10 with partial vote history and `debate_unresolved: true`. Kevin can manually review and reclassify.

**`debate_forced` findings:** Hit MAX_ROUNDS or stuck-detection threshold. Written to the appropriate ledger (confirmed or dismissed) per majority-vote, with `debate_forced: true` in the findings JSONL (`cycle-{N}-findings.jsonl`). Surfaced as a dedicated subsection in §10.

After the loop, every finding has a terminal status: confirmed, dismissed, debate_unresolved, or debate_forced. Proceed to §7/§8 ledger writes (skipping debate_unresolved findings).

### Recording votes

For every finding, insert one row per model:
```python
votes[finding_id].append({"model": model, "round": debate_round, "vote": vote, "reasoning": justification})  # F-c1-010
```

`debate_round` = 0 for the initial blind review tally, 1+ for debate rounds.

> **In-memory state note:** No SQL escaping is required for the in-memory structures above; preserve raw strings exactly and serialize safely when writing JSONL.

### Updating finding status

```python
findings[id]["status"] = "confirmed"  # F-c1-010
# Possible statuses: "confirmed", "dismissed", "suppressed", "pending"
# Additional flags (set independently): debate_forced = True, debate_unresolved = True
# debate_round tracks the round number where the finding was resolved (0 = initial tally)
```

---

## Report Template

Write to `.adversarial-review/reports/YYYY-MM-DD-cycle-{N}-report.md`. Use today's date for the filename.

```markdown
# Adversarial Code Review — Cycle {N}
**Date:** {YYYY-MM-DD} | **Mode:** {mode} | **Repo:** {root}

## Summary
| Files reviewed | New findings | Confirmed | Dismissed | Suppressed | Collisions |
|...|...|...|...|...|...|

## Confirmed Findings
[For each, sorted by severity desc:]
### {ID}: {Title}
**Severity:** {level} | **Category:** {cat} | **File:** `{file}` | **Symbol:** `{symbol}` | **Votes:** {N}/4
**Description:** ...
**Suggested fix:** ...

## Dismissed Findings
| ID | Title | File | Reason | Dismissed By |

## Force-Resolved Findings
[Findings that hit MAX_ROUNDS or stuck detection — resolved by majority vote with `debate_forced=true`]
| ID | Title | File | Final Vote | Rounds Debated | Resolution Method |

## Unresolved Findings
[Findings where agent failures prevented valid tally — `debate_unresolved=true`, not written to ledgers]
| ID | Title | File | Partial Votes | Failure Reason |

## Suppressed Findings (Prior Sessions)
| Fingerprint | Category | File | Originally Dismissed |

## Vote Detail
| Finding | Implementer | Implementer Alt | Challenger | Orchestrator | Decision |

## By File
| File | Confirmed | Severity breakdown |

## By Category
| Category | Confirmed | Severity breakdown |

## Cycle History
| Cycle | Date | Confirmed | Dismissed | Suppressed | Fixed |
```
