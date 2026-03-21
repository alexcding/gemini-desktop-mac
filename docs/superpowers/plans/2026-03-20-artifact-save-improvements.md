# Artifact Save Improvements Implementation Plan

> **STATUS: COMPLETE** — All tasks implemented. See git log around 2026-03-20.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve artifact saving with enriched YAML metadata, a `~/Downloads/Artifacts` default directory, stem-only filename selection, a top-of-window feedback banner (Apple HIG), and structured error logging.

**Architecture:** A new `ArtifactMetadata` value type flows through the entire pipeline — pre-fetched from the DOM before the save sheet opens, displayed read-only in a disclosure group, written to YAML frontmatter on save. Capture feedback moves from a button-anchored popup to the existing top-banner slot in `MainWindowView`. Errors write to the app container's log directory and persist until the user dismisses them.

**Tech Stack:** Swift 6, SwiftUI, AppKit, WKWebView (`evaluateJavaScript`), `os.log`, `FileManager`, `NSWorkspace`. No new package dependencies.

---

## File Structure

| Action | File | Responsibility |
|---|---|---|
| Create | `Artifacts/ArtifactMetadata.swift` | Value type + `toYAMLFrontmatter()` + `empty()` factory |
| Create | `Utils/ArtifactLogger.swift` | Structured error log (container Logs dir + `os.log`) |
| Modify | `WebKit/UserScripts.swift` | Add `createMetadataScript()` |
| Modify | `Intents/AppIntentError.swift` | Update `directoryUnavailable` error message; add `Equatable` to `CaptureProgress` |
| Modify | `Coordinators/AppCoordinator.swift` | `fetchMetadataPreview()`, `captureResponseMarkdown()`, updated `captureLastResponse`/`saveArtifact`/`performFileIO`, `resolveUniqueURL()`, `dismissCaptureProgress()`, default dir logic, remove error auto-dismiss |
| Modify | `Views/ArtifactCaptureButton.swift` | Pre-fetch on tap, stem-only selection, `FilenameInputSheet` metadata disclosure group |
| Modify | `Views/MainWindowView.swift` | Single overlay `VStack`, capture feedback banner |
| Modify | `Intents/CaptureLastArtifactIntent.swift` | Update calls to renamed/resigend coordinator methods |

---

## Build Command (use after every task)

```bash
cd /Users/zmarkley/src/github.com/alexcding/gemini-desktop-mac
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

---

## Task 1: Create ArtifactMetadata value type

**Files:**
- Create: `Artifacts/ArtifactMetadata.swift`

- [ ] **Step 1: Create the `Artifacts/` directory and file**

```bash
mkdir -p /Users/zmarkley/src/github.com/alexcding/gemini-desktop-mac/Artifacts
```

Create `Artifacts/ArtifactMetadata.swift` with this exact content:

```swift
//
//  ArtifactMetadata.swift
//  GeminiDesktop
//

import Foundation

/// Carries all capture metadata through the save pipeline.
/// All properties are `var` to support future in-sheet editing (Option B).
struct ArtifactMetadata: Sendable {
    // Provenance — set by Swift at capture time
    var schemaVersion: String = "1"
    var capturedAt: Date = Date()
    var tool: String = "Gemini Desktop"
    var toolVersion: String
    var macosVersion: String

    // Source context — extracted from DOM via JS
    var source: String = "gemini.google.com"
    var conversationId: String?
    var conversationTitle: String?
    var conversationUrl: String?
    var responseIndex: Int?

    // Model context — extracted from DOM
    var geminiModel: String?

    // Reproduction — extracted from DOM
    var request: String?
    var attachments: [String] = []

    // Runtime environment — extracted from JS
    var webkitVersion: String?
    var jscVersion: String?

    // User-fillable — empty by default, present in YAML as a prompt
    var tags: [String] = []
}

extension ArtifactMetadata {

    /// Returns metadata with only Swift-side fields populated.
    /// Safe to use before fetchMetadataPreview() completes.
    static func empty() -> ArtifactMetadata {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return ArtifactMetadata(toolVersion: version, macosVersion: os)
    }

