---
name: review-process
description: >
  Fingerprint algorithm, reconciliation rules, and report template
  for the adversarial-review plugin.
---

# Review Process

**Normative precedence:** this skill is a reusable process module referenced by `agents\adversarial-review.agent.md`. If any wording here diverges from the agent spec, the **agent spec wins**.

## Exact Fingerprint (`fp_v1`) and Occurrence Key (`occ_v1`)

Compute two deterministic identities for every finding before reconciliation:

- **`fp_v1`** — exact-match fingerprint for collision-safe suppression/audit when title + evidence text are materially the same
- **`occ_v1`** — locator-backed occurrence key for suppressing, deduplicating, or carry-forward tracking of the same code occurrence when title/evidence wording drifts across models or cycles

`fp_v1` remains the exact canonical identity. `occ_v1` is supplementary and is used only when a stable locator anchor is available.

### Exact fingerprint algorithm

```
fp_v1 = sha256(normalized_category + "|" + normalized_repo_path + "|" + normalized_symbol + "|" + normalized_title + "|" + normalized_evidence)
```

### Occurrence key algorithm

```
occ_v1 = sha256(normalized_category + "|" + normalized_repo_path + "|" + normalized_symbol + "|" + normalized_locator_anchor)
```

Truncate both hex digests to the first **24 characters** (96 bits of entropy — birthday-safe to ~1 billion entries).

### Normalization rules

| Field | Rule |
|-------|------|
| `normalized_category` | Lowercase. Must be one of: security, correctness, reliability, performance, maintainability, accessibility, documentation, testing, configuration |
| `normalized_repo_path` | Repo-relative path with forward-slash normalization and trimming only. **Preserve original case** for identity computation; some repos are case-sensitive. Example: `src/api/controllers/WorkoutController.cs` |
| `normalized_symbol` | Symbol/function/class name if known, trimmed but **case-preserving**. If null, empty string, or no symbol applies, use `"<file>"`. Example: `GetWorkoutPlan`. **Note:** this is the function/class/method name — it is NOT the review scope mode (`full`, `local`, etc.). Case-insensitive reasoning belongs in semantic dedup, not exact identity. |
| `normalized_title` | Lowercase, punctuation collapsed (replace sequences of non-alphanumeric chars with single space), trimmed. Example: `missing input validation on workout id` |
| `normalized_evidence` | Lowercase, all whitespace collapsed to single space, trimmed. Then apply literal substitutions in this order: **(1) String literals** — replace content between matching `"..."` or `'...'` delimiters (exclusive of delimiters) with `<STR>`. Use a **non-greedy (shortest-match)** algorithm; if the evidence contains an escaped delimiter (e.g., `\"` inside a `"`-delimited string), treat the escaped character as literal and do not close the string at that point. Only single-line string content applies; do not match across newlines. Template literals and raw strings are not substituted (too ambiguous — leave as-is). **(2) Numeric literals** — replace tokens matching `0[xX][0-9a-fA-F]+` (hex) or `[0-9]+([._][0-9]+)*([eE][+-]?[0-9]+)?` (decimal/float/version) that are bounded by non-alphanumeric characters or string boundaries, with `<NUM>`. Underscore-separated numbers (e.g., `1_000_000`) are included. Do NOT substitute numbers that are part of identifiers (e.g., `catch2`, `net8`, `v2`, `IAsyncEnumerable<T>` — these are part of a word token and not bounded on both sides by non-alphanumeric chars). After all substitutions, apply **middle-preserving truncation**: take the first 100 characters + `···` + the last 100 characters. If the normalized result is ≤ 200 characters, use it in full (no truncation). This preserves context-identifying head and specificity-bearing tail while avoiding collision risk from common boilerplate tails. *(A-3)* |
| `normalized_locator_anchor` | Used only for `occ_v1`. Preferred form: `L{start_line}-L{end_line}` from reviewer-provided `locator`. If no reviewer locator is present, the orchestrator may infer the anchor from S-1 evidence verification **only when the snippet resolves to a unique line span in the current file**. If the match is missing, ambiguous, or the path is deleted/renamed with no stable line span, `normalized_locator_anchor = null` and `occ_v1` is omitted for that finding. |

> **Implementation note — prefer PowerShell (no extra dependencies):**
> ```powershell
> $sha = [System.Security.Cryptography.SHA256]::Create()
> $bytes = [System.Text.Encoding]::UTF8.GetBytes($input_string)
> $fp_v1 = ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-','').ToLower().Substring(0,24)
> ```
> Python (`hashlib.sha256`) or any other platform tool producing identical hex output is also acceptable. The algorithm is tool-agnostic; only the normalization rules and field ordering matter.

