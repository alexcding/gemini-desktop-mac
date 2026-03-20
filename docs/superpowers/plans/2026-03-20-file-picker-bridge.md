# File Picker Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the "Add files" button in Gemini Desktop by bridging WKWebView's blocked programmatic file input clicks to a native `NSOpenPanel` via `WKScriptMessageHandler` + `WKURLSchemeHandler`.

**Architecture:** A JS user script intercepts `HTMLInputElement.prototype.click` on file inputs and posts a message to Swift. Swift presents `NSOpenPanel`, registers selected files in `GeminiFileSchemeHandler` (a custom URL scheme handler), then calls back to JS with `gemini-file://` URLs. JS fetches those URLs, reconstructs `File` objects via `DataTransfer`, and injects them into the original file input.

**Tech Stack:** Swift, WKWebKit (`WKURLSchemeHandler`, `WKScriptMessageHandler`), AppKit (`NSOpenPanel`), `UniformTypeIdentifiers` (MIME detection), JavaScript (`DataTransfer`, `fetch`). No new Swift Package dependencies.

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `WebKit/GeminiFileSchemeHandler.swift` | `WKURLSchemeHandler`: thread-safe file registry, disk reads, CORS headers, task lifecycle |
| Modify | `WebKit/WebViewModel.swift` | Add `FilePickerHandler` class; add stored properties; update `createWebView` to register scheme handler; register message handler in `init` |
| Modify | `WebKit/UserScripts.swift` | Add `fileInputClickedHandler` constant; add `filePickerSource` JS; include in `createAllScripts()` |
| Modify | `WebKit/GeminiWebView.swift` | Remove `runOpenPanelWith` method; remove 3 debug `[DEBUG]` prints |

---

## Task 1: Create GeminiFileSchemeHandler

**Files:**
- Create: `WebKit/GeminiFileSchemeHandler.swift`

- [ ] **Step 1: Create the file with full implementation**

Create `WebKit/GeminiFileSchemeHandler.swift` with this exact content:

```swift
//
//  GeminiFileSchemeHandler.swift
//  GeminiDesktop
//

import WebKit
import UniformTypeIdentifiers

/// Custom URL scheme handler that serves locally selected files to the Gemini web page.
///
/// Files are registered under `gemini-file://[uuid]/[filename]` URLs and served
/// directly from disk on request. This allows JS to reconstruct File objects from
/// native NSOpenPanel selections without base64 encoding.
final class GeminiFileSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "gemini-file"

    private let lock = NSLock()
    private var registry: [String: URL] = [:]           // uuid → local file URL
    private var activeTasks: Set<ObjectIdentifier> = []  // tasks currently in flight

    // MARK: - Registry

    /// Register an array of local file URLs. Returns the corresponding gemini-file:// URLs.
    func register(files: [URL]) -> [String] {
        lock.withLock {
            files.map { fileURL in
                let uuid = UUID().uuidString
                registry[uuid] = fileURL
                let encoded = fileURL.lastPathComponent
                    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileURL.lastPathComponent
                return "\(Self.scheme)://\(uuid)/\(encoded)"
            }
        }
    }

    /// Clear all registered files. Call before presenting a new NSOpenPanel.
    func clearRegistry() {
        lock.withLock { registry = [:] }
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let taskId = ObjectIdentifier(urlSchemeTask)
        lock.withLock { activeTasks.insert(taskId) }

        guard let url = urlSchemeTask.request.url,
              let uuid = url.host else {
            failTask(urlSchemeTask, id: taskId, error: URLError(.badURL))
            return
        }

        let fileURL: URL? = lock.withLock { registry[uuid] }
        guard let fileURL else {
            failTask(urlSchemeTask, id: taskId, error: URLError(.fileDoesNotExist))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let data = try Data(contentsOf: fileURL)
                let mimeType = self.mimeType(for: fileURL)
                let headers: [String: String] = [
                    "Content-Type": mimeType,
                    "Content-Length": "\(data.count)",
                    "Access-Control-Allow-Origin": "*"
                ]
                guard let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                ) else { return }

                self.lock.withLock {
                    guard self.activeTasks.contains(taskId) else { return }
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                    self.activeTasks.remove(taskId)
                }
            } catch {
                self.failTask(urlSchemeTask, id: taskId, error: error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        lock.withLock { activeTasks.remove(ObjectIdentifier(urlSchemeTask)) }
    }

    // MARK: - Private

    private func failTask(_ task: any WKURLSchemeTask, id: ObjectIdentifier, error: Error) {
        lock.withLock {
            guard activeTasks.contains(id) else { return }
            task.didFailWithError(error)
            activeTasks.remove(id)
        }
    }

    private func mimeType(for url: URL) -> String {
        guard let utType = UTType(filenameExtension: url.pathExtension),
              let mime = utType.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }
}
```

- [ ] **Step 2: Verify sandbox entitlement is present**

Open `Resources/GeminiDesktop.entitlements` and confirm this key exists:

```xml
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

