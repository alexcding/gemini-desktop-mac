# Prompt Library UI & Schema Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ad-hoc prompt YAML schema with a greenfield Prompt-as-Code standard, decouple menu labels from YAML, and add structured `.help()` hover tooltips.

**Architecture:** `PromptMetadata` gets a new parser with 5 required + 11 optional fields. `PromptFile.displayTitle` becomes filename-only. A new `PromptTooltipContent` struct generates the `.help()` string and serves as the seam for a future rich popover. Security badges move from menu labels to tooltip text. Two bundle resources ship for external tooling.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, Yams (existing dependency), Xcode 15+, macOS 14+

---

## Context for Implementers

This is a macOS app — there is no command-line test runner. "Build" means running:

```bash
xcodebuild -project GeminiDesktop.xcodeproj -scheme GeminiDesktop build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected output: `** BUILD SUCCEEDED **`

**Key files to read before starting:**
- `Prompts/PromptMetadata.swift` — current YAML parser, manually maps `[String: Any]` dict (not Codable)
- `Prompts/PromptFile.swift` — `PromptFile` struct + `PromptNode` enum; `displayTitle` currently falls back through metadata title → filename
- `Views/PromptsMenuButton.swift` — SwiftUI `Menu` button; currently prepends emoji badges via `getBadgePrefix()`
- `Prompts/PromptScanner.swift` — `ScanResult` enum with `.safe`, `.warning(reason:)`, `.danger(reason:)`
- `Intents/PromptAppEntity.swift` — uses `file.displayTitle` and `file.displayDescription` for Siri/Shortcuts display

**Spec:** `docs/superpowers/specs/2026-03-21-prompt-library-ui-and-schema.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `Prompts/PromptMetadata.swift` | Modify | New schema: 5 required + 11 optional fields; updated parser; `ModelParameters` nested struct |
| `Prompts/PromptFile.swift` | Modify | `displayTitle` = filename only; `displayDescription` → `metadata?.summary`; add `PromptTooltipContent` struct + `tooltipContent` computed property |
| `Views/PromptsMenuButton.swift` | Modify | Remove emoji/`getBadgePrefix`; add `.help()`; grey deprecated items; remove description caption |
| `Resources/prompt-schema-v1.json` | Create | Formal JSON Schema (Draft 7) for external tooling validation |
| `Resources/prompt-template.md` | Create | Starter template prompt with all fields documented inline |

**No changes needed:**
- `Prompts/PromptLibrary.swift` — sorts by `displayTitle`; since `displayTitle` now equals filename, behavior is identical
- `Intents/PromptAppEntity.swift` — adapts naturally via `displayTitle` and `displayDescription`
- `Intents/PromptEntityQuery.swift` — no metadata field references
- `Prompts/PromptScanner.swift` — unchanged

---

## Build Command (use after every task)

```bash
cd /Users/zmarkley/src/github.com/alexcding/gemini-desktop-mac
xcodebuild -project GeminiDesktop.xcodeproj -scheme GeminiDesktop build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`

---

## Task 1: Update `PromptMetadata.swift`

**Files:**
- Modify: `Prompts/PromptMetadata.swift`

Read the current file before editing. The parser uses `Yams.load()` to produce `[String: Any]`, then manually extracts fields. The new parser follows the same pattern — add new keys, enforce required fields via `guard`.

- [ ] **Step 1.1: Replace the entire file contents**

