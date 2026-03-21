# Prompt Library Filtering & Tooltip Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide non-prompt markdown files (README.md, YAML-schema.md, prompt-structure.md) from the Prompts dropdown, and fix the `.help()` tooltip that never displays on hover.

**Architecture:** Two independent changes. (A) `PromptMetadata` gets a `parseHiddenFlag(from:)` static method; `PromptFile` gets an `isHiddenFlag` stored property; `PromptLibrary.buildTree()` filters README.md before load and `isHiddenFlag` files after load. (B) The `Button` form in `PromptsMenuButton.fileMenuButton(for:)` changes from custom-content to string-label so SwiftUI forwards `.help()` to `NSMenuItem.toolTip`. No new Swift files.

**Tech Stack:** Swift, SwiftUI, Yams (existing dependency), Xcode 15+, macOS 14+.

---

## Context for Implementers

macOS Xcode project at `/Users/zmarkley/src/github.com/alexcding/gemini-desktop-mac`.

**Build command** (run after every Swift change):
```bash
cd /Users/zmarkley/src/github.com/alexcding/gemini-desktop-mac
xcodebuild -project GeminiDesktop.xcodeproj -scheme GeminiDesktop build 2>&1 | grep -E "error:|BUILD" | tail -5
```
Expected: `** BUILD SUCCEEDED **`

**IMPORTANT:** SourceKit (the IDE language server) reports false "Cannot find type" errors even when the build succeeds. Always trust `xcodebuild` output — never act on SourceKit diagnostics alone.

**Spec:** `docs/superpowers/specs/2026-03-21-prompt-library-filtering-and-tooltip-fix.md`

**Key files:**
- `Prompts/PromptMetadata.swift` — YAML frontmatter parsing
- `Prompts/PromptFile.swift` — per-file struct, `load()` entry point
- `Prompts/PromptLibrary.swift` — directory scan and tree building
- `Views/PromptsMenuButton.swift` — SwiftUI menu button rendering
- `Resources/prompt-schema-v1.json` — JSON Schema for YAML validation

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `Prompts/PromptMetadata.swift` | Modify | Add `parseHiddenFlag(from:) -> Bool` static method |
| `Prompts/PromptFile.swift` | Modify | Add `isHiddenFlag: Bool = false` stored property; set in `load()` |
| `Prompts/PromptLibrary.swift` | Modify | Skip `readme.md` before load; skip `isHiddenFlag` after load (before both appends) |
| `Views/PromptsMenuButton.swift` | Modify | Fix Button form from custom-content to string-label |
| `Resources/prompt-schema-v1.json` | Modify | Add `hidden` boolean field |
| `~/Documents/Prompts/prompt-schema-v1.json` | Shell copy | Update local copy to match bundle |
| `~/Documents/Prompts/YAML-schema.md` | Modify | Prepend `hidden: true` frontmatter |
| `~/Documents/Prompts/prompt-structure.md` | Modify | Prepend `hidden: true` frontmatter |

---

## Task 1: Add `parseHiddenFlag` to PromptMetadata

**Files:**
- Modify: `Prompts/PromptMetadata.swift`

This is a pure static method — zero side effects. Add it as a new `// MARK: - Hidden flag` section after the existing `// MARK: - Body extraction` section.

- [ ] **Step 1.1: Add the method**

Open `Prompts/PromptMetadata.swift`. After the closing `}` of `extractBody(from:)` (around line 134), add:

```swift
    // MARK: - Hidden flag

    /// Returns true only if the YAML frontmatter contains `hidden: true` (boolean).
    /// Independent of required-field validation — a file can have only `hidden: true`
    /// and nothing else and still return true. Returns false for any file without a
    /// `---` block, malformed YAML, missing key, or `hidden: "true"` (string).
    static func parseHiddenFlag(from content: String) -> Bool {
        let lines = content.components(separatedBy: .newlines)
        guard lines.count > 2, lines[0] == "---" else { return false }
        var endIndex = -1
        for i in 1..<lines.count {
            if lines[i] == "---" { endIndex = i; break }
        }
        guard endIndex > 1 else { return false }
        let yamlContent = lines[1..<endIndex].joined(separator: "\n")
        guard let decoded = try? Yams.load(yaml: yamlContent) as? [String: Any] else { return false }
        return decoded["hidden"] as? Bool == true
    }
```

- [ ] **Step 1.2: Build**

