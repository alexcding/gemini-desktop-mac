# Research: Boris Tane — Claude Code Workflow

**Source:** https://boristane.com/blog/how-i-use-claude-code/
**Published:** February 10, 2026
**Author:** Boris Tane, Engineering Lead at Cloudflare

---

## Core Principle

> Never let Claude write code until you've reviewed and approved a written plan.

This single principle separates Tane's workflow from standard AI-assisted coding. The separation of planning and execution is described as the single most important practice — it prevents wasted effort, keeps the developer in control of architecture decisions, and produces better results with lower token usage than jumping straight to code.

---

## Phase 1: Research

### How It Works

Every meaningful task begins with a **deep-read directive**. Claude is asked to thoroughly understand the relevant part of the codebase before doing anything else. Critically, findings must be written into a persistent markdown file — never just summarized verbally in chat.

### Example Prompts

```
read this folder in depth, understand how it works deeply, what it does and all
its specificities. when that's done, write a detailed report of your learnings
and findings in research.md
```

```
study the notification system in great details, understand the intricacies of it
and write a detailed research.md document with everything there is to know about
how notifications work
```

```
go through the task scheduling flow, understand it deeply and look for potential bugs.
there definitely are bugs in the system as it sometimes runs tasks that should have
been cancelled. keep researching the flow until you find all the bugs, don't stop
until all the bugs are found. when you're done, write a detailed report of your
findings in research.md
```

### Key Observation: Deliberate Language

Tane emphasizes specific language: **"deeply"**, **"in great details"**, **"intricacies"**, **"go through everything"**. These are not stylistic preferences — they are functional signals. Without explicit depth cues, Claude skims. It reads file signatures and moves on. The language instructs Claude that surface-level reading is unacceptable.

### Why the Written Artifact Matters

The `research.md` file serves two purposes:

1. **Review surface** — the developer can read it and verify Claude actually understood the system. If the research is wrong, the plan will be wrong, and the implementation will be wrong.
2. **Correction opportunity** — misunderstandings caught here are cheap. Misunderstandings caught during implementation are expensive.

### The Most Expensive Failure Mode

Tane identifies this as implementations that work in isolation but break the surrounding system:
- A function that ignores an existing caching layer
- A migration that doesn't account for the ORM's conventions
- An API endpoint that duplicates logic that already exists elsewhere

The research phase is the primary defense against this failure mode.

---

## Phase 2: Planning

### How It Works

After the developer reviews the research, Claude is asked to produce a **detailed implementation plan** in a separate markdown file (`plan.md`). The plan always includes:
- Detailed explanation of the approach
- Code snippets showing actual changes
- File paths that will be modified
- Considerations and trade-offs

### Example Prompts

```
I want to build a new feature <name and description> that extends the system to
perform <business outcome>. write a detailed plan.md document outlining how to
implement this. include code snippets
```

```
the list endpoint should support cursor-based pagination instead of offset.
write a detailed plan.md for how to achieve this. read source files before
suggesting changes, base the plan on the actual codebase
```

### Why Not Claude Code's Built-In Plan Mode

Tane explicitly rejects the built-in plan mode: *"The built-in plan mode sucks."* The markdown file gives full control — it can be edited in the developer's own editor, annotated inline, and persists as a real artifact in the project.

### Reference Implementations

A key technique: for well-contained features where a good implementation exists in open source, Tane pastes that code alongside the plan request. Example: "this is how they do sortable IDs, write a plan.md explaining how we can adopt a similar approach." Claude works dramatically better with a concrete reference implementation than when designing from scratch.

---

## Phase 2.5: The Annotation Cycle (Most Distinctive)

### How It Works

After Claude writes the plan, Tane opens it in his editor and **adds inline notes directly into the document**. These notes correct assumptions, reject approaches, add constraints, or provide domain knowledge that Claude doesn't have. Then Claude is asked to address the notes and update the document — without implementing.

### Example Annotations

- `"use drizzle:generate for migrations, not raw SQL"` — domain knowledge Claude doesn't have
- `"no — this should be a PATCH, not a PUT"` — correcting a wrong assumption
- `"remove this section entirely, we don't need caching here"` — rejecting a proposed approach
- `"the queue consumer already handles retries, so this retry logic is redundant. remove it and just let it fail"` — explaining why something should change
- `"this is wrong, the visibility field needs to be on the list itself, not on individual items. when a list is public, all items are public. restructure the schema section accordingly"` — redirecting an entire section

### The Return Prompt

```
I added a few notes to the document, address all the notes and update the document
accordingly. don't implement yet
```

### Iteration Count

