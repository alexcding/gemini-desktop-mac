# Plan: Workflow System — CLAUDE.md + Commands + Skills + CR-AW

**Task:** 000001-chore_workflow_setup
**Stage:** 040-plan
**Based on:** 000001-chore_workflow_setup-020-scout.md, user CR-AW spec v1
**Status:** AWAITING APPROVAL — do not implement until annotated and approved

---

## Design Principle

**CLAUDE.md and all base commands are language, platform, and knowledge-work agnostic.**
They describe *what* happens at each stage, not *how* to execute it in any specific stack.

**Skills** live in `.claude/commands/skills/` and provide platform/language/domain-specific
implementations of the generic workflow. A skill defines the build command, test framework,
type system rules, architectural boundaries, and known gotchas for a specific context.

```
CLAUDE.md                          — universal: workflow, CR-AW, boundaries, artifact naming
.claude/commands/
  scout.md                      — universal: what research produces
  design.md                          — universal: what a plan must contain
  forge.md                     — universal: rules of execution
  audit.md                        — universal: what verification checks
  seal.md                       — universal: lifecycle close
  charter.md                     — universal: CR-AW spec gate
  challenge.md                  — universal: CR-AW test generation
  blueprint.md                     — universal: CR-AW architecture planning
  craft.md                — universal: CR-AW implementation
  score.md                   — universal: CR-AW sanitized reporting
  certify.md                   — universal: CR-AW final audit
  skills/
    swift-xcode.md                 — build cmd, test framework, type rules, Swift gotchas
    swiftui-appkit.md              — AppKit boundaries, window lifecycle, WKWebView constraints
    typescript-node.md             — tsc, jest, ESLint, type rules
    react-components.md            — component isolation, visual regression, a11y
    knowledge-work.md              — writing, research synthesis, documentation tasks
```

---

## Acceptance Criteria

