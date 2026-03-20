# Research: Workflow System — Boris Tane + Addy Osmani + Clean Room Agentic Workflow

**Task:** 000001-chore_workflow_setup
**Stage:** 020-research
**Sources:** docs/000-workflow-research.md, docs/000-workflow-plan.md,
             addyosmani.com (good-spec, self-improving-agents, bias-towards-action, agentic-engineering),
             user CR-AW spec v1

---

## 1. Existing Foundation (Boris Tane Workflow)

The current workflow plan (`docs/000-workflow-plan.md`) is already adapted for Swift/macOS. Core flow:

```
Research → Plan → Annotate (1–6 cycles) → Implement
```

Each phase produces a persistent markdown artifact. Research is always done deeply and in writing —
never just verbally summarized. Plans include code snippets, file paths, and trade-offs. Annotations
are inline notes in the plan doc. Implementation uses a standard prompt template with continuous
xcodebuild typecheck.

**What's working:** Solid philosophy, good Swift-specific adaptations.

**What's missing:** Command scaffolding, artifact naming convention, task lifecycle tracking,
independent verification (not self-review), and the Clean Room separation for feature work.

---

## 2. Addy Osmani — Key Additions

### good-spec
- **Spec-driven gating:** Specify → Plan → Tasks → Implement. Each phase gates the next.
- **Three-tier boundaries** embedded in CLAUDE.md: Always / Ask First / Never
- **Modular prompts over monolithic context:** Spec performance degrades as requirements stack.
  Phase-scoped prompts avoid the "curse of instructions."
- **Plan mode (read-only) enforcement:** Agents must analyze and draft before executing.

### self-improving-agents
- **Atomic tasks with unambiguous pass/fail criteria** — "add navigation bar with Home/About/Contact;
  active link highlighted in blue" not "build the dashboard"
- **Six-step loop:** Select → Implement → Validate → Commit → Document learnings → Reset context
- **Four-channel memory:** CLAUDE.md (semantic knowledge), task registry (state), progress logs, git history
- **Mistakes become durable knowledge** — when Claude makes a wrong assumption, add it to CLAUDE.md
  as a gotcha, not just a chat correction

### bias-towards-action
- **70% information threshold** — act before perfect certainty; research stops at "sufficient
  understanding," not exhaustive documentation
- **Two-way door test** — before extensive analysis, ask "can this be reversed?" Small-scoped changes
  are two-way doors; act on them faster
- **Define "done" before starting** — acceptance criteria must exist before delegation, not after

### agentic-engineering
- **Testing is the primary differentiator** — tests enable reliable agent delegation. Without them,
  agent output is unreliable; with them, it's reproducible
- **Human owns architecture** — Claude implements, human decides system design, security, performance
- **Skill atrophy risk** — never merge what you don't understand. Review every module

---

## 3. The Confirmation Bias Problem (CR-AW Rationale)

When a single agent writes both implementation code and the tests that verify it, the tests are
written to match the code's behavior — not to validate the requirements. This is structurally
identical to asking a developer to write their own code review: they know what the code does and
unconsciously explain away anything that looks wrong.

**Why this is worse with AI than human developers:** An AI agent has no friction against writing a
test that confirms the code it just wrote — in fact, it's the path of least resistance because both
the code and the test share the same context window and therefore the same understanding of the problem.

**Observed failure mode:** Agent writes `formatCurrency()`, then writes tests for the specific
rounding behavior it chose rather than testing the rounding behavior the spec required.

### Cleanroom Software Engineering (Harlan Mills, IBM, 1980s)

Cleanroom separates development from verification as a first-class architectural principle:
1. Developers write code to a formal specification
2. A separate team (with no knowledge of the implementation) generates test cases from the same spec
3. Testing is statistical — designed to estimate operational reliability, not just catch bugs

**CR-AW's adaptation:** Replace the separate human test team with a separate AI agent (Red Team)
initialized with the spec but not the code. The "Test Oracle" role (an independent mechanism that
determines correctness) is played by the Red Team agent.

---

## 4. CR-AW Spec Analysis

### Phase 1: Research (sound)
Orchestrator does read-only exploration → writes SPEC.md → human approves. Maps directly to
existing 020-research / 025-spec pattern.

**Gap:** SPEC.md format is undefined. Without a template, Red Team test coverage varies wildly.

### Phase 2: Parallel Specification (structural issue)
Red Team reads SPEC.md only → generates tests. Correct.
Green Team reads SPEC.md only → generates PLAN.md. **This is wrong.**

PLAN.md is an architectural document. If the implementer writes the plan, they optimize for what
they already know how to build, not what the spec requires. Osmani's Orchestrator explicitly owns
architecture. **Correction:** Orchestrator writes PLAN.md. Green Team only receives and executes it.

### Phase 3: Execution Loop (two issues)

**Issue 1 — Stack trace leakage:**
`test_report.md (Pass/Fail + Stack Traces)` — stack traces reveal expected values:
```
AssertionError: expected formatCurrency(0.001) to return "$0.00"
    at tests/currency.spec.ts:142
```
Green Team now knows the exact assertion, partially defeating the Chinese Wall.
**Fix:** Orchestrator sanitizes the report. Green Team sees test name + error category only.

