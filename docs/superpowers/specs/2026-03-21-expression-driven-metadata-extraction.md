# Expression-Driven Metadata Extraction — Design Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace hardcoded Swift metadata extraction logic with JSON-driven JS expressions, so selector drift caused by Google DOM updates can be fixed by editing `gemini-selectors.json` — no recompile required.

**Architecture:** Extend the existing `gemini-selectors.json` with a `metadata` section containing JS expression strings. `createMetadataScript()` generates its extraction script entirely from these expressions. Each field is isolated — one failure cannot affect others.

**Tech Stack:** Swift, SwiftUI, WKWebView JS evaluation, `gemini-selectors.json` (user-patchable)

---

## Background

`ArtifactMetadata` is populated by `fetchMetadataPreview()` in `AppCoordinator`, which evaluates `createMetadataScript()` against the WKWebView. That script currently hardcodes all extraction logic in Swift: which CSS selectors to use, how to extract values (`.textContent`, URL regex, `querySelectorAll`), and which JS globals to read (`navigator.userAgent`, `window.WIZ_global_data`).

This means every Google DOM update that breaks metadata requires a Swift code change and a new app build. The patchable-selectors infrastructure (user file at `~/Library/Application Support/GeminiDesktop/gemini-selectors.json`) exists but only stores CSS selector strings — it cannot express the extraction logic needed for URL parsing, WIZ state, or userAgent parsing.

Two additional problems discovered during implementation review:

1. **`isPageReady` guard causes silent failures.** Gemini is a SPA; `onNavigationStart` resets `isPageReady` to `false` on in-app conversation switches. By the time the user clicks capture the DOM is populated, but `fetchMetadataPreview` returns `ArtifactMetadata.empty()` because the guard fires.

2. **Missing tier metadata.** `window.WIZ_global_data["AfY8Hf"]` contains a boolean that distinguishes Advanced (Ultra/Pro) from Standard subscriptions. This is relevant for artifact reproducibility (Advanced-only models like high-reasoning tiers cannot be reproduced on a standard account) but is impossible to capture with CSS selectors alone.

---

## Design

### 1. JSON Schema — `metadata` Section

`gemini-selectors.json` gains a top-level `metadata` object. Each key is a metadata field name (matching `ArtifactMetadata` property naming convention). Each value is either a JS expression string or an array of JS expression strings.

**String value:** A single JS expression evaluated as-is.

**Array value:** Expressions tried in order; the first that returns a non-null, non-empty, non-undefined result wins. Subsequent expressions are not evaluated. This is the A/B testing path: when Google changes a DOM structure, append the new expression — old installs still work with the previous expression until the user updates their JSON.

The 5 metadata-specific CSS selector fields previously in the top level (`conversationTitleSelector`, `modelSelector`, `modelSelectorFallback`, `userQuerySelector`, `attachmentSelector`) are removed from the JSON. `streamingIndicatorSelector` stays at the top level (used by the debug probe and `createCaptureScript`).

Updated `gemini-selectors.json`:

```json
{
  "conversationContainer": "infinite-scroller[data-test-id='chat-history-container']",
  "responseContainer": "response-container",
  "goodResponseButton": "[aria-label='Good response']",
  "badResponseButton": "[aria-label='Bad response']",
  "promptInput": "rich-textarea[aria-label='Enter a prompt here']",
  "richTextareaSelector": "rich-textarea[aria-label='Enter a prompt here']",
  "sendButtonSelector": "button[aria-label='Send message']",
  "lastResponseSelector": "model-response:last-of-type",
  "streamingIndicatorSelector": "button.send-button.stop",

  "metadata": {
    "conversation_url": "window.location.href",
    "conversation_id": "window.location.href.match(/\\/app\\/([a-zA-Z0-9_-]+)/)?.[1] ?? null",
    "conversation_title": [
      "document.querySelector('a.conversation.selected')?.textContent?.trim() || null",
      "document.querySelector('[data-test-id=\"conversation-title\"]')?.textContent?.trim() || null"
    ],
    "response_index": "document.querySelectorAll('response-container').length",
    "gemini_model": [
      "document.querySelector('[data-test-id=\"bard-mode-menu-button\"]')?.textContent?.trim() || null",
      "document.querySelector('[data-test-id=\"logo-pill-label-container\"]')?.textContent?.trim() || null"
    ],
    "gemini_tier": [
      "(window.WIZ_global_data?.['AfY8Hf'] === true) ? 'advanced' : (window.WIZ_global_data?.['AfY8Hf'] === false ? 'standard' : null)",
      "null"
    ],
    "request": "Array.from(document.querySelectorAll('user-query .query-text-line')).at(-1)?.textContent?.trim() || null",
    "attachments": "Array.from(document.querySelectorAll('.attachment-chip .attachment-name')).map(el => el.textContent.trim()).filter(Boolean)",
    "webkit_version": "navigator.userAgent.match(/AppleWebKit\\/([\\d.]+)/)?.[1] ?? null",
    "jsc_version": "navigator.userAgent.match(/AppleWebKit\\/([\\d.]+)/)?.[1] ?? null"
  }
}
```

