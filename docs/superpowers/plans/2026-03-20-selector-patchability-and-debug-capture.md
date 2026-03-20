# Selector Patchability & Debug Capture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make all Gemini DOM selectors user-patchable via a drop-in JSON file, and add an opt-in debug capture tool that exports page state for selector diagnosis.

**Architecture:** Feature A extends `GeminiSelectors` with 6 metadata selector fields and adds user-file loading priority (Application Support before bundle). Feature B adds a fetch interceptor, JS capture scripts, AppCoordinator capture methods, a conditional Debug menu, and Settings UI. All new code follows existing patterns: `AppCoordinator` as hub, `UserScripts` for JS, `UserDefaultsKeys` for feature flags, separate handler classes for `WKScriptMessageHandler`.

**Tech Stack:** Swift, SwiftUI, WKWebView JS injection, FileManager (Application Support), `CommandMenu` (SwiftUI)

---

## File Map

| File | Change |
|---|---|
| `Utils/UserDefaultsKeys.swift` | Add `debugModeEnabled` case |
| `WebKit/GeminiSelectors.swift` | Add 6 fields + user-file loading priority |
| `Resources/gemini-selectors.json` | Add 6 new fields |
| `WebKit/UserScripts.swift` | Parameterize `createMetadataScript()`; add DOM, WIZ, interceptor scripts |
| `WebKit/WebViewModel.swift` | Add `DebugNetworkHandler` class; conditional interceptor injection in `init()` |
| `Coordinators/AppCoordinator.swift` | Add `debugCaptureBannerMessage`, capture methods, file I/O |
| `Views/SettingsView.swift` | Add Selectors status row; add Advanced section with debug toggle |
| `App/GeminiDesktopApp.swift` | Add conditional `CommandMenu("Debug")` |
| `Views/MainWindowView.swift` | Add debug capture confirmation banner to existing overlay |

---

## Task 1: Add debugModeEnabled to UserDefaultsKeys

**Files:**
- Modify: `Utils/UserDefaultsKeys.swift:12-24`

- [ ] **Step 1: Add the case**

In `Utils/UserDefaultsKeys.swift`, add `debugModeEnabled` to the enum (after `promptInjectionMode`):

```swift
enum UserDefaultsKeys: String {
    case panelWidth
    case panelHeight
    case pageZoom
    case hideWindowAtLaunch
    case hideDockIcon
    case appTheme
    case useCustomToolbarColor
    case toolbarColorHex
    case promptsDirectoryBookmark
    case artifactsDirectoryBookmark
    case promptInjectionMode   // "copy" | "inject"
    case debugModeEnabled
}
```

- [ ] **Step 2: Build to verify**

Open Xcode, press Cmd+B. Expected: Build Succeeded.

- [ ] **Step 3: Commit**

```bash
git add Utils/UserDefaultsKeys.swift
git commit -m "feat: add debugModeEnabled UserDefaults key"
```

---

## Task 2: Extend GeminiSelectors with new fields and user-file loading

**Files:**
- Modify: `WebKit/GeminiSelectors.swift`
- Modify: `Resources/gemini-selectors.json`

`GeminiSelectors` is a `Codable` struct currently with 8 fields loaded from bundle JSON. We add 6 metadata selector fields and a two-path load priority (user file first, bundle fallback). The `static let shared` is replaced with a tuple-based pattern to safely expose an `isUsingUserFile` flag without mutating state inside a lazy initializer.

- [ ] **Step 1: Replace GeminiSelectors.swift**

Replace the entire content of `WebKit/GeminiSelectors.swift`:

```swift
//
//  GeminiSelectors.swift
//  GeminiDesktop
//

import Foundation

struct GeminiSelectors: Codable {

    // MARK: - Existing fields (unchanged)

    let conversationContainer: String
    let responseContainer: String
    let goodResponseButton: String
    let badResponseButton: String
    let promptInput: String
    let richTextareaSelector: String
    let sendButtonSelector: String
    let lastResponseSelector: String

    // MARK: - New metadata selector fields

    let conversationTitleSelector: String
    let modelSelector: String
    let modelSelectorFallback: String
    let userQuerySelector: String
    let attachmentSelector: String
    let streamingIndicatorSelector: String

    // MARK: - Loading

    /// Computed once at first access. Returns (selectors, fromUserFile).
    private static let _loaded: (selectors: GeminiSelectors, fromUserFile: Bool) = {
        // Priority 1: user override at ~/Library/Application Support/GeminiDesktop/
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            let userURL = appSupport
                .appendingPathComponent("GeminiDesktop/gemini-selectors.json")
            if FileManager.default.fileExists(atPath: userURL.path),
               let data = try? Data(contentsOf: userURL),
               let loaded = try? JSONDecoder().decode(GeminiSelectors.self, from: data) {
                return (loaded, true)
            }
        }

        // Priority 2: bundled default
        guard let bundleURL = Bundle.main.url(
            forResource: "gemini-selectors", withExtension: "json"
        ),
              let data = try? Data(contentsOf: bundleURL),
              let loaded = try? JSONDecoder().decode(GeminiSelectors.self, from: data)
        else {
            return (.default, false)
        }
        return (loaded, false)
    }()

    static var shared: GeminiSelectors { _loaded.selectors }

    /// True if a valid user override file was found at launch.
    static var isUsingUserFile: Bool { _loaded.fromUserFile }

    // MARK: - Hardcoded fallback (used only if JSON is missing or corrupt)

    static let `default` = GeminiSelectors(
        conversationContainer: "infinite-scroller[data-test-id='chat-history-container']",
        responseContainer: "response-container",
        goodResponseButton: "[aria-label='Good response']",
        badResponseButton: "[aria-label='Bad response']",
        promptInput: "rich-textarea[aria-label='Enter a prompt here']",
        richTextareaSelector: "rich-textarea[aria-label='Enter a prompt here']",
        sendButtonSelector: "button[aria-label='Send message']",
        lastResponseSelector: "model-response:last-of-type",
        conversationTitleSelector: "a.conversation.selected",
        modelSelector: "[data-test-id=\"bard-mode-menu-button\"]",
        modelSelectorFallback: "[data-test-id=\"logo-pill-label-container\"]",
        userQuerySelector: "user-query .query-text-line",
        attachmentSelector: ".attachment-chip .attachment-name",
        streamingIndicatorSelector: "button.send-button.stop"
    )
}
```

- [ ] **Step 2: Update Resources/gemini-selectors.json**

Replace the content of `Resources/gemini-selectors.json` with all 14 fields:

```json
{
  "conversationContainer": "infinite-scroller[data-test-id='chat-history-container']",
  "responseContainer": "response-container",
  "goodResponseButton": "[aria-label='Good response']",
  "badResponseButton": "[aria-label='Bad response']",
  "promptInput": "rich-textarea[aria-label='Enter a prompt here']",
  "richTextareaSelector": "rich-textarea[aria-label='Enter a prompt here']",
  "sendButtonSelector": "button[aria-label='Send message']",
  "lastResponseSelector": "model-response:last-of-type",
  "conversationTitleSelector": "a.conversation.selected",
  "modelSelector": "[data-test-id=\"bard-mode-menu-button\"]",
  "modelSelectorFallback": "[data-test-id=\"logo-pill-label-container\"]",
  "userQuerySelector": "user-query .query-text-line",
  "attachmentSelector": ".attachment-chip .attachment-name",
  "streamingIndicatorSelector": "button.send-button.stop"
}
```

- [ ] **Step 3: Build to verify**

Press Cmd+B. Expected: Build Succeeded. The new fields will now be available as `GeminiSelectors.shared.conversationTitleSelector` etc.

