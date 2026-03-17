//
//  PromptEntityQuery.swift
//  GeminiDesktop
//

import Foundation
import AppIntents

struct PromptEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PromptAppEntity] {
        let library = PromptLibrary()
        library.reload()

        return library.allFiles
            .filter { identifiers.contains($0.url.lastPathComponent) }
            .map { PromptAppEntity($0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PromptAppEntity] {
        let library = PromptLibrary()
        library.reload()

        return library.allFiles
            .prefix(10)
            .map { PromptAppEntity($0) }
    }

    @MainActor
    func defaultResult() async -> PromptAppEntity? {
        let library = PromptLibrary()
        library.reload()

        return library.allFiles.first.map { PromptAppEntity($0) }
    }
}