This cycle repeats **1 to 6 times**. The `"don't implement yet"` guard is described as essential — without it, Claude jumps to code the moment it thinks the plan is good enough.

### Why Annotations in the Document Beat Chat Steering

The markdown file acts as **shared mutable state** between developer and Claude. Key advantages:
- Think at your own pace without the conversation running away
- Point precisely at the location in the document where something is wrong
- Review the plan holistically as a structured specification
- All decisions are captured and visible — no need to scroll through chat history to reconstruct decisions

Three rounds of annotation can transform a generic plan into one that perfectly fits the existing system.

### The Todo List

Before implementation begins, a granular task breakdown is always requested:

```
add a detailed todo list to the plan, with all the phases and individual tasks
necessary to complete the plan - don't implement yet
```

This creates a checklist that serves as a progress tracker during implementation. Claude marks items completed as it goes. Especially valuable in sessions that run for hours.

---

## Phase 3: Implementation

### The Standard Implementation Prompt

```
implement it all. when you're done with a task or phase, mark it as completed in
the plan document. do not stop until all tasks and phases are completed. do not add
unnecessary comments or jsdocs, do not use any or unknown types. continuously run
typecheck to make sure you're not introducing new issues.
```

### What Each Clause Encodes

| Clause | Purpose |
|--------|---------|
| `implement it all` | Don't cherry-pick from the plan |
| `mark it as completed in the plan document` | Plan is the source of truth for progress |
| `do not stop until all tasks and phases are completed` | Don't pause for confirmation mid-flow |
| `do not add unnecessary comments or jsdocs` | Keep the code clean |
| `do not use any or unknown types` | Maintain strict typing |
| `continuously run typecheck` | Catch problems early, not at the end |

### Implementation Should Be Boring

> By the time I say "implement it all," every decision has been made and validated. The implementation becomes mechanical, not creative. This is deliberate. I want implementation to be boring.

Without the planning phase, Claude makes a reasonable-but-wrong assumption early, builds on top of it for 15 minutes, and then the developer has to unwind a chain of changes. The annotation cycle eliminates this entirely.

---

## Feedback During Implementation

Once Claude is executing, the developer's role shifts from **architect to supervisor**. Prompts become dramatically shorter.

### Terse Corrections
- `"You didn't implement the deduplicateByTitle function."`
- `"You built the settings page in the main app when it should be in the admin app, move it."`

### Frontend Visual Corrections
- `"wider"`
- `"still cropped"`
- `"there's a 2px gap"`
- Screenshots attached for visual issues

### Reference-Based Corrections
- `"this table should look exactly like the users table, same header, same pagination, same row density."`

Pointing to an existing pattern communicates all implicit requirements without spelling them out.

### When Things Go Wrong: Revert and Re-Scope

When something goes in the wrong direction, don't patch it:

```
I reverted everything. Now all I want is to make the list view more minimal — nothing else.
```

Narrowing scope after a revert almost always produces better results than incrementally fixing a bad approach.

---

## Staying in the Driver's Seat

Tane delegates execution but never delegates architectural judgement. Specific techniques:

**Cherry-picking from proposals:**
> "for the first one, just use Promise.all, don't make it overly complicated; for the third one, extract it into a separate function for readability; ignore the fourth and fifth ones, they're not worth the complexity."

**Trimming scope:**
> "remove the download feature from the plan, I don't want to implement this now."

**Protecting existing interfaces:**
> "the signatures of these three functions should not change, the caller should adapt, not the library."

**Overriding technical choices:**
> "use this model instead of that one" / "use this library's built-in method instead of writing a custom one."

---

## Session Structure

**Single long sessions** — research, planning, and implementation in one continuous conversation rather than split across sessions.

By the time implementation begins, Claude has spent the entire session building understanding. When the context window fills up, auto-compaction maintains continuity. The plan document, as a persistent artifact, survives compaction in full fidelity and can be referenced at any point.

---

## The Workflow in One Sentence (Tane's Own)

> Read deeply, write a plan, annotate the plan until it's right, then let Claude execute the whole thing without stopping, checking types along the way.

---

## Key Takeaways for Applying This Workflow

1. **Research always produces a file** — chat summaries are not acceptable artifacts
2. **Depth language is functional, not stylistic** — "deeply", "in great details", "intricacies" are instructions
3. **The plan is the specification** — not chat history, not memory
4. **Annotations inject developer judgement** — this is where the developer adds the most value
5. **"don't implement yet" is a hard guard** — used until the plan is explicitly approved
6. **Implementation prompt is a template** — same phrasing reused across sessions
7. **Revert rather than patch** — when direction is wrong, reset and re-scope
8. **Plan document survives context compaction** — it's the persistent state of the session
