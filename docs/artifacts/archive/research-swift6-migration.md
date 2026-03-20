# Research: Swift 6 + macOS 15 + Sandbox Migration

**Scope:** Full audit of concurrency, AppKit surface, entitlements, and legacy patterns
**Target:** macOS 15.0, Swift 6 strict concurrency, full App Sandbox

---

## 1. Current Project Configuration

| Setting | Current | Target |
|---|---|---|
| `MACOSX_DEPLOYMENT_TARGET` | `14.0` | `15.0` |
| `SWIFT_VERSION` | `5.0` | `6.0` |
| `ENABLE_HARDENED_RUNTIME` | `YES` | `YES` (keep) |
| `CODE_SIGN_ENTITLEMENTS` | `Resources/GeminiDesktop.entitlements` | same file, populated |
| App Sandbox | **not declared** | `com.apple.security.app-sandbox = true` |

The entitlements file is currently an empty `<dict/>`. No sandbox is declared, which means the app runs without restriction. This must be corrected before any file access or camera/mic features are added.

---

## 2. Concurrency Audit

### 2.1 `@MainActor` — Not Applied Anywhere

Zero uses of `@MainActor`, `actor`, `Sendable`, or `nonisolated` exist in the codebase. Every class that touches UI or AppKit state is unprotected under Swift 6 strict concurrency checking. Swift 6 will flag these as errors.

**Classes that must become `@MainActor`:**

| Class | Reason |
|---|---|
| `AppCoordinator` | Manages `NSApp`, `NSWindow`, `WKWebView` |
| `WebViewModel` | Owns `WKWebView`, drives SwiftUI state |
| `ChatBarPanel` (already `NSPanel`) | AppKit class — inherently main-thread |
| `AppTheme` (the `apply()` method) | Calls `NSApp.appearance =` |

**Classes with mixed threading that need analysis:**
- `GeminiWebView.Coordinator` — implements `WKNavigationDelegate`, `WKUIDelegate`, `WKDownloadDelegate`. WebKit delegates are NOT guaranteed to fire on the main thread (download delegate callbacks specifically can come off-main). Cannot be `@MainActor` without careful `nonisolated` handling on delegate methods.

### 2.2 `DispatchQueue.main.async` — 11 call sites

All of these become either unnecessary (once the owning class is `@MainActor`) or should be replaced with `await MainActor.run { }` at a call boundary.

| File | Line | Current | After `@MainActor` |
|---|---|---|---|
| `AppCoordinator.swift` | 171 | `DispatchQueue.main.asyncAfter(deadline:)` | `Task { try await Task.sleep(for:); ... }` |
| `WebViewModel.swift` | 151, 158, 165 | inside KVO callbacks | removed — KVO callbacks stay on main with `[weak self]` + `.main` queue already specified |
| `GeminiDesktopApp.swift` | 122 | `asyncAfter` for window hide delay | `Task { try await Task.sleep(for:); ... }` |
| `ChatBarPanel.swift` | 87 | `asyncAfter` for webview search delay | `Task { try await Task.sleep(for:); ... }` |
| `ChatBarPanel.swift` | 145 | `asyncAfter` for polling start delay | replaced by `WKScriptMessageHandler` (polling eliminated) |
| `ChatBarPanel.swift` | 158 | inside `checkForConversation` | same — polling eliminated |
| `ChatBarPanel.swift` | 220 | inside `checkAndAdjustSize` | replaced by `WKScriptMessageHandler` |
| `SettingsView.swift` | 112 | inside `WKWebsiteDataStore` callback | `await MainActor.run { isClearing = false }` |
| `MainWindowView.swift` | 94 | inside `WindowAccessor.makeNSView` | remains — `DispatchQueue.main.async` inside `makeNSView` is the correct pattern for accessing `nsView.window` after layout |

