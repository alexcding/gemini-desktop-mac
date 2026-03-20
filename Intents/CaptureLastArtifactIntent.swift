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

        let isReady = await MainActor.run { coordinator.webViewModel.isPageReady }
        if !isReady {
            throw AppIntentError.notAuthenticated
        }

        // Fetch metadata and response in sequence on the main actor
        let metadata = await coordinator.fetchMetadataPreview()
        let markdownContent = try await coordinator.captureResponseMarkdown()

        if markdownContent.isEmpty {
            throw AppIntentError.noResponseAvailable
        }

        let artifactFilename = filename.isEmpty
            ? await coordinator.defaultArtifactFilename()
            : (filename.hasSuffix(".md") ? filename : filename + ".md")

        await coordinator.saveArtifact(
            markdown: markdownContent,
            metadata: metadata,
            filename: artifactFilename
        )

        return .result(dialog: "Response captured as '\(artifactFilename)'")
    }
}
