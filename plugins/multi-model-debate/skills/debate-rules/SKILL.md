---
name: debate-rules
description: >
  Process rules, evaluation criteria, convergence logic, and model selection
  for multi-model adversarial debates.
---

# Debate Rules

## 1. When to Use This Process

**If the user explicitly invokes the debate process, proceed regardless of the criteria below — unless the question has a single factual answer verifiable by a quick lookup (e.g. "what is the latest version of X"), in which case confirm intent before proceeding.**

Otherwise, before proactively suggesting this process, confirm **both**:
1. The problem matches at least one criterion below
2. The cost of getting this decision wrong justifies the overhead — it is expensive to reverse, or affects correctness, safety, or performance at meaningful scale

Use when any of these apply:
- Multiple valid approaches exist and the tradeoffs are non-obvious
- A previous automated fix or review produced an error that affects functional behavior, performance, or safety — not style, formatting, naming, or minor behavioral nits
- A decision will be expensive to reverse (architecture, public API, schema)
- You need audit-quality reasoning, not just a recommendation
- A single model produced a confident answer you want pressure-tested, and the decision is expensive to reverse or affects correctness/safety

**Do not proactively suggest for:**
- Problems with a single clearly correct answer
- Bugs with a clear stack trace pointing to a single root cause
- Choosing between two approaches where official documentation recommends one
- Questions that a quick experiment, test run, or documentation lookup would settle in minutes
- Decisions that are cheap to reverse (feature flags, internal helpers, configuration values)
- Style, naming, formatting, or minor behavioral nits

---

## 2. Model Selection

Use four models that bring genuinely different reasoning styles. **When launching each debater via the `task` tool, the `model:` parameter MUST be set explicitly** — without it, all agents run on the default model and the multi-model debate collapses to a single-model debate.

| Role | Model family | Strength | `model:` parameter value |
|------|-------------|----------|--------------------------|
| Implementer (primary) | claude-opus (latest) | Deep reasoning, concedes when evidence is clear | `claude-opus-4.6` |
| Implementer (alternate) | gpt-codex (latest) | Strong code + empirical arguments | `gpt-5.3-codex` |
| Challenger | gpt (latest flagship) | Broad architectural perspective | `gpt-5.4` |
| Synthesizer | claude-sonnet (latest) | Reads all positions, writes synthesis, detects consensus | `claude-sonnet-4.6` |

**Always use the latest available version within each model family.** The values above reflect the current model list — if newer versions are available in your context, use those instead. To identify latest: scan the complete available model list, sort by version number descending, and pick the highest.

**GPT family disambiguation — critical:** The GPT family splits into two distinct
sub-families that must NOT be mixed when selecting a role:
- **GPT flagship (non-codex):** models whose ID contains only `gpt` and a version number,
  with no `-codex` suffix. Use for the **Challenger** role. Compare only non-codex GPT
  versions against each other, then pick the highest version.
- **GPT Codex:** models with a `-codex` suffix. Use for the **Implementer (alternate)**
  role only. Compare only codex GPT versions against each other, then pick the highest
  version.

When selecting the Challenger, filter to non-codex GPT models only, then pick the
highest version. A codex model must never fill the Challenger slot, and a non-codex
GPT flagship must never fill the Implementer (alternate) slot.

At selection time, look at the model list available in your current context — do not
rely on training memory or examples in this document.

Any four models with meaningfully different training distributions work. The goal is
genuine disagreement, not confirmation from four similar models.

---

## 3. 10 Mandatory Criteria

Every agent must address ALL mandatory questions in every round. The orchestrator sets
the questions. The **10 default criteria** are defined below — use them in this order:

| # | Criterion | Question to answer | Notes |
|---|-----------|-------------------|-------|
| 1 | **Correctness** | Does this actually solve the problem? Does it handle edge cases? | Gate — if no, stop |
| 2 | **Safety** | Could this cause harm — data loss, outage, silent failure? Is the failure mode safe? | Gate — if harmful, stop |
| 3 | **Security** | Does this introduce attack vectors, privilege escalation, or information disclosure? | |
| 4 | **Performance** | Does this meet latency/throughput requirements? Are there hot-path concerns? | |
| 5 | **Minimality** | Is this the simplest correct solution? Can anything be removed without breaking correctness? | Tiebreaker — simpler answer wins if equally correct on all other criteria |
| 6 | **Cost** | What is the operational cost — compute, storage, API calls, maintenance burden? | |
| 7 | **Observability** | Can you tell when this is working or broken? Are there logs, metrics, alerts? | |
| 8 | **Testability** | Can this be verified? Is there a clear test that would catch a regression? | |
| 9 | **Consistency** | Does this match existing patterns? Does it create an unintended precedent? | |
| 10 | **Reversibility** | How hard is it to undo? Is there a rollback path? | |

