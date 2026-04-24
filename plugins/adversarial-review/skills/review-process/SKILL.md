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
fp_v1 = sha256(normalized_category + "|" + normalized_repo_path + "|" + normalized_symbol + "|" + normalized_title + "|" + normalized_evidence)
```

Truncate the hex digest to the first **24 characters** (96 bits of entropy — birthday-safe to ~1 billion entries).

### Normalization rules

| Field | Rule |
|-------|------|
| `normalized_category` | Lowercase. Must be one of: security, correctness, reliability, performance, maintainability, accessibility, documentation, testing, configuration |
| `normalized_repo_path` | Repo-relative path, lowercase, forward-slash normalized. Example: `src/api/controllers/workoutcontroller.cs` |
| `normalized_symbol` | Symbol/function/class name if known, lowercase. If null, empty string, or no symbol applies, use `"<file>"`. Example: `getworkoutplan`. **Note:** this is the function/class/method name — it is NOT the review scope mode (`full`, `local`, etc.). |
| `normalized_title` | Lowercase, punctuation collapsed (replace sequences of non-alphanumeric chars with single space), trimmed. Example: `missing input validation on workout id` |
| `normalized_evidence` | Lowercase, all whitespace collapsed to single space, trimmed. Then apply literal substitutions in this order: **(1) String literals** — replace content between matching `"..."` or `'...'` delimiters (exclusive of delimiters) with `<STR>`. Use a **non-greedy (shortest-match)** algorithm; if the evidence contains an escaped delimiter (e.g., `\"` inside a `"`-delimited string), treat the escaped character as literal and do not close the string at that point. Only single-line string content applies; do not match across newlines. Template literals and raw strings are not substituted (too ambiguous — leave as-is). **(2) Numeric literals** — replace tokens matching `0[xX][0-9a-fA-F]+` (hex) or `[0-9]+([._][0-9]+)*([eE][+-]?[0-9]+)?` (decimal/float/version) that are bounded by non-alphanumeric characters or string boundaries, with `<NUM>`. Underscore-separated numbers (e.g., `1_000_000`) are included. Do NOT substitute numbers that are part of identifiers (e.g., `catch2`, `net8`, `v2`, `IAsyncEnumerable<T>` — these are part of a word token and not bounded on both sides by non-alphanumeric chars). After all substitutions, apply **middle-preserving truncation**: take the first 100 characters + `···` + the last 100 characters. If the normalized result is ≤ 200 characters, use it in full (no truncation). This preserves context-identifying head and specificity-bearing tail while avoiding collision risk from common boilerplate tails. *(A-3)* |

> **Implementation note — prefer PowerShell (no extra dependencies):**
> ```powershell
> $sha = [System.Security.Cryptography.SHA256]::Create()
> $bytes = [System.Text.Encoding]::UTF8.GetBytes($input_string)
> $fp_v1 = ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-','').ToLower().Substring(0,24)
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
  - To retrieve the stored entry for canonical_fields comparison, iterate the **list** `dismissed_fp_index[fp_v1]` (O(1) reverse lookup by fingerprint to the collision bucket — populated at bootstrap alongside `dismissed_fps`).
- **Match found — different canonical_fields:** Hash collision. Do NOT suppress. Flag the finding with `collision = true` and include it in normal voting.
- **No match:** Proceed to reconciliation.

**Confirmed-finding suppression check (mode-dependent):**

After the dismissed check above, also check against the mode-appropriate confirmed fingerprint set:

- In **review-only** mode: check `fp_v1 in confirmed_all_fps`
- In **review-and-fix** mode: check `fp_v1 in confirmed_fps`

```python
# Review-only mode:
fp_v1 in confirmed_all_fps  # suppress all previously confirmed findings  # F-c7-005
# Review-and-fix mode:
fp_v1 in confirmed_fps  # suppress only fixed confirmed findings
```

Apply the same match/collision logic as the dismissed check:
- **Match found — same canonical_fields:** Mark finding as `suppressed`. Do not include in voting.
  - To retrieve the stored entry for canonical_fields comparison, iterate the **list** `confirmed_fp_index[fp_v1]` (O(1) reverse lookup by fingerprint to the collision bucket — populated at bootstrap alongside `confirmed_fps`/`confirmed_all_fps`; see §2 Step 2).
- **Match found — different canonical_fields:** Hash collision. Do NOT suppress. Flag `collision = true`.
- **No match:** Proceed to reconciliation.

