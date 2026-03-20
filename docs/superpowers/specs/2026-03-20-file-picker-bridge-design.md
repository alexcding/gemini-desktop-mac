# File Picker Bridge — Design Spec

**Date:** 2026-03-20
**Status:** Approved

## Problem

Gemini's web UI opens its file picker by calling `.click()` programmatically on a hidden `<input type="file" style="display:none">`. WKWebView silently drops this request — `webView(_:runOpenPanelWith:)` is never called — because the click arrives without a live user-gesture token (Gemini's code path goes async before calling `.click()`). The result: clicking "Add files" / "Upload files" does nothing in the desktop app.

**Root cause confirmed via debugging:**
- `HTMLInputElement.prototype.click` fires (JS interception log shows it)
- `runOpenPanelWith` is never called (no Xcode console output)
- Making the element temporarily `display:block` does not fix it — gesture token expiry is the blocker, not visibility

## Solution

Bypass WKWebView's gesture requirement entirely via a native bridge:

1. JS intercepts the file input click and messages Swift instead
2. Swift presents `NSOpenPanel` natively (no gesture requirement for native UI)
3. Swift registers selected files in a `WKURLSchemeHandler` under a custom scheme
4. JS fetches files via the custom scheme with CORS headers, reconstructs `File` objects, and injects them into the input

## Components

### `GeminiFileSchemeHandler` (new file: `WebKit/GeminiFileSchemeHandler.swift`)

Implements `WKURLSchemeHandler`. Maintains a thread-safe registry of `[String: URL]` mapping UUID-based identifiers to local filesystem URLs. Serves file data for `gemini-file://` requests — reads directly from disk per request (no full file copy into memory).

URL format: `gemini-file://[uuid]/[filename]`
- UUID used as the host component for registry lookup
- Filename in the path preserves the original name for JS `File` construction

Must be registered on `WKWebViewConfiguration` before WebView creation. Covers both the main window and chat bar panel (single shared WebView).

**Threading:** `WKURLSchemeHandler` methods are called on arbitrary threads. The file registry must be protected by a lock (e.g. `NSLock` or `Mutex`). Active tasks must be tracked in a lock-protected set; `webView(_:stop:)` must mark the task as stopped, and `start` must check before calling any `WKURLSchemeTask` response methods to avoid crashing on stopped tasks.

**CORS headers:** Every response must include:
```
Access-Control-Allow-Origin: *
```
Without this, `fetch()` from `https://gemini.google.com` to the custom scheme will be blocked by WebKit's same-origin policy before the response body is read.

**MIME type detection:** Use `UTType(filenameExtension:)` to detect MIME type. For unknown extensions, fall back to `application/octet-stream`.

### `FilePickerHandler` (added to `WebKit/WebViewModel.swift`)

`@MainActor` class implementing `WKScriptMessageHandler`. Follows the existing `ConsoleLogHandler` pattern.

Holds `weak var webView: WKWebView?` injected at init time — weak to avoid a retain cycle (`WKUserContentController` → handler → `WKWebView`).

Responsibilities:
- Receive `fileInputClicked` message with `{multiple: Bool, accept: String, nonce: String}` payload
- Clear previous file registrations from `GeminiFileSchemeHandler`
- Present `NSOpenPanel` — `allowsMultipleSelection` from payload, `allowedContentTypes` left unrestricted (see accept handling below)
- On selection: register files with UUIDs, call `evaluateJavaScript("window.__GeminiDesktop.filesSelected('[nonce]', [urls])")`
- On cancel: call `evaluateJavaScript("window.__GeminiDesktop.filesSelected('[nonce]', [])")` to clean up JS state
- Clear the previous registry just before presenting the new `NSOpenPanel` (after the old panel is definitively dismissed), not at message receipt — active `fetch` requests from the previous selection may still be in flight

**`accept` attribute handling:** `NSOpenPanel.allowedContentTypes` is left unrestricted regardless of the `accept` attribute. The `accept` value is passed from JS for potential future use but is not parsed. Rationale: Gemini's file input has `accept=""` (unrestricted), and implementing MIME wildcard → `UTType` conversion (`image/*` has no `UTType` equivalent) adds complexity for zero user benefit currently.

### File Picker User Script (added to `WebKit/UserScripts.swift`)

Injected at `atDocumentStart`, `forMainFrameOnly: true`.

`forMainFrameOnly: true` because Gemini's file inputs only exist in the main frame; intercepting subframes could cause false triggers.

All globals are namespaced under `window.__GeminiDesktop` (consistent with IIFE-based isolation pattern used by existing scripts).

