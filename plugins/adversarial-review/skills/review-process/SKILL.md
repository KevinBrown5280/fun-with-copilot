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
| `normalized_evidence` | Lowercase, all whitespace collapsed to single space, trimmed, numeric literals → `<NUM>`, string literals → `<STR>`. Max 200 characters |

### Suppression check

After computing `fp_v1` for a new finding, query `dismissed_findings`:
```sql
SELECT id, reason FROM dismissed_findings WHERE fingerprint = '{fp_v1}';
```

- **Match found — same canonical_fields:** Mark finding as `suppressed`. Do not include in voting.
- **Match found — different canonical_fields:** Hash collision. Do NOT suppress. Flag the finding with `collision = true` and include it in normal voting.
- **No match:** Proceed to reconciliation.

---

## Reconciliation Rules

The reconciliation set is the **union of all non-suppressed findings** raised by any of the 4 reviewers.

**Only record findings that were actually raised in reviewer output with explicit evidence.** Do not infer, interpolate, or add findings that no reviewer raised. If a finding lacks an `evidence` field citing exact code, treat it as invalid and discard it before voting.

### Deduplication before voting

Group findings by fingerprint. Findings with the same fingerprint from different reviewers are treated as the **same finding**. Merge them: use the most detailed description, combine evidence, note all raising models.

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

**Debate rounds — parallel batching algorithm**

After initial tally, partition findings:

```
resolved  = findings where confirm_count == 4 (Confirmed) or confirm_count == 0 (Dismissed)
contested = findings where 0 < confirm_count < 4
```

If `contested` is empty, skip to §7/§8 ledger writes.

**Constants (configurable in `config.json` — see §14):**

```
MAX_ROUNDS      = 10    # hard cap; force-resolves remaining findings
SUBBATCH_SIZE   = 8     # max findings per sub-batch → 8 × 4 = 32 debate agents per wave
AGENT_TIMEOUT   = 120   # seconds to wait per agent before treating as failed
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
                apply majority-vote rule (see Force-resolve below)
                mark finding debate_forced = true
                remove from contested
        if contested is empty: break

    # --- Sub-batch partitioning ---
    subbatches = chunk(contested, SUBBATCH_SIZE)

    for subbatch in subbatches:

        # Launch 4 × len(subbatch) debate agents in parallel
        # Every agent receives the frozen input snapshot:
        #   finding details + all votes and reasoning from prior rounds
        # Use the debate round prompt template from the review-templates skill
        # agent_type: "code-review", mode: "background"
        # model: assigned model for each of the 4 roles
        # CRITICAL: set model: explicitly on each task call
        Launch 4 × len(subbatch) task agents in parallel

        # Wait for ALL agents in this sub-batch before tallying any finding
        Wait (blocking) for all agents in sub-batch; timeout each at AGENT_TIMEOUT seconds

        for finding in subbatch:
            votes = collect_votes(finding, this_round_agents)

            # --- Failure handling ---
            if len(votes) < 4:
                failed_count = 4 - len(votes)
                log: "WARN: {failed_count} agent(s) failed/timed-out for finding {id} round {round}"

                # Retry each failed agent once
                for each failed_agent:
                    retry_result = retry_agent(failed_agent, timeout=AGENT_TIMEOUT)
                    if retry_result.ok:
                        votes.add(retry_result.vote)
                    else:
                        log: "ERROR: Agent {model} failed retry for finding {id} round {round}"

            if len(votes) == 4:
                confirm_count = count(v for v in votes if v == 'confirm')
                INSERT INTO votes (finding_id, model, vote, justification, cycle, debate_round) ...
                if confirm_count == 4:
                    UPDATE findings SET status = 'confirmed'
                    move from contested to resolved
                elif confirm_count == 0:
                    UPDATE findings SET status = 'dismissed'
                    move from contested to resolved
                # else: still split — remains in contested for round+1

            elif len(votes) >= 2:
                # 2-3 votes after retry — mark unresolved, do not tally partial results
                log: "ERROR: Only {len(votes)}/4 votes for finding {id} round {round}. Marking debate_unresolved."
                UPDATE findings SET status = 'dismissed', debate_unresolved = 1
                record partial votes in SQL with debate_unresolved note
                remove from contested
                # NOT written to §7/§8 ledgers; reported in §10

            else:
                # 0-1 votes — catastrophic failure
                log: "ERROR: <2 votes for finding {id} round {round}. Marking debate_unresolved."
                UPDATE findings SET debate_unresolved = 1
                remove from contested

    round += 1

# --- Force-resolve: MAX_ROUNDS cap ---
if contested is not empty:
    log: "WARN: MAX_ROUNDS={MAX_ROUNDS} reached. {len(contested)} finding(s) still contested."
    for finding in contested:
        latest_votes = finding.votes_by_round[round - 1]
        confirm_count = count(v for v in latest_votes if v == 'confirm')
        resolved_status = 'confirmed' if confirm_count >= 2 else 'dismissed'
        UPDATE findings SET status = resolved_status, debate_forced = 1
        log: "Finding {id} force-resolved — majority {confirm_count}/4 → {resolved_status}"
        move from contested to resolved
```

**Wait rationale:** All agents within a sub-batch must complete before any finding in that sub-batch is tallied. This guarantees round-`r` votes are written only after all round-`r` agents return — preserving a consistent input snapshot for round-`r+1`.

**Stuck detection rationale:** If a finding has the same vote vector for 3 consecutive rounds, no new reasoning is entering the debate. Force-resolve applies the same majority-vote rule as the MAX_ROUNDS cap.

**`debate_unresolved` findings:** Agent failures prevented a valid 4/4 tally. NOT written to §7/§8 ledgers. Appear in §10 with partial vote history and `debate_unresolved: true`. Kevin can manually review and reclassify.

**`debate_forced` findings:** Hit MAX_ROUNDS or stuck-detection threshold. Written to the appropriate ledger (confirmed or dismissed) per majority-vote, with `debate_forced: true` in SQL. Surfaced as a dedicated subsection in §10.

After the loop, every finding has a terminal status: confirmed, dismissed, debate_unresolved, or debate_forced. Proceed to §7/§8 ledger writes (skipping debate_unresolved findings).

### Recording votes

For every finding, insert one row per model:
```sql
INSERT INTO votes (finding_id, model, vote, justification, cycle, debate_round)
VALUES ('{id}', '{model}', '{confirm|dismiss}', '{one-sentence justification}', {cycle}, {debate_round});
```

`debate_round` = 0 for the initial blind review tally, 1+ for debate rounds.

### Updating finding status

```sql
UPDATE findings SET status = 'confirmed' WHERE id = '{id}';
-- Possible statuses: 'confirmed', 'dismissed', 'suppressed', 'pending'
-- Additional flags (set independently): debate_forced = 1, debate_unresolved = 1
-- debate_round tracks the round number where the finding was resolved (0 = initial tally)
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
