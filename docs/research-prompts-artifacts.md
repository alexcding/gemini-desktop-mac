# Research: Prompts & Artifacts Feature

**Scope:** Toolbar widgets, prompt library, YAML schema, injection security, WebView injection, artifact capture

---

## 1. Toolbar Architecture

### Current State
The toolbar is pure SwiftUI `.toolbar {}` — no AppKit `NSToolbar`. Three items exist:

| Placement | Item | File |
|-----------|------|------|
| `.navigation` | Back button (`coordinator.canGoBack`) | `MainWindowView.swift:30-39` |
| `.principal` | `Spacer()` | `MainWindowView.swift:41-43` |
| `.primaryAction` | Minimize to Prompt button | `MainWindowView.swift:45-52` |

### Adding Dropdown Menus
SwiftUI `Menu {}` inside a `ToolbarItem` works natively — macOS renders it as a toolbar button with a disclosure arrow. The clickable area activates the dropdown with no extra affordance needed:

```swift
ToolbarItem(placement: .primaryAction) {
    Menu {
        ForEach(prompts) { prompt in
            Button(prompt.title) { ... }
        }
    } label: {
        Label("Prompts", systemImage: "doc.text")
    }
}
```

### Placement Strategy
To add buttons *to the left* of the existing Minimize button, use additional `.primaryAction` items (macOS stacks them right-to-left in that zone) or use explicit placement order. Multiple `.primaryAction` items are ordered by declaration order in the `toolbar` block. New items declared **before** the existing Minimize button will appear to its left.

---

## 2. Existing Infrastructure

**Already in place — no re-implementation needed:**

- `BookmarkStore.swift` — full security-scoped bookmark system with `withBookmarkedURL` wrapper
- `UserDefaultsKeys.promptsDirectoryBookmark` — key defined, unused
- `UserDefaultsKeys.artifactsDirectoryBookmark` — key defined, unused
- `NSOpenPanel` wiring already exists in `GeminiWebView.swift` for file picking

The prompts directory picker in Settings will save to `promptsDirectoryBookmark`. The artifacts directory picker saves to `artifactsDirectoryBookmark`. Reading files goes through `bookmarkStore.withBookmarkedURL(for: .promptsDirectoryBookmark)`.

---

## 3. YAML Frontmatter Schema

### Survey of Existing Tools
No ratified standard exists for AI prompt YAML frontmatter as of 2025. Key tools surveyed:

- **Fabric** — no YAML; plain Markdown only
- **GPT Runner** — JSON-in-frontmatter; no description/tags/author fields
- **LangChain Hub** — structured objects with `name`, `description`, `tags`, `input_variables`, `template_format`; no file-based standard
- **PromptFlow** — YAML DAGs, not per-prompt files
- **Jekyll convention** — `title`, `description`, `date`, `tags`, `author`; most widely culturally adopted

### Recommended Schema

**Required:**
```yaml
---
title: "Structured Code Review"
description: "Reviews code for readability and SOLID principles. Outputs structured feedback with severity ratings."
tags: [code-review, engineering]
---
```

**Optional fields (all have clear purpose):**
```yaml
---
title: "Structured Code Review"
description: "Reviews code for readability and SOLID principles."
tags: [code-review, engineering]
category: "Engineering"          # one per prompt — tree navigation node
version: "1.2.0"                 # SemVer — prompt iteration tracking
author: "zmarkley"
created: 2025-01-15              # ISO 8601 — enables sort by date
updated: 2025-03-10
model: "gemini-2.0-flash"        # optional model override
temperature: 0.3                 # optional inference override
input_vars: [code_snippet, lang] # named slots for future template substitution
output_format: "markdown"        # expected output type
---
```

**Design decisions:**
- `description` is required because it drives the hover tooltip — the primary UX affordance in the dropdown. Plain text only (no Markdown in this field), soft limit 280 chars for legible tooltips.
- `category` (one per prompt) is separate from `tags` (many per prompt): category = tree path, tags = cross-cutting filter.
- `input_vars` is optional now but enables future "fill in the blanks" parameterized prompts without schema change.