This is the authoritative reconciliation-time suppression gate. The prompt-level hint (injecting fingerprints into reviewer prompts) is best-effort only — reviewers may ignore it. This check is the defense-in-depth backstop that prevents previously confirmed findings from re-entering voting.

**Canonical format for `canonical_fields`:** A pipe-delimited string matching the `fp_v1` input order: `category|repo_path|symbol|title|evidence` (all values normalized per the `fp_v1` rules above; `symbol` = normalized_symbol value: symbol/function/class name or `"<file>"`). This deterministic format ensures equality comparison is reliable across sessions and serialization boundaries. Both the §7 dismissal ledger write and the suppression check here must use this exact format.

---

## Reconciliation Rules

**Reviewer output validation (before reconciliation):** *(F-c9-009)*
After all 4 reviewer agents complete, for each reviewer:
1. Count the number of JSON objects successfully parsed from the output (valid finding lines with required fields).
2. Extract the `REVIEW_COMPLETE: N` count from the end of the output.
3. If `parsed_count < declared_count`: log `"WARN: Reviewer {model} declared {declared_count} findings but only {parsed_count} were parseable ({declared_count - parsed_count} malformed/missing lines)."`
   - **Partial recovery (A-9):** If `parsed_count > 0` AND gap (`declared_count - parsed_count`) ≥ 2: send a recovery prompt to that reviewer agent: *"Your previous output was truncated. You declared {declared_count} findings but only {parsed_count} were parseable. The last successfully parsed finding had id `{last_parsed_id}`. Re-output all findings after that one, in the same JSONL format."* Merge any successfully parsed recovery findings with the original batch. If recovery fails or yields 0 additional parseable findings, proceed with what was originally parsed and log the gap in the §10 report. **Note — gap=1 is not recovered by design:** a gap of exactly 1 is treated as normal trailing truncation (the final finding line was cut mid-write, which is common at context limits); recovery is skipped to avoid a round-trip for a single marginal line. A WARN log is still emitted. If this threshold is too lossy for your use case, lower to ≥1 via config (not yet configurable — raise an issue).
4. If `parsed_count == 0` AND `declared_count > 0`: log `"ERROR: Reviewer {model} returned 0 parseable findings vs declared {declared_count} — output may be entirely malformed."` and attempt one retry of that reviewer agent. If retry also yields 0 parseable findings, proceed with 0 for that reviewer and flag in the §10 report (per §13 rule 6a — do not stall waiting for user input).

The reconciliation set is the **union of all non-suppressed findings** raised by any of the 4 reviewers.

**File coverage check before debate (A-8):**
After computing the reconciliation set, cross-reference FILES_REVIEWED against the canonical scope file list:
1. For each scoped file, count how many of the 4 reviewers listed it in their FILES_REVIEWED output.
2. Build `missed_files_by_reviewer` from the canonical scope file list minus each reviewer's FILES_REVIEWED list. For each reviewer with missed files: log `"WARN: Reviewer {model} missed {count} scoped file(s) — triggering bounded catch-up review."` Launch one catch-up review per reviewer, chunked into batches of at most 25 files, using that reviewer's assigned model and the normal blind-review JSONL schema. Merge any new findings from the catch-up batches into the reconciliation set before evidence verification and deduplication.
3. For each merged finding, compute `covering_roles` = the set of reviewer roles whose final FILES_REVIEWED list contains that finding's `file`.
4. For findings in files with < 3-reviewer coverage: treat reviewers that did NOT list the file in FILES_REVIEWED as **abstaining**, not dismissing, for blind-tally purposes (they cannot confirm absence of findings they did not read). Adjust round-0 reasoning accordingly.

**Evidence verification (S-1) — runs after A-8, before fingerprint dedup:**
After the coverage check (so micro-review findings are included), for each finding where `evidence` is non-null AND `file` is non-null:
1. Extract the first 80 characters of the finding's `evidence` field (collapse whitespace only — **do not lowercase**).
2. Search the cited `file` (repo-relative path) using a case-insensitive, whitespace-tolerant grep for that 80-char snippet.
3. If no match is found: set `evidence_unverified: true` on the finding and log: `"WARN: Evidence for finding from {model} ('{title[:50]}') could not be located in {file} — may be hallucinated or misquoted."`
4. Findings with `evidence_unverified: true` carry the flag into fingerprint dedup. The auto-dismiss decision (raise_count < 3) is applied **after fingerprint dedup** (step below) using the consolidated `raise_count` (number of distinct models that raised findings with matching fingerprint) — not the per-reviewer count here. This prevents losing consensus signal when multiple reviewers cite the same bug with slightly different evidence excerpts.
5. All findings with `evidence_unverified: true` are listed in the §10 "Evidence-Unverified Findings" section regardless of outcome.

