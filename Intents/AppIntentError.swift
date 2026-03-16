//
//  AppIntentError.swift
//  GeminiDesktop
//

import Foundation

enum AppIntentError: LocalizedError {
    case promptTooLong(Int)
    case dangerPatternDetected(String)
    case notAuthenticated
    case noResponseAvailable
    case stillStreaming
    case directoryUnavailable
    case promptNotFound

    var errorDescription: String? {
        switch self {
        case .promptTooLong(let count):
            return "Prompt is too long (\(count) chars). Maximum is 16,000 characters."
        case .dangerPatternDetected(let pattern):
            return "Prompt contains a dangerous pattern (\(pattern)). For safety, it cannot be injected."
        case .notAuthenticated:
            return "Gemini is not loaded or authenticated. Please open Gemini and try again."
        case .noResponseAvailable:
            return "No response from Gemini to capture. Start a conversation first."
        case .stillStreaming:
            return "Gemini is still generating a response. Wait for it to finish before capturing."
        case .directoryUnavailable:
            return "The artifacts directory is not accessible."
        case .promptNotFound:
            return "The selected prompt was not found."
        }
    }
}
