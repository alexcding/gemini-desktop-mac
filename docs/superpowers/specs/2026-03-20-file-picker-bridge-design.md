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
4. JS fetches files via the custom scheme, reconstructs `File` objects, and injects them into the input

## Components

### `GeminiFileSchemeHandler` (new file: `WebKit/GeminiFileSchemeHandler.swift`)

Implements `WKURLSchemeHandler`. Maintains a thread-safe registry of `[String: URL]` mapping UUID-based identifiers to local filesystem URLs. Serves file data for `gemini-file://` requests — reads directly from disk per request (no full file copy into memory).

URL format: `gemini-file://[uuid]/[filename]`
- UUID key used for registry lookup
- Filename in the path preserves the original name for JS `File` construction

Must be registered on `WKWebViewConfiguration` before WebView creation. Covers both the main window and chat bar panel (single shared WebView).

### `FilePickerHandler` (added to `WebKit/WebViewModel.swift`)

`@MainActor` class implementing `WKScriptMessageHandler`. Follows the existing `ConsoleLogHandler` pattern.

Responsibilities:
- Receive `fileInputClicked` message with `{multiple: Bool, accept: String}` payload
- Clear previous file registrations from `GeminiFileSchemeHandler`
- Present `NSOpenPanel` with correct `allowsMultipleSelection` and `allowedContentTypes`
- On selection: register files with UUIDs, call `evaluateJavaScript("window.__nativeFilesSelected([...])")`
- On cancel: call `evaluateJavaScript("window.__nativeFilesSelected([])")` to clean up JS state

### File Picker User Script (added to `WebKit/UserScripts.swift`)

Injected at `atDocumentStart`, main frame only.

**Intercept side:**
```javascript
const orig = HTMLInputElement.prototype.click;
HTMLInputElement.prototype.click = function() {
    if (this.type === 'file') {
        pendingFileInput = this;
        window.webkit.messageHandlers.fileInputClicked.postMessage({
            multiple: this.multiple,
            accept: this.accept || ''
        });
    } else {
        orig.call(this);
    }
};
```

**Callback side (`window.__nativeFilesSelected`):**
- Accepts array of `gemini-file://` URLs (empty array = cancel)
- Fetches all URLs in parallel via `Promise.all`
- Creates `File` objects from response `arrayBuffer()` + MIME type from `Content-Type` header
- Builds `DataTransfer`, adds all `File` objects
- Sets `pendingFileInput.files = dt.files`
- Dispatches `change` and `input` events (covers React synthetic events and native DOM listeners)
- Clears `pendingFileInput`
- Wraps in try/catch: on error, clears `pendingFileInput` and logs to console

## Data Flow

```
User clicks "Add files"
  → Gemini JS calls fileInput.click()
  → Injected script intercepts
      saves pendingFileInput
      posts {multiple, accept} to Swift
  → FilePickerHandler (@MainActor)
      clears GeminiFileSchemeHandler registry
      presents NSOpenPanel
  → [cancel] → __nativeFilesSelected([]) → JS clears pendingFileInput
  → [select] → register files with UUIDs in GeminiFileSchemeHandler
              → __nativeFilesSelected(['gemini-file://[uuid]/foo.png', ...])
  → JS fetches all URLs in parallel (Promise.all)
  → GeminiFileSchemeHandler serves each request
      lookup UUID → local file URL
      read from disk → respond with correct Content-Type (UTType detection)
  → JS creates File objects, sets input.files, dispatches events
  → Gemini React code sees FileList, uploads normally
```

## Error Handling

| Scenario | Behavior |
|----------|----------|
| User cancels NSOpenPanel | Swift calls `__nativeFilesSelected([])`, JS clears `pendingFileInput` |
| User opens picker again before completing | `FilePickerHandler` clears previous registry; `pendingFileInput` overwritten |
| UUID not found in scheme handler | `fetch` rejects; JS catch block clears `pendingFileInput`, logs error |
| `accept` attribute empty | `NSOpenPanel.allowedContentTypes` left unrestricted |
| `accept` attribute non-empty | Parsed and set on `NSOpenPanel` for native filtering |

**File registry lifetime:** Registrations persist until the next picker invocation clears them. No timer-based cleanup — the registry holds URL references only (no file data in memory), and `fetch` requests may arrive slightly after `__nativeFilesSelected` is called.

## Files Changed

| Action | File | Change |
|--------|------|--------|
| New | `WebKit/GeminiFileSchemeHandler.swift` | `WKURLSchemeHandler` with thread-safe file registry |
| Modify | `WebKit/WebViewModel.swift` | Add `FilePickerHandler`; register scheme + message handlers in `createWebView` |
| Modify | `WebKit/UserScripts.swift` | Add handler name constant, JS source, include in `createAllScripts()` |
| Modify | `WebKit/GeminiWebView.swift` | Remove 3 debug `[DEBUG]` print statements |

## Non-Goals

- No changes to `AppCoordinator`, SwiftUI views, or `UserDefaults`
- No new Swift Package dependencies
- Camera / microphone capture not affected (handled separately via `requestMediaCapturePermissionFor`)
