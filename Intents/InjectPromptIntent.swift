//
//  InjectPromptIntent.swift
//  GeminiDesktop
//

import Foundation
import AppKit
import AppIntents

struct InjectPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Inject Prompt Into Gemini"
    static let description: IntentDescription = IntentDescription(
        "Inject a saved Markdown prompt into the Gemini text field."
    )

    @Parameter(title: "Prompt")
    var prompt: PromptAppEntity

    func perform() async throws -> some IntentResult {
        guard let promptFile = prompt.file else {
            throw AppIntentError.promptNotFound
        }

        // Verify bookmark access
        guard let coordinator = AppDelegate.shared?.appCoordinator else {
            throw AppIntentError.notAuthenticated
        }

        // Check for dangerous patterns
        if case .danger = promptFile.scanResult {
            throw AppIntentError.dangerPatternDetected("")
        }

        // Bring app to foreground and inject the prompt
        await MainActor.run {
            if !NSApplication.shared.isActive {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            coordinator.injectPrompt(promptFile)
        }

        return .result(dialog: "Prompt '\(promptFile.displayTitle)' injected successfully")
    }
}