```bash
xcodebuild -project GeminiDesktop.xcodeproj -scheme GeminiDesktop build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 1.3: Manual verification of test cases**

No XCTest target exists in this project yet. Verify these cases mentally/by inspection against the implementation:

| Input | Expected |
|---|---|
| Content with no `---` block | `false` — `guard lines[0] == "---"` fails |
| `---\nname: foo\n---` | `false` — no `hidden` key in dict |
| `---\nhidden: false\n---` | `false` — `decoded["hidden"] as? Bool == true` is false |
| `---\nhidden: true\n---` | `true` |
| `---\nhidden: "true"\n---` | `false` — `as? Bool` fails for String |
| `---\n{malformed\n---` | `false` — Yams throws, guard returns false |
| `---\nhidden: true\nname: Foo\n---` | `true` — extra fields are ignored |

- [ ] **Step 1.4: Commit**

```bash
git add Prompts/PromptMetadata.swift
git commit -m "feat: add parseHiddenFlag to PromptMetadata for library filtering"
```

---

## Task 2: Add `isHiddenFlag` to PromptFile + filtering in PromptLibrary

**Files:**
- Modify: `Prompts/PromptFile.swift` (lines ~113–201)
- Modify: `Prompts/PromptLibrary.swift` (lines ~65–82)

- [ ] **Step 2.1: Add `isHiddenFlag` stored property to PromptFile**

In `Prompts/PromptFile.swift`, find the `struct PromptFile` definition (around line 113). Add `isHiddenFlag` after `scanResult`:

```swift
struct PromptFile: Identifiable, Equatable {
    let url: URL
    let metadata: PromptMetadata?
    let yamlParseError: Bool
    let body: String
    let scanResult: ScanResult
    let isHiddenFlag: Bool = false  // ← add this line
```

The `= false` default value is required. Swift's synthesized memberwise initializer generates `isHiddenFlag: Bool = false` as an optional parameter, so the catch-path initializer in `load()` (lines 187–195) compiles unchanged without modification.

- [ ] **Step 2.2: Set `isHiddenFlag` in `load()` success path**

In the same file, find `PromptFile.load(from:)` (around line 166). Before the `return PromptFile(...)` call in the success path, compute the flag:

```swift
// Compute hidden flag (independent of metadata parsing)
let isHiddenFlag = content.hasPrefix("---")
    ? PromptMetadata.parseHiddenFlag(from: content)
    : false
```

Then add `isHiddenFlag: isHiddenFlag` to the success-path `PromptFile(...)` initializer:

```swift
return PromptFile(
    url:            url,
    metadata:       metadata,
    yamlParseError: yamlParseError,
    body:           body,
    scanResult:     scanResult,
    isHiddenFlag:   isHiddenFlag    // ← add this line
)
```

The catch-path initializer (lines 187–195) does NOT need to change — it omits `isHiddenFlag` and uses the default `false`.

- [ ] **Step 2.3: Build (verify PromptFile changes compile)**

```bash
xcodebuild -project GeminiDesktop.xcodeproj -scheme GeminiDesktop build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2.4: Add filtering to `PromptLibrary.buildTree()`**

In `Prompts/PromptLibrary.swift`, find the `buildTree(at:)` method. The relevant section (around lines 65–82) currently looks like:

```swift
for case let url as URL in enumerator {
    do {
        let values = try url.resourceValues(forKeys: resourceKeys)
        guard let isDir = values.isDirectory else { continue }

        if isDir {
            continue
        } else if url.pathExtension.lowercased() == "md" {
            let file = PromptFile.load(from: url)
            let parent = url.deletingLastPathComponent()
            filesByParent[parent, default: []].append(file)
            allFiles.append(file)
        }
    } catch {
        continue
    }
}
```

Replace the `else if` block with:

```swift
        } else if url.pathExtension.lowercased() == "md" {
            // Level 1: skip README.md before load (no I/O needed)
            guard url.lastPathComponent.lowercased() != "readme.md" else { continue }
            let file = PromptFile.load(from: url)
            // Level 2: skip files marked hidden: true in YAML
            guard !file.isHiddenFlag else { continue }
            let parent = url.deletingLastPathComponent()
            filesByParent[parent, default: []].append(file)
            allFiles.append(file)
        }
```

Both guards skip the file from `allFiles` AND `filesByParent` — hidden files do not appear in the menu or in Siri/Shortcuts.

- [ ] **Step 2.5: Build**

```bash
xcodebuild -project GeminiDesktop.xcodeproj -scheme GeminiDesktop build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2.6: Commit**

```bash
git add Prompts/PromptFile.swift Prompts/PromptLibrary.swift
git commit -m "feat: add isHiddenFlag to PromptFile and filter hidden/README files from library"
```

---

## Task 3: Fix Tooltip Button Form in PromptsMenuButton

**Files:**
- Modify: `Views/PromptsMenuButton.swift` (lines ~38–52)

The fix: change the tooltip branch's `Button` from custom-content form to string-label form. This matches the existing non-tooltip branch (lines 49–50), which is already verified to work.

- [ ] **Step 3.1: Fix the Button form**

In `Views/PromptsMenuButton.swift`, find `fileMenuButton(for:)`. The current tooltip branch (lines 42–47):

```swift
if let tooltip = file.tooltipContent {
    Button(action: { handleSelection(file) }) {
        Text(file.displayTitle)
            .foregroundStyle(isDeprecated ? Color.secondary : Color.primary)
    }
    .help(tooltip.formatted())
```

Replace with:

```swift
if let tooltip = file.tooltipContent {
    Button(file.displayTitle, action: { handleSelection(file) })
        .foregroundStyle(isDeprecated ? Color.secondary : Color.primary)
        .help(tooltip.formatted())
```

- [ ] **Step 3.2: Build**

```bash
xcodebuild -project GeminiDesktop.xcodeproj -scheme GeminiDesktop build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3.3: Manual verification**

Run the app (`Cmd+R` in Xcode or launch from Applications). Open the Prompts menu. Hover over a prompt that has YAML metadata (e.g., `meta/prompt-architect`). Wait 2–3 seconds. A tooltip panel should appear showing the prompt name, role, and summary.

Expected: tooltip panel appears with structured metadata content.

- [ ] **Step 3.4: Commit**

```bash
git add Views/PromptsMenuButton.swift
git commit -m "fix: use string-label Button form to fix .help() tooltip forwarding to NSMenuItem"
```

---

## Task 4: Add `hidden` to `prompt-schema-v1.json` + Update Doc Files

**Files:**
- Modify: `Resources/prompt-schema-v1.json`
- Shell: copy to `~/Documents/Prompts/prompt-schema-v1.json`
- Modify: `~/Documents/Prompts/YAML-schema.md`
- Modify: `~/Documents/Prompts/prompt-structure.md`

- [ ] **Step 4.1: Add `hidden` field to `Resources/prompt-schema-v1.json`**

Open `Resources/prompt-schema-v1.json`. After the `"input_variables"` property block (the last property before the closing `}`), and after the three routing fields added in a previous session (`output_format`, `reasoning_trace`, `interaction_mode`), add a comma and:

```json
    "hidden": {
      "type": "boolean",
      "description": "When true, the file is excluded from the Gemini Desktop Prompts menu. Use for documentation files stored in the prompt library directory."
    }
```

The final three properties in `"properties"` will be: `..., "interaction_mode": {...}, "hidden": {...}`. The `"additionalProperties": true` line remains at the end.

- [ ] **Step 4.2: Validate JSON**

```bash
python3 -c "import json; json.load(open('Resources/prompt-schema-v1.json')); print('JSON valid')"
```

Expected: `JSON valid`

- [ ] **Step 4.3: Build**

```bash
xcodebuild -project GeminiDesktop.xcodeproj -scheme GeminiDesktop build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4.4: Commit the schema change**

```bash
git add Resources/prompt-schema-v1.json
git commit -m "feat: add hidden boolean field to prompt-schema-v1.json"
```

- [ ] **Step 4.5: Copy updated schema to local Prompts dir**

```bash
cp /Users/zmarkley/src/github.com/alexcding/gemini-desktop-mac/Resources/prompt-schema-v1.json \
   /Users/zmarkley/Documents/Prompts/prompt-schema-v1.json
```

- [ ] **Step 4.6: Prepend `hidden: true` frontmatter to YAML-schema.md**

Open `/Users/zmarkley/Documents/Prompts/YAML-schema.md`. Prepend these 3 lines at the very top (before line 1):

```
---
hidden: true
---

```

The file should begin with `---\nhidden: true\n---\n\n# Prompt YAML...`

- [ ] **Step 4.7: Prepend `hidden: true` frontmatter to prompt-structure.md**

Open `/Users/zmarkley/Documents/Prompts/prompt-structure.md`. Prepend the same 3 lines at the very top:

```
---
hidden: true
---

```

The file should begin with `---\nhidden: true\n---\n\n# Prompt Body...`

- [ ] **Step 4.8: Manual verification**

Run the app (`Cmd+R` in Xcode or launch from Applications). Open the Prompts menu. Verify:

1. `YAML-schema` does NOT appear in the menu (was previously visible at root)
2. `prompt-structure` does NOT appear in the menu (was previously visible at root)
3. `README` does NOT appear in the menu
4. All other prompts (engineering/, clinical/, meta/, etc.) still appear normally

No commit needed for steps 4.5–4.7 (files are outside the git repo).
