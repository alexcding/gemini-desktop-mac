# Artifact Capture Bug Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two bugs in artifact capture: filename sheet should pre-fill default + select, streaming detection should use locale-agnostic CSS class instead of localized aria-label.

**Architecture:** Three targeted file changes: expose `defaultArtifactFilename()`, update `FilenameInputSheet` to pre-fill and select on appear, replace JavaScript streaming check with structural selector.

**Tech Stack:** SwiftUI, AppKit (NSApp.keyWindow for text selection), JavaScript (querySelector), no new dependencies.

---

## File Structure

| File | Responsibility |
|---|---|
| `Coordinators/AppCoordinator.swift` | Expose `defaultArtifactFilename()` for view layer access |
| `Views/ArtifactCaptureButton.swift` | Pass coordinator's default filename to sheet at presentation time |
| `WebKit/UserScripts.swift` | Replace broken streaming detection with structural CSS class selector |

---

## Task 1: Expose defaultArtifactFilename()

**Files:**
- Modify: `Coordinators/AppCoordinator.swift:357`

- [ ] **Step 1: Open AppCoordinator.swift and locate defaultArtifactFilename()**

Go to line 357. You'll see:
```swift
private func defaultArtifactFilename() -> String {
```

- [ ] **Step 2: Remove the `private` modifier**

Change to:
```swift
func defaultArtifactFilename() -> String {
```

(Swift defaults to `internal` visibility; do not add `internal` keyword explicitly.)

- [ ] **Step 3: Build and verify no errors**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | head -20
```

Expected: Build succeeds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Coordinators/AppCoordinator.swift
git commit -m "refactor: expose defaultArtifactFilename for view access"
```

---

## Task 2: Update FilenameInputSheet to accept initialFilename

**Files:**
- Modify: `Views/ArtifactCaptureButton.swift:77-111` (FilenameInputSheet struct)

- [ ] **Step 1: Add initialFilename parameter and FocusState to FilenameInputSheet struct**

Open the file and find `private struct FilenameInputSheet: View` at line 77. Add two new properties to the struct (after line 80, before the body):

```swift
private struct FilenameInputSheet: View {
    @Binding var isPresented: Bool
    @Binding var filename: String
    let initialFilename: String  // Add this line
    var onSave: () -> Void
    @FocusState private var isFocused: Bool  // Add this line
```

- [ ] **Step 2: Update the TextField to use the new placeholder and add focused state**

Find the TextField at line 87. Replace:
```swift
            TextField("Filename (without .md extension)", text: $filename)
```

With:
```swift
            TextField("Filename (e.g. Gemini-2026-03-19-143022.md)", text: $filename)
                .focused($isFocused)
```

- [ ] **Step 3: Replace the .onAppear block**

Find the existing `.onAppear` modifier at line 107-108. It currently reads:
```swift
        .onAppear {
            filename = ""
        }
```

Replace it with:
```swift
        .onAppear {
            filename = initialFilename
            isFocused = true
            DispatchQueue.main.async {
                NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
            }
        }
```

**CRITICAL:** There must be exactly one `.onAppear` modifier on the TextField. Replace the existing one; do not add a second one.

- [ ] **Step 4: Build and verify**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|warning:" || echo "Build succeeded"
```

Expected: "Build succeeded" (or at least no errors, warnings are okay)

- [ ] **Step 5: Commit**

```bash
git add Views/ArtifactCaptureButton.swift
git commit -m "fix: pre-fill filename sheet with default and auto-select on appear"
```

---

## Task 3: Update ArtifactCaptureButton to pass initialFilename

**Files:**
- Modify: `Views/ArtifactCaptureButton.swift:24-33` (the .sheet closure in ArtifactCaptureButton)

- [ ] **Step 1: Update .sheet() to pass initialFilename**

Find the `.sheet(isPresented: $showingSheet)` closure starting at line 24. Replace the entire closure contents with:
```swift
        .sheet(isPresented: $showingSheet) {
            FilenameInputSheet(
                isPresented: $showingSheet,
                filename: $filenameInput,
                initialFilename: coordinator.defaultArtifactFilename(),
                onSave: {
                    coordinator.captureLastResponse(suggestedFilename: filenameInput)
                    showingSheet = false
                }
            )
        }