    /// Serializes metadata to a YAML frontmatter block.
    /// Non-throwing — pure string interpolation, cannot fail.
    /// Optional fields are omitted when nil or empty.
    func toYAMLFrontmatter() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var lines: [String] = ["---"]

        lines.append("schema_version: \"\(schemaVersion)\"")
        lines.append("captured_at: \"\(iso.string(from: capturedAt))\"")
        lines.append("tool: \"\(tool)\"")
        if !toolVersion.isEmpty { lines.append("tool_version: \"\(toolVersion)\"") }
        if !macosVersion.isEmpty { lines.append("macos_version: \"\(macosVersion)\"") }
        lines.append("source: \"\(source)\"")

        if let conversationId { lines.append("conversation_id: \"\(conversationId)\"") }
        if let conversationTitle {
            let escaped = conversationTitle.replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("conversation_title: \"\(escaped)\"")
        }
        if let conversationUrl { lines.append("conversation_url: \"\(conversationUrl)\"") }
        if let responseIndex { lines.append("response_index: \(responseIndex)") }
        if let geminiModel {
            let escaped = geminiModel.replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("gemini_model: \"\(escaped)\"")
        }

        if let request, !request.isEmpty {
            // YAML literal block scalar for multi-line strings
            lines.append("request: |")
            request.components(separatedBy: "\n").forEach { lines.append("  \($0)") }
        }

        if attachments.isEmpty {
            lines.append("attachments: []")
        } else {
            lines.append("attachments:")
            attachments.forEach { lines.append("  - \"\($0)\"") }
        }

        if let webkitVersion { lines.append("webkit_version: \"\(webkitVersion)\"") }
        if let jscVersion { lines.append("jsc_version: \"\(jscVersion)\"") }

        if tags.isEmpty {
            lines.append("tags: []")
        } else {
            lines.append("tags:")
            tags.forEach { lines.append("  - \"\($0)\"") }
        }