### Suppression check

> **NOTE:** All vote and finding tracking is in-memory only — do NOT create SQL tables.  
> Durable state is rebuilt from JSONL files on each bootstrap. Ephemeral in-run state  
> (vote tracking, findings in progress, cycle history) is persisted to  
> `.adversarial-review/session-state.json` per §2 Steps 0 and 4 of the agent spec — not in SQL.  
> The pseudocode below uses Python-style dict/list notation to describe in-memory operations only. *(F-c1-010)*

After computing `fp_v1` and, when possible, `occ_v1` for a new finding, query `dismissed_findings`:
```python
fp_v1 in dismissed_fps  # check if fingerprint is in the in-memory dismissed_fps set  # F-c1-010, F-c2-003
```

- **Exact match found — same canonical_fields:** Mark finding as `suppressed`. Do not include in voting.
  - To retrieve the stored entry for canonical_fields comparison, iterate the **list** `dismissed_fp_index[fp_v1]` (O(1) reverse lookup by fingerprint to the collision bucket — populated at bootstrap alongside `dismissed_fps`).
- **Exact match found — different canonical_fields:** Hash collision. Do NOT suppress. Flag the finding with `collision = true` and include it in normal voting.
- **No exact match, but `occ_v1` is non-null and `occ_v1 in dismissed_occurrence_keys`:** Iterate `dismissed_occurrence_index[occ_v1]`. If any stored row has matching `occurrence_fields`, mark the finding as `suppressed` by occurrence-key match. This suppresses the same locator-backed code occurrence even when title/evidence wording drifted. If no stored row has matching `occurrence_fields`, treat as an occurrence-key collision and continue normally.
- **No match:** Proceed to reconciliation.

**Confirmed-finding suppression check (mode-dependent):**

After the dismissed check above, also check against the mode-appropriate confirmed exact/occurrence sets:

- In **review-only** mode: check `fp_v1 in confirmed_fps or fp_v1 in run_confirmed_fps` **or** `occ_v1 in confirmed_occurrence_keys or occ_v1 in run_confirmed_occurrence_keys` when `occ_v1` is non-null
- In **review-and-fix** mode: check `fp_v1 in confirmed_fps` **or** `occ_v1 in confirmed_occurrence_keys` when `occ_v1` is non-null

```python
# Review-only mode:
fp_v1 in confirmed_fps or fp_v1 in run_confirmed_fps  # suppress only fixed cross-session findings plus same-run confirmed findings  # F-c7-005
# Review-and-fix mode:
fp_v1 in confirmed_fps  # suppress only fixed confirmed findings
```

Apply the same match/collision logic as the dismissed check:
- **Exact match found — same canonical_fields:** Mark finding as `suppressed`. Do not include in voting.
  - To retrieve the stored entry for canonical_fields comparison, iterate the **list** `confirmed_fp_index[fp_v1]` (O(1) reverse lookup by fingerprint to the collision bucket — populated at bootstrap alongside `confirmed_fps`, `confirmed_all_fps`, and `run_confirmed_fps`; see §2 Step 2).
- **Exact match found — different canonical_fields:** Hash collision. Do NOT suppress. Flag `collision = true`.
- **No exact match, but `occ_v1` is non-null and an allowed confirmed occurrence set contains it:** iterate `confirmed_occurrence_index[occ_v1]`. If any stored row has matching `occurrence_fields`, mark the finding as `suppressed` by occurrence-key match. If none do, treat as an occurrence-key collision and continue normally.
- **No match:** Proceed to reconciliation.

This is the authoritative reconciliation-time suppression gate. The prompt-level hint (injecting fingerprints into reviewer prompts) is best-effort only — reviewers may ignore it. This exact-plus-occurrence check is the defense-in-depth backstop that prevents previously decided findings from re-entering voting because of minor wording drift.

**Canonical format for `canonical_fields`:** A pipe-delimited string matching the `fp_v1` input order: `category|repo_path|symbol|title|evidence` (all values normalized per the `fp_v1` rules above; `symbol` = normalized_symbol value: symbol/function/class name or `"<file>"`). This exact format is used for exact-fingerprint collision checks.

**Canonical format for `occurrence_fields`:** A pipe-delimited string matching the `occ_v1` input order: `category|repo_path|symbol|locator_anchor`. This format is used for occurrence-key collision checks and locator-backed suppression. When `locator_anchor` is unavailable, `occurrence_fields = null` and `occ_v1` is omitted.

