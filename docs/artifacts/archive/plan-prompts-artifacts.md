# Plan: Prompts & Artifacts Feature

## Context
The app currently has security-scoped bookmark infrastructure (`BookmarkStore`, `promptsDirectoryBookmark`, `artifactsDirectoryBookmark` keys) defined but unused. This plan implements the full Prompts & Artifacts feature on top of that foundation, adding a toolbar dropdown that lets users inject saved Markdown prompts into Gemini and capture Gemini's last response as a saved Markdown artifact. A native App Intents layer exposes the same capabilities to macOS Spotlight, Shortcuts, and Siri.

This plan also absorbs the edge-to-edge UI work (`docs/plan-edge-to-edge-ui.md`, now superseded). The two plans share `MainWindowView.swift` and must be implemented together: the banner overlay from prompts and the full-bleed WebView from edge-to-edge require a `ZStack` architecture described in Phase 5.

Security constraints: Tier-1 regex scanning only (Foundation Models dropped from V1). Users always have override — the scanner flags but never blocks.

---

## New Dependency
**Yams** — add via Xcode SPM: `https://github.com/jpsim/Yams`, version `5.1.3+`, target `GeminiDesktop`.

---

## Phase 0 — Foundation (zero visible change, always buildable)

### 0.1 `Resources/gemini-selectors.json`
Add 3 keys to the existing 5:
```json
"richTextareaSelector": "rich-textarea[aria-label='Enter a prompt here']",
"sendButtonSelector":   "button[aria-label='Send message']",
"lastResponseSelector": "model-response:last-of-type"
```

### 0.2 `WebKit/GeminiSelectors.swift`
Add 3 new `let` properties + update `.default` to match.

### 0.3 `Utils/UserDefaultsKeys.swift`
Add one case (bookmark keys already exist):
```swift
case promptInjectionMode   // "copy" | "inject"
```

### 0.4 Edge-to-Edge Foundation