**`MainWindowView.swift:94` is the one legitimate remaining use** — `makeNSView` is called before the view is added to a window, so the async dispatch is necessary to defer until after the window hierarchy is established. This pattern is correct and should stay.

### 2.3 `NotificationCenter` — Observer Token Not Retained

**`AppCoordinator.swift:28`** — critical bug:

```swift
// Current — token is discarded
NotificationCenter.default.addObserver(forName: .openMainWindow, object: nil, queue: .main) { [weak self] _ in
    self?.openMainWindow()
}
```

The block-based `addObserver` returns an `NSObjectProtocol` token that must be retained and passed to `removeObserver` on deinit. Discarding it means the observer cannot be explicitly removed. In practice the observer keeps firing (NotificationCenter retains the block internally), but it cannot be cleaned up, which is a memory leak.

**Fix:** Store the token, remove in `deinit`.

```swift
private var openMainWindowObserver: NSObjectProtocol?

init() {
    openMainWindowObserver = NotificationCenter.default.addObserver(...)
}

deinit {
    if let token = openMainWindowObserver {
        NotificationCenter.default.removeObserver(token)
    }
}
```

**Better fix for Swift 6:** The only reason this `Notification` exists is to let `AppDelegate.applicationShouldHandleReopen` call into `AppCoordinator` without a direct reference. With Swift 6 concurrency, `AppDelegate` can hold a weak reference to `AppCoordinator` directly, eliminating the notification entirely.

**`GeminiWebView.swift:167,173`** — `windowObserver` is properly stored and removed. No issue here.

### 2.4 KVO Observers in `WebViewModel`

Three `NSKeyValueObservation` properties observe `WKWebView` properties:

```swift
private var backObserver: NSKeyValueObservation?    // observes canGoBack
private var forwardObserver: NSKeyValueObservation?  // observes canGoForward
private var urlObserver: NSKeyValueObservation?      // observes url
```

The KVO callbacks dispatch back to `.main` explicitly:

```swift
backObserver = wkWebView.observe(\.canGoBack, options: [.new, .initial]) { [weak self] webView, _ in
    DispatchQueue.main.async { ... }
}
```

Under Swift 6 with `@MainActor` on `WebViewModel`, the `DispatchQueue.main.async` becomes redundant (already on main) and the `[weak self]` closure will generate a Sendability warning because the closure escapes across actor boundaries.

**Fix options:**
- **Option A (minimal change):** Keep KVO, add `@MainActor` annotation to `WebViewModel`, mark the KVO callback closures as `@Sendable` and use `MainActor.assumeIsolated { }` inside them. Clean and low-risk.
- **Option B (modern Swift):** Replace with Combine publishers: `wkWebView.publisher(for: \.canGoBack).receive(on: RunLoop.main).assign(to: &$canGoBack)`. Cleaner but introduces Combine dependency and `@Published` which conflicts with `@Observable`.
- **Option C (Swift 6 native):** `AsyncStream` wrapping KVO via `withObservationTracking`. Most future-proof but most complex.

**Recommendation: Option A** — minimal diff, correct under Swift 6, no new dependencies.

### 2.5 `ChatBarPanel` Polling Timer — Replace with `WKScriptMessageHandler`

**Current mechanism** (`ChatBarPanel.swift:145`):
- `Timer.scheduledTimer` fires every 1 second
- Calls `webView.evaluateJavaScript(checkConversationScript)` — async JavaScript evaluation
- On result, dispatches back to main thread
- Delayed start: 3 seconds after panel shows

**Problems:**
- 1 Hz polling of JavaScript is expensive and racey
- `Timer` must be invalidated carefully (done in `deinit` and `resetToInitialSize`, but fragile)
- The 3-second startup delay is a heuristic to wait for the page to render
- Under Swift 6, the `Timer` callback closure has Sendability issues

**Replacement: `WKScriptMessageHandler` + `MutationObserver`**

Instead of polling from Swift, inject a JavaScript `MutationObserver` that watches for the conversation container appearing and posts a message back to Swift when it does:

```javascript
// injected at document end
(function() {
    const handler = 'conversationStarted';
    const targetSelector = 'infinite-scroller[data-test-id="chat-history-container"]';

    function checkAndNotify() {
        const scroller = document.querySelector(targetSelector);
        if (!scroller) return;
        const hasContent = scroller.querySelector('response-container') !== null
                        || scroller.querySelector('[aria-label="Good response"]') !== null;
        if (hasContent) {
            window.webkit.messageHandlers[handler].postMessage(true);
        }
    }

    const observer = new MutationObserver(checkAndNotify);
    observer.observe(document.body, { childList: true, subtree: true });
    checkAndNotify(); // check immediately on inject
})();
```

Swift side registers a `WKScriptMessageHandler` for `"conversationStarted"` and calls `expandToNormalSize()` on receipt. No timer, no polling, no artificial delays. Message fires exactly once when the conversation container appears.

**This is the most impactful single change in the migration.**

---

## 3. AppKit Surface Audit

### 3.1 Direct `NSApp.windows` Iteration — 4 locations

| File | Usage |
|---|---|
| `AppCoordinator.swift:95` | `closeMainWindow()` — iterates all windows to find main |
| `AppCoordinator.swift:155` | `findMainWindow()` — finds main window by identifier/title |
| `GeminiDesktopApp.swift:123` | `onAppear` — iterates to hide window at launch |
| `MainWindowView.swift:57` | `mainWindows` computed property |

`AppCoordinator` has its own `findMainWindow()`, and `MainWindowView` has `mainWindows`. These are parallel implementations of the same logic. Under macOS 15, `defaultWindowPlacement` and `pushWindow` environment values are available, but `NSApp.windows` iteration remains the only way to find an existing window by identifier outside of SwiftUI callbacks. This pattern should be consolidated into `AppCoordinator.findMainWindow()` and called from `MainWindowView` via the coordinator.

### 3.2 `NSApp.setActivationPolicy` — 3 locations

Called in:
- `AppCoordinator.openMainWindow()` — sets `.regular` if dock icon is visible
- `GeminiDesktopApp` body `onAppear` — sets `.accessory` if hiding
- `SettingsView` `onChange(of: hideDockIcon)` — toggles

This is AppKit-only and cannot be replaced with SwiftUI. The pattern is correct but scattered. The activation policy should be managed in one place — `AppCoordinator` is the right owner.

### 3.3 `ChatBarPanel.findWebView(in:)` — Anti-pattern

```swift
private func findWebView(in view: NSView) {
    if let wk = view as? WKWebView {
        self.webView = wk
        return
    }
    for subview in view.subviews {
        findWebView(in: subview)
    }
}
```

Recursively searches the view hierarchy for a `WKWebView`. This is fragile — it depends on the view hierarchy structure of `NSHostingView`, which is implementation detail. `ChatBarPanel` is initialized with the hosting view but not directly with the `WKWebView`. The fix is to pass `WKWebView` directly to `ChatBarPanel.init`.

### 3.4 `NSHostingView` in `AppCoordinator`

```swift
let contentView = ChatBarView(webView: webViewModel.wkWebView, ...)
let hostingView = NSHostingView(rootView: contentView)
let bar = ChatBarPanel(contentView: hostingView)
```

`NSHostingView` is the correct bridge here. The `WKWebView` can be passed directly to `ChatBarPanel` alongside the hosting view, eliminating `findWebView(in:)`.

### 3.5 `NSAlert.runModal()` — Blocking Main Thread

All JavaScript dialog handlers in `GeminiWebView.Coordinator` use synchronous `runModal()`:

```swift
func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage ...) {
    let alert = NSAlert()
    alert.runModal()  // blocks the main thread
    completionHandler()
}
```