`NSOpenPanel` returns security-scoped URLs; without this entitlement `Data(contentsOf:)` on those URLs fails silently. The entitlement should already be present (it was added for the download feature). If missing, add it now.

- [ ] **Step 3: Add the new file to the Xcode project**

In Xcode, right-click the `WebKit` group in the Project Navigator and choose **"Add Files to 'GeminiDesktop'..."**. Navigate to `WebKit/GeminiFileSchemeHandler.swift`, ensure the **GeminiDesktop** target checkbox is ticked, and click **Add**.

Xcode must reference the file or it will not be compiled — `xcodebuild` only builds files listed in `project.pbxproj`.

- [ ] **Step 4: Build and verify no errors**

```bash
cd /Users/zmarkley/src/github.com/alexcding/gemini-desktop-mac
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 5: Commit**

```bash
git add WebKit/GeminiFileSchemeHandler.swift GeminiDesktop.xcodeproj/project.pbxproj
git commit -m "feat: add GeminiFileSchemeHandler for serving selected files via custom URL scheme"
```

---

## Task 2: Add FilePickerHandler and wire up WebViewModel

**Files:**
- Modify: `WebKit/WebViewModel.swift`

- [ ] **Step 1: Add FilePickerHandler class after ConsoleLogHandler**

Open `WebViewModel.swift`. After the closing `}` of `ConsoleLogHandler` (line 19), insert this new class:

```swift
/// Receives fileInputClicked messages from JS, presents NSOpenPanel, and
/// calls back to JS with gemini-file:// URLs for the selected files.
@MainActor
final class FilePickerHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private let schemeHandler: GeminiFileSchemeHandler

    init(webView: WKWebView, schemeHandler: GeminiFileSchemeHandler) {
        self.webView = webView
        self.schemeHandler = schemeHandler
    }

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let multiple = body["multiple"] as? Bool,
              let nonce = body["nonce"] as? String else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        // Clear previous registrations only after the new panel is about to present,
        // so any in-flight fetch requests from the previous selection can still complete.
        schemeHandler.clearRegistry()

        panel.begin { [weak self] response in
            guard let self, let webView = self.webView else { return }
            let jsCallback: String
            if response == .OK, !panel.urls.isEmpty {
                let urls = self.schemeHandler.register(files: panel.urls)
                let urlsJSON = urls
                    .map { "\"\($0)\"" }
                    .joined(separator: ", ")
                jsCallback = "window.__GeminiDesktop.filesSelected('\(nonce)', [\(urlsJSON)])"
            } else {
                jsCallback = "window.__GeminiDesktop.filesSelected('\(nonce)', [])"
            }
            webView.evaluateJavaScript(jsCallback, completionHandler: nil)
        }
    }
}
```

- [ ] **Step 2: Add stored properties to WebViewModel**

In `WebViewModel`, find the `// MARK: - Private Properties` section (around line 62). Add two new stored properties after `private let navigationDelegate = WebViewNavigationDelegate()`:

```swift
    private let schemeHandler: GeminiFileSchemeHandler
    private let filePickerHandler: FilePickerHandler
```

- [ ] **Step 3: Update createWebView to accept and register the scheme handler**

Find `private static func createWebView(consoleLogHandler: ConsoleLogHandler) -> WKWebView` (around line 169). Change the signature and add scheme handler registration just before `let webView = WKWebView(...)`:

Change:
```swift
    private static func createWebView(consoleLogHandler: ConsoleLogHandler) -> WKWebView {
        let configuration = WKWebViewConfiguration()
```

To:
```swift
    private static func createWebView(
        consoleLogHandler: ConsoleLogHandler,
        schemeHandler: GeminiFileSchemeHandler
    ) -> WKWebView {
        let configuration = WKWebViewConfiguration()
```

Then, immediately after `configuration.mediaTypesRequiringUserActionForPlayback = []` and before `// Add user scripts`, insert:

