# Plan: Adopting Boris Tane Workflow for Gemini Desktop Mac

**Based on:** `docs/research-boris-tane-workflow.md`
**Project:** Gemini Desktop Mac — SwiftUI/AppKit macOS wrapper for Google Gemini
**Scope:** How to adapt the Tane workflow to Swift/macOS development with Claude Code

---

## Overview

The Tane workflow is language-agnostic in principle but its tactics assume a TypeScript/Node.js environment (typecheck, jsdoc, any types). This plan translates each phase into Swift/macOS equivalents and proposes concrete conventions for this project.

The two active workstreams that need this workflow immediately:
1. **Swift 6 + macOS 15 migration** (audit gap analysis — architectural, non-trivial)
2. **Prompts & Artifacts toolbar feature** (new feature — well-scoped, isolated)

---

## Workflow Phases — Swift/macOS Translation

### Phase 1: Research

**Standard research prompt template for this project:**

```
read [folder/file/subsystem] in depth, understand how it works deeply, including all
AppKit/SwiftUI bridging points, memory management, and concurrency assumptions.
when done, write a detailed report of your findings in docs/research-[topic].md
```

**When to use research:**
- Before any change touching `AppCoordinator`, `ChatBarPanel`, or `WebViewModel` — these have non-obvious shared-state constraints
- Before adding any new window, panel, or scene — macOS window lifecycle is complex
- Before any concurrency refactor — Swift 6 actor isolation has sharp edges
- Before the prompts/artifacts feature — the WebView injection pattern needs to be understood before designing the file-reading layer

**Swift-specific depth signals to add to research prompts:**
- `"including actor isolation boundaries"`
- `"including all @MainActor constraints"`
- `"including AppKit/SwiftUI bridging points and memory ownership"`
- `"including all places that touch NSWindow or NSApp directly"`

**Artifact naming convention:**
```
docs/research-[subsystem].md        # e.g. research-window-management.md
docs/research-[feature-name].md     # e.g. research-prompts-toolbar.md
```

---

### Phase 2: Planning

**Standard plan prompt template:**

```
I want to [goal]. write a detailed docs/plan-[feature].md document outlining how
to implement this. include code snippets in Swift. read source files before
suggesting changes. base the plan on the actual codebase.
```

