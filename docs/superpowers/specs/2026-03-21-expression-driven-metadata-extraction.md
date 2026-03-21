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
- `jsc_version` intentionally duplicates the `webkit_version` expression. JSC co-releases with WebKit and its version is not independently exposed in `navigator.userAgent`. This mirrors the existing behavior in the old hardcoded script.
- `attachments` evaluates to an array, not a string. An empty array `[]` is a valid result and is not treated as "empty" by the null-check logic (see Section 3).
- `response_index` evaluates to a non-negative integer. `0` is a valid result meaning no responses yet and is passed through as-is, not coerced to null.
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

All existing fields in `GeminiSelectors` are `let`. Add `metadata` as `var` with an empty-dict default:

```swift
var metadata: [String: MetadataExpression] = [:]
```

Use `var` (not `let`) so that `JSONDecoder` can skip the key when absent from a user JSON file. A user JSON that has all the top-level CSS selector fields but no `"metadata"` key will decode successfully — giving the user their custom CSS selectors while falling back to `GeminiSelectors.default.metadata` for the metadata expressions. A `let` with no default would throw `DecodingError.keyNotFound` and discard the entire user file.

Because the field has a default value, the memberwise initializer makes it optional. Update `GeminiSelectors.default` to pass it explicitly: Update `GeminiSelectors.default` with a complete explicit initializer that includes `metadata`:

```swift
static let `default` = GeminiSelectors(
    conversationContainer: "infinite-scroller[data-test-id='chat-history-container']",
    responseContainer: "response-container",
    goodResponseButton: "[aria-label='Good response']",
    badResponseButton: "[aria-label='Bad response']",
    promptInput: "rich-textarea[aria-label='Enter a prompt here']",
    richTextareaSelector: "rich-textarea[aria-label='Enter a prompt here']",
    sendButtonSelector: "button[aria-label='Send message']",
    lastResponseSelector: "model-response:last-of-type",
    streamingIndicatorSelector: "button.send-button.stop",
    metadata: [
        "conversation_url": .single("window.location.href"),
        "conversation_id": .single("window.location.href.match(/\\/app\\/([a-zA-Z0-9_-]+)/)?.[1] ?? null"),
        "conversation_title": .multiple([
            "document.querySelector('a.conversation.selected')?.textContent?.trim() || null",
            "document.querySelector('[data-test-id=\"conversation-title\"]')?.textContent?.trim() || null"
        ]),
        "response_index": .single("document.querySelectorAll('response-container').length"),
        "gemini_model": .multiple([
            "document.querySelector('[data-test-id=\"bard-mode-menu-button\"]')?.textContent?.trim() || null",
            "document.querySelector('[data-test-id=\"logo-pill-label-container\"]')?.textContent?.trim() || null"
        ]),
        "gemini_tier": .multiple([
            "(window.WIZ_global_data?.['AfY8Hf'] === true) ? 'advanced' : (window.WIZ_global_data?.['AfY8Hf'] === false ? 'standard' : null)",
            "null"
        ]),
        "request": .single("Array.from(document.querySelectorAll('user-query .query-text-line')).at(-1)?.textContent?.trim() || null"),
        "attachments": .single("Array.from(document.querySelectorAll('.attachment-chip .attachment-name')).map(el => el.textContent.trim()).filter(Boolean)"),
        "webkit_version": .single("navigator.userAgent.match(/AppleWebKit\\/([\\d.]+)/)?.[1] ?? null"),
        "jsc_version": .single("navigator.userAgent.match(/AppleWebKit\\/([\\d.]+)/)?.[1] ?? null")
    ]
)
```

---

### 3. `createMetadataScript()` Rewrite

**File:** `WebKit/UserScripts.swift`

The new implementation generates a JS IIFE from `GeminiSelectors.shared.metadata`. No extraction logic lives in Swift. `GeminiSelectors.shared` is backed by a `static let` (computed once at first access) and is safe to read from a `nonisolated` context — no `await` or actor hopping required.

For each field, Swift emits one of two patterns:

**Single expression** → one try/catch block. The null-check `_v !== ''` is applied only to string/scalar values. For array-valued fields (`attachments`), the expression evaluates to an array — the check `_v !== null && _v !== undefined` is sufficient; do not add `_v !== ''` for array fields. Distinguish at the Swift level by field key: `"attachments"` is the only array-valued field in the current schema. The `isArrayField` flag in the Swift generator is set by `key == "attachments"`. If a future schema adds more array-valued fields, their keys must also be added to this check.

```javascript
// Scalar single expression:
try {
    var _v = (window.location.href);
    result["conversation_url"] = (_v !== null && _v !== undefined && _v !== '') ? _v : null;
} catch(e) { result["conversation_url"] = null; }

// Array single expression (attachments) — no empty-string check:
try {
    result["attachments"] = Array.from(document.querySelectorAll('.attachment-chip .attachment-name')).map(el => el.textContent.trim()).filter(Boolean);
} catch(e) { result["attachments"] = []; }
```