**Intercept side:**
```javascript
(function() {
    window.__GeminiDesktop = window.__GeminiDesktop || {};
    let pendingFileInput = null;
    let pendingNonce = null;

    const orig = HTMLInputElement.prototype.click;
    HTMLInputElement.prototype.click = function() {
        if (this.type === 'file') {
            pendingFileInput = this;
            pendingNonce = Math.random().toString(36).slice(2);
            window.webkit.messageHandlers.fileInputClicked.postMessage({
                multiple: this.multiple,
                accept: this.accept || '',
                nonce: pendingNonce
            });
        } else {
            orig.call(this);
        }
    };

    window.__GeminiDesktop.filesSelected = function(nonce, urls) {
        if (nonce !== pendingNonce) return; // stale response, ignore
        const input = pendingFileInput;
        pendingFileInput = null;
        pendingNonce = null;
        if (!input || urls.length === 0) return;

        Promise.all(urls.map(url =>
            fetch(url)
                .then(r => Promise.all([
                    r.arrayBuffer(),
                    r.headers.get('Content-Type') || 'application/octet-stream',
                    decodeURIComponent(new URL(url).pathname.split('/').pop())
                ]))
                .then(([buf, type, name]) => new File([buf], name, { type }))
        )).then(files => {
            const dt = new DataTransfer();
            files.forEach(f => dt.items.add(f));
            input.files = dt.files;  // supported in WebKit via DataTransfer
            input.dispatchEvent(new Event('change', { bubbles: true }));
            input.dispatchEvent(new Event('input', { bubbles: true }));
        }).catch(err => {
            console.error('[GeminiDesktop] File picker error:', err);
        });
    };
})();
```

**Note on `input.files = dt.files`:** Modern WebKit (Safari 14.1+, WKWebView) supports assigning a `DataTransfer.files` `FileList` to a file input's `files` property. This is a widely-supported de-facto standard. Both `change` and `input` events are dispatched to cover Angular's native DOM event listeners.

### `runOpenPanelWith` in `GeminiWebView.Coordinator`

**Remove this method entirely.** The JS intercept permanently takes over the file picker code path; `runOpenPanelWith` will never be called again. Leaving it as dead code would confuse future maintainers. The `NSOpenPanel` logic now lives in `FilePickerHandler`.

### Sandbox Entitlement

Verify `com.apple.security.files.user-selected.read-only` (or read-write) is present in `GeminiDesktop.entitlements`. `NSOpenPanel` URLs are security-scoped and require this entitlement for the scheme handler to read the selected files.

## Data Flow

```
User clicks "Add files"
  → Gemini JS calls fileInput.click()
  → Injected script intercepts
      saves pendingFileInput + generates nonce
      posts {multiple, accept, nonce} to Swift
  → FilePickerHandler (@MainActor)
      clears GeminiFileSchemeHandler registry
      presents NSOpenPanel
  → [cancel] → __GeminiDesktop.filesSelected(nonce, []) → JS clears state
  → [select] → register files with UUIDs in GeminiFileSchemeHandler
              → __GeminiDesktop.filesSelected(nonce, ['gemini-file://[uuid]/foo.png', ...])
  → JS verifies nonce, fetches all URLs in parallel (Promise.all)
  → GeminiFileSchemeHandler serves each request
      lookup UUID in thread-safe registry → local file URL
      check task not stopped → read from disk
      respond with Content-Type + Access-Control-Allow-Origin: *
  → JS creates File objects, sets input.files = dt.files, dispatches events
  → Gemini receives change event, sees FileList, uploads normally
```

## Error Handling

| Scenario | Behavior |
|----------|----------|
| User cancels NSOpenPanel | Swift calls `filesSelected(nonce, [])`, JS clears state |
| User opens picker again before previous completes | New nonce issued; old nonce check in JS discards any stale response; registry cleared before new panel opens |
| `stop` called on active scheme task | Task removed from active set; no further response methods called |
| UUID not found in scheme handler | Task fails with error; `fetch` rejects; JS catch block logs error |
| `input.files` assignment fails (future WebKit regression) | `change` event not dispatched; Gemini sees no files; user must retry. No crash. |
| `accept` attribute non-empty | Passed in message payload, currently ignored; `NSOpenPanel` unrestricted |

## Files Changed

| Action | File | Change |
|--------|------|--------|
| New | `WebKit/GeminiFileSchemeHandler.swift` | `WKURLSchemeHandler` with thread-safe file registry, task tracking, CORS headers |
| Modify | `WebKit/WebViewModel.swift` | Add `FilePickerHandler` (weak webView ref); register scheme + message handlers in `createWebView` |
| Modify | `WebKit/UserScripts.swift` | Add handler name constant, namespaced JS source, include in `createAllScripts()` |
| Modify | `WebKit/GeminiWebView.swift` | Remove `runOpenPanelWith` method; remove 3 debug `[DEBUG]` print statements |

## Non-Goals

- No changes to `AppCoordinator`, SwiftUI views, or `UserDefaults`
- No new Swift Package dependencies
- Camera / microphone capture not affected (handled separately via `requestMediaCapturePermissionFor`)
- `accept` attribute MIME filtering not implemented (unrestricted open panel for all file types)
