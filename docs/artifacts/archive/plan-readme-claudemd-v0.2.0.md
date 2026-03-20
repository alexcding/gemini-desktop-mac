# Plan: Update README.md and CLAUDE.md to v0.2.0

**Research basis:** Codebase audit, `docs/MIGRATION-COMPLETE.md`, `docs/plan-chatbar-fixes.md`
**Marketing version confirmed:** 0.2.0 in `project.pbxproj` lines 399, 450

---

## Confirmed Facts (from audit)

| Item | Current Reality | Old Docs Said |
|------|----------------|---------------|
| macOS minimum | **15.0 (Sequoia)** | 14.0 (Sonoma) |
| Swift version | **6.0, strict concurrency** | Not mentioned |
| Xcode version | **26.2+** (CreatedOnToolsVersion = 26.2) | "Xcode 15+" |
| xcodeproj filename | **GeminiDesktop.xcodeproj** | `GeminiMac.xcodeproj` (bug in README) |
| Marketing version | **0.2.0** | Not mentioned |
| App sandbox | **Enabled** with 6 entitlements | Not mentioned |
| WKAppBoundDomains | **Not configured** | Not mentioned |
| Bundle ID (Debug/Release) | Typo: `com.daveorzach` vs `com.daveorach` | Not mentioned |

---

## README.md Changes

### What to Remove / Correct
- [ ] **1.1** Fix xcodeproj filename: `GeminiMac.xcodeproj` → `GeminiDesktop.xcodeproj`
- [ ] **1.2** Update macOS requirement: `macOS 14.0 (Sonoma)` → `macOS 15.0 (Sequoia)`

### What to Add
- [ ] **1.3** Add version badge header: `v0.2.0`

- [ ] **1.4** Update the Features section to reflect the actual app:

  **Floating Chat Bar** (already there — expand):
  - Quick-access floating panel over all apps
  - Auto-expands when Gemini responds
  - ESC to dismiss, Cmd+N for new chat within the panel
  - Remembers position across screens (multi-display aware)
  - Correct behavior when entering from fullscreen

  **Global Keyboard Shortcut** (already there — keep as-is)

  **Appearance** (new section):
  - System / Light / Dark theme
  - Custom toolbar color with color picker
  - Adjustable text size (60%–140%)

  **Privacy & Security** (new section — important differentiator):
  - Full App Sandbox (camera, microphone, network, file access only via user-granted permissions)
  - No data collection, no telemetry, no accounts required beyond Google sign-in
  - Security-scoped file access for future file features

  **Keyboard Shortcuts** (new section — makes the app feel more like a native app):

  | Shortcut | Action |
  |----------|--------|
  | Cmd+N | New Chat |
  | Cmd+[ | Back |
  | Cmd+] | Forward |
  | Cmd+Shift+H | Go Home |
  | Cmd+R | Reload |
  | Cmd++ | Zoom In |
  | Cmd+- | Zoom Out |
  | Cmd+0 | Actual Size |
  | Cmd+, | Settings |

- [ ] **1.5** Update System Requirements section:
  ```
  - macOS 15.0 (Sequoia) or later
  - Apple Silicon or Intel Mac
  ```

- [ ] **1.6** Remove or update the note *"Adjustable text size (80%-120%)"* in Other Features — the actual range is **60%–140%** (from `SettingsView.Constants`).

### What to Leave Alone
- Disclaimer about Google trademark — keep as-is
- "What this app is / is not" section — still accurate
- Login & Security Notes — still accurate
- Open source declaration — keep

---

## CLAUDE.md Changes

### Section: Project Overview
- [ ] **2.1** Update macOS requirement to **macOS 15.0 (Sequoia)**
- [ ] **2.2** Add Swift 6 mention: *"Swift 6 with strict concurrency enabled"*

### Section: Build & Run
- [ ] **2.3** Update Xcode requirement: `Xcode 15+` → `Xcode 26+`
- [ ] **2.4** Update dependencies list:

  ```
  - KeyboardShortcuts v2.4.0 — global keyboard shortcut recording in Settings
  ```
  *(Yams not yet added — add when the Prompts feature is implemented)*

### Section: Architecture
- [ ] **2.5** Update `ChatBarPanel` description — remove "auto-expansion when a conversation starts (via polling)" — **polling was eliminated in Phase 4 of Swift 6 migration**. Replace with event-driven via `WKScriptMessageHandler`.

- [ ] **2.6** Update the WebViewModel description to mention `@Observable` and `@MainActor`.

- [ ] **2.7** Add `WebViewContainer` note: *NSView subclass managing WKWebView attachment/detachment between window hierarchies. The WKWebView moves between the main window and ChatBarPanel on `NSWindow.didBecomeKeyNotification`.*

- [ ] **2.8** Update JavaScript injection section — currently says "two cases"; there are **three**:
  1. IME fix — CJK double-Enter resolution
  2. Conversation observer — fires once when first response appears, triggers ChatBar auto-expansion
  3. Console log bridge (DEBUG builds only)