```

This ensures `defaultArtifactFilename()` is called at sheet-presentation time (when the sheet is about to appear), capturing the current timestamp.

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|warning:" || echo "Build succeeded"
```

Expected: "Build succeeded"

- [ ] **Step 3: Commit**

```bash
git add Views/ArtifactCaptureButton.swift
git commit -m "fix: pass default filename to input sheet at presentation time"
```

---

## Task 4: Fix streaming detection in UserScripts

**Files:**
- Modify: `WebKit/UserScripts.swift:343-358` (createCaptureScript function)

- [ ] **Step 1: Locate createCaptureScript function**

Go to line 343. You'll see the function definition:
```swift
nonisolated static func createCaptureScript(lastResponseSelector: String) -> String {
```

- [ ] **Step 2: Replace the isStreaming check in the JavaScript**

Inside the returned JavaScript string (lines 347-348), find:
```javascript
const isStreaming = document.querySelector('[data-streaming="true"]')
    || Array.from(document.querySelectorAll('button[aria-label*="Stop"]')).length > 0;
```

Replace with:
```javascript
const isStreaming = document.querySelector('button.send-button.stop') !== null;
```

Also update the comment on line 346 from:
```javascript
// Check if still streaming — look for structural class or data attribute, then fallback to localized aria-label
```

To:
```javascript
// Check if still streaming — look for structural CSS class (language-agnostic)
```

The complete updated function should be:
```swift
nonisolated static func createCaptureScript(lastResponseSelector: String) -> String {
    """
    (function() {
        // Check if still streaming — look for structural CSS class (language-agnostic)
        const isStreaming = document.querySelector('button.send-button.stop') !== null;

        if (isStreaming) {
            return '__streaming__';
        }

        const responseEl = document.querySelector('\(lastResponseSelector)');
        return responseEl ? responseEl.innerHTML : '';
    })();
    """
}
```

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|warning:" || echo "Build succeeded"
```

Expected: "Build succeeded"

- [ ] **Step 4: Commit**

```bash
git add WebKit/UserScripts.swift
git commit -m "fix: use locale-agnostic CSS class for streaming detection"
```

---

## Task 5: Manual Testing

**Files:** None (testing only)

- [ ] **Step 1: Build and run the app**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build && \
open build/Release/GeminiDesktop.app
```

(Or just Cmd+R in Xcode.)

- [ ] **Step 2: Test Bug 1 — Default filename pre-fill and select**

1. Open Gemini in the app and send a message to generate a response
2. Click the artifact capture button (download icon in the toolbar)
3. **Verify:** The filename input sheet should appear with a pre-filled default filename (e.g., `Gemini-2026-03-19-143022.md`)
4. **Verify:** The text should be selected/highlighted (not just focused)
5. **Verify:** The Save button should be ENABLED (this confirms the fix is working)
6. Press Save immediately — file should be created with the default name in your artifacts directory
7. Click the capture button again
8. **Verify:** A new default filename is generated (fresh timestamp, different from step 3)
9. Type a custom name to override the selection (just start typing)
10. Press Save — file should be created with the custom name
11. Click capture again
12. Clear the filename field entirely (select all, delete)
13. **Verify:** The Save button is now disabled

- [ ] **Step 3: Test Bug 2 — Streaming detection (DevTools)**

1. Open Gemini in Safari (not the desktop app for this step)
2. Send a long prompt to trigger streaming response
3. While response is mid-stream, open Web Inspector (Cmd+Option+I)
4. Go to Console tab
5. Run: `document.querySelector('button.send-button.stop')`
6. It should return the button element (not null)
7. After streaming completes, run the same command
8. It should return null
9. This confirms the selector works

- [ ] **Step 4: Verify all four commits are present**

```bash
git log --oneline -4
```

Expected output: You should see four commits from Tasks 1-4, with messages:
1. `fix: use locale-agnostic CSS class for streaming detection`
2. `fix: pass default filename to input sheet at presentation time`
3. `fix: pre-fill filename sheet with default and auto-select on appear`
4. `refactor: expose defaultArtifactFilename for view access`

---

## Notes

- No unit tests are needed for these changes. They are UI tweaks and a JavaScript selector fix, both covered by manual testing.
- The changes are minimal and self-contained. No refactoring was necessary.
- If streaming detection needs further validation in non-English locales, the setup is documented in the spec (set macOS language, reload Gemini, test capture mid-stream).
