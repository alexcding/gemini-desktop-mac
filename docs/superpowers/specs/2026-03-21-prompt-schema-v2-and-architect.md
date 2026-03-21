# Prompt Schema v1 Additions & Prompt Architect — Design Spec

**Goal:** Extend the YAML frontmatter schema with 3 provider-routing fields, introduce a machine-readable body-content schema catalog, and ship a meta prompt architect agent that creates, converts, and maintains prompts to standard via a research → plan → approve → archive → update change control workflow.

**Architecture:** Two JSON Schema files (YAML frontmatter + body content catalog), one new prompt file (`meta/prompt-architect.md`), and an `archive/` directory. Changes are minimal, additive, and backward-compatible. No Gemini Desktop Swift code changes required.

**Tech Stack:** JSON Schema Draft 7, YAML frontmatter, Markdown, Gemini Desktop prompt library convention.

**Scope:** Anthropic (Claude) and Google (Gemini) providers as primary targets. Universal/provider-agnostic fields only in YAML — provider-specific behavior lives in the body.

---

## Background

The existing `prompt-schema-v1.json` covers YAML frontmatter metadata. It has no fields that signal:
- How the output is structured (XML, JSON, Markdown, conversational)
- Whether the prompt uses reasoning trace / scratchpad / extended thinking
- Whether the prompt is designed for single-turn, multi-turn, or interview interaction

These gaps prevent orchestrators from routing correctly and prevent linters from validating prompt fitness for a given provider. Additionally, there is no machine-readable specification for the prompt *body* structure — only a human-readable `prompt-structure.md` guide.

The prompt library also has no meta-level tooling: no way to upgrade existing prompts to the current standard without manual effort.

---

## Feature A: YAML Frontmatter Schema Updates

### 3 New Optional Fields

Added to `prompt-schema-v1.json`. All optional. All provider-agnostic.

| Field | Type | Values | Description |
|---|---|---|---|
| `output_format` | String enum | `"xml"` \| `"json"` \| `"markdown"` \| `"conversational"` | Structure of the prompt's primary output. Enables orchestrator routing and parser selection. |
| `reasoning_trace` | Boolean | `true` \| `false` | Whether the prompt uses a scratchpad / extended thinking block. Signals cost/latency implications and whether the orchestrator must strip the trace before forwarding. |
| `interaction_mode` | String enum | `"single-turn"` \| `"multi-turn"` \| `"interview"` | How the prompt is designed to be invoked. Shapes Gemini Desktop and orchestrator behavior. |

### Backward Compatibility

All three fields are optional. Existing prompts without them remain valid. `additionalProperties: true` is preserved.

### Files Updated

- `Resources/prompt-schema-v1.json` — primary (in Xcode, ships in app bundle)
- `~/Documents/Prompts/prompt-schema-v1.json` — local copy for VS Code YAML validation (synced manually or by the architect prompt)

---

## Feature B: Body Content Schema

### File: `prompt-content-schema-v1.json`

A JSON catalog (not an executable validator) that specifies the sections a prompt body may contain. Machine-readable for future linting, VS Code extensions, or the architect prompt itself. Stored at `~/Documents/Prompts/prompt-content-schema-v1.json` and `Resources/prompt-content-schema-v1.json` in the app bundle.

### Section Entry Structure

```json
{
  "id": "identity_and_purpose",
  "heading": "# IDENTITY AND PURPOSE",
  "tier": "required",
  "order": 1,
  "condition": null,
  "description": "Defines who the model is and its one-sentence mission. Sets the frame for all subsequent sections.",
  "providers": ["anthropic", "google", "universal"],
  "anthropic_note": "Wrap in <persona> XML tag when output feeds a downstream Claude agent.",
  "google_note": "Maps to the 'Persona' pillar of Google's Four Pillars framework.",
  "example": "You are a staff-level technical reviewer. Your purpose is to critically evaluate research and planning documents before they enter an execution phase."
}
```

### Fields

| Field | Type | Description |
|---|---|---|
| `id` | String | Machine identifier (snake_case) |
| `heading` | String | Exact Markdown heading as it appears in the body |
| `tier` | Enum | `"required"` \| `"conditional"` \| `"optional"` \| `"agentic"` |
| `order` | Integer | Canonical position in the body (1 = first) |
| `condition` | String \| null | When null = always include if tier is required. String = include when this condition is true. |
| `description` | String | What this section does and why it matters |
| `providers` | [String] | Which providers this section applies to |
| `anthropic_note` | String \| null | Anthropic/Claude-specific guidance |
| `google_note` | String \| null | Google/Gemini-specific guidance |
| `example` | String | One concrete example of this section's opening |

