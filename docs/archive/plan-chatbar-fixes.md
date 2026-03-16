# Plan: ChatBar Bug Fixes

**Research basis:** `docs/research-chatbar-issues.md`
**Bugs addressed:**
- Bug 1 (fix): Fullscreen not exited before ChatBar shows
- Bug 2 (fix + toggle): Window not draggable — native drag overlay with user opt-in
- Bug 3 (fix): Two windows / blank green window after dock click
- Bug 4 (resilience): DOM selector fragility

---

## Phase 0 — Verify Bug 3 Root Cause: External Events

*Before removing `.handlesExternalEvents(matching:)`, confirm it is safe to do so.*

### Background
Commit `2fb42c9` switched `Window` → `WindowGroup` and added `.handlesExternalEvents(matching: [mainWindowID])`. The commit message ("Changed the toolbar colors to official Google colors") suggests the `WindowGroup` switch was unintentional. However, `.handlesExternalEvents` is also used by `WindowGroup` to handle URL scheme opens (deep links). If any feature relies on deep links or `NSUserActivity` scene restoration, removing it without replacement could cause a regression.

### Tasks

- [ ] **0.1** Check `Info.plist` for `CFBundleURLTypes` entries. If none exist, the app registers no URL scheme and no external event handling is active.

- [ ] **0.2** Check `GeminiDesktopApp.swift` and `AppDelegate.swift` for `application(_:open:)`, `application(_:continue:restorationHandler:)`, or `onOpenURL` modifiers. If none exist, no deep-link handling is in use.

- [ ] **0.3** Check git log for any commit that added URL scheme handling or `NSUserActivity` support after `2fb42c9`.

- [ ] **0.4** Decision gate:
  - If no URL scheme / NSUserActivity found → **proceed with Phase 1** (remove `WindowGroup`, drop `.handlesExternalEvents`)
  - If URL scheme found → add an `onOpenURL` modifier on the `Window` scene (or handle in `AppDelegate.application(_:open:)`) before removing `handlesExternalEvents`

---

## Phase 1 — Fix Bug 3: `Window` vs `WindowGroup`

*Goal: prevent SwiftUI from creating a second main window when the first is hidden with `orderOut`.*

### Root cause recap
`WindowGroup` can create multiple instances. When the main window is hidden with AppKit's `orderOut(nil)`, SwiftUI's scene manager is not notified — it considers the scene still active. When the app is reopened (dock click → `openMainWindow()` → `NSApp.activate`), SwiftUI detects "no visible SwiftUI window" and spawns a second `WindowGroup` instance. This is the blank green window.

`Window` is a single-instance scene. SwiftUI cannot create a second `Window` — calling `openWindow(id:)` for an existing `Window` scene focuses/reveals the single underlying NSWindow rather than creating a new one. This eliminates the entire class of problem.

### Tasks

- [ ] **1.1** Change `WindowGroup` to `Window` in `GeminiDesktopApp.swift`

  ```swift
  // Before
  WindowGroup(AppCoordinator.Constants.mainWindowTitle, id: Constants.mainWindowID) {
      MainWindowView(coordinator: $coordinator)
          ...
  }
  .handlesExternalEvents(matching: [Constants.mainWindowID])
  .defaultSize(...)
  .defaultWindowPlacement(...)
  .windowToolbarStyle(...)

  // After
  Window(AppCoordinator.Constants.mainWindowTitle, id: Constants.mainWindowID) {
      MainWindowView(coordinator: $coordinator)
          ...
  }
  .defaultSize(...)
  .defaultWindowPlacement(...)
  .windowToolbarStyle(...)
  ```

  Remove `.handlesExternalEvents(matching:)` — this modifier is for `WindowGroup` to deduplicate instances from external events. `Window` is inherently single-instance and does not need it.

- [ ] **1.2** Build and verify no compiler errors. `Window` supports all modifiers currently used: `defaultSize`, `defaultWindowPlacement`, `windowToolbarStyle`, `commands`.

- [ ] **1.3** Test the two-window scenario:
  - Launch app → minimize to ChatBar → click outside ChatBar → click Dock icon
  - Verify: exactly ONE window appears with Gemini content
  - Verify: no blank green window