---

## Reconciliation Rules

**Reviewer output validation (before reconciliation):** *(F-c9-009)*
After all 4 reviewer agents complete, for each reviewer:
1. Count the number of JSON objects successfully parsed from the output (valid finding lines with required fields).
2. Extract the integer count from the exact trailer line `REVIEW_COMPLETE: N findings` at the end of the output. If the trailer is missing or malformed, log `"WARN: Reviewer {model} omitted valid REVIEW_COMPLETE trailer — treating declared_count as parsed_count for this batch."`, set `declared_count = parsed_count`, and mark `review_complete_valid = false`; otherwise `review_complete_valid = true`.
3. Extract the `REVIEW_RECEIPTS: [...]` line. If it is missing or malformed, log `"WARN: Reviewer {model} provided no valid REVIEW_RECEIPTS — treating receipt coverage as zero until catch-up repairs it."`, treat the reviewer as having completed zero deterministic receipt batches, and mark `receipts_valid = false`. `FILES_REVIEWED` remains an audit/debug signal only. Otherwise `receipts_valid = true`.
4. If `parsed_count < declared_count`: log `"WARN: Reviewer {model} declared {declared_count} findings but only {parsed_count} were parseable ({declared_count - parsed_count} malformed/missing lines)."`
   - **Partial recovery (A-9):** If `parsed_count > 0` AND gap (`declared_count - parsed_count`) ≥ 1: send a recovery prompt to that reviewer agent: *"Your previous output was truncated. You declared {declared_count} findings but only {parsed_count} were parseable. The last successfully parsed finding had id `{last_parsed_id}`. Re-output all findings after that one, in the same JSONL format."* Merge any successfully parsed recovery findings with the original batch. If recovery fails or yields 0 additional parseable findings, proceed with what was originally parsed and log the gap in the §10 report.
5. If `parsed_count == 0` AND `declared_count > 0`: log `"ERROR: Reviewer {model} returned 0 parseable findings vs declared {declared_count} — output may be entirely malformed."` and attempt one retry of that reviewer agent. If retry also yields 0 parseable findings, proceed with 0 for that reviewer and flag in the §10 report (per §13 rule 6a — do not stall waiting for user input).
6. **Usable blind-review output (for the 3-of-4 viability gate):** count a reviewer as **usable** only if either (a) `parsed_count > 0`, or (b) `parsed_count == 0` **and** `review_complete_valid == true` **and** `declared_count == 0` **and** `receipts_valid == true`. A reviewer with 0 parseable lines plus malformed/missing trailers is **not** a zero-findings success; it counts as a failed blind-review agent for §13 rule 6a / A-8 precondition purposes.

The reconciliation set is the **union of all non-suppressed findings** raised by any of the 4 reviewers.

**File coverage check before debate (A-8):**
**Precondition:** A-8 runs only if at least **3 of 4** blind-review agents produced usable outputs after the automatic retry path. If only 2 or fewer blind reviewers succeed, §13 rule 6a in the agent spec takes precedence: abort the cycle and emit a partial report. Catch-up review repairs missing **receipt coverage** from otherwise successful reviewers; it is **not** a substitute for missing reviewer diversity.

After computing the reconciliation set, expand reviewer `REVIEW_RECEIPTS` against the orchestrator's canonical receipt map:
1. For each reviewer, resolve receipt IDs to their file batches and build that reviewer's authoritative covered-file set. `FILES_REVIEWED` remains an audit/debug list and may be used only for WARN messages or diagnostics when receipts are missing.
2. For each scoped file, count how many of the 4 reviewers covered it via receipts.
3. Build `missing_receipts_by_reviewer` from the canonical receipt map minus each reviewer's reported receipt IDs. For each reviewer with missing receipts: log `"WARN: Reviewer {model} missed {count} receipt batch(es) — triggering bounded catch-up review."` Launch one catch-up review per reviewer, reusing the exact missing receipt batches (same reviewer model, same blind-review JSONL schema). Merge any new findings from the catch-up batches into the reconciliation set before evidence verification and deduplication.
4. For each merged finding, compute `covering_roles` = the set of reviewer roles whose final receipt-expanded coverage contains that finding's `file`.
5. For findings in files with < 3-reviewer coverage: treat reviewers that did NOT cover the file via receipts as **abstaining**, not dismissing, for blind-tally purposes (they cannot confirm absence of findings they did not read). Adjust round-0 reasoning accordingly.

