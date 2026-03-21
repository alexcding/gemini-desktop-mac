# Prompt Library UI & Schema — Design Spec

**Goal:** Replace the current ad-hoc prompt YAML schema with a greenfield Prompt-as-Code standard, improve the menu UI to follow Apple HIG, and add a structured hover tooltip with a clean seam for a future rich popover.

**Architecture:** New `PromptMetadata` schema with required and optional fields. Menu rendering decoupled from YAML (filename drives label). `PromptTooltipContent` struct generates `.help()` tooltip text and serves as the seam for a future Option B popover. Two bundle resources ship with the app: a formal JSON Schema and a starter template.

**Tech Stack:** Swift, SwiftUI, AppKit, Yams (existing), WKWebView (unchanged)

---

## Background

The current prompt menu has four problems:

1. **Emojis are opaque** — 🚫/⚠️ prefixes are not explained anywhere; users don't know what they mean.
2. **Order feels random** — alphabetical by metadata title creates an unpredictable sort order when filenames differ from titles.
3. **No hover summary** — users must click or inject to discover what a prompt does.
4. **Schema is inconsistent** — `title` and `description` are required for any metadata to parse; prompts missing them silently lose all metadata. Fields do not reflect production/agentic use cases.

---

## Feature A: Greenfield YAML Schema

### Schema Version

Every prompt file that uses YAML frontmatter must declare `schema_version: "1"`. This anchors the schema contract and enables forward-compatible parsing when fields change in future versions.

### Required Fields

A prompt file with a `---` YAML block that is missing any required field is treated as a YAML parse error. The parser returns `nil` for the metadata object; the error is surfaced in the hover tooltip.

| Field | Type | Description |
|---|---|---|
| `schema_version` | String | Always `"1"` for this version |
| `name` | String | Human-readable prompt name (shown in hover, not menu) |
| `version` | String | Prompt version — treat prompts as code (e.g. `"1.0"`) |
| `role` | String | Persona the prompt plays (e.g. `"teaching assistant"`) |
| `summary` | String | One-to-two sentence description shown as hover body |

### Optional — Core Fields

| Field | Type | Description |
|---|---|---|
| `last_updated` | String | Date string, displayed as-is (no parsing) |
| `author` | String | Attribution for shared or team libraries |
| `intent` | String | One-sentence goal declaration — prevents drift in agentic chains |
| `language` | String | Locale the prompt is written in (e.g. `"en-US"`) |
| `deprecated` | Bool | When `true`, menu item is greyed out |

### Optional — Production / Agentic Fields

| Field | Type | Description |
|---|---|---|
| `compatible_with` | [String] | Models this prompt is tuned for (e.g. `["gemini-thinking", "claude-opus"]`) |
| `tags` | [String] | Reserved for future filtering and search |
| `output_schema` | String | Expected output structure for orchestrators (e.g. `"scratchpad → verdict"`) |
| `safety_gates` | [String] | Explicit human-in-the-loop checkpoints |
| `model_parameters` | Object | Hints for orchestrators: `temperature`, `top_p`, `max_tokens` |
| `license` | String | For shared/public prompt libraries (e.g. `"MIT"`, `"CC-BY-4.0"`) |
| `input_variables` | [String] | Named placeholders the prompt body expects (e.g. `["user_name", "context"]`) |

### Canonical Example

```yaml
---
schema_version: "1"
name: "Socratic Tutor"
version: "1.0"
role: "teaching assistant"
summary: "Guides through problems by asking questions rather than giving answers. Good for learning-mode sessions."
last_updated: "2026-03-21"
author: "zmarkley"
intent: "Help users develop independent reasoning without receiving direct answers"
language: "en-US"
compatible_with:
  - "gemini-thinking"
  - "gemini-2.0-pro"
tags:
  - "education"
  - "reasoning"
input_variables:
  - "topic"
output_schema: "clarifying question → guided reflection → follow-up question"
safety_gates:
  - "human-review-before-clinical-use"
model_parameters:
  temperature: 0.4
  max_tokens: 2048
license: "MIT"
---
```

### Parser Behavior

- A file with no `---` block: `metadata == nil`, no error, renders as plain filename.
- A file with a `---` block where all required fields are present: `metadata` fully populated.
- A file with a `---` block where any required field is missing: `metadata == nil`, `yamlParseError == true`, error shown in tooltip.
- Optional fields absent from the file: omitted from tooltip, no error.

---

## Feature B: Bundle Schema Resources

Two files ship in the app bundle under `Resources/`:

### `prompt-schema-v1.json`

