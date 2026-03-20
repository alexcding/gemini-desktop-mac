# Design: Artifact Save Improvements

**Date:** 2026-03-20
**Status:** Approved for implementation
**Plan:** `docs/superpowers/plans/2026-03-20-artifact-save-improvements.md` (to be written)

---

## Goals

1. Complete remaining UX gaps in artifact capture (performance work is done; UX gaps remain)
2. Default artifacts directory: `~/Downloads/Artifacts`, auto-create, zero setup friction
3. Enriched YAML front matter with reproducibility, provenance, and A/B tracking fields
4. Filename selection scoped to stem only (not extension)
5. Improved feedback UX (top banner, Apple HIG); structured error log in the app's container log directory

## Non-Goals

- YAML field editing in the save dialog (code structured as a seam for future Option B)
- Gemini internal build/experiment ID capture (too fragile, changes without notice)
- Log file rotation (v1: create-and-append only)
- Unit tests (all changes are UI or thin pipeline wiring; manual testing checklist covers them)

---

## Sandbox Constraints

The app uses `com.apple.security.app-sandbox` with:
- `com.apple.security.files.user-selected.read-write` — user-selected paths via NSOpenPanel
- `com.apple.security.files.downloads.read-write` — direct access to `~/Downloads` (no user selection required)

**`~/Documents` is NOT accessible** without user selection. The auto-default directory is therefore `~/Downloads/Artifacts`.

**Security-scoped bookmarks are NOT used for the auto-default path.** The `downloads.read-write` entitlement provides persistent access to `~/Downloads` directly via `FileManager`. Bookmarks are only needed for user-chosen paths outside the entitlement scope (handled by the existing `BookmarkStore` when the user picks via Settings). `BookmarkStore.withBookmarkedURL` returning `nil` is the signal to fall through to the entitlement-based Downloads path.

**Known limitation:** If `BookmarkStore.withBookmarkedURL` returns `nil` because `startAccessingSecurityScopedResource()` failed on a previously-configured custom directory (e.g., the user deleted it), `performFileIO` silently falls through to `~/Downloads/Artifacts` rather than surfacing an error. This is a pre-existing limitation of `BookmarkStore`'s silent `nil` return and is not addressed in this design.

**Log file path:** Sandboxed apps cannot write to `~/Library/Logs` directly. `FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first` inside the sandbox resolves to the container-relative Library. The log file lives at:
```
~/Library/Containers/<bundle-id>/Data/Library/Logs/GeminiDesktop/gemini-desktop.log
```
This is accessible without any entitlement change. `NSWorkspace.shared.open(logURL)` opens it in Console.app.

---

## Architecture

### 1. `ArtifactMetadata` (new value type)

**File:** `Artifacts/ArtifactMetadata.swift`

A `Sendable` struct that carries all metadata through the capture pipeline. This is the key seam for the Option A → Option B upgrade path: in Option A the save dialog displays it read-only; in Option B, fields become bound `TextField` inputs with no pipeline changes required.

All properties are `var` (not `let`) so they can be mutated in the save dialog when Option B is implemented.

```swift
struct ArtifactMetadata: Sendable {
    // Provenance (set by Swift at capture time)
    var schemaVersion: String = "1"
    var capturedAt: Date = Date()
    var tool: String = "Gemini Desktop"
    var toolVersion: String          // Bundle.main CFBundleShortVersionString
    var macosVersion: String         // ProcessInfo.processInfo.operatingSystemVersionString

    // Source context (extracted from DOM via JS)
    var source: String = "gemini.google.com"
    var conversationId: String?      // path segment after /app/ in window.location.href
    var conversationTitle: String?   // document.title
    var conversationUrl: String?     // window.location.href
    var responseIndex: Int?          // count of response-container elements

    // Model context (extracted from DOM)
    var geminiModel: String?         // model selector button text

    // Reproduction (extracted from DOM)
    var request: String?             // last user message text
    var attachments: [String] = []   // visible attachment chip label texts

    // Runtime environment (extracted from JS)
    var webkitVersion: String?       // parsed from navigator.userAgent (AppleWebKit/X.Y.Z)
    var jscVersion: String?          // same as webkitVersion (JSC co-releases with WebKit)

    // User-fillable (empty by default, present in YAML for user to populate)
    var tags: [String] = []
}
```