**Only record findings that were actually raised in reviewer output with explicit evidence.** Do not infer, interpolate, or add findings that no reviewer raised. If a finding lacks an `evidence` field citing exact code, treat it as invalid and discard it before voting.

### Deduplication before voting

Group findings by fingerprint. Findings with the same fingerprint from different reviewers are treated as the **same finding**. Merge them: use the most detailed description, combine evidence, note all raising models.

**Post-fingerprint-dedup: apply `evidence_unverified` raise_count auto-dismiss:**
After fingerprint dedup, for each merged finding that has `evidence_unverified: true`, check the consolidated `raise_count` (number of distinct models that contributed to this fingerprint group):

**`evidence_unverified` flag merge rule:** When multiple reviewers contribute to the same fingerprint group, the merged finding has `evidence_unverified: true` if **ANY** contributing reviewer finding had the flag set (OR logic). After merging, re-run the 80-char snippet search against the combined evidence to give the merged finding a chance to clear the flag before the raise_count check.

- If `raise_count < 3`: **auto-dismiss** (explicit pre-debate bypass — fewer than 3 reviewers raised this fingerprint AND evidence is unverifiable). Mark the merged finding `status = "dismissed"` and `dismissal_source = "evidence_unverified"` immediately, but **do not write §7 yet**. Carry the finding through semantic dedup and stable-ID assignment so it receives a normal orchestrator `F-c...` ID before any durable write. **Debate-path rule:** once this auto-dismiss is applied, the finding is removed from blind-tally / `contested` partitioning and must not enter §5/§6 debate, §6.5 skeptic re-debate, or §6.7 live-data re-debate. It proceeds directly to the dismissed/report flow after stable-ID assignment. Log: `"Auto-dismissed pending stable ID assignment: evidence_unverified and raise_count={raise_count} < 3."` In **exhaustive** profile, write the §7 dismissal entry later in the normal ledger-write pass using the stable `F-c...` ID. In **fast** profile, do **not** write a durable ledger entry — keep the dismissal report-only for this session.
- If `raise_count ≥ 3`: proceed to normal debate but include a note in the debate prompt: `"NOTE: Evidence for this finding could not be verified in the cited file. Reviewers should inspect the code directly before voting."`

### Semantic dedup (post-fingerprint)

After fingerprint-based dedup, perform a secondary semantic check:

1. Group remaining findings by `(file, category)`.
2. Within each group, compare titles pairwise. If two findings target the same file, same category, and have substantially overlapping titles or descriptions (e.g., both reference the same code construct or configuration value), flag them as **candidate duplicates**.
3. Compute Jaccard similarity on character 2-grams of the normalized titles. **Auto-merge** if Jaccard ≥ 0.65; **escalate to orchestrator** if 0.35–0.64; **keep separate** if < 0.35. Severity protection rule: **never auto-merge a `critical` or `high` severity finding into a lower severity** — escalate to orchestrator regardless of Jaccard score.
   Merge rules (auto or orchestrator-approved):
   - Use the most detailed description from either finding.
   - Combine evidence from both findings.
   - Use the higher severity if they differ.
   - Record all raising models from both findings.
   - Keep the fingerprint and ID of the finding raised by more models (or the first-encountered if tied).
   - Log: `"Semantic merge (Jaccard={score:.2f}): {id_kept} absorbed {id_dropped} (same file/category, overlapping title)"`
4. Record all merged pairs (auto and orchestrator-approved) in a `merged_findings` list for the §10 report "Semantically Merged Findings" section.

### Debate-to-consensus

**Execution-profile inputs (set by the agent, never by `config.json`):**

| Profile | Intended use | `MAX_ROUNDS` | `CUMULATIVE_CAP` | `AGENT_TIMEOUT` | Durable ledgers |
|---------|---------------|--------------|------------------|-----------------|-----------------|
| `exhaustive` | Default authoritative review path | 10 | 15 | 600 | yes |
| `fast` | Advisory `review-only` path | 2 | 2 | 300 | no |

Decision policy depends on the active execution profile:
- **`exhaustive`**: keep the unanimity baseline — 4/4 confirm = **Confirmed**, 0/4 confirm = **Dismissed**, any split triggers debate.
- **`fast`**: 4/4 confirm = **Confirmed**; 3/4 confirm = **Confirmed** only when `evidence_unverified != true` **and** file coverage is at least 3/4 after A-8 catch-up; 0/4 confirm = **Dismissed**; 1/4 confirm = **Dismissed** as `fast_low_confidence` (report-only); any remaining split triggers the bounded fast debate loop.