### Sections Catalog

| Order | ID | Heading | Tier | Condition (`null` = always) |
|---|---|---|---|---|
| 1 | `identity_and_purpose` | `# IDENTITY AND PURPOSE` | required | `null` |
| 2 | `context` | `# CONTEXT` | conditional | `"Model needs domain knowledge not available in training data"` |
| 3 | `instructions` | `# INSTRUCTIONS` | required | `null` |
| 4 | `steps` | `# STEPS` | conditional | `"Task has a defined multi-step sequence or phased workflow"` |
| 5 | `constraints` | `# CONSTRAINTS` | conditional | `"Hard behavioral rules, safety gates, or prohibited actions exist"` |
| 6 | `examples` | `# EXAMPLES` | optional | `null` |
| 7 | `uncertainty_handling` | `# UNCERTAINTY HANDLING` | optional | `null` |
| 8 | `input` | `# INPUT` | optional | `null` |
| 9 | `output_format` | `# OUTPUT FORMAT` | required | `null` |

**Ordering rule:** CONTEXT always before INSTRUCTIONS when both are present — domain knowledge must be loaded before instructions reference it. OUTPUT FORMAT always last — model reads this closest to where it starts generating.

### Agentic Pattern: Scratchpad Split

`scratchpad_split` is NOT a standalone section with a `#` heading. It is a **content pattern** used inside the `# OUTPUT FORMAT` section when `reasoning_trace: true` in YAML. When active, the OUTPUT FORMAT section body specifies two XML blocks:

```
<scratchpad> ... </scratchpad>
<output_payload> ... </output_payload>
```

The `scratchpad_split` entry in the catalog has `"heading": null` (no Markdown heading — it is XML inline content) and `"tier": "agentic"`. Its presence is signaled by `reasoning_trace: true` in the YAML frontmatter, not by a separate `#` section in the body.

This resolves the apparent conflict with "OUTPUT FORMAT always last" — scratchpad lives *inside* OUTPUT FORMAT, not after it.

---

## Feature C: Prompt Architect Agent

### File: `~/Documents/Prompts/meta/prompt-architect.md`

A system prompt that creates, converts, and improves prompts to current schema and SOTA standards. Designed for Anthropic and Google providers.

### YAML Frontmatter

```yaml
schema_version: "1"
name: "Prompt Architect"
version: "1.0"
role: "Senior Prompt Engineer"
summary: "Creates, converts, and improves prompts to current schema and SOTA structure standards for Anthropic and Google providers."
last_updated: "2026-03-21"
author: "zmarkley"
intent: "Produce best-in-class prompts optimized for Anthropic and Google with minimal token overhead and explicit safety controls"
language: "en-US"
compatible_with:
  - "claude-opus"
  - "claude-sonnet"
  - "gemini-2.0-pro"
  - "gemini-thinking"
output_format: "markdown"
interaction_mode: "multi-turn"
reasoning_trace: true
safety_gates:
  - "user-approval-required-before-any-file-change"
  - "archive-before-overwrite"
  - "intent-preservation: flag any change that alters semantic goal"
tags:
  - "meta"
  - "tooling"
  - "architecture"
```

### Three Priorities (encoded as behavioral rules)

1. **Quality** — every section must meet SOTA criteria before output. No filler, no vague instructions, no softened language.
2. **Security & privacy** — flag prompt injection risks, PII exposure, missing safety gates, and dangerous pattern vectors. Never silently omit a security concern.
3. **Token efficiency** — no redundant sections, no padding. If a section adds no signal, omit it. Every token must earn its place.

### Change Control Workflow

The architect follows a mandatory 3-phase change control process. No file changes occur without explicit user approval.

**Phase 1 — Research**
1. Analyze the prompt against current schema (`prompt-schema-v1.json`) and body structure (`prompt-content-schema-v1.json`)
2. Research relevant SOTA guidelines for the prompt's domain and target providers
3. Produce a **Research Report**: gaps identified, improvements found, security concerns flagged, provider-specific recommendations
4. Present report to user
5. Accept feedback and iterate until user is satisfied with the research findings