`ArtifactMetadata` owns its YAML serialization via a non-throwing method. No fallback is needed — the method is pure string interpolation and cannot fail. Optional fields are omitted from output when nil or empty.

`ArtifactMetadata` also provides a static `empty()` factory for use as a safe fallback before pre-fetch completes:

```swift
extension ArtifactMetadata {
    func toYAMLFrontmatter() -> String { ... }  // non-throwing

    /// Returns a metadata value with only Swift-side fields populated.
    /// Used as a safe fallback in UI code before fetchMetadataPreview() completes.
    static func empty() -> ArtifactMetadata {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return ArtifactMetadata(toolVersion: version, macosVersion: os)
    }
}
```

Output format:

```yaml
---
schema_version: "1"
captured_at: "2026-03-20T14:30:00Z"
tool: "Gemini Desktop"
tool_version: "0.3.1"
macos_version: "macOS 15.3.1"
source: "gemini.google.com"
conversation_id: "abc123xyz"
conversation_title: "How to sort in Python"
conversation_url: "https://gemini.google.com/app/abc123xyz"
response_index: 3
gemini_model: "2.0 Flash Thinking"
request: |
  Write a Python function that sorts a list of dicts by a key.
attachments: []
webkit_version: "605.1.15"
jsc_version: "605.1.15"
tags: []
---
```

---

### 2. `ArtifactLogger` (new)

**File:** `Utils/ArtifactLogger.swift`

Writes structured error entries to the container log file. Also emits to `os.log` (visible in Console.app). Falls back gracefully if the log directory cannot be created — a logging failure must never surface as a user-facing error.

```swift
enum ArtifactLogger {
    /// Resolved at runtime via FileManager container path. nil if the path cannot be built.
    static var logFileURL: URL? { ... }

    /// Appends one structured entry. No-op if log file cannot be created.
    static func logError(_ error: Error, context: [String: String] = [:]) { ... }
}
```

Every `captureProgress = .failed(...)` transition in `AppCoordinator` must call `ArtifactLogger.logError` before setting the state. This guarantees that any `.failed` state shown in the UI always has a corresponding log entry — so the view can unconditionally show "Open Log" on `.failed`.

The "Open Log" button in the UI is disabled (not hidden) when `ArtifactLogger.logFileURL` is nil:
```swift
Button("Open Log") {
    if let url = ArtifactLogger.logFileURL { NSWorkspace.shared.open(url) }
}
.disabled(ArtifactLogger.logFileURL == nil)
```

Log entry format:
```
[2026-03-20T14:30:00Z] ERROR ArtifactCapture: The artifacts directory is not accessible.
  conversation_url: https://gemini.google.com/app/abc123xyz
  filename_attempted: Gemini-2026-03-20-143000.md
  underlying: NSCocoaErrorDomain/4
```

---

### 3. JS Scripts

**File:** `WebKit/UserScripts.swift`

Two static methods:

**`createMetadataScript() -> String`** — returns a JSON string with all DOM-extractable fields. Wraps the entire body in `try/catch`; returns `{}` on any exception. Called both in the pre-fetch (before the sheet opens) and as the first step of the full capture pipeline.

**`createCaptureScript(lastResponseSelector:)` (existing)** — unchanged interface. Returns the response element's `innerHTML`, `__streaming__`, or `""`.

| Field | DOM Source |
|---|---|
| `conversation_url` | `window.location.href` |
| `conversation_id` | path segment after `/app/` in the URL |
| `conversation_title` | `document.title` |
| `response_index` | `document.querySelectorAll('response-container').length` |
| `gemini_model` | text content of the model selector button |
| `request` | text content of the last user turn element |
| `attachments` | array of attachment chip label texts |
| `webkit_version` | parsed from `navigator.userAgent` (`AppleWebKit/X.Y.Z`) |
| `jsc_version` | same parse (JSC co-releases with WebKit) |

