# Research: ChatBar Issues

**Scope:** Three reported bugs in the ChatBar / minimizeToPrompt flow

---

## Bug 1: Entering ChatBar from Fullscreen Doesn't Exit Fullscreen

### What happens
When the main window is in fullscreen mode and the user clicks "Minimize to Prompt Panel", `minimizeToPrompt()` in `MainWindowView.swift` calls `mainWindows.first?.orderOut(nil)`. `orderOut` on a fullscreen window does not exit fullscreen — it hides the window while the fullscreen space remains active. The ChatBar then appears floating above the fullscreen space rather than returning the user to their normal desktop.

### Root cause
`MainWindowView.minimizeToPrompt()` → `window.orderOut(nil)`.
`AppCoordinator.showChatBar()` → `closeMainWindow()` → `window.orderOut(nil)`.

Neither path checks `window.styleMask.contains(.fullScreen)` before hiding. AppKit requires explicitly calling `window.toggleFullScreen(nil)` to exit fullscreen, and that exit is animated and asynchronous — the window isn't actually out of fullscreen until `windowDidExitFullScreen(_:)` fires.

### Fix
Before hiding the main window in `showChatBar()`:
1. Check if the window is in fullscreen
2. If so, exit fullscreen first and defer the rest of `showChatBar()` until `windowDidExitFullScreen` fires
3. Use `NSWindowDelegate.windowDidExitFullScreen` or a one-shot observer on `NSWindow.didExitFullScreenNotification`

```swift
func showChatBar() {
    if let window = findMainWindow(), window.styleMask.contains(.fullScreen) {
        // Exit fullscreen first, show chat bar after the animation completes
        NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            NotificationCenter.default.removeObserver(self as AnyObject,
                name: NSWindow.didExitFullScreenNotification, object: window)
            self?.showChatBarAfterFullscreenExit()
        }
        window.toggleFullScreen(nil)
        return
    }
    showChatBarAfterFullscreenExit()
}
```

---

## Bug 2: ChatBar Window Cannot Be Moved

### What happens
The ChatBar window cannot be dragged to reposition it, despite `isMovable = true` and `isMovableByWindowBackground = true` being set in `ChatBarPanel.configureWindow()`.

### Root cause — WKWebView limitation, not a design choice
`isMovableByWindowBackground = true` allows dragging from any non-interactive area of the window. However, `WKWebView` (via `WebViewContainer`) fills the entire content area of the panel. WKWebView captures **all** mouse events for web content — click, drag, scroll — so there is no exposed "background" for the window manager to intercept drag gestures from. The window system never sees the drag events because WKWebView consumes them.

