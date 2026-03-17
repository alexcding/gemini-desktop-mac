# Plan: Artifact Capture Performance Optimization — Path B (HTML→Markdown in Swift)

**Based on:** `docs/research-artifacts-capture-performance.md`
**Scope:** Fix slowness (2-3 seconds) and lack of user feedback in artifact capture
**Status:** The feature itself (Phases 1-6 of `plan-prompts-artifacts.md`) is complete. This plan only addresses performance.
**Approach:** Extract raw HTML from the response element in JavaScript (<100ms), then convert HTML to Markdown in Swift (off main thread, unit testable, 100x faster than current approach).

---

## Architecture Summary (Path B)

```
Current (Slow):
WKWebView.evaluateJavaScript(domToMarkdown recurse)  [2-3 seconds, blocks WebView]
    ↓
Swift: saveArtifact()

Optimized (Path B):
WKWebView.evaluateJavaScript(extract HTML)  [<100ms, returns HTML string]
    ↓
Task(priority: .userInitiated) { HTMLToMarkdown.convert(html) }  [100-500ms, background]
    ↓
Swift: saveArtifact()  [background task, no main thread blocking]

Total User-Perceived Time: ~500-800ms (vs. current 2-3 seconds)
```

---

## Problem Summary

The artifact capture feature works correctly but has poor UX:

1. **Slow capture** (2-3 seconds) due to expensive JavaScript DOM-to-Markdown recursion
2. **No user feedback** — sheet closes immediately, spinner/status missing
3. **File I/O blocks main thread** during save (FileManager checks + disk write)

See `docs/research-artifacts-capture-performance.md` for detailed root cause analysis.

---

## Architectural Design Question