**Key notes:**
- `gemini_tier` uses an array so that when Google renames `AfY8Hf`, the user updates expression `[0]` with the new key. The `"null"` fallback ensures a clean null if `WIZ_global_data` is absent entirely.
- All expressions are self-contained one-liners. No expression depends on another.
- Fields not present in the `metadata` dict are simply absent from the result — `fetchMetadataPreview` maps known keys to `ArtifactMetadata` properties; unknown keys are ignored.

---

### 2. `GeminiSelectors.swift` — Type Model

Add a `Codable` enum to represent the string-or-array duality. Swift normalizes both forms internally; callers always see `[String]`:

```swift
enum MetadataExpression: Codable {
    case single(String)
    case multiple([String])

    var expressions: [String] {
        switch self {
        case .single(let s): return [s]
        case .multiple(let arr): return arr
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .single(s); return }
        self = .multiple(try c.decode([String].self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .single(let s): try c.encode(s)
        case .multiple(let arr): try c.encode(arr)
        }
    }
}
```

Remove the 5 metadata-only CSS selector fields from `GeminiSelectors`:
- `conversationTitleSelector`
- `modelSelector`
- `modelSelectorFallback`
- `userQuerySelector`
- `attachmentSelector`

Add:
```swift
var metadata: [String: MetadataExpression] = [:]
```

Update `GeminiSelectors.default` to match — the `metadata` dict in the default mirrors the bundled JSON expressions above. This ensures the hardcoded fallback (used only if JSON is missing or corrupt) also produces correct output.

---

### 3. `createMetadataScript()` Rewrite

**File:** `WebKit/UserScripts.swift`

The new implementation generates a JS IIFE from `GeminiSelectors.shared.metadata`. No extraction logic lives in Swift. For each field:

- **Single expression** → one try/catch block
- **Array of expressions** → IIFE with sequential try/catch blocks, returning on first non-empty hit

Generated structure (no `eval`, no CSP issues — pure code generation):

```javascript
(function() {
    var result = {};

    // Single expression field:
    try {
        var _v = (window.location.href);
        result["conversation_url"] = (_v !== null && _v !== undefined && _v !== '') ? _v : null;
    } catch(e) { result["conversation_url"] = null; }

    // Array field:
    (function() {
        try {
            var _v = (document.querySelector('[data-test-id="bard-mode-menu-button"]')?.textContent?.trim() || null);
            if (_v !== null && _v !== undefined && _v !== '') { result["gemini_model"] = _v; return; }
        } catch(e) {}
        try {
            var _v = (document.querySelector('[data-test-id="logo-pill-label-container"]')?.textContent?.trim() || null);
            if (_v !== null && _v !== undefined && _v !== '') { result["gemini_model"] = _v; return; }
        } catch(e) {}
        result["gemini_model"] = null;
    })();

    return JSON.stringify(result);
})();
```

Swift generation logic:

```swift
nonisolated static func createMetadataScript() -> String {
    let entries = GeminiSelectors.shared.metadata
    var blocks: [String] = []

    for (key, expr) in entries {
        let exprs = expr.expressions
        if exprs.count == 1 {
            blocks.append(singleExprBlock(key: key, expr: exprs[0]))
        } else {
            blocks.append(multiExprBlock(key: key, exprs: exprs))
        }
    }

    return """
    (function() {
        var result = {};
        \(blocks.joined(separator: "\n    "))
        return JSON.stringify(result);
    })();
    """
}
```

Private helpers `singleExprBlock(key:expr:)` and `multiExprBlock(key:exprs:)` emit the JS snippets shown above. Both are `nonisolated static` pure string functions.

---

### 4. `ArtifactMetadata` — Add `geminiTier`

**File:** `Artifacts/ArtifactMetadata.swift`

Add to the "Model context" section:

```swift
var geminiTier: String?   // "advanced" or "standard", from WIZ_global_data
```

Add to `toYAMLFrontmatter()` after `geminiModel`:

```swift
if let geminiTier {
    lines.append("gemini_tier: \"\(geminiTier)\"")
}
```

Add to `fetchMetadataPreview()` mapping in `AppCoordinator`:

```swift
metadata.geminiTier = json["gemini_tier"] as? String
```