### Swift Parsing
Use `Yams` (https://github.com/jpsim/Yams) — the standard Swift YAML library. Parse frontmatter delimited by `---` lines. Required fields should produce a non-nil `PromptMetadata` struct or a parse error displayed in the UI (badge on the prompt row).

```swift
// Rough shape
struct PromptMetadata: Codable {
    let title: String
    let description: String
    let tags: [String]
    var category: String?
    var version: String?
    var model: String?
    var inputVars: [String]?
    // ...

    enum CodingKeys: String, CodingKey {
        case title, description, tags, category, version, model
        case inputVars = "input_vars"
    }
}
```

---

## 4. Prompt Injection Security

### Threat Model
**Attack vector:** A malicious `.md` file in the user's prompts directory (via shared folder, git clone, downloaded prompt pack). Clicking it injects the payload into Gemini.

**Realistic harms:**
1. Instruction override — malicious content appended to a legitimate-looking prompt that overrides Gemini's persona/constraints
2. Exfiltration via user action — Gemini instructed to tell the user to copy/paste data to an attacker URL
3. Prompt leakage — extracting prior conversation history

**This is NOT code execution on the host machine.** The sandbox prevents that. The severity is lower than agentic LLM injection but non-trivial if the user trusts the output.

### Critical UI Rule — Never Auto-Block
The security layer is strictly advisory. The user must always retain control via a **one-click override**. The tool must never quarantine, hide, or auto-reject files. If a pattern matches:
- `.warning` → yellow badge on the prompt row; injection proceeds normally unless user reads the badge and chooses to abort.
- `.danger` → red badge + confirmation modal before inject (matched rule names + flagged excerpt shown). "Use Anyway" and "Cancel" both available.

This is especially important because prompts *about* prompt engineering or educational jailbreak examples will legitimately trigger these patterns. The scanner's job is to surface information, not make decisions.

### Tier 1 — Regex/Pattern Matching (Always Available)
Run on every file at directory load time and on file changes. Never block the main thread.

**Instruction Override:**
- `ignore (all |prior )?previous instructions`
- `disregard (all )?previous`
- `forget everything above`
- `your new instructions are`
- `override system prompt`

**Persona/Role Replacement:**
- `you are now` (followed by alternate identity)
- `act as [DAN|STAN|DUDE|AIM|jailbroken|unrestricted]`
- `you are (going to act|free from|no longer bound)`
- `pretend you have no restrictions`

**DAN/Dual-Response Format:**
- `[🔒CLASSIC]` / `[🔓JAILBREAK]`
- `developer mode enabled`
- `maintenance mode` / `admin override`

**Exfiltration Patterns:**
- `(print|repeat|output|reveal) (your |the )?(system prompt|full conversation|instructions)`
- `what were you told`

**Encoding Red Flags:**
- Base64 blocks >40 chars: `[A-Za-z0-9+/]{40,}={0,2}`
- Dense hex sequences: `(\\x[0-9a-fA-F]{2}){5,}`
- Markdown comments with text: `<!--.*?(ignore|override|instructions).*?-->`

**Result enum:** `.clean` / `.warning` (ambiguous match) / `.danger` (high-confidence match). Badge the prompt row. Never auto-block — the user always has a one-click override (see UI rule above).

### Tier 2 — Apple Foundation Models API (Supplementary, Capable Hardware Only)
The `FoundationModels` framework (macOS 15+, WWDC 2025) provides `LanguageModelSession` backed by Apple's on-device 3B model. Private, no network.

```swift
import FoundationModels

guard SystemLanguageModel.default.isAvailable else { /* skip */ }
let session = LanguageModelSession()
// Use structured output (@Generable) to classify:
// is this content: instruction-override / jailbreak / exfiltration / clean
```

**Limitations:**
- Requires Apple Intelligence hardware (M-series Mac, macOS 15+)
- Must check `SystemLanguageModel.default.isAvailable` — not universal
- No dedicated safety classifier adapter; requires prompt-engineering the classification
- A sufficiently obfuscated injection may fool the 3B model
- Use as secondary layer on top of regex, not as replacement

**Verdict:** Implement regex as the primary control. Offer Foundation Models as an opt-in "deep scan" setting, shown only when the hardware supports it.

### Tier 3 — Procedural Controls
- **Show last-modified date** on every prompt row — helps users spot unexpectedly changed files
- **Visual diff for changed prompts** — if a prompt changes on disk after load, show a diff before allowing injection
- **Character limit on injection**: cap at 16,000 characters to prevent large encoded payloads
- **Clipboard path as a softer option**: copying to clipboard gives the user an extra decision point before the text reaches Gemini
- **Sandboxed file access**: `BookmarkStore` limits which directories are readable — weak mitigation (content inside the authorized directory is still trusted), but prevents path traversal

### Recommendation for the Warning UI
- `.warning` → yellow shield badge; user can inject without any modal
- `.danger` → red shield badge + modal before inject (rule names + flagged excerpt); "Use Anyway" and "Cancel" available
- No auto-quarantine, no hidden files — the user always sees every prompt in the directory

---

## 5. WebView Text Injection

### App-Bound Domains — Not Required
`WKAppBoundDomains` is an **opt-in privacy feature**, not a prerequisite for `evaluateJavaScript`. It was introduced in iOS 14/macOS 11 to let apps voluntarily restrict their WebView to specific domains (preventing third-party SDKs from navigating away or injecting scripts). It is not a security gate on `evaluateJavaScript` itself.

A standard `WKWebView` without any App-Bound Domain configuration can call `evaluateJavaScript` against any page it has loaded — including `gemini.google.com`. The existing `WKUserScript` injection (conversation observer, IME fix) already proves this works without it.

**When you would add it:** Only if you want to lock the WebView to Gemini-related domains for compliance/privacy reasons (preventing malicious redirects from executing scripts in a different origin). For this app, the risk of that attack is low. Test injection without it first.

```xml
<!-- Only add this if you decide to lock down navigation — NOT required for evaluateJavaScript -->
<key>WKAppBoundDomains</key>
<array>
    <string>gemini.google.com</string>
    <string>accounts.google.com</string>
</array>
```

### Framework Note — Gemini Uses Angular, Not React
Gemini's web app is built on Angular with Zone.js event patching. This means:
- Standard `new Event('input', { bubbles: true })` dispatches **are picked up** by Angular's change detection
- The React `_valueTracker` hack is **not needed**
- Angular is more tolerant of synthetic events than React

### Injection Strategy

Gemini's input is a `rich-textarea` custom web component with a shadow DOM. The editable surface inside is a `div[contenteditable="true"]` (ProseMirror-style rich text, not a plain `<textarea>`).

```javascript
// Full injection script — to be delivered via evaluateJavaScript
// NOTE: escape `text` in Swift before interpolating into this string
(function injectPrompt(text) {
    // Auth state guard: only inject on the Gemini app page, not login screens.
    // rich-textarea is absent on login pages; this check handles both cases.
    const richTextarea = document.querySelector('rich-textarea');
    if (!richTextarea) {
        // Likely on login page or unsupported Gemini sub-page.
        const isLoginPage = window.location.hostname.includes('accounts.google.com')
            || !window.location.pathname.startsWith('/app');
        return {
            error: isLoginPage
                ? 'not-authenticated'   // Swift side shows "Sign in to Gemini first"
                : 'rich-textarea not found'
        };
    }

    const shadow = richTextarea.shadowRoot;
    if (!shadow) return { error: 'shadow root inaccessible' };

    const editor = shadow.querySelector('[contenteditable="true"]');
    if (!editor) return { error: 'contenteditable not found' };

    editor.focus();
    editor.textContent = '';

    // Primary: execCommand — deprecated in web standards but currently functional
    // in WKWebView and correctly triggers Angular's undo stack.
    let inserted = document.execCommand('insertText', false, text);

    // Fallback: DataTransfer + InputEvent dispatch (for when execCommand is removed).
    // Angular's Zone.js picks up standard InputEvent dispatches.
    if (!inserted) {
        const dt = new DataTransfer();
        dt.setData('text/plain', text);
        editor.dispatchEvent(new InputEvent('beforeinput', {
            inputType: 'insertText',
            data: text,
            bubbles: true,
            cancelable: true,
            dataTransfer: dt
        }));
        editor.textContent = text;
        editor.dispatchEvent(new InputEvent('input', {
            inputType: 'insertText',
            data: text,
            bubbles: true
        }));
    }

    // Click submit — most reliable path through Angular's event pipeline.
    const sendBtn = document.querySelector(
        'button[aria-label="Send message"], button[aria-label="Send"]'
    );
    if (sendBtn && !sendBtn.disabled) {
        sendBtn.click();
        return { success: true };
    }
    return { success: true, warning: 'send button not found; text inserted only' };
})
```

**Auth state handling in Swift:** When the script returns `{ error: 'not-authenticated' }`, show a non-modal notification (e.g., a brief banner): *"Sign in to Gemini first, then try again."* Do not show a blocking alert.

**Swift-side text escaping before interpolation (security-critical):**
```swift
// Prevent the prompt content from breaking out of the JS string literal
func escapeForJavaScript(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "</", with: "<\\/")
}
```

Failure to escape is a secondary injection vulnerability where prompt content breaks out of the JS string literal and executes arbitrary JavaScript in the web view.

### Copy Mode (Alternative)
For "copy to clipboard" mode: `NSPasteboard.general.setString(contents, forType: .string)`. The user manually pastes into Gemini. Simpler, safer, no JS dependency. Appropriate as the default setting.

### Selector Fragility
`rich-textarea`, shadow DOM depth, and `button[aria-label="Send message"]` are all brittle — a Gemini deploy can break them. Extract these into `gemini-selectors.json` (already planned/implemented in Phase 4 of ChatBar fixes) and add injection-specific selectors to that file.

---

## 6. Artifact Capture

### DOM Structure
Gemini renders each model response into an Angular component. The most consistent selector is positional:

```javascript
// Last model response — positional, resilient to name changes
const responses = document.querySelectorAll('model-response');
const lastResponse = responses[responses.length - 1];
```

### V1 Requirement: DOM-to-Markdown Conversion
`innerText` alone is a UX dead-end for artifacts. It destroys code blocks, bold text, tables, and lists. A user who asks Gemini to write a Python script and saves it with `innerText` gets unindented flat text — the artifact is immediately unusable.

DOM-to-Markdown conversion is a **V1 requirement**, not a future enhancement. The conversion logic is a small, focused script (~50 lines) that maps the HTML Gemini actually renders into Markdown equivalents — no third-party library needed:

```javascript
function domToMarkdown(el) {
    function convert(node) {
        if (node.nodeType === Node.TEXT_NODE) return node.textContent;
        const tag = node.tagName?.toLowerCase();
        const children = Array.from(node.childNodes).map(convert).join('');

        switch (tag) {
            case 'p':    return children + '\n\n';
            case 'br':   return '\n';
            case 'strong': case 'b': return `**${children}**`;
            case 'em':   case 'i':   return `*${children}*`;
            case 'code': return node.closest('pre') ? children : `\`${children}\``;
            case 'pre':  return `\`\`\`\n${node.innerText}\n\`\`\`\n\n`;
            case 'h1':   return `# ${children}\n\n`;
            case 'h2':   return `## ${children}\n\n`;
            case 'h3':   return `### ${children}\n\n`;
            case 'ul':   return Array.from(node.children).map(li =>
                             `- ${convert(li).trim()}`).join('\n') + '\n\n';
            case 'ol':   return Array.from(node.children).map((li, i) =>
                             `${i+1}. ${convert(li).trim()}`).join('\n') + '\n\n';
            case 'li':   return children;
            case 'a':    return `[${children}](${node.href})`;
            case 'table': return convertTable(node);
            default:     return children;
        }
    }

    function convertTable(table) {
        const rows = Array.from(table.querySelectorAll('tr'));
        if (!rows.length) return '';
        const header = Array.from(rows[0].cells).map(c => c.innerText.trim());
        const sep = header.map(() => '---');
        const body = rows.slice(1).map(r =>
            Array.from(r.cells).map(c => c.innerText.trim()).join(' | '));
        return [header, sep, ...body].map(r => '| ' + r.join(' | ') + ' |').join('\n') + '\n\n';
    }

    return convert(el).replace(/\n{3,}/g, '\n\n').trim();
}