**What the plan must always include for this project:**
- File paths being modified
- New files being created (with rationale)
- Swift types/protocols/actors being introduced
- AppKit components being touched (flag these — they need extra review)
- Entitlement changes (file access, network, camera)
- UserDefaults keys being added or modified
- Any JavaScript injection changes (fragile — Gemini's DOM can change)

**Artifact naming convention:**
```
docs/plan-[feature].md              # e.g. plan-swift6-migration.md
                                    #      plan-prompts-toolbar.md
```

**Reference implementations to keep handy:**
- The existing `WindowAccessor` pattern for any new AppKit bridging
- `UserDefaultsKeys.swift` for any new persistent settings
- `UserScripts.swift` for any new JavaScript injection
- Existing toolbar items in `MainWindowView.swift` for new toolbar additions

---

### Phase 2.5: Annotation Cycle

**Annotation conventions for this project:**

Use `<!-- NOTE: ... -->` HTML comments inline in the plan markdown so they're visible in the raw file and ignored if rendered. Alternatively, use a `**[NOTE]**` bold prefix on a new line directly under the relevant section.

Example plan section with annotations:
```markdown
## Step 3: Add file reading to PromptStore

PromptStore will scan ~/Documents/GeminiPrompts/ on init and refresh on demand.

**[NOTE: use a security-scoped bookmark, not a hardcoded path — user must choose
the directory via NSOpenPanel once and we persist the bookmark data in UserDefaults.
This is required for sandboxing.]**

The store will be @Observable and @MainActor.

**[NOTE: file I/O must happen off main actor — use Task { await actor.load() }
with an isolated async function, not sync reads on the main thread]**
```

**Return prompt (unchanged from Tane):**
```
I added a few notes to the document, address all the notes and update the document
accordingly. don't implement yet
```

**Swift-specific annotation triggers — annotate whenever the plan:**
- Touches `NSApp.windows` directly (prefer coordinator methods)
- Uses `DispatchQueue.main.async` (should be `@MainActor`)
- Introduces a new `@AppStorage` key without adding it to `UserDefaultsKeys`
- Creates a new `NSPanel` or `NSWindow` subclass without noting memory ownership
- Adds JavaScript that hardcodes Gemini DOM selectors (must note fragility)
- Proposes `Timer` (should be `Task` + `AsyncStream` or `WKScriptMessageHandler`)
- Suggests modifying `WKWebViewConfiguration` after the webView is created (not possible)
- Adds file access without noting entitlement requirements

---

### Phase 3: Implementation

**Standard implementation prompt — Swift/macOS version:**

```
implement it all. when you're done with a task or phase, mark it as completed in
the plan document. do not stop until all tasks and phases are completed. do not add
unnecessary comments or docstrings. use strict Swift typing — no Any, no force
unwraps unless already established in the surrounding code. continuously run
`xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build` to verify
no new compiler errors or warnings are introduced.
```

**Key differences from Tane's TypeScript version:**
| Tane (TypeScript) | This project (Swift) |
|---|---|
| `continuously run typecheck` | `xcodebuild ... build` (catches Swift type errors + warnings) |
| `do not use any or unknown types` | `no Any, no force unwraps` |
| `do not add unnecessary jsdocs` | `do not add unnecessary comments or docstrings` |

**Additional Swift-specific implementation guards to include as needed:**
- `"do not introduce new AppKit dependencies without noting them in the plan"`
- `"do not add @MainActor annotations speculatively — only where required by the compiler"`
- `"do not change public function signatures in AppCoordinator or WebViewModel without explicit annotation in the plan"`

---

## Applying the Workflow to Active Workstreams

### Workstream A: Swift 6 + macOS 15 Migration

**Research phase goal:**
Produce `docs/research-swift6-migration.md` covering:
- Every `DispatchQueue.main.async` call and what actor it should be on
- Every `NotificationCenter` observer and whether it can be replaced
- Every KVO observation and its Combine/async equivalent
- All `NSWindow` access patterns and where they need `@MainActor`
- `ChatBarPanel` polling timer and the WKScriptMessageHandler replacement design
- Entitlement requirements for the planned file access feature

**Annotation priorities for plan review:**
- Any proposal to add `@MainActor` globally to a class — verify it doesn't break `GeminiWebView.Coordinator` delegate callbacks that come off main thread
- Any proposal to replace KVO with Combine — verify Combine publishers for WKWebView properties behave identically to the current `NSKeyValueObservation`
- The `ChatBarPanel` polling replacement — the JavaScript MutationObserver + `WKScriptMessageHandler` approach needs careful design; the DOM selector is fragile

**Implementation sequencing (suggested order for plan todo list):**
1. Add `@MainActor` to `AppCoordinator` and `WebViewModel`
2. Replace `DispatchQueue.main.async` with direct calls (now guaranteed on main)
3. Fix `NotificationCenter` observer token storage in `AppCoordinator`
4. Replace `ChatBarPanel` polling with `WKScriptMessageHandler`
5. Replace KVO observers in `WebViewModel` with Combine or async sequences
6. Bump deployment target to macOS 15 in Xcode project
7. Enable Swift 6 strict concurrency checking, fix any remaining errors
8. Add sandbox entitlements

---

### Workstream B: Prompts & Artifacts Toolbar

**Research phase goal:**
Produce `docs/research-prompts-toolbar.md` covering:
- How the existing toolbar items in `MainWindowView.swift` work (SwiftUI `ToolbarItem`, placement, state)
- How `webView.evaluateJavaScript` is currently used (in `ChatBarPanel`, `WebViewModel`) — patterns and limitations
- The Gemini input field DOM structure (what selectors work for setting text content)
- `NSOpenPanel` usage patterns in the existing codebase (`GeminiWebView.swift` file picker)
- Security-scoped bookmark pattern for persistent directory access under sandboxing
- How `@Observable` stores are structured (`WebViewModel`, `AppCoordinator`) to model `PromptStore`

**Annotation priorities for plan review:**
- The JavaScript injection for pasting — setting `contenteditable` div content requires dispatching the right events (React synthetic events, `input` event, not just `innerText =`). Flag any plan section that doesn't account for this.
- Directory picker persistence — must use security-scoped bookmarks or the bookmark is lost on relaunch
- Whether prompts/artifacts share one `PromptStore` with a `kind` enum, or are two separate stores — decide this in annotation before implementation
- Where the directory picker setting lives in SettingsView — needs annotation since it touches existing settings UI

**Implementation sequencing (suggested order for plan todo list):**
1. `PromptStore` model — `@Observable @MainActor`, reads from user-selected directory
2. Settings UI — directory picker for prompts folder, artifacts folder
3. Toolbar button + `Menu` view for prompts
4. Toolbar button + `Menu` view for artifacts
5. JavaScript injection — paste selected content into Gemini input
6. Entitlements — `user-selected.read-only` or `read-write` + security-scoped bookmarks

---

## Session Management Conventions

**Single session per workstream** — don't split research, planning, and implementation across sessions. The context accumulated during research makes annotation faster and implementation more accurate.

**When context window fills during long Swift builds:**
- The plan document is the persistent state — point Claude to `docs/plan-[feature].md` at the start of a resumed session
- Prefix the resume: `"read docs/plan-[feature].md, we are at [phase/task], continue from there"`

**Revert convention:**
```
I reverted everything. Now all I want is [narrow scope]. nothing else.
```
Use `git stash` or `git checkout -- .` before re-issuing scope. This matches Tane's pattern exactly.

---

## File Conventions Summary

```
docs/
  research-boris-tane-workflow.md      # ✅ complete — source material
  plan-adopt-boris-tane-workflow.md    # ✅ this document
  research-[topic].md                  # produced at start of each workstream
  plan-[feature].md                    # produced after research review
```

Plans and research files are **project artifacts**, not throwaway chat context. They should be committed to git alongside code changes so the rationale for architectural decisions is traceable.

---

## Decisions (Resolved)

1. **macOS target** — ✅ **macOS 15.0**. Enables Swift 6 strict concurrency, `defaultWindowPlacement`, and removes legacy workarounds.

2. **Sandbox** — ✅ **Fully sandboxed**. Declare all required entitlements now. Required entitlements: `app-sandbox`, `network.client`, `files.user-selected.read-write` (for prompts/artifacts directory picker), `device.camera`, `device.microphone` (already granted programmatically — must be declared).

3. **Prompts vs Artifacts store** — ✅ **External markdown files**, user-editable outside the app. Two separate default directories (see #5). Feature is deferred until after the Swift 6 / sandbox refactor is complete.

4. **Injection behavior** — ✅ **Copy to clipboard only** (no WebView injection). User pastes manually into Gemini. This eliminates the fragile DOM selector dependency entirely. Deferred to post-refactor feature work.

5. **Default directories** — ✅ `~/Documents/Prompts/` and `~/Documents/Artifacts/`. Created on first launch if they don't exist (requires `files.user-selected.read-write` entitlement + security-scoped bookmark after user selects via `NSOpenPanel`).

6. **File format** — ✅ **`.md` only initially**. Architecture should make adding `.txt` and `.json` trivial (filter extension list). Strip extension when displaying file names in menus..