`file_coverage` = the number of reviewers whose final `FILES_REVIEWED` set includes the finding's file after the A-8 catch-up batches complete.

**Round 1 — Blind review (§4 output)**

A model's initial blind-review disposition is:
- **explicit confirm** — model raised the finding (was in its output)
- **explicit dismiss** — model reviewed the finding's file and did not raise the finding during blind review
- **abstain** — model did not review the finding's file during blind review; this is not counted as a dismiss

**Round-0 reasoning placeholders:** When recording round-0 votes, use canonical factual placeholders — not invented arguments:
- explicit dismiss → `"(did not raise this finding in blind review)"`
- abstain → `"(did not review this file in blind review)"`

For each finding, tally initial votes:
```
confirm_count = number of models that raised this finding
dismiss_count = number of covering_roles that did NOT raise this finding
abstain_count = 4 - confirm_count - dismiss_count
```

- **Exhaustive profile**
  - 4/4 confirm → **Confirmed** (skip debate)
  - 4/4 dismiss → **Dismissed** (skip debate)
  - Any abstain or split → **proceed to debate**
- **Fast profile**
  - 4/4 confirm → **Confirmed** (skip debate)
  - 3/4 confirm + `abstain_count == 0` + `evidence_unverified != true` + `file_coverage >= 3` → **Confirmed** (skip debate)
  - 4/4 dismiss → **Dismissed** (skip debate)
  - 1/4 confirm + `abstain_count == 0` → **Dismissed** with source `fast_low_confidence` (report-only; do not write durable ledgers)
  - 2/4, or 3/4 without verified evidence / coverage → **proceed to bounded fast debate**

**Debate rounds — parallel algorithm**

After initial tally, partition findings:

```
resolved  = []
contested = []

for finding in all_findings:
    if execution_profile == "exhaustive":
        if finding.confirm_count == 4:
            finding.status = "confirmed"
            resolved.append(finding)
        elif finding.dismiss_count == 4:
            finding.status = "dismissed"
            resolved.append(finding)
        else:
            contested.append(finding)
    else:  # fast
        enough_coverage = file_coverage(finding.file) >= 3
        fully_covered = finding.abstain_count == 0
        if finding.confirm_count == 4:
            finding.status = "confirmed"
            resolved.append(finding)
        elif finding.confirm_count == 3 and fully_covered and not finding.evidence_unverified and enough_coverage:
            finding.status = "confirmed"
            resolved.append(finding)
        elif finding.dismiss_count == 4:
            finding.status = "dismissed"
            resolved.append(finding)
        elif finding.confirm_count == 1 and fully_covered:
            finding.status = "dismissed"
            finding.fast_low_confidence = True
            resolved.append(finding)
        else:
            contested.append(finding)
```

**Record round-0 (blind review) votes — required for all findings before entering the debate loop.** The debate prompt history, stuck-detection vector lookups, and vote audit trail all depend on round-0 entries existing in `votes[finding_id]`. Record them now for every finding (resolved and contested alike):

```python
role_order = ["Implementer", "Implementer-Alt", "Challenger", "Orchestrator-Reviewer"]
for finding in resolved + contested:
    for role in role_order:
        voted_confirm = role in finding.raising_models  # True if this role raised the finding in §4 blind review
        votes[finding.id].append({
            "role": role,
            "model": model_for_role[role],          # from model assignment table in review-templates skill
            "round": 0,
            "phase": current_phase,                 # "main" for §5/§6 initial debate
            "vote": "confirm" if voted_confirm else ("dismiss" if role in finding.covering_roles else "abstain"),
            "reasoning": "raised in blind review" if voted_confirm else ("(did not raise this finding in blind review)" if role in finding.covering_roles else "(did not review this file in blind review)")
        })
```
`finding.raising_models` = the set of role names (e.g., `"Implementer"`, `"Challenger"`) whose §4 output included this finding. Findings in `resolved` with `confirm_count == 4` will have all 4 roles in `raising_models`; those with `confirm_count == 0` will have none.

If `contested` is empty, skip to §7/§8 ledger writes.

**Helper definitions:**