```swift
//
//  PromptMetadata.swift
//  GeminiDesktop
//

import Foundation
import Yams

struct PromptMetadata {

    // MARK: - Required fields

    let schemaVersion: String
    let name: String
    let version: String
    let role: String
    let summary: String

    // MARK: - Optional core fields

    let lastUpdated: String?
    let author: String?
    let intent: String?
    let language: String?
    let deprecated: Bool         // defaults to false if absent

    // MARK: - Optional production / agentic fields

    let compatibleWith: [String] // defaults to [] if absent
    let tags: [String]           // defaults to [] if absent
    let outputSchema: String?
    let safetyGates: [String]    // defaults to [] if absent
    let modelParameters: ModelParameters?
    let license: String?
    let inputVariables: [String] // defaults to [] if absent

    // MARK: - Nested types

    struct ModelParameters {
        let temperature: Double?
        let topP: Double?
        let maxTokens: Int?
    }

    // MARK: - Parsing

    /// Parses YAML frontmatter from a prompt file's full content string.
    /// Returns nil if: no --- block, YAML is malformed, or any required field is missing.
    static func parse(from content: String) -> PromptMetadata? {
        let lines = content.components(separatedBy: .newlines)
        guard lines.count > 2, lines[0] == "---" else { return nil }

        var endIndex = -1
        for i in 1..<lines.count {
            if lines[i] == "---" { endIndex = i; break }
        }
        guard endIndex > 1 else { return nil }

        let yamlContent = lines[1..<endIndex].joined(separator: "\n")

        do {
            guard let decoded = try Yams.load(yaml: yamlContent) as? [String: Any] else { return nil }

            // Required fields — missing any returns nil (yamlParseError = true in PromptFile)
            guard
                let schemaVersion = decoded["schema_version"] as? String,
                let name = decoded["name"] as? String,
                let version = decoded["version"] as? String,
                let role = decoded["role"] as? String,
                let summary = decoded["summary"] as? String
            else { return nil }

            // Optional core
            let lastUpdated    = decoded["last_updated"] as? String
            let author         = decoded["author"] as? String
            let intent         = decoded["intent"] as? String
            let language       = decoded["language"] as? String
            let deprecated     = decoded["deprecated"] as? Bool ?? false

            // Optional production
            let compatibleWith  = decoded["compatible_with"] as? [String] ?? []
            let tags            = decoded["tags"] as? [String] ?? []
            let outputSchema    = decoded["output_schema"] as? String
            let safetyGates     = decoded["safety_gates"] as? [String] ?? []
            let license         = decoded["license"] as? String
            let inputVariables  = decoded["input_variables"] as? [String] ?? []

            var modelParameters: ModelParameters? = nil
            if let mp = decoded["model_parameters"] as? [String: Any] {
                modelParameters = ModelParameters(
                    temperature: mp["temperature"] as? Double,
                    topP:        mp["top_p"] as? Double,
                    maxTokens:   mp["max_tokens"] as? Int
                )
            }

            return PromptMetadata(
                schemaVersion:   schemaVersion,
                name:            name,
                version:         version,
                role:            role,
                summary:         summary,
                lastUpdated:     lastUpdated,
                author:          author,
                intent:          intent,
                language:        language,
                deprecated:      deprecated,
                compatibleWith:  compatibleWith,
                tags:            tags,
                outputSchema:    outputSchema,
                safetyGates:     safetyGates,
                modelParameters: modelParameters,
                license:         license,
                inputVariables:  inputVariables
            )
        } catch {
            return nil
        }
    }

    // MARK: - Body extraction (unchanged)

    /// Returns the prompt body — the content after the closing --- delimiter.
    static func extractBody(from content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        guard lines.count > 2, lines[0] == "---" else { return content }

        for i in 1..<lines.count {
            if lines[i] == "---" {
                return lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
            }
        }
        return content
    }
}
```

- [ ] **Step 1.2: Build**

```bash
xcodebuild -project GeminiDesktop.xcodeproj -scheme GeminiDesktop build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`

If there are compiler errors, they will be in files that referenced the old `PromptMetadata` fields (`title`, `description`, `category`, `model`). Fix any that appear before proceeding. The most likely offender is `PromptFile.swift` which uses `metadata?.title` and `metadata?.description` — those will be fixed in Task 2.

- [ ] **Step 1.3: Commit**

```bash
git add Prompts/PromptMetadata.swift
git commit -m "feat: replace PromptMetadata schema with greenfield v1 fields"
```

---

## Task 2: Update `PromptFile.swift`

**Files:**
- Modify: `Prompts/PromptFile.swift`

Three changes: (1) `displayTitle` becomes filename-only, (2) `displayDescription` returns `metadata?.summary`, (3) add `PromptTooltipContent` struct and `tooltipContent` computed property.

Read the current file before editing.

- [ ] **Step 2.1: Replace the entire file contents**