Formal JSON Schema (Draft 7) defining the v1 prompt frontmatter structure. Enables live YAML validation in VS Code (via the Red Hat YAML extension's `yaml.schemas` setting). When schema v2 is introduced, `prompt-schema-v2.json` is added alongside — old files are not broken.

Key contents:
- `$schema`, `title`, `description`
- `required` array: `["schema_version", "name", "version", "role", "summary"]`
- `properties` for every field with `type`, `description`, and where appropriate `enum` or `items`
- `additionalProperties: true` — orchestrators may add custom fields

### `prompt-template.md`

A starter prompt file with all fields present and commented. Users copy this when creating a new prompt. Shipping in the bundle means it's always up to date with the current schema version.

```markdown
---
schema_version: "1"
name: "My Prompt"           # Required: human-readable name
version: "1.0"              # Required: increment when you change the prompt
role: "assistant"           # Required: persona this prompt plays
summary: "..."              # Required: one sentence describing what this does

# Optional — core
last_updated: "2026-03-21"
author: ""
intent: ""
language: "en-US"
# deprecated: false

# Optional — production / agentic
# compatible_with: []
# tags: []
# input_variables: []
# output_schema: ""
# safety_gates: []
# model_parameters:
#   temperature: 0.7
#   max_tokens: 2048
# license: "MIT"
---

Your prompt body goes here.
```

---

## Feature C: Menu Rendering

### Display Title

Menu item label = **filename without extension**. No YAML dependency for the label. `socratic-tutor.md` → `socratic-tutor`. Ordering and display are fully predictable regardless of metadata.

This simplifies `PromptFile.displayTitle` to a single expression with no fallback chain.

### Security Status

Security badge emoji (`🚫`, `⚠️`) removed from menu item labels entirely. Security status is surfaced in the hover tooltip only (see Feature D). The click-time `NSAlert` for dangerous prompts is retained — it remains the primary protection.

### Deprecated Prompts

When `deprecated: true` in metadata, the menu item renders with `.foregroundStyle(.secondary)` — greyed out, still selectable. The tooltip notes the prompt is deprecated.

### YAML Parse Errors

When `yamlParseError == true`, the tooltip notes the error. No visual change to the menu item label beyond the plain filename — the error is not surfaced until hover.

### Ordering

Unchanged: mirrors filesystem directory structure, alphabetical by filename within each directory.

---

## Feature D: Hover Tooltip

### Implementation: Option A — `.help()` modifier

Each menu item receives `.help(file.tooltipContent?.formatted() ?? "")`. Uses the standard macOS help tag system — no custom positioning, no custom views, no sandbox issues.

**Known limitation:** `.help()` renders in the system proportional font. True column alignment is not possible. Short, consistent labels are used to keep values visually clustered. Full alignment is deferred to Option B.

### Option B Happy Path

`PromptTooltipContent` is the data/rendering seam. Option A calls `content.formatted()` to get a plain string. Option B replaces `.help()` with `onHover` + `NSPopover` containing a SwiftUI `Grid` view built from the same `PromptTooltipContent` fields — no change to the data layer.

### `PromptTooltipContent` Struct

```swift
struct PromptTooltipContent {
    let name: String?
    let version: String?
    let role: String?
    let lastUpdated: String?
    let summary: String?
    let intent: String?
    let compatibleWith: [String]
    let tags: [String]
    let inputVariables: [String]
    let outputSchema: String?
    let deprecated: Bool
    let securityNotice: String?   // nil if safe
    let yamlError: Bool

    func formatted() -> String { ... }
}
```

`PromptFile` gains a computed property `var tooltipContent: PromptTooltipContent?` that returns `nil` when there is no metadata and no security notice and no YAML error (i.e. a plain prompt with no frontmatter gets no tooltip).

### Tooltip Format

```
Socratic Tutor  v1.0
⚠ Risky: "act as if"

Role:     teaching assistant
Summary:  Guides through problems by asking
          questions rather than giving answers.
Intent:   Help users develop independent reasoning

Compatible: gemini-thinking, gemini-2.0-pro
Tags:       education, reasoning
Inputs:     topic
Updated:    2026-03-21
```

**Formatting rules:**
- Line 1: `name  vX.Y` (omit version if absent, omit name if absent)
- Line 2: security notice if present (danger or warning with matched pattern)
- Blank line
- Behavior group: Role, Summary (wrapped), Intent — omit absent fields
- Blank line (only if production fields present)
- Production group: Compatible, Tags, Inputs, Output, Updated — omit absent fields
- If `deprecated: true`: append `\nDeprecated — use a newer version`
- If `yamlError: true`: show `YAML error: required fields missing` instead of all other content

---

## Feature E: Existing Prompt Migration

All existing prompt `.md` files are updated to the new schema as part of this work. The migration is manual — each prompt is reviewed and updated with correct `name`, `version`, `role`, and `summary` values. No automated migration script.

---

## Out of Scope

- Option B popover implementation
- Scanner criteria changes (template placeholder false-positive fix deferred)
- Auto-update of schema from GitHub
- Editable prompt fields in Settings UI
- Filtering or search by tags

---

## Files Changed

| Action | File | What changes |
|---|---|---|
| Modify | `Prompts/PromptMetadata.swift` | New required/optional fields; updated parser |
| Modify | `Prompts/PromptFile.swift` | `displayTitle` = filename only; add `PromptTooltipContent` |
| Modify | `Views/PromptsMenuButton.swift` | Remove emoji prefixes; add `.help()`; grey deprecated items |
| Add | `Resources/prompt-schema-v1.json` | Formal JSON Schema for v1 |
| Add | `Resources/prompt-template.md` | Starter template with all fields documented |
| Modify | `*.md` (prompt files) | Refactor all existing prompts to new schema |