Example output:
```yaml
gemini_model: "Thinking"
gemini_tier: "advanced"
```

---

### 5. Fix `isPageReady` Guard

**File:** `Coordinators/AppCoordinator.swift`

Remove the guard from `fetchMetadataPreview`:

```swift
// Remove this:
guard webViewModel.isPageReady else { return metadata }
```

The generated metadata script wraps every expression in try/catch. If the DOM is not ready, expressions return null and `fetchMetadataPreview` returns partial metadata — which is the defined safe behavior. The guard was unnecessarily strict and fires on SPA navigation switches within Gemini, producing empty metadata even when the DOM is fully populated.

---

### 6. Debug Capture — `metadataProbe`

**File:** `WebKit/UserScripts.swift`

Extend `createDOMCaptureScript` to include a `metadataProbe` section alongside `selectorProbe`. For each field in `GeminiSelectors.shared.metadata`, evaluate expressions in order and record which index matched and the raw value (truncated to 120 chars):

```json
"metadataProbe": [
  { "field": "gemini_model", "matchedIndex": 0, "value": "Thinking" },
  { "field": "gemini_tier", "matchedIndex": 0, "value": "advanced" },
  { "field": "conversation_title", "matchedIndex": 0, "value": "Shipping Pallet Michigan City to Austin" },
  { "field": "conversation_id", "matchedIndex": 0, "value": "abc123xyz" }
]
```

`matchedIndex: null` and `value: null` when all expressions returned empty — this is the primary signal that a field needs a new expression added to the JSON.

The generation uses the same `multiExprBlock` pattern but returns index and value instead of setting `result`.

---

## What Does Not Change

- `ArtifactCaptureButton.swift` — no changes
- `saveArtifact`, `performFileIO`, `captureResponseMarkdown` — no changes
- `createCaptureScript` — no changes
- `toYAMLFrontmatter` structure — additive only (`gemini_tier`)
- `GeminiSelectors` loading priority (user file → bundle → hardcoded default) — unchanged
- Settings UI — unchanged

---

## File Summary

| Action | File | Change |
|---|---|---|
| Modify | `Resources/gemini-selectors.json` | Add `metadata` object; remove 5 CSS metadata selector fields |
| Modify | `WebKit/GeminiSelectors.swift` | Add `MetadataExpression` enum; replace 5 CSS fields with `metadata: [String: MetadataExpression]`; update `default` |
| Modify | `WebKit/UserScripts.swift` | Rewrite `createMetadataScript()` to generate expression-driven JS; add `metadataProbe` to `createDOMCaptureScript` |
| Modify | `Artifacts/ArtifactMetadata.swift` | Add `geminiTier: String?`; add to `toYAMLFrontmatter()` |
| Modify | `Coordinators/AppCoordinator.swift` | Remove `isPageReady` guard in `fetchMetadataPreview`; add `geminiTier` mapping |

---

## Error Handling

| Scenario | Behavior |
|---|---|
| Expression throws a JS exception | That field is null; all other fields unaffected |
| All expressions for a field return empty | Field is null; no user-facing error |
| `metadata` key missing from JSON | `GeminiSelectors.metadata` is empty dict; script returns `{}`; all ArtifactMetadata DOM fields are nil |
| WIZ_global_data key renamed by Google | `gemini_tier` returns null until JSON is updated; all other fields unaffected |
| User JSON missing `metadata` section | Decodes as empty dict (default value); bundled JSON always has it |

---

## Manual Testing Checklist

- [ ] **Basic metadata capture:** Trigger artifact capture mid-conversation → YAML frontmatter contains `conversation_url`, `conversation_title`, `gemini_model`, `request`
- [ ] **Tier field:** With Advanced account, `gemini_tier: "advanced"` appears in YAML; with standard, `"standard"`
- [ ] **Array fallback:** Manually break expression `[0]` for `gemini_model` in user JSON → expression `[1]` picks up the value
- [ ] **SPA navigation:** Switch conversations, immediately capture → metadata populated (no empty result from `isPageReady` guard)
- [ ] **metadataProbe in debug capture:** Run "Capture DOM" → output contains `metadataProbe` array with `matchedIndex` and `value` per field
- [ ] **Missing expression:** Remove a field from `metadata` in user JSON → that field absent from YAML, no crash
- [ ] **Broken expression:** Add syntactically invalid JS expression → that field is null, other fields unaffected
- [ ] **User file override:** Place updated `gemini-selectors.json` in Application Support → Settings shows "Custom (user file)"; new expressions used
- [ ] **Fallback to bundle:** Delete user file, relaunch → bundled expressions used, metadata still populates
- [ ] **YAML output:** Verify `gemini_tier` appears between `gemini_model` and `request` in frontmatter