- [ ] **1.4** Test `openWindow(id:)` still works for the case where no window exists yet:
  - Launch app with "Hide Window at Launch" enabled
  - Click "Open Gemini Desktop" in the menu bar extra
  - Verify: window appears correctly

- [ ] **1.5** Test `applicationShouldHandleReopen` path:
  - Launch, minimize to ChatBar, click Dock icon
  - Verify: `openMainWindow()` → `findMainWindow()` finds the window → `makeKeyAndOrderFront` brings it front
  - Verify: `openWindowAction("main")` fallback path (if `findMainWindow` returns nil) also works correctly with `Window` scene — it should focus/reveal the single window rather than create a duplicate

---

## Phase 2 — Fix Bug 1: Fullscreen Exit Before ChatBar

*Goal: exit fullscreen before hiding the main window and showing the ChatBar.*

### Root cause recap
Fullscreen exit is asynchronous and animated (~0.5–1s). `orderOut(nil)` on a fullscreen window has no effect (the window stays in its fullscreen space). The ChatBar must not be shown until `NSWindow.didExitFullScreenNotification` fires. All code paths that show the ChatBar route through `AppCoordinator.showChatBar()`, making it the single place to add this guard.

### Multi-monitor consideration
`repositionChatBarToMouseScreen(bar)` in `showChatBarCore()` uses `NSEvent.mouseLocation` to determine which screen to place the ChatBar on. When called synchronously, this is fine. When called after an async fullscreen exit, the mouse may have moved to a different screen during the ~1s animation. The target screen should be captured from `NSEvent.mouseLocation` or `NSScreen.screenContaining(window.frame)` **before** `toggleFullScreen(nil)` is called, then passed through to `showChatBarCore()` so the ChatBar lands on the screen the user was on when they initiated minimize.

### Tasks

- [ ] **2.1** Refactor `minimizeToPrompt()` in `MainWindowView.swift`

  Remove the redundant `orderOut` call. `showChatBar()` in the coordinator already calls `closeMainWindow()` which performs the hide. The direct `orderOut` in the view skips the fullscreen guard we're about to add.

  ```swift
  // Before
  private func minimizeToPrompt() {
      mainWindows.first?.orderOut(nil)
      coordinator.showChatBar()
  }

  // After
  private func minimizeToPrompt() {
      coordinator.showChatBar()
  }
  ```

- [ ] **2.2** Add a fullscreen guard to `AppCoordinator.showChatBar()`

  Add a private `isExitingFullscreen` flag to prevent double-triggering if the shortcut is pressed while the exit animation is in progress. Capture the originating screen before calling `toggleFullScreen(nil)` and pass it to `showChatBarCore()`.

  ```swift
  private var isExitingFullscreen = false
  private var fullscreenExitObserver: NSObjectProtocol?
  private var fullscreenFailObserver: NSObjectProtocol?
  private var fullscreenExitTimeoutTask: Task<Void, Never>?

  func showChatBar() {
      if let window = findMainWindow(), window.styleMask.contains(.fullScreen) {
          guard !isExitingFullscreen else { return }
          isExitingFullscreen = true

          // Capture screen now — after the animation completes the mouse may be elsewhere
          let originatingScreen = NSScreen.screens.first(where: { $0.frame.contains(window.frame.origin) })
              ?? NSScreen.main

          fullscreenExitObserver = NotificationCenter.default.addObserver(
              forName: NSWindow.didExitFullScreenNotification,
              object: window,
              queue: .main
          ) { [weak self] _ in
              guard let self else { return }
              self.clearFullscreenObservers()
              self.showChatBarCore(preferredScreen: originatingScreen)
          }

          fullscreenFailObserver = NotificationCenter.default.addObserver(
              forName: NSWindow.didFailToExitFullScreenNotification,
              object: window,
              queue: .main
          ) { [weak self] _ in
              guard let self else { return }
              self.clearFullscreenObservers()
              // Exit animation failed — window is still in fullscreen. Do not show ChatBar.
          }

          // Safety timeout: if neither notification fires within 2s, reset the guard
          fullscreenExitTimeoutTask = Task { @MainActor [weak self] in
              try? await Task.sleep(for: .seconds(2))
              guard let self, self.isExitingFullscreen else { return }
              self.clearFullscreenObservers()
          }

          window.toggleFullScreen(nil)
          return
      }
      showChatBarCore(preferredScreen: nil)
  }

  private func clearFullscreenObservers() {
      if let token = fullscreenExitObserver {
          NotificationCenter.default.removeObserver(token)
          fullscreenExitObserver = nil
      }
      if let token = fullscreenFailObserver {
          NotificationCenter.default.removeObserver(token)
          fullscreenFailObserver = nil
      }
      fullscreenExitTimeoutTask?.cancel()
      fullscreenExitTimeoutTask = nil
      isExitingFullscreen = false
  }
  ```