> **Decision recorded from UI shell review (2026-03-16):** `fullSizeContentView` was prototyped and rejected. When inserted, it causes AppKit to compute the toolbar's visual bottom edge using the window's screen-relative Y position, inflating the toolbar height by the menu bar height (~24pt). There is no writable API to correct this (`contentLayoutRect` is get-only; `additionalSafeAreaInsets` requires reaching inside SwiftUI's private `NSHostingController`). The flag is therefore **not used**.
>
> `fullSizeContentView` is also unnecessary for this app. `titlebarAppearsTransparent = true` + `window.backgroundColor = geminiGreen` already produces a seamless toolbar because Gemini's web page header is the same green. The only visible gap without `fullSizeContentView` is a white flash in the toolbar area during page load — fixed by `underPageBackgroundColor` below. The ZStack architecture (Phase 5) is kept for the banner overlay but `.ignoresSafeArea` is not used.

**`WebKit/WebViewModel.swift` — `underPageBackgroundColor`**

Set the over-scroll bounce color on the WKWebView instance to match the window background. Without this, bouncing past the top of the page shows the system default (white in light mode, dark gray in dark mode) through the transparent toolbar during page load and over-scroll:

```swift
// After WKWebView initialisation in WebViewModel.init():
if #available(macOS 12.3, *) {
    wkWebView.underPageBackgroundColor = GeminiDesktopApp.Constants.toolbarColor
}
```

**Full-screen transparency — `AppCoordinator` as `NSWindowDelegate`**

> **Decision recorded from UI shell review (2026-03-16):** `NotificationCenter` block observers were prototyped and rejected. The `willEnterFullScreenNotification` observer caused the toolbar to render at 2× height with a dark tint. Root cause: macOS resets `titlebarAppearsTransparent` during the full-screen animation; fighting that reset via `willEnter` triggers a second layout pass at double height.

The correct fix is `NSWindowDelegate.windowDidEnterFullScreen` — a single delegate callback that fires **after** the transition completes, when the toolbar layout is stable:

```swift
// In AppCoordinator (Phase 2), after wiring as window delegate:
func windowDidEnterFullScreen(_ notification: Notification) {
    findMainWindow()?.titlebarAppearsTransparent = true
}
```

`AppCoordinator` already manages the window lifecycle and is the correct owner of the delegate. `MainWindowView.setupWindowAppearance` stays as the simple 4-line implementation (no observers).

These two changes are the complete edge-to-edge foundation. The ZStack layout architecture lives in Phase 5.

---

## Phase 1 — Data Layer (new `Prompts/` group, 5 files)

### `Prompts/PromptMetadata.swift`
`struct PromptMetadata` — parses YAML frontmatter using Yams. Required: `title: String`, `description: String`. Optional: `tags`, `category`, `author`, `version`, `model`.

Key methods:
- `static func parse(from: String) -> PromptMetadata?` — splits on `---` delimiter, `Yams.load(yaml:)`, returns nil if required fields absent
- `static func extractBody(from: String) -> String` — everything after closing `---`

### `Prompts/PromptScanner.swift`
`enum ScanResult { case safe, warning(reason: String), danger(reason: String) }`

`enum PromptScanner` — static `scan(body: String) -> ScanResult`. Tier-1 regex only:
- Danger: `ignore previous instructions`, `you are now`, URL exfiltration, `<script>`, `system prompt`
- Warning: `forget everything`, `act as if`, `jailbreak`, template placeholders `{…}`

Uses `NSRegularExpression`. Runs on body only (not frontmatter). Never blocks — result is advisory.

### `Prompts/PromptFile.swift`
```swift
struct PromptFile: Identifiable, Equatable {
    let url: URL
    let metadata: PromptMetadata?   // nil if frontmatter absent OR parse failed
    let yamlParseError: Bool        // true ONLY if --- delimiters present but Yams threw
    let body: String
    let scanResult: ScanResult
    var displayTitle: String        // metadata.title ?? (yamlParseError ? "⚠️ (YAML Error) {stem}" : stem)
    var displayDescription: String?
    static func load(from: URL) -> PromptFile  // reads + parses + scans
}

> **YAML parse logic:** In `load(from:)`, check `content.hasPrefix("---")` before invoking Yams. If the file has no `---` prefix, set `metadata = nil` and `yamlParseError = false` — a plain `.md` file with no frontmatter is valid, not broken. Only set `yamlParseError = true` if the `---` delimiters are present but Yams throws during parsing.

enum PromptNode: Identifiable {
    case file(PromptFile)
    case directory(name: String, children: [PromptNode])
}
```

### `Prompts/PromptDirectoryWatcher.swift`
FSEvents C-API wrapper. NOT `@MainActor` (holds raw `FSEventStreamRef`). Callbacks hop to `@MainActor` via `Task { @MainActor in }`.

```swift
final class PromptDirectoryWatcher: @unchecked Sendable {
    var onChange: (@MainActor () -> Void)?
    func start(at path: String)     // FSEventStreamCreate + schedule on main run loop
    func stop()                     // FSEventStreamStop + invalidate + release
}
```

FSEvents flags: `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer`. Latency: 0.5s.

Use `Unmanaged.passRetained(self)` as context; `fromOpaque` in callback. In `stop()`, balance with `Unmanaged.fromOpaque(info).release()` — **never** `passUnretained(self).release()`, which over-releases the object and crashes.

**Debounce:** `PromptDirectoryWatcher` must debounce its `onChange` callback. Bulk operations (e.g. unzipping 50 prompt files) fire dozens of FSEvents in milliseconds. Without debouncing, each event triggers `PromptLibrary.reload()` and `updateAppShortcutsParameters()`, thrashing the disk and hammering the Spotlight indexer.

Implementation: hold a `DispatchWorkItem?` in the watcher. On each FSEvent callback, cancel the pending item and schedule a new one with a 0.5s delay. Only the final item fires `onChange`.

```swift
private var debounceItem: DispatchWorkItem?

// Inside the FSEvent callback:
debounceItem?.cancel()
let item = DispatchWorkItem { [weak self] in
    Task { @MainActor in self?.onChange?() }
}
debounceItem = item
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
```

### `Prompts/PromptLibrary.swift`
`@MainActor @Observable final class PromptLibrary`

```swift
private(set) var rootNodes: [PromptNode] = []
private(set) var allFiles: [PromptFile] = []
private(set) var loadError: String? = nil
private var watcher: PromptDirectoryWatcher?
private let bookmarkStore = BookmarkStore()    // reuses Utils/BookmarkStore.swift

func reload()          // bookmarkStore.withBookmarkedURL(.promptsDirectoryBookmark) + buildTree
func startWatching()   // PromptDirectoryWatcher(path:); onChange = { [weak self] in reload() }
func stopWatching()
```

> **Security-scoped bookmarks in background context:** When an App Intent triggers `reload()` or `saveArtifact` while the app has no foreground window, `BookmarkStore.withBookmarkedURL` must still call `url.startAccessingSecurityScopedResource()` before any file I/O and `stopAccessingSecurityScopedResource()` in a `defer` block. Security-scoped bookmarks permit background access but only when access is explicitly started. If `startAccessingSecurityScopedResource()` returns `false`, surface an `IntentError.directoryUnavailable` — do not silently fail.

```swift
```

`buildTree` recursively reads directory with `FileManager.contentsOfDirectory(includingPropertiesForKeys:)`, creates `PromptNode` tree from `.md` files and subdirs. Skips hidden files and empty directories.

After each `reload()`, call `updateAppShortcutsParameters()` (from Phase 6) to keep Spotlight index fresh.

---

## Phase 2 — AppCoordinator Extensions

**File:** `Coordinators/AppCoordinator.swift`

Add after line 16 (`var webViewModel = WebViewModel()`):
```swift
let promptLibrary = PromptLibrary()
private(set) var isInjecting: Bool = false
private(set) var injectionBannerMessage: String? = nil
```

Expand `init()` (currently empty):
```swift
init() {
    promptLibrary.reload()
    promptLibrary.startWatching()
}
```

Add methods:

**`escapeForJavaScript(_ text: String) -> String`** (private or fileprivate free function):
Escapes `\`, `'`, `\n`, `\r`, `\0` for safe embedding in a JS single-quoted string literal.

**`injectPrompt(_ file: PromptFile)`**:
- Guard `!isInjecting`
- Hard length check: if `file.body.count > 16_000`, set `injectionBannerMessage = "Prompt is too long (\(file.body.count.formatted())/16,000 characters). Please shorten it."` and return — **do not truncate silently**
- `escapeForJavaScript(text)` → `UserScripts.createInjectionScript(escapedText:richTextareaSelector:)`
- Set `isInjecting = true`; reset in completion handler
- On JS return `false`: set `injectionBannerMessage = "Could not inject — make sure you're signed in to Gemini."`

**`injectText(_ text: String)`** (used by App Intents — accepts raw string, already composed):
- Same length check: if `text.count > 16_000`, throws `IntentError.promptTooLong(text.count)` — no silent truncation
- Same pipeline as `injectPrompt`; returns `async throws` for App Intents compatibility
- Also checks `webViewModel.isPageReady` before injecting (see readiness state below)

**`copyPromptToClipboard(_ file: PromptFile)`**:
`NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.body, forType: .string)`

**`captureLastResponse(suggestedFilename:)`**:
- `UserScripts.createCaptureScript(lastResponseSelector:)` → `evaluateJavaScript`
- On result: call `saveArtifact(markdown: filename:)`

**`captureLastResponseAsString() async throws -> String`** (used by App Intents):
- Same JS evaluation as above but returns the Markdown string to the caller instead of saving to disk
- Throws `AppIntentError.noResponseAvailable` if element not found or result empty

**`captureLastResponse(suggestedFilename:)`**:
- **Streaming guard:** Before evaluating JS, check for the "Stop generating" button in the DOM (selector: `button[aria-label='Stop response']`). If present, Gemini is still streaming — set `injectionBannerMessage = "Wait for Gemini to finish before capturing."` and return early. Do not capture a partial response.
- If `suggestedFilename` is nil or empty, generate a timestamp-based default using `DateFormatter` with `dateFormat = "yyyy-MM-dd-HHmmss"` → e.g. `Gemini-2026-03-16-184635.md`. Do **not** use `ISO8601DateFormatter().string(from:).prefix(15)` — that yields `2026-03-16T18:4`, chopping mid-minute and creating collisions within the same 10-minute window.
- This eliminates the vast majority of collisions and organizes the artifacts dir chronologically
- `UserScripts.createCaptureScript(lastResponseSelector:)` → `evaluateJavaScript`
- On result: call `saveArtifact(markdown: filename:)`

**`saveArtifact(markdown:filename:)` (private)**:
- `BookmarkStore().withBookmarkedURL(for: .artifactsDirectoryBookmark) { dirURL in … }`
- Name collision loop: append `-1`, `-2`, etc. (rare fallback now that default is timestamp-based)
- Guard: if `markdown.hasPrefix("---")` do NOT prepend frontmatter (collision guard)
- Otherwise prepend: `---\ncaptured_at: ISO8601\nsource: gemini.google.com\n---\n\n`
- `finalContent.write(to:, atomically: true, encoding: .utf8)`
- On `nil` result: set `injectionBannerMessage = "Artifacts directory unavailable…"`

**`dismissInjectionBanner()`**: `injectionBannerMessage = nil`

**WebView readiness state** (used by App Intents cold-boot fix):

Add to `AppCoordinator`:
```swift
private(set) var isPageReady: Bool = false
```

`AppCoordinator` must be marked `@MainActor` (Swift 6 strict concurrency). `isPageReady` is written by the `WKNavigationDelegate` on the main thread and read by `waitForPageReady` inside App Intent `perform()` which runs on a background executor. Without `@MainActor` isolation on the coordinator, Swift 6 will flag this as a data race. Marking the whole coordinator `@MainActor` is the correct fix — it makes all property accesses implicitly safe and the intent's `perform()` will `await` the coordinator on the main actor.

Set `isPageReady = true` in `webViewModel`'s navigation delegate callback `didFinish` (already observed via `WebViewModel`); reset to `false` on `didStartProvisionalNavigation`.

```swift
// Inside injectText, before evaluateJavaScript:
if !isPageReady {
    // Wait up to 30s for page to become ready; throw notAuthenticated if timeout
    try await waitForPageReady(timeout: 30)
}
```

`waitForPageReady(timeout:)` polls `isPageReady` via a `Task.sleep` loop (check every 0.5s). After timeout, throws `IntentError.notAuthenticated`. This covers the cold-boot race condition where the Intent fires while the WebView is still loading `gemini.google.com`.

---

## Phase 3 — JavaScript (UserScripts.swift)

**File:** `WebKit/UserScripts.swift`

Add two static methods to the `UserScripts` enum:

**`createInjectionScript(escapedText: String, richTextareaSelector: String) -> String`**

IIFE that:
1. Finds `rich-textarea` (shadow DOM for contenteditable) or falls back to `[contenteditable="true"]`
2. Returns `false` if not found (auth guard → Swift shows banner)
3. Primary: `document.execCommand('insertText', false, escapedText)`
4. Fallback if `inserted == false`: `DataTransfer` + `InputEvent('input', { inputType: 'insertText' })`
5. Returns `true` on success

Uses string interpolation like existing `conversationObserverSource`.

**`createCaptureScript(lastResponseSelector: String) -> String`**

IIFE containing `domToMarkdown(node)` function:
- `h1–h6` → `# …`
- `p` → `…\n\n`
- `strong/b` → `**…**`, `em/i` → `_…_`
- `code` (inline) → `` `…` ``
- `pre` → `` ```lang\n{node.innerText || node.textContent}\n``` `` (innerText primary, textContent fallback for syntax-highlighted spans)
- `ul/ol` → `- item` / `1. item` using `:scope > li`
- `a` → `[text](href)`
- `blockquote` → `> …`
- `table` → pipe-delimited Markdown
- All others → recurse children

Returns `domToMarkdown(lastResponseEl).trim()` or `''` if element not found.

**Streaming state check** (embedded in the same IIFE, before `domToMarkdown`):
```js
if (document.querySelector("button[aria-label='Stop response']")) {
    return '__streaming__';   // sentinel; Swift checks for this and shows banner
}
```
Swift side: if result string equals `'__streaming__'`, set `injectionBannerMessage` and skip `saveArtifact`.

---

## Phase 4 — Settings UI (SettingsView.swift)

Add to form after existing "Privacy" section:

```swift
Section("Prompts & Artifacts") {
    // Prompts dir row: directory label + "Choose..." NSOpenPanel button
    // Artifacts dir row: same pattern
    // Prompt Mode picker: "Copy to Clipboard" | "Inject into Gemini" (.segmented)
}
```

Add `@AppStorage(UserDefaultsKeys.promptInjectionMode.rawValue)` + two `@State` labels for directory names.

**`chooseDirectory(for:onPicked:)` helper** — follows `GeminiWebView.swift:126-134` pattern:
```swift
let panel = NSOpenPanel()
panel.canChooseFiles = false; panel.canChooseDirectories = true
panel.begin { response in
    guard response == .OK, let url = panel.url else { return }
    try? bookmarkStore.saveBookmark(for: url, key: key)
    onPicked(url)
}
```

On `onPicked` for prompts dir: call `coordinator.promptLibrary.reload()` and `startWatching()`.

---

## Phase 5 — Toolbar UI (new view files + MainWindowView.swift)

### `Views/PromptsMenuButton.swift`
`struct PromptsMenuButton: View` — `Menu {}` in toolbar.

Recursive `nodeView(for: PromptNode)`: `.directory` → `Menu(name) { children }`, `.file` → `promptMenuItem`.

`promptMenuItem`: `Button` with `VStack` label (title on line 1, description in `.caption .secondary` on line 2). Badge prefix: `⚠️ ` / `🚫 ` prepended to title string. `.help()` NOT used in menus — subtitle label is the affordance.

`handleSelection`: if `.danger`, show `NSAlert` with "Use Anyway" / "Cancel" before proceeding. Otherwise call `coordinator.injectPrompt` or `copyPromptToClipboard` based on `injectionMode`.

`.disabled(coordinator.isInjecting)`

### `Views/ArtifactCaptureButton.swift`
`struct ArtifactCaptureButton: View` — `Button` with `Image(systemName: "square.and.arrow.down.on.square")` + `.sheet` for filename input.

Sheet: `TextField` + "Save" / "Cancel". On save: `coordinator.captureLastResponse(suggestedFilename: name)`.

### `Views/MainWindowView.swift` — ZStack architecture + toolbar additions

**Why ZStack instead of `.overlay`:**
Phase 0.4 adds `fullSizeContentView` + the WebView uses `.ignoresSafeArea(.all, edges: .top)` to fill the full window including the title bar region. A `.overlay(alignment: .top)` applied to a full-bleed view anchors to the very top of the window — behind the toolbar buttons. The fix is a `ZStack` where:
- `GeminiWebView` is the bottom layer, full-bleed via `.ignoresSafeArea(.all, edges: .top)`
- The banner lives above it in the ZStack's natural coordinate space, which respects the safe area and thus starts below the toolbar

**New `body` structure:**

```swift
var body: some View {
    ZStack(alignment: .top) {
        GeminiWebView(webView: coordinator.webViewModel.wkWebView)
            .ignoresSafeArea(.all, edges: .top)

        if let msg = coordinator.injectionBannerMessage {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(msg)
                Spacer()
                Button("Dismiss") { coordinator.dismissInjectionBanner() }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .top], 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: coordinator.injectionBannerMessage)
        }
    }
    .background(WindowAccessor { window in
        setupWindowAppearance(window)
    })
    .onAppear {
        coordinator.openWindowAction = { id in openWindow(id: id) }
    }
    .onChange(of: useCustomToolbarColor) { _, _ in applyColorToAllWindows() }
    .onChange(of: toolbarColorHex) { _, _ in applyColorToAllWindows() }
    .toolbar {
        // ... all existing + new toolbar items (unchanged placement logic)
    }
}
```

The `.background(WindowAccessor)`, `.onAppear`, `.onChange`, and `.toolbar` modifiers move from `GeminiWebView` to the `ZStack`. The `GeminiWebView` inside the ZStack carries only `.ignoresSafeArea`.

Add `@AppStorage(UserDefaultsKeys.promptInjectionMode.rawValue)` property.

**Toolbar items** — insert before the existing `.primaryAction` minimize button:

```swift
ToolbarItem(placement: .primaryAction) {
    ArtifactCaptureButton(coordinator: coordinator)
}
ToolbarItem(placement: .primaryAction) {
    PromptsMenuButton(coordinator: coordinator, injectionMode: promptInjectionMode)
}
// existing minimize button stays here — rightmost
```

---

## Phase 6 — App Intents (new `Intents/` group, 4 files)

Exposes the prompt library and capture pipeline to macOS Spotlight, Shortcuts, and Siri. No AI agents, no background processing — deterministic Swift code only.

**Requirements:** `AppIntents` framework (built into macOS 13+ SDK; no SPM addition needed).

### `Intents/PromptAppEntity.swift`

```swift
struct PromptAppEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Prompt"
    static var defaultQuery = PromptEntityQuery()

    var id: String          // prompt URL absolute string
    var title: String
    var summary: String     // metadata.description ?? ""
    var tags: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(summary)")
    }
}
```

Initialised from `PromptFile`:
```swift
extension PromptFile {
    var asAppEntity: PromptAppEntity {
        PromptAppEntity(id: url.absoluteString, title: displayTitle,
                        summary: displayDescription ?? "", tags: metadata?.tags ?? [])
    }
}
```

### `Intents/PromptEntityQuery.swift`

```swift
struct PromptEntityQuery: EntityQuery {
    @Dependency var library: PromptLibrary   // resolved via AppDependencyManager

    func entities(for ids: [String]) async throws -> [PromptAppEntity] {
        library.allFiles.filter { ids.contains($0.url.absoluteString) }.map(\.asAppEntity)
    }

    func suggestedEntities() async throws -> [PromptAppEntity] {
        library.allFiles.map(\.asAppEntity)
    }
}
```

Cache note: `library.allFiles` is already in memory (populated by `PromptLibrary.reload()`). No disk I/O at query time. Spotlight search is instantaneous.

### `Intents/InjectPromptIntent.swift`

```swift
struct InjectPromptIntent: AppIntent {
    static var title: LocalizedStringResource = "Inject Prompt into Gemini"
    static var description = IntentDescription("Brings Gemini Desktop to the foreground and injects a saved prompt into the input field.")
    static var openAppWhenRun: Bool = true   // MUST remain true — macOS App Nap suspends WKWebView JS execution when the window is hidden/occluded; forcing foreground guarantees evaluateJavaScript runs

    @Parameter(title: "Prompt") var prompt: PromptAppEntity
    @Parameter(title: "Additional Text", default: "") var additionalText: String

    @Dependency var coordinator: AppCoordinator

    func perform() async throws -> some IntentResult {
        // 1. Resolve PromptFile from entity ID
        guard let file = coordinator.promptLibrary.allFiles
            .first(where: { $0.url.absoluteString == prompt.id }) else {
            throw IntentError.promptNotFound
        }

        // 2. Hard length check — never silently truncate
        let composed = additionalText.isEmpty ? file.body : file.body + "\n\n" + additionalText
        if composed.count > 16_000 {
            throw IntentError.promptTooLong(composed.count)
        }

        // 3. Tier-1 security scan
        // For Intents: .danger immediately halts and returns a descriptive error to Shortcuts.
        // Do NOT await an NSAlert — macOS Intent timeouts (~10-20s) will silently crash the
        // Shortcut if the user steps away before clicking. The in-app UI handles confirmation
        // for toolbar-triggered injections; the Intent path takes the safe halt-and-report route.
        let scanResult = PromptScanner.scan(body: composed)
        if case .danger(let reason) = scanResult {
            throw IntentError.dangerPatternDetected(reason)
        }

        // 4. Inject (waits for page readiness; throws notAuthenticated on timeout)
        try await coordinator.injectText(composed)
        return .result()
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case promptNotFound
    case promptTooLong(Int)
    case notAuthenticated
    case dangerPatternDetected(String)
    case noResponseAvailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .promptNotFound:
            return "Prompt not found in library."
        case .promptTooLong(let count):
            return "Prompt is too long (\(count)/16,000 characters). Shorten it in the app and try again."
        case .notAuthenticated:
            return "Gemini Desktop isn't ready. Open the app, sign in to Gemini, and try again."
        case .dangerPatternDetected(let reason):
            return "Prompt flagged for security (\(reason)). Open Gemini Desktop and inject it manually to review and confirm."
        case .noResponseAvailable:
            return "No Gemini response found. Make sure a response is visible in the app."
        }
    }
}
```

### `Intents/CaptureLastArtifactIntent.swift`

```swift
struct CaptureLastArtifactIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Last Gemini Response"
    static var description = IntentDescription(
        "Returns the last Gemini response as Markdown. Use in Shortcuts to pipe into Obsidian, Git, or any file.")
    static var openAppWhenRun: Bool = true   // MUST remain true — see InjectPromptIntent note on App Nap

    @Dependency var coordinator: AppCoordinator

    func perform() async throws -> some ReturnsValue<String> {
        let markdown = try await coordinator.captureLastResponseAsString()
        guard !markdown.isEmpty else { throw IntentError.noResponseAvailable }
        return .result(value: markdown)
    }
}
```

### `App/GeminiDesktopApp.swift` additions

Register dependencies so `@Dependency` resolution works:
```swift
// In GeminiDesktopApp body or init:
AppDependencyManager.shared.add(dependency: coordinator)
AppDependencyManager.shared.add(dependency: coordinator.promptLibrary)
```

> **OS requirement:** `AppDependencyManager` requires macOS 14+. This project targets macOS 15.0 (`MACOSX_DEPLOYMENT_TARGET = 15.0`), so this is safe. If the deployment target is ever lowered to macOS 13, replace `@Dependency` + `AppDependencyManager` with a custom singleton or static accessor pattern.

Call `updateAppShortcutsParameters()` when the library reloads (in `PromptLibrary.reload()`) to keep Spotlight index current:
```swift
// Inside PromptLibrary.reload(), after allFiles is updated:
InjectPromptIntent.updateAppShortcutsParameters()
```

---

## Xcode Project
Add `Prompts/` group (5 files) + `Intents/` group (4 files) + 2 new view files to `GeminiDesktop` target in `project.pbxproj`. Handled via Xcode GUI when adding files (drag into project navigator).

---

## Key Reused Infrastructure
| Utility | File | How used |
|---------|------|----------|
| `BookmarkStore.withBookmarkedURL<T>(for:_:)` | `Utils/BookmarkStore.swift` | Directory reading in `PromptLibrary.reload()` and artifact saving |
| `BookmarkStore.resolveBookmark(for:)` | same | Directory label display in Settings |
| `BookmarkStore.saveBookmark(for:key:)` | same | NSOpenPanel result saved in Settings |
| `GeminiSelectors.shared` | `WebKit/GeminiSelectors.swift` | Selector strings for injection + capture JS |
| `UserScripts` enum pattern | `WebKit/UserScripts.swift` | `createInjectionScript` and `createCaptureScript` follow same static func + string interpolation pattern |
| `evaluateJavaScript(_:completionHandler:)` pattern | `WebKit/WebViewModel.swift:94` | completion handler style (not async) |
| NSOpenPanel `.begin { }` pattern | `WebKit/GeminiWebView.swift:126-134` | Directory picker in Settings |

---

## Verification

**Build:** `xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build` — 0 errors after each phase.

**Functional:**
- [ ] Directory picker saves bookmark; label persists across relaunch
- [ ] Adding a `.md` file to prompts dir updates the menu (FSEvents fires within ~500ms)
- [ ] Prompt with YAML `title`/`description` shows two-line menu item
- [ ] Prompt without frontmatter falls back to filename as title; no description line
- [ ] Empty subdirectory not shown; non-empty subdirectory appears as submenu
- [ ] `⚠️` badge on warning patterns; `🚫` badge + NSAlert on danger patterns
- [ ] "Cancel" in NSAlert aborts; "Use Anyway" proceeds
- [ ] Copy mode: `NSPasteboard.general` contains body (no frontmatter)
- [ ] Inject mode: text appears in Gemini textarea; `isInjecting` disables menu while in-flight
- [ ] Prompt > 16,000 chars shows error banner — injection aborted, text NOT modified
- [ ] Prompt with malformed YAML frontmatter shows `⚠️ (YAML Error)` prefix in menu title; description line absent
- [ ] Capture button shows sheet with timestamp-based default filename (e.g. `Gemini-20260316T1813.md`)
- [ ] Saved `.md` appears in artifacts dir; consecutive captures produce distinct timestamp filenames
- [ ] Captured file has YAML header; captured text already starting with `---` does NOT get double header
- [ ] Filename collision fallback: `-1`, `-2` suffix appended (only when two captures within same second)
- [ ] `injectionBannerMessage` banner appears when Gemini not loaded; dismisses on X
- [ ] Settings window accommodates new section (increase `settingsWindowDefaultHeight` in `GeminiDesktopApp.swift` from 600 → 750 if needed)
- [ ] Spotlight (`Cmd+Space`) surfaces prompt library entries by title and tags
- [ ] Selecting a prompt in Spotlight copies body to clipboard (default action)
- [ ] Shortcuts app shows `InjectPromptIntent` and `CaptureLastArtifactIntent` under Gemini Desktop
- [ ] `InjectPromptIntent` brings app to foreground and injects combined text
- [ ] Cold boot: Intent triggered while app is launching waits for page ready (up to 30s); succeeds once Gemini loads
- [ ] Cold boot timeout (page never loads): Intent throws `notAuthenticated` with descriptive message in Shortcuts
- [ ] `InjectPromptIntent` with prompt > 16,000 chars throws `promptTooLong` to Shortcuts — no truncation
- [ ] `.danger` prompt in `InjectPromptIntent` immediately throws `dangerPatternDetected` to Shortcuts — no hanging modal
- [ ] `CaptureLastArtifactIntent` returns Markdown string to Shortcuts caller
- [ ] `CaptureLastArtifactIntent` throws `noResponseAvailable` when no response in DOM
- [ ] `AppDependencyManager` resolves `AppCoordinator` and `PromptLibrary` in both intents
- [ ] `updateAppShortcutsParameters()` called after each `PromptLibrary.reload()`; Spotlight index updates within seconds