```swift
//
//  PromptFile.swift
//  GeminiDesktop
//

import Foundation

// MARK: - PromptTooltipContent

/// Carries structured metadata for display in a .help() tooltip.
/// All fields are typed — Option B (rich popover) reads them directly instead of calling formatted().
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
    let securityNotice: String?  // nil when safe
    let yamlError: Bool

    /// Formats content as a plain-text string for .help() tooltip display.
    /// yamlError takes priority over all other fields.
    /// Omits rows for nil/empty fields.
    func formatted() -> String {
        if yamlError {
            return "YAML error: required fields missing"
        }

        var lines: [String] = []

        // Header: "Name  vX.Y"
        let namePart    = name ?? ""
        let versionPart = version.map { "v\($0)" } ?? ""
        let header      = [namePart, versionPart].filter { !$0.isEmpty }.joined(separator: "  ")
        if !header.isEmpty { lines.append(header) }

        // Security notice immediately after header
        if let notice = securityNotice { lines.append(notice) }

        // Blank line after header block (only if name/version or security notice is present)
        if !header.isEmpty || securityNotice != nil { lines.append("") }

        // Behavior group
        var behaviorLines: [String] = []
        if let role = role, !role.isEmpty {
            behaviorLines.append("Role:     \(role)")
        }
        if let summary = summary, !summary.isEmpty {
            behaviorLines.append(contentsOf: wrap(summary, label: "Summary:  "))
        }
        if let intent = intent, !intent.isEmpty {
            behaviorLines.append(contentsOf: wrap(intent, label: "Intent:   "))
        }
        lines.append(contentsOf: behaviorLines)

        // Production group (only rendered if at least one field is present)
        var prodLines: [String] = []
        if !compatibleWith.isEmpty {
            prodLines.append("Compatible: \(compatibleWith.joined(separator: ", "))")
        }
        if !tags.isEmpty {
            prodLines.append("Tags:       \(tags.joined(separator: ", "))")
        }
        if !inputVariables.isEmpty {
            prodLines.append("Inputs:     \(inputVariables.joined(separator: ", "))")
        }
        if let outputSchema = outputSchema, !outputSchema.isEmpty {
            prodLines.append("Output:     \(outputSchema)")
        }
        if let lastUpdated = lastUpdated, !lastUpdated.isEmpty {
            prodLines.append("Updated:    \(lastUpdated)")
        }
        if !prodLines.isEmpty {
            if !behaviorLines.isEmpty { lines.append("") }
            lines.append(contentsOf: prodLines)
        }

        // Deprecated note as final line
        if deprecated {
            lines.append("Deprecated — use a newer version")
        }

        return lines.joined(separator: "\n")
    }

    /// Wraps text at 60 characters, indenting continuation lines to align with value start.
    private func wrap(_ text: String, label: String) -> [String] {
        let maxWidth = 60
        let indent   = String(repeating: " ", count: label.count)
        var result: [String] = []
        var current = label
        for word in text.components(separatedBy: " ") {
            if current == label {
                current += word
            } else if (current + " " + word).count <= maxWidth {
                current += " " + word
            } else {
                result.append(current)
                current = indent + word
            }
        }
        if current != label { result.append(current) }
        return result
    }
}

// MARK: - PromptFile

struct PromptFile: Identifiable, Equatable {
    let url: URL
    let metadata: PromptMetadata?
    let yamlParseError: Bool
    let body: String
    let scanResult: ScanResult

    var id: String { url.lastPathComponent }

    /// Menu display label — always the filename without extension.
    /// No YAML dependency: ordering and display are predictable regardless of metadata.
    var displayTitle: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Summary text for Siri/Shortcuts display via PromptAppEntity.
    var displayDescription: String? {
        metadata?.summary
    }

    /// Structured tooltip content for .help() display.
    /// Returns nil for plain prompts with no metadata, no security notice, and no YAML error.
    var tooltipContent: PromptTooltipContent? {
        let securityNotice: String?
        switch scanResult {
        case .safe:
            securityNotice = nil
        case .warning(let reason):
            securityNotice = "⚠ Risky: \"\(reason)\""
        case .danger(let reason):
            securityNotice = "Danger: \"\(reason)\""
        }

        // Plain prompts with no metadata and no security issue get no tooltip
        guard metadata != nil || securityNotice != nil || yamlParseError else { return nil }

        return PromptTooltipContent(
            name:           metadata?.name,
            version:        metadata?.version,
            role:           metadata?.role,
            lastUpdated:    metadata?.lastUpdated,
            summary:        metadata?.summary,
            intent:         metadata?.intent,
            compatibleWith: metadata?.compatibleWith ?? [],
            tags:           metadata?.tags ?? [],
            inputVariables: metadata?.inputVariables ?? [],
            outputSchema:   metadata?.outputSchema,
            deprecated:     metadata?.deprecated ?? false,
            securityNotice: securityNotice,
            yamlError:      yamlParseError
        )
    }

    static func load(from url: URL) -> PromptFile {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let body    = PromptMetadata.extractBody(from: content)
            let scanResult = PromptScanner.scan(body: body)

            var metadata: PromptMetadata? = nil
            var yamlParseError = false

            if content.hasPrefix("---") {
                metadata      = PromptMetadata.parse(from: content)
                yamlParseError = (metadata == nil)
            }

            return PromptFile(
                url:           url,
                metadata:      metadata,
                yamlParseError: yamlParseError,
                body:          body,
                scanResult:    scanResult
            )
        } catch {
            return PromptFile(
                url:           url,
                metadata:      nil,
                yamlParseError: false,
                body:          "",
                scanResult:    .safe
            )
        }
    }

    static func == (lhs: PromptFile, rhs: PromptFile) -> Bool {
        lhs.url == rhs.url && lhs.body == rhs.body
    }
}

// MARK: - PromptNode

enum PromptNode: Identifiable {
    case file(PromptFile)
    case directory(name: String, children: [PromptNode])

    var id: String {
        switch self {
        case .file(let f):            return f.id
        case .directory(let name, _): return "dir:\(name)"
        }
    }
}
```