- [ ] **Step 4: Commit**

```bash
git add WebKit/GeminiSelectors.swift Resources/gemini-selectors.json
git commit -m "feat: extend GeminiSelectors with metadata fields and user-file loading priority"
```

---

## Task 3: Parameterize createMetadataScript() from GeminiSelectors.shared

**Files:**
- Modify: `WebKit/UserScripts.swift:78-124`

The metadata selectors are currently hardcoded in the JS string. Replace them with interpolated values from `GeminiSelectors.shared`. Behavior is identical — only the source of the strings changes.

- [ ] **Step 1: Replace createMetadataScript()**

In `WebKit/UserScripts.swift`, replace lines 78–124 (`createMetadataScript()` function) with:

```swift
    /// Creates a script that extracts conversation metadata from the Gemini DOM.
    /// Returns a JSON string. Wraps everything in try/catch — returns "{}" on any exception.
    /// Selectors sourced from GeminiSelectors.shared (user-patchable via gemini-selectors.json).
    nonisolated static func createMetadataScript() -> String {
        let s = GeminiSelectors.shared
        return """
        (function() {
            try {
                var url = window.location.href;
                var idMatch = url.match(/\\/app\\/([a-zA-Z0-9_-]+)/);
                var conversationId = idMatch ? idMatch[1] : null;

                var responseIndex = document.querySelectorAll('\(s.responseContainer)').length;

                var modelEl = document.querySelector('\(s.modelSelector)')
                    || document.querySelector('\(s.modelSelectorFallback)');
                var geminiModel = modelEl ? modelEl.textContent.trim() : null;

                var userTurns = document.querySelectorAll('\(s.userQuerySelector)');
                var request = null;
                if (userTurns.length > 0) {
                    request = userTurns[userTurns.length - 1].textContent.trim();
                }

                var attachmentEls = document.querySelectorAll('\(s.attachmentSelector)');
                var attachments = Array.from(attachmentEls)
                    .map(function(el) { return el.textContent.trim(); })
                    .filter(Boolean);

                var webkitVersion = null;
                var uaMatch = navigator.userAgent.match(/AppleWebKit\\/([\\d.]+)/);
                if (uaMatch) { webkitVersion = uaMatch[1]; }

                return JSON.stringify({
                    conversation_url: url,
                    conversation_id: conversationId,
                    conversation_title: (document.querySelector('\(s.conversationTitleSelector)') || {textContent: ''}).textContent.trim() || null,
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

- [ ] **Step 2: Build to verify**

Press Cmd+B. Expected: Build Succeeded. Metadata extraction behavior is unchanged.

- [ ] **Step 3: Commit**

```bash
git add WebKit/UserScripts.swift
git commit -m "refactor: source metadata selectors from GeminiSelectors.shared instead of hardcoding"
```

---

## Task 4: Feature A Settings UI — Selectors status row

**Files:**
- Modify: `Views/SettingsView.swift`

Add a row to the existing "Prompts & Artifacts" section showing whether the user override file is active, and a "Reveal in Finder" button for the Application Support directory.

- [ ] **Step 1: Add selectorSource state property**

In `SettingsView`, add this `@State` property after `artifactsDirLabel`:

```swift
@State private var selectorSource: String = ""
```

- [ ] **Step 2: Load selectorSource in loadDirectoryLabels()**

In the existing `loadDirectoryLabels()` method (line 161), append at the end:

```swift
selectorSource = GeminiSelectors.isUsingUserFile ? "Custom (user file)" : "Default (bundled)"
```

- [ ] **Step 3: Add Selectors row to Prompts & Artifacts section**

In the `Section("Prompts & Artifacts")` block (around line 138, after the Injection Mode picker), add:

```swift
HStack {
    VStack(alignment: .leading, spacing: 2) {
        Text("Selectors")
        Text(selectorSource.isEmpty ? "Default (bundled)" : selectorSource)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    Spacer()
    Button("Reveal in Finder") {
        revealSelectorsDirectory()
    }
}
```

- [ ] **Step 4: Add revealSelectorsDirectory() helper**

Add this private method to `SettingsView`:

```swift
private func revealSelectorsDirectory() {
    guard let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first else { return }
    let dir = appSupport.appendingPathComponent("GeminiDesktop")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    NSWorkspace.shared.open(dir)
}
```

- [ ] **Step 5: Build and manually verify**

Press Cmd+B. Run the app, open Settings → Prompts & Artifacts. Verify the "Selectors" row appears showing "Default (bundled)". Click "Reveal in Finder" — it should open (and create if needed) `~/Library/Application Support/GeminiDesktop/` in Finder.

- [ ] **Step 6: Commit**

```bash
git add Views/SettingsView.swift
git commit -m "feat: add Selectors status row and Reveal in Finder to Settings"
```

---

## Task 5: Add debug capture scripts to UserScripts

**Files:**
- Modify: `WebKit/UserScripts.swift`
- Modify: `WebKit/UserScripts.swift` (add `debugNetworkCaptureHandler` constant)

Add three static script-builder methods and one new handler name constant at the bottom of the `UserScripts` enum, before the closing `}`.

- [ ] **Step 1: Add debugNetworkCaptureHandler constant**

After the existing handler constants (around line 20), add:

```swift
/// Message handler name for debug network payload capture
static let debugNetworkCaptureHandler = "debugNetworkCapture"
```

- [ ] **Step 2: Add the three capture script methods**

Add after the `createCaptureScript` method (after line 481), before the closing `}` of the enum:

```swift
    // MARK: - Debug Capture Scripts

    /// DOM capture: selector probe + all data-test-id elements + structural data-ved/jsaction nodes.
    /// selectorJSON: JSON string of { fieldName: cssSelector } pairs built by AppCoordinator.
    nonisolated static func createDOMCaptureScript(selectorJSON: String) -> String {
        """
        (function() {
            try {
                var selectors = \(selectorJSON);

                // 1. Selector probe — hit/miss + element details for each field
                var selectorProbe = Object.keys(selectors).map(function(field) {
                    var sel = selectors[field];
                    var el = document.querySelector(sel);
                    return {
                        field: field,
                        selector: sel,
                        found: el !== null,
                        tag: el ? el.tagName : null,
                        classes: el ? (el.className || '').toString().slice(0, 100) : null,
                        dataTestId: el ? el.getAttribute('data-test-id') : null,
                        ariaLabel: el ? el.getAttribute('aria-label') : null,
                        textSnippet: el ? el.textContent.trim().slice(0, 80) : null
                    };
                });

                // 2. All visible data-test-id elements (primary lookup table for replacements)
                var dataTestIds = Array.from(document.querySelectorAll('[data-test-id]'))
                    .filter(function(el) { return el.offsetParent !== null; })
                    .map(function(el) {
                        return {
                            tag: el.tagName,
                            dataTestId: el.getAttribute('data-test-id'),
                            ariaLabel: el.getAttribute('aria-label'),
                            text: el.textContent.trim().slice(0, 60)
                        };
                    });

                // 3. Structural Wiz elements, capped at 200
                var structural = Array.from(document.querySelectorAll('[data-ved], [jsaction]'))
                    .slice(0, 200)
                    .map(function(el) {
                        return {
                            tag: el.tagName,
                            classes: (el.className || '').toString().slice(0, 80),
                            dataVed: el.getAttribute('data-ved'),
                            jsaction: (el.getAttribute('jsaction') || '').slice(0, 100),
                            jscontroller: el.getAttribute('jscontroller')
                        };
                    });

                return JSON.stringify({
                    selectorProbe: selectorProbe,
                    dataTestIds: dataTestIds,
                    structural: structural
                });
            } catch(e) {
                return JSON.stringify({ error: e.message });
            }
        })();
        """
    }

    /// WIZ state capture: serializes window.WIZ_global_data.
    nonisolated static func createWIZCaptureScript() -> String {
        """
        (function() {
            try {
                return JSON.stringify(window.WIZ_global_data || {});
            } catch(e) {
                return JSON.stringify({ error: e.message });
            }
        })();
        """
    }

    /// Fetch interceptor — injected at document start when debug mode is on.
    /// Passively buffers batchexecute payloads and posts them to the
    /// 'debugNetworkCapture' WKScriptMessageHandler.
    nonisolated static func createFetchInterceptorScript() -> String {
        """
        (function() {
            if (window.__GeminiDesktopDebugIntercepted) return;
            window.__GeminiDesktopDebugIntercepted = true;
            var originalFetch = window.fetch;
            window.fetch = function() {
                var url = arguments[0];
                var options = arguments[1];
                if (url && url.toString().includes('/batchexecute') && options && options.body) {
                    try {
                        window.webkit.messageHandlers.\(debugNetworkCaptureHandler).postMessage({
                            url: url.toString(),
                            payload: options.body.toString().slice(0, 8000)
                        });
                    } catch(e) {}
                }
                return originalFetch.apply(this, arguments);
            };
        })();
        """
    }