- [ ] **2.9** Add concurrency section:
  ```
  ## Concurrency Model
  Swift 6 strict concurrency is fully enabled (SWIFT_STRICT_CONCURRENCY = complete).
  - `@MainActor` on: AppCoordinator, WebViewModel
  - `@Observable` on: AppCoordinator, WebViewModel (replaces ObservableObject)
  - `Mutex<T>` (Swift.Synchronization) for: GeminiWebView.Coordinator.downloadDestination
  - All KVO callbacks use `Task { @MainActor in }` — never `assumeIsolated`
  - NotificationCenter block observers store their token as a property and remove it explicitly
  ```

### Section: Code Organization
- [ ] **2.10** Update the directory map to add new files:
  ```
  App/            # @main app + AppDelegate (weak coordinator reference)
  ChatBar/        # Floating panel (NSPanel subclass + SwiftUI view)
  Coordinators/   # AppCoordinator (central state, window lifecycle, fullscreen coordination)
  WebKit/         # GeminiWebView, WebViewModel, UserScripts, GeminiSelectors
  Views/          # MainWindowView, SettingsView, MenuBarView
  Utils/          # UserDefaultsKeys, AppTheme, BookmarkStore, NSScreen extensions
  Resources/      # Assets, entitlements, Info.plist, gemini-selectors.json
  ```

- [ ] **2.11** Add new files description:
  - **`Utils/BookmarkStore.swift`** — Security-scoped bookmark persistence. `withBookmarkedURL(for:_:)` wrapper uses `defer` to guarantee `stopAccessingSecurityScopedResource()`. Not yet actively used — infrastructure for future Prompts/Artifacts feature.
  - **`WebKit/GeminiSelectors.swift`** — DOM selectors loaded from `Resources/gemini-selectors.json` with hardcoded fallback. Singleton (`GeminiSelectors.shared`) to avoid repeated synchronous file I/O.
  - **`Resources/gemini-selectors.json`** — Externalised Gemini DOM selectors. Update this file to fix selector breakage from Gemini deploys without a binary release.
  - **`Utils/NSScreen+Extensions.swift`** — Screen utility methods: `screen(containing:)`, `screenAtMouseLocation()`, `bottomCenterPoint(for:dockOffset:)`, `centerPoint(for:)`.

### Section: Settings & State Persistence
- [ ] **2.12** Update the settings description to list all current keys:
  ```
  panelWidth / panelHeight   — ChatBar panel size
  pageZoom                   — WebView zoom level
  hideWindowAtLaunch         — suppress main window on startup
  hideDockIcon               — accessory activation policy
  appTheme                   — "system" | "light" | "dark"
  useCustomToolbarColor      — boolean
  toolbarColorHex            — "#RRGGBB" hex string
  promptsDirectoryBookmark   — Data, security-scoped bookmark (future use)
  artifactsDirectoryBookmark — Data, security-scoped bookmark (future use)
  ```

### New Section: Known Constraints
- [ ] **2.13** Add a "Known Constraints" section:
  ```
  ## Known Constraints

  **WKWebView single-hierarchy:** One WKWebView instance exists for the lifetime of the app.
  It moves between the main window and ChatBarPanel on window focus changes. Never create a
  second WKWebView.

  **ChatBar not draggable:** WKWebView consumes all mouse events; isMovableByWindowBackground
  has no effect. This is a macOS/WKWebView limitation with no clean fix.

  **Gemini DOM selectors are fragile:** All JavaScript targeting Gemini's UI (conversation
  detection, input focus) uses selectors in gemini-selectors.json. A Gemini deploy can break
  them silently. Update the JSON file when selectors change.

  **WKAppBoundDomains not configured:** evaluateJavaScript on gemini.google.com currently
  works because limitsNavigationsToAppBoundDomains defaults to false. If this changes or
  the future Prompt injection feature needs it explicitly, add gemini.google.com and
  accounts.google.com to WKAppBoundDomains in Info.plist.

  **Window scene: Window (not WindowGroup):** The app uses SwiftUI Window (single-instance)
  for the main window to prevent duplicate window creation when the main window is hidden via
  AppKit orderOut. Do not change this to WindowGroup.

  **Bundle ID inconsistency:** Debug uses com.daveorzach.geminidesktop, Release uses
  com.daveorach.geminidesktop (typo). These should be unified before App Store submission.
  ```

---

## What NOT to Change in Either File

- Legal disclaimer (Google trademark)
- "No tracking, no data collection" statement — still true
- Authentication/security notes
- Any description of the Chat Bar's core behavior that is still accurate

---

## Suggested Final README Structure

```
# Gemini Desktop for macOS (Unofficial)   [v0.2.0]

[screenshots]

[disclaimer]

---

## Features
### Floating Chat Bar
### Native Keyboard Shortcuts   ← new
### Appearance                  ← new
### Privacy & Security          ← new

---

## What This App Is (and Isn't)    [unchanged]

---

## Login & Security Notes          [unchanged]

---

## System Requirements
- macOS 15.0 (Sequoia) or later   ← updated

---

## Installation
### Download                       [unchanged]
### Build from Source              ← fix xcodeproj name
```

---

## Notes for Implementation

- Both files should be edited, not rewritten from scratch — the existing structure is good.
- The bundle ID typo is documented as a known constraint in CLAUDE.md but not surfaced in README (user-facing document should not expose internal implementation details).
- `WKAppBoundDomains` note belongs in CLAUDE.md (developer guidance) not README.
- Keep CLAUDE.md concise — it is loaded into context on every conversation, so every line costs tokens.
