# Selector Patchability & Debug Capture — Design Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users apply selector fixes without rebuilding the app, and give developers a one-click debug capture to diagnose broken selectors quickly.

**Architecture:** Two independent but related features. Feature A makes `GeminiSelectors` user-patchable at runtime. Feature B adds an opt-in debug dump tool that captures Gemini page state to a file.

**Tech Stack:** Swift, SwiftUI, WKWebView JS injection, macOS Application Support directory, NSMenu

---

## Background

`GeminiSelectors` already loads from a bundled JSON file, but:
1. The bundle is not user-writable — users cannot apply fixes without rebuilding.
2. Metadata selectors (title, model, request, attachments, streaming indicator) are hardcoded in `UserScripts.swift` rather than in `GeminiSelectors`.

When Gemini updates its DOM, selectors break silently. The fix workflow today requires developer involvement and a new build. The goal is to reduce that to: developer posts updated JSON to GitHub → user drops file in → relaunch.

A debug capture tool shortens the diagnosis step: instead of guided Web Inspector sessions, the user saves a capture file and shares it.

---

## Feature A: User-Patchable Selectors

### Load Priority

At launch, `GeminiSelectors.shared` checks:
1. `~/Library/Application Support/GeminiDesktop/gemini-selectors.json` — user override
2. Bundle resource `gemini-selectors.json` — authoritative default fallback

If the user file exists but fails to decode, fall back to bundle and log the error. Never crash.

### New Fields

Add to `GeminiSelectors` (struct and bundled JSON):

| Field | Default Value |
|---|---|
| `conversationTitleSelector` | `"a.conversation.selected"` |
| `modelSelector` | `"[data-test-id=\"bard-mode-menu-button\"]"` |
| `modelSelectorFallback` | `"[data-test-id=\"logo-pill-label-container\"]"` |
| `userQuerySelector` | `"user-query .query-text-line"` |
| `attachmentSelector` | `".attachment-chip .attachment-name"` |
| `streamingIndicatorSelector` | `"button.send-button.stop"` |

### Script Updates

`createMetadataScript()` and `createCaptureScript()` accept a `GeminiSelectors` parameter (or read from `GeminiSelectors.shared`) instead of hardcoding selector strings. No behavioural change — only the source of selector strings changes.

### Settings UI

Add one row to the existing Settings view (Prompts & Artifacts section or a new Advanced section):

```
Selectors    Custom (user file)    [Reveal in Finder]
             — or —
             Default (bundled)     [Reveal in Finder]
```

"Reveal in Finder" creates `~/Library/Application Support/GeminiDesktop/` if it doesn't exist, then opens it in Finder. The status label reads "Custom (user file)" if a valid user file was loaded, "Default (bundled)" otherwise.

---

## Feature B: Debug Capture Tool

### Opt-In

Toggle in Settings with label:
> *"Enable debug mode — only needed by developers or when filing a selector bug report."*

Also configurable via terminal:
```bash
defaults write com.daveorzach.geminidesktop DebugModeEnabled -bool true
```

No confirmation dialog. The toggle and warning text together constitute informed consent.

### Debug Menu

When debug mode is on, a **Debug** menu appears in the macOS menu bar:

```
Debug
  Capture All
  ─────────────
  Capture DOM
  Capture WIZ State
  Capture Network
```

The menu does not appear when debug mode is off.

### What Each Capture Collects

**Capture DOM**
- Selector probe: for each field in `GeminiSelectors.shared`, run the selector and record `{ field, selector, found: bool, tag, classes, dataTestId, ariaLabel, textSnippet }`.
- All `[data-test-id]` elements: `{ tag, dataTestId, ariaLabel, text }` for every visible element with a `data-test-id` attribute. This is the primary lookup table for finding replacement selectors.
- `data-ved` structural elements: `{ tag, classes, dataVed, jsaction, jscontroller }`.

**Capture WIZ State**
- `JSON.stringify(window.WIZ_global_data)` — full object.

**Capture Network**
- Contents of the passive batchexecute buffer (last N payloads, default N=20).
- Network capture requires the fetch interceptor to be active. The interceptor is injected as a `WKUserScript` only when debug mode is on. If no payloads have been captured yet (e.g. no prompt was sent since launch), the network section will be an empty array.

**Capture All** — runs all three and merges into one file.

### Output Format

Timestamped JSON saved to:
```
~/Library/Application Support/GeminiDesktop/debug-captures/YYYY-MM-DD-HHmmss.json
```

Top-level structure:
```json
{
  "capturedAt": "ISO8601",
  "appVersion": "0.3.1",
  "url": "https://gemini.google.com/app/...",
  "dom": { ... },
  "wizState": { ... },
  "network": [ ... ]
}
```

Missing sections (e.g. individual captures) are omitted rather than null.

### Confirmation

After save, a banner (reusing the existing `CaptureProgress` banner infrastructure) confirms:
```
Debug capture saved — [Reveal in Finder]
```

Auto-dismisses after 3 seconds.

### Network Interceptor Lifecycle

The fetch interceptor `WKUserScript` is added to the `WKWebView` configuration **only** when debug mode is on. Changing the toggle takes effect on next app launch (WKWebView configuration is immutable after init). A note in Settings: *"Restart the app after enabling debug mode for network capture to work."*

---

## Out of Scope

- Auto-update of `gemini-selectors.json` from GitHub (future feature)
- Editable selectors UI in Settings
- Parsing or interpreting batchexecute payloads
- Sending captures automatically anywhere
