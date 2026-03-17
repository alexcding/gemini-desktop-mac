//
//  PromptAppEntity.swift
//  GeminiDesktop
//

import Foundation
import AppIntents

struct PromptAppEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Prompt")

    let id: String
    let displayRepresentation: DisplayRepresentation

    var file: PromptFile?

    init(_ file: PromptFile) {
        self.id = file.url.lastPathComponent
        self.file = file

        let subtitle: LocalizedStringResource?
        if let description = file.displayDescription {
            subtitle = LocalizedStringResource(stringLiteral: description)
        } else {
            subtitle = nil
        }

        self.displayRepresentation = DisplayRepresentation(
            title: "\(file.displayTitle)",
            subtitle: subtitle
        )
    }

    static var defaultQuery: PromptEntityQuery {
        PromptEntityQuery()
    }
}
