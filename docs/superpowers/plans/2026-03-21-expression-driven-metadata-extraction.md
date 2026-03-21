# Expression-Driven Metadata Extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace hardcoded Swift metadata extraction with JSON-driven JS expressions, fix the `isPageReady` guard bug that empties all metadata, and add `gemini_tier` field to artifact YAML frontmatter.

**Architecture:** `gemini-selectors.json` gains a `metadata` object mapping field names to JS expression strings (or arrays for A/B fallbacks). `createMetadataScript()` generates its entire extraction script from these expressions. Each field is wrapped in an isolated try/catch — one failure cannot affect others.

**Tech Stack:** Swift 5.9+, Xcode 15+, WKWebView JS evaluation, JSON (no external dependencies added)

---

## Context for Implementers

This is a macOS app (no command-line test runner). "Build" means Cmd+B in Xcode. "Run" means Cmd+R and interact with the live app. Each task ends with a build verification before committing.

**Key files to understand before starting:**
- `WebKit/GeminiSelectors.swift` — `Codable` struct loaded from `gemini-selectors.json`. Currently has 14 `let` fields. Has a `static let _loaded` that reads the user file or bundle once.
- `WebKit/UserScripts.swift` — Static JS script generators. `createMetadataScript()` (line 81) currently hardcodes all extraction logic using selectors from `GeminiSelectors.shared`. `createDOMCaptureScript()` (line 490) generates the debug DOM probe.
- `Coordinators/AppCoordinator.swift` — `fetchMetadataPreview()` (line 281) evaluates `createMetadataScript()` and maps results to `ArtifactMetadata`. `selectorDictJSON()` (line 424) builds the JSON for the debug probe. Both reference the 5 fields being removed.
- `Artifacts/ArtifactMetadata.swift` — `Sendable` struct with YAML serialization. All fields are `var`.
- `Resources/gemini-selectors.json` — Bundled JSON loaded at startup. The user-patchable version lives at `~/Library/Application Support/GeminiDesktop/gemini-selectors.json`.

**Spec:** `docs/superpowers/specs/2026-03-21-expression-driven-metadata-extraction.md`

---

## File Map

| File | What changes |
|---|---|
| `Resources/gemini-selectors.json` | Add `metadata` object; remove 5 CSS metadata selector fields |
| `WebKit/GeminiSelectors.swift` | Add `MetadataExpression` enum; add `let metadata`; remove 5 CSS fields; update `GeminiSelectors.default` |
| `WebKit/UserScripts.swift` | Rewrite `createMetadataScript()`; add `singleExprBlock`/`multiExprBlock` helpers; add `metadataProbe` to `createDOMCaptureScript` |
| `Artifacts/ArtifactMetadata.swift` | Add `geminiTier: String?`; add to `toYAMLFrontmatter()` |
| `Coordinators/AppCoordinator.swift` | Remove `isPageReady` guard in `fetchMetadataPreview`; add `geminiTier` mapping; remove 5 deleted fields from `selectorDictJSON` |

---

## Task 1: Update `gemini-selectors.json`

**Files:**
- Modify: `Resources/gemini-selectors.json`

This is a pure data change with no Swift impact. Do it first so the bundled file is in sync with the Swift changes that follow.

- [ ] **Step 1.1: Replace the entire file**

Replace `Resources/gemini-selectors.json` with this content (removes 5 CSS metadata fields, adds `metadata` section):

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

- [ ] **Step 1.2: Build (Cmd+B)**

Expected: builds clean. The JSON file has no Swift impact yet — `GeminiSelectors.swift` still expects the old 5 fields and the decoder will fail silently, falling back to `GeminiSelectors.default`. That is acceptable for now; the Swift struct is updated in Task 2.

- [ ] **Step 1.3: Commit**

```bash
git add Resources/gemini-selectors.json
git commit -m "feat: add metadata expression section to gemini-selectors.json"
```

---

## Task 2: Add `MetadataExpression` and `metadata` field to `GeminiSelectors`

**Files:**
- Modify: `WebKit/GeminiSelectors.swift`