Structural logic: *correct? → harmful? → attack surface? → fast enough? → simpler way? → what does it cost? → observable? → testable? → consistent? → recoverable?*

Add domain-specific criteria only by replacing one of 8–10 when the problem warrants it
(e.g., swap Consistency for Backward Compatibility on a public API change). Never exceed 10.

---

## 4. Key Process Rules

### Agents must read files themselves
Do not paste file content into prompts. Agents must read the workspace files and relevant
artifacts themselves. This:
- Keeps prompts manageable
- Forces agents to verify they have the right context
- Prevents the orchestrator from inadvertently filtering what agents see

### Ground technical claims in live documentation

Training data goes stale. For decisions involving library versions, API surface, or
service capabilities, agents must **verify** claims against live documentation rather
than relying on training data alone — and cite the source used. If live documentation
cannot be retrieved, flag the claim as training-data-only and apply the four fallback
rules in the Verification Gate section (retry, isolated section, conditional options, post-decision
verification).

**When live research is mandatory (not optional):** If a debater is making **any claim** in a round that involves the following, they must use `web_fetch` (or an equivalent live retrieval tool) and record findings in a structured `## Live Research Log` table:
- Package/library version numbers
- GA / Preview / deprecated / EOS status for a runtime, service, or SDK
- EOS / support lifecycle dates
- Pricing (any service tier, meter rate, or cost estimate)
- API surface changes or breaking changes since a stated date

**Required format — Live Research Log table** (must appear at the top of the round file):

```
## Live Research Log
| Source URL | Finding | Date Retrieved |
|---|---|---|
| https://... | Latest stable: X.Y.Z | YYYY-MM-DD |
```

A round file that asserts any of the fact types above **without a corresponding row in
the Live Research Log** is making a training-data-only claim. The synthesizer treats
such claims as contested (not given) and flags them.

