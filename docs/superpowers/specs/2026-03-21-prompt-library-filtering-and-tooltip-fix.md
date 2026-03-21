# Prompt Library Filtering & Tooltip Fix — Design Spec

**Goal:** Hide non-prompt markdown files (README.md, YAML-schema.md, prompt-structure.md) from the Prompts dropdown menu, and fix the `.help()` tooltip that is completely silent on hover for prompt menu items.

**Architecture:** Two independent changes to the existing Prompts subsystem. Filtering is additive — a `parseHiddenFlag` method on `PromptMetadata` + filtering in `PromptLibrary.buildTree()`. Tooltip fix is a one-line Button form change in `PromptsMenuButton.swift`. No new files created in the app bundle beyond a schema field addition.

**Tech Stack:** Swift, SwiftUI, Yams (existing), macOS 14+.

**Scope:** Filtering applies to all `.md` files in the user's Prompts directory. Tooltip fix applies to all menu items that have tooltip content.

---

## Background

The Prompts directory contains documentation files alongside prompt files. `PromptLibrary.buildTree()` currently includes every `.md` file, so YAML-schema.md, prompt-structure.md, and README.md appear as selectable menu items — which is unintended.

The `.help()` tooltip modifier is applied to prompt menu buttons but never displays. Root cause: SwiftUI does not forward `.help()` to `NSMenuItem.toolTip` when the `Button` uses a custom content label (`Button(action:) { Text() }`). The string-label form (`Button(title, action:)`) does forward correctly. This matches the pattern already used by the non-tooltip branch (line 49–50 of `PromptsMenuButton.swift`), which is verified working.

---

## Feature A: File Filtering

### Two-level filtering in `PromptLibrary.buildTree()`

Both levels exclude files from **both** `allFiles` and `filesByParent` — hidden files do not appear in the menu or in the Siri/Shortcuts `allFiles` list. Documentation files are not useful as Siri shortcut targets.

**Level 1 — README.md (before file load):**

Skip any `.md` file whose filename (case-insensitive) is `readme.md` before calling `PromptFile.load()`. This avoids unnecessary file I/O.

```swift
guard url.lastPathComponent.lowercased() != "readme.md" else { continue }
```

Place this guard immediately after the `url.pathExtension.lowercased() == "md"` check, before `PromptFile.load(from: url)`.

**Level 2 — `hidden: true` (after file load):**

`PromptFile.load()` calls a new `PromptMetadata.parseHiddenFlag(from:)` static method that parses only the `hidden` key from the YAML frontmatter — independent of required-field validation.

```swift
let file = PromptFile.load(from: url)
guard !file.isHiddenFlag else { continue }
// Both appends happen after this guard:
filesByParent[parent, default: []].append(file)
allFiles.append(file)
```

Place the `guard` before both `filesByParent` and `allFiles` appends so hidden files are excluded from everything.

### `PromptMetadata.parseHiddenFlag(from:) -> Bool`

New static method on `PromptMetadata`. Extracts the YAML frontmatter block and checks for `hidden: true`. Returns `false` for any file without a `---` block, with malformed YAML, or without the `hidden` key. Only `hidden: true` (boolean) returns `true` — a string `"true"` or any other value returns `false`.

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

New stored property on `PromptFile` with a **default value of `false`**:

```swift
let isHiddenFlag: Bool = false
```

The default value ensures the error-path initializer in `PromptFile.load()` (the `catch` branch) compiles without changes — Swift's memberwise initializer uses the default when the argument is omitted.

Set in the success path of `PromptFile.load()`:

```swift
let isHiddenFlag = content.hasPrefix("---")
    ? PromptMetadata.parseHiddenFlag(from: content)
    : false
```

Include `isHiddenFlag: isHiddenFlag` in the success-path `PromptFile(...)` initializer call.

The `Equatable` conformance (`==` comparing `url` and `body`) is intentionally unchanged — `isHiddenFlag` is not part of prompt identity, and the directory watcher triggers a full rebuild on any change.

### `hidden` field in `Resources/prompt-schema-v1.json`

`Resources/prompt-schema-v1.json` exists at that path in the app bundle (added in a previous session). Add `hidden` as an optional boolean field in the `properties` object:

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

No required fields needed — `parseHiddenFlag` is intentionally independent of required-field validation.

`~/Documents/Prompts/prompt-schema-v1.json` is updated to match the bundle schema (copy of `Resources/prompt-schema-v1.json`).

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

Use the string-label form. This matches the existing non-tooltip branch (lines 49–50), which is already in production:

```swift
Button(file.displayTitle, action: { handleSelection(file) })
    .foregroundStyle(isDeprecated ? Color.secondary : Color.primary)
    .help(tooltip.formatted())
```

The `.foregroundStyle` modifier moves from the `Text` to the `Button`. This is the only place in `PromptsMenuButton.swift` that uses the custom-content Button form.

---

## Testing

Unit tests for `PromptMetadata.parseHiddenFlag(from:)`:

| Input | Expected |
|---|---|
| Content with no `---` block | `false` |
| `---\nname: foo\n---` (no `hidden` key) | `false` |
| `---\nhidden: false\n---` | `false` |
| `---\nhidden: true\n---` | `true` |
| `---\nhidden: "true"\n---` (string, not bool) | `false` |
| `---\n{malformed yaml\n---` | `false` |
| `---\nhidden: true\nname: Foo\n---` (extra fields) | `true` |

---

## Files Changed

| Action | File | What |
|---|---|---|
| Modify | `Prompts/PromptMetadata.swift` | Add `parseHiddenFlag(from:) -> Bool` static method |
| Modify | `Prompts/PromptFile.swift` | Add `isHiddenFlag: Bool = false` stored property; set in `load()` success path |
| Modify | `Prompts/PromptLibrary.swift` | Skip `readme.md` before load; skip `isHiddenFlag` after load (before both appends) |
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
- Updating `YAML-schema.md` documentation content to describe the new `hidden` field (the file will be hidden anyway; the architect prompt carries the schema reference)