**Evidence verification (S-1) — runs after A-8, before identity dedup:**
After the coverage check (so micro-review findings are included), for each finding where `evidence` is non-null AND `file` is non-null:
1. Extract the first 80 characters of the finding's `evidence` field (collapse whitespace only — **do not lowercase**).
2. If the cited path is absent from the current workspace **and** it came from deleted/renamed diff scope, skip current-file verification: annotate `evidence_verification_skipped: "deleted_or_renamed_path"`, log `"INFO: Skipping current-file evidence verification for deleted/renamed path {file} — diff context must be reviewed instead."`, and do **not** set `evidence_unverified`.
3. Otherwise, if the finding includes `locator.start_line` / `locator.end_line`, search the cited `file` within that line window first (allowing a small +/-2-line tolerance for formatter drift). If the snippet matches there, mark the locator as verified and set `locator_anchor = "L{matched_start}-L{matched_end}"`.
4. If the locator window search fails, fall back to a case-insensitive, whitespace-tolerant grep of the full cited file for the 80-char snippet.
5. If the fallback search finds exactly one unique match span, set `locator_anchor = "L{matched_start}-L{matched_end}"` for `occ_v1` computation. If it finds multiple matches, leave `locator_anchor = null` and continue without an occurrence key for this finding.
6. If no match is found after both checks: set `evidence_unverified: true` on the finding and log: `"WARN: Evidence for finding from {model} ('{title[:50]}') could not be located in {file} — may be hallucinated, misquoted, or have a stale locator."`
7. Findings with `evidence_unverified: true` carry the flag into identity dedup. The auto-dismiss decision (raise_count < 3) is applied **after exact-fingerprint and occurrence-key dedup** (step below) using the consolidated `raise_count` (number of distinct models that raised findings merged into the final group) — not the per-reviewer count here. This prevents losing consensus signal when multiple reviewers cite the same bug with slightly different wording. Findings marked `evidence_verification_skipped: "deleted_or_renamed_path"` are **not** eligible for this auto-dismiss path.
8. All findings with `evidence_unverified: true` are listed in the §10 "Evidence-Unverified Findings" section regardless of outcome.

**Only record findings that were actually raised in reviewer output with explicit evidence.** Do not infer, interpolate, or add findings that no reviewer raised. If a finding lacks an `evidence` field citing exact code, treat it as invalid and discard it before voting.

### Deduplication before voting

1. **Exact-fingerprint dedup:** Group findings by `fp_v1`. Findings with the same exact fingerprint from different reviewers are treated as the **same finding**. Merge them: use the most detailed description, combine evidence, note all raising models, and union `covering_roles`.
2. **Occurrence-key dedup:** For remaining groups with non-null `occ_v1`, merge groups that share the same `occurrence_fields`. This is specifically for reworded duplicates of the same locator-backed code occurrence. Preserve the union of `covering_roles` and raising models across the merged group. If two groups share `occ_v1` but the Jaccard similarity of their normalized `(title + description)` strings is **< 0.35**, keep them separate and annotate both with `occurrence_collision: true` instead of auto-merging.

**Merged-field survival rules (apply after exact-fingerprint dedup, occurrence-key dedup, and semantic auto-merge):**
- `fingerprint` / `canonical_fields`: if the merged group came from exact-fingerprint dedup, retain the shared `fp_v1` and `canonical_fields`. Otherwise retain the representative finding's `fingerprint` and `canonical_fields`, where representative = the finding raised by more distinct models, or the first-encountered finding in stable processing order if tied.
- `occurrence_key` / `occurrence_fields`: if every non-null contributor carries the same `occurrence_fields`, keep that pair; if contributors are a mix of that pair and nulls, keep the non-null pair; if contributors carry multiple distinct non-null `occurrence_fields`, clear both fields on the merged finding and set `occurrence_collision: true` rather than picking one arbitrarily.
- `locator`: if a surviving `occurrence_fields` pair remains, keep the locator from the contributor for that pair with the lexicographically earliest `(start_line, end_line, file, reviewer_role)` tuple among non-null locators. If no surviving occurrence pair remains, keep the lexicographically earliest non-null locator across the merged group using that same tuple. If all locators are null, keep null.

**Post-identity-dedup: apply `evidence_unverified` raise_count auto-dismiss:**
After exact-fingerprint and occurrence-key dedup, for each merged finding that has `evidence_unverified: true`, check the consolidated `raise_count` (number of distinct models that contributed to this merged group):

