//
//  PromptMetadata.swift
//  GeminiDesktop
//

import Foundation
import Yams

struct PromptMetadata: Codable {
    let title: String
    let description: String
    let tags: [String]?
    let category: String?
    let author: String?
    let version: String?
    let model: String?

    static func parse(from content: String) -> PromptMetadata? {
        // Find the closing --- delimiter
        let lines = content.components(separatedBy: .newlines)
        guard lines.count > 2, lines[0] == "---" else { return nil }

        var endIndex = -1
        for i in 1..<lines.count {
            if lines[i] == "---" {
                endIndex = i
                break
            }
        }
        guard endIndex > 1 else { return nil }

        let yamlContent = lines[1..<endIndex].joined(separator: "\n")

        do {
            guard let decoded = try Yams.load(yaml: yamlContent) as? [String: Any] else { return nil }
            guard let title = decoded["title"] as? String,
                  let description = decoded["description"] as? String else {
                return nil
            }

            let tags = decoded["tags"] as? [String]
            let category = decoded["category"] as? String
            let author = decoded["author"] as? String
            let version = decoded["version"] as? String
            let model = decoded["model"] as? String

            return PromptMetadata(
                title: title,
                description: description,
                tags: tags,
                category: category,
                author: author,
                version: version,
                model: model
            )
        } catch {
            return nil
        }
    }

    static func extractBody(from content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        guard lines.count > 2, lines[0] == "---" else { return content }

        for i in 1..<lines.count {
            if lines[i] == "---" {
                return lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
            }
        }

        return content
    }
}
