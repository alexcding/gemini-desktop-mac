//
//  GeminiSelectors.swift
//  GeminiDesktop
//

import Foundation

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

    // MARK: - New metadata selector fields

    let conversationTitleSelector: String
    let modelSelector: String
    let modelSelectorFallback: String
    let userQuerySelector: String
    let attachmentSelector: String
    let streamingIndicatorSelector: String

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
        conversationTitleSelector: "a.conversation.selected",
        modelSelector: "[data-test-id=\"bard-mode-menu-button\"]",
        modelSelectorFallback: "[data-test-id=\"logo-pill-label-container\"]",
        userQuerySelector: "user-query .query-text-line",
        attachmentSelector: ".attachment-chip .attachment-name",
        streamingIndicatorSelector: "button.send-button.stop"
    )
}