**`evidence_unverified` flag merge rule:** When multiple reviewers contribute to the same merged group, the merged finding has `evidence_unverified: true` if **ANY** contributing reviewer finding had the flag set (OR logic). After merging, re-run the 80-char snippet search against the combined evidence to give the merged finding a chance to clear the flag before the raise_count check.

- If `raise_count < 3`: **auto-dismiss** (explicit pre-debate bypass — fewer than 3 reviewers raised this merged identity group AND evidence is unverifiable). Mark the merged finding `status = "dismissed"` and `dismissal_source = "evidence_unverified"` immediately, but **do not write §7 yet**. Carry the finding through stable-ID assignment so it receives a normal orchestrator `F-c...` ID before any durable write. **Semantic-dedup isolation rule:** once this auto-dismiss is applied, the finding is removed from blind-tally / `contested` partitioning **and** from the semantic auto-merge candidate set; a pre-dismissed evidence-unverified group may not absorb, or be absorbed by, a non-dismissed finding. **Debate-path rule:** once this auto-dismiss is applied, the finding must not enter §5/§6 debate, §6.5 skeptic re-debate, or §6.7 live-data re-debate. It proceeds directly to the dismissed/report flow after stable-ID assignment. Log: `"Auto-dismissed pending stable ID assignment: evidence_unverified and raise_count={raise_count} < 3."` In **exhaustive** profile, write the §7 dismissal entry later in the normal ledger-write pass using the stable `F-c...` ID. In **fast** profile, do **not** write a durable ledger entry — keep the dismissal report-only for this session.
- If `raise_count ≥ 3`: proceed to normal debate but include a note in the debate prompt: `"NOTE: Evidence for this finding could not be verified in the cited file. Reviewers should inspect the code directly before voting."`

### Semantic dedup (post-identity)

After exact-fingerprint and occurrence-key dedup, perform a secondary semantic check on the remaining **non-dismissed** findings only:

1. Group remaining findings by `(file, category)`.
2. Within each group, compare titles pairwise. If two findings target the same file, same category, and have substantially overlapping titles or descriptions (e.g., both reference the same code construct or configuration value), flag them as **candidate duplicates**.
3. Compute Jaccard similarity on character 2-grams of the normalized titles. **Auto-merge** if Jaccard ≥ 0.65. If Jaccard is 0.35–0.64, log a near-duplicate note for audit but **keep the findings separate**. If < 0.35, keep separate. Severity protection rule: **never auto-merge a `critical` or `high` severity finding into a lower severity** — keep the pair separate and log the blocked merge.
    Merge rules (auto only):
    - Use the most detailed description from either finding.
    - Combine evidence from both findings.
    - Use the higher severity if they differ.
    - Record all raising models from both findings.
    - Union `covering_roles` from both findings so later blind-tally logic keeps dismiss vs abstain correct.
    - Representative finding = the finding raised by more models (or the first-encountered if tied); keep its reviewer-local identity as the representative during semantic dedup, apply the merged-field survival rules above for fingerprint/canonical/occurrence/locator fields, and let the orchestrator assign the final stable `F-c...` ID afterward.
    - Log: `"Semantic merge (Jaccard={score:.2f}): {id_kept} absorbed {id_dropped} (same file/category, overlapping title)"`
4. Record all merged pairs (auto only) in a `merged_findings` list for the §10 report "Semantically Merged Findings" section.

### Debate-to-consensus

**Execution-profile inputs (set by the agent, never by `config.json`):**

| Profile | Intended use | `MAX_ROUNDS` | `CUMULATIVE_CAP` | `AGENT_TIMEOUT` | Durable ledgers |
|---------|---------------|--------------|------------------|-----------------|-----------------|
| `exhaustive` | Default authoritative review path | 10 | 15 | 600 | yes |
| `fast` | Advisory `review-only` path | 2 | 2 | 300 | no |

Decision policy depends on the active execution profile:
- **`exhaustive`**: keep the unanimity baseline — 4/4 confirm = **Confirmed**, 0/4 confirm = **Dismissed**, any split triggers debate.
- **`fast`**: 4/4 confirm = **Confirmed**; 3/4 confirm = **Confirmed** only when the fourth reviewer is an `abstain` (no explicit dismiss), `evidence_unverified != true`, and file coverage is at least 3/4 after A-8 catch-up; 4/4 dismiss (= 0 confirm with no abstains) = **Dismissed**; 1/4 confirm = **Dismissed** as `fast_low_confidence` (report-only); any remaining split triggers the bounded fast debate loop.