```

- [ ] **Step 3: Build to verify**

Press Cmd+B. Expected: Build Succeeded.

- [ ] **Step 4: Commit**

```bash
git add WebKit/UserScripts.swift
git commit -m "feat: add DOM capture, WIZ capture, and fetch interceptor scripts to UserScripts"
```

---

## Task 6: WebViewModel — DebugNetworkHandler and conditional interceptor injection

**Files:**
- Modify: `WebKit/WebViewModel.swift`

Add a `DebugNetworkHandler` class (following the pattern of `ConsoleLogHandler` at line 13) that buffers batchexecute payloads. Conditionally inject the fetch interceptor script and register the handler when debug mode is on at launch.

The fetch interceptor must be in the `WKUserContentController` before the webview loads. `WebViewModel.init()` calls `loadHome()` last, so we add the interceptor between `filePickerHandler` registration and `setupObservers()`.

- [ ] **Step 1: Add DebugNetworkHandler class**

Add this class after the `FilePickerHandler` class (around line 76), before `WebViewNavigationDelegate`:

```swift
/// Buffers batchexecute payloads captured by the fetch interceptor script.
/// Added to WKUserContentController only when debug mode is on at launch.
@MainActor
final class DebugNetworkHandler: NSObject, WKScriptMessageHandler {
    private let maxBufferSize = 20
    private(set) var payloadBuffer: [[String: String]] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        let entry: [String: String] = [
            "url": body["url"] as? String ?? "",
            "payload": body["payload"] as? String ?? ""
        ]
        payloadBuffer.append(entry)
        if payloadBuffer.count > maxBufferSize {
            payloadBuffer.removeFirst()
        }
    }
}
```

- [ ] **Step 2: Add debugNetworkHandler property to WebViewModel**

In `WebViewModel`, add after the `filePickerHandler` private property (around line 124):

```swift
private let debugNetworkHandler: DebugNetworkHandler?
```

Add a public accessor for the buffer (used by AppCoordinator in Task 7):

```swift
var networkPayloadBuffer: [[String: String]] {
    debugNetworkHandler?.payloadBuffer ?? []
}
```

- [ ] **Step 3: Update WebViewModel.init() to conditionally inject interceptor**

In `WebViewModel.init()`, after the existing `filePickerHandler` registration block (around line 139), add:

```swift
// Register fetch interceptor for debug network capture (only when debug mode on at launch)
let debugModeEnabled = UserDefaults.standard.bool(
    forKey: UserDefaultsKeys.debugModeEnabled.rawValue
)
if debugModeEnabled {
    let handler = DebugNetworkHandler()
    self.debugNetworkHandler = handler
    webView.configuration.userContentController.add(
        handler,
        name: UserScripts.debugNetworkCaptureHandler
    )
    let interceptorScript = WKUserScript(
        source: UserScripts.createFetchInterceptorScript(),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )
    webView.configuration.userContentController.addUserScript(interceptorScript)
} else {
    self.debugNetworkHandler = nil
}
```

Note: `self.debugNetworkHandler` must be set before `setupObservers()` and `loadHome()`. Make sure the `debugNetworkHandler` property is initialized in this block (or set to `nil`) before either of those calls.

- [ ] **Step 4: Build to verify**

Press Cmd+B. Expected: Build Succeeded. If there are "stored property not initialized" errors, ensure `debugNetworkHandler` is assigned in the `if/else` before `setupObservers()`.

- [ ] **Step 5: Commit**

```bash
git add WebKit/WebViewModel.swift
git commit -m "feat: add DebugNetworkHandler and conditional fetch interceptor to WebViewModel"
```

---

## Task 7: AppCoordinator — debug capture methods and file I/O

**Files:**
- Modify: `Coordinators/AppCoordinator.swift`

Add `debugCaptureBannerMessage` state, helper to build selector JSON, JS evaluation helper, capture methods, and file I/O. Follow the existing `performFileIO` pattern: serialize on the main actor, offload the write to `Task.detached`.

- [ ] **Step 1: Add debugCaptureBannerMessage property**

In `AppCoordinator`, add after `captureProgress` (around line 32):

```swift
private(set) var debugCaptureBannerMessage: String? = nil
```

- [ ] **Step 2: Add dismissDebugCaptureBanner()**

After the existing `dismissCaptureProgress()` method:

```swift
func dismissDebugCaptureBanner() {
    debugCaptureBannerMessage = nil
}
```

- [ ] **Step 3: Add the debug capture section**

Add a new `// MARK: - Debug Capture` section after the existing file I/O helpers:

