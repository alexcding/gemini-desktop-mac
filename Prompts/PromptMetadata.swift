//
//  PromptMetadata.swift
//  GeminiDesktop
//

import Foundation
import Yams

struct PromptMetadata {

    // MARK: - Required fields

    let schemaVersion: String
    let name: String
    let version: String
    let role: String
    let summary: String

    // MARK: - Optional core fields

    let lastUpdated: String?
    let author: String?
    let intent: String?
    let language: String?
    let deprecated: Bool         // defaults to false if absent

    // MARK: - Optional production / agentic fields

    let compatibleWith: [String] // defaults to [] if absent
    let tags: [String]           // defaults to [] if absent
    let outputSchema: String?
    let safetyGates: [String]    // defaults to [] if absent
    let modelParameters: ModelParameters?
    let license: String?
    let inputVariables: [String] // defaults to [] if absent

    // MARK: - Nested types

    struct ModelParameters {
        let temperature: Double?
        let topP: Double?
        let maxTokens: Int?
    }

    // MARK: - Parsing

    /// Parses YAML frontmatter from a prompt file's full content string.
    /// Returns nil if: no --- block, YAML is malformed, or any required field is missing.
    static func parse(from content: String) -> PromptMetadata? {
        let lines = content.components(separatedBy: .newlines)
        guard lines.count > 2, lines[0] == "---" else { return nil }

        var endIndex = -1
        for i in 1..<lines.count {
            if lines[i] == "---" { endIndex = i; break }
        }
        guard endIndex > 1 else { return nil }

        let yamlContent = lines[1..<endIndex].joined(separator: "\n")

        do {
            guard let decoded = try Yams.load(yaml: yamlContent) as? [String: Any] else { return nil }

            // Required fields — missing any returns nil (yamlParseError = true in PromptFile)
            guard
                let schemaVersion = decoded["schema_version"] as? String,
                let name = decoded["name"] as? String,
                let version = decoded["version"] as? String,
                let role = decoded["role"] as? String,
                let summary = decoded["summary"] as? String
            else { return nil }

            // Optional core
            let lastUpdated    = decoded["last_updated"] as? String
            let author         = decoded["author"] as? String
            let intent         = decoded["intent"] as? String
            let language       = decoded["language"] as? String
            let deprecated     = decoded["deprecated"] as? Bool ?? false

            // Optional production
            let compatibleWith  = decoded["compatible_with"] as? [String] ?? []
            let tags            = decoded["tags"] as? [String] ?? []
            let outputSchema    = decoded["output_schema"] as? String
            let safetyGates     = decoded["safety_gates"] as? [String] ?? []
            let license         = decoded["license"] as? String
            let inputVariables  = decoded["input_variables"] as? [String] ?? []

            var modelParameters: ModelParameters? = nil
            if let mp = decoded["model_parameters"] as? [String: Any] {
                modelParameters = ModelParameters(
                    temperature: mp["temperature"] as? Double,
                    topP:        mp["top_p"] as? Double,
                    maxTokens:   mp["max_tokens"] as? Int
                )
            }

            return PromptMetadata(
                schemaVersion:   schemaVersion,
                name:            name,
                version:         version,
                role:            role,
                summary:         summary,
                lastUpdated:     lastUpdated,
                author:          author,
                intent:          intent,
                language:        language,
                deprecated:      deprecated,
                compatibleWith:  compatibleWith,
                tags:            tags,
                outputSchema:    outputSchema,
                safetyGates:     safetyGates,
                modelParameters: modelParameters,
                license:         license,
                inputVariables:  inputVariables
            )
        } catch {
            return nil
        }
    }

    // MARK: - Body extraction (unchanged)

    /// Returns the prompt body — the content after the closing --- delimiter.
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

    // MARK: - Hidden flag

    /// Returns true only if the YAML frontmatter contains `hidden: true` (boolean).
    /// Independent of required-field validation — a file can have only `hidden: true`
    /// and nothing else and still return true. Returns false for any file without a
    /// `---` block, malformed YAML, missing key, or `hidden: "true"` (string).
    static func parseHiddenFlag(from content: String) -> Bool {
        let lines = content.components(separatedBy: .newlines)
        guard lines.count > 2, lines[0] == "---" else { return false }
        var endIndex = -1
        for i in 1..<lines.count {
            if lines[i] == "---" { endIndex = i; break }
        }
        guard endIndex > 1 else { return false }
        let yamlContent = lines[1..<endIndex].joined(separator: "\n")
        guard let decoded = try? Yams.load(yaml: yamlContent) as? [String: Any] else { return false }
        return decoded["hidden"] as? Bool == true
    }
}