Under Swift 6, this in a `nonisolated` delegate method calling a main-thread API will generate a warning. The correct approach is `alert.beginSheetModal(for: window) { _ in completionHandler() }`. However, the delegate method receives `completionHandler` which must be called exactly once — `beginSheetModal` handles this correctly. Requires access to the parent `NSWindow`.

---

## 4. `UserDefaults` Usage Audit

### Direct `UserDefaults.standard` calls — 13 locations across 5 files

| File | Keys accessed directly |
|---|---|
| `AppCoordinator.swift` | `hideDockIcon` |
| `WebViewModel.swift` | `pageZoom` (read + write) |
| `GeminiDesktopApp.swift` | `hideWindowAtLaunch`, `hideDockIcon` |
| `ChatBarPanel.swift` | `panelWidth`, `panelHeight` (read x2 + write x2) |
| `UserDefaultsKeys.swift` | `appTheme` (in `AppTheme.current`) |

`ChatBarPanel.swift` is particularly problematic — it reads `panelWidth`/`panelHeight` in two separate places (`initialSize` computed property and `init`), which is redundant. `ChatBarPanel` is `NSPanel` (AppKit), so `@AppStorage` is not available. Direct `UserDefaults.standard` access is unavoidable in AppKit classes.

No issues with the usage pattern itself — all accesses use `UserDefaultsKeys.rawValue` consistently. The `AppTheme.current` static on `UserDefaultsKeys.swift` reads directly as a fallback for non-SwiftUI context (used in `init()` of the app). Acceptable.

---

## 5. Entitlements & Sandbox Audit

### Current state: No sandbox declared

The app runs with full process privileges. Adding the sandbox requires declaring every capability the app uses.

### Required entitlements

| Entitlement key | Reason |
|---|---|
| `com.apple.security.app-sandbox` | Master sandbox switch |
| `com.apple.security.network.client` | Loading `gemini.google.com`, Google auth, any external URL |
| `com.apple.security.device.camera` | Auto-granted to google.com in `requestMediaCapturePermissionFor` |
| `com.apple.security.device.microphone` | Same — Gemini voice input |
| `com.apple.security.files.user-selected.read-write` | File picker (`NSOpenPanel`) in `GeminiWebView`, future prompts/artifacts directory selection |
| `com.apple.security.files.downloads.read-write` | Writing downloaded files to `~/Downloads` in `GeminiWebView.download(_:decideDestinationUsing:)` |

### Entitlements that may cause sandbox rejection at runtime

**Downloads directory access** — `FileManager.default.urls(for: .downloadsDirectory, ...)` is used in `GeminiWebView.swift` to determine the download destination. Under sandbox, this requires `com.apple.security.files.downloads.read-write`. Without it, the download silently fails (the path is returned but writing is denied by the kernel).

**`NSWorkspace.shared.activateFileViewerSelecting([destination])`** — used after download completes to reveal the file in Finder. This is an outgoing inter-process communication that is allowed under sandbox by default via `com.apple.security.automation.apple-events`. No additional entitlement needed.

**`SMAppService.mainApp.register()`** (Launch at Login) — works under sandbox with `com.apple.security.app-sandbox` declared. No additional entitlement needed in macOS 13+.

### `ENABLE_HARDENED_RUNTIME = YES` — already set

Hardened runtime is already enabled, which is a prerequisite for sandbox. No change needed.

### Security-scoped bookmarks (for future prompts/artifacts)

When the user selects a directory via `NSOpenPanel`, sandbox-derived file access is limited to that session. To persist access across app launches, the app must:
1. Call `url.startAccessingSecurityScopedResource()` after the picker
2. Create a bookmark: `url.bookmarkData(options: .withSecurityScope, ...)`
3. Store the bookmark `Data` in `UserDefaults`
4. On next launch, resolve the bookmark and call `startAccessingSecurityScopedResource()`

This is a well-defined pattern. The relevant entitlement `com.apple.security.files.user-selected.read-write` enables the initial picker selection. The bookmark persists that access.

---