`file_coverage` = the number of reviewers whose final receipt-expanded covered-file set includes the finding's file after the A-8 catch-up batches complete.

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
  - 3/4 confirm + `dismiss_count == 0` + `evidence_unverified != true` + `file_coverage >= 3` → **Confirmed** (skip debate)
  - 4/4 dismiss → **Dismissed** (skip debate)
  - 1/4 confirm + `abstain_count == 0` → **Dismissed** with source `fast_low_confidence` (report-only; do not write durable ledgers)
  - 2/4, or 3/4 with any explicit dismiss, or 3/4 without verified evidence / sufficient coverage → **proceed to bounded fast debate**

**Debate rounds — parallel algorithm**

Before launching any debate agents, sort `contested` findings by `(severity desc, file, id)` and partition them into deterministic **debate batches**:
- **`exhaustive`**: up to **8 findings per batch**
- **`fast`**: up to **4 findings per batch**

Build batches with a single left-to-right greedy pass over that sorted list: append the next finding to the current batch until adding another would exceed the cap, then start a new batch. Do **not** reorder findings beyond the initial sort to chase file grouping. Run the loop below **once per batch** in deterministic batch order. Within the loop, `contested` and `resolved` refer to the current batch only.

In the pseudocode below, `all_findings` means the **current debate batch input**, not the full run-wide finding set.

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
            finding.dismissal_source = "blind_dismiss"
            resolved.append(finding)
        else:
            contested.append(finding)
    else:  # fast
        enough_coverage = file_coverage(finding.file) >= 3
        fully_covered = finding.abstain_count == 0
        if finding.confirm_count == 4:
            finding.status = "confirmed"
            resolved.append(finding)
        elif finding.confirm_count == 3 and finding.dismiss_count == 0 and not finding.evidence_unverified and enough_coverage:
            finding.status = "confirmed"
            resolved.append(finding)
        elif finding.dismiss_count == 4:
            finding.status = "dismissed"
            finding.dismissal_source = "blind_dismiss"
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

If `contested` is empty, skip the **main debate loop** and proceed directly to the optional §6.5 skeptic round / §6.7 live-data round gating, then to §7/§8 ledger writes.

**Helper definitions:**

```python
def vote_vector(finding_id, round_num, phase="main"):
    """Return an ordered tuple of vote values for a finding in a specific round and phase.
    Order: (Implementer, Implementer-Alt, Challenger, Orchestrator-Reviewer) — canonical model role order.
    Returns None for any role that did not vote in the specified round and phase.
    phase: "main" for §5/§6 initial debate; "skeptic_redebate" for §6.5 re-debate; "live_data_redebate" for §6.7 re-debate.
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
if EXECUTION_PROFILE == "exhaustive":
    MAX_ROUNDS      = 10
    CUMULATIVE_CAP  = 15
    AGENT_TIMEOUT   = 600
else:  # fast
    MAX_ROUNDS      = 2
    CUMULATIVE_CAP  = 2
    AGENT_TIMEOUT   = 300
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
# current_phase = "main" | "skeptic_redebate" | "live_data_redebate"
# Separate uphold/challenge audit votes from §6.5 use phase="skeptic" and are not driven by this loop.
# These variables are SET BY THE CALLER (§5/§6 sets is_redebate=False, current_phase="main";
# §6.5 sets is_redebate=True, current_phase="skeptic_redebate"; §6.7 sets is_redebate=True, current_phase="live_data_redebate").
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

# F-c1-011: launch one agent per role (4 total), each receives the CURRENT debate batch
# Every agent receives the frozen input snapshot:
#   the current batch's finding details + all votes and reasoning from prior rounds
    # Use the debate round prompt template from the review-templates skill.
    # Launch the 4 debate agents concurrently via the task tool,
    # using whatever runtime-supported non-serial launch pattern keeps all 4
    # active before collection, plus agent_type="general-purpose" and the
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

    # --- Debate output count validation (before per-finding tally) ---
    # Every successful debate agent must emit exactly one JSON vote line per
    # contested finding plus `DEBATE_COMPLETE: N`. Validate declared vs parseable
    # counts before collect_votes() so partial outputs cannot silently skew a vote
    # vector or stuck-detection history.
    for each successful_agent in this_round_agents:
        parsed_vote_count = count_parseable_debate_vote_lines(successful_agent.output)
        declared_count = extract_DEBATE_COMPLETE(successful_agent.output)  # exact trailer: `DEBATE_COMPLETE: N findings`
        if declared_count is missing or malformed:
            log: "WARN: Debate agent {model} omitted valid DEBATE_COMPLETE trailer in round {round} — using batch size {len(this_round_findings)} as declared_count."
            declared_count = len(this_round_findings)
        if parsed_vote_count < declared_count:
            log: "WARN: Debate agent {model} declared {declared_count} votes but only {parsed_vote_count} were parseable in round {round} — sending recovery prompt."
            recovery_result = send_recovery_prompt(successful_agent,
                "Your previous debate output was truncated. You declared {declared_count} votes but only {parsed_vote_count} were parseable. "
                "The last successfully parsed vote was for finding id `{last_parsed_id}`. Re-output votes for all findings after that one, "
                "using the same JSON format and ending with DEBATE_COMPLETE.")
            merge any successfully parsed recovery votes with the original round output
            if parsed_vote_count still < declared_count after recovery:
                log: "WARN: Debate agent {model} still missing {declared_count - parsed_vote_count} vote(s) after recovery in round {round}."
    # Missing debate votes are never synthesized as confirm/dismiss. They remain
    # absent from collect_votes(), which forces the finding down the explicit
    # debate_unresolved path below rather than silently counting a partial vector
    # as complete.

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
    "model": model_id,     # actual model ID (e.g. "claude-opus-4.7") — for audit/reporting only
    "round": debate_round, # 0 = blind review tally, 1+ = debate rounds (reset to 1 at each phase start)
    "phase": phase,        # "main" (§5/§6), "skeptic" (§6.5 uphold/challenge), "skeptic_redebate" (§6.5 re-debate), "live_data_redebate" (§6.7 re-debate)
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

When the run ends normally, write the **final aggregate report** to `.adversarial-review/reports/YYYY-MM-DD-cycle-{N}-report.md`. Use today's date for the filename. `cycle-{N}` identifies the **terminal cycle of the run**; it does **not** mean the document is limited to cycle-{N}-only data. When the run stops early because of user stop, blind-review viability failure, fix-agent failure, explicit cycle abort, or fatal ledger-write failure, write a **partial aggregate report** to `.adversarial-review/reports/YYYY-MM-DD-cycle-{N}-partial.md` instead.

```markdown
# Adversarial Code Review — {REPORT_KIND} Report (ended at Cycle {N})
**Date:** {YYYY-MM-DD} | **Mode:** {mode} | **Profile:** {execution_profile} | **Repo:** {root}