        lines.append("---")
        lines.append("")  // blank line after frontmatter

        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 2: Add the file to the Xcode project**

In Xcode, right-click the project root in the Project Navigator and choose **"Add Files to 'GeminiDesktop'…"**. Navigate to the `Artifacts/` folder, select `ArtifactMetadata.swift`, ensure the **GeminiDesktop** target checkbox is ticked, and click **Add**. Xcode will create the `Artifacts` group automatically.

- [ ] **Step 3: Build and verify no errors**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 4: Commit**

```bash
git add Artifacts/ArtifactMetadata.swift GeminiDesktop.xcodeproj/project.pbxproj
git commit -m "feat: add ArtifactMetadata value type with YAML serialization"
```

---

## Task 2: Create ArtifactLogger

**Files:**
- Create: `Utils/ArtifactLogger.swift`

- [ ] **Step 1: Create `Utils/ArtifactLogger.swift`**

```swift
//
//  ArtifactLogger.swift
//  GeminiDesktop
//

import Foundation
import OSLog

/// Writes structured error entries to the app container's log file
/// and to the unified logging system (visible in Console.app).
///
/// Log path: ~/Library/Containers/<bundle-id>/Data/Library/Logs/GeminiDesktop/gemini-desktop.log
///
/// All operations are best-effort — a logging failure is never surfaced to the user.
enum ArtifactLogger {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.geminidesktop",
        category: "ArtifactCapture"
    )

    /// The log file URL resolved from the app's sandboxed Library container.
    /// Returns nil if the path cannot be constructed (should never happen in practice).
    static var logFileURL: URL? {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/GeminiDesktop/gemini-desktop.log")
    }

    /// Appends one structured entry to the log file and emits to os.log.
    /// No-op if the log directory cannot be created.
    static func logError(_ error: Error, context: [String: String] = [:]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var entry = "[\(timestamp)] ERROR ArtifactCapture: \(error.localizedDescription)\n"
        for (key, value) in context.sorted(by: { $0.key < $1.key }) {
            entry += "  \(key): \(value)\n"
        }

        // Unified logging (visible in Console.app)
        logger.error("\(error.localizedDescription, privacy: .public) — \(context.description, privacy: .public)")

        // File logging — silently no-op on any failure
        guard let logURL = logFileURL else { return }
        let logDir = logURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: logDir, withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = entry.data(using: .utf8) { handle.write(data) }
            } else {
                try entry.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            // Logging failure is intentionally silent
        }
    }
}
```

- [ ] **Step 2: Add the file to the Xcode project**

In Xcode, right-click the `Utils` group and choose **"Add Files to 'GeminiDesktop'…"**. Select `Utils/ArtifactLogger.swift`, ensure the **GeminiDesktop** target is ticked, and click **Add**.

- [ ] **Step 3: Build and verify no errors**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 4: Commit**

```bash
git add Utils/ArtifactLogger.swift GeminiDesktop.xcodeproj/project.pbxproj
git commit -m "feat: add ArtifactLogger for structured error logging to container Logs dir"
```

---

## Task 3: Add metadata extraction JS script

**Files:**
- Modify: `WebKit/UserScripts.swift`

- [ ] **Step 1: Read the current file to find the right insertion point**

Open `WebKit/UserScripts.swift`. Find the `consoleLogHandler` / `conversationStartedHandler` / `fileInputClickedHandler` constants at the top of the `UserScripts` enum (around line 14–18). Also find `createAllScripts()` and the private static source string constants.

- [ ] **Step 2: Add the `nonisolated static func createMetadataScript()` method**

After `createIMEFixScript()` (and `createFilePickerScript()`), insert:

```swift
    /// Creates a script that extracts conversation metadata from the Gemini DOM.
    /// Returns a JSON string. Wraps everything in try/catch — returns "{}" on any exception.
    /// All selectors are best-effort; missing fields are simply absent from the JSON.
    nonisolated static func createMetadataScript() -> String {
        """
        (function() {
            try {
                var url = window.location.href;
                var idMatch = url.match(/\\/app\\/([a-zA-Z0-9_-]+)/);
                var conversationId = idMatch ? idMatch[1] : null;

                var responseIndex = document.querySelectorAll('response-container').length;

                var modelEl = document.querySelector('[data-test-id="model-switcher-button"]')
                    || document.querySelector('.model-switcher-button')
                    || document.querySelector('[jsname][aria-label*="Gemini"]');
                var geminiModel = modelEl ? modelEl.textContent.trim() : null;

                var userTurns = document.querySelectorAll('user-query .query-text');
                var request = null;
                if (userTurns.length > 0) {
                    request = userTurns[userTurns.length - 1].textContent.trim();
                }

                var attachmentEls = document.querySelectorAll('.attachment-chip .attachment-name');
                var attachments = Array.from(attachmentEls)
                    .map(function(el) { return el.textContent.trim(); })
                    .filter(Boolean);

                var webkitVersion = null;
                var uaMatch = navigator.userAgent.match(/AppleWebKit\\/([\\d.]+)/);
                if (uaMatch) { webkitVersion = uaMatch[1]; }

                return JSON.stringify({
                    conversation_url: url,
                    conversation_id: conversationId,
                    conversation_title: document.title,
                    response_index: responseIndex,
                    gemini_model: geminiModel,
                    request: request,
                    attachments: attachments,
                    webkit_version: webkitVersion,
                    jsc_version: webkitVersion
                });
            } catch (e) {
                return '{}';
            }
        })();
        """
    }
```

- [ ] **Step 3: Build and verify no errors**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 4: Commit**

```bash
git add WebKit/UserScripts.swift
git commit -m "feat: add createMetadataScript for DOM metadata extraction"
```

---

## Task 4: Update AppIntentError and CaptureProgress

**Files:**
- Modify: `Intents/AppIntentError.swift`
- Modify: `Coordinators/AppCoordinator.swift` (CaptureProgress enum only)

- [ ] **Step 1: Update `directoryUnavailable` error description in `AppIntentError.swift`**

Open `Intents/AppIntentError.swift`. Find:

```swift
        case .directoryUnavailable:
            return "The artifacts directory is not accessible."
```

Replace with:

```swift
        case .directoryUnavailable:
            return "Could not access or create the artifacts directory. Choose a folder in Settings → Prompts & Artifacts."
```

- [ ] **Step 2: Update `loadDirectoryLabels()` in `SettingsView.swift` to show auto-default label**

Open `Views/SettingsView.swift`. Find `loadDirectoryLabels()`. Replace:

```swift
        if let url = bookmarkStore.resolveBookmark(for: .artifactsDirectoryBookmark) {
            artifactsDirLabel = url.lastPathComponent
        }
```

With:

```swift
        if let url = bookmarkStore.resolveBookmark(for: .artifactsDirectoryBookmark) {
            artifactsDirLabel = url.lastPathComponent
        } else {
            artifactsDirLabel = "Downloads/Artifacts"
        }
```

This ensures Settings shows `"Downloads/Artifacts"` when no custom directory bookmark is saved, matching the auto-default behavior in `performFileIO`.

- [ ] **Step 3: Add `Equatable` conformance and `.streaming` case to `CaptureProgress`**

Open `Coordinators/AppCoordinator.swift`. Find:

```swift
    enum CaptureProgress {
        case started
        case converting
        case saving
        case completed(filename: String)
        case failed(error: String)
    }
```

Replace with:

```swift
    enum CaptureProgress: Equatable {
        case started
        case converting
        case saving
        case completed(filename: String)
        case failed(error: String)      // persistent banner, shows "Open Log"
        case streaming                  // transient, auto-dismisses after 3s
    }
```

- [ ] **Step 4: Build and verify no errors**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 5: Commit**

```bash
git add Intents/AppIntentError.swift Coordinators/AppCoordinator.swift Views/SettingsView.swift
git commit -m "fix: update directoryUnavailable message; add CaptureProgress.streaming+Equatable; show Downloads/Artifacts label in Settings when no bookmark"
```

---

## Task 5: Refactor AppCoordinator capture pipeline

**Files:**
- Modify: `Coordinators/AppCoordinator.swift`

This is the largest task. Read the full current file before starting. All changes are in `AppCoordinator.swift`.

- [ ] **Step 1: Add `resolveUniqueURL` static helper**

This is a `nonisolated static` function so it can be called from `Task.detached` without capturing `self`. Add it to `AppCoordinator` just before the closing `}` of the main class body (before the `extension AppCoordinator` block):

```swift
    /// Returns a unique file URL inside dirURL by appending -1, -2, … suffixes until no collision.
    nonisolated private static func resolveUniqueURL(in dirURL: URL, filename: String) throws -> URL {
        var url = dirURL.appendingPathComponent(filename, isDirectory: false)
        var counter = 1
        let maxRetries = 100

        while FileManager.default.fileExists(atPath: url.path) && counter < maxRetries {
            let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            var ext = URL(fileURLWithPath: filename).pathExtension
            if ext.isEmpty { ext = "md" }
            url = dirURL.appendingPathComponent("\(stem)-\(counter).\(ext)", isDirectory: false)
            counter += 1
        }

        if counter >= maxRetries {
            throw AppIntentError.fileCollisionLimitExceeded
        }

        return url
    }
```

- [ ] **Step 2: Replace `performFileIO` with the new signature**

Find the entire existing `performFileIO` method:

```swift
    nonisolated private func performFileIO(markdown: String, filename: String) async throws -> String {
```

Replace the entire method with:

```swift
    nonisolated private func performFileIO(
        markdown: String,
        metadata: ArtifactMetadata,
        filename: String
    ) async throws -> String {
        return try await Task.detached(priority: .userInitiated) {
            let content = metadata.toYAMLFrontmatter() + markdown
            let bookmarkStore = BookmarkStore()

            // Priority 1: user-configured bookmark directory
            if let savedFilename = try bookmarkStore.withBookmarkedURL(
                for: .artifactsDirectoryBookmark
            ) { dirURL in
                let url = try AppCoordinator.resolveUniqueURL(in: dirURL, filename: filename)
                try content.write(to: url, atomically: true, encoding: .utf8)
                return url.lastPathComponent
            } {
                return savedFilename
            }

            // Priority 2: ~/Downloads/Artifacts (entitlement-based, no bookmark needed)
            let downloadsArtifacts = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/Artifacts", isDirectory: true)
            try FileManager.default.createDirectory(
                at: downloadsArtifacts, withIntermediateDirectories: true
            )
            let url = try AppCoordinator.resolveUniqueURL(in: downloadsArtifacts, filename: filename)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url.lastPathComponent
        }.value
    }
```

- [ ] **Step 3: Replace `captureLastResponseAsString` with `captureResponseMarkdown`**

Find the entire `captureLastResponseAsString` method and replace it:

```swift
    /// Extracts the last Gemini response as Markdown.
    /// Runs HTML extraction on @MainActor (evaluateJavaScript), then converts
    /// HTML→Markdown on a background task. Does not fetch metadata.
    func captureResponseMarkdown() async throws -> String {
        try await waitForPageReady(timeout: 10)

        let script = UserScripts.createCaptureScript(
            lastResponseSelector: GeminiSelectors.shared.lastResponseSelector
        )
        let htmlString: String = try await withCheckedThrowingContinuation { continuation in
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

        return await Task(priority: .userInitiated) {
            HTMLToMarkdown.convert(htmlString)
        }.value
    }
```

- [ ] **Step 4: Add `fetchMetadataPreview()`**

Add this method after `captureResponseMarkdown()`:

```swift
    /// Fetches conversation metadata from the DOM. Never throws.
    /// Returns partial metadata (Swift-side fields only) if the page is not ready
    /// or the JS extraction fails.
    func fetchMetadataPreview() async -> ArtifactMetadata {
        var metadata = ArtifactMetadata.empty()
        guard webViewModel.isPageReady else { return metadata }

        let script = UserScripts.createMetadataScript()
        return await withCheckedContinuation { continuation in
            webViewModel.wkWebView.evaluateJavaScript(script) { result, _ in
                guard let jsonString = result as? String,
                      !jsonString.isEmpty,
                      let data = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continuation.resume(returning: metadata)
                    return
                }

                metadata.conversationUrl = json["conversation_url"] as? String
                metadata.conversationId = json["conversation_id"] as? String
                metadata.conversationTitle = json["conversation_title"] as? String
                metadata.responseIndex = json["response_index"] as? Int
                metadata.geminiModel = json["gemini_model"] as? String
                metadata.request = json["request"] as? String
                metadata.attachments = json["attachments"] as? [String] ?? []
                metadata.webkitVersion = json["webkit_version"] as? String
                metadata.jscVersion = json["jsc_version"] as? String

                continuation.resume(returning: metadata)
            }
        }
    }
```

- [ ] **Step 5: Replace `captureLastResponse` with the new signature**

Find the entire existing `captureLastResponse` method and replace it:

```swift
    func captureLastResponse(suggestedFilename: String?, previewMetadata: ArtifactMetadata) {
        Task {
            captureProgress = .started
            do {
                captureProgress = .converting
                let markdown = try await captureResponseMarkdown()
                captureProgress = .saving
                let filename = suggestedFilename?.isEmpty == false
                    ? suggestedFilename!
                    : defaultArtifactFilename()
                await saveArtifact(markdown: markdown, metadata: previewMetadata, filename: filename)
            } catch AppIntentError.stillStreaming {
                // Streaming is transient — no log entry, no "Open Log" button
                captureProgress = .streaming
                try? await Task.sleep(for: .seconds(3))
                self.captureProgress = nil
            } catch {
                ArtifactLogger.logError(error)
                captureProgress = .failed(error: error.localizedDescription)
                // No auto-dismiss — persistent banner, dismissed by user via ×
            }
        }
    }
```

- [ ] **Step 6: Replace `saveArtifact` with the new signature**

Find the entire existing `saveArtifact` method and replace it:

```swift
    func saveArtifact(markdown: String, metadata: ArtifactMetadata, filename: String) async {
        do {
            let savedFilename = try await performFileIO(
                markdown: markdown, metadata: metadata, filename: filename
            )
            captureProgress = .completed(filename: savedFilename)
            try await Task.sleep(for: .seconds(2))
            self.captureProgress = nil
        } catch {
            ArtifactLogger.logError(error, context: [
                "filename_attempted": filename,
                "conversation_url": metadata.conversationUrl ?? ""
            ])
            captureProgress = .failed(error: error.localizedDescription)
            // No auto-dismiss — persistent banner, dismissed by user via ×
        }
    }
```

- [ ] **Step 7: Add `dismissCaptureProgress()`**

Add after `dismissInjectionBanner()`:

```swift
    func dismissCaptureProgress() {
        captureProgress = nil
    }
```

- [ ] **Step 8: Build and verify no errors**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"
```

**Note:** If the only errors reference `captureLastResponseAsString` or the old `saveArtifact(markdown:filename:)` in `CaptureLastArtifactIntent.swift`, that is expected — those callers are fixed in Task 8. Proceed to Step 9 and fix them in Task 8. The build will only fully succeed after Task 8 is complete.

- [ ] **Step 9: Commit**

```bash
git add Coordinators/AppCoordinator.swift
git commit -m "feat: refactor AppCoordinator capture pipeline with ArtifactMetadata, fetchMetadataPreview, and Downloads fallback directory"
```

---

## Task 6: Update ArtifactCaptureButton and FilenameInputSheet

**Files:**
- Modify: `Views/ArtifactCaptureButton.swift`

Read the full current file first. This task rewrites the entire file.

- [ ] **Step 1: Replace the entire file contents**

```swift
//
//  ArtifactCaptureButton.swift
//  GeminiDesktop
//

import SwiftUI
import AppKit

struct ArtifactCaptureButton: View {
    var coordinator: AppCoordinator
    @State private var showingSheet = false
    @State private var filenameInput = ""
    @State private var prefetchedMetadata: ArtifactMetadata? = nil

