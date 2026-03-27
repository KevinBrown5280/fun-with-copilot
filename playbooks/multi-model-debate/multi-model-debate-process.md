# Multi-Model Adversarial Debate Process

A repeatable process for reaching high-confidence technical decisions on hard problems
where a single model's judgment is insufficient. Designed for enterprise-level technical
decisions — code reviews, architectural tradeoffs, implementation choices, platform
selection, feature scoping, and bug fixes — where accuracy is more important than speed.

---

## When to use this process

**If the user explicitly invokes the debate process, proceed regardless of the criteria below.**

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

## Models

Use four models that bring genuinely different reasoning styles. Suggested configuration:

| Role | Model family | Strength |
|------|-------------|----------|
| Implementer (primary) | claude-opus (latest) | Deep reasoning, concedes when evidence is clear |
| Implementer (alternate) | gpt-codex (latest) | Strong code + empirical arguments |
| Challenger | gpt (latest flagship) | Broad architectural perspective |
| Orchestrator / tiebreaker | claude-sonnet (latest) | Synthesis and deciding vote if needed |

**Always use the latest available version within each model family.** To identify
latest: scan the complete available model list, sort by version number descending
(e.g. `claude-opus-4.6 > claude-opus-4.5`; `gpt-5.3-codex > gpt-5.1-codex`), and
pick the highest. Do not anchor on the first model whose name contains the family
prefix.

Any four models with meaningfully different training distributions work. The goal is
genuine disagreement, not confirmation from four similar models.

---

## Setup

### 1. Create a debate workspace
A dedicated folder in your session state (or project temp folder):
```
<workspace>/
  context.md                  ← master briefing (all agents read this first)
  round-1-<model>.md          ← each agent's Round 1 position (one file per model)
  round-1-synthesis.md
  round-2-<model>.md
  round-2-synthesis.md
  ... (repeat per round)
  round-N-synthesis.md
  consensus.md                ← final decision with full rationale (Orchestrator writes)
  implementation-notes.md     ← written by implementer before review begins
  polish-<model>.md           ← each agent's validation verdict
  <model>-review.md           ← reviewer's verdict on implementation
  test-failure.md             ← (optional) test output if testing cycle triggered
```

> **Naming convention:** `<model>` in filenames is the model family shorthand (e.g.,
> `opus`, `sonnet`, `codex`, `gpt`). Agree on identifiers before Round 1 and record them
> in `context.md` — agents reading each other's files need consistent names to find them.
>
> **Workspace path:** Record the absolute path to `<workspace>/` in `context.md` so all
> parallel agents write to the same folder.

### 2. Write context.md

**Owner: the human initiating the debate** (or an orchestrating agent acting on the human's
behalf). This file is the entry point — no agent begins Round 1 until it exists.

Include:
- **Problem statement** — what is broken, ambiguous, or being decided
- **Evidence** — relevant code, logs, schemas, git history, empirical test results
- **Options under consideration** — labeled A/B/C etc. with brief descriptions
- **Enterprise quality bar** — the standard the solution must meet
- **Explicit decision criteria** — what tradeoffs matter (performance, maintainability,
  consistency, safety, future expansion, etc.)
- **Final validation round** — note that a polish/validation round follows consensus