```python
def vote_vector(finding_id, round_num, phase="main"):
    """Return an ordered tuple of vote values for a finding in a specific round and phase.
    Order: (Implementer, Implementer-Alt, Challenger, Orchestrator-Reviewer) — canonical model role order.
    Returns None for any role that did not vote in the specified round and phase.
    phase: "main" for §5/§6 initial debate; "skeptic_redebate" for §6.5 re-debate; "livedata_redebate" for §6.7 re-debate.
    Separate skeptic uphold/challenge votes use phase="skeptic" and are recorded for audit,
    but they are not confirm/dismiss debate rounds and therefore are not queried via vote_vector().
    Keyed by `role` (not model ID) — every vote record MUST include a `role` field."""
    role_order = ["Implementer", "Implementer-Alt", "Challenger", "Orchestrator-Reviewer"]
    round_votes = {v["role"]: v["vote"] for v in votes[finding_id]
                   if v["round"] == round_num and v.get("phase", "main") == phase}
    return tuple(round_votes.get(role, None) for role in role_order)

def latest_votes_from_prior_phase(finding_id):
    """Return the vote tuple for the most recently recorded round for this finding, regardless of phase.
    Used when round==1 in a re-debate phase (no prior rounds in the current phase exist yet).
    'Most recently recorded' means the last-appended votes by insertion order in votes[finding_id],
    NOT the numerically highest round number (round numbers reset to 1 at each phase start, so
    a later phase with fewer rounds could have a lower max round number than an earlier phase).
    Implementation: find the (phase, round) pair whose last vote was most recently appended."""
    role_order = ["Implementer", "Implementer-Alt", "Challenger", "Orchestrator-Reviewer"]
    if not votes[finding_id]:
        return tuple(None for _ in role_order)  # no votes at all — should not happen after round-0 recording
    # Walk votes in reverse insertion order to find the most recently-written (phase, round) pair
    last_entry = votes[finding_id][-1]
    last_phase, last_round = last_entry["phase"], last_entry["round"]
    # Collect all votes for that (phase, round) pair
    round_votes = {v["role"]: v["vote"] for v in votes[finding_id]
                   if v["phase"] == last_phase and v["round"] == last_round}
    return tuple(round_votes.get(role, None) for role in role_order)
```

**Execution-profile constants (set by the caller — not configurable in `config.json`):**

```
MAX_ROUNDS      = 10    # hard cap per phase; force-resolves remaining findings
CUMULATIVE_CAP  = 15    # total debate rounds across ALL phases (§5/§6 + §6.5 + §6.7) per finding
AGENT_TIMEOUT   = 600   # seconds to wait per agent before treating as failed  # F-c2-001
```

**Round loop:**

