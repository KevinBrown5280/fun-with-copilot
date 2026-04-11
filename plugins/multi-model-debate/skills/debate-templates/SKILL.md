---
name: debate-templates
description: >
  Prompt templates and workspace file structure for multi-model adversarial debates.
  Used by the debate-round agent to construct per-model prompts.
---

# Debate Templates

## 1. Workspace File Structure

A debate workspace contains the following files:

```
<workspace>/
  context.md                  ← master briefing (all agents read this first)
  round-1-<model>.md          ← each agent's Round 1 position (one file per model)
  round-1-synthesis.md        ← includes clustering result if fragmented
  round-2-<model>.md
  round-2-synthesis.md
  ... (repeat per round)
  round-N-synthesis.md
  consensus.md                ← final decision with full rationale (Orchestrator writes)
  implementation-notes.md     ← written by implementer before review begins
  polish-<model>.md           ← each agent's validation verdict
  <model>-review.md           ← reviewer's verdict on implementation
  split-positions.md          ← (if 2-2 auto-exit, non-2/2 stagnation exit, or Kevin stops): each side's best case + recommended next step
  test-failure.md             ← (optional) test output if testing cycle triggered
```

**Naming convention:** `<model>` in filenames is the model family shorthand (e.g.,
`opus`, `sonnet`, `codex`, `gpt`). Agree on identifiers before Round 1 and record them
in `context.md` — agents reading each other's files need consistent names to find them.

**Workspace path:** Record the absolute path to `<workspace>/` in `context.md` so all
parallel agents write to the same folder.

---

## 2. Round 1 Prompt Template

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

## 3. Round 2+ Prompt Template

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

## 4. Polish Round Prompt Template

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

## 6. split-positions.md Template

When a debate exits without consensus (2-2 auto-exit, non-2/2 stagnation exit, or Kevin terminates), write this file:

```
# Split Positions

## Exit reason
[2-2 deadlock after N consecutive stuck rounds | stagnation exit after forcing function | Kevin terminated]

## Round reached
Round N

## Vote tally at exit
Option A: N models (list names)
Option B: N models (list names)

## Position A — [option name]
**Advocates:** [model names]
**Core argument:** [2–3 sentences: the strongest case for this option]
**Key evidence:** [specific claims, tests, or data cited]
**What would change this position:** [falsifiable criterion, if provided]

## Position B — [option name]
**Advocates:** [model names]
**Core argument:** [2–3 sentences: the strongest case for this option]
**Key evidence:** [specific claims, tests, or data cited]
**What would change this position:** [falsifiable criterion, if provided]

## Recommended next step

Choose one or more:

- **DEFER** — Wait for more evidence before deciding. Appropriate when: the debate exposed missing data that could be gathered (e.g., run a benchmark, get user feedback, wait for a library to stabilize). Blocking assumption: [state what needs to be true before revisiting]
- **ESCALATE** — Bring in additional expertise or a human decision-maker beyond the current process. Appropriate when: the disagreement is a values/priorities question (not factual), or requires authority that models cannot provide.
- **TEST** — Run a concrete experiment to break the tie. Appropriate when: a specific test case or benchmark would produce different outcomes under each option, and running it is feasible. Test to run: [describe exact test]
```

---

## 7. Synthesis Template Guidance

The synthesizer writes `round-N-synthesis.md` after each round with this structure:

- **Vote changes this round** — list each model that changed its vote vs. prior round, with their one-sentence stated reason (if no model changed: note "no vote changes")
- **Where agents agree** — positions and reasoning held in common
- **Where they disagree** — the actual split, by agent name and argument
- **Unresolved questions** — issues to address in the next round
- **Directed questions** — specific questions for specific agents based on their positions

**Rule:** Keep synthesis descriptive (report what others said) rather than evaluative
(judge who is right) until the tiebreaker is explicitly needed.

**Note on the orchestrator's dual role:** Sonnet participates as a debater in rounds
AND writes synthesis and casts tiebreaker votes. This is a known trade-off — Sonnet's
synthesis inevitably reflects its own reasoning style. Mitigate by keeping synthesis
descriptive rather than evaluative until the tiebreaker is explicitly needed.
