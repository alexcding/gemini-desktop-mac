//
//  CaptureLastArtifactIntent.swift
//  GeminiDesktop
//

import Foundation
import AppIntents

struct CaptureLastArtifactIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Last Gemini Response"
    static let description: IntentDescription = IntentDescription(
        "Capture the last response from Gemini and save it as a Markdown artifact."
    )

    @Parameter(title: "Filename", description: "Name for the artifact (without .md extension)")
    var filename: String

    func perform() async throws -> some IntentResult {
        guard let coordinator = AppDelegate.shared?.appCoordinator else {
            throw AppIntentError.notAuthenticated
        }

        // Check if page is ready (access MainActor property)
        let isReady = await MainActor.run { coordinator.webViewModel.isPageReady }
        if !isReady {
            throw AppIntentError.notAuthenticated
        }

        // Check if still streaming
        let isStreaming = await coordinator.webViewModel.isStreamingResponse()
        if isStreaming {
            throw AppIntentError.stillStreaming
        }

        // Capture the response asynchronously
        let markdownContent = try await coordinator.captureLastResponseAsString()
        if markdownContent.isEmpty {
            throw AppIntentError.noResponseAvailable
        }

        // Save as artifact on main thread
        await MainActor.run {
            coordinator.saveArtifact(markdown: markdownContent, filename: filename)
        }

        return .result(dialog: "Response captured as '\(filename).md'")
    }
}
