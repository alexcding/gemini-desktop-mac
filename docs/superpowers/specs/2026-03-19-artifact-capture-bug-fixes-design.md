# Design: Artifact Capture Bug Fixes

**Date:** 2026-03-19
**Status:** Approved
**Scope:** Two targeted bug fixes in the artifact capture feature

---

## Background

The artifact capture feature (introduced in v0.3.0) has two bugs:

1. The filename input sheet requires the user to type a filename before Save is enabled, even though `defaultArtifactFilename()` already generates a sensible default. Users have no path to accept the default without typing.

2. The streaming detection in `UserScripts.createCaptureScript()` uses `button[aria-label*="Stop"]` as its primary/fallback check. This is localized text — it fails in non-English Gemini locales. Inspection of the live Gemini DOM confirms that the send button receives a `stop` CSS class during streaming, which is structural and language-agnostic.

---

## Bug 1 — Filename Sheet: No Default Pre-fill

### Root Cause

`FilenameInputSheet` initializes `filename` to `""` and disables the Save button when the field is empty (`filename.trimmingCharacters(in: .whitespaces).isEmpty`). `defaultArtifactFilename()` is `private` on `AppCoordinator` and never passed to the sheet.

### Fix

**`Coordinators/AppCoordinator.swift`**
- Remove the `private` modifier from `defaultArtifactFilename()` (Swift `internal` is the default; do not write `internal func` explicitly)

**`Views/ArtifactCaptureButton.swift`**
- When constructing `FilenameInputSheet`, pass `coordinator.defaultArtifactFilename()` as `initialFilename`. This call must happen at sheet-presentation time (inside the `.sheet` closure), not at view initialization, so the timestamp reflects when the sheet opens.
- `defaultArtifactFilename()` returns a full filename including the `.md` extension (e.g. `Gemini-2026-03-19-143022.md`). Pass this value as-is — `performFileIO` uses the filename directly and its collision-deduplication logic already handles extensions correctly.
- Add an `initialFilename: String` parameter to `FilenameInputSheet`. Retain the existing `@Binding var filename: String` — the binding owns the value and drives the Save button and `onSave` callback. `initialFilename` is only used to seed the binding on appear.
- In `FilenameInputSheet.onAppear`: **replace** the existing `filename = ""` with `filename = initialFilename`. Do not add a second `.onAppear` modifier — there must be exactly one, and it sets the binding to the passed default.
- After the pre-fill, select all text so the user can immediately type to override. Use `@FocusState` to give focus to the `TextField` on appear, then trigger select-all via `DispatchQueue.main.async { NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil) }` inside the same `.onAppear`. The async dispatch is required because the field must be focused before `firstResponder` reflects it.
- Update the `TextField` placeholder from `"Filename (without .md extension)"` to `"Filename (e.g. Gemini-2026-03-19-143022.md)"` — since the pre-filled default includes `.md`, the old placeholder is misleading.

### Behavior After Fix

- Sheet opens with the generated default filename pre-filled and selected
- User can press Save immediately to accept the default
- User can start typing to replace the selection with a custom name
- Save button remains disabled only if the user clears the field entirely

---

## Bug 2 — Streaming Detection: Localized aria-label

### Root Cause

`UserScripts.createCaptureScript()` checks:
```javascript
document.querySelector('[data-streaming="true"]')          // never fires — Gemini doesn't use this attribute
|| Array.from(document.querySelectorAll('button[aria-label*="Stop"]')).length > 0  // localized, fails non-English
```

DOM inspection of live Gemini confirms: during streaming, the send button gains the CSS class `stop`, making its full class list include `send-button stop`. This class is removed when streaming ends. The `[data-streaming="true"]` selector is dead code.

### Fix

**`WebKit/UserScripts.swift`** — replace the entire `isStreaming` check:

```javascript
// Before
const isStreaming = document.querySelector('[data-streaming="true"]')
    || Array.from(document.querySelectorAll('button[aria-label*="Stop"]')).length > 0;

// After
const isStreaming = document.querySelector('button.send-button.stop') !== null;
```

Single structural selector. Language-agnostic. Verified against live Gemini DOM.

---

## Files Changed

| File | Change |
|---|---|
| `Coordinators/AppCoordinator.swift` | Remove `private` from `defaultArtifactFilename()` |
| `Views/ArtifactCaptureButton.swift` | Pass default filename to sheet; add `initialFilename` parameter; update placeholder |
| `WebKit/UserScripts.swift` | Replace streaming check with `button.send-button.stop` |

---

## What Is Not Changed

- `captureLastResponse()` flow is untouched
- `performFileIO()` filename collision logic is untouched — it already handles extensions correctly
- `HTMLToMarkdown.swift` is untouched
- No new dependencies

---

## Testing

**Bug 1:**
- Open artifact capture sheet — default filename appears pre-filled (including `.md` extension) and selected
- Press Save immediately — file saved with default name
- Type over the selection — Save uses the typed name
- Clear the field — Save is disabled

**Bug 2 — Verify selector before shipping (DevTools):**
- Open `gemini.google.com` in Safari
- Send a long prompt to trigger a streaming response
- While the response is streaming, open Web Inspector (Cmd+Option+I) → Console
- Run: `document.querySelector('button.send-button.stop')` — should return the button element (not null)
- After streaming ends, run the same query — should return null
- This confirms the selector works without requiring a locale change

**Bug 2 — Locale regression test:**
- Set macOS system language to a non-English locale (e.g. German or Spanish)
- Reload Gemini, send a long prompt, trigger capture mid-stream
- Verify the capture fails with the message "Error: Response is still generating" (the UI shows `CaptureProgress.failed` with `AppIntentError.stillStreaming.localizedDescription`)
- Wait for stream to complete, capture again — succeeds and file is saved
