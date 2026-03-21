# Prompt Library Filtering & Tooltip Fix — Design Spec

**Goal:** Hide non-prompt markdown files (README.md, YAML-schema.md, prompt-structure.md) from the Prompts dropdown menu, and fix the `.help()` tooltip that is completely silent on hover for prompt menu items.

**Architecture:** Two independent changes to the existing Prompts subsystem. Filtering is additive — a `parseHiddenFlag` method on `PromptMetadata` + filtering in `PromptLibrary.buildTree()`. Tooltip fix is a one-line Button form change in `PromptsMenuButton.swift`. No new files created in the app bundle beyond a schema field addition.

**Tech Stack:** Swift, SwiftUI, Yams (existing), macOS 14+.

**Scope:** Filtering applies to all `.md` files in the user's Prompts directory. Tooltip fix applies to all menu items that have tooltip content.

---

## Background

The Prompts directory contains documentation files alongside prompt files. `PromptLibrary.buildTree()` currently includes every `.md` file, so YAML-schema.md, prompt-structure.md, and README.md appear as selectable menu items — which is unintended.

The `.help()` tooltip modifier is applied to prompt menu buttons but never displays. Root cause: SwiftUI does not forward `.help()` to `NSMenuItem.toolTip` when the `Button` uses a custom content label (`Button(action:) { Text() }`). The string-label form (`Button(title, action:)`) does forward correctly.

---

## Feature A: File Filtering

### Two-level filtering in `PromptLibrary.buildTree()`

**Level 1 — README.md (before file load):**

Skip any `.md` file whose filename (case-insensitive) is `readme.md` before calling `PromptFile.load()`. This avoids unnecessary file I/O for a universally understood doc convention.

```swift
guard url.lastPathComponent.lowercased() != "readme.md" else { continue }
```

**Level 2 — `hidden: true` (after file load):**

`PromptFile.load()` calls a new `PromptMetadata.parseHiddenFlag(from:)` static method that parses only the `hidden` key from the YAML frontmatter — independent of required-field validation. Files with `hidden: true` are excluded from the tree regardless of whether the rest of their YAML is valid.

```swift
guard !file.isHiddenFlag else { continue }
```

### `PromptMetadata.parseHiddenFlag(from:) -> Bool`

New static method on `PromptMetadata`. Extracts the YAML frontmatter block and checks for `hidden: true`. Returns `false` for any file without a `---` block, with malformed YAML, or without the `hidden` key.

```swift
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

### `PromptFile.isHiddenFlag: Bool`

New stored property on `PromptFile`. Set in `PromptFile.load()` by calling `PromptMetadata.parseHiddenFlag(from: content)`. Only computed when the file has a `---` prefix (same guard used for metadata parsing).

### `hidden` field in `prompt-schema-v1.json`

Add `hidden` as an optional boolean field. This registers it in the schema for VS Code validation and the Prompt Architect.

```json
"hidden": {
  "type": "boolean",
  "description": "When true, the file is excluded from the Gemini Desktop Prompts menu. Use for documentation files stored in the prompt library directory."
}
```

### YAML frontmatter for doc files

`~/Documents/Prompts/YAML-schema.md` and `~/Documents/Prompts/prompt-structure.md` each get this minimal frontmatter prepended:

```yaml
---
hidden: true
---
```

No required fields needed — `parseHiddenFlag` is intentionally independent of required-field validation. The files are excluded before they are ever added to the tree.

`~/Documents/Prompts/prompt-schema-v1.json` is updated to match the bundle schema.

---

## Feature B: Tooltip Fix

### Root cause

In SwiftUI on macOS, `.help()` maps to `NSMenuItem.toolTip`. This forwarding only works reliably when the `Button` uses the string-label initializer. The custom-content initializer (`Button(action:) { Text() }`) does not forward `.help()` to the underlying `NSMenuItem`.

Current broken form in `PromptsMenuButton.fileMenuButton(for:)`:

```swift
Button(action: { handleSelection(file) }) {
    Text(file.displayTitle)
        .foregroundStyle(isDeprecated ? Color.secondary : Color.primary)
}
.help(tooltip.formatted())
```

### Fix

Use the string-label form, matching the pattern used by non-tooltip buttons:

```swift
Button(file.displayTitle, action: { handleSelection(file) })
    .foregroundStyle(isDeprecated ? Color.secondary : Color.primary)
    .help(tooltip.formatted())
```

The `.foregroundStyle` modifier moves from the `Text` to the `Button`, which is equivalent for this use case.

---

## Files Changed

| Action | File | What |
|---|---|---|
| Modify | `Prompts/PromptMetadata.swift` | Add `parseHiddenFlag(from:) -> Bool` static method |
| Modify | `Prompts/PromptFile.swift` | Add `isHiddenFlag: Bool` stored property; set in `load()` |
| Modify | `Prompts/PromptLibrary.swift` | Skip `readme.md` before load; skip `isHiddenFlag` after load |
| Modify | `Views/PromptsMenuButton.swift` | Fix Button form to use string-label initializer |
| Modify | `Resources/prompt-schema-v1.json` | Add `hidden` boolean field |
| Modify | `~/Documents/Prompts/prompt-schema-v1.json` | Update local copy to match bundle |
| Modify | `~/Documents/Prompts/YAML-schema.md` | Prepend `hidden: true` frontmatter |
| Modify | `~/Documents/Prompts/prompt-structure.md` | Prepend `hidden: true` frontmatter |

---

## Out of Scope

- Hiding directories (no use case yet)
- A UI to manage hidden files
- Persisting hidden state to UserDefaults
- Applying `hidden` to the Intents/Shortcuts system (hidden files remain available to `allFiles` for Siri/Shortcuts — only the menu tree excludes them)
- Updating `YAML-schema.md` documentation content to describe the new `hidden` field (the file will be hidden anyway; the architect prompt carries the schema reference)