```swift
        // Register custom scheme handler for serving locally selected files
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: GeminiFileSchemeHandler.scheme)
```

- [ ] **Step 4: Update WebViewModel.init to initialize new properties and call updated createWebView**

Find the `init()` method (around line 70). Replace it entirely:

```swift
    init() {
        // Initialize scheme handler first — must be registered on config before WebView is created
        let schemeHandler = GeminiFileSchemeHandler()
        let webView = Self.createWebView(consoleLogHandler: consoleLogHandler, schemeHandler: schemeHandler)
        let filePickerHandler = FilePickerHandler(webView: webView, schemeHandler: schemeHandler)

        self.schemeHandler = schemeHandler
        self.wkWebView = webView
        self.filePickerHandler = filePickerHandler

        // Register file picker message handler after WebView exists
        webView.configuration.userContentController.add(
            filePickerHandler,
            name: UserScripts.fileInputClickedHandler
        )

        self.wkWebView.navigationDelegate = navigationDelegate

        navigationDelegate.onPageReady = { [weak self] in
            self?.isPageReady = true
        }
        navigationDelegate.onNavigationStart = { [weak self] in
            self?.isPageReady = false
        }

        setupObservers()
        loadHome()
    }
```

- [ ] **Step 5: Build and verify no errors**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 6: Commit**

```bash
git add WebKit/WebViewModel.swift
git commit -m "feat: add FilePickerHandler and wire GeminiFileSchemeHandler into WebViewModel"
```

---

## Task 3: Add file picker JS user script to UserScripts

**Files:**
- Modify: `WebKit/UserScripts.swift`

- [ ] **Step 1: Add the fileInputClickedHandler constant**

In `UserScripts`, find the existing constants at the top of the enum (around line 14):

```swift
    static let consoleLogHandler = "consoleLog"
    static let conversationStartedHandler = "conversationStarted"
```

Add after `conversationStartedHandler`:

```swift
    /// Message handler name for native file picker bridge
    static let fileInputClickedHandler = "fileInputClicked"
```

- [ ] **Step 2: Add createFilePickerScript factory method**

After `createIMEFixScript()` (around line 59), add:

```swift
    /// Creates a script that intercepts file input clicks and routes them through
    /// the native file picker bridge.
    nonisolated private static func createFilePickerScript() -> WKUserScript {
        WKUserScript(
            source: filePickerSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }
```

- [ ] **Step 3: Add filePickerSource JS string**

After the closing `"""` of `imeFixSource` (before the `// MARK: - Prompt Injection` comment), add:

```swift
    /// JavaScript that intercepts hidden file input clicks and routes them to
    /// the native NSOpenPanel via WKScriptMessageHandler.
    ///
    /// Flow: input.click() intercept → postMessage → Swift NSOpenPanel
    ///   → evaluateJavaScript callback → fetch(gemini-file://) → DataTransfer → input.files
    private static let filePickerSource = """
    (function() {
        window.__GeminiDesktop = window.__GeminiDesktop || {};

        var pendingFileInput = null;
        var pendingNonce = null;

        // Intercept programmatic clicks on hidden file inputs.
        // WKWebView drops these silently (gesture token expired by the time
        // Gemini's async code calls click()). We route them native instead.
        var origClick = HTMLInputElement.prototype.click;
        HTMLInputElement.prototype.click = function() {
            if (this.type === 'file') {
                pendingFileInput = this;
                pendingNonce = Math.random().toString(36).slice(2);
                window.webkit.messageHandlers.\(fileInputClickedHandler).postMessage({
                    multiple: this.multiple,
                    accept: this.accept || '',
                    nonce: pendingNonce
                });
            } else {
                origClick.call(this);
            }
        };

        // Called by Swift after NSOpenPanel completes.
        // urls: array of gemini-file:// strings, or empty on cancel.
        window.__GeminiDesktop.filesSelected = function(nonce, urls) {
            if (nonce !== pendingNonce) { return; } // stale response from a previous picker
            var input = pendingFileInput;
            pendingFileInput = null;
            pendingNonce = null;
            if (!input || !urls.length) { return; }

            Promise.all(urls.map(function(url) {
                return fetch(url).then(function(r) {
                    var type = r.headers.get('Content-Type') || 'application/octet-stream';
                    var rawName = new URL(url).pathname.split('/').pop() || 'file';
                    var name = decodeURIComponent(rawName);
                    return r.arrayBuffer().then(function(buf) {
                        return new File([buf], name, { type: type });
                    });
                });
            })).then(function(files) {
                var dt = new DataTransfer();
                files.forEach(function(f) { dt.items.add(f); });
                input.files = dt.files; // supported in WebKit via DataTransfer
                input.dispatchEvent(new Event('change', { bubbles: true }));
                input.dispatchEvent(new Event('input', { bubbles: true }));
            }).catch(function(err) {
                console.error('[GeminiDesktop] File picker error:', err);
            });
        };
    })();
    """
```