```
round = 1

# Cumulative debate round tracker — persists across phases (§5/§6, §6.5, §6.7)
# Initialize once per finding when it first enters any debate loop.
# If cumulative_rounds does not yet exist for a finding, set it to 0.
# cumulative_rounds: dict[str, int] — keyed by finding_id
# votes: dict[str, list[dict]] — keyed by finding_id; each entry has keys: role, model, round, phase, vote, reasoning
#         Must be initialized with round-0 entries (blind review tally) BEFORE this loop starts — see round-0 recording step above.

# Variable naming convention in this pseudocode:
#   `finding` = the loop variable (a finding object from the contested list)
#   `finding.id` or `id` = shorthand for the finding's stable ID (e.g., F-c1-001)
#   `finding_id` = same as `id`, used when indexing the global votes ledger
#   `findings[id]` = the global findings dict entry for this finding
#   All three (`id`, `finding_id`, `finding.id`) refer to the same value within a loop iteration.

# Phase context flag — initialized by the caller before entering this loop:
#   is_redebate = False   # §5/§6 initial debate
#   is_redebate = True    # §6.5 skeptic re-debate or §6.7 live-data re-debate
# current_phase = "main" | "skeptic_redebate" | "livedata_redebate"
# Separate uphold/challenge audit votes from §6.5 use phase="skeptic" and are not driven by this loop.
# These variables are SET BY THE CALLER (§5/§6 sets is_redebate=False, current_phase="main";
# §6.5 sets is_redebate=True, current_phase="skeptic_redebate"; §6.7 sets is_redebate=True, current_phase="livedata_redebate").
# They are NOT modified inside this loop.

while contested is not empty AND round <= MAX_ROUNDS:

    # --- Cumulative cap check (before launching round) ---
    for finding in contested:
        if cumulative_rounds.get(finding.id, 0) >= CUMULATIVE_CAP:
            log: "Finding {id} hit CUMULATIVE_CAP={CUMULATIVE_CAP} across all phases. Force-resolving."
            latest_votes = vote_vector(finding.id, round - 1, phase=current_phase) if round > 1 else latest_votes_from_prior_phase(finding.id)
            # NOTE: When round==1 in a re-debate phase (§6.5/§6.7), no round-0 votes exist for the
            # current phase — latest_votes_from_prior_phase() returns the most recent votes from any phase.
            confirm_count = count(v for v in latest_votes if v == 'confirm' and v is not None)
            if confirm_count >= 3:
                findings[id]["status"] = "confirmed"
                findings[id]["debate_forced"] = True
            elif confirm_count <= 1:
                findings[id]["status"] = "dismissed"
                findings[id]["debate_forced"] = True
            else:
                # 2-2 tie: debate_unresolved only — do NOT set debate_forced (F-c2-005)
                # In re-debate (is_redebate=True), preserve pre-challenge confirmed status.
                if not is_redebate:
                    findings[id]["status"] = "pending"  # F-c1-010
                # else: keep existing status (e.g., "confirmed")
                findings[id]["debate_unresolved"] = True  # F-c1-010
            remove from contested

    if contested is empty: break

    # --- Stuck detection (check before launching) ---
    if round >= 4:
        for finding in contested:
            current_vector  = vote_vector(finding.id, round - 1, phase=current_phase)
            previous_vector = vote_vector(finding.id, round - 2, phase=current_phase)
            two_rounds_ago  = vote_vector(finding.id, round - 3, phase=current_phase)
            # Guard: skip stuck detection if any vector contains None (incomplete round)
            if None in current_vector or None in previous_vector or None in two_rounds_ago:
                continue  # Cannot detect stuck state with incomplete data
            if current_vector == previous_vector == two_rounds_ago:
                log: "Finding {id} stalled — identical vote vector for 3 consecutive rounds. Force-resolving."
                apply majority-vote rule (see Force-resolve below — 3/4+ → confirmed, 1/4 or 0/4 → dismissed, 2/4 → debate_unresolved)
                confirm_count = count(v for v in current_vector if v == 'confirm')
                # F-c2-005: only set debate_forced when outcome is confirmed/dismissed, not on 2-2 ties
                if confirm_count >= 3 or confirm_count <= 1:
                    findings[id]["status"] = "confirmed" if confirm_count >= 3 else "dismissed"  # F-c6-004
                    findings[id]["debate_forced"] = True  # F-c2-005
                else:
                    # 2-2 tie: debate_unresolved only — do NOT set debate_forced (F-c2-005)
                    # In re-debate context (§6.5/§6.7), a 2-2 tie is inconclusive: preserve the
                    # pre-challenge confirmed status rather than downgrading to pending.
                    # is_redebate = True when this loop was entered from §6.5/§6.7, False for §5/§6.
                    if not is_redebate:
                        findings[id]["status"] = "pending"  # F-c1-010
                    # else: keep existing status (e.g., "confirmed") — inconclusive challenge
                    findings[id]["debate_unresolved"] = True  # F-c1-010
                remove from contested  # only remove when stuck — non-stuck findings continue to next round
        if contested is empty: break

    # F-c1-011: launch one agent per role (4 total), each receives ALL contested findings
    # Every agent receives the frozen input snapshot:
    #   all contested finding details + all votes and reasoning from prior rounds
    # Use the debate round prompt template from the review-templates skill.
    # Launch the 4 debate agents concurrently via the task tool,
    # using whatever runtime-supported non-serial launch pattern keeps all 4
    # active before collection, plus agent_type="code-review" and the
    # assigned model for each role.
    # CRITICAL: set model: explicitly on each task call
    # Capture snapshot of contested BEFORE launching — used for cumulative counter at end of round
    this_round_findings = list(contested)  # snapshot before any removes this round
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
                votes[finding_id].append({"role": v["role"], "model": v["model"], "round": round, "phase": current_phase, "vote": v["vote"], "reasoning": v["reasoning"]})
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
            if not is_redebate:
                findings[id]["status"] = "pending"  # F-c2-004, F-c1-010
            # else: keep existing status (e.g., "confirmed") — agent failure in re-debate does not downgrade
            findings[id]["debate_unresolved"] = True  # F-c1-010
            for v in round_votes:  # F-c3-001
                votes[finding_id].append({"role": v["role"], "model": v["model"], "round": round, "phase": current_phase, "vote": v["vote"], "reasoning": v["reasoning"], "debate_unresolved": True})
            remove from contested
            # NOT written to §7/§8 ledgers; reported in §10

        else:
            # 0-1 votes — catastrophic failure
            log: "ERROR: <2 votes for finding {id} round {round}. Marking debate_unresolved."
            if not is_redebate:
                findings[id]["status"] = "pending"  # F-c2-004, F-c1-010, F-c9-005
            # else: keep existing status (e.g., "confirmed") — agent failure in re-debate does not downgrade
            findings[id]["debate_unresolved"] = True  # F-c1-010
            for v in round_votes:  # F-c9-006: record any received votes to preserve audit trail
                votes[finding_id].append({"role": v["role"], "model": v["model"], "round": round, "phase": current_phase, "vote": v["vote"], "reasoning": v["reasoning"], "debate_unresolved": True})
            remove from contested

    # Increment cumulative round counter for ALL findings that participated in this round
    # (both resolved and still-contested) BEFORE removing the resolved ones.
    # This ensures cumulative_rounds reflects total debate exposure, not just remaining findings.
    for finding in this_round_findings:  # this_round_findings = snapshot of contested at round start
        cumulative_rounds[finding.id] = cumulative_rounds.get(finding.id, 0) + 1

    round += 1

# --- Force-resolve: MAX_ROUNDS cap ---
if contested is not empty:
    log: "WARN: MAX_ROUNDS={MAX_ROUNDS} reached. {len(contested)} finding(s) still contested."
    for finding in contested:
        latest_votes = vote_vector(finding.id, round - 1, phase=current_phase)
        confirm_count = count(v for v in latest_votes if v == 'confirm' and v is not None)
        if confirm_count >= 3:
            resolved_status = 'confirmed'
        elif confirm_count <= 1:
            resolved_status = 'dismissed'
        else:
            # 2-2 tie — no tiebreaker; flag for manual review
            resolved_status = 'debate_unresolved'
        if resolved_status == 'debate_unresolved':
            # In re-debate (is_redebate=True), preserve pre-challenge confirmed status.
            if not is_redebate:
                findings[id]["status"] = "pending"  # F-c1-010
            # else: keep existing status (e.g., "confirmed")
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

**`debate_unresolved` findings:** This flag has two distinct meanings depending on context:

- **Main debate (§5/§6) — three causes produce `debate_unresolved = True` in the main phase:**
  1. **Agent failure:** Fewer than 2 votes were received for a finding in a round, and retry also failed.
  2. **Stuck-detection 2-2 tie:** The vote vector is identical for 3 consecutive rounds and the final vector is a 2-2 split — models are genuinely deadlocked, not a failure.
  3. **MAX_ROUNDS 2-2 tie:** The hard round cap is hit and the final vote is a 2-2 split.
  In all three cases: finding status is `pending`, NOT written to §7/§8 ledgers. Appears in §10 only. The user can manually review and reclassify.
- **§6.5/§6.7 re-debate — 2-2 tie:** The finding receives a 2-2 split that cannot be resolved within MAX_ROUNDS. Finding **retains its `confirmed` status** (the skeptic/live-data round did not produce a majority to dismiss it) and IS written to the §8 confirmed ledger, annotated with `debate_unresolved: true`.

In both contexts, `debate_unresolved = True` indicates an unresolved split, but the consequences differ: main-debate unresolved findings are excluded from ledgers; re-debate unresolved findings stay confirmed and are written to ledgers.

**`debate_forced` findings:** Hit MAX_ROUNDS or stuck-detection threshold. Written to the appropriate ledger (confirmed or dismissed) per majority-vote, with `debate_forced: true` in the confirmed/dismissed JSONL entries. Surfaced as a dedicated subsection in §10.

After the loop, every finding has a terminal **status** of one of: `confirmed`, `dismissed`, `suppressed`, or `pending`. The flags `debate_forced` and `debate_unresolved` are **orthogonal metadata**, not statuses:
- `debate_forced = True` + status `confirmed` or `dismissed`: finding was force-resolved by majority vote (MAX_ROUNDS or stuck detection). Written to the appropriate §7/§8 ledger with the flag preserved.
- `debate_unresolved = True` + status `pending`: unresolved in the **main** debate phase (agent failure or 2-2 deadlock). NOT written to §7/§8 ledgers. Reported in §10 only.
- `debate_unresolved = True` + status `confirmed`: unresolved **re-debate** in §6.5/§6.7. The finding remains confirmed, is written to §8 with the flag preserved, and is surfaced in the skeptic/live-data report sections.

For termination/clean-cycle purposes: a finding is "resolved" when its status is `confirmed`, `dismissed`, or `suppressed`, OR when it has `debate_unresolved = True`. Proceed to §7/§8 ledger writes, skipping only findings whose status is `pending` with `debate_unresolved = True`.

### Recording votes

For every finding, insert one row per model. Every vote record MUST include `role` (canonical role name, keyed by `vote_vector`) and `phase` (to prevent round-number collisions between debate phases):
```python
votes[finding_id].append({
    "role": role,          # canonical role name: "Implementer", "Implementer-Alt", "Challenger", "Orchestrator-Reviewer"
    "model": model_id,     # actual model ID (e.g. "claude-opus-4.6") — for audit/reporting only
    "round": debate_round, # 0 = blind review tally, 1+ = debate rounds (reset to 1 at each phase start)
    "phase": phase,        # "main" (§5/§6), "skeptic" (§6.5 uphold/challenge), "skeptic_redebate" (§6.5 re-debate), "livedata_redebate" (§6.7 re-debate)
    "vote": vote,
    "reasoning": justification
})  # F-c1-010
```

`debate_round` = 0 for the initial blind review tally, 1+ for debate rounds. Phase resets the round counter — rounds within each phase are independent sequences starting at 1. `vote_vector()` must always be called with the matching `phase` argument to avoid cross-phase vote collisions.

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
**Date:** {YYYY-MM-DD} | **Mode:** {mode} | **Profile:** {execution_profile} | **Repo:** {root}

{IF execution_profile == "fast":}
> Fast profile is advisory only: findings in this report were **not** appended to durable dismissal or confirmation ledgers.
{END IF}

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
| ID | Title | File | Reason | Dismissed By | Source |

> `Source` column values: `debate`, `force_resolve`, `skeptic_reversal`, `livedata_reversal`, `evidence_unverified`; in fast profile, `fast_low_confidence` may also appear for report-only 1/4 findings.

## Force-Resolved Findings
[Findings that hit MAX_ROUNDS or stuck detection — resolved by majority vote with `debate_forced=true`]
| ID | Title | File | Final Vote | Rounds Debated | Resolution Method |

## Unresolved Findings
[Main-phase findings where agent failures or genuine 2-2 deadlocks prevented resolution — `status = pending` with `debate_unresolved=true`, not written to ledgers. Causes: (1) agent failure (<2 votes received and retry failed), (2) stuck-detection 2-2 tie (same vote vector 3 consecutive rounds), (3) MAX_ROUNDS 2-2 tie. Re-debate 2-2 ties from §6.5/§6.7 remain confirmed and are shown in the Skeptic / Live-Data sections instead.]
| ID | Title | File | Partial Votes | Cause |

## Suppressed Findings (Prior Sessions)
[Findings suppressed by fingerprint match against dismissed or confirmed ledgers]
| Fingerprint | Category | File | Suppression Source | Originally Decided |

## Skeptic Round Results
[Only include if skeptic round was enabled and ran. Shows outcome of §6.5 for each confirmed finding.]
| ID | Title | Uphold | Challenge | Outcome | Re-Debate Rounds |

## Live-Data Verification Results
[Only include if live-data verification was enabled and ran. Shows outcome of §6.7 for each verified finding.]
| ID | Title | Verdict | Source URL | Claims Checked | Action Taken |

## Semantically Merged Findings
[Findings merged during semantic dedup — recorded for audit. Omit this section if no merges occurred.]
| Absorbed ID | Absorbed Title | Merged Into | Jaccard Score | Merge Method |

> `Merge Method`: `auto` (Jaccard ≥ 0.65) or `orchestrator` (0.35–0.64 escalated to orchestrator judgment).

## Evidence-Unverified Findings
[Findings where evidence text could not be located in the cited file — may indicate hallucinated evidence. Omit if none.]
| ID | Title | File | Outcome | Evidence Snippet (first 80 chars) |

> Findings with `evidence_unverified: true` and consolidated raise_count < 3 (after fingerprint dedup) are auto-dismissed. Findings with raise_count ≥ 3 proceed to debate with the flag noted. All are listed here regardless of outcome for manual inspection.

## Vote Detail
| Finding | Implementer | Implementer-Alt | Challenger | Orchestrator-Reviewer | Decision |

## By File
| File | Confirmed | Severity breakdown |

## By Category
| Category | Confirmed | Severity breakdown |

## Cycle History
| Cycle | Date | Confirmed | Dismissed | Suppressed | Fixed |
```