    var body: some View {
        Button(action: {
            Task {
                // Pre-fetch metadata before opening the sheet so the disclosure group is populated.
                // fetchMetadataPreview() never throws and completes in <50ms.
                prefetchedMetadata = await coordinator.fetchMetadataPreview()
                showingSheet = true
            }
        }) {
            Image(systemName: "square.and.arrow.down.on.square")
        }
        .disabled(coordinator.captureProgress != nil)
        .sheet(isPresented: $showingSheet) {
            // prefetchedMetadata is always set before showingSheet = true.
            // ArtifactMetadata.empty() is a defensive fallback that should never be reached.
            let metadata = prefetchedMetadata ?? ArtifactMetadata.empty()
            FilenameInputSheet(
                isPresented: $showingSheet,
                filename: $filenameInput,
                initialFilename: coordinator.defaultArtifactFilename(),
                metadata: metadata,
                onSave: {
                    coordinator.captureLastResponse(
                        suggestedFilename: filenameInput,
                        previewMetadata: metadata
                    )
                    showingSheet = false
                }
            )
        }
    }
}

private struct FilenameInputSheet: View {
    @Binding var isPresented: Bool
    @Binding var filename: String
    let initialFilename: String
    let metadata: ArtifactMetadata
    var onSave: () -> Void
    @FocusState private var isFocused: Bool
    @State private var metadataExpanded = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Save Artifact As")
                .font(.headline)