- [ ] **Step 2.2: Build**

```bash
xcodebuild -project GeminiDesktop.xcodeproj -scheme GeminiDesktop build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2.3: Commit**

```bash
git add Prompts/PromptFile.swift
git commit -m "feat: add PromptTooltipContent, update displayTitle to filename-only"
```

---

## Task 3: Update `PromptsMenuButton.swift`

**Files:**
- Modify: `Views/PromptsMenuButton.swift`

Three changes: (1) remove `getBadgePrefix` and emoji logic, (2) add `.help()` modifier with tooltip content, (3) grey out deprecated items.

Read the current file before editing.

- [ ] **Step 3.1: Replace the entire file contents**

```swift
//
//  PromptsMenuButton.swift
//  GeminiDesktop
//

import SwiftUI

struct PromptsMenuButton: View {
    var coordinator: AppCoordinator
    var injectionMode: String

    var body: some View {
        Menu {
            ForEach(coordinator.promptLibrary.rootNodes, id: \.id) { node in
                AnyView(nodeContent(for: node))
            }
        } label: {
            Image(systemName: "sparkles")
        }
        .disabled(coordinator.isInjecting)
    }

    private func nodeContent(for node: PromptNode) -> some View {
        switch node {
        case .directory(let name, let children):
            return AnyView(
                Menu(name) {
                    ForEach(children, id: \.id) { child in
                        AnyView(nodeContent(for: child))
                    }
                }
            )
        case .file(let file):
            return AnyView(fileMenuButton(for: file))
        }
    }

    @ViewBuilder
    private func fileMenuButton(for file: PromptFile) -> some View {
        let isDeprecated = file.metadata?.deprecated == true

        if let tooltip = file.tooltipContent {
            Button(action: { handleSelection(file) }) {
                Text(file.displayTitle)
                    .foregroundStyle(isDeprecated ? Color.secondary : Color.primary)
            }
            .help(tooltip.formatted())
        } else {
            Button(file.displayTitle, action: { handleSelection(file) })
                .foregroundStyle(isDeprecated ? Color.secondary : Color.primary)
        }
    }

    private func handleSelection(_ file: PromptFile) {
        if case .danger = file.scanResult {
            showDangerAlert(for: file)
        } else {
            executePrompt(file)
        }
    }