**Array of expressions** → IIFE with sequential try/catch blocks, returning on first non-empty hit. All expressions in an array field are string/scalar — the empty-string check applies to all of them:

```javascript
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
```

Full generated script structure:

```javascript
(function() {
    var result = {};

    try { var _v = (window.location.href); result["conversation_url"] = (_v !== null && _v !== undefined && _v !== '') ? _v : null; } catch(e) { result["conversation_url"] = null; }

    (function() {
        try { var _v = (EXPR_0); if (_v !== null && _v !== undefined && _v !== '') { result["gemini_model"] = _v; return; } } catch(e) {}
        try { var _v = (EXPR_1); if (_v !== null && _v !== undefined && _v !== '') { result["gemini_model"] = _v; return; } } catch(e) {}
        result["gemini_model"] = null;
    })();

    try { result["attachments"] = Array.from(document.querySelectorAll('.attachment-chip .attachment-name')).map(el => el.textContent.trim()).filter(Boolean); } catch(e) { result["attachments"] = []; }

    return JSON.stringify(result);
})();
```

Swift generation logic:

```swift
nonisolated static func createMetadataScript() -> String {
    let entries = GeminiSelectors.shared.metadata  // static let — safe from nonisolated context
    var blocks: [String] = []

    for (key, expr) in entries {
        let exprs = expr.expressions
        let isArrayField = key == "attachments"  // only known array-valued field
        if exprs.count == 1 {
            blocks.append(singleExprBlock(key: key, expr: exprs[0], isArrayField: isArrayField))
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

Private helpers `singleExprBlock(key:expr:isArrayField:)` and `multiExprBlock(key:exprs:)` emit the JS snippets shown above. Both are `nonisolated static` pure string functions.

---

### 4. `ArtifactMetadata` — Add `geminiTier`

**File:** `Artifacts/ArtifactMetadata.swift`

Add to the "Model context" section:

```swift
var geminiTier: String?   // "advanced" or "standard", from WIZ_global_data
```

Add to `toYAMLFrontmatter()` after `geminiModel`. The possible values are `"advanced"` and `"standard"` — no quote escaping is required (no double-quote characters in either value):

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

Extend `createDOMCaptureScript` to include a `metadataProbe` array in the returned JSON object, alongside the existing `selectorProbe`, `dataTestIds`, and `structural` arrays.

For each field in `GeminiSelectors.shared.metadata`, evaluate expressions in order and record which index matched (0-based) and the raw value truncated to 120 chars. If all expressions fail, record `matchedIndex: null, value: null`.

Generated probe JS structure — add inside the existing try/catch in `createDOMCaptureScript`, before the `return JSON.stringify(...)`. Swift generates one IIFE per field using the same loop structure for both single and multi-expression fields (single-expression fields get a one-element array):

```javascript
// 4. Metadata expression probe
var metadataProbe = [];

// Single-expression field (e.g., conversation_url):
(function() {
    var field = "conversation_url";
    var exprs = ["window.location.href"];
    for (var i = 0; i < exprs.length; i++) {
        try {
            var _v = eval(exprs[i]);
            if (_v !== null && _v !== undefined && _v !== '') {
                metadataProbe.push({ field: field, matchedIndex: i, value: String(_v).slice(0, 120) });
                return;
            }
        } catch(e) {}
    }
    metadataProbe.push({ field: field, matchedIndex: null, value: null });
})();

// Multi-expression field (e.g., gemini_model):
(function() {
    var field = "gemini_model";
    var exprs = [
        "document.querySelector('[data-test-id=\"bard-mode-menu-button\"]')?.textContent?.trim() || null",
        "document.querySelector('[data-test-id=\"logo-pill-label-container\"]')?.textContent?.trim() || null"
    ];
    for (var i = 0; i < exprs.length; i++) {
        try {
            var _v = eval(exprs[i]);
            if (_v !== null && _v !== undefined && _v !== '') {
                metadataProbe.push({ field: field, matchedIndex: i, value: String(_v).slice(0, 120) });
                return;
            }
        } catch(e) {}
    }
    metadataProbe.push({ field: field, matchedIndex: null, value: null });
})();