All fields are best-effort. A metadata extraction failure must never block the capture — callers proceed with partial metadata.

---

### 4. Pipeline Changes in `AppCoordinator`

**File:** `Coordinators/AppCoordinator.swift`

#### Threading model (explicit)

All `evaluateJavaScript` calls and `ArtifactMetadata` assembly happen on `@MainActor`. The assembled `ArtifactMetadata` value (which is `Sendable`) is then passed by value to `performFileIO`, which is `nonisolated` and runs in a `Task.detached`. This crossing is safe because `ArtifactMetadata` is a value type with `Sendable` conformance.

#### 4a. `fetchMetadataPreview()` (new method)

```swift
// @MainActor
func fetchMetadataPreview() async -> ArtifactMetadata
```

Runs `createMetadataScript` on the WebView, parses the JSON result, and assembles a fully populated `ArtifactMetadata` with both JS-extracted and Swift-side fields (`capturedAt`, `toolVersion`, `macosVersion`). Returns a partial `ArtifactMetadata` (with only Swift-side fields populated) if the JS fails or the page is not ready. **Never throws.**

This is the metadata shown in `FilenameInputSheet`'s disclosure group and also used as the starting metadata for the save operation — see section 4b.

#### 4b. `captureLastResponse` pre-fetches metadata before showing the sheet

The sheet-open flow in `ArtifactCaptureButton` changes to:

1. User clicks the capture button
2. `fetchMetadataPreview()` runs (< 50ms — metadata-only JS, no HTML extraction)
3. The sheet opens with the pre-fetched `ArtifactMetadata` passed in
4. User edits the filename, clicks Save
5. Sheet closes, `captureLastResponse(suggestedFilename:previewMetadata:)` is called with the pre-fetched metadata

```swift
func captureLastResponse(suggestedFilename: String?, previewMetadata: ArtifactMetadata) {
    Task {
        captureProgress = .started
        do {
            captureProgress = .converting
            // Only runs createCaptureScript + HTMLToMarkdown — metadata already fetched
            let markdown = try await captureResponseMarkdown()
            captureProgress = .saving
            let filename = suggestedFilename?.isEmpty == false ? suggestedFilename! : defaultArtifactFilename()
            await saveArtifact(markdown: markdown, metadata: previewMetadata, filename: filename)
        } catch {
            ArtifactLogger.logError(error)
            captureProgress = .failed(error: error.localizedDescription)
            // No auto-dismiss — error banner is persistent, dismissed by user via × button
        }
    }
}
```

`captureResponseMarkdown() async throws -> String` is `captureLastResponseAsString` refactored to drop the metadata return value. It retains the full two-step pipeline: JS extracts HTML (`createCaptureScript`), then `HTMLToMarkdown.convert` runs on a background task. The name reflects what it returns (Markdown, not HTML). Metadata was already fetched in step 2 and is not re-fetched here.

**Remove the existing error auto-dismiss** (`try? await Task.sleep(for: .seconds(3))` / `self.captureProgress = nil`) from the error branch. Error state is persistent and cleared only by the user pressing ×.

#### 4c. `saveArtifact` (updated signature)

```swift
func saveArtifact(markdown: String, metadata: ArtifactMetadata, filename: String) async {
    do {
        let savedFilename = try await performFileIO(markdown: markdown, metadata: metadata, filename: filename)
        captureProgress = .completed(filename: savedFilename)
        // Success auto-dismisses after 2 seconds
        try await Task.sleep(for: .seconds(2))
        self.captureProgress = nil
    } catch {
        ArtifactLogger.logError(error, context: [
            "filename_attempted": filename,
            "conversation_url": metadata.conversationUrl ?? ""
        ])
        captureProgress = .failed(error: error.localizedDescription)
        // No auto-dismiss — persistent banner, user dismisses via ×
    }
}
```

**Remove the existing 3-second auto-dismiss from `saveArtifact`'s error path.**