- [ ] **2.3** Extract `showChatBarCore(preferredScreen:)` — the existing body of `showChatBar()` becomes this private method. The `preferredScreen` parameter overrides the default mouse-screen calculation when coming from fullscreen:

  ```swift
  private func showChatBarCore(preferredScreen: NSScreen?) {
      closeMainWindow()

      if let bar = chatBar {
          repositionChatBarToScreen(bar, screen: preferredScreen)
          bar.orderFront(nil)
          bar.makeKeyAndOrderFront(nil)
          bar.checkAndAdjustSize()
          return
      }

      // ... create and position new ChatBarPanel using preferredScreen ...
  }
  ```

  Update `repositionChatBarToMouseScreen(_:)` to accept an optional explicit screen:
  ```swift
  // If screen is provided (post-fullscreen path), use it directly.
  // Otherwise fall back to NSEvent.mouseLocation screen detection (normal path).
  private func repositionChatBarToScreen(_ bar: ChatBarPanel, screen: NSScreen?) {
      let targetScreen = screen ?? NSScreen.screens.first(where: {
          $0.frame.contains(NSEvent.mouseLocation)
      }) ?? NSScreen.main ?? NSScreen.screens[0]
      // ... existing positioning logic using targetScreen ...
  }
  ```

- [ ] **2.4** Clean up observers in `deinit` (belt-and-suspenders):
  ```swift
  deinit {
      clearFullscreenObservers()
  }
  ```

- [ ] **2.5** Build. 0 errors.

- [ ] **2.6** Test:
  - Enter fullscreen (green traffic light or Ctrl+Cmd+F)
  - Click "Minimize to Prompt Panel" toolbar button → verify fullscreen exits, then ChatBar appears
  - Press the keyboard shortcut for Toggle Chat Bar while in fullscreen → same result
  - Press the shortcut rapidly while fullscreen is animating → verify only one ChatBar appears (guard works)
  - Expand from ChatBar back to main window → verify main window appears normally (not in fullscreen)
  - Multi-monitor: enter fullscreen on secondary display, minimize to ChatBar → verify ChatBar appears on the secondary display (not the primary)
  - Wait 2s after pressing shortcut with fullscreen stuck (edge case) → verify `isExitingFullscreen` resets and a second press works

---

## Phase 3 — Fix Bug 2: Native Drag Handle (User-Opt-In)

*Goal: provide a draggable strip at the top of the ChatBar panel, guarded by a user toggle.*

### Root cause recap
`isMovableByWindowBackground = true` has no effect because WKWebView captures all mouse events. The only native fix is a dedicated `NSView` strip that sits above (or overlaps) the WebView and handles drag events directly.

### Design
- A transparent `NSView` subclass anchored to the top of the `ChatBarPanel` content view, 24pt tall
- Overrides `mouseDown(with:)` to call `window?.performDrag(with:)`
- A drag handle indicator (optional: three short horizontal lines rendered with Core Graphics) in the center of the strip to hint at draggability
- `@AppStorage("chatBarDraggable")` toggle in Settings → General — defaults to `false`
- When the toggle is `false`, the overlay is not added (or is hidden), preserving the full WebView area
- When the toggle is `true`, the overlay is added and the WebView's frame is inset by 24pt from the top

### Tasks

- [ ] **3.1** Add `chatBarDraggable` key to `UserDefaultsKeys`:
  ```swift
  case chatBarDraggable = "chatBarDraggable"
  ```