> Report scope: final aggregate for this invocation. Unless a section explicitly says otherwise, counts and tables below reflect the final disposition of findings across **all cycles in this run**, not only cycle {N}.
> For partial reports, add `**Stop Reason:** {reason}` and `**Last Completed Phase:** {phase}` immediately under the metadata line, and render every not-yet-reached phase section as `Not run: partial-report-before-phase`.

{IF execution_profile == "fast":}
> Fast profile is advisory only: findings in this report were **not** appended to durable dismissal or confirmation ledgers.
{END IF}

## Summary
| Files reviewed | New findings | Confirmed | Dismissed | Suppressed | Collisions |
|...|...|...|...|...|...|

## Process Telemetry
| Metric | Value |
|...|...|

> Minimum telemetry to include: reviewer retries, parse recoveries, receipt batches, catch-up batches, debate batches, total debate rounds, skeptic candidates/challenges, live-data claim count, live-data batches, fetch-cache hits/misses, phase/section outcome notes (`disabled-by-profile`, `disabled-by-prompt`, `zero_candidates`, `zero_confirmed_findings`, `zero_verifiable_claims`, `all_batches_failed`, `partial-report-before-phase`), and any degraded-path skips.

## Confirmed Findings
[All findings still open/confirmed at run end, sorted by severity desc. In a clean `review-and-fix` run, this section is empty.]
### {ID}: {Title}
**Severity:** {level} | **Category:** {cat} | **File:** `{file}` | **Symbol:** `{symbol}` | **Votes:** {N}/4
**Basis:** {basis}  [Include only when non-null; e.g. `training-data-only` or `live-data-failed`]
**Description:** ...
**Suggested fix:** ...

## Fixed Findings
[Findings that were confirmed in an earlier cycle of this run and later marked `fixed = true` before the run ended.]
| Original ID | Title | File | Fixed In Cycle | Fixed At | Match Key |

## Dismissed Findings
[All findings whose final disposition in this run is dismissed, including evidence-unverified auto-dismissals and skeptic/live-data reversals.]
| ID | Title | File | Reason | Dismissed By | Source |

