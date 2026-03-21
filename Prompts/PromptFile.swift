//
//  PromptFile.swift
//  GeminiDesktop
//

import Foundation

// MARK: - PromptTooltipContent

/// Carries structured metadata for display in a .help() tooltip.
/// All fields are typed — Option B (rich popover) reads them directly instead of calling formatted().
struct PromptTooltipContent {
    let name: String?
    let version: String?
    let role: String?
    let lastUpdated: String?
    let summary: String?
    let intent: String?
    let compatibleWith: [String]
    let tags: [String]
    let inputVariables: [String]
    let outputSchema: String?
    let deprecated: Bool
    let securityNotice: String?  // nil when safe
    let yamlError: Bool

    /// Formats content as a plain-text string for .help() tooltip display.
    /// yamlError takes priority over all other fields.
    /// Omits rows for nil/empty fields.
    func formatted() -> String {
        if yamlError {
            return "YAML error: required fields missing"
        }

        var lines: [String] = []

        // Header: "Name  vX.Y"
        let namePart    = name ?? ""
        let versionPart = version.map { "v\($0)" } ?? ""
        let header      = [namePart, versionPart].filter { !$0.isEmpty }.joined(separator: "  ")
        if !header.isEmpty { lines.append(header) }

        // Security notice immediately after header
        if let notice = securityNotice { lines.append(notice) }

        // Blank line after header block (only if name/version or security notice is present)
        if !header.isEmpty || securityNotice != nil { lines.append("") }

        // Behavior group
        var behaviorLines: [String] = []
        if let role = role, !role.isEmpty {
            behaviorLines.append("Role:     \(role)")
        }
        if let summary = summary, !summary.isEmpty {
            behaviorLines.append(contentsOf: wrap(summary, label: "Summary:  "))
        }
        if let intent = intent, !intent.isEmpty {
            behaviorLines.append(contentsOf: wrap(intent, label: "Intent:   "))
        }
        lines.append(contentsOf: behaviorLines)

        // Production group (only rendered if at least one field is present)
        var prodLines: [String] = []
        if !compatibleWith.isEmpty {
            prodLines.append("Compatible: \(compatibleWith.joined(separator: ", "))")
        }
        if !tags.isEmpty {
            prodLines.append("Tags:       \(tags.joined(separator: ", "))")
        }
        if !inputVariables.isEmpty {
            prodLines.append("Inputs:     \(inputVariables.joined(separator: ", "))")
        }
        if let lastUpdated = lastUpdated, !lastUpdated.isEmpty {
            prodLines.append("Updated:    \(lastUpdated)")
        }
        if !prodLines.isEmpty {
            if !behaviorLines.isEmpty { lines.append("") }
            lines.append(contentsOf: prodLines)
        }

        // Deprecated note as final line
        if deprecated {
            lines.append("Deprecated — use a newer version")
        }

        return lines.joined(separator: "\n")
    }

    /// Wraps text at 60 characters, indenting continuation lines to align with value start.
    /// Single words longer than maxWidth are not broken — they exceed the limit as-is.
    private func wrap(_ text: String, label: String) -> [String] {
        let maxWidth = 60
        let indent   = String(repeating: " ", count: label.count)
        var result: [String] = []
        var current = label
        for word in text.components(separatedBy: " ") {
            if current == label {
                current += word
            } else if (current + " " + word).count <= maxWidth {
                current += " " + word
            } else {
                result.append(current)
                current = indent + word
            }
        }
        if current != label { result.append(current) }
        return result
    }
}

// MARK: - PromptFile

struct PromptFile: Identifiable, Equatable {
    let url: URL
    let metadata: PromptMetadata?
    let yamlParseError: Bool
    let body: String
    let scanResult: ScanResult
    let isHiddenFlag: Bool

    var id: String { url.lastPathComponent }

    /// Menu display label — always the filename without extension.
    /// No YAML dependency: ordering and display are predictable regardless of metadata.
    var displayTitle: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Summary text for Siri/Shortcuts display via PromptAppEntity.
    var displayDescription: String? {
        metadata?.summary
    }

    /// Structured tooltip content for .help() display.
    /// Returns nil for plain prompts with no metadata, no security notice, and no YAML error.
    var tooltipContent: PromptTooltipContent? {
        let securityNotice: String?
        switch scanResult {
        case .safe:
            securityNotice = nil
        case .warning(let reason):
            securityNotice = "⚠ Risky: \"\(reason)\""
        case .danger(let reason):
            securityNotice = "Danger: \"\(reason)\""
        }

        // Plain prompts with no metadata and no security issue get no tooltip
        guard metadata != nil || securityNotice != nil || yamlParseError else { return nil }

        return PromptTooltipContent(
            name:           metadata?.name,
            version:        metadata?.version,
            role:           metadata?.role,
            lastUpdated:    metadata?.lastUpdated,
            summary:        metadata?.summary,
            intent:         metadata?.intent,
            compatibleWith: metadata?.compatibleWith ?? [],
            tags:           metadata?.tags ?? [],
            inputVariables: metadata?.inputVariables ?? [],
            outputSchema:   metadata?.outputSchema,
            deprecated:     metadata?.deprecated ?? false,
            securityNotice: securityNotice,
            yamlError:      yamlParseError
        )
    }

    static func load(from url: URL) -> PromptFile {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let body    = PromptMetadata.extractBody(from: content)
            let scanResult = PromptScanner.scan(body: body)

            var metadata: PromptMetadata? = nil
            var yamlParseError = false

            if content.hasPrefix("---") {
                metadata       = PromptMetadata.parse(from: content)
                yamlParseError = (metadata == nil)
            }

            // Compute hidden flag (independent of metadata parsing)
            let isHiddenFlag = content.hasPrefix("---")
                ? PromptMetadata.parseHiddenFlag(from: content)
                : false

            return PromptFile(
                url:            url,
                metadata:       metadata,
                yamlParseError: yamlParseError,
                body:           body,
                scanResult:     scanResult,
                isHiddenFlag:   isHiddenFlag
            )
        } catch {
            return PromptFile(
                url:            url,
                metadata:       nil,
                yamlParseError: false,
                body:           "",
                scanResult:     .safe,
                isHiddenFlag:   false
            )
        }
    }

    static func == (lhs: PromptFile, rhs: PromptFile) -> Bool {
        lhs.url == rhs.url && lhs.body == rhs.body
    }
}

// MARK: - PromptNode

enum PromptNode: Identifiable {
    case file(PromptFile)
    case directory(name: String, children: [PromptNode])

    var id: String {
        switch self {
        case .file(let f):            return f.id
        case .directory(let name, _): return "dir:\(name)"
        }
    }
}