- [ ] **3.2** Create `DragHandleView: NSView` in `ChatBar/DragHandleView.swift`:
  ```swift
  final class DragHandleView: NSView {
      override var mouseDownCanMoveWindow: Bool { true }

      override func mouseDown(with event: NSEvent) {
          window?.performDrag(with: event)
      }

      override func draw(_ dirtyRect: NSRect) {
          // Draw three short horizontal lines centered in the strip
          NSColor.tertiaryLabelColor.setFill()
          let lineWidth: CGFloat = 20
          let lineHeight: CGFloat = 2
          let gap: CGFloat = 4
          let totalHeight = lineHeight * 3 + gap * 2
          var y = (bounds.height - totalHeight) / 2
          for _ in 0..<3 {
              let rect = NSRect(x: (bounds.width - lineWidth) / 2, y: y, width: lineWidth, height: lineHeight)
              NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
              y += lineHeight + gap
          }
      }
  }
  ```

- [ ] **3.3** In `ChatBarPanel.configureWindow()` (or a new `applyDragHandle()` method called from `init`), check the user default and conditionally add the drag handle:
  ```swift
  private func applyDragHandle() {
      let enabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.chatBarDraggable.rawValue)
      guard enabled, let contentView else { return }

      let handleHeight: CGFloat = 24
      let handle = DragHandleView()
      handle.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(handle, positioned: .above, relativeTo: nil)
      NSLayoutConstraint.activate([
          handle.topAnchor.constraint(equalTo: contentView.topAnchor),
          handle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
          handle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
          handle.heightAnchor.constraint(equalToConstant: handleHeight),
      ])
  }
  ```

  The drag handle sits above the WebView in Z-order. Because the WebView fills the full content area, the WebView still renders behind the handle — the handle only intercepts the top 24pt of hit-testing. No frame inset is needed.

- [ ] **3.4** Add toggle to `SettingsView` under the General section:
  ```swift
  Toggle("Draggable Chat Bar (reduces top content by 24pt)", isOn: $chatBarDraggable)
  ```
  Changing this setting takes effect on the next ChatBar show (a live-update would require destroying and recreating the panel, which is not worth the complexity).

- [ ] **3.5** Update the code comment in `ChatBarPanel.configureWindow()`:
  ```swift
  // isMovableByWindowBackground has no effect because WKWebView captures all mouse
  // events for web content. A native DragHandleView overlay is used instead when
  // the user enables "Draggable Chat Bar" in Settings.
  isMovable = true
  isMovableByWindowBackground = true
  ```

- [ ] **3.6** Build. 0 errors.

- [ ] **3.7** Test:
  - Settings → "Draggable Chat Bar" off (default) → open ChatBar → verify full content visible, dragging does nothing
  - Settings → "Draggable Chat Bar" on → reopen ChatBar → verify drag strip visible at top → drag to reposition → verify window follows
  - Verify drag handle does not interfere with WebView content below it (mouse events outside handle go through to WebView)

---

## Phase 4 — DOM Selector Resilience

*Goal: extract hardcoded Gemini DOM selectors from Swift/JS source into a bundle resource file so they can be updated without a binary release.*

### Background
The conversation detection `MutationObserver` and the focus script target Gemini-specific DOM selectors (`infinite-scroller[data-test-id="chat-history-container"]`, `response-container`, `rich-textarea[aria-label="Enter a prompt here"]`, etc.). These are hardcoded in Swift strings today. A Gemini deploy can break them silently — the ChatBar simply never expands.

### Design
- `Resources/gemini-selectors.json` — a JSON file bundled with the app
- Loaded at runtime by `UserScripts` before injecting JavaScript
- Structure mirrors the selectors in use today
- Future: could be loaded from a remote URL with a local fallback

### Tasks

- [ ] **4.1** Create `Resources/gemini-selectors.json`:
  ```json
  {
    "conversationContainer": "infinite-scroller[data-test-id='chat-history-container']",
    "responseContainer": "response-container",
    "goodResponseButton": "[aria-label='Good response']",
    "badResponseButton": "[aria-label='Bad response']",
    "promptInput": "rich-textarea[aria-label='Enter a prompt here']"
  }
  ```
  Add to Xcode target's "Copy Bundle Resources" build phase.