    private func showDangerAlert(for file: PromptFile) {
        let alert = NSAlert()
        alert.messageText = "Dangerous Pattern Detected"
        alert.informativeText = "This prompt contains a pattern that could be misused. Are you sure you want to use it?"
        alert.addButton(withTitle: "Use Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            executePrompt(file)
        }
    }

    private func executePrompt(_ file: PromptFile) {
        if injectionMode == "copy" {
            coordinator.copyPromptToClipboard(file)
        } else {
            coordinator.injectPrompt(file)
        }
    }
}
```

- [ ] **Step 3.2: Build**

```bash
xcodebuild -project GeminiDesktop.xcodeproj -scheme GeminiDesktop build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3.3: Commit**

```bash
git add Views/PromptsMenuButton.swift
git commit -m "feat: update prompt menu — filename labels, .help() tooltips, deprecated styling"
```

---

## Task 4: Add Bundle Resources

**Files:**
- Create: `Resources/prompt-schema-v1.json`
- Create: `Resources/prompt-template.md`

Both files must also be added to the Xcode project (the `Resources` group) and included in the "Copy Bundle Resources" build phase — the same way `gemini-selectors.json` is included. In Xcode: right-click the `Resources` group → Add Files → select both files → ensure the GeminiDesktop target checkbox is ticked.

- [ ] **Step 4.1: Create `Resources/prompt-schema-v1.json`**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Gemini Desktop Prompt v1",
  "description": "Schema for Gemini Desktop prompt YAML frontmatter (schema_version: 1). See https://github.com/daveorzach/gemini-desktop-mac for details.",
  "type": "object",
  "required": ["schema_version", "name", "version", "role", "summary"],
  "properties": {
    "schema_version": {
      "type": "string",
      "const": "1",
      "description": "Schema version anchor. Always '1' for this version."
    },
    "name": {
      "type": "string",
      "description": "Human-readable prompt name shown in hover tooltip."
    },
    "version": {
      "type": "string",
      "description": "Prompt version string. Increment when you change the prompt body."
    },
    "role": {
      "type": "string",
      "description": "Persona this prompt plays (e.g. 'teaching assistant', 'code reviewer')."
    },
    "summary": {
      "type": "string",
      "description": "One-to-two sentence description. Shown as hover tooltip body."
    },
    "last_updated": {
      "type": "string",
      "description": "Date string, displayed as-is (e.g. '2026-03-21')."
    },
    "author": {
      "type": "string",
      "description": "Prompt author. Used for attribution in shared libraries."
    },
    "intent": {
      "type": "string",
      "description": "One-sentence goal declaration. Prevents drift in agentic chains."
    },
    "language": {
      "type": "string",
      "description": "Locale the prompt is written in (e.g. 'en-US')."
    },
    "deprecated": {
      "type": "boolean",
      "description": "When true, the prompt is greyed out in the menu."
    },
    "compatible_with": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Models this prompt is tuned for (e.g. ['gemini-thinking', 'claude-opus'])."
    },
    "tags": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Reserved for future filtering and search."
    },
    "output_schema": {
      "type": "string",
      "description": "Expected output structure for orchestrators (e.g. 'scratchpad → verdict')."
    },
    "safety_gates": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Explicit human-in-the-loop checkpoints."
    },
    "model_parameters": {
      "type": "object",
      "description": "Inference parameter hints for orchestrators.",
      "properties": {
        "temperature": { "type": "number" },
        "top_p":       { "type": "number" },
        "max_tokens":  { "type": "integer" }
      },
      "additionalProperties": true
    },
    "license": {
      "type": "string",
      "description": "License for shared/public prompt libraries (e.g. 'MIT', 'CC-BY-4.0')."
    },
    "input_variables": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Named placeholders the prompt body expects (e.g. ['user_name', 'context'])."
    }
  },
  "additionalProperties": true
}
```

- [ ] **Step 4.2: Create `Resources/prompt-template.md`**

```markdown
---
schema_version: "1"
name: "My Prompt"           # Required: human-readable name shown in hover
version: "1.0"              # Required: increment when you change the prompt body
role: "assistant"           # Required: persona this prompt plays
summary: "..."              # Required: one-to-two sentences describing what this does