**Phase 2 — Change Plan**
1. Translate research findings into a specific, numbered list of proposed changes
2. For each change: state what changes, why, and what standard/rule it satisfies
3. Flag any change that alters the semantic intent of the prompt — these require explicit individual user confirmation
4. Present plan to user
5. Accept feedback and iterate until user approves the full plan

**Phase 3 — Execute**
1. Archive: copy current file to `archive/{filename}-v{current_version}.md`
   - If `version` is missing from YAML, use `v0.0` in the archive filename and warn the user
   - If that archive path already exists, append `-{YYYY-MM-DD}` to disambiguate before writing
2. Apply all approved changes
3. Increment `version` in YAML using this decision tree:
   - **Patch** (1.0 → 1.1): wording improvements, adding optional fields (`output_format`, `reasoning_trace`, `interaction_mode`), adding/removing optional sections (`# EXAMPLES`, `# UNCERTAINTY HANDLING`, `# INPUT`)
   - **Minor** (1.0 → 2.0): adding or removing required/conditional sections (`# IDENTITY AND PURPOSE`, `# INSTRUCTIONS`, `# OUTPUT FORMAT`, `# STEPS`, `# CONTEXT`, `# CONSTRAINTS`), or any change the user explicitly flags as structural
4. Output the complete updated prompt
5. Output a **Change Summary**: bulleted list of every change applied with the rule/standard that justified it

### Scope Boundaries

The architect does NOT:
- Change what a prompt does — only how it is expressed
- Add sections the user did not approve in Phase 2
- Modify `safety_gates` values without explicit individual user confirmation
- Overwrite an existing archive file (always disambiguate first)
- Auto-populate the 3 new YAML fields (`output_format`, `reasoning_trace`, `interaction_mode`) without including them in the Phase 2 change plan — they are YAML metadata changes and require approval like any other change

### Provider Notes Usage

`anthropic_note` and `google_note` fields in the body content schema are reference data for the architect's Phase 1 Research Report. When the target prompt's `compatible_with` includes Anthropic or Google models, the architect surfaces the relevant provider note as a recommendation. They are not validated or enforced — they are advisory guidance to the architect.

---

## Feature D: Archive Directory

### Path: `~/Documents/Prompts/archive/`

Created as an empty directory with a `.gitkeep` file. Populated by the architect on first use.

### Archive Filename Convention

`{original-filename-without-extension}-v{version}.md`

Examples:
- `neurodivergent-intake-v1.0.md`
- `doc-review-agent-v1.0.md`
- `doc-review-agent-v1.1.md`

**Behavior:** If an archive file with that name already exists, the architect appends `-{date}` to disambiguate: `doc-review-agent-v1.0-2026-03-21.md`. This prevents silent overwrites of existing archives.

---

## Files Changed

| Action | File | What |
|---|---|---|
| Update | `Resources/prompt-schema-v1.json` | Add `output_format`, `reasoning_trace`, `interaction_mode` |
| Create | `Resources/prompt-content-schema-v1.json` | Body section catalog, ships in app bundle |
| Update | `GeminiDesktop.xcodeproj/project.pbxproj` | Register `prompt-content-schema-v1.json` in Copy Bundle Resources |
| Create | `~/Documents/Prompts/prompt-content-schema-v1.json` | Local copy for VS Code + architect reference |
| Create | `~/Documents/Prompts/prompt-schema-v1.json` | Local copy of updated YAML schema for VS Code |
| Create | `~/Documents/Prompts/meta/prompt-architect.md` | The architect prompt |
| Create | `~/Documents/Prompts/archive/.gitkeep` | Archive directory placeholder |
| Update | `~/Documents/Prompts/YAML-schema.md` | Document 3 new fields |
| Update | `~/Documents/Prompts/prompt-structure.md` | Reference the content schema |

---

## Out of Scope

- Swift code changes to Gemini Desktop (no new parser fields needed — the 3 new YAML fields are optional and not rendered in the tooltip)
- Automated prompt migration script
- VS Code extension for live body-section validation
- `prompt-schema-v2.json` — this is an additive update to v1, not a version bump
- Multi-provider body variants (Anthropic XML vs Google Markdown) — handled in body by the architect, not in schema
