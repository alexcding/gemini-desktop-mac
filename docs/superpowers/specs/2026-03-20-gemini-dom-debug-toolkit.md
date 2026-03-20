# Gemini DOM Debug Toolkit — Problem Statement

## Background

Gemini Desktop extracts metadata from the Gemini web page via JavaScript injected into WKWebView. These selectors are fragile: Gemini is a Google-controlled Angular app that changes its DOM without notice. When selectors break, metadata silently goes missing — the save sheet shows only `captured`, with no indication that anything failed.

## What We Verified (2026-03-20)

We debugged the metadata script live via Web Inspector on a real conversation. Findings:

| Field | Old Selector | Status | Working Selector |
|---|---|---|---|
| `conversation_id` | URL regex `/app/([a-zA-Z0-9_-]+)` | ✅ Working | (unchanged) |
| `conversation_url` | `window.location.href` | ✅ Working | (unchanged) |
| `conversation_title` | `document.title` | ❌ Returns `"Google Gemini"` | `a.conversation.selected` |
| `gemini_model` | `[data-test-id="model-switcher-button"]`, `.model-switcher-button`, `[jsname][aria-label*="Gemini"]` | ❌ All miss | `[data-test-id="bard-mode-menu-button"]` |
| `response_index` | `response-container` count | Unverified | — |
| `request` | `user-query .query-text` | Unverified | — |
| `attachments` | `.attachment-chip .attachment-name` | Unverified | — |

Both broken selectors were fixed in commit `56e72c2`.

The `model` value returned is the *mode* name (e.g. `"Pro"`, `"Flash"`) not the full versioned model string (e.g. `"Gemini 2.0 Flash"`). The full version string may not be exposed in the DOM at all.

## Problem Statement

**Selector rot is inevitable and currently invisible.**

Gemini's DOM is unversioned, undocumented, and changes without notice. Every metadata field is a fragile pointer into Google's internals. The current workflow for detecting and fixing breakage is:

1. User notices the save sheet shows only `captured`
2. Developer opens Web Inspector manually
3. Developer runs ad-hoc console queries to rediscover correct selectors
4. Developer updates the hardcoded JS string in `UserScripts.swift`
5. Rebuild and ship

This is slow, requires developer involvement for every Gemini DOM change, and provides no signal to users that data is missing.

## What a Debug Toolkit Should Solve

1. **Selector health check** — run all metadata selectors and report which hit / which miss, without needing the developer to be present
2. **Output visibility** — show raw extraction results so a user can copy/paste them into a bug report
3. **Low friction** — accessible without Xcode or Web Inspector knowledge
4. **No permanent UI cost** — should not add UI complexity for non-developer users

## Out of Scope (for now)

- Auto-healing selectors (fragile, unpredictable)
- Shipping a "DOM explorer" to end users
- Versioned selector tables / fallback chains (over-engineering until selector rot frequency is known)