# Optional — core
last_updated: "2026-03-21"  # Date string, shown as-is
author: ""                  # Your name or handle
intent: ""                  # One-sentence goal — prevents drift in agentic chains
language: "en-US"           # Locale this prompt is written in
# deprecated: false         # Set to true to grey this out in the menu

# Optional — production / agentic
# compatible_with:
#   - "gemini-thinking"
#   - "gemini-2.0-pro"
# tags:
#   - "example"
# input_variables:
#   - "variable_name"
# output_schema: "step1 → step2 → result"
# safety_gates:
#   - "human-review-required"
# model_parameters:
#   temperature: 0.7
#   max_tokens: 2048
# license: "MIT"
---

Your prompt body goes here.

Use {{variable_name}} for placeholders if you declared input_variables above.
```

- [ ] **Step 4.3: Add both files to Xcode project**

In Xcode:
1. Right-click the `Resources` group in the Project Navigator
2. Choose **Add Files to 'GeminiDesktop'…**
3. Select both `prompt-schema-v1.json` and `prompt-template.md`
4. Ensure the **GeminiDesktop** target checkbox is ticked
5. Click **Add**

- [ ] **Step 4.4: Build**

```bash
xcodebuild -project GeminiDesktop.xcodeproj -scheme GeminiDesktop build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4.5: Commit**

```bash
git add Resources/prompt-schema-v1.json Resources/prompt-template.md GeminiDesktop.xcodeproj/project.pbxproj
git commit -m "feat: add prompt-schema-v1.json and prompt-template.md bundle resources"
```

---

## Task 5: Migrate Existing Prompt Files

**Files:**
- Modify: any `*.md` prompt files in the user's prompts directory

The app stores prompts in a user-selected directory (sandboxed via `BookmarkStore`). There are no prompt files checked into the repository — this task applies to the user's personal prompt library.

For each prompt file:

- [ ] **Step 5.1: Add the required YAML header**

Open each `.md` file and add a frontmatter block at the top. Use `prompt-template.md` as the starting point (it ships in the app bundle after Task 4). At minimum, supply all 5 required fields:

```yaml
---
schema_version: "1"
name: "Descriptive Name Here"
version: "1.0"
role: "the persona this prompt plays"
summary: "One sentence describing what this prompt does."
---
```

Fill in optional fields (`last_updated`, `author`, `intent`, etc.) where you have the information.

- [ ] **Step 5.2: Verify each migrated file in the app**

Run the app (Cmd+R), open the Prompts menu, hover over each migrated prompt. Confirm:
- Tooltip appears with name, role, and summary
- No YAML error notice in tooltip
- Filename (not YAML `name`) appears as the menu item label

A file with a missing required field will show `YAML error: required fields missing` in the tooltip — fix by supplying the missing field.

---

## Manual Verification Checklist

After all tasks complete, run the app (Cmd+R) and verify:

- [ ] **V1: Filename labels** — Menu items show filename without extension (e.g. `my-prompt`, not the YAML `name` field)
- [ ] **V2: Hover tooltip** — Hovering a prompt with full metadata shows formatted tooltip with name, role, summary, etc.
- [ ] **V3: Plain prompt (no frontmatter)** — A `.md` file with no `---` block shows no tooltip and no error; renders as plain filename
- [ ] **V4: YAML error** — A prompt with `---` block missing a required field (e.g. no `role`) shows `YAML error: required fields missing` in tooltip
- [ ] **V5: Security notice** — A prompt body containing `"jailbreak"` shows `⚠ Risky: "jailbreak"` at top of tooltip (and still opens normally with `.warning`)
- [ ] **V6: Deprecated** — A prompt with `deprecated: true` renders greyed out in menu; tooltip ends with `Deprecated — use a newer version`
- [ ] **V7: No emoji in menu** — Menu item labels contain no emoji prefix characters
- [ ] **V8: Production fields** — A prompt with `compatible_with`, `tags`, `input_variables` shows them in tooltip's production group
- [ ] **V9: Siri/Shortcuts** — In System Settings → Siri & Spotlight → Shortcuts, the prompt summary (not the filename) appears as the subtitle for Gemini Desktop prompt entities