const responses = document.querySelectorAll('model-response');
const last = responses[responses.length - 1];
const markdown = last ? domToMarkdown(last) : null;
```

This handles the common cases Gemini produces: paragraphs, code blocks, bold/italic, numbered/bulleted lists, headings, tables, and links. For edge cases (nested lists, complex tables), the output degrades gracefully to readable text.

### Streaming Detection
Gemini streams responses. `evaluateJavaScript` called immediately after send will capture a partial or empty response. Use a `MutationObserver` in a `WKUserScript` to detect completion:

```javascript
// Injected at documentEnd via WKUserScript
// Listens for "stop generating" button disappearing (response complete)
let debounceTimer = null;
const captureObserver = new MutationObserver(() => {
    const isStreaming = !!document.querySelector(
        'button[aria-label="Stop generating"]'
    );
    if (!isStreaming) {
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(() => {
            const responses = document.querySelectorAll('model-response');
            const text = responses[responses.length - 1]?.innerText;
            if (text) {
                window.webkit.messageHandlers.artifactCapture.postMessage(text);
            }
        }, 1500); // 1.5s quiescence — wait for any final chunks
    }
});
captureObserver.observe(document.body, { childList: true, subtree: true });
```

This observer would be activated on-demand (not always running). The Swift side registers as `WKScriptMessageHandler` for `"artifactCapture"`.

**Alternative approach (simpler):** A "Capture Last Response" toolbar button triggers `evaluateJavaScript` immediately — the user is responsible for clicking after streaming completes. Lower engineering complexity; acceptable UX given the save dialog that follows.

### Save Flow
1. User clicks "Capture Response" toolbar button
2. Swift checks: is `window.location.pathname.startsWith('/app')`? If not, show "Sign in to Gemini first."
3. Check if streaming is complete (`document.querySelector('button[aria-label="Stop generating"]')` is null)
4. If streaming, show toast: "Wait for response to finish generating"
5. If complete, evaluate `domToMarkdown` capture script, receive Markdown string
6. Swift enforces a character limit before passing to `evaluateJavaScript` — if the response exceeds ~100,000 chars, show a warning: "Response is very large — capture may be truncated."
7. Show `NSPanel` (similar to ChatBarPanel) or `NSAlert` with name `TextField` + Save/Cancel
8. On Save: `bookmarkStore.withBookmarkedURL(for: .artifactsDirectoryBookmark) { url in ... }` write `name.md` to dir
9. Content format: Markdown from `domToMarkdown`. Prepend `---\ncaptured: ISO_DATE\nsource: gemini\n---\n\n` frontmatter.

---

## 7. V1 Decisions (Closed)

Decisions made during planning — these are no longer open questions:

| Question | Decision | Rationale |
|----------|----------|-----------|
| Default mode: copy or inject? | Copy as default; inject as opt-in in Settings | Safer default; inject available for power users |
| YAML parser library | `Yams` v5.1.3+ | Well-maintained; handles all edge cases |
| Artifact format | `domToMarkdown` inline JS script | V1 requirement — `innerText` destroys code blocks and tables |
| Prompt character limit (inject) | Truncate at 16,000 chars Swift-side (no modal) | Prevents large encoded payloads; silent truncation acceptable |
| Artifact capture size limit | Warning at ~100,000 chars; hard cap at 200,000 | Large Gemini responses are rare but plausible |
| Security scan: Foundation Models | **Dropped from V1** | 1GB+ binary bloat, memory pressure, hardware fragmentation; Tier-1 regex is sufficient |
| Streaming detection method | **User-initiated for V1** | Simplest; acceptable UX given the save dialog; MutationObserver deferred to V2 |
| File watcher for prompt directory | **FSEvents C-API** (`FSEventStreamRef`) | More reliable than `DispatchSource` for directory trees; handles recursive changes |
| Hover tooltip | Two-line `Button` label (title + `.caption .secondary` description) | `.help()` can't show rich text in menus; inline label is the only option in `Menu {}` |
| Selector updates | Extracted to `gemini-selectors.json` | Already implemented in Phase 0; selectors are data, not code |

---

## 8. App Intents Architecture

App Intents expose the prompt library and capture pipeline to macOS Spotlight, Shortcuts, and Siri — without adding any AI agent or background service.

### Key Types

**`PromptAppEntity`** (`AppEntity`)
- Properties: `id: String`, `title: String`, `description: String`, `tags: [String]`
- Backed by `PromptLibrary.allFiles`; `PromptLibrary` caches parsed `PromptFile` objects, so `EntityQuery` reads from an in-memory array (instantaneous)
- `defaultQuery`: `PromptEntityQuery` — `suggestedEntities()` returns full library; `entities(matching:)` filters by title/tags

**`InjectPromptIntent`** (`AppIntent`)
- Parameters: `prompt: PromptAppEntity`, `text: String` (optional additional context to append)
- Behavior: brings app to foreground, combines `prompt.body + text` (if any), runs Tier-1 scanner, injects via existing `AppCoordinator.injectPrompt`
- Error handling: throws `IntentError.notAuthenticated` (Gemini not loaded) or `IntentError.dangerPatternDetected` (requires visual confirmation; intent suspends until user confirms in app UI)
- `.danger` flow: post a `NSAlert` on `@MainActor`, await user response, then resume or cancel intent

**`CaptureLastArtifactIntent`** (`AppIntent`)
- No parameters
- Returns `String` (the Markdown text) — caller's Shortcut decides what to do with it (write to Obsidian, Git commit, Notion API, etc.)
- Brings app to foreground; evaluates `createCaptureScript` via `WebViewModel.evaluateJavaScript`
- Returns empty string and throws `IntentError.noResponseAvailable` if `model-response` not found

### Caching Strategy
`PromptLibrary` is already `@Observable` and holds `allFiles: [PromptFile]` in memory. The `EntityQuery` reads directly from this array — no additional disk I/O at query time. `PromptDirectoryWatcher` invalidates the cache on FSEvents, triggering `reload()` which re-builds `allFiles`. Spotlight re-indexes when `PromptLibrary` calls `updateAppShortcutsParameters()` after each reload.

### Constraints
- **No background agents:** Intents execute deterministic Swift code only. No SLM, no LLM, no async AI calls.
- **Security layer preserved:** `InjectPromptIntent` runs `PromptScanner.scan()` before calling any injection. `.danger` result suspends the intent and requires `@MainActor` confirmation.
- **App must be running:** App Intents with `openAppWhenRun: false` only work if the app is already in memory. For foreground-required intents (injection, capture), set `openAppWhenRun: true`.

---

## 9. Edge-to-Edge UI & macOS Notch Integration

*Note: `docs/research-edge-to-edge-ui.md` and `docs/plan-edge-to-edge-ui.md` were deleted after their content was merged here and into `plan-prompts-artifacts.md` (Phase 0.4 + Phase 5 ZStack architecture).*

### Current State (Before This Feature)

The app already has the first half of edge-to-edge setup in place:

| Setting | Where | Effect |
|---------|-------|--------|
| `titlebarAppearsTransparent = true` | `MainWindowView.setupWindowAppearance` | Toolbar area becomes transparent; shows `window.backgroundColor` through it |
| `titleVisibility = .hidden` | same | Hides window title string |
| `.windowToolbarStyle(.unified(showsTitle: false))` | `GeminiDesktopApp` Scene | Single slim bar |
| `.toolbarBackground(geminiGreen, for: .windowToolbar)` | `GeminiDesktopApp` Scene | Toolbar layer color |
| `window.backgroundColor = geminiGreen` | `MainWindowView.applyColor` | Color shown through transparent title bar |

**What's missing:** The WebView frame is constrained to the SwiftUI safe area — the region below the toolbar. There is always a visible solid-color strip between the toolbar and the web content. This becomes obvious when: the page background is white (login screens, non-Gemini pages); the window is resized; or light/dark mode switches mid-session.

### The Approach: ZStack Architecture (No `fullSizeContentView`)

> **UI shell review finding (2026-03-16):** `fullSizeContentView` was prototyped and caused the toolbar bottom edge to inflate by the menu bar height (~24pt). Root cause: AppKit computes the toolbar's visual extent using the window's screen-relative Y offset when `fullSizeContentView` is set, which adds the menu bar height (~24pt) to the toolbar's reported height. No writable API exists to correct this (`contentLayoutRect` is get-only). `fullSizeContentView` is therefore dropped from the implementation.
>
> `fullSizeContentView` is also unnecessary for this app — see "Material Blur vs Solid Color" section below.

The implementation uses a `ZStack` root view for a different reason: the injection banner overlay. Without `ZStack`, a `.overlay(alignment: .top)` on `GeminiWebView` would work — but Phase 5 adds `.ignoresSafeArea` to the WebView for other layout reasons. A `.overlay(alignment: .top)` on a full-bleed view anchors to the window top — behind toolbar buttons. The ZStack fix:
- `GeminiWebView` fills the content area (no `ignoresSafeArea` — toolbar height inflation is avoided)
- The injection banner is a ZStack sibling — lives in the same coordinate space, naturally below the toolbar

All view modifiers (`.background(WindowAccessor)`, `.onAppear`, `.onChange`, `.toolbar`) attach to the ZStack.

### MacBook Notch

MacBook Pro 2021+ has a hardware camera notch in the display. In **windowed mode**, all app windows sit below the menu bar — the notch is never inside the app frame. No handling required.

In **full screen**, the window fills the entire screen. macOS reports `NSWindow.safeAreaInsets.top > 0` to reflect the notch height. SwiftUI automatically respects this via the environment's `safeAreaInsets` — toolbar items don't collide with the notch. Background content using `.ignoresSafeArea(.all, edges: .top)` bleeds behind the notch cutout naturally (the pixels there aren't displayed anyway). No code change needed.

### Material Blur vs. Solid Color

**Decision: solid color bleed.** The Gemini green theming is intentional and branded; it already matches Gemini's own web UI header color. The `window.backgroundColor` prevents a white flash in the toolbar area during page load. `NSVisualEffectView` material blur would fight against the `useCustomToolbarColor` setting by layering a secondary visual treatment over a user-chosen color. Material blur is more complex to get right across light/dark mode.

### `WKWebView.underPageBackgroundColor`

`WKWebView` shows `underPageBackgroundColor` when the user over-scrolls (bounce). It defaults to the system background (white/dark gray). With a transparent toolbar and full-bleed layout, a bounce at the top reveals this color through the toolbar. Setting it to `GeminiDesktopApp.Constants.toolbarColor` (the adaptive Gemini green NSColor) eliminates the artifact. API available macOS 12.3+; guard with `#available`.