#### 4d. `performFileIO` (updated signature)

```swift
nonisolated private func performFileIO(
    markdown: String,
    metadata: ArtifactMetadata,
    filename: String
) async throws -> String
```

Replaces the hardcoded two-field YAML header with `metadata.toYAMLFrontmatter()`.

#### 4e. Default directory resolution

Extract the filename collision-avoidance loop into a private helper so it is shared by both the bookmark path and the Downloads fallback path:

```swift
/// Returns a unique file URL inside dirURL for the given filename,
/// appending -1, -2, … suffixes until no collision exists.
private func resolveUniqueURL(in dirURL: URL, filename: String) throws -> URL { ... }
```

Priority chain in `performFileIO`:

1. **Saved bookmark** — `BookmarkStore().withBookmarkedURL(for: .artifactsDirectoryBookmark, ...)` returns non-nil → resolve unique URL inside bookmark dir, write file
2. **No bookmark** → build `~/Downloads/Artifacts` URL via `FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Artifacts")`; create with `createDirectory(at:withIntermediateDirectories:true)`; resolve unique URL using the same `resolveUniqueURL` helper; write directly — no bookmark saved, the `downloads.read-write` entitlement provides persistent access
3. **Download dir creation fails** → throw `AppIntentError.directoryUnavailable`

Update `AppIntentError.directoryUnavailable`'s `errorDescription` to: `"Could not access or create the artifacts directory. Choose a folder in Settings → Prompts & Artifacts."`

Settings shows the directory's `lastPathComponent` as before; when using the auto-default, the label shows `"Downloads/Artifacts"`.

#### 4f. `dismissCaptureProgress()` (new method)

```swift
// @MainActor
func dismissCaptureProgress() {
    captureProgress = nil
}
```

Called by the × button in the capture feedback banner (section 6). Required because `captureProgress` is `private(set)` — the view cannot set it directly.

---

### 5. Save Dialog (`ArtifactCaptureButton` / `FilenameInputSheet`)

**File:** `Views/ArtifactCaptureButton.swift`

#### 5a. Button action — pre-fetch before sheet open

`prefetchedMetadata` is set before `showingSheet = true`, so it is always non-nil by the time the sheet body evaluates. The `if let` guard in the sheet body makes this safe without force-unwrapping. The `ArtifactMetadata.empty()` fallback in the `else` branch is defensive only and should never be reached in practice.

```swift
struct ArtifactCaptureButton: View {
    var coordinator: AppCoordinator
    @State private var showingSheet = false
    @State private var filenameInput = ""
    @State private var prefetchedMetadata: ArtifactMetadata? = nil

    var body: some View {
        Button(action: {
            Task {
                // Pre-fetch runs first; sheet opens only after metadata is ready.
                prefetchedMetadata = await coordinator.fetchMetadataPreview()
                showingSheet = true
            }
        }) {
            Image(systemName: "square.and.arrow.down.on.square")
        }
        .disabled(coordinator.captureProgress != nil)
        .sheet(isPresented: $showingSheet) {
            let metadata = prefetchedMetadata ?? ArtifactMetadata.empty()
            FilenameInputSheet(
                isPresented: $showingSheet,
                filename: $filenameInput,
                initialFilename: coordinator.defaultArtifactFilename(),
                metadata: metadata,
                onSave: {
                    coordinator.captureLastResponse(
                        suggestedFilename: filenameInput,
                        previewMetadata: metadata   // same value shown in disclosure group
                    )
                    showingSheet = false
                }
            )
        }
    }
}
```

#### 5b. Stem-only selection

On appear, select only the stem. Use `DispatchQueue.main.asyncAfter(deadline: .now() + 0.05)` and cast to `NSText` (the shared field editor superclass) to allow AppKit to finish its focus-handling cycle before the selection is applied. Without the 50ms delay, AppKit's own `becomeFirstResponder` sequence overwrites the selection immediately after it is set.