**When live research is optional:** Purely architectural / pattern decisions (e.g., "data
source vs import," "rate limiter at BFF vs gateway") do not require live fetching. Include
a `## Live Research Log` section with `N/A — no version/status/pricing/API-surface claims in this round`
if nothing was fetched, so the synthesizer can confirm the omission was deliberate.

> **Useful tools:** For coding, architecture decisions, or verifying version/API facts —
> both of these optional MCP tools are worth consulting if available:
> - **Context7** (`context7-resolve-library-id` + `context7-query-docs`) — up-to-date docs
>   and code samples for any library or framework
> - **Microsoft Learn** (`microsoft_docs_search` / `microsoft_docs_fetch` /
>   `microsoft_code_sample_search`) — authoritative docs, code samples, and guidance for
>   Microsoft/Azure products

### Write round files for all back-and-forth
Every round position goes to a durable workspace file. The orchestrator reads these files to synthesize. This:
- Preserves the full debate history across context windows
- Allows the orchestrator to compress and synthesize without losing nuance
- Creates an audit trail for the final decision

### Shifts must be explicit and evidence-driven
An agent that changes position must:
- State explicitly: "I am shifting from [X] to [Y]"
- Name the specific argument or evidence that changed their mind
- Acknowledge what their prior position got right (to prevent wholesale capitulation)

### No implementation until consensus
The implementer (Opus or Codex) does not touch production files until:
- Consensus is reached (4-of-4 immediately, or 3-of-4 validated near-consensus after rebuttal + 2 stuck rounds — see §5 Convergence Criteria)
- The polish round has validated the exact output (code, config, documentation)

### No commit until human review
After implementation:
1. Changes applied to local files
2. Changes deployed to local/test environment (for testability verification — not a production push)
3. Changes reviewed by the designated reviewer model (see Implementation and Review in orchestrator)
4. Human reviews and approves before any `git commit`

---

## 5. Convergence Criteria

### What counts as a "position"

A model's **position** is its **vote** (which option it supports), not the arguments it makes. A dissenter who refines their arguments, attacks from new angles, or adds new evidence has *not* moved — only a vote change counts as movement. This prevents the dissenter window from extending indefinitely due to argument churn.

### Consensus rules

- **4-of-4 agreement** = consensus immediately at any round; proceed to polish round
- **3-of-4 agreement** = "near-consensus" — the dissenter continues debating under the normal convergence and auto-exit rules:
  - Before 3/4 is confirmed, the **majority must explicitly rebut the dissenter's single strongest objection** in their round file. A 3/4 that never addresses the dissenter's best argument is not valid.
  - If any round reaches 4/4 → consensus immediately
  - If any round drops back to a split → near-consensus is cancelled; debate continues normally
  - If the dissenter fails to move anyone across **2 consecutive near-consensus rounds** (no vote changes while at 3/4) → consensus confirmed; the dissenter had full opportunity
- **3/4 is never valid before round 2** — the dissenting position must be heard before it can be overruled; run round 2 regardless
- **Any other split** = run another debate round

The orchestrator enforces a hard round cap (default `max_rounds=10`, configurable via config). Debate runs until 3-of-4 or better, subject to the auto-exit conditions below, but the hard cap triggers force-resolve if consensus has not been reached by round `max_rounds`.

### Long-running debates

After round 6 without consensus, the orchestrator must surface a check-in: report the current vote tally, the core unresolved disagreement, and ask the user whether to continue or terminate. This is not a hard stop — the user can say continue and the debate proceeds. If the user is unavailable, continue automatically.

### Stuck detection

**"Position" = vote.** If no model changes its vote in a completed round, the synthesizer must actively try to break the deadlock with targeted directed questions:
- Identify the single sharpest disagreement between camps. Pose a concrete scenario or test case that would produce different outcomes under each position.
- If still stuck the next round: demand each camp explicitly state what evidence or argument would change their mind. If neither camp can name anything falsifiable, reframe the question — it may be a values disagreement rather than a factual one, and reframing often unlocks movement.

**2/2 automatic exit** — if the vote is 2-2 and no model has changed its vote for **5 consecutive rounds**, the debate cannot converge through argument alone. Write `split-positions.md` automatically (do not wait for the user). Each side's strongest case is documented; the user decides.

**Non-2/2 stagnation exit** — for any other stuck configuration (e.g., 2/1/1 with 3 distinct options, or a split oscillating below 3-of-4 and never stabilizing), if no model changes its vote for **5 consecutive rounds**, the synthesizer must run a **forcing function round**: each camp must explicitly state what concrete evidence or test would falsify their position. A camp that cannot name a falsifiable criterion is flagged as holding a non-empirical position. If the vote still does not move in the round following the forcing function, write `split-positions.md` automatically. Note: this does not apply to near-consensus (3/4) — that path has its own confirmation rules above.

For splits other than 2-2 that are still moving (any model changed vote in the last round), debate continues subject to the orchestrator hard cap (`max_rounds`).

**When 4/4 unanimous consensus is reached**, the Synthesizer (debate-synthesizer agent) writes `consensus.md` immediately after the final synthesis. **When confirmed near-consensus (3/4) is reached**, the orchestrator writes `consensus.md` as part of Step 3. In both cases, `consensus.md` captures the agreed decision, the key rationale, and any dissenting concerns that were raised and addressed. This file is required reading for the polish round.

## 5.1 Degraded-Round Convergence Paths

### Degraded rounds

A **degraded round** occurs when one or more debaters time out or produce no output. The orchestrator passes `degraded=true` and `present_count=(4 - missing_count)` to the synthesizer.

**Key rules:**
- **All present agents agree** (`present_count`-of-`present_count`) in a degraded round → **near-consensus only**, NOT immediate consensus. One additional clean non-degraded round is required to confirm. The `degraded_unanimous_pending` flag is set while awaiting that confirmation round.
- **`(present_count-1)`-of-`present_count` agree with a present dissenter (`present_count >= 3`)** → degraded near-consensus: apply the same rebuttal-check and `near_consensus_stuck` logic as the normal 3/4 path.
- **Any other split among present agents** → apply normal split rules scaled to `present_count`.
- **All 4 debaters absent** → do not invoke the synthesizer; report total failure to the user.

The `degraded_unanimous_pending` flag resets when: (a) the confirmation non-degraded round runs, or (b) the vote drops back below near-consensus. Full implementation details are in the orchestrator agent spec (Step 2, items 6 and 10).

---

## 6. Verification Gate for context.md

If the question involves library versions, API surface, release state, deprecation status,
pricing, or any claim whose correctness depends on a date — **whoever writes context.md**
(human or orchestrator) **must fetch live documentation** and record the results in a
**Verified Facts** section using this structure:

```
## Verified current-state facts
| Claim | Source URL | Date Retrieved |
|-------|-----------|----------------|

## Training-Data-Only Claims
(facts known only from model training data because live fetch failed after retry;
may be stale — treat as contested, not given)

## Options (derived from verified facts above)
```

Prefer primary sources in this order: official docs/changelog/release notes →
official package registry metadata → official repository releases/tags → secondary
sources. For version-selection questions, record at minimum the latest stable version,
any relevant prerelease, and any stated support/LTS/deprecation status.

**When live documentation cannot be retrieved, apply all four rules:**

**Rule 1 — Retry once.** Retry the fetch once with short backoff before marking a
claim as training-data-only. Record both attempts in context.md (e.g., *"Fetch
attempted twice: both failed with [error]"*). Only move to the Training-Data-Only
section if both attempts fail.

**Rule 2 — Isolated section.** Place all unconfirmed claims in the dedicated
`## Training-Data-Only Claims` section. Do not embed them inline in
`## Verified Facts` or option prose.

**Rule 3 — Conditional options.** For each training-data-only claim, apply this
test: *if flipping the claim (true ↔ false) would change (a) which options are
valid, (b) option feasibility, or (c) the recommended ranking* — the claim is
**load-bearing**. For every load-bearing claim, options must include explicit
true/false branches and may not be written or ranked as if the claim were true
unless that branch is explicitly labeled as conditional. This judgment is made by
the context.md author and is **explicitly challengeable by any debater in Round 1**.
If more than two claims are independently load-bearing, flag this to the
orchestrator — they may request a blocking re-fetch rather than proliferating
conditional branches.

**Rule 4 — Post-decision verification.** Before the final recommendation is
published, the orchestrator must re-verify all load-bearing training-data-only
claims using the source hierarchy. If verification yields a definitive answer,
resolve to the matching conditional branch. If still unresolved, the recommendation
must include a **Blocking Assumptions** section naming each unresolved claim and
the branch-dependent impact. The orchestrator records the verification result —
claim, outcome, and branch selected — in the final recommendation document.

**Options must not be defined unconditionally on load-bearing training-data-only
claims.** Conditional options (branched on the claim's truth) are permitted and
preferred over blocking the debate entirely.

---

## 7. Calibration Notes

- **Rounds 1–2** typically surface factual disagreements (who's right about what the
  code does, what the empirical behavior is)
- **Round 3** typically surfaces the real value tradeoff (minimality vs. safety,
  consistency vs. flexibility)
- **Round 4+** — not unusual under the new rules; if you reach it, either a dissenter is still holding out or the debate dropped back from near-consensus. Check whether any model changed position in the last round; if not, the debate is stuck — apply stuck detection per §5 rules: 3/4 uses the `near_consensus_stuck` counter; 2-2 uses the `two_two_stuck` counter (auto-exit at 5 consecutive stuck rounds — the debate does not immediately surface to the user). If models are still shifting, keep going — the deciding factor is usually a criterion that wasn't made explicit until that round (add it to context.md for future runs)
- Models converge faster when the evidence is unambiguous; empirical tests (running the
  actual code and reporting output) are more powerful than theoretical arguments
- A model that has shifted once is more likely to shift again — evaluate the *evidence*
  they cited for the shift, not the act of shifting itself. An explicit evidence-driven
  shift is a sign the process is working.

---

## 8. Signals

### Signals the process is working

✅ Agents explicitly disagree with each other by name and argument
✅ At least one agent shifts position during the debate
✅ The final consensus addresses the dissenting position's strongest point
✅ The output (code, config, documentation) is validated before being written
✅ The test either passes clean or generates a new debate cycle

### Signals the process is not working

❌ All agents agree in Round 1 **without independently derived evidence** (unanimous early convergence is fine if each agent reached the same conclusion independently — the red flag is agreement without anyone challenging an assumption)
❌ Agents shift without citing specific new evidence
❌ The synthesis doesn't surface unresolved questions
❌ Implementation is done before the polish round
❌ Test failures are fixed without going back through the debate cycle
