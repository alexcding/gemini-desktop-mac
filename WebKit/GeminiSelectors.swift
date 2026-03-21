//
//  GeminiSelectors.swift
//  GeminiDesktop
//

import Foundation

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

struct GeminiSelectors: Codable {

    // MARK: - Existing fields (unchanged)

    let conversationContainer: String
    let responseContainer: String
    let goodResponseButton: String
    let badResponseButton: String
    let promptInput: String
    let richTextareaSelector: String
    let sendButtonSelector: String
    let lastResponseSelector: String

    let streamingIndicatorSelector: String

    // MARK: - Expression-driven metadata fields

    var metadata: [String: MetadataExpression] = [:]

    // MARK: - Loading

    /// Computed once at first access. Returns (selectors, fromUserFile).
    private static let _loaded: (selectors: GeminiSelectors, fromUserFile: Bool) = {
        // Priority 1: user override at ~/Library/Application Support/GeminiDesktop/
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            let userURL = appSupport
                .appendingPathComponent("GeminiDesktop/gemini-selectors.json")
            if FileManager.default.fileExists(atPath: userURL.path),
               let data = try? Data(contentsOf: userURL),
               let loaded = try? JSONDecoder().decode(GeminiSelectors.self, from: data) {
                return (loaded, true)
            }
        }

        // Priority 2: bundled default
        guard let bundleURL = Bundle.main.url(
            forResource: "gemini-selectors", withExtension: "json"
        ),
              let data = try? Data(contentsOf: bundleURL),
              let loaded = try? JSONDecoder().decode(GeminiSelectors.self, from: data)
        else {
            return (.default, false)
        }
        return (loaded, false)
    }()

    static var shared: GeminiSelectors { _loaded.selectors }

    /// True if a valid user override file was found at launch.
    static var isUsingUserFile: Bool { _loaded.fromUserFile }

    // MARK: - Hardcoded fallback (used only if JSON is missing or corrupt)

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
}
