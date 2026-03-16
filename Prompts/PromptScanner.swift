//
//  PromptScanner.swift
//  GeminiDesktop
//

import Foundation

enum ScanResult: Equatable {
    case safe
    case warning(reason: String)
    case danger(reason: String)
}

enum PromptScanner {
    static func scan(body: String) -> ScanResult {
        // Danger patterns
        let dangerPatterns = [
            "ignore previous instructions",
            "you are now",
            "system prompt",
            "<script>",
            "exfiltrate",
            "steal",
            "bypass"
        ]

        for pattern in dangerPatterns {
            if body.lowercased().range(of: NSRegularExpression.escapedPattern(for: pattern)) != nil {
                return .danger(reason: pattern)
            }
        }

        // Warning patterns
        let warningPatterns = [
            "forget everything",
            "act as if",
            "jailbreak",
            "\\{[^}]+\\}"  // Template placeholders {…}
        ]

        for pattern in warningPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(body.startIndex..., in: body)
                if regex.firstMatch(in: body, range: range) != nil {
                    return .warning(reason: pattern)
                }
            }
        }

        return .safe
    }
}