```swift
// MARK: - Debug Capture

/// Builds a JSON string of { fieldName: selector } for all GeminiSelectors fields.
private func selectorDictJSON() -> String {
    let s = GeminiSelectors.shared
    let dict: [String: String] = [
        "conversationContainer": s.conversationContainer,
        "responseContainer": s.responseContainer,
        "goodResponseButton": s.goodResponseButton,
        "badResponseButton": s.badResponseButton,
        "richTextareaSelector": s.richTextareaSelector,
        "sendButtonSelector": s.sendButtonSelector,
        "lastResponseSelector": s.lastResponseSelector,
        "conversationTitleSelector": s.conversationTitleSelector,
        "modelSelector": s.modelSelector,
        "modelSelectorFallback": s.modelSelectorFallback,
        "userQuerySelector": s.userQuerySelector,
        "attachmentSelector": s.attachmentSelector,
        "streamingIndicatorSelector": s.streamingIndicatorSelector
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let json = String(data: data, encoding: .utf8) else { return "{}" }
    return json
}

private func evaluateJSForCapture(_ script: String) async -> Any? {
    await withCheckedContinuation { continuation in
        webViewModel.wkWebView.evaluateJavaScript(script) { result, _ in
            continuation.resume(returning: result)
        }
    }
}

func captureDebugAll()     async { await performDebugCapture(dom: true,  wiz: true,  network: true)  }
func captureDebugDOMOnly() async { await performDebugCapture(dom: true,  wiz: false, network: false) }
func captureDebugWIZOnly() async { await performDebugCapture(dom: false, wiz: true,  network: false) }
func captureDebugNetworkOnly() async { await performDebugCapture(dom: false, wiz: false, network: true) }

private func performDebugCapture(dom: Bool, wiz: Bool, network: Bool) async {
    var output: [String: Any] = [
        "capturedAt": ISO8601DateFormatter().string(from: Date()),
        "appVersion": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown",
        "url": webViewModel.wkWebView.url?.absoluteString ?? ""
    ]

    if dom, let result = await evaluateJSForCapture(
        UserScripts.createDOMCaptureScript(selectorJSON: selectorDictJSON())
    ) as? String,
       let parsed = try? JSONSerialization.jsonObject(with: Data(result.utf8)) {
        output["dom"] = parsed
    }

    if wiz, let result = await evaluateJSForCapture(
        UserScripts.createWIZCaptureScript()
    ) as? String,
       let parsed = try? JSONSerialization.jsonObject(with: Data(result.utf8)) {
        output["wizState"] = parsed
    }

    if network {
        output["network"] = webViewModel.networkPayloadBuffer
    }

    guard let data = try? JSONSerialization.data(withJSONObject: output, options: .prettyPrinted) else {
        debugCaptureBannerMessage = "Capture failed: could not serialize JSON"
        try? await Task.sleep(for: .seconds(4))
        debugCaptureBannerMessage = nil
        return
    }

    do {
        let filename = try await writeDebugCaptureFile(data)
        debugCaptureBannerMessage = filename
        try? await Task.sleep(for: .seconds(3))
        debugCaptureBannerMessage = nil
    } catch {
        debugCaptureBannerMessage = "Capture failed: \(error.localizedDescription)"
        try? await Task.sleep(for: .seconds(4))
        debugCaptureBannerMessage = nil
    }
}

nonisolated private func writeDebugCaptureFile(_ data: Data) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let capturesDir = appSupport
            .appendingPathComponent("GeminiDesktop/debug-captures")
        try FileManager.default.createDirectory(
            at: capturesDir, withIntermediateDirectories: true
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "debug-\(formatter.string(from: Date())).json"
        let url = capturesDir.appendingPathComponent(filename)
        try data.write(to: url)
        return filename
    }.value
}
```