- [ ] CLAUDE.md is fully platform-agnostic (no xcodebuild, XCTest, Swift types, or project-specific rules)
- [ ] CLAUDE.md contains Workflow, CR-AW, Boundaries, Known Gotchas, Skills, and SPEC.md Template sections
- [ ] Eleven base commands in `.claude/commands/` are fully generic
- [ ] Two skills created: `swift-xcode.md` and `swiftui-appkit.md` (this project's stack)
- [ ] Skills contain all Swift/Xcode/AppKit specifics removed from base commands and CLAUDE.md
- [ ] Task registry exists at `docs/artifacts/TASK_REGISTRY.md`
- [ ] CR-AW agent roles, boundaries, and worktree enforcement mechanism documented generically
- [ ] `GeminiDesktopCRAWTests` Xcode target created by human via Xcode UI (not by agent)

---

## Decisions Requiring Annotation

### D1: Chinese Wall Enforcement

**Execution model:** The Orchestrator is a human typing slash commands into Claude Code.
Commands are prompt templates — Claude executes tools (Bash, Agent) in response. Claude can
run bash and launch subagents as part of command execution. Worktree setup happens inside
Claude's tool-call sequence.

**Option A — Honor system (system-prompt only)**
No infrastructure. Unreliable — agents can violate the boundary during error recovery.

**Option B — Worktree isolation + pre-deletion (recommended)**
Claude runs `git worktree add` + `rm -rf [restricted-dirs]` before launching each subagent.
Agent literally cannot read what isn't there. Cleanup via `git worktree remove` after.
Restricted dirs are defined by the active skill (e.g., swift-xcode skill defines which
directories constitute "source" vs "tests").

**Option C — Separate repository clones**
Strongest isolation; highest orchestration complexity.

**[NOTE: YOUR DECISION HERE]**

---

### D2: SPEC.md Format

**Option A — Acceptance Criteria list (recommended)**
```
AC-001 [P0] [Criterion described as observable behavior]
AC-002 [P1] [Edge case or boundary condition]
```
Concise, traceable, maps naturally to P0/P1/P2. Language-agnostic.

**Option B — BDD (Given/When/Then)**
More verbose. Better for complex UI or user-journey flows.

**Option C — API contract**
Best for pure functions/data layer.

**Recommendation:** Option A primary. Option C for pure functions. Option B optional for complex flows.

**[NOTE: YOUR DECISION HERE]**

---

### D3: Failure Classification

| Priority | Definition | Exit Threshold |
|----------|-----------|---------------|
| P0 | Core acceptance criteria — the feature is broken without these | 100% required |
| P1 | Edge cases, boundary conditions, error handling | 90%+ required |
| P2 | Robustness, stress, unusual inputs | 70%+ required; failures become follow-up tasks |

Any P0 failure blocks completion.

**[NOTE: YOUR DECISION HERE]**

---

### D4: Report Sanitization Level

**Option C — Test names visible, assertion details hidden (recommended)**
Implementer sees: test name + PASS/FAIL + error category.
Implementer never sees: expected values, actual values, test file paths, line numbers.
Test names describe requirements without revealing implementation details.

**[NOTE: YOUR DECISION HERE]**

---

### D5: CR-AW Task Scope

| Task Type | CR-AW? | Rationale |
|-----------|--------|-----------|
| `feat_` | Always | New observable behavior, high confirmation bias risk |
| `bug_` | If fix adds new logic | Trivial fixes use standard workflow |
| `refactor_` | Never | No new behavior; existing tests cover correctness |
| `perf_` | Never | Optimization doesn't change observable behavior |
| `chore_` | Never | No testable behavior |

**[NOTE: YOUR DECISION HERE]**

---

### D6: Task ID Assignment

**Option B — Auto-increment from registry (recommended)**
Claude reads `TASK_REGISTRY.md`, finds highest ID, increments. User just provides the blob.

**[NOTE: YOUR DECISION HERE]**

---

## Part 1: CLAUDE.md Changes

All new sections are platform-agnostic. Project/stack specifics belong in skills.

---

### Section: Workflow

```markdown
## Workflow

All non-trivial tasks follow a staged cycle. Feature tasks use the CR-AW extension (see below).
Platform-specific execution details (build commands, test frameworks, type rules) are defined
in the active skill for this project — see Skills section.

### Standard Stages

| Stage | Seq | Artifact |
|-------|-----|----------|
| Research | 020 | `[task_id]-[blob]-020-scout.md` |
| Plan + Annotate | 040 | `[task_id]-[blob]-040-plan.md` |
| Verification | 060 | `[task_id]-[blob]-060-verification.md` |

### CR-AW Extension (feat_ tasks, non-trivial bug_ tasks)

| Stage | Seq | Artifact | Owner |
|-------|-----|----------|-------|
| Research | 020 | `...-020-scout.md` | Orchestrator |
| Spec | 025 | `...-025-spec.md` | Orchestrator |
| Verification Suite | 030 | `...-030-verification-suite[.ext]` | Red Team |
| Plan | 040 | `...-040-plan.md` | Orchestrator |
| Test Report (per iter) | 050 | `...-050-test-report-N.md` | Orchestrator (sanitized) |
| Verification | 060 | `...-060-verification.md` | Orchestrator |

030 and 040 run in parallel after 025 is approved. Human reviews both together before 060.

### Artifact Naming

`[task_id]-[blob]-[stage_seq]-[stage_name][.ext]`

- task_id: 6-digit zero-padded (000001)
- blob: type-prefixed, underscored (feat_add_backup, bug_crash_on_launch)
- stage_seq: 3-digit, step of 20 (020, 040, 060)
- ext: .md for documents; skill-appropriate extension for test suites (.swift, .spec.ts, etc.)
- Type prefixes: feat_ / bug_ / refactor_ / chore_ / perf_

Active: `docs/artifacts/` | Complete: `docs/artifacts/archive/`
Task registry: `docs/artifacts/TASK_REGISTRY.md`

### Rules
- Never write code without a reviewed, approved plan
- Research always produces a file — never a chat summary
- Annotations use `**[NOTE: ...]**` inline in the plan doc; say "address notes" to update
- "Don't implement yet" is enforced until explicit user approval
- After each logical unit of implementation, run the build verification command (see active skill)
- Mistakes become durable knowledge — add new entries to Known Gotchas after a bug
```

---

### Section: Clean Room Agentic Workflow (CR-AW)

```markdown
## Clean Room Agentic Workflow (CR-AW)

Applies to: feat_ tasks always. Non-trivial bug_ tasks (fix adds new logic).

Prevents confirmation bias: an agent that writes both code and tests will fit tests to code,
not code to spec. CR-AW separates the verifier from the implementer structurally.

### Three Roles

| Role | Reads | Writes | Never |
|------|-------|--------|-------|
| Orchestrator | Everything | SPEC.md, PLAN.md, sanitized reports | Implementation code |
| Red Team | SPEC.md only | Verification suite | Source directories (defined by active skill) |
| Green Team | SPEC.md + PLAN.md + sanitized reports | Implementation | Test directories (defined by active skill) |

### Chinese Wall Enforcement

[Decision D1 outcome — describe the chosen mechanism here after annotation]

The specific directories that constitute "source" and "tests" are defined by the active skill.

### Failure Thresholds

| Priority | Definition | Required |
|----------|-----------|---------|
| P0 | Core acceptance criteria | 100% pass |
| P1 | Edge cases, error handling | 90%+ pass |
| P2 | Robustness, stress | 70%+ pass |

P0 failure blocks completion. P1/P2 failures below threshold become follow-up tasks.

### Report Sanitization

Orchestrator sanitizes test output before Green Team sees it.
Green Team receives: test name, PASS/FAIL, error category.
Green Team never sees: expected values, actual values, test file paths, line numbers.

### Spec Change Classification

| Change Type | Reset Required |
|-------------|---------------|
| Clarification (no semantic change) | None |
| Additive (new requirement) | Red Team adds tests for new ACs only |
| Breaking (existing requirement changed) | Full reset of both teams |

### Commands

Standard: /scout, /design, /forge, /audit, /seal
CR-AW: /charter, /challenge, /blueprint, /craft, /score, /certify
```

---

### Section: Skills

```markdown
## Skills

Skills provide platform, language, and domain-specific implementations of the generic workflow.
They define the concrete details that base commands leave abstract.

**Location:** `.claude/commands/skills/[name].md`

**A skill defines:**
- Build verification command (what "build and check" means for this stack)
- Test framework and how to run it
- Test file conventions (naming, location, structure)
- Type system rules (what constitutes a type violation for this language)
- Architectural boundaries specific to this stack
- Known gotchas for this platform/framework
- CR-AW directory mapping (which dirs are "source" vs "tests" for worktree isolation)

**Active skills for this project:**
- `swift-xcode` — Xcode build system, XCTest, Swift type rules
- `swiftui-appkit` — AppKit/SwiftUI bridging, window lifecycle, WebKit constraints

**Before starting any task:** confirm which skills apply and load them alongside the base command.
If no skill applies (e.g., pure documentation or research work), proceed with base commands only.

**Adding a new skill:** create `.claude/commands/skills/[name].md` following the structure
defined in an existing skill. Skills are composable — a task may use multiple skills.
```

---

### Section: Boundaries

```markdown
## Boundaries

**Always (safe autonomous actions — no confirmation needed):**
- Reading any file in the repository
- Running build or diagnostic commands (read-only)
- Writing research, plan, spec, and verification artifacts to docs/artifacts/
- Editing files explicitly named in an approved plan
- Running git status, git diff, git log

**Ask First (requires explicit approval before proceeding):**
- Creating new files outside docs/
- Modifying CLAUDE.md or project configuration files
- Deleting any file
- Changing public interfaces that other modules depend on
- Adding new external dependencies
- Touching high-risk subsystems (defined per project in the active skill)

**Never (hard stops):**
- Committing to main directly
- Amending published commits
- Force-pushing
- Skipping pre-commit hooks
- Red Team reading source directories
- Green Team reading test directories
```

---

### Section: Known Gotchas

```markdown
## Known Gotchas

Durable learnings that survive context resets. Universal entries belong here.
Platform/project-specific entries belong in the appropriate skill file.

**Confirmation bias: agents that write both code and tests will fit tests to code.**
The CR-AW workflow exists to prevent this. Never ask a single agent to write implementation
and verification in the same context without a spec-approved separation point.

**Research that stays in chat is lost.**
Any findings not written to a docs/artifacts/ file will not survive context compaction.
Research always produces a 020-scout.md artifact.

**Annotation cycles prevent wrong implementations.**
A plan reviewed by the human before implementation catches wrong assumptions cheaply.
The same wrong assumption caught during implementation requires unwinding multiple changes.
```

---

### Section: SPEC.md Template

```markdown
## SPEC.md Template (CR-AW tasks)

A valid SPEC.md contains:

**Header**
- Task ID, blob, feature name, one-sentence description
- Explicit out-of-scope list

**Acceptance Criteria**
AC-[ID] [P0/P1/P2] [Observable behavior — what a user or test can verify without reading source]

Example:
AC-001 [P0] The feature must complete its primary action within 3 seconds under normal load
AC-002 [P0] Error states must be communicated to the user with a specific, actionable message
AC-003 [P1] The feature must handle empty input without crashing
AC-004 [P2] The feature must remain functional after 100 consecutive operations

**Implementation Boundaries**
What the implementation must not do (dependencies, interface changes, scope limits).

**Test Expectations (for Red Team)**
- Test framework: [defined by active skill]
- Priority coverage: each P0 criterion must have ≥ 2 test cases
- Scope: test observable behavior only — do not couple tests to internal implementation details
```

---

## Part 2: Eleven Base Commands (Generic)

---

### `.claude/commands/scout.md`
```markdown
# /scout

Deep-read phase. Usage: /scout [blob] [scope description]
Claude auto-assigns task_id from TASK_REGISTRY.md.

Steps:
1. Read TASK_REGISTRY.md, assign next task_id, add entry with status PLANNED.
2. Load the active skill(s) for this task's technology stack.
3. Read the named scope in depth — structure, data flow, lifecycle, state, constraints,
   edge cases, and non-obvious dependencies.
4. Write findings to: docs/artifacts/[task_id]-[blob]-020-scout.md
5. Update TASK_REGISTRY.md status to IN PROGRESS.

Research artifact must include:
- What exists (files, types/classes, key functions/methods)
- How it works (data flow, lifecycle, state management)
- Constraints (concurrency, memory, external dependencies, platform limits)
- Gotchas (non-obvious behaviors, fragile contracts, known failure modes)
- Gap analysis (what's missing for the proposed task)
- Open questions for the plan phase

Do not propose solutions. Do not write code. Research only.
Stop at sufficient understanding — not at exhaustive documentation.
```

---

### `.claude/commands/design.md`
```markdown
# /design

Planning phase. Usage: /design [task_id] [blob] [goal description]
Precondition: [task_id]-[blob]-020-scout.md must exist and have been reviewed by user.

Steps:
1. Load the active skill(s) for this task's technology stack.
2. Read the research artifact.
3. Read all source files relevant to the planned changes.
4. Write a detailed plan to: docs/artifacts/[task_id]-[blob]-040-plan.md

Plan must include:
- Acceptance criteria (all defined before any implementation details)
- Files to be modified (with relevant context)
- New files to be created (with rationale)
- New types, interfaces, or abstractions being introduced
- New configuration or settings entries being added
- External dependency changes
- Any integration points with fragile external systems (note fragility explicitly)
- Code snippets for key changes (not full implementation)
- Trade-offs considered and rejected
- Todo list with phases and individual tasks

Annotation instructions:
Add **[NOTE: ...]** inline to correct assumptions, add constraints, or redirect sections.
Then say "address notes" to trigger a plan update. Repeat until plan is correct.

End with: "AWAITING APPROVAL — do not implement until annotated and approved"
Do not implement. Do not modify source files.
```

---

### `.claude/commands/forge.md`
```markdown
# /forge

Implementation phase. Usage: /forge [task_id] [blob]
Precondition: [task_id]-[blob]-040-plan.md must be annotated and explicitly approved.

Steps:
1. Load the active skill(s) for this task's technology stack.
2. Read the plan artifact in full.
3. Implement all phases and tasks in the todo list.
4. After each task or phase, mark it completed in the plan document.
5. Do not stop until all tasks and phases are marked complete.

Universal implementation rules:
- No unnecessary comments or docstrings
- No unsafe patterns unless already present in surrounding code
- No new external dependencies not listed in the plan
- Do not change public interfaces unless plan explicitly specifies
- After each logical unit: run the build verification command defined in the active skill.
  Fix any errors before continuing to the next unit.

Skill-specific rules (type system violations, architectural boundaries, etc.) are defined
in the active skill — load and apply them.
```

---

### `.claude/commands/audit.md`
```markdown
# /audit

Verification phase. Usage: /audit [task_id] [blob]
Precondition: Implementation complete.

Steps:
1. Load the active skill(s) for this task's technology stack.
2. Read the plan artifact — acceptance criteria section.
3. Read all files modified during implementation.
4. Run the build verification command defined in the active skill.
5. For each acceptance criterion: met / not met / partial.
6. Run skill-specific quality checks (type violations, boundary violations, etc.).
7. Write findings to: docs/artifacts/[task_id]-[blob]-060-verification.md

Verification report must include:
- Acceptance criteria: status per item (met / not met / partial)
- Build status: pass / fail
- Skill quality checks: pass/fail per category
- Issues found: description + file:line
- Follow-up tasks recommended (if any)

Verdict: PASS / PASS_WITH_NOTES / FAIL
FAIL blocks archive. PASS_WITH_NOTES must list follow-up task_ids.
```

---

### `.claude/commands/seal.md`
```markdown
# /seal

Archive completed task. Usage: /seal [task_id] [blob]
Precondition: /audit returned PASS or PASS_WITH_NOTES.

Steps:
1. Find all files in docs/artifacts/ matching [task_id]-[blob]-*.
2. Move them to docs/artifacts/archive/.
3. Update TASK_REGISTRY.md: status = COMPLETE, add completion date.
4. Confirm which files were moved.

Do not archive if /audit returned FAIL.
```

---

### `.claude/commands/charter.md`
```markdown
# /charter

Generate SPEC.md for a CR-AW task. Usage: /charter [task_id] [blob] [feature description]
Precondition: [task_id]-[blob]-020-scout.md exists and was reviewed.

Steps:
1. Load the active skill(s) for this task's technology stack.
2. Read the research artifact.
3. Read source files relevant to the feature.
4. Draft SPEC.md at: docs/artifacts/[task_id]-[blob]-025-spec.md

Using the SPEC.md Template from CLAUDE.md:
- Write explicit out-of-scope section
- Write acceptance criteria with [ID] and [P0/P1/P2] tags
- Write implementation boundaries
- Write test expectations section for Red Team (reference active skill for test framework)

Do not write code, tests, or a plan.
End with: "AWAITING HUMAN APPROVAL — this is the Chinese Wall gate. Do not launch Red Team
or Green Team until this spec is explicitly approved by the human."
```

---

### `.claude/commands/challenge.md`
```markdown
# /challenge

Launch Red Team to generate verification suite. Usage: /challenge [task_id] [blob]
Precondition: [task_id]-[blob]-025-spec.md is human-approved.

## Orchestrator steps

Load the active skill to determine:
- [src-dirs]: directories constituting implementation source (Red Team must not see these)
- [test-dir]: directory where Red Team writes the verification suite
- [test-ext]: file extension for test files (.swift, .spec.ts, etc.)

1. Set up an isolated worktree:
   ```bash
   git worktree add /tmp/craw-red-[task_id] HEAD
   rm -rf /tmp/craw-red-[task_id]/[src-dir-1]
   rm -rf /tmp/craw-red-[task_id]/[src-dir-2]   # repeat per skill definition
   cp docs/artifacts/[task_id]-[blob]-025-spec.md /tmp/craw-red-[task_id]/docs/artifacts/
   ```
2. Launch subagent (Agent tool) with working directory /tmp/craw-red-[task_id].

## Red Team agent instructions

Your working directory contains: the spec artifact and the test directory.
Source directories have been removed. You cannot read implementation code.

1. Read docs/artifacts/[task_id]-[blob]-025-spec.md — your ONLY source.
2. Generate a comprehensive verification suite covering all acceptance criteria.
3. Write to: [test-dir]/[task_id]-[blob]-VerificationSuite[test-ext]

Test rules:
- Label each test // P0, // P1, or // P2 matching the AC priority
- Each P0 criterion must have ≥ 2 test cases
- Test names describe the requirement, not assumed implementation
- Test observable behavior only — do not couple to internal implementation details
- Single assertion focus per test

## Orchestrator cleanup

```bash
cp /tmp/craw-red-[task_id]/[test-dir]/[task_id]-[blob]-VerificationSuite[test-ext] [test-dir]/
cp /tmp/craw-red-[task_id]/[test-dir]/[task_id]-[blob]-VerificationSuite[test-ext] \
   docs/artifacts/[task_id]-[blob]-030-verification-suite[test-ext]
git worktree remove /tmp/craw-red-[task_id] --force
```
```

---

### `.claude/commands/blueprint.md`
```markdown
# /blueprint

Orchestrator writes the CR-AW implementation plan. Usage: /blueprint [task_id] [blob] [goal]
Preconditions:
- [task_id]-[blob]-025-spec.md is human-approved
- [task_id]-[blob]-030-verification-suite[.ext] exists (Red Team complete)
- Human has reviewed both artifacts together before approving this step

Steps:
1. Load the active skill(s).
2. Read docs/artifacts/[task_id]-[blob]-025-spec.md
3. Read docs/artifacts/[task_id]-[blob]-030-verification-suite[.ext]
   Note each test: what behavior it asserts, what interfaces it expects to call.
4. Read all source files relevant to the planned changes.
5. Design an architecture that satisfies both the spec and the test contract.
   If the verification suite implies behavior that conflicts with the spec, flag it explicitly.
6. Write plan to: docs/artifacts/[task_id]-[blob]-040-plan.md

Plan must include (same as /design, plus):
- Interfaces the verification suite will call (traced from test file)
- Explicit note on any spec/test conflicts found
- Green Team will receive this plan and the spec — NOT the test source. Design so the
  correct implementation follows directly without requiring inference.

End with: "AWAITING APPROVAL — do not launch Green Team until this plan is approved."
```

---

### `.claude/commands/craft.md`
```markdown
# /craft

Launch Green Team to implement. Usage: /craft [task_id] [blob] [iteration]
Preconditions:
- [task_id]-[blob]-025-spec.md approved
- [task_id]-[blob]-040-plan.md approved
- If iteration > 1: [task_id]-[blob]-050-test-report-[N-1].md exists

## Orchestrator steps

Load the active skill to determine [test-dirs] (directories Green Team must not see).

1. Set up an isolated worktree:
   ```bash
   git worktree add /tmp/craw-green-[task_id] HEAD
   rm -rf /tmp/craw-green-[task_id]/[test-dir-1]   # repeat per skill definition
   cp docs/artifacts/[task_id]-[blob]-025-spec.md /tmp/craw-green-[task_id]/docs/artifacts/
   cp docs/artifacts/[task_id]-[blob]-040-plan.md /tmp/craw-green-[task_id]/docs/artifacts/
   # If iteration > 1:
   cp docs/artifacts/[task_id]-[blob]-050-test-report-[N-1].md /tmp/craw-green-[task_id]/docs/artifacts/
   ```
2. Launch subagent (Agent tool) with working directory /tmp/craw-green-[task_id].

## Green Team agent instructions

Your working directory contains the full source tree minus test directories.
You have SPEC.md, PLAN.md, and (if iteration > 1) the sanitized test report.

1. Read the spec and plan in full.
2. If iteration > 1, read the sanitized test report.
3. Implement to satisfy the spec and pass failing tests.
4. Reason from SPEC.md for correct behavior — do not infer test internals from test names.
5. If a failing test name implies behavior not in the spec, add:
   `// ORCHESTRATOR: [test_name] implies [X] — not in spec, flagging for review`
   then implement what the spec says.

Implementation rules:
- No unnecessary comments or docstrings
- No unsafe patterns unless already present in surrounding code
- No new dependencies not listed in the plan
- Do not change public interfaces unless plan specifies
- After EACH logical unit: run the build verification command from the active skill.
  Fix all errors before continuing.
- Mark each plan todo item complete as you finish it.

Apply all additional rules from the active skill.

## Orchestrator cleanup

```bash
git -C /tmp/craw-green-[task_id] diff --name-only HEAD   # review scope before copying
# Copy modified source files back to main repo
git worktree remove /tmp/craw-green-[task_id] --force
```
```

---

### `.claude/commands/score.md`
```markdown
# /score

Run tests and generate sanitized report. Usage: /score [task_id] [blob] [iteration]

Steps:
1. Load the active skill to get the test run command for the verification suite.
2. Run: [skill test command] targeting [task_id]-[blob]-VerificationSuite only
3. Parse raw output.
4. Write sanitized report to: docs/artifacts/[task_id]-[blob]-050-test-report-[iteration].md

Sanitized report format:
---
## Test Report — Iteration [N] — [date]
Build: PASS / FAIL (include build errors verbatim — not test logic)
P0: X/Y passed | P1: X/Y passed | P2: X/Y passed
Status: BLOCKED / NEEDS_WORK / PASS_WITH_NOTES / PASS

### Failed Tests
| Test Name | Priority | Error Category |
|-----------|----------|----------------|
| test_featureDoesX | P0 | assertion_failure |

### Passed Tests
[list]
---

Sanitization rules (strict):
- NEVER include expected values or actual values from assertions
- NEVER include test file paths or line numbers
- DO include test names (they describe requirements, not implementation)
- DO include error categories: assertion_failure / null_crash / type_error / timeout / compile_error
- DO include build errors verbatim (build errors are not test logic leakage)
```

---

### `.claude/commands/certify.md`
```markdown
# /certify

Final verification audit. Usage: /certify [task_id] [blob]
Precondition: Latest test report shows P0: 100%, P1: 90%+, P2: 70%+.

Steps:
1. Load the active skill(s).
2. Read SPEC.md, PLAN.md, all implementation files touched, and latest test report.
3. For each P0 acceptance criterion: confirm met, cite file:line.
4. For each P1/P2 failure below threshold: add follow-up task to TASK_REGISTRY.md.
5. Run skill-specific quality checks.
6. Write to: docs/artifacts/[task_id]-[blob]-060-verification.md

Verdict: PASS / PASS_WITH_NOTES / FAIL
PASS_WITH_NOTES must list follow-up task IDs.
```

---

## Part 3: Skills — This Project's Stack

Two skills for this project. Both live in `.claude/commands/skills/`.

---

### `.claude/commands/skills/swift-xcode.md`

```markdown
# Skill: swift-xcode

Applies to: any task touching Swift source, Xcode project, or XCTest.

## Build Verification Command
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build
Run after each logical unit of implementation. Fix all errors and warnings before continuing.

## Test Run Command (standard)
xcodebuild test -scheme GeminiDesktop -destination 'platform=macOS'

## Test Run Command (CR-AW — targeted)
xcodebuild test -scheme GeminiDesktop -destination 'platform=macOS' \
  -only-testing:GeminiDesktopCRAWTests/[task_id]-[blob]-VerificationSuite

## CR-AW Directory Mapping
- Source dirs (Red Team must not see): GeminiDesktop/, GeminiDesktopTests/
- Test dir (Green Team must not see): GeminiDesktopCRAWTests/
- Test file extension: .swift
- Test target: GeminiDesktopCRAWTests

## CR-AW Test Target Setup (one-time, human manual)
⚠️ Do not delegate to Claude — project.pbxproj modification by LLM corrupts the project.
1. Open GeminiDesktop.xcodeproj in Xcode
2. File → New → Target → Unit Testing Bundle → Name: GeminiDesktopCRAWTests
3. Set "Target to be Tested" to GeminiDesktop
4. Match deployment target to main target (macOS 14.0+)
5. Delete auto-generated placeholder test file
6. Commit: git add GeminiDesktop.xcodeproj && git commit -m "chore: add GeminiDesktopCRAWTests target"
7. Verify: xcodebuild test -only-testing:GeminiDesktopCRAWTests → expect "0 tests", exit 0

## Type System Rules
- No force unwraps (!) unless already present in surrounding code
- No Any or AnyObject types
- No speculative @MainActor annotations — only where the compiler requires them
- No new external SPM dependencies unless listed in the plan

## Research Depth Signals (add to /scout prompts for Swift tasks)
Include: @MainActor and actor isolation boundaries, memory ownership (strong/weak/unowned),
AppKit/SwiftUI bridging points, concurrency assumptions (async/await vs DispatchQueue).

## Plan Requirements (add to /design for Swift tasks)
Include: Swift types/protocols/actors being introduced, UserDefaults keys (must go in
UserDefaultsKeys.swift), entitlement changes, any JavaScript changes (note selector fragility).

## Verification Quality Checks
- New force unwraps introduced?
- New Any types?
- Build passes with zero new warnings?
- New @AppStorage keys missing from UserDefaultsKeys.swift?

## Known Gotchas

**Force unwrapping optionals from IBOutlets or legacy AppKit patterns is common in this codebase.**
Match the existing pattern rather than introducing new safe-unwrap styles inconsistently.

**Swift 6 strict concurrency is not yet enabled on this project.**
Do not add @MainActor speculatively. The migration is a planned future workstream.

**UserDefaults keys must be registered in UserDefaultsKeys.swift.**
Never use raw string literals as UserDefaults keys — always add to the enum first.
```

---

### `.claude/commands/skills/swiftui-appkit.md`

```markdown
# Skill: swiftui-appkit

Applies to: any task touching NSWindow, NSPanel, WKWebView, AppCoordinator, WebViewModel,
ChatBarPanel, or any AppKit/SwiftUI bridging layer.

Stack on top of swift-xcode skill — both apply together for UI tasks.

## Architectural Boundaries (Ask First before crossing)
- Changing public interfaces of AppCoordinator or WebViewModel
- Adding any new NSWindow or NSPanel subclass
- Touching ChatBarPanel (complex polling state, high regression risk)
- Any direct NSApp.windows access — use AppCoordinator.findMainWindow() instead
- Any window lifecycle changes (orderFront, makeKeyAndOrderFront, orderOut)

## CR-AW Behavioral Test Constraint
Tests must verify observable behavior, not internal AppKit state.
Do not assert on NSWindow properties directly — assert on what the user sees or can interact with.

## Known Gotchas

**window.backgroundColor fills the entire content area, not just the toolbar.**
Do not set window.backgroundColor to the toolbar color. SwiftUI's .toolbarBackground() modifier
handles toolbar color. Setting backgroundColor causes a solid-color screen on launch because
the WebView renders beneath the window background. The WebView attaches lazily on the first
key-window event — the solid color is visible during that gap.
Discovered: 2026-03-17 (task 000000)

**WKWebView can only exist in one view hierarchy at a time.**
Moving it between windows requires removing it from the current superview first.
AppCoordinator manages this exclusively — never add webViewModel.wkWebView as a subview
from outside the coordinator.

**WebView attachment fires only on didBecomeKey, not on window show.**
WebViewContainer.attachWebView() is called from viewDidMoveToWindow() only when the window
is already key, and from the didBecomeKeyNotification observer. A window shown via orderFront
without becoming key will not attach the WebView until it receives focus.

**JavaScript injection for Gemini requires dispatching synthetic input events.**
Setting element.innerText or element.textContent directly does not trigger React's event system.
The input event must be dispatched after setting content, or Gemini ignores the text.

**ChatBarPanel polling is fragile.**
Auto-expansion detection polls via JavaScript on a timer. Gemini DOM selectors can change
with any Gemini update. Treat any JS selector in UserScripts.swift as a fragile contract.

**WKWebViewConfiguration cannot be modified after the WKWebView is created.**
All configuration (user scripts, message handlers, data stores) must be set before init.
```

---

## Part 4: Task Registry

**File:** `docs/artifacts/TASK_REGISTRY.md`

```markdown
# Task Registry

| task_id | blob | description | status | created | completed |
|---------|------|-------------|--------|---------|-----------|
| 000001 | chore_workflow_setup | Workflow system: CLAUDE.md + commands + skills + CR-AW | IN PROGRESS | 2026-03-17 | — |

**Status values:** PLANNED / IN PROGRESS / COMPLETE / ABANDONED
```

---

## Todo List

- [ ] **D1–D6:** All decisions annotated and resolved
- [ ] **Phase 1 — CLAUDE.md:** Add Workflow, CR-AW, Skills, Boundaries, Known Gotchas, SPEC.md Template (all generic)
- [ ] **Phase 2 — Base commands (11):** Create `.claude/commands/` with all generic commands
- [ ] **Phase 3 — Skills:** Create `.claude/commands/skills/swift-xcode.md` and `swiftui-appkit.md`
- [ ] **Phase 4 — Task registry:** Create `docs/artifacts/TASK_REGISTRY.md`
- [ ] **Phase 5 — Xcode target (HUMAN MANUAL):** Create `GeminiDesktopCRAWTests` via Xcode UI per swift-xcode skill instructions
- [ ] **Phase 6 — Verify:** Run `/audit 000001 chore_workflow_setup`
- [ ] **Phase 7 — Archive:** Run `/seal 000001 chore_workflow_setup`

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Generic commands too abstract to be actionable | Medium | High | Skills provide concrete details; commands reference skill explicitly |
| Skill not loaded before command invocation | Medium | Medium | CLAUDE.md Skills section instructs Claude to check active skills before any command |
| Red Team writes untestable acceptance criteria | Medium | High | SPEC.md template enforces observable-behavior-only test expectations |
| Worktree pre-deletion corrupts git state | Low | High | Test worktree setup in isolation before first CR-AW task |
| Skill files diverge from actual project state | Low | Medium | Treat skill gotchas like CLAUDE.md — update after each bug discovery |

AWAITING APPROVAL — do not implement until all decisions (D1–D6) are annotated and approved.