### Traffic Lights and Full Screen

Traffic light buttons (close/minimize/zoom) are anchored by macOS to the title bar area independently of the content view frame — no repositioning needed with `fullSizeContentView`. In full screen, `titlebarAppearsTransparent` is overridden by the system; the auto-hiding toolbar becomes opaque. This is correct macOS behavior; no change needed.

---

## 10. Dependency Summary

| Dependency | Purpose | Status |
|-----------|---------|--------|
| `Yams` v5.1.3+ Swift package | YAML frontmatter parsing | **Not yet added** — needs SPM entry |
| `AppIntents` framework | Spotlight / Shortcuts / Siri integration | ✅ Built into macOS 13+ SDK — no addition needed |
| `BookmarkStore.swift` | Directory access | ✅ Already implemented |
| `promptsDirectoryBookmark` key | UserDefaults key for prompts dir | ✅ Already defined |
| `artifactsDirectoryBookmark` key | UserDefaults key for artifacts dir | ✅ Already defined |
| `gemini-selectors.json` | Injection/capture DOM selectors | ✅ Already implemented (Phase 0) |
| `WKAppBoundDomains` in Info.plist | Optional — only if navigation lockdown is desired | Not required for `evaluateJavaScript` |
| `FoundationModels` framework | Deep prompt scan | **Dropped from V1** — deferred indefinitely |
| `NSWindowStyleMask.fullSizeContentView` | Edge-to-edge layout | Built-in AppKit — no addition needed |