```swift
.onAppear {
    filename = initialFilename
    isFocused = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSText {
            let stem = (initialFilename as NSString).deletingPathExtension
            editor.setSelectedRange(NSRange(location: 0, length: (stem as NSString).length))
        }
    }
}
```

#### 5c. Metadata disclosure group (Option A → B seam)

`FilenameInputSheet` receives `metadata: ArtifactMetadata`. Below the filename field, a collapsed `DisclosureGroup("Metadata")` renders `metadataRows` — a separate `private var metadataRows: some View` computed property. In Option B, replace the `Text` labels in `metadataRows` with `TextField` bindings — no other changes required.

```
┌─────────────────────────────────────┐
│  Save Artifact As                   │
│                                     │
│  [ Gemini-2026-03-20-143000   .md ] │  ← stem selected, .md visible but not selected
│                                     │
│  ▶ Metadata                         │  ← collapsed by default
│                                     │
│            [Cancel]  [Save]         │
└─────────────────────────────────────┘

Expanded:
│  ▼ Metadata                         │
│    model:    2.0 Flash Thinking      │
│    request:  Write a Python...       │
│    url:      gemini.google.com/...   │
│    captured: 2026-03-20 14:30:00    │
```

---

### 6. Capture Feedback Banner (`MainWindowView`)

**File:** `Views/MainWindowView.swift`

Replace the current button-anchored `ProgressIndicator` overlay with a top-of-window banner. Both the existing injection banner and the new capture banner live inside a **single** `.overlay(alignment: .top)` containing a `VStack(spacing: 0)`. Using a single overlay ensures both banners stack vertically and the overlay correctly accounts for the combined height:

```swift
.overlay(alignment: .top) {
    VStack(spacing: 0) {
        // Injection banner (existing)
        if let msg = coordinator.injectionBannerMessage { ... }
        // Capture banner (new)
        if let progress = coordinator.captureProgress { ... }
    }
    .padding([.horizontal, .top], 12)
}
```

**Progress states** (starting/converting/saving): indeterminate `ProgressView` + phase label. Indeterminate is correct — markdown files are small and write time is not byte-quantifiable.

**Success state:** auto-dismisses after 2 seconds (handled by `AppCoordinator`).

**Error state:** persistent. Shows error message + "Open Log" button (disabled if `ArtifactLogger.logFileURL` is nil) + × dismiss button. The view unconditionally renders the "Open Log" button on `.failed` because `AppCoordinator` always calls `ArtifactLogger.logError` before setting `.failed`.

```
// Progress (indeterminate)
┌────────────────────────────────────────────────────────────────┐
│  ◌  Converting…                                               │
└────────────────────────────────────────────────────────────────┘

// Success (auto-dismisses after 2s)
┌────────────────────────────────────────────────────────────────┐
│  ✓  Saved: Gemini-2026-03-20-143000.md                        │
└────────────────────────────────────────────────────────────────┘

// Error (persistent)
┌────────────────────────────────────────────────────────────────┐
│  ⚠  Could not save: directory not accessible.                  │
│     [Open Log]                                            [×]  │
└────────────────────────────────────────────────────────────────┘
```

"Open Log" calls `NSWorkspace.shared.open(url)` (button disabled when `logFileURL` is nil).
× calls `coordinator.dismissCaptureProgress()`.

---

## Option A → Option B Upgrade Path

The `ArtifactMetadata` struct and the `metadataRows` computed property are the two seams. The upgrade is purely additive:

| Step | Option A (now) | Option B (future) |
|---|---|---|
| `ArtifactMetadata` struct | Exists, all `var`, `Sendable` | Unchanged |
| Pre-fetch | `fetchMetadataPreview()` runs before sheet opens | Unchanged |
| `metadataRows` view | `Text` labels (read-only) | `TextField` bindings on `$metadata` properties |
| Pipeline | `captureLastResponse(suggestedFilename:previewMetadata:)` | Unchanged |
| YAML write | `metadata.toYAMLFrontmatter()` | Unchanged |

---

## File Summary