This task is **additive only** — the 5 old CSS fields stay until Task 4. The new `metadata` field is added alongside them. The struct will temporarily have both old fields and new metadata. That is intentional: it keeps every step compilable.

- [ ] **Step 2.1: Add `MetadataExpression` enum above the `GeminiSelectors` struct**

In `WebKit/GeminiSelectors.swift`, before `struct GeminiSelectors`, add:

```swift
/// Represents a single JS expression string or an ordered array of fallback expressions.
/// Callers always use `.expressions` which normalizes both cases to `[String]`.
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

- [ ] **Step 2.2: Add `metadata` field to the `GeminiSelectors` struct**

In `GeminiSelectors`, after the last `let` field (`streamingIndicatorSelector`), add:

```swift
    // MARK: - Expression-driven metadata fields

    var metadata: [String: MetadataExpression] = [:]
```

**Why `var` with a default, not `let`:** If declared `let` with no default, `JSONDecoder` throws `DecodingError.keyNotFound` when `"metadata"` is absent from a user JSON file. This would discard the entire user file — including their custom CSS selector overrides — just because they haven't added a `metadata` section yet. With `var ... = [:]`, a user JSON that omits `"metadata"` still decodes successfully; the empty dict causes the metadata expressions to fall back to `GeminiSelectors.default.metadata` at script-generation time.

- [ ] **Step 2.3: Update `GeminiSelectors.default` to include `metadata`**

Replace the entire `static let default` with:

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
        conversationTitleSelector: "a.conversation.selected",
        modelSelector: "[data-test-id=\"bard-mode-menu-button\"]",
        modelSelectorFallback: "[data-test-id=\"logo-pill-label-container\"]",
        userQuerySelector: "user-query .query-text-line",
        attachmentSelector: ".attachment-chip .attachment-name",
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

Note: The 5 old CSS fields (`conversationTitleSelector`, `modelSelector`, etc.) are still in `default` here because they are still in the struct. They will be removed together in Task 4.

- [ ] **Step 2.4: Build (Cmd+B)**

Expected: builds clean. The bundled JSON is now missing the 5 old fields, so JSON decoding will fail and fall back to `GeminiSelectors.default`. The `default` has the `metadata` dict. Metadata extraction still uses the old hardcoded script — that changes in Task 3.

- [ ] **Step 2.5: Commit**

```bash
git add WebKit/GeminiSelectors.swift
git commit -m "feat: add MetadataExpression enum and metadata field to GeminiSelectors"
```

---

## Task 3: Rewrite `createMetadataScript()` in `UserScripts.swift`

**Files:**
- Modify: `WebKit/UserScripts.swift`

Replace the hardcoded extraction logic with expression-driven code generation. The two private helper functions generate the JS blocks; `createMetadataScript` orchestrates them.

- [ ] **Step 3.1: Add `singleExprBlock` private helper**

In `UserScripts.swift`, inside `enum UserScripts`, after `createMetadataScript()` (around line 127), add:

```swift
    /// Generates a JS try/catch block that evaluates one expression and assigns to result[key].
    /// isArrayField: if true, skips the empty-string check (arrays are never empty strings).
    /// On catch, sets result[key] to null (scalar) or [] (array).
    nonisolated private static func singleExprBlock(key: String, expr: String, isArrayField: Bool) -> String {
        if isArrayField {
            return """
            try { result["\(key)"] = (\(expr)); } catch(e) { result["\(key)"] = []; }
            """
        } else {
            return """
            try { var _v = (\(expr)); result["\(key)"] = (_v !== null && _v !== undefined && _v !== '') ? _v : null; } catch(e) { result["\(key)"] = null; }
            """
        }
    }
```

- [ ] **Step 3.2: Add `multiExprBlock` private helper**

Immediately after `singleExprBlock`, add:

```swift
    /// Generates an IIFE that tries each expression in order, assigning the first
    /// non-null non-empty result to result[key]. Falls through to null if all fail.
    nonisolated private static func multiExprBlock(key: String, exprs: [String]) -> String {
        var lines: [String] = ["(function() {"]
        for expr in exprs {
            lines.append("""
                try { var _v = (\(expr)); if (_v !== null && _v !== undefined && _v !== '') { result["\(key)"] = _v; return; } } catch(e) {}
            """)
        }
        lines.append("""
            result["\(key)"] = null;
        })();
        """)
        return lines.joined(separator: "\n")
    }