> `Source` column values: `blind_dismiss`, `debate`, `force_resolve`, `skeptic_reversal`, `live_data_reversal`, `evidence_unverified`; in fast profile, `fast_low_confidence` may also appear for report-only 1/4 findings.

## Force-Resolved Findings
[Findings that hit MAX_ROUNDS or stuck detection — resolved by majority vote with `debate_forced=true`]
| ID | Title | File | Final Vote | Rounds Debated | Resolution Method |

## Unresolved Findings
[Main-phase findings where agent failures or genuine 2-2 deadlocks prevented resolution — `status = pending` with `debate_unresolved=true`, not written to ledgers. Causes: (1) agent failure (<2 votes received and retry failed), (2) stuck-detection 2-2 tie (same vote vector 3 consecutive rounds), (3) MAX_ROUNDS 2-2 tie. Re-debate 2-2 ties from §6.5/§6.7 remain confirmed and are shown in the Skeptic / Live-Data sections instead.]
| ID | Title | File | Partial Votes | Cause |

## Suppressed Findings
[Findings suppressed either by prior-session ledgers or by same-run confirmed suppression during later review-only cycles.]
| Suppression Key | Category | File | Suppression Scope | Suppression Source | Originally Decided |

> `Suppression Scope` values: `prior_session_dismissed`, `prior_session_fixed_confirmed`, or `same_run_confirmed`.

## Skeptic Round Results
[Always render this section in the final report. If the skeptic phase produced per-finding outcomes, show the table below; otherwise replace the table with `Not run: <reason>` where reason is one of `disabled-by-profile`, `disabled-by-prompt`, `zero_candidates`, or `partial-report-before-phase`.]
| ID | Title | Uphold | Challenge | Outcome | Re-Debate Rounds | Flags |

> `Flags` should include `skeptic_skipped` and/or `debate_unresolved` when applicable.

## Live-Data Verification Results
[Always render this section in the final report. If the live-data phase produced per-finding outcomes, show the table below; otherwise replace the table with `Not run: <reason>` where reason is one of `disabled-by-profile`, `disabled-by-prompt`, `zero_confirmed_findings`, `zero_verifiable_claims`, or `partial-report-before-phase`.]
| ID | Title | Verdict | Claims Checked | Source Count | Action Taken | Flags |

> `Verdict` values for this per-finding table should be drawn from the finding-level set: `verified`, `contradicted`, `unverifiable`, or `not-applicable`. When `Action Taken = skipped (agent failure)`, use `Verdict = unverifiable` plus `Flags += live_data_skipped`.
> `Flags` should include `live_data_skipped`, `live_data_contradicted`, and/or `debate_unresolved` when applicable.
> `Action Taken` should explicitly surface `confirmed (training-data-only)`, `confirmed (live-data-failed)`, and `skipped (agent failure)` when applicable.

## Live Data Claim Results
[Always render this section in the final report. If claim verdict rows were recorded, show the table below. Otherwise replace the table with `Not run: <reason>` where reason is one of `disabled-by-profile`, `disabled-by-prompt`, `zero_confirmed_findings`, `zero_verifiable_claims`, or `partial-report-before-phase`. One row per canonical claim verification result, including `unverifiable` outcomes. If every row is synthetic recovery output because live-data batches all failed, still render the table and record `all_batches_failed` in telemetry / degraded-path notes.]
| Claim ID | Linked Findings | Tool | Source URL | Verdict |

## Semantically Merged Findings
[Findings merged during semantic dedup — recorded for audit. Omit this section if no merges occurred.]
| Absorbed ID | Absorbed Title | Merged Into | Jaccard Score | Merge Method |

> `Merge Method`: `auto` only (Jaccard ≥ 0.65 after severity protection). Near-duplicates below that threshold are logged but kept separate.

## Evidence-Unverified Findings
[Findings where evidence text could not be located in the cited file — may indicate hallucinated evidence. Omit if none.]
| ID | Title | File | Outcome | Evidence Snippet (first 80 chars) |

> Findings with `evidence_unverified: true` and consolidated raise_count < 3 (after identity dedup) are auto-dismissed. Findings with raise_count ≥ 3 proceed to debate with the flag noted. All are listed here regardless of outcome for manual inspection.

## Vote Detail
| Finding | Implementer | Implementer-Alt | Challenger | Orchestrator-Reviewer | Decision |

## By File
| File | Confirmed | Severity breakdown |

## By Category
| Category | Confirmed | Severity breakdown |

## Cycle History
| Cycle | Date | Confirmed | Dismissed | Suppressed | Fixed |
```