**[ANNOTATION: Challenge from review — Clipboard vs. DOM contradiction**

The research document (`research-prompts-artifacts.md`, section 4) states the architectural goal:
> "Clipboard-only injection (no WebView injection). User pastes manually into Gemini. This eliminates the fragile DOM selector dependency entirely."

However, **artifact capture fundamentally requires DOM interaction** — we must extract the formatted response to preserve code blocks, tables, and formatting. The HTML-to-Markdown conversion is unavoidable.

**The question:** If the long-term vision is to move entirely to clipboard-based workflows, is building `HTMLToMarkdown.swift` (200+ lines) now throwaway work?

**Decision for this implementation:** Artifact capture MUST stay DOM-based for V1 (to preserve formatting). This optimization improves performance without changing that requirement. Path B is the right choice for artifact capture specifically. However, acknowledge that **if Gemini's HTML structure changes significantly**, this component may need redesign.

**For future consideration:** Could we use Gemini's export-to-markdown API (if it exists) instead of parsing the DOM? This would be the ultimate fix for fragility.]**

---

## Solution: Three Focused Optimizations

### Optimization 1: Add User Feedback (30-45 min)

**Goal:** Show loading spinner during capture, success/error toast on completion.

**Implementation:**

1. **`Coordinators/AppCoordinator.swift`** — Add observable progress state using pure Swift Concurrency:
   ```swift
   enum CaptureProgress {
       case started
       case converting
       case saving
       case completed(filename: String)
       case failed(error: String)
   }

   @MainActor
   @Observable
   class AppCoordinator {
       var captureProgress: CaptureProgress? = nil

       func captureLastResponse(suggestedFilename: String?) {
           Task {
               captureProgress = .started
               do {
                   captureProgress = .converting
                   let markdown = try await captureLastResponseAsString()

                   captureProgress = .saving
                   let filename = suggestedFilename ?? defaultArtifactFilename()
                   saveArtifact(markdown: markdown, filename: filename)

                   captureProgress = .completed(filename: filename)

                   // Use Task.sleep instead of DispatchQueue to avoid mixing GCD + Swift Concurrency
                   try await Task.sleep(for: .seconds(2))
                   self.captureProgress = nil
               } catch {
                   captureProgress = .failed(error: error.localizedDescription)

                   // Sleep before clearing error state
                   try? await Task.sleep(for: .seconds(3))
                   self.captureProgress = nil
               }
           }
       }
   }
   ```

**[NOTE: Fix concurrency anti-pattern — use `Task.sleep(for:)` instead of `DispatchQueue.main.asyncAfter` to avoid mixing GCD with Swift Concurrency in MainActor context.]**

2. **`Views/ArtifactCaptureButton.swift`** — Update UI to show progress:
   ```swift
   struct ArtifactCaptureButton: View {
       var coordinator: AppCoordinator
       @State private var showingSheet = false
       @State private var filenameInput = ""

       var body: some View {
           Button(action: { showingSheet = true }) {
               Image(systemName: "square.and.arrow.down.on.square")
           }
           .disabled(coordinator.captureProgress != nil)  // Disable while capturing
           .overlay(alignment: .bottom) {
               if coordinator.captureProgress != nil {
                   HStack(spacing: 8) {
                       ProgressView()
                           .scaleEffect(0.75)
                       Text(captureProgressLabel(coordinator.captureProgress))
                           .font(.caption)
                   }
                   .padding(8)
                   .background(.regularMaterial)
                   .cornerRadius(6)
                   .offset(y: 30)
               }
           }
           .sheet(isPresented: $showingSheet) {
               FilenameInputSheet(
                   isPresented: $showingSheet,
                   filename: $filenameInput,
                   onSave: {
                       coordinator.captureLastResponse(suggestedFilename: filenameInput)
                       showingSheet = false
                   }
               )
           }
       }

       private func captureProgressLabel(_ progress: CaptureProgress?) -> String {
           switch progress {
           case .started: return "Starting…"
           case .converting: return "Converting…"
           case .saving: return "Saving…"
           case .completed(let filename): return "Saved: \(filename)"
           case .failed(let error): return "Error: \(error)"
           case nil: return ""
           }
       }
   }
   ```

**Files modified:**
- `Coordinators/AppCoordinator.swift` — add `CaptureProgress` enum + progress state
- `Views/ArtifactCaptureButton.swift` — observe progress, show spinner + status

**No breaking changes to existing API.** The `captureLastResponse()` method continues to work identically.

---

### Optimization 2: HTML Extraction + Swift Markdown Conversion (Path B)

**Architecture:** Extract raw HTML from the response element in JavaScript (<100ms), then convert HTML to Markdown in Swift (off main thread, unit testable).

#### Step 2a: Minimal JavaScript Extraction

**File:** `WebKit/UserScripts.swift`

Replace `createCaptureScript()` to return only raw HTML:

```swift
nonisolated static func createCaptureScript(lastResponseSelector: String) -> String {
    return """
    (function() {
        // Check if still streaming — look for structural class, NOT localized aria-label
        // Gemini uses .streaming or data-streaming attribute on the response container
        // Fallback: look for any "Stop" button-like element in aria-label (language-agnostic contains check)
        const isStreaming = document.querySelector('[data-streaming="true"]')
            || Array.from(document.querySelectorAll('button[aria-label*="Stop"]')).length > 0;

        if (isStreaming) {
            return '__streaming__';
        }

        const el = document.querySelector('\(lastResponseSelector)');
        return el ? el.innerHTML : '';
    })();
    """
}
```

**[ANNOTATION: Streaming detection is language-fragile. Research the actual Gemini DOM structure for a streaming indicator (class, data attribute, or icon structure) that doesn't rely on localized text. Current fallback uses `aria-label*="Stop"` (substring match) which is slightly more robust but still not ideal.]**

**Benefits:**
- JavaScript execution: <100ms (nearly instantaneous)
- Does NOT block WKWebView's main thread
- Returns raw HTML string to Swift for processing

#### Step 2b: Swift Markdown Converter

**File:** `Utils/HTMLToMarkdown.swift` (new)

**CRITICAL DECISION: Do NOT implement a custom regex-based HTML parser.** HTML is not a regular language, and custom parsers inevitably break on edge cases (nested tags, malformed DOM, unescaped characters). This will cause silent content loss or crashes in production.

**Two Safe Approaches:**

**Option A: Use SwiftSoup (Recommended)**
Add `SwiftSoup` via SPM: https://github.com/scinfu/SwiftSoup
```swift
import SwiftSoup

enum HTMLToMarkdown {
    static func convert(_ html: String) -> String {
        do {
            let doc = try SwiftSoup.parse(html)
            return parseNode(doc.body() ?? doc).trimmingCharacters(in: .whitespaces)
        } catch {
            // Fallback: if parsing fails, return plaintext
            return html.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func parseNode(_ node: Node) -> String {
        // Traverse the parsed DOM tree, emit Markdown for each tag
        // SwiftSoup provides: `node.children()`, `node.tagName()`, `node.ownText()`, `node.attr(name)`
        // Implementation: recursive switch on tagName, handle all cases (h1-h6, p, strong, em, code, pre, ul/ol/li, a, blockquote, table, img, br)
        // ... (full implementation follows standard recursion pattern)
    }
}
```

**Option B: Use NSAttributedString (Zero Dependencies)**
```swift
import Foundation

enum HTMLToMarkdown {
    static func convert(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return "" }

        do {
            let attributed = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            )
            // Convert NSAttributedString back to Markdown
            // Iterate through attributes (font, bold, italic, link, attachment)
            // Emit Markdown equivalents
            return attributed.string.trimmingCharacters(in: .whitespaces)
        } catch {
            return html
        }
    }
}
```

**Recommendation: Use SwiftSoup** — it's the standard Swift HTML parser and handles Gemini's complex responses reliably. NSAttributedString loses structural information (tables, lists, code blocks render as plain text).

**[ANNOTATION: Choose between SwiftSoup (adds SPM dependency, robust) or NSAttributedString (zero dependencies, loses some formatting). Strongly recommend SwiftSoup for production quality.]**

### Handling Media & Edge Cases

Add handling for elements the parser will encounter:

```swift
private static func parseNode(_ node: Node) -> String {
    let tag = node.nodeName().lowercased()

    switch tag {
    case "h1": return "# \(nodeText(node))\n\n"
    case "h2": return "## \(nodeText(node))\n\n"
    // ... (other tags as before)
    case "img":
        // Extract alt text or URL
        let alt = (try? node.attr("alt")) ?? ""
        let src = (try? node.attr("src")) ?? ""
        return alt.isEmpty ? "![Image](\(src))" : "![\(alt)](\(src))"
    case "svg":
        // SVG elements can't be represented in Markdown
        // Option: extract embedded text, or skip with note
        return "[Chart/Diagram - not captured in Markdown]\n"
    case "br":
        return "\n"
    default:
        // For unrecognized tags, recurse into children
        return node.childNodes().map { parseNode($0) }.joined()
    }
}
```

#### Step 2c: Update AppCoordinator

**File:** `Coordinators/AppCoordinator.swift`

Modify `captureLastResponseAsString()` to use the two-step pipeline:

```swift
func captureLastResponseAsString() async throws -> String {
    try await waitForPageReady(timeout: 10)

    // Step 1: Extract raw HTML from the response element (fast, <100ms)
    let htmlString: String = try await withCheckedThrowingContinuation { continuation in
        let script = UserScripts.createCaptureScript(lastResponseSelector: GeminiSelectors.shared.lastResponseSelector)
        webViewModel.wkWebView.evaluateJavaScript(script) { result, error in
            if let error = error {
                continuation.resume(throwing: error)
            } else if let html = result as? String {
                if html == "__streaming__" {
                    continuation.resume(throwing: AppIntentError.stillStreaming)
                } else if html.isEmpty {
                    continuation.resume(throwing: AppIntentError.noResponseAvailable)
                } else {
                    continuation.resume(returning: html)
                }
            } else {
                continuation.resume(throwing: AppIntentError.noResponseAvailable)
            }
        }
    }

    // Step 2: Convert HTML to Markdown in background (off main thread)
    let markdown = await Task(priority: .userInitiated) {
        HTMLToMarkdown.convert(htmlString)
    }.value

    return markdown
}
```

**Benefits:**
- JavaScript execution: <100ms (unblocks WebView)
- Swift conversion: 100-500ms (happens on background task, main thread not blocked)
- Total user-perceived latency: ~500ms (compared to 2-3s currently)
- Conversion is unit testable

**Files modified:**
- `WebKit/UserScripts.swift` — simplify `createCaptureScript()` to HTML extraction only
- `Utils/HTMLToMarkdown.swift` (new) — 200-300 lines of HTML→Markdown logic
- `Coordinators/AppCoordinator.swift` — update `captureLastResponseAsString()` to use both steps

---

### Optimization 3: Move File I/O Off Main Thread (45-60 min)

**Goal:** Prevent UI jank during file write by moving I/O to background task.

**Implementation:**

Modify `AppCoordinator.saveArtifact()` to use a detached background task:

```swift
func saveArtifact(markdown: String, filename: String) {
    // Move file I/O to background
    // Use Task.detached to guarantee execution OFF the main thread
    // (AppCoordinator is @MainActor, so plain Task() would inherit MainActor context)
    Task.detached(priority: .userInitiated) {
        do {
            try await self.performFileIO(markdown: markdown, filename: filename)
        } catch {
            await MainActor.run {
                self.injectionBannerMessage = "Failed to save artifact: \(error.localizedDescription)"
            }
        }
    }
}
```

**[ANNOTATION: Critical — Use `Task.detached` not `Task`. Since `AppCoordinator` is `@MainActor`, a plain `Task` inherits the MainActor context and file I/O may still block the UI. `Task.detached` breaks isolation and guarantees off-main-thread execution.]**

private nonisolated func performFileIO(markdown: String, filename: String) async throws {
    // Not on MainActor — can do blocking I/O without jank
    // Use Task.detached to guarantee execution off the main thread
    let bookmarkStore = BookmarkStore()
    try bookmarkStore.withBookmarkedURL(for: .artifactsDirectoryBookmark) { dirURL in
        var finalURL = dirURL.appendingPathComponent(filename, isDirectory: false)
        var counter = 1
        let maxRetries = 100  // Circuit breaker: prevent runaway loop on permissions errors

        // FileManager.fileExists is sync, but we're not on main thread
        while FileManager.default.fileExists(atPath: finalURL.path) && counter < maxRetries {
            let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            let ext = URL(fileURLWithPath: filename).pathExtension

            // Handle case where filename has no extension (avoid trailing dot)
            let newName = ext.isEmpty
                ? "\(stem)-\(counter).md"  // Default to .md if no extension
                : "\(stem)-\(counter).\(ext)"

            finalURL = dirURL.appendingPathComponent(newName, isDirectory: false)
            counter += 1
        }

        // Failsafe: if we hit the retry limit, it suggests a permissions/bookmark issue
        if counter >= maxRetries {
            throw NSError(domain: "CaptureError", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Could not find available filename. Check artifacts directory permissions."])
        }

        // Unconditionally prepend YAML header — the markdown was just generated from HTML extraction
        // and will never have frontmatter at this point
        let iso8601 = ISO8601DateFormatter().string(from: Date())
        let header = "---\ncaptured_at: \(iso8601)\nsource: gemini.google.com\n---\n\n"
        let content = header + markdown

        try content.write(to: finalURL, atomically: true, encoding: .utf8)
    }
}
```

**[NOTE: Add circuit breaker (maxRetries = 100) to prevent infinite loop if permissions or bookmark staleness causes FileManager issues.]**
```

**Files modified:**
- `Coordinators/AppCoordinator.swift` — refactor `saveArtifact()` to use background task

**No changes to calling code.** The method remains synchronous to the caller.

---

## Testing Checklist

- [ ] Optimization 1:
  - [ ] Trigger artifact capture, observe spinner below button
  - [ ] Spinner disappears on completion with "Saved: filename" label
  - [ ] Label auto-dismisses after 2 seconds
  - [ ] Error state shows for 3 seconds on failure

- [ ] Optimization 2:
  - [ ] Measure time before/after (target: 2-3s → 1-1.5s)
  - [ ] Test on large response with code blocks, tables, lists
  - [ ] Verify markdown output is identical to before
  - [ ] No new errors or warnings in console

- [ ] Optimization 3:
  - [ ] Save artifact on external/slow drive
  - [ ] Verify UI stays responsive (no main thread freeze)
  - [ ] File write completes successfully
  - [ ] Progress spinner continues spinning during write

---

## Error Handling & Bookmark Staleness

**Current gap:** If `BookmarkStore` fails silently or resolves to an inaccessible directory, the UI could hang in `.saving` state indefinitely.

**Fix:** Ensure comprehensive error handling in `performFileIO`:

```swift
private nonisolated func performFileIO(markdown: String, filename: String) async throws {
    let bookmarkStore = BookmarkStore()

    // Wrap bookmark resolution in error handling
    do {
        try bookmarkStore.withBookmarkedURL(for: .artifactsDirectoryBookmark) { dirURL in
            // ... file I/O code ...
        }
    } catch {
        // Surface specific errors based on bookmark failure
        if error as? CocoaError != nil, (error as! CocoaError).code == .fileReadNoSuchFile {
            throw NSError(domain: "CaptureError", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Artifacts directory no longer exists. Reconfigure in Settings."])
        }
        throw error
    }
}
```

**[NOTE: Bookmark staleness (user deletes directory outside app) is not prevented here, only detected. Consider adding a periodic validation task or "Check Directory" button in Settings if this becomes a problem.]**

---

## Effort Summary

| Phase | Effort | Risk | Impact |
|---|---|---|---|
| Phase 1: User Feedback | 30-45 min | Low | Spinner + status label (massive UX improvement) |
| Phase 2a: JS HTML Extraction | 15-30 min | Low | Change 1 function, 5 lines (near-zero risk) |
| Phase 2b: Swift Markdown Converter | 1.5-2 hours | Low | 200-300 lines of regex-based HTML parsing, fully unit testable |
| Phase 3: Off-Main-Thread I/O | 45-60 min | Low | Move file I/O to background task, add error handling |

**Total: 3-4.5 hours** for complete optimization (Path B)

---

## Implementation Sequence (Path B)

1. **Phase 1 (User Feedback)** — 30-45 min
   - Add `CaptureProgress` enum to AppCoordinator
   - Update `ArtifactCaptureButton` to show spinner + status label
   - Update `captureLastResponse()` to emit progress states
   - ✓ First visible improvement, user sees feedback immediately

2. **Phase 2a (Simplify JavaScript)** — 15-30 min
   - Modify `UserScripts.createCaptureScript()` to extract HTML only (5 lines changed)
   - Test that JS returns raw HTML string without markup conversion
   - ✓ Minimal change, nearly zero risk

3. **Phase 2b (Build HTML→Markdown Converter)** — 1.5-2 hours
   - Create `Utils/HTMLToMarkdown.swift` with `HTMLParser` class
   - Implement regex-based tag extraction, attribute parsing, recursive content handling
   - Unit test on sample HTML fragments (write 10-15 unit tests in `Tests/HTMLToMarkdownTests.swift`)
   - Compare output to current JavaScript version (should be pixel-identical)
   - ✓ Fully testable before integration

4. **Phase 3 (File I/O Off Main Thread)** — 45-60 min
   - Refactor `saveArtifact()` to use background `Task`
   - Add circuit breaker to filename collision loop
   - Improve error handling for bookmark staleness
   - ✓ Prevents UI jank on slow file systems

**All phases integrate smoothly:**
- Phase 2a updates JavaScript to extract HTML
- Phase 2b adds the HTML parser that consumes that HTML
- Phase 1 shows progress throughout all three operations
- Phase 3 runs file I/O without blocking main thread

---

## Success Criteria (Path B)

**Phase 1 (User Feedback):**
- [ ] Artifact capture shows loading spinner below button
- [ ] Spinner displays status: "Started…" → "Converting…" → "Saving…" → "Saved: filename"
- [ ] On success: "Saved: filename" label appears for 2 seconds, then auto-dismisses
- [ ] On error: "Error: …" message appears for 3 seconds, user can dismiss early
- [ ] Capture button is disabled while operation is in-flight (no double-clicks)
- [ ] No GCD (`DispatchQueue`) — uses `Task.sleep(for:)` only

**Phase 2a (JavaScript Extraction):**
- [ ] `createCaptureScript()` returns raw HTML string (no Markdown conversion)
- [ ] JavaScript execution time: <100ms (measured with Safari DevTools)
- [ ] WKWebView main thread is not blocked during extraction
- [ ] Empty response returns `''` (empty string, not error)
- [ ] Streaming detection: uses structural selector (not localized `aria-label`) — **verify the actual Gemini DOM structure** for the streaming indicator
  - [ ] Test in English locale: streaming detection works
  - [ ] Test in non-English locale (German, Spanish, Japanese): streaming detection still works (should not rely on text)
  - [ ] If locale breaks detection, revert to substring match fallback (`aria-label*="Stop"`) and file issue for future research

**Phase 2b (HTML→Markdown Converter):**
- [ ] Parser library chosen: SwiftSoup (recommended) or NSAttributedString (zero dependencies)
- [ ] If SwiftSoup: SPM dependency added to `GeminiDesktop` target
- [ ] `HTMLToMarkdown.convert()` correctly handles all tags:
  - [ ] Headings: `<h1>` through `<h6>` → `#` through `######`
  - [ ] Text formatting: `<strong>`, `<b>`, `<em>`, `<i>`, `<code>`
  - [ ] Blocks: `<p>`, `<pre>`, `<blockquote>`
  - [ ] Lists: `<ul>`, `<ol>`, `<li>` (including nested)
  - [ ] Links: `<a href="url">text</a>` → `[text](url)`
  - [ ] Tables: `<table><tr><th>`, `<td>` → pipe-delimited Markdown
  - [ ] Media: `<img alt="text" src="url">` → `![text](url)`
  - [ ] Special: `<br>` → newline, unknown tags → recurse into children
- [ ] Unit tests: ≥15 test cases covering all tag types
  - [ ] Simple tags: h1, p, strong, em, code
  - [ ] Nested tags: `<p><strong>bold</strong> and <em>italic</em></p>`
  - [ ] Lists with nesting: `<ul><li>A<ul><li>Nested</li></ul></li></ul>`
  - [ ] Tables: headers, body rows, mixed content
  - [ ] Media: images, SVG (fallback to note)
  - [ ] Malformed HTML: missing closing tags, unescaped characters — should not crash
  - [ ] HTML entities: `&amp;`, `&lt;`, `&gt;`, `&nbsp;`, etc.
- [ ] Markdown output matches current JavaScript version (spot-check 5+ real Gemini responses)
- [ ] Performance: conversion <500ms for typical response (200-500 DOM nodes)
- [ ] Edge cases handled:
  - [ ] Empty HTML → empty string (no error)
  - [ ] Parser errors gracefully fallback to plaintext

**Phase 3 (File I/O):**
- [ ] Verify `Task.detached` is used (not `Task`) to guarantee off-main-thread execution
- [ ] Save artifact to slow/external drive, verify UI stays responsive (spinner continues spinning, main thread doesn't freeze)
- [ ] Verify file successfully writes with correct content and YAML header
- [ ] Test filename collision loop:
  - [ ] First capture: `Gemini-20260317-120000.md`
  - [ ] Second capture same second: `Gemini-20260317-120000-1.md`
  - [ ] Third capture: `Gemini-20260317-120000-2.md`
- [ ] Test filename without extension handling (edge case):
  - [ ] User enters "MyCapture" (no `.md`)
  - [ ] First file saved: `MyCapture.md` (default extension added)
  - [ ] Second file: `MyCapture-1.md` (no trailing dot)
- [ ] Circuit breaker: if >100 collisions (counter >= 100), throw error and show in UI
- [ ] Error handling:
  - [ ] Delete artifacts directory while app is running
  - [ ] Trigger capture
  - [ ] Verify error state displays: "Error: Artifacts directory no longer exists…"
  - [ ] Verify user can dismiss error

**All Phases Integration:**
- [ ] No regressions in existing artifact capture functionality
- [ ] End-to-end test: Create capture in UI → see progress feedback → file appears in directory with correct content and header
- [ ] Bookmark staleness gracefully handled with user-facing error message
- [ ] No mixing of GCD and Swift Concurrency in AppCoordinator
- [ ] All error paths update `captureProgress` state (no hung spinners)
- [ ] Build succeeds: `xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build` with 0 warnings
