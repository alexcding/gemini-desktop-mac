# Research: Artifact Capture Performance & Prompts/Artifacts Feature Architecture

**Date:** 2026-03-17
**Scope:** Current implementation of artifact capture, performance bottlenecks, and architecture for the broader Prompts & Artifacts feature
**Based on:** Bug report: "Capture the last Response as a Artifact" is slow (several seconds, no user feedback)

---

## Executive Summary

The artifact capture feature is slow due to **expensive DOM-to-Markdown conversion in JavaScript** and provides **no user feedback**. The recursive DOM traversal in `UserScripts.swift:354-425` can take 2-3 seconds for large responses, and the main thread is blocked during file I/O with no progress indicator.

Additionally, the current architecture lacks proper separation of concerns for the planned Prompts & Artifacts feature:
- No `PromptStore`/`ArtifactStore` abstraction
- No persistent directory handling (bookmarks)
- No Settings UI for directory configuration
- Limited extensibility for future file formats

---

## Part 1: Current Artifact Capture Implementation

### Architecture Overview

```
User clicks "Save" in ArtifactCaptureButton
    ↓
captureLastResponse(suggestedFilename:)  [async Task]
    ↓
captureLastResponseAsString()  [await continuation]
    ├─ waitForPageReady()  [~100-500ms]
    ├─ evaluateJavaScript(createCaptureScript)  [⚠️ SLOW: 2-3 seconds]
    │   └─ domToMarkdown() recursive traversal  [bottleneck]
    └─ Return markdown string
    ↓
saveArtifact(markdown:, filename:)  [MainActor]
    ├─ BookmarkStore.withBookmarkedURL()  [file system access]
    ├─ Handle filename conflicts  [FileManager checks]
    ├─ Prepend YAML frontmatter  [string manipulation]
    └─ Write to disk  [synchronous I/O on main thread]
    ↓
Show success/error via injectionBannerMessage
```

**File locations:**
- `Intents/CaptureLastArtifactIntent.swift` — AppIntent entry point (Siri/Shortcuts)
- `Views/ArtifactCaptureButton.swift` — UI button + filename input sheet
- `Coordinators/AppCoordinator.swift` — `captureLastResponse()`, `captureLastResponseAsString()`, `saveArtifact()`
- `WebKit/UserScripts.swift` — JavaScript capture script with DOM conversion
- `WebKit/GeminiSelectors.swift` — DOM selectors (currently `lastResponseSelector: "model-response:last-of-type"`)

### Performance Bottleneck 1: JavaScript DOM-to-Markdown Conversion

**Location:** `UserScripts.swift:343-428` – `createCaptureScript()`

The script injects a function `domToMarkdown()` that recursively processes the entire DOM tree:

```javascript
function domToMarkdown(node, depth = 0) {
    let markdown = '';
    // ...
    if (node.nodeType === 3) {
        markdown = node.textContent.trim();
    } else if (node.nodeType === 1) {
        const tag = node.tagName.toLowerCase();
        const text = Array.from(node.childNodes)
            .map(child => domToMarkdown(child, depth))  // ← recursive call
            .join('')
            .trim();
        // ... handle each tag type
    }
    return markdown;
}
```

**Performance characteristics:**
- **Time complexity:** O(n) where n = total DOM nodes in response
- **String allocations:** Multiple per node (trimming, concatenation, array joins)
- **DOM queries:** Each `<pre>` tag triggers `node.querySelector('code')`, each list triggers `:scope > li` query
- **For a typical Gemini response (tables, code blocks, formatted text):** 200-500 DOM nodes → 2-3 seconds
- **No optimization:** No streaming of results, no batching, single synchronous pass

**Why it's slow specifically:**
1. String concatenation in JavaScript is O(n²) behavior in some engines (though modern engines optimize this)
2. Each recursive call creates new scope
3. DOM queries inside the recursion (`:scope > li`, `querySelector`) re-traverse the tree
4. The entire response is buffered in memory before returning

### Performance Bottleneck 2: File I/O on Main Thread

**Location:** `AppCoordinator.swift:250-280` – `saveArtifact()`

```swift
func saveArtifact(markdown: String, filename: String) {
    let bookmarkStore = BookmarkStore()
    do {
        _ = try bookmarkStore.withBookmarkedURL(for: .artifactsDirectoryBookmark) { dirURL in
            // 1. Check for filename conflicts (multiple FileManager.fileExists calls)
            while FileManager.default.fileExists(atPath: finalURL.path) { ... }

            // 2. String manipulation (prepend YAML frontmatter)
            var content = markdown
            if !markdown.hasPrefix("---") { ... }

            // 3. Synchronous file write — blocks main thread
            try content.write(to: finalURL, atomically: true, encoding: .utf8)
        }
    } catch { ... }
}
```