> **Mandatory verification gate for context.md:** If the question involves library
> versions, API surface, release state, deprecation status, pricing, or any claim whose
> correctness depends on a date — **whoever writes context.md** (human or orchestrator)
> **must fetch live documentation** (e.g., via `web_fetch` on the project's releases page)
> and record the results in a **Verified Facts** section using this structure:
>
> ```
> ## Verified current-state facts
> | Claim | Source URL | Date Retrieved |
> |-------|-----------|----------------|
>
> ## Training-Data-Only Claims
> (facts known only from model training data because live fetch failed after retry;
> may be stale — treat as contested, not given)
>
> ## Options (derived from verified facts above)
> ```
>
> Prefer primary sources in this order: official docs/changelog/release notes →
> official package registry metadata → official repository releases/tags → secondary
> sources. For version-selection questions, record at minimum the latest stable version,
> any relevant prerelease, and any stated support/LTS/deprecation status.
>
> **When live documentation cannot be retrieved, apply all four rules:**
>
> **Rule 1 — Retry once.** Retry the fetch once with short backoff before marking a
> claim as training-data-only. Record both attempts in context.md (e.g., *"Fetch
> attempted twice: both failed with [error]"*). Only move to the Training-Data-Only
> section if both attempts fail.
>
> **Rule 2 — Isolated section.** Place all unconfirmed claims in the dedicated
> `## Training-Data-Only Claims` section. Do not embed them inline in
> `## Verified Facts` or option prose.
>
> **Rule 3 — Conditional options.** For each training-data-only claim, apply this
> test: *if flipping the claim (true ↔ false) would change (a) which options are
> valid, (b) option feasibility, or (c) the recommended ranking* — the claim is
> **load-bearing**. For every load-bearing claim, options must include explicit
> true/false branches and may not be written or ranked as if the claim were true
> unless that branch is explicitly labeled as conditional. This judgment is made by
> the context.md author and is **explicitly challengeable by any debater in Round 1**.
> If more than two claims are independently load-bearing, flag this to the
> orchestrator — they may request a blocking re-fetch rather than proliferating
> conditional branches.
>
> **Rule 4 — Post-decision verification.** Before the final recommendation is
> published, the orchestrator must re-verify all load-bearing training-data-only
> claims using the source hierarchy. If verification yields a definitive answer,
> resolve to the matching conditional branch. If still unresolved, the recommendation
> must include a **Blocking Assumptions** section naming each unresolved claim and
> the branch-dependent impact. The orchestrator records the verification result —
> claim, outcome, and branch selected — in the final recommendation document.
>
> **Options must not be defined unconditionally on load-bearing training-data-only
> claims.** Conditional options (branched on the claim's truth) are permitted and
> preferred over blocking the debate entirely.
>
> (See also: *Ground technical claims in live documentation* in the Key process rules
> section, which applies the equivalent obligation to every round.)

---

## Round structure

### Round 1 — Independent positions
Each model reads `context.md` + all relevant artifacts (source files, docs, configs, schemas) independently.
Each writes its full position to `round-1-<model>.md`:
- **Sourcing audit:** If context.md contains version/release/date-sensitive claims, verify
  they have source URLs in the Verified Facts section. If they do not, flag this in your
  round file and treat the affected claims as training-data-only/contested. If any
  training-data-only claim is load-bearing to the option definitions, verify that options
  are written conditionally — if not, raise this explicitly.
- Analysis of the problem
- Recommended option with explicit rationale
- Weaknesses of the other options

Launch all four agents **in parallel** (background mode). They do not see each other's
output yet. **Sonnet submits its own `round-1-sonnet.md` position alongside the others
before reading any of them** — its position counts as one of the four votes toward
convergence thresholds.

The **Orchestrator (Sonnet)** then reads all four `round-1-<model>.md` files and writes
`round-1-synthesis.md`:
- Where agents agree
- Where they disagree (the actual split)
- Unresolved questions to address in Round 2

> **Note on the orchestrator's dual role:** Sonnet participates as a debater in rounds
> AND writes synthesis and casts tiebreaker votes. This is a known trade-off — Sonnet's
> synthesis inevitably reflects its own reasoning style. Mitigate by keeping synthesis
> descriptive (report what others said) rather than evaluative (judge who is right) until
> the tiebreaker is explicitly needed.

### Round 2+ — Adversarial cross-examination
Each model reads:
- All prior round files for all agents
- `round-N-synthesis.md`
- Any new evidence gathered since Round 1

Each agent must:
- Directly address the strongest argument against their position
- Either defend their position with new evidence/reasoning, or explicitly shift
- State what would change their mind

Write updated synthesis after each round.

### Convergence criteria
- **3-of-4 agreement** = consensus reached
- **4-of-4 agreement** = proceed to polish round immediately
- **2-vs-2 split after 3 rounds** = orchestrator (Sonnet) casts deciding vote with
  explicit written rationale
- **2-1-1 or other multi-way split** = orchestrator identifies the majority position
  and runs one additional round focused on the dissenting arguments before deciding

Typical convergence: 2–4 rounds. If still split at round 4, the orchestrator decides.

**When consensus is reached**, the Orchestrator writes `consensus.md` immediately after
the final synthesis. It should capture the agreed decision, the key rationale, and any
dissenting concerns that were raised and addressed. This file is required reading for the
polish round.

### Polish / validation round
After consensus, one final round where:
- All agents read `consensus.md` and relevant artifacts
- They validate the proposed implementation against all 10 criteria
- They flag any final issues with the *exact* output to be used (not the abstract decision)
- Each agent writes their verdict to `polish-<model>.md`
- The Orchestrator scans the polish files for blockers before the implementer proceeds
- The implementer (Opus or Codex) writes the final production-ready artifact

---

## Mandatory criteria per round

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

## Key process rules

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
rules in the Setup section (retry, isolated section, conditional options, post-decision
verification).

> (For the stricter gate that applies when writing context.md — including the required
> Verified Facts table structure and source hierarchy — see the Setup section above.)

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
- Consensus is reached (3-of-4 minimum)
- The polish round has validated the exact output (code, config, documentation)

### No commit until human review
After implementation:
1. Changes applied to local files
2. Changes deployed to local/test environment (for testability verification — not a production push)
3. Changes reviewed by the designated reviewer model (see Reviewer section)
4. Human reviews and approves before any `git commit`

---

## Implementation and review

### Implementer selection
- **claude-opus (latest)** — preferred for large, complex changes requiring careful
  reading of existing code and nuanced edits
- **gpt-codex (latest)** — preferred for precise, surgical code changes with clear
  mechanical steps

Only one model implements per run. The other becomes the reviewer.

### Reviewer
The non-implementing model reviews the changes. In the standard 4-model configuration
this is the Implementer (alternate) — whichever implementer did not run this time.

Before review begins, the implementer writes `implementation-notes.md` describing what
was changed, why, and any deviation from the consensus text.

The reviewer:
- Reads `implementation-notes.md` and the actual changed files
- Compares against the consensus text
- Flags any deviation, omission, or unintended side effect
- If issues found: one discussion round between implementer and reviewer to resolve,
  then implementer applies corrections
- Writes verdict to `<reviewer>-review.md`

---

## Testing cycle

> **For decision-only debates** (platform selection, architecture, feature scoping) where
> there is no runnable artifact, skip this section. The process ends at the polish round.

After implementation is reviewed and approved:

1. **Run the test** (the actual system, not a dry-run simulation)
2. **If clean** → present to human for commit approval
3. **If issues found** → restart the debate process with the test failure as new evidence:
   - Add test output to `context.md` or a new `test-failure.md`
   - Run full debate on the new issue (same round structure)
   - Implement fix, re-review, re-test
   - Repeat until clean

---

## Prompt template for each round

**Round 1 template** (no prior round files exist yet):

```
You are [model-name], acting as [role: Implementer / Challenger / Orchestrator] in
Round 1 of a [N]-model adversarial debate.

## Required reading (do this first)
- [debate workspace]/context.md
- [relevant artifacts: source files, docs, configs, schemas]

## Mandatory questions for this round
Address ALL of the following criteria in order:
1. Correctness — Does this actually solve the problem? Does it handle edge cases?
2. Safety — Could this cause harm? Is the failure mode safe?
3. Security — Does this introduce attack vectors or information disclosure?
4. Performance — Does this meet requirements? Any hot-path concerns?
5. Minimality — Is this the simplest correct solution?
6. Cost — What is the operational cost?
7. Observability — Can you tell when this is working or broken?
8. Testability — Can this be verified? What test would catch a regression?
9. Consistency — Does this match existing patterns?
10. Reversibility — How hard is it to undo?
(Items 1–10 are evaluation criteria — the 10-criterion cap applies here. Items below are debate mechanics.)
11. Final vote: [Option A / B / C] with one-sentence rationale

## Output
Write your full position to: [debate workspace]/round-1-[your-model].md

Be specific. Cite exact evidence (line numbers, section headings, timestamps, etc.).
Challenge the weaknesses of each option you do not recommend.
```

---

**Round 2+ template** (prior round files exist):

```
You are [model-name], acting as [role: Implementer / Challenger / Orchestrator] in
Round [R] of a [M]-model adversarial debate.

## Required reading (do this first)
- [debate workspace]/context.md
- [debate workspace]/round-[N-1]-synthesis.md
- [debate workspace]/round-[N-1]-[your-model].md        ← your prior position
- [debate workspace]/round-[N-1]-[all other models].md  ← all opposing positions
- [relevant artifacts: source files, docs, configs, schemas]

## Mandatory questions for this round
Address ALL of the following criteria in order:
1. Correctness — Does this actually solve the problem? Does it handle edge cases?
2. Safety — Could this cause harm? Is the failure mode safe?
3. Security — Does this introduce attack vectors or information disclosure?
4. Performance — Does this meet requirements? Any hot-path concerns?
5. Minimality — Is this the simplest correct solution?
6. Cost — What is the operational cost?
7. Observability — Can you tell when this is working or broken?
8. Testability — Can this be verified? What test would catch a regression?
9. Consistency — Does this match existing patterns?
10. Reversibility — How hard is it to undo?
(Items 1–10 are evaluation criteria — the 10-criterion cap applies here. Items below are debate mechanics.)
11. Directly address the strongest argument from the synthesis against your position
12. State explicitly: are you holding your position or shifting? If shifting, name the
    exact argument or evidence that changed your mind. If holding, state what would
    change your mind.
13. Final vote: [Option A / B / C] with one-sentence rationale

## Output
Write your full position to: [debate workspace]/round-[N]-[your-model].md

Be specific. Cite exact evidence (line numbers, section headings, timestamps, etc.).
Do NOT provide production-ready implementation until the polish round.
```

---

**Polish round template** (after consensus is reached):

```
You are [model-name] in the polish / validation round of a [N]-model adversarial debate.
Consensus was reached on [Option X].

## Required reading (do this first)
- [debate workspace]/consensus.md
- [relevant artifacts: source files, docs, configs, schemas]

## Your task
1. Validate the consensus decision against all 10 criteria (see Mandatory criteria section)
2. Flag any final issues with the *exact* proposed output — not the abstract decision
3. [Implementer only] Write the final production-ready artifact

## Output
Write your validation notes to: [debate workspace]/polish-[your-model].md
[Implementer only] Apply changes to the actual files after validation passes.
```

---

## Calibration notes

- **Rounds 1–2** typically surface factual disagreements (who's right about what the
  code does, what the empirical behavior is)
- **Round 3** typically surfaces the real value tradeoff (minimality vs. safety,
  consistency vs. flexibility)
- **Round 4+** is rare — if you reach it, the deciding factor is usually a criterion
  that wasn't made explicit until that round (add it to context.md for future runs)
- Models converge faster when the evidence is unambiguous; empirical tests (running the
  actual code and reporting output) are more powerful than theoretical arguments
- A model that has shifted once is more likely to shift again — evaluate the *evidence*
  they cited for the shift, not the act of shifting itself. An explicit evidence-driven
  shift is a sign the process is working.

---

## Signals the process is working

✅ Agents explicitly disagree with each other by name and argument  
✅ At least one agent shifts position during the debate  
✅ The final consensus addresses the dissenting position's strongest point  
✅ The output (code, config, documentation) is validated before being written  
✅ The test either passes clean or generates a new debate cycle  

## Signals the process is not working

❌ All agents agree in Round 1 **without independently derived evidence** (unanimous early convergence is fine if each agent reached the same conclusion independently — the red flag is agreement without anyone challenging an assumption)  
❌ Agents shift without citing specific new evidence  
❌ The synthesis doesn't surface unresolved questions  
❌ Implementation is done before the polish round  
❌ Test failures are fixed without going back through the debate cycle  