This is a fundamental limitation of embedding WKWebView in a borderless panel. Any app that makes a WKWebView fill an entire panel window faces this same constraint (e.g., Electron apps solve it with `-webkit-app-region: drag` CSS on designated areas of the webpage itself, which we can't add to gemini.google.com).

### What would fix it
The only practical option is a **dedicated drag handle** — a native NSView strip positioned above or overlapping the top edge of the WebView that handles `mouseDown` / `mouseDragged` events and calls `window.performDrag(with:)`. This would need to be:
- Narrow enough not to interfere with the WebView content significantly
- Placed at the top of the panel, within the rounded corner region
- Distinct from the expand button already in the top-left

A thin (~20pt) transparent overlay at the top of the ChatBar that doesn't cover the WebView content would work, but it permanently reduces the visible web area and changes the UX.

**Alternative: inject CSS into the Gemini page** using `evaluateJavaScript` to add `-webkit-app-region: drag` to the Gemini header bar. This would make the Gemini toolbar area act as a native drag handle. This is fragile (Gemini's DOM can change) but is used by macOS Electron apps wrapping web content.

### Recommendation
Document this as a known limitation. Don't add a drag handle strip — it adds complexity for a marginal benefit given the ChatBar already repositions itself to the correct screen when toggled.

---

## Bug 3: Two Windows + Blank Green Window After Dock Click

### What happens
1. User is in ChatBar (main window hidden with `orderOut`)
2. Clicking outside the ChatBar dismisses it (global click monitor → `orderOut`)
3. User clicks the Dock icon
4. Two windows appear:
   - One normal main window with Gemini content
   - One blank green window (green background, no content)
5. Clicking the green window moves the WebView content into it
6. The state is recoverable by toggling minimize/expand twice

### Root cause — SwiftUI `WindowGroup` + AppKit `orderOut` conflict

This is the central design tension in the app. The app uses `WindowGroup` (SwiftUI scene management) to create the main window, but hides it with AppKit's `orderOut(nil)`. These two systems have different models of what "exists":

**AppKit's model:** `orderOut(nil)` removes a window from the screen but the `NSWindow` object survives in memory and remains in `NSApp.windows`.

**SwiftUI `WindowGroup`'s model:** `WindowGroup` tracks scene instances. When `orderOut` is called directly on the underlying NSWindow, SwiftUI's scene manager is **not notified** — it still considers the scene "active". When `openWindow(id: "main")` is called again, SwiftUI may create a **new window instance** rather than revealing the hidden one, because it has no mechanism to detect the AppKit-level hide.

### Exact sequence that creates two windows

1. App launches — SwiftUI creates Window A ("Gemini Desktop") via `WindowGroup`
2. `minimizeToPrompt()` calls `window.orderOut(nil)` on Window A — hidden from screen, alive in memory
3. ChatBar is shown
4. Global click monitor fires, ChatBar dismissed with `orderOut`
5. User clicks Dock icon → `applicationShouldHandleReopen` fires
6. `Task { await coordinator?.openMainWindow() }` runs
7. `openMainWindow()` calls `findMainWindow()` which finds Window A (still in `NSApp.windows`)
8. `window.makeKeyAndOrderFront(nil)` brings Window A back — ✅ correct
9. BUT: `NSApp.activate(ignoringOtherApps: true)` triggers SwiftUI scene restoration
10. SwiftUI's `WindowGroup` scene detects the app is activating and sees no "SwiftUI-visible" window (because the hide was AppKit-level)
11. SwiftUI creates **Window B** — a new `WindowGroup` instance
12. Window B runs `setupWindowAppearance` → gets the green `backgroundColor` → **blank green window**

### Why the WebView "switches" between windows

`WebViewContainer.attachWebView()` is triggered by `NSWindow.didBecomeKeyNotification`. Whichever window becomes key, the WebView moves into that container. Clicking the blank green window makes it key → WebView moves to it → green window now has content → original window is blank.

### The prior implementation used `Window` (not `WindowGroup`)

Looking at git history (commit `2fb42c9`), the original code used `Window` (single-instance scene). The switch to `WindowGroup` was made to fix `.handlesExternalEvents(matching:)`. But `Window` vs `WindowGroup` is the source of this bug:

- `Window` — single scene, SwiftUI knows there is exactly one instance, never creates a second
- `WindowGroup` — can have multiple instances, SwiftUI will create new ones when asked

### Three possible fix paths

**Option A: Switch back to `Window`** (lowest risk)
`Window` is a single-instance scene — SwiftUI cannot create a second window. The `.handlesExternalEvents` issue that prompted the switch needs to be diagnosed separately. This is the cleanest architectural fix.

**Option B: Stop using `orderOut` for the main window**
Instead of hiding with `orderOut`, move the main window off-screen or set `alphaValue = 0`. SwiftUI considers the window still "visible" (in its model), preventing it from creating a duplicate.
- `window.setFrame(NSRect(x: -10000, y: -10000, width: ...), display: false)` — moves off-screen
- `window.alphaValue = 0` + `window.ignoresMouseEvents = true` — invisible but present
- These approaches keep SwiftUI's scene state consistent but are hacky

**Option C: Accept `WindowGroup` but close duplicate windows**
In `MainWindowView.onAppear`, detect if a duplicate window already exists with the same title and immediately close the newly created one. This is a defensive workaround, not a fix.

### Recommendation

**Option A** (switch back to `Window`) should be investigated first. If the `handlesExternalEvents` issue that caused the original switch is minor or solvable, this eliminates the entire class of problem. A `Window` scene + `NSApplicationDelegate.applicationShouldHandleReopen` returning `false` (letting the system unhide) may be sufficient.

---

## Summary

| Bug | Root Cause | Type |
|-----|-----------|------|
| Fullscreen not exited | `orderOut` doesn't exit fullscreen; no async wait for exit animation | Code bug — fixable |
| Window not draggable | WKWebView consumes all mouse events; no exposed background | WKWebView limitation — known constraint |
| Two windows / blank green | `WindowGroup` creates new instances when AppKit `orderOut` hides windows invisibly | Architectural — requires `Window` vs `WindowGroup` decision |

---

## Bigger Picture: Should ChatBar Be Reconsidered?

The user raised this directly. Several things to weigh:

**What works:**
- The expand-to-main-window pattern is functional
- The event-driven size expansion (post migration) is solid
- The keyboard shortcut toggle works

**What is broken or limited:**
- Cannot drag/reposition (WKWebView constraint, not fixable without native drag handle)
- Window lifecycle conflicts with SwiftUI scene management (fixable but requires care)
- Fullscreen transition not handled (fixable)
- Gemini's DOM selectors for the conversation detector are fragile and could break on any Gemini update

**What Gemini may have changed:**
The conversation-detection `MutationObserver` targets:
```
infinite-scroller[data-test-id="chat-history-container"]
```
and looks for `response-container`, `[aria-label="Good response"]`, `[aria-label="Bad response"]`. If Gemini has updated its component names (it's a web app that deploys continuously), these selectors may be stale and the auto-expansion may never trigger.

The focus script targets:
```
rich-textarea[aria-label="Enter a prompt here"]
```
This is a custom element that Google could rename at any point.

**Verdict:** The ChatBar feature is fundamentally a "best effort" feature that wraps a web app Google didn't design for desktop embedding. The window management bugs are fixable. The movability limitation is real but acceptable. The Gemini DOM dependency is the biggest ongoing maintenance risk — it can break silently with any Gemini deployment.