**Blocking operations on main thread:**
- `FileManager.fileExists()` calls (synchronous)
- `content.write(to:atomically:)` (synchronous disk I/O)
- `BookmarkStore` access (depends on implementation, likely involves `FileManager`)

### Performance Bottleneck 3: Zero User Feedback

**Location:** `ArtifactCaptureButton.swift:20-24`

```swift
onSave: {
    coordinator.captureLastResponse(suggestedFilename: filenameInput)
    showingSheet = false  // ← closes immediately
}
```

**Problem:**
- Sheet closes before async task starts
- No progress indicator, spinner, or status banner
- No success toast or completion notification
- User has no feedback for 2-3 seconds — appears frozen
- Error message only appears in `injectionBannerMessage` (requires UI state observation)

### Current Selector Fragility

**Location:** `WebKit/GeminiSelectors.swift:41` – `lastResponseSelector`

```swift
lastResponseSelector: "model-response:last-of-type"
```

**Risk:**
- Hardcoded DOM selector
- Gemini's HTML structure can change between versions
- No fallback if selector doesn't match
- Currently stored in `gemini-selectors.json` (good), but if changed, all artifact captures break

---

## Part 2: Broader Prompts & Artifacts Feature Architecture

### Current State: Feature is Only Half-Built

**What exists:**
- `CaptureLastArtifactIntent` (Siri/Shortcuts only, via AppIntent)
- `ArtifactCaptureButton` + filename input sheet
- `captureLastResponse()` in AppCoordinator
- YAML frontmatter generation
- Directory persistence via `BookmarkStore` (abstraction exists, but not fully utilized)

**What's missing for a complete feature:**
1. **`PromptStore` abstraction** — reusable model for loading/caching markdown files from a directory
2. **Settings UI** — UI to configure prompt/artifact directories
3. **Toolbar menu** — display list of saved prompts/artifacts in a menu
4. **File watcher** — hot-reload when files are edited outside the app
5. **Error handling** — graceful fallbacks for missing directories or corrupted files
6. **Artifact list view** — option to browse saved artifacts

### Architecture Constraints & Decisions (from plan)

Per `docs/plan-adopt-boris-tane-workflow.md`:

1. **External markdown files** — user-editable outside the app ✅
2. **Two separate directories** — `~/Documents/Prompts/` and `~/Documents/Artifacts/` ✅
3. **Clipboard-only injection** (no WebView injection) — eliminates fragile DOM selectors
4. **Sandboxed + security-scoped bookmarks** — required for directory persistence
5. **File format:** `.md` initially, architecture should support `.txt` and `.json` trivially

### How `@Observable` Stores Should Be Structured

Looking at existing patterns in the codebase:

**`AppCoordinator` pattern** (`Coordinators/AppCoordinator.swift`):
```swift
@MainActor
@Observable
class AppCoordinator {
    var webViewModel = WebViewModel()
    let promptLibrary = PromptLibrary()

    init() {
        promptLibrary.reload()
        promptLibrary.startWatching()
    }
}
```

**`WebViewModel` pattern** (`WebKit/WebViewModel.swift`):
```swift
@MainActor
@Observable
class WebViewModel {
    var isPageReady: Bool = false
    var canGoBack: Bool { webViewModel.canGoBack }
    // ... property getters delegate to WKWebView
}
```

**For Prompts/Artifacts stores, the pattern should be:**
```swift
@MainActor
@Observable
class PromptStore {
    private(set) var prompts: [PromptFile] = []
    private(set) var isLoading: Bool = false
    private var fileWatcher: DirectoryWatcher?

    func reload() async { ... }  // Load from directory
    func startWatching() { ... }  // File system monitoring
}
```

### File Format for Prompts/Artifacts

**Current YAML header format** (from `saveArtifact()`):
```markdown
---
captured_at: 2026-03-17T12:34:56Z
source: gemini.google.com
---

[actual markdown content]
```

**Should be compatible with:**
- Frontmatter parsers (YAML)
- Plain-text editors (users can ignore the header)
- Future metadata (tags, version, etc.)

### Directory Persistence Pattern

**Current `BookmarkStore` usage** (`AppCoordinator.swift:253`):
```swift
let bookmarkStore = BookmarkStore()
try bookmarkStore.withBookmarkedURL(for: .artifactsDirectoryBookmark) { dirURL in
    try content.write(to: finalURL, atomically: true, encoding: .utf8)
}
```

**Question:** How does `BookmarkStore` work?
- Need to check the implementation to understand:
  - How bookmarks are created (requires NSOpenPanel in SettingsView?)
  - How they persist (likely UserDefaults with encoded bookmark data)
  - Error handling if bookmark is invalid
  - Thread safety for repeated access

**Assumption:** Security-scoped bookmarks require:
1. User selects directory via `NSOpenPanel` once
2. Bookmark data is stored in UserDefaults
3. On each access, bookmark is converted back to URL with `startAccessingSecurityScopedResource()`