| Action | File | Responsibility |
|---|---|---|
| Create | `Artifacts/ArtifactMetadata.swift` | Value type + YAML serialization |
| Create | `Utils/ArtifactLogger.swift` | Structured error logging (container Logs dir + os.log) |
| Modify | `WebKit/UserScripts.swift` | Add `createMetadataScript()` |
| Modify | `Coordinators/AppCoordinator.swift` | `fetchMetadataPreview()`, `captureResponseMarkdown()`, updated `captureLastResponse`/`saveArtifact`/`performFileIO` signatures, `dismissCaptureProgress()`, `resolveUniqueURL()` helper, default dir logic, remove error auto-dismiss |
| Modify | `Views/ArtifactCaptureButton.swift` | Pre-fetch on button tap, `prefetchedMetadata` state, stem-only selection (50ms delay + NSText cast), metadata disclosure group with `metadataRows` |
| Modify | `Views/MainWindowView.swift` | Single overlay VStack for both banners, capture feedback banner, × calls `dismissCaptureProgress()` |
| Modify | `Intents/AppIntentError.swift` | Update `directoryUnavailable` errorDescription to mention Settings path |

---

## Error Handling

| Scenario | Behavior |
|---|---|
| No directory configured, `~/Downloads/Artifacts` auto-creates OK | Silent — proceeds, file saved |
| `~/Downloads/Artifacts` creation fails | `directoryUnavailable` → log entry + persistent error banner with "Open Log" |
| Directory deleted after user-chosen bookmark saved | Silent fallback to `~/Downloads/Artifacts` (known BookmarkStore limitation — pre-existing) |
| Metadata pre-fetch fails (JS exception or page not ready) | `fetchMetadataPreview()` returns partial metadata with only Swift-side fields; no user-facing error; capture proceeds |
| Capture script returns `__streaming__` | Transient banner "Gemini is still streaming — wait for response to finish" (auto-dismiss 3s, no log entry, `.failed` not set) |
| File collision limit exceeded | `fileCollisionLimitExceeded` → log entry + persistent error banner |

---

## Manual Testing Checklist

- [ ] **Default directory**: Clear `artifactsDirectoryBookmark` from UserDefaults (`defaults delete <bundle-id> artifactsDirectoryBookmark`), trigger capture → `~/Downloads/Artifacts` created, file saved there
- [ ] **Settings label**: After auto-create, Settings shows `"Downloads/Artifacts"` as the artifacts path
- [ ] **User-chosen directory**: Choose a custom directory in Settings → subsequent captures go there (bookmark path takes priority)
- [ ] **YAML header**: Open a saved `.md` file, verify all populated fields present; nil/empty fields omitted
- [ ] **Pre-fetch metadata**: Click capture button; sheet opens with metadata visible in disclosure group (model, request, URL populated)
- [ ] **Filename selection**: Sheet opens with stem selected only; `.md` visible but not selected; typing immediately replaces stem
- [ ] **Metadata disclosure**: Click "Metadata" chevron → fields expand showing all non-nil values in `metadataRows`
- [ ] **Success banner**: Capture succeeds → banner at top of window, auto-dismisses after 2 seconds
- [ ] **Error banner**: Delete artifacts directory while app running, trigger capture → persistent banner with "Open Log" and × buttons
- [ ] **× dismiss**: Click × → banner clears, button re-enables
- [ ] **Open Log button**: Click "Open Log" → Console.app opens, log entry present with timestamp and context
- [ ] **Log file location**: Confirm log at `~/Library/Containers/<bundle-id>/Data/Library/Logs/GeminiDesktop/gemini-desktop.log`
- [ ] **Log button disabled state**: If `ArtifactLogger.logFileURL` returns nil, "Open Log" button appears disabled
- [ ] **Streaming guard**: Trigger capture mid-stream → transient "still streaming" banner, no log entry, no file written
- [ ] **Simultaneous banners**: Trigger injection error + capture error → both banners stack vertically in single overlay
- [ ] **Option B seam**: Verify `metadataRows` is a separate computed property; all `ArtifactMetadata` properties are `var`