- [ ] **4.2** Add a loader in `UserScripts` (or a new `GeminiSelectors` struct):
  ```swift
  struct GeminiSelectors {
      let conversationContainer: String
      let responseContainer: String
      let goodResponseButton: String
      let badResponseButton: String
      let promptInput: String

      static func load() -> GeminiSelectors {
          guard let url = Bundle.main.url(forResource: "gemini-selectors", withExtension: "json"),
                let data = try? Data(contentsOf: url),
                let json = try? JSONDecoder().decode(GeminiSelectors.self, from: data) else {
              return .default
          }
          return json
      }

      static let `default` = GeminiSelectors(
          conversationContainer: "infinite-scroller[data-test-id='chat-history-container']",
          responseContainer: "response-container",
          goodResponseButton: "[aria-label='Good response']",
          badResponseButton: "[aria-label='Bad response']",
          promptInput: "rich-textarea[aria-label='Enter a prompt here']"
      )
  }
  extension GeminiSelectors: Codable {}
  ```

- [ ] **4.3** Update `UserScripts.createConversationObserverScript()` and `UserScripts.focusInputScript()` to use `GeminiSelectors.load()` instead of hardcoded strings.

- [ ] **4.4** Build. 0 errors. Verify ChatBar still auto-expands and input focus still works.

---

## Phase 5 — Cleanup

- [ ] **5.1** Remove `mainWindows` computed property from `MainWindowView` if it is now only used by `minimizeToPrompt()` (which no longer does its own `orderOut`). It was also used by `applyColorToAllWindows()` — keep it if still needed there.

- [ ] **5.2** Verify `toggleChatBar()` (keyboard shortcut path) correctly goes through `showChatBar()` and benefits from the fullscreen fix. It does — `toggleChatBar()` calls `showChatBar()` which now calls `showChatBarCore()`. No additional change needed.

- [ ] **5.3** Verify `applicationShouldHandleReopen` still returns `true`. Returning `false` would cause NSApp to attempt `unhideWithoutActivation`, which does not restore `orderOut`-hidden windows. `true` is correct.

- [ ] **5.4** Full regression test using the testing checklist from `docs/MIGRATION-COMPLETE.md`. Add:
  - [ ] Minimize to ChatBar while in fullscreen → fullscreen exits, ChatBar appears on same screen
  - [ ] Click outside ChatBar → dismiss → click Dock icon → exactly one main window appears
  - [ ] Two-window scenario does not reproduce
  - [ ] Drag handle toggle off: full WebView visible, window not draggable
  - [ ] Drag handle toggle on: handle visible, window repositions on drag
  - [ ] ChatBar auto-expands when Gemini responds (DOM selectors still functional)

---

## Risk Register

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `Window` scene behaves differently than `WindowGroup` for `openWindow(id:)` on a hidden window | Low | macOS 15 `Window` focuses/reveals existing window — test in Phase 1.5 |
| App relied on `.handlesExternalEvents` for deep links (undetected) | Low | Phase 0 audit checks `Info.plist` and all `open URL` handlers before removing |
| `toggleFullScreen(nil)` initiates fullscreen exit but neither success nor fail notification fires | Very Low | 2s timeout in `fullscreenExitTimeoutTask` resets `isExitingFullscreen` guard |
| Multi-monitor: ChatBar appears on wrong screen after fullscreen exit | Low | Originating screen captured before `toggleFullScreen(nil)` and passed to `showChatBarCore` |
| `DragHandleView` intercepts WebView mouse events unintentionally (outside 24pt strip) | Very Low | Overlay is constrained to 24pt top; auto layout prevents overlap with rest of WebView |
| `gemini-selectors.json` missing from bundle (build phase omitted) | Low | `GeminiSelectors.load()` falls back to `GeminiSelectors.default` with same hardcoded values |
| Gemini DOM selectors break silently even with JSON approach | Medium | Ongoing — JSON makes updates easier but still requires manual discovery; `checkAndAdjustSize()` falls back to non-expanded state |
| `minimizeToPrompt` removing its own `orderOut` causes a regression | Low | `showChatBarCore()` calls `closeMainWindow()` which does the `orderOut` — same effect, one path |