- [ ] **Step 4: Include file picker script in createAllScripts()**

Find `createAllScripts()` (around line 20). Add `createFilePickerScript()` to the scripts array:

Change:
```swift
        var scripts: [WKUserScript] = [
            createConversationObserverScript(),
            createIMEFixScript()
        ]
```

To:
```swift
        var scripts: [WKUserScript] = [
            createConversationObserverScript(),
            createIMEFixScript(),
            createFilePickerScript()
        ]
```

- [ ] **Step 5: Build and verify no errors**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 6: Commit**

```bash
git add WebKit/UserScripts.swift
git commit -m "feat: add file picker JS bridge user script"
```

---

## Task 4: Clean up GeminiWebView

**Files:**
- Modify: `WebKit/GeminiWebView.swift`

- [ ] **Step 1: Remove runOpenPanelWith method**

In `GeminiWebView.swift`, find and delete the entire `runOpenPanelWith` method (lines 126–135):

```swift
        nonisolated func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @Sendable ([URL]?) -> Void) {
            print("[DEBUG] runOpenPanelWith called — uiDelegate: \(String(describing: webView.uiDelegate)), thread: \(Thread.isMainThread ? "main" : "background")")
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            panel.begin { [completionHandler] response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }
```

This method is permanently bypassed by the JS intercept — removing it prevents future maintainer confusion.

- [ ] **Step 2: Remove the two remaining debug print statements**

The third `[DEBUG]` print was inside `runOpenPanelWith` and was already eliminated in Step 1. Remove these two standalone prints:

In `setupWindowObserver` (around line 185), remove:
```swift
            print("[DEBUG] window became key — uiDelegate is now: \(String(describing: self.webView.uiDelegate))")
```

In `attachWebView` (around line 211), remove:
```swift
        print("[DEBUG] attachWebView — uiDelegate set to coordinator \(ObjectIdentifier(coordinator))")
```

- [ ] **Step 3: Build and verify no errors**

```bash
xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 4: Commit**

```bash
git add WebKit/GeminiWebView.swift
git commit -m "refactor: remove runOpenPanelWith and debug prints (file picker now uses JS bridge)"
```

---

## Task 5: Manual Integration Testing

**Files:** None (testing only)

- [ ] **Step 1: Run the app**

Open `GeminiDesktop.xcodeproj` in Xcode and run with Cmd+R (or build + open from terminal).

- [ ] **Step 2: Test single file upload**

1. Open a new Gemini conversation
2. Click the "Add files" / paperclip icon
3. **Verify:** macOS file picker (Open dialog) appears
4. Select a single image file (e.g. a PNG)
5. **Verify:** The file appears attached to the Gemini input area
6. Send the message
7. **Verify:** Gemini receives and processes the file

- [ ] **Step 3: Test multiple file upload**

1. Click "Add files" again
2. In the Open dialog, select multiple files (Cmd+click)
3. **Verify:** Multiple files appear attached
4. Send — **Verify:** Gemini receives all files

- [ ] **Step 4: Test cancel**

1. Click "Add files"
2. Press Escape or click Cancel in the Open dialog
3. **Verify:** No files are attached, input field is unchanged

- [ ] **Step 5: Test rapid re-open (race condition)**

1. Click "Add files", then immediately click it again before selecting
2. **Verify:** The second Open dialog appears cleanly, no crash, no stale state

- [ ] **Step 6: Verify debug output is clean**

Open Xcode console. Confirm no `[DEBUG]` lines appear. Confirm no `[GeminiDesktop] File picker error:` lines in the web inspector console.

- [ ] **Step 7: Verify git log**

```bash
git log --oneline -5
```

Expected output includes (in order):
1. `refactor: remove runOpenPanelWith and debug prints (file picker now uses JS bridge)`
2. `feat: add file picker JS bridge user script`
3. `feat: add FilePickerHandler and wire GeminiFileSchemeHandler into WebViewModel`
4. `feat: add GeminiFileSchemeHandler for serving selected files via custom URL scheme`
