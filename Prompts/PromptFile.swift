//
//  PromptFile.swift
//  GeminiDesktop
//

import Foundation

struct PromptFile: Identifiable, Equatable {
    let url: URL
    let metadata: PromptMetadata?
    let yamlParseError: Bool
    let body: String
    let scanResult: ScanResult

    var id: String { url.lastPathComponent }

    var displayTitle: String {
        if yamlParseError {
            return "⚠️ (YAML Error) \(url.deletingPathExtension().lastPathComponent)"
        }
        return metadata?.title ?? url.deletingPathExtension().lastPathComponent
    }

    var displayDescription: String? {
        metadata?.description
    }

    static func load(from url: URL) -> PromptFile {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let body = PromptMetadata.extractBody(from: content)
            let scanResult = PromptScanner.scan(body: body)

            var metadata: PromptMetadata? = nil
            var yamlParseError = false

            if content.hasPrefix("---") {
                metadata = PromptMetadata.parse(from: content)
                yamlParseError = (metadata == nil)
            }

            return PromptFile(
                url: url,
                metadata: metadata,
                yamlParseError: yamlParseError,
                body: body,
                scanResult: scanResult
            )
        } catch {
            return PromptFile(
                url: url,
                metadata: nil,
                yamlParseError: false,
                body: "",
                scanResult: .safe
            )
        }
    }

    static func == (lhs: PromptFile, rhs: PromptFile) -> Bool {
        lhs.url == rhs.url && lhs.body == rhs.body
    }
}

enum PromptNode: Identifiable {
    case file(PromptFile)
    case directory(name: String, children: [PromptNode])

    var id: String {
        switch self {
        case .file(let f):
            return f.id
        case .directory(let name, _):
            return "dir:\(name)"
        }
    }
}
