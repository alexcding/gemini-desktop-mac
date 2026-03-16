//
//  GeminiSelectors.swift
//  GeminiDesktop
//

import Foundation

struct GeminiSelectors: Codable {
    let conversationContainer: String
    let responseContainer: String
    let goodResponseButton: String
    let badResponseButton: String
    let promptInput: String
    let richTextareaSelector: String
    let sendButtonSelector: String
    let lastResponseSelector: String

    /// Loaded once at first use. Falls back to hardcoded defaults on any failure.
    static let shared: GeminiSelectors = {
        guard let url = Bundle.main.url(forResource: "gemini-selectors", withExtension: "json") else {
            print("[GeminiSelectors] gemini-selectors.json not found in bundle — using defaults")
            return .default
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(GeminiSelectors.self, from: data)
        } catch {
            print("[GeminiSelectors] Failed to load gemini-selectors.json: \(error) — using defaults")
            return .default
        }
    }()

    static let `default` = GeminiSelectors(
        conversationContainer: "infinite-scroller[data-test-id='chat-history-container']",
        responseContainer: "response-container",
        goodResponseButton: "[aria-label='Good response']",
        badResponseButton: "[aria-label='Bad response']",
        promptInput: "rich-textarea[aria-label='Enter a prompt here']",
        richTextareaSelector: "rich-textarea[aria-label='Enter a prompt here']",
        sendButtonSelector: "button[aria-label='Send message']",
        lastResponseSelector: "model-response:last-of-type"
    )
}
