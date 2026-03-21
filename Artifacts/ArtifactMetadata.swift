//
//  ArtifactMetadata.swift
//  GeminiDesktop
//

import Foundation

/// Carries all capture metadata through the save pipeline.
/// All properties are `var` to support future in-sheet editing (Option B).
struct ArtifactMetadata: Sendable {
    // Provenance — set by Swift at capture time
    var schemaVersion: String = "1"
    var capturedAt: Date = Date()
    var tool: String = "Gemini Desktop"
    var toolVersion: String
    var macosVersion: String

    // Source context — extracted from DOM via JS
    var source: String = "gemini.google.com"
    var conversationId: String?
    var conversationTitle: String?
    var conversationUrl: String?
    var responseIndex: Int?

    // Model context — extracted from DOM
    var geminiModel: String?
    var geminiTier: String?    // "advanced" or "standard", from WIZ_global_data["AfY8Hf"]

    // Reproduction — extracted from DOM
    var request: String?
    var attachments: [String] = []

    // Runtime environment — extracted from JS
    var webkitVersion: String?
    var jscVersion: String?

    // User-fillable — empty by default, present in YAML as a prompt
    var tags: [String] = []
}

extension ArtifactMetadata {

    /// Returns metadata with only Swift-side fields populated.
    /// Safe to use before fetchMetadataPreview() completes.
    static func empty() -> ArtifactMetadata {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return ArtifactMetadata(toolVersion: version, macosVersion: os)
    }

    /// Serializes metadata to a YAML frontmatter block.
    /// Non-throwing — pure string interpolation, cannot fail.
    /// Optional fields are omitted when nil or empty.
    func toYAMLFrontmatter() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var lines: [String] = ["---"]

        lines.append("schema_version: \"\(schemaVersion)\"")
        lines.append("captured_at: \"\(iso.string(from: capturedAt))\"")
        lines.append("tool: \"\(tool)\"")
        if !toolVersion.isEmpty { lines.append("tool_version: \"\(toolVersion)\"") }
        if !macosVersion.isEmpty { lines.append("macos_version: \"\(macosVersion)\"") }
        lines.append("source: \"\(source)\"")

        if let conversationId { lines.append("conversation_id: \"\(conversationId)\"") }
        if let conversationTitle {
            let escaped = conversationTitle.replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("conversation_title: \"\(escaped)\"")
        }
        if let conversationUrl { lines.append("conversation_url: \"\(conversationUrl)\"") }
        if let responseIndex { lines.append("response_index: \(responseIndex)") }
        if let geminiModel {
            let escaped = geminiModel.replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("gemini_model: \"\(escaped)\"")
        }
        if let geminiTier {
            lines.append("gemini_tier: \"\(geminiTier)\"")
        }

        if let request, !request.isEmpty {
            // YAML literal block scalar for multi-line strings
            lines.append("request: |")
            request.components(separatedBy: "\n").forEach { lines.append("  \($0)") }
        }

        if attachments.isEmpty {
            lines.append("attachments: []")
        } else {
            lines.append("attachments:")
            attachments.forEach {
                let escaped = $0.replacingOccurrences(of: "\"", with: "\\\"")
                lines.append("  - \"\(escaped)\"")
            }
        }

        if let webkitVersion { lines.append("webkit_version: \"\(webkitVersion)\"") }
        if let jscVersion { lines.append("jsc_version: \"\(jscVersion)\"") }

        if tags.isEmpty {
            lines.append("tags: []")
        } else {
            lines.append("tags:")
            tags.forEach { lines.append("  - \"\($0)\"") }
        }

        lines.append("---")
        lines.append("")  // blank line after frontmatter

        return lines.joined(separator: "\n")
    }
}