- [ ] **Step 4: Build to verify**

Press Cmd+B. Expected: Build Succeeded.

- [ ] **Step 5: Commit**

```bash
git add Coordinators/AppCoordinator.swift
git commit -m "feat: add debug capture methods and file I/O to AppCoordinator"
```

---

## Task 8: Feature B Settings UI — Debug mode toggle

**Files:**
- Modify: `Views/SettingsView.swift`

Add an "Advanced" section at the bottom of Settings with the debug mode toggle and informational text.

- [ ] **Step 1: Add AppStorage property**

In `SettingsView`, add with the other `@AppStorage` properties (around line 14):

```swift
@AppStorage(UserDefaultsKeys.debugModeEnabled.rawValue) private var debugModeEnabled: Bool = false
```

- [ ] **Step 2: Add Advanced section**

At the end of the `Form` body, after the closing brace of `Section("Prompts & Artifacts")` and before the closing `}` of `Form`:

```swift
Section("Advanced") {
    VStack(alignment: .leading, spacing: 6) {
        Toggle("Enable Debug Mode", isOn: $debugModeEnabled)
        Text("Only needed by developers or when filing a selector bug report. Restart the app after enabling for network capture to work.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 3: Build and manually verify**

Press Cmd+B. Run the app, open Settings. Scroll to the bottom — an "Advanced" section should appear with the debug mode toggle and caption text.

- [ ] **Step 4: Commit**

```bash
git add Views/SettingsView.swift
git commit -m "feat: add debug mode toggle to Settings > Advanced section"
```

---

## Task 9: Conditional CommandMenu("Debug") in GeminiDesktopApp

**Files:**
- Modify: `App/GeminiDesktopApp.swift`

Add a `CommandMenu("Debug")` that appears in the macOS menu bar only when debug mode is on. Use SwiftUI `CommandMenu` inside the existing `.commands { }` block.

- [ ] **Step 1: Add AppStorage property to GeminiDesktopApp**

In `GeminiDesktopApp`, add after the existing `@AppStorage` properties (around line 26):

```swift
@AppStorage(UserDefaultsKeys.debugModeEnabled.rawValue) private var debugModeEnabled: Bool = false
```

- [ ] **Step 2: Add CommandMenu at the end of the .commands block**

In the `.commands { }` block (after the closing brace of `CommandGroup(after: .toolbar)`, before the closing `}` of `.commands`), add:

```swift
if debugModeEnabled {
    CommandMenu("Debug") {
        Button("Capture All") {
            Task { await coordinator.captureDebugAll() }
        }

        Divider()

        Button("Capture DOM") {
            Task { await coordinator.captureDebugDOMOnly() }
        }
        Button("Capture WIZ State") {
            Task { await coordinator.captureDebugWIZOnly() }
        }
        Button("Capture Network") {
            Task { await coordinator.captureDebugNetworkOnly() }
        }
    }
}
```

- [ ] **Step 3: Build and manually verify**

Press Cmd+B. Enable debug mode in Settings, relaunch the app. A "Debug" menu should appear in the macOS menu bar between "Window" and "Help". Disabling debug mode in Settings and relaunching should remove it.

- [ ] **Step 4: Commit**

```bash
git add App/GeminiDesktopApp.swift
git commit -m "feat: add conditional Debug menu to menu bar when debug mode is enabled"
```

---

## Task 10: Debug capture confirmation banner in MainWindowView

**Files:**
- Modify: `Views/MainWindowView.swift`

Add the debug capture banner to the existing `.overlay(alignment: .top)` `VStack` at line 65. The VStack already contains the injection banner and capture progress banner — add the debug banner as a third item following the same visual pattern.

- [ ] **Step 1: Add debug banner inside the overlay VStack**

In `Views/MainWindowView.swift`, inside the `VStack(spacing: 8)` at line 66, after the closing `}` of the capture progress banner block (after line 88), add:

```swift
// Debug capture confirmation banner
if let filename = coordinator.debugCaptureBannerMessage {
    HStack(spacing: 8) {
        Image(systemName: "ant.circle")
            .foregroundStyle(.secondary)
        Text("Debug capture saved: \(filename)")
            .font(.callout)
            .lineLimit(1)
        Spacer()
        Button("Reveal") {
            revealDebugCaptures()
        }
        .font(.callout)
        .buttonStyle(.borderless)
        Button {
            coordinator.dismissDebugCaptureBanner()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
    .padding(10)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .transition(.move(edge: .top).combined(with: .opacity))
}
```

Also add a third `.animation` modifier after the existing two, outside the `.overlay`:

```swift
.animation(.easeInOut(duration: 0.2), value: coordinator.debugCaptureBannerMessage)
```

- [ ] **Step 2: Add revealDebugCaptures() helper**

Add this private method to `MainWindowView`:

```swift
private func revealDebugCaptures() {
    guard let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first else { return }
    let dir = appSupport.appendingPathComponent("GeminiDesktop/debug-captures")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    NSWorkspace.shared.open(dir)
}
```

- [ ] **Step 3: Build and verify end-to-end**

Press Cmd+B. Run the app with debug mode on. Open a Gemini conversation and send a prompt (to populate the network buffer). Use **Debug → Capture All** from the menu bar. Verify:
1. A banner appears at the top of the window with the filename
2. "Reveal" opens `~/Library/Application Support/GeminiDesktop/debug-captures/` in Finder
3. The JSON file contains `capturedAt`, `url`, `dom`, `wizState`, and `network` keys
4. `dom.selectorProbe` shows hit/miss for each GeminiSelectors field
5. `dom.dataTestIds` lists visible data-test-id elements
6. Banner auto-dismisses after 3 seconds

- [ ] **Step 4: Commit**

```bash
git add Views/MainWindowView.swift
git commit -m "feat: add debug capture confirmation banner to main window overlay"
```