            TextField("Filename (e.g. Gemini-2026-03-20-143022.md)", text: $filename)
                .focused($isFocused)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            DisclosureGroup("Metadata", isExpanded: $metadataExpanded) {
                metadataRows
                    .padding(.top, 4)
            }
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(filename.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 360)
        .onAppear {
            filename = initialFilename
            isFocused = true
            // Use asyncAfter to let AppKit complete its focus-handling cycle before
            // setting the selection range. Without the delay, AppKit overwrites it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let editor = NSApp.keyWindow?.firstResponder as? NSText {
                    let stem = (initialFilename as NSString).deletingPathExtension
                    editor.setSelectedRange(NSRange(location: 0, length: (stem as NSString).length))
                }
            }
        }
    }

    /// Read-only metadata preview. Option B: replace Text rows with TextField bindings.
    private var metadataRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let model = metadata.geminiModel {
                metadataRow(label: "model", value: model)
            }
            if let request = metadata.request {
                metadataRow(label: "request", value: String(request.prefix(80)))
            }
            if let url = metadata.conversationUrl {
                metadataRow(label: "url", value: url)
            }
            metadataRow(
                label: "captured",
                value: metadata.capturedAt.formatted(date: .abbreviated, time: .shortened)
            )
            if !metadata.attachments.isEmpty {
                metadataRow(label: "attachments", value: metadata.attachments.joined(separator: ", "))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(label):")
                .fontWeight(.medium)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
```

- [ ] **Step 2: Build and verify no errors**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 3: Commit**

```bash
git add Views/ArtifactCaptureButton.swift
git commit -m "feat: add metadata pre-fetch, stem-only selection, and metadata disclosure to save dialog"
```

---

## Task 7: Update MainWindowView — consolidate banners

**Files:**
- Modify: `Views/MainWindowView.swift`

Read the full current file. Focus on the `.overlay(alignment: .top)` block and the `.animation` modifiers.

- [ ] **Step 1: Replace the single injection-banner overlay with a unified VStack overlay**

Find the existing overlay block (the one that shows `injectionBannerMessage`):

```swift
            .overlay(alignment: .top) {
                if let msg = coordinator.injectionBannerMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(msg)
                        Spacer()
                        Button(action: { coordinator.dismissInjectionBanner() }) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding([.horizontal, .top], 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: coordinator.injectionBannerMessage)
```

Replace it with:

```swift
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    // Injection banner (existing)
                    if let msg = coordinator.injectionBannerMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(msg)
                            Spacer()
                            Button(action: { coordinator.dismissInjectionBanner() }) {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Capture progress / feedback banner (new)
                    if let progress = coordinator.captureProgress {
                        captureBanner(progress: progress)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding([.horizontal, .top], 12)
            }
            .animation(.easeInOut(duration: 0.2), value: coordinator.injectionBannerMessage)
            .animation(.easeInOut(duration: 0.2), value: coordinator.captureProgress)
```

- [ ] **Step 2: Add the `captureBanner` helper method**

Add this private method to `MainWindowView` (after `minimizeToPrompt()`):

```swift
    @ViewBuilder
    private func captureBanner(progress: AppCoordinator.CaptureProgress) -> some View {
        switch progress {
        case .started, .converting, .saving:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.75)
                Text(progressLabel(progress))
                    .font(.callout)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

        case .completed(let filename):
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved: \(filename)")
                    .font(.callout)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

        case .streaming:
            HStack {
                Image(systemName: "waveform")
                Text("Gemini is still streaming — wait for the response to finish.")
                    .font(.callout)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

        case .failed(let error):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.callout)
                    Spacer()
                    Button {
                        coordinator.dismissCaptureProgress()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    Button("Open Log") {
                        if let url = ArtifactLogger.logFileURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(ArtifactLogger.logFileURL == nil)
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func progressLabel(_ progress: AppCoordinator.CaptureProgress) -> String {
        switch progress {
        case .started: return "Starting…"
        case .converting: return "Converting…"
        case .saving: return "Saving…"
        default: return ""
        }
    }
```

- [ ] **Step 3: Build and verify no errors**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 4: Commit**

```bash
git add Views/MainWindowView.swift
git commit -m "feat: move capture feedback to top-of-window banner with error log access"
```

---

## Task 8: Update CaptureLastArtifactIntent

**Files:**
- Modify: `Intents/CaptureLastArtifactIntent.swift`

- [ ] **Step 1: Update the intent to use the renamed and resigend coordinator methods**

The current `perform()` calls `captureLastResponseAsString()` (renamed) and `saveArtifact(markdown:filename:)` (new signature). Replace the entire `perform()` method body:

```swift
    func perform() async throws -> some IntentResult {
        guard let coordinator = AppDelegate.shared?.appCoordinator else {
            throw AppIntentError.notAuthenticated
        }

        let isReady = await MainActor.run { coordinator.webViewModel.isPageReady }
        if !isReady {
            throw AppIntentError.notAuthenticated
        }

        // Fetch metadata and response in sequence on the main actor
        let metadata = await coordinator.fetchMetadataPreview()
        let markdownContent = try await coordinator.captureResponseMarkdown()

        if markdownContent.isEmpty {
            throw AppIntentError.noResponseAvailable
        }

        let artifactFilename = filename.isEmpty
            ? await coordinator.defaultArtifactFilename()
            : (filename.hasSuffix(".md") ? filename : filename + ".md")

        await coordinator.saveArtifact(
            markdown: markdownContent,
            metadata: metadata,
            filename: artifactFilename
        )

        return .result(dialog: "Response captured as '\(artifactFilename)'")
    }
```

- [ ] **Step 2: Build and verify no errors**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 3: Commit**

```bash
git add Intents/CaptureLastArtifactIntent.swift
git commit -m "fix: update CaptureLastArtifactIntent to use captureResponseMarkdown and new saveArtifact signature"
```

---

## Task 9: Manual Integration Testing

**Files:** None (testing only)

Run the app with Cmd+R in Xcode and work through the checklist. Open a Gemini conversation and generate at least one response before testing.

- [ ] **Default directory — first run**

```bash
# Clear any saved artifacts bookmark to simulate first run
defaults delete $(defaults domains | tr ',' '\n' | grep -i gemini | head -1) artifactsDirectoryBookmark 2>/dev/null || true
```

Trigger a capture. Verify `~/Downloads/Artifacts/` is created and the file lands there.

- [ ] **Settings label**

Open Settings → Prompts & Artifacts. Verify the Artifacts Folder label shows `"Downloads/Artifacts"` (not "No folder selected").

- [ ] **User-chosen directory**

Click "Choose…" in Settings, pick a custom folder. Trigger a capture. Verify the file goes to the custom folder, not Downloads/Artifacts.

- [ ] **YAML header**

Open a saved `.md` file in a text editor. Verify:
- `schema_version`, `captured_at`, `tool`, `source` are present
- `conversation_url`, `gemini_model`, `request` are populated (not empty)
- `attachments: []` and `tags: []` are present
- No `nil` literal values appear anywhere in the YAML block

- [ ] **Pre-fetch metadata in disclosure group**

Click the capture button. Before clicking Save in the sheet, expand "Metadata". Verify model, request, and URL are populated with real data from the current conversation.

- [ ] **Filename selection**

In the save sheet, verify only the stem (`Gemini-2026-03-20-143000`) is selected, not the `.md` extension. Start typing — verify it replaces only the stem.

- [ ] **Success banner**

Save an artifact. Verify:
- A green "Saved: filename.md" banner appears at the top of the window (below the toolbar)
- It auto-dismisses after ~2 seconds
- The capture button re-enables after dismissal

- [ ] **Error banner — persistent**

1. After a successful save, note the `~/Downloads/Artifacts` path
2. Move `~/Downloads/Artifacts` to the Trash while the app is running (and no custom directory is set)
3. Trigger another capture
4. Verify: an orange error banner appears at top of window and does NOT auto-dismiss
5. Verify: "Open Log" and × buttons are present

- [ ] **Open Log button**

Click "Open Log" in the error banner. Verify Console.app opens and the log entry is visible with a timestamp and the error description.

- [ ] **× dismiss**

Click × on the error banner. Verify the banner disappears and the capture button re-enables.

- [ ] **Log file location**

```bash
BUNDLE=$(osascript -e 'id of app "GeminiDesktop"' 2>/dev/null || echo "com.example.GeminiDesktop")
ls ~/Library/Containers/$BUNDLE/Data/Library/Logs/GeminiDesktop/
```

Verify `gemini-desktop.log` exists with at least one error entry.

- [ ] **Streaming guard**

Send a long prompt to Gemini. While it is mid-stream, click the capture button and immediately click Save. Verify: a transient "still streaming" banner appears and auto-dismisses after ~3 seconds. No log file entry is written.

- [ ] **Simultaneous banners**

1. Trigger a prompt injection error (e.g., inject while page is loading)
2. While the injection error banner is visible, trigger a capture that also errors
3. Verify both banners stack vertically below the toolbar in a single overlay

- [ ] **Verify git log**

```bash
git log --oneline -8
```

Expected commits (most recent first):
1. `fix: update CaptureLastArtifactIntent to use captureResponseMarkdown and new saveArtifact signature`
2. `feat: move capture feedback to top-of-window banner with error log access`
3. `feat: add metadata pre-fetch, stem-only selection, and metadata disclosure to save dialog`
4. `feat: refactor AppCoordinator capture pipeline with ArtifactMetadata, fetchMetadataPreview, and Downloads fallback directory`
5. `fix: update directoryUnavailable message; add CaptureProgress.streaming case and Equatable`
6. `feat: add createMetadataScript for DOM metadata extraction`
7. `feat: add ArtifactLogger for structured error logging to container Logs dir`
8. `feat: add ArtifactMetadata value type with YAML serialization`