// Array-valued field (attachments) — value is JSON-stringified:
(function() {
    var field = "attachments";
    var exprs = ["Array.from(document.querySelectorAll('.attachment-chip .attachment-name')).map(el => el.textContent.trim()).filter(Boolean)"];
    for (var i = 0; i < exprs.length; i++) {
        try {
            var _v = eval(exprs[i]);
            if (_v !== null && _v !== undefined) {
                metadataProbe.push({ field: field, matchedIndex: i, value: JSON.stringify(_v).slice(0, 120) });
                return;
            }
        } catch(e) {}
    }
    metadataProbe.push({ field: field, matchedIndex: null, value: null });
})();
```

**Note on `eval` in the probe:** `evaluateJavaScript` in WKWebView bypasses page CSP entirely — the page's `unsafe-eval` restriction does not apply to natively injected scripts. The expression strings originate from `GeminiSelectors.shared`, not the page. The metadata capture script (`createMetadataScript`) does **not** use `eval` — it generates inline code. The probe uses `eval` because passing expression strings as runtime data into a loop is cleaner for a diagnostic tool; correctness is the same.

Output shape:
```json
"metadataProbe": [
  { "field": "conversation_url", "matchedIndex": 0, "value": "https://gemini.google.com/app/abc123xyz" },
  { "field": "gemini_model", "matchedIndex": 0, "value": "Thinking" },
  { "field": "gemini_tier", "matchedIndex": 0, "value": "advanced" },
  { "field": "conversation_title", "matchedIndex": 0, "value": "Shipping Pallet Michigan City to Austin" },
  { "field": "attachments", "matchedIndex": 0, "value": "[]" },
  { "field": "conversation_id", "matchedIndex": null, "value": null }
]
```

**Diagnostic notes:**
- `matchedIndex: null, value: null` is the primary signal that a field needs a new expression added to the JSON.
- `attachments` with `matchedIndex: 0, value: "[]"` means the expression ran successfully and found zero attachment chips — this is expected when no files are attached. It does not indicate a broken selector.

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
| Modify | `Resources/gemini-selectors.json` | Add `metadata` object with all expression fields; remove 5 CSS metadata selector fields; bundled file must include `metadata` section |
| Modify | `WebKit/GeminiSelectors.swift` | Add `MetadataExpression` enum; replace 5 CSS fields with `let metadata: [String: MetadataExpression]`; provide full updated `GeminiSelectors.default` with `metadata` |
| Modify | `WebKit/UserScripts.swift` | Rewrite `createMetadataScript()` to generate expression-driven JS with array-field awareness; add `metadataProbe` to `createDOMCaptureScript` |
| Modify | `Artifacts/ArtifactMetadata.swift` | Add `geminiTier: String?` to Model context section; add to `toYAMLFrontmatter()` after `geminiModel` |
| Modify | `Coordinators/AppCoordinator.swift` | Remove `isPageReady` guard in `fetchMetadataPreview`; add `geminiTier` mapping |

---

## Error Handling

| Scenario | Behavior |
|---|---|
| Expression throws a JS exception | That field is null; all other fields unaffected |
| All expressions for a field return empty/null | Field is null in result; `fetchMetadataPreview` maps it as nil in `ArtifactMetadata`; no user-facing error |
| `metadata` key absent from user JSON | Decodes to empty dict (Swift default value); script returns `{}`; all DOM fields nil. The bundled JSON always has the `metadata` section — if user JSON omits it, they get no metadata. Document this in the user-facing patchability notes. |
| WIZ_global_data key renamed by Google | `gemini_tier` returns null until the user updates expression `[0]` in their JSON |
| Broken JS expression syntax in user JSON | That field is null (try/catch catches the syntax error at eval time); other fields unaffected |

---

## Manual Testing Checklist

- [ ] **Basic metadata capture:** Trigger artifact capture mid-conversation → YAML frontmatter contains `conversation_url`, `conversation_title`, `gemini_model`, `request`
- [ ] **Tier field — advanced:** With Advanced account, `gemini_tier: "advanced"` appears in YAML
- [ ] **Tier field — standard:** With standard account, `gemini_tier: "standard"` appears in YAML
- [ ] **Array fallback:** Manually corrupt expression `[0]` for `gemini_model` in user JSON → expression `[1]` picks up the value
- [ ] **SPA navigation:** Switch conversations, immediately capture → metadata populated (no empty result from `isPageReady` guard)
- [ ] **Attachments field:** Capture with no attachments → `attachments: []` in YAML (not null, not omitted)
- [ ] **metadataProbe in debug capture:** Run "Capture DOM" → output contains `metadataProbe` array with `matchedIndex` (0-based integer or null) and `value` per field
- [ ] **metadataProbe null signal:** Remove a working expression from user JSON → that field shows `matchedIndex: null, value: null` in probe output
- [ ] **Missing expression field:** Remove a field from `metadata` in user JSON → that field absent from YAML, no crash
- [ ] **Broken expression:** Add syntactically invalid JS expression to user JSON → that field is null in YAML, other fields unaffected
- [ ] **User file override:** Place updated `gemini-selectors.json` in Application Support → Settings shows "Custom (user file)"; new expressions used
- [ ] **Fallback to bundle:** Delete user file, relaunch → bundled expressions used, metadata still populates
- [ ] **YAML field order:** Verify `gemini_tier` appears between `gemini_model` and `request` in frontmatter
- [ ] **GeminiSelectors.default:** Delete both user file and bundle resource (test only) → hardcoded `default` produces correct metadata