```

- [ ] **Step 3.3: Replace `createMetadataScript()` body**

Replace the entire `createMetadataScript()` method (lines 81–127) with:

```swift
    /// Creates a script that extracts conversation metadata from the Gemini DOM.
    /// Returns a JSON string. Each field is individually wrapped in try/catch.
    /// All extraction expressions are sourced from GeminiSelectors.shared.metadata
    /// (user-patchable via gemini-selectors.json — no recompile needed for selector updates).
    /// GeminiSelectors.shared is backed by a static let — safe from nonisolated context.
    nonisolated static func createMetadataScript() -> String {
        let entries = GeminiSelectors.shared.metadata
        var blocks: [String] = []

        for (key, expr) in entries {
            let exprs = expr.expressions
            let isArrayField = key == "attachments"  // only array-valued field in current schema
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

- [ ] **Step 3.4: Build (Cmd+B)**

Expected: builds clean. The old references to `s.conversationTitleSelector` etc. are gone from `createMetadataScript`. `AppCoordinator.selectorDictJSON()` still references the 5 old fields (they still exist in the struct), so no compiler errors yet.

- [ ] **Step 3.5: Commit**

```bash
git add WebKit/UserScripts.swift
git commit -m "feat: rewrite createMetadataScript to generate expression-driven JS from GeminiSelectors.metadata"
```

---

## Task 4: Remove 5 old CSS metadata fields (atomic cleanup)

**Files:**
- Modify: `WebKit/GeminiSelectors.swift`
- Modify: `Coordinators/AppCoordinator.swift`

This is the only task that touches two files in one commit — it must be atomic because removing the 5 fields from the struct breaks `AppCoordinator.selectorDictJSON()` which references them. Both files must be fixed before the build passes.

- [ ] **Step 4.1: Remove the 5 CSS fields from `GeminiSelectors` struct**

In `WebKit/GeminiSelectors.swift`, remove these 5 field declarations from the `// MARK: - New metadata selector fields` section:

```swift
    let conversationTitleSelector: String
    let modelSelector: String
    let modelSelectorFallback: String
    let userQuerySelector: String
    let attachmentSelector: String
```

Also remove the `// MARK: - New metadata selector fields` comment if it becomes empty.

- [ ] **Step 4.2: Update `GeminiSelectors.default` — remove the 5 fields**

In the `static let default` initializer, remove these 5 lines:

```swift
        conversationTitleSelector: "a.conversation.selected",
        modelSelector: "[data-test-id=\"bard-mode-menu-button\"]",
        modelSelectorFallback: "[data-test-id=\"logo-pill-label-container\"]",
        userQuerySelector: "user-query .query-text-line",
        attachmentSelector: ".attachment-chip .attachment-name",
```

- [ ] **Step 4.3: Update `selectorDictJSON()` in `AppCoordinator.swift` — remove the 5 fields**

In `Coordinators/AppCoordinator.swift`, in `selectorDictJSON()` (around line 424), remove these 5 lines from the `dict` literal:

```swift
            "conversationTitleSelector": s.conversationTitleSelector,
            "modelSelector": s.modelSelector,
            "modelSelectorFallback": s.modelSelectorFallback,
            "userQuerySelector": s.userQuerySelector,
            "attachmentSelector": s.attachmentSelector,
```

- [ ] **Step 4.4: Build (Cmd+B)**

Expected: builds clean with no references to the 5 removed fields anywhere.

- [ ] **Step 4.5: Commit**

```bash
git add WebKit/GeminiSelectors.swift Coordinators/AppCoordinator.swift
git commit -m "refactor: remove CSS metadata selector fields, now expressed as JS in metadata dict"
```

---

## Task 5: Add `metadataProbe` to `createDOMCaptureScript`

**Files:**
- Modify: `WebKit/UserScripts.swift`

Extends the debug DOM capture with a `metadataProbe` section. This uses `eval` (safe in WKWebView's natively injected context) to evaluate expressions at probe time, recording which index matched and the raw value.

- [ ] **Step 5.1: Add `metadataProbeBlocks` private helper**

In `UserScripts.swift`, after `multiExprBlock`, add:

```swift
    /// Generates the metadataProbe JS — one IIFE per metadata field.
    /// Uses eval (safe: evaluateJavaScript bypasses page CSP; expressions come from GeminiSelectors, not page).
    /// Array-valued fields (attachments) use JSON.stringify for the value.
    nonisolated private static func metadataProbeBlocks() -> String {
        let entries = GeminiSelectors.shared.metadata
        var blocks: [String] = []

        for (key, expr) in entries {
            let exprs = expr.expressions
            let isArrayField = key == "attachments"
            // Build JS array literal of expression strings, escaping backslashes and double quotes
            let jsExprs = exprs.map { e -> String in
                let escaped = e
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }.joined(separator: ", ")

            let valueExpr = isArrayField
                ? "JSON.stringify(_v).slice(0, 120)"
                : "String(_v).slice(0, 120)"
            let nullCheck = isArrayField
                ? "_v !== null && _v !== undefined"
                : "_v !== null && _v !== undefined && _v !== ''"

            blocks.append("""
            (function() {
                var field = "\(key)";
                var exprs = [\(jsExprs)];
                for (var i = 0; i < exprs.length; i++) {
                    try {
                        var _v = eval(exprs[i]);
                        if (\(nullCheck)) {
                            metadataProbe.push({ field: field, matchedIndex: i, value: \(valueExpr) });
                            return;
                        }
                    } catch(e) {}
                }
                metadataProbe.push({ field: field, matchedIndex: null, value: null });
            })();
            """)
        }

        return blocks.joined(separator: "\n")
    }
```

- [ ] **Step 5.2: Update `createDOMCaptureScript` to include `metadataProbe`**

In `createDOMCaptureScript`, the returned JS currently ends with:

```javascript
                return JSON.stringify({
                    selectorProbe: selectorProbe,
                    dataTestIds: dataTestIds,
                    structural: structural
                });
```

Replace that `return` block with:

```javascript
                // 4. Metadata expression probe
                var metadataProbe = [];
                \(metadataProbeBlocks())

                return JSON.stringify({
                    selectorProbe: selectorProbe,
                    dataTestIds: dataTestIds,
                    structural: structural,
                    metadataProbe: metadataProbe
                });
```

Note: `\(metadataProbeBlocks())` is a Swift string interpolation call inside the triple-quoted string — this inlines the probe IIFEs at script-generation time (same pattern as the existing script generation).

- [ ] **Step 5.3: Build (Cmd+B)**

Expected: builds clean.

- [ ] **Step 5.4: Commit**

```bash
git add WebKit/UserScripts.swift
git commit -m "feat: add metadataProbe section to DOM debug capture"
```

---

## Task 6: Add `geminiTier` to `ArtifactMetadata`

**Files:**
- Modify: `Artifacts/ArtifactMetadata.swift`
- Modify: `Coordinators/AppCoordinator.swift`

- [ ] **Step 6.1: Add `geminiTier` property to `ArtifactMetadata`**

In `Artifacts/ArtifactMetadata.swift`, in the `// Model context` section, after `var geminiModel: String?`, add:

```swift
    var geminiTier: String?    // "advanced" or "standard", from WIZ_global_data["AfY8Hf"]
```

- [ ] **Step 6.2: Add `gemini_tier` to `toYAMLFrontmatter()`**

In `toYAMLFrontmatter()`, after the `if let geminiModel { ... }` block, add:

```swift
        if let geminiTier {
            lines.append("gemini_tier: \"\(geminiTier)\"")
        }
```

The values are always `"advanced"` or `"standard"` — no quote escaping needed.

- [ ] **Step 6.3: Map `gemini_tier` in `fetchMetadataPreview`**

In `Coordinators/AppCoordinator.swift`, in `fetchMetadataPreview()`, after `metadata.geminiModel = json["gemini_model"] as? String`, add:

```swift
                metadata.geminiTier = json["gemini_tier"] as? String
```

- [ ] **Step 6.4: Build (Cmd+B)**

Expected: builds clean.

- [ ] **Step 6.5: Commit**

```bash
git add Artifacts/ArtifactMetadata.swift Coordinators/AppCoordinator.swift
git commit -m "feat: add gemini_tier field to ArtifactMetadata from WIZ_global_data"
```

---

## Task 7: Fix `isPageReady` Guard

**Files:**
- Modify: `Coordinators/AppCoordinator.swift`

- [ ] **Step 7.1: Remove the guard**

In `fetchMetadataPreview()` (around line 283), remove:

```swift
        guard webViewModel.isPageReady else { return metadata }
```

The generated script wraps every expression in try/catch — if the page is not ready, expressions return null and `fetchMetadataPreview` returns partial metadata with only Swift-side fields populated. This is the defined safe behavior. The guard was incorrect: Gemini is a SPA and `onNavigationStart` resets `isPageReady` to `false` on in-app conversation switches, causing `fetchMetadataPreview` to return empty metadata even when the DOM is fully populated.

- [ ] **Step 7.2: Build (Cmd+B)**

Expected: builds clean.

- [ ] **Step 7.3: Commit**

```bash
git add Coordinators/AppCoordinator.swift
git commit -m "fix: remove isPageReady guard in fetchMetadataPreview — SPA navigation caused false negatives"
```

---

## Task 8: Manual Verification

Run the app (Cmd+R) and verify the following. Reference the spec's testing checklist for full coverage: `docs/superpowers/specs/2026-03-21-expression-driven-metadata-extraction.md`

- [ ] **8.1: Basic metadata populated** — Open Gemini, have a conversation, click capture → save artifact → open the `.md` file → YAML frontmatter contains `conversation_url`, `conversation_title`, `gemini_model`, `request` (all were nil before this change)

- [ ] **8.2: `gemini_tier` present** — YAML includes `gemini_tier: "advanced"` or `"standard"` depending on account

- [ ] **8.3: `attachments: []` not null** — Capture with no attachments → `attachments: []` in YAML (not omitted)

- [ ] **8.4: SPA navigation** — Switch to a different conversation, immediately click capture (without full page reload) → metadata still populated (tests the `isPageReady` fix)

- [ ] **8.5: Array fallback** — Add a user file at `~/Library/Application Support/GeminiDesktop/gemini-selectors.json` with `gemini_model[0]` corrupted (e.g. `"BROKEN"`). Capture → `gemini_model` in YAML comes from expression `[1]` (the fallback). Relaunch → Settings shows "Custom (user file)".

- [ ] **8.6: metadataProbe in debug capture** — With debug mode on, run Debug → Capture DOM → open the capture file → `dom.metadataProbe` array present, each field has `matchedIndex` and `value`. Fields that match have integer `matchedIndex`; a field with a broken expression in user JSON shows `matchedIndex: null`.

- [ ] **8.7: Broken expression resilience** — Add a syntactically invalid expression to user JSON for one field → only that field is null in YAML, all others unaffected.

- [ ] **8.8: Fallback to bundle** — Delete user file, relaunch → Settings shows "Default (bundled)"; metadata still populates correctly.

- [ ] **8.9: YAML field order** — Open saved artifact `.md` → verify `gemini_tier` line appears immediately after `gemini_model` and before `request` in the frontmatter.

- [ ] **8.10: Missing expression field resilience** — In user JSON, omit `"request"` from the `metadata` object entirely. Capture → `request` absent from YAML, all other fields present, no crash.

- [ ] **8.11: Hardcoded default fallback** — Temporarily rename both the user file and the bundled `gemini-selectors.json` (or run with a debugger breakpoint forcing the decode to fail). Metadata should still populate from `GeminiSelectors.default`. Restore files after.