## 6. Force Unwraps & Unsafe Patterns

### `FileManager.default.urls(for:in:).first!`

```swift
// GeminiWebView.swift
let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
```

`first!` force-unwrap. `urls(for:in:)` returns an empty array only if the directory does not exist, which cannot happen for `.downloadsDirectory` on macOS. Low risk in practice, but should be `guard let` for correctness.

### `WebViewContainer.init(coder:)`

```swift
required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
}
```

Standard pattern for programmatic NSView subclasses. Acceptable.

---

## 7. macOS 15 API Opportunities

### `defaultWindowPlacement` (macOS 15)

```swift
// New in macOS 15
.defaultWindowPlacement { content, context in
    .init(.center)  // or .leading, .trailing, custom frame
}
```

Replaces `centerNewlyCreatedWindow(on:attempt:)` — the fragile retry-polling mechanism that attempts to center a new window up to 5 times with 50ms delays. `defaultWindowPlacement` runs synchronously before the window appears.

### `pushWindow` environment (macOS 15)

Provides a programmatic way to navigate between SwiftUI scenes. Could replace the `openWindowAction` closure currently threaded through the coordinator.

### `NSWindow.windowingBehaviors` (macOS 15)

New API for configuring window tiling, fullscreen, and resizing behaviors declaratively. Could replace the `collectionBehavior.insert(.fullScreenPrimary)` AppKit call in `setupWindowAppearance`.

### `@Observable` and Swift 6

`@Observable` (introduced in Swift 5.9/macOS 14) works correctly with Swift 6 when the class is `@MainActor`. No migration needed for the macro itself.

---

## 8. `openNewChat` Duplication

The Shift+Cmd+O keyboard event simulation JavaScript exists in two places:

- `WebViewModel.openNewChat()` — called from `AppCoordinator`, menu bar, keyboard shortcut
- `ChatBarPanel.openNewChat()` (private) — called from `performKeyEquivalent`

These are identical scripts. `ChatBarPanel.openNewChat()` should call `webViewModel.openNewChat()` directly, or the `WKWebView` reference in `ChatBarPanel` should be replaced with a reference to `WebViewModel`.

---

## 9. Summary: Changes by Category

### Must fix (Swift 6 compiler errors)
- Add `@MainActor` to `AppCoordinator`, `WebViewModel`, `AppTheme.apply()`
- Fix `DispatchQueue.main.async` in `WebViewModel` KVO callbacks (redundant once `@MainActor`)
- Fix `NotificationCenter` observer token leak in `AppCoordinator`
- Handle `GeminiWebView.Coordinator` delegate sendability (`nonisolated` on delegate methods)

### Must fix (sandbox)
- Populate `GeminiDesktop.entitlements` with all 6 required entitlements
- Update build settings: `MACOSX_DEPLOYMENT_TARGET = 15.0`, `SWIFT_VERSION = 6.0`
- Guard `downloadsURL` force-unwrap

### High value (eliminate technical debt)
- Replace `ChatBarPanel` polling timer with `WKScriptMessageHandler` + `MutationObserver`
- Pass `WKWebView` directly to `ChatBarPanel.init`, eliminate `findWebView(in:)`
- Replace `centerNewlyCreatedWindow(on:attempt:)` retry loop with `defaultWindowPlacement`
- Replace `DispatchQueue.main.asyncAfter` in `AppCoordinator` and `GeminiDesktopApp` with `Task { try await Task.sleep(for:) }`
- Consolidate `openNewChat` JavaScript into one location
- Consolidate `NSApp.setActivationPolicy` calls into `AppCoordinator`

### Low priority / nice to have
- Replace `NSAlert.runModal()` with `beginSheetModal` in JavaScript dialog handlers
- Replace `NotificationCenter` + `AppDelegate` pattern with direct coordinator reference
- Deduplicate `UserDefaults` reads in `ChatBarPanel.initialSize` vs `init`