**Issue 2 — 100% exit criterion creates deadlock:**
If Red Team misread the spec, 100% is unreachable without a spec change, which triggers full reset.
**Fix:** P0/P1/P2 priority classification with thresholds: P0=100%, P1=90%+, P2=70%+.

### Spec Change Policy (too coarse)
"Any spec change requires full reset" is operationally brutal. Minor clarifications shouldn't blow
up everything. **Fix:** Classify changes — clarifications (no reset), additive (partial), breaking (full reset).

---

## 5. Technical Constraints

### Chinese Wall Enforcement
Claude Code subagents have no enforced filesystem sandboxing. "Never reads src/" is an honor system
unless structural isolation is used.

**Options:**
- **Honor system** — system-prompt instruction only. No enforcement. Unreliable.
- **Worktree isolation + pre-deletion** — launch agent with `isolation: worktree`, then delete
  restricted directories from the worktree before the agent starts. Agent literally cannot read
  what isn't there. Requires one Bash setup command per agent launch.
- **Separate repository clones** — strongest isolation; highest complexity.

**Recommendation: worktree isolation + pre-deletion.** Structural enforcement at low cost.

### Swift/XCTest Architecture
This project uses Swift + XCTest + Xcode project structure. Key constraint:

XCTest files must be registered in an Xcode test target to be compiled and run by `xcodebuild`.
The `.verifier/` hidden directory approach from the CR-AW spec does not work — files outside
registered targets cannot be run.

**Solution:** Add a dedicated Xcode test target `GeminiDesktopCRAWTests`. Red Team writes test
files to this target's directory. Orchestrator runs only that target via `-only-testing:`.
Green Team is instructed (and worktree-isolated) to never read `GeminiDesktopCRAWTests/`.

---

## 6. Gap Analysis

| Gap | Source | Priority |
|-----|---------|----------|
| No artifact naming convention | All | High |
| No task ID tracking | self-improving-agents | High |
| No explicit three-tier boundaries in CLAUDE.md | good-spec | High |
| No slash commands scaffolding the workflow | good-spec | High |
| No independent verification stage | self-improving-agents + CR-AW | High |
| No SPEC.md template | CR-AW | High |
| PLAN.md owned by wrong team in CR-AW spec | CR-AW analysis | High |
| Stack traces leak test logic | CR-AW analysis | Medium |
| 100% exit criterion too rigid | CR-AW analysis | Medium |
| No acceptance criteria field in plan template | bias-towards-action | Medium |
| No gotcha/learnings section in CLAUDE.md | self-improving-agents | Medium |

---

## 7. Artifact Stage Design

### Naming Convention
```
[task_id]-[blob]-[stage_seq]-[stage_name].md
```

| Field | Format | Example |
|-------|--------|---------|
| task_id | 6-digit zero-padded | 000001 |
| blob | type_description_underscored | feat_add_backup, bug_backup_crash |
| stage_seq | 3-digit zero-padded, step of 20 | 020, 040, 060 |
| stage_name | stage identifier | research, plan, verification |

**Blob type prefixes:** `feat_`, `bug_`, `refactor_`, `chore_`, `perf_`

**Directories:** Active → `docs/artifacts/` | Complete → `docs/artifacts/archive/`

### Stage Sequence (Standard Workflow)
- `020` — research
- `040` — plan
- `060` — verification

### Stage Sequence (CR-AW Extension, feat_ and non-trivial bug_ tasks)
- `020` — research
- `025` — spec (SPEC.md, human-approved Chinese Wall gate)
- `030` — verification-suite (Red Team test files)
- `040` — plan (Orchestrator writes, not Green Team)
- `050` — test-report-N (sanitized, per iteration)
- `060` — verification (final audit)

Step-of-20 leaves room for insertion without renaming existing files.

---

## 8. Command Design

### Standard Workflow Commands (5)
| Command | Purpose |
|---------|---------|
| `/research` | Deep-read, writes 020-research.md |
| `/plan` | Plan + todo list, writes 040-plan.md |
| `/implement` | Executes plan, marks tasks complete |
| `/verify` | Checks acceptance criteria, writes 060-verification.md |
| `/archive` | Moves artifacts to archive/, closes task in registry |

### CR-AW Commands (5 additional)
| Command | Purpose |
|---------|---------|
| `/craw-spec` | Orchestrator writes SPEC.md (025-spec.md) |
| `/craw-redteam` | Red Team generates verification suite (030-verification-suite) |
| `/craw-greenteam` | Green Team implements against SPEC + PLAN |
| `/craw-report` | Orchestrator runs tests, sanitizes, writes 050-test-report-N.md |
| `/craw-verify` | Final audit against all acceptance criteria, writes 060-verification.md |

All commands are project-scoped in `.claude/commands/`.

---

## 9. Open Questions for Plan Phase

1. **Chinese Wall enforcement:** Worktree + pre-deletion, or honor system? (Recommendation: worktree)
2. **SPEC.md format:** Acceptance criteria list (recommended), BDD, or API contract?
3. **CR-AW scope:** Which task types trigger the CR-AW loop? (Recommendation: feat_ always, bug_ if non-trivial)
4. **Report sanitization depth:** Test names visible but expected values hidden? (Recommendation: yes)
5. **Spec change classification:** What triggers full reset vs. partial update?
6. **Command scope:** Project-only or some commands global?
7. **Task ID assignment:** Auto-increment from registry, or user-assigned?
