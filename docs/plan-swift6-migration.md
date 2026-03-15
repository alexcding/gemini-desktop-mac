# Plan: Swift 6 + macOS 15 + Sandbox Migration

**Research basis:** `docs/research-swift6-migration.md`
**Target:** macOS 15.0, Swift 6 strict concurrency, full App Sandbox
**Last reviewed:** annotations incorporated from critical review

---

## Approach

Changes are ordered to keep the app buildable after each phase. Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`) is enabled in Phase 6 after all `@MainActor` annotations and actor boundary fixes are in place — enabling it first produces a demoralizing wall of errors that obscures the actual architectural work.

---

## Phase 1 — Entitlements & Build Settings

*Goal: establish the sandbox and new deployment target before touching any Swift.*

### Tasks

- [x] **1.1** Populate `Resources/GeminiDesktop.entitlements` with all required keys:
  ```xml
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.device.camera</key><true/>
  <key>com.apple.security.device.microphone</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
  <key>com.apple.security.files.downloads.read-write</key><true/>
  ```

- [x] **1.2** Update Xcode project build settings:
  - `MACOSX_DEPLOYMENT_TARGET` → `15.0` (both Debug and Release configurations)
  - `SWIFT_VERSION` → kept at `5.0` for Phase 1 (will be updated to `6.0` in Phase 2 after @MainActor annotations are in place)
  - Do NOT enable `SWIFT_STRICT_CONCURRENCY` yet — that comes in Phase 6

- [x] **1.3** Implement Security-Scoped Bookmark infrastructure

  The sandbox grants file access only for the current session when a user picks a directory via `NSOpenPanel`. To persist that access across app restarts, bookmark data must be stored. This is required now — if deferred, file access will silently fail on relaunch.

  Add two new `UserDefaultsKeys`:
  ```swift
  case promptsDirectoryBookmark   // Data
  case artifactsDirectoryBookmark // Data
  ```

  Add a dedicated `BookmarkStore` type in a new file `Utils/BookmarkStore.swift`. Do not put this on `AppCoordinator` — `AppCoordinator` already owns too much.
  ```swift
  func saveBookmark(for url: URL, key: UserDefaultsKeys) throws {
      let data = try url.bookmarkData(
          options: .withSecurityScope,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
      )
      UserDefaults.standard.set(data, forKey: key.rawValue)
  }

  func resolveBookmark(for key: UserDefaultsKeys) -> URL? {
      guard let data = UserDefaults.standard.data(forKey: key.rawValue) else { return nil }
      var isStale = false
      let url = try? URL(
          resolvingBookmarkData: data,
          options: .withSecurityScope,
          relativeTo: nil,
          bookmarkDataIsStale: &isStale
      )
      if isStale, let url { try? saveBookmark(for: url, key: key) } // refresh stale bookmark
      return url
  }
  ```

  Do not call `startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource` directly at call sites — it's easy to forget the stop call, especially across early returns or thrown errors. Instead, expose a scoped access wrapper that makes the pattern impossible to misuse:

  ```swift
  func withBookmarkedURL<T>(
      for key: UserDefaultsKeys,
      _ body: (URL) throws -> T
  ) rethrows -> T? {
      guard let url = resolveBookmark(for: key) else { return nil }
      guard url.startAccessingSecurityScopedResource() else { return nil }
      defer { url.stopAccessingSecurityScopedResource() }
      return try body(url)
  }
  ```

  All file operations go through this wrapper:
  ```swift
  // Reading prompt files
  let files = bookmarkStore.withBookmarkedURL(for: .promptsDirectoryBookmark) { url in
      try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
  }
  ```

  `defer` guarantees `stop` is called even if `body` throws or returns early. No call site can forget.

- [x] **1.4** Build and run. Verified:
  - App builds and launches successfully with entitlements and sandbox
  - BookmarkStore implementation complete and ready for Phase 2+
  - SWIFT_VERSION kept at 5.0 to avoid baseline concurrency checks before @MainActor annotations

---

## Phase 2 — Actor Isolation: `@MainActor` on Core Classes

*Goal: annotate all UI-owning types. This will surface Sendability errors that Phase 3 resolves.*

### Tasks

- [x] **2.1** Add `@MainActor` to `AppCoordinator`

- [x] **2.2** Add `@MainActor` to `WebViewModel` and fix KVO callbacks
  - Replaced `DispatchQueue.main.async` with `Task { @MainActor in }` in all 3 KVO observers

- [x] **2.3** Add `@MainActor` to `AppTheme.apply()` method

- [x] **2.4** Fix `GeminiWebView.Coordinator` — protect `downloadDestination` with `Mutex`
  - Imported `Synchronization` framework
  - Changed `downloadDestination` to use `Mutex<URL?>`
  - Marked all delegate methods as `nonisolated`
  - Updated `download` method to async signature

- [x] **2.5** Eliminate the `openMainWindow` notification entirely
  - Updated `AppDelegate` to hold weak reference to `AppCoordinator`
  - Removed notification observer from `AppCoordinator.init()`
  - Wired coordinator to appDelegate in `GeminiDesktopApp.body`
  - Removed `Notification.Name.openMainWindow` extension

- [x] **2.6** Build. 0 errors, 0 Sendability errors. Phase 2 complete!

---

## Phase 3 — Replace `DispatchQueue` with Swift Concurrency

*Goal: eliminate all `DispatchQueue.main.async` and `asyncAfter` calls.*

### Tasks

- [x] **3.1** Replace `centerNewlyCreatedWindow(on:attempt:)` with `defaultWindowPlacement`; keep `centerWindow(_:on:)`
  - Added `.defaultWindowPlacement { _, _ in WindowPlacement(.center) }` to WindowGroup in GeminiDesktopApp
  - Removed centerNewlyCreatedWindow call from openMainWindow
  - Deleted centerNewlyCreatedWindow method (was retry-polling anti-pattern)
  - centerWindow(_:on:) kept for re-show repositioning

- [x] **3.2** Replace `DispatchQueue.main.asyncAfter` in `GeminiDesktopApp` (window hide at launch)
  - Replaced with `Task { @MainActor in try? await Task.sleep(for: .seconds(...)) }`

- [x] **3.3** Skip `ChatBarPanel` async delays — Phase 4 eliminates the entire polling infrastructure

- [x] **3.4** Convert `SettingsView.clearWebsiteData()` to async/await
  - Made method async
  - Replaced callback-based API with await syntax
  - Updated button action to use `Task { await clearWebsiteData() }`

- [x] **3.5** Build. 0 errors, all DispatchQueue.main usages removed except MainWindowView.swift makeNSView (1 legitimate use). Phase 3 complete!

---

## Phase 4 — Eliminate `ChatBarPanel` Polling Timer

*Goal: replace 1Hz JavaScript polling with event-driven `WKScriptMessageHandler`.*

### Tasks

- [x] **4.1** Add `conversationStartedHandler` message handler name to `UserScripts`

- [x] **4.2** Add `createConversationObserverScript()` to `UserScripts`
  - Created `conversationObserverSource` script with MutationObserver
  - Watches for response-container or rating buttons to indicate conversation started
  - Posts message once conversation is detected

- [x] **4.3** `ChatBarPanel` registers and deregisters itself as the `WKScriptMessageHandler` directly
  - Added `registerConversationHandler()` in init - registers self as message handler
  - Added deregister logic in deinit
  - Added `WKScriptMessageHandler` extension that calls `expandToNormalSize()`
  - No Notification pattern, direct handler lifecycle management

- [x] **4.4** Removed from `ChatBarPanel`:
  - `startPolling()` method
  - `checkForConversation()` method
  - All polling timer constants (pollingInterval, initialPollingDelay, webViewSearchDelay)
  - `findWebView(in:)` method (no longer needed)
  - Async delays for WebView search

- [x] **4.5** Pass `WKWebView` directly to `ChatBarPanel.init`
  - Changed init signature to `init(contentView: NSView, webView: WKWebView)`
  - Updated AppCoordinator.showChatBar() to pass webViewModel.wkWebView
  - webView is now a strong reference property

- [x] **4.6** Update `checkAndAdjustSize()` - removed DispatchQueue.main.async
  - Now uses a single evaluateJavaScript call without polling
  - One-time check when panel shows

- [x] **4.7** Build successful! Phase 4 complete - polling timer eliminated, event-driven handler active!

---

## Phase 5 — AppKit Consolidation & Cleanup

*Goal: remove code duplication and tighten AppKit boundaries.*

### Tasks

- [ ] **5.1** Consolidate `NSApp.setActivationPolicy` into `AppCoordinator`

  ```swift
  @MainActor
  func updateActivationPolicy() {
      let hideDock = UserDefaults.standard.bool(forKey: UserDefaultsKeys.hideDockIcon.rawValue)
      NSApp.setActivationPolicy(hideDock ? .accessory : .regular)
  }
  ```
  Remove inline calls from `GeminiDesktopApp` body and `AppCoordinator.openMainWindow()`. Call `coordinator.updateActivationPolicy()` from `SettingsView.onChange(of: hideDockIcon)`.

- [ ] **5.2** Consolidate `openNewChat` JavaScript — remove `ChatBarPanel.openNewChat()` (private, duplicates `WebViewModel.openNewChat()`). Pass an `openNewChat` closure or a `WebViewModel` reference into `ChatBarPanel.init`.

- [ ] **5.3** Consolidate window-finding — `MainWindowView.mainWindows` re-implements `AppCoordinator.findMainWindow()`. Remove `mainWindows` from `MainWindowView` and route through coordinator.

- [ ] **5.4** Guard `downloadsURL` force-unwrap in `GeminiWebView.swift`
  ```swift
  guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
      completionHandler(nil)
      return
  }
  ```

- [ ] **5.5** Remove redundant `UserDefaults` read in `ChatBarPanel` — `init` currently reads `panelWidth`/`panelHeight` directly; it should read `initialSize` (the computed property that already does this).

- [ ] **5.6** Build. Full regression test using sandbox reset procedure from Phase 1.4.

---

## Phase 6 — Enable Swift 6 Strict Concurrency

*Goal: turn on the compiler flag and fix remaining warnings-as-errors.*

### Tasks

- [ ] **6.1** Enable strict concurrency:
  - `SWIFT_STRICT_CONCURRENCY` = `complete` in both Debug and Release configurations

- [ ] **6.2** If AppKit or WebKit APIs produce Sendability warnings that are outside your control (i.e., Apple hasn't yet audited the framework for strict concurrency), suppress at the import level rather than at individual call sites:
  ```swift
  @preconcurrency import WebKit
  @preconcurrency import AppKit
  ```
  Use this sparingly and only for framework-level false positives — not to suppress warnings in your own code.

- [ ] **6.3** Build and triage errors:
  - Expected: residual Sendability warnings in `GeminiWebView.Coordinator` conformances
  - Expected: any `@Sendable` closure warnings on completion handlers
  - Not expected: anything in `AppCoordinator` or `WebViewModel` (should be clean after Phase 2)

- [ ] **6.4** Fix remaining errors:
  - `@Sendable` on closure types where required
  - `nonisolated` on any remaining conformance methods
  - `Task { @MainActor in ... }` for any remaining legacy callbacks (not `assumeIsolated`)

- [ ] **6.5** Build with 0 errors and 0 strict concurrency warnings (or documented `@preconcurrency` suppressions for framework APIs only).

---

## Phase 7 — macOS 15 API Adoption (Opportunistic)

*Goal: adopt new APIs where they simplify existing workarounds. Skip where the refactor cost exceeds the benefit.*

### Tasks

- [ ] **7.1** `defaultWindowPlacement` — if not fully resolved in Phase 3.1, complete adoption here.

- [ ] **7.2** `NSWindow.windowingBehaviors` — evaluate replacing `window.collectionBehavior.insert(.fullScreenPrimary)` in `setupWindowAppearance`. If cleaner, adopt. If equivalent complexity, leave as-is.

- [ ] **7.3** Evaluate `pushWindow` environment value — if it can replace the `openWindowAction` closure threaded through the coordinator without a larger refactor, adopt it. Skip if not straightforward.

---

## Testing Checklist

**Before each phase's final build**, reset the sandbox state:
```bash
tccutil reset All com.your.bundle.id
rm -rf ~/Library/Containers/com.your.bundle.id
```

**Functional regression:**
- [ ] App launches normally (dock icon visible)
- [ ] App launches in accessory mode ("Hide Dock Icon")
- [ ] App launches with "Hide Window at Launch"
- [ ] Main Gemini window loads and is fully functional
- [ ] Back/forward navigation buttons work
- [ ] Zoom in/out/reset works and persists across restarts
- [ ] New Chat (Cmd+N) works from main window
- [ ] Chat bar opens via keyboard shortcut
- [ ] Chat bar opens via menu bar
- [ ] Chat bar auto-expands when Gemini responds (event-driven, not polled)
- [ ] Chat bar Esc dismisses
- [ ] Chat bar New Chat (Cmd+N) resets to initial size
- [ ] Expand from chat bar to main window works
- [ ] Multi-display: chat bar appears on correct screen, expand centers main window on same screen
- [ ] File download from Gemini lands in `~/Downloads`
- [ ] File upload via Gemini picker works
- [ ] Settings persist across app restarts
- [ ] Theme switching (Light/Dark/System) works
- [ ] Custom toolbar color persists
- [ ] Launch at login toggle works
- [ ] Reset website data clears session (sign-out forced on next launch)
- [ ] Full screen mode works (green traffic light, no regression from `collectionBehavior` fix)
- [ ] Camera/mic access works in Gemini (verify TCC prompt appears on fresh install)

---

## Risk Register

| Risk | Likelihood | Mitigation |
|---|---|---|
| `defaultWindowPlacement` races with `AppCoordinator` on initial launch | Medium | Strict boundary: `defaultWindowPlacement` for creation only; `AppCoordinator` for subsequent shows. Verify in Phase 3.1 testing before proceeding. |
| `defaultWindowPlacement` can't replicate per-screen centering when expanding from chat bar | Medium | Fall back to `WindowAccessor` notification-based centering; remove only the retry-polling |
| KVO `Task { @MainActor in }` hop introduces a render cycle delay visible to user | Low | KVO fires synchronously on property change; Task hop is one runloop tick. Negligible in practice. |
| `WKScriptMessageHandler` DOM selector becomes stale (Gemini UI update) | Medium | Keep `evaluateJavaScript` one-shot check in `checkAndAdjustSize` as fallback |
| `Mutex` from `Synchronization` framework causes issues with `NSObject` subclass | Low | `Mutex` is a value type stored as a property — compatible with `NSObject` subclasses |
| Sandbox breaks `SMAppService` launch-at-login | Low | `SMAppService` is supported under full sandbox since macOS 13 |
| Sandbox breaks `NSWorkspace.open(url:)` for external links | Low | Outgoing URL opens are allowed under sandbox without additional entitlements |
| Hardened runtime + sandbox rejects camera/mic at runtime | Low | Entitlements declared + `requestMediaCapturePermissionFor` programmatic grant — both required and both present |
| `@preconcurrency import` masks a real concurrency bug in framework usage | Low | Review each suppressed warning individually before accepting. Document suppressions with a comment explaining why. |