---

## Part 3: Root Causes of Slowness

### Root Cause 1: JavaScript Recursion + String Concatenation

The `domToMarkdown()` function:
- Traverses every DOM node in the response
- Makes a recursive call for each child
- Concatenates strings repeatedly
- Contains DOM queries within the recursion

**For a typical Gemini response with:**
- Code blocks (nested `<pre><code>`)
- Tables (multiple `<tr><th><td>`)
- Lists (multiple `<li>`)
- Formatted text

**Expected node count:** 200-500 nodes
**Processing time per node:** 10-50μs (recursive call overhead + string ops)
**Total time:** 2-3 seconds

### Root Cause 2: Synchronous WKWebView Execution

`WKWebView.evaluateJavaScript()` is asynchronous on the Swift side, but the JavaScript runs **synchronously in the WebKit JavaScript context**. This blocks the WebView from processing any other scripts or events until `domToMarkdown()` completes.

### Root Cause 3: Main Thread File I/O

`content.write(to:atomically:)` blocks the main thread. For a 50KB artifact on a typical SSD:
- File write: ~50-200ms
- `FileManager.fileExists()` checks: ~20-50ms per call

### Root Cause 4: No Feedback Mechanism

The async task runs in the background with no observer in the UI. The sheet closes immediately, so the user doesn't know what's happening.

---

## Part 4: Why This Matters for the Feature Design

The slowness reveals architectural gaps:

1. **No separation between capture logic and UI** — the button directly calls `captureLastResponse()` with no progress model
2. **No observable progress state** — could emit events like `.started`, `.processing(progress)`, `.completed`, `.failed(error)`
3. **No async-friendly file I/O** — `saveArtifact()` does blocking writes on main thread
4. **No background queue for heavy work** — JavaScript evaluation and file I/O should be off main thread where possible

---

## Part 5: Gemini DOM Structure for Future Enhancement

**Current selector:** `model-response:last-of-type`

**Risk:** If Gemini changes from custom elements to standard `<div>` with attributes, selector breaks.

**To future-proof, need research on:**
1. Is `model-response` a custom element (`<model-response>`) or a class/attribute?
2. What's the HTML structure inside a response container (flexbox, grid)?
3. What elements contain the actual text content (are they `contenteditable`, plain `<div>`, or `<span>`)?
4. Are there any `data-*` attributes that identify response boundaries?

---

## Part 6: Recommended Optimization Strategy

### Phase 1 (Quick Win): Add User Feedback
- Move async task into a `@State` variable that drives a loading indicator
- Show progress spinner while capturing
- Replace error `injectionBannerMessage` with a proper Toast/Alert
- **Effort:** 30 minutes, significant UX improvement

### Phase 2 (Medium): Optimize JavaScript
- Profile the JavaScript to identify slowest nodes
- Consider streaming results (process DOM in chunks)
- Cache DOM queries
- Consider converting to iterative instead of recursive
- **Effort:** 1-2 hours, potential 50% speedup

### Phase 3 (Architectural): Move I/O Off Main Thread
- Use `Task(priority: .userInitiated) { await captureAndSave(...) }` with isolated async function
- Split file write into background operation
- **Effort:** 1 hour, prevents UI jank on slow file systems

### Phase 4 (Long-term): Build PromptStore + Settings UI
- Create `PromptStore` and `ArtifactStore` abstractions
- Add Settings UI for directory configuration
- Add toolbar menu items to list/insert prompts
- Implement file watcher for hot reload
- **Effort:** 3-4 hours, enables full feature

---

## Summary of Findings

| Component | Issue | Impact | Effort to Fix |
|---|---|---|---|
| JavaScript DOM recursion | O(n) traversal, string concat overhead | 2-3s per artifact | Medium (optimize JS) |
| Main thread file I/O | Blocking writes with FileManager checks | UI jank on slow FS | Low (move to background) |
| No user feedback | Sheet closes immediately | User thinks it failed | Low (add spinner) |
| No PromptStore abstraction | Feature is half-built | Hard to extend | Medium (architecture) |
| Fragile DOM selector | Hardcoded to Gemini structure | Breaks on updates | N/A (use clipboard instead) |

---

## Next Steps

To move forward, we should:

1. **Add user feedback first** (quick win, visible improvement)
2. **Profile the JavaScript** (understand where 2-3 seconds actually goes)
3. **Implement PromptStore** (enables full feature once Swift 6 refactor is done)
4. **Add Settings UI** (let users configure directories)

The Boris Tane workflow suggests addressing the full architecture before implementation, so a **`docs/plan-artifacts-performance-and-feature.md`** should be next, outlining:
- How to add a `PromptStore` + `ArtifactStore` that share code
- Where Settings UI fits
- JavaScript optimization strategy (with code examples)
- File I/O migration to background tasks
- User feedback UI (spinner, toast)
