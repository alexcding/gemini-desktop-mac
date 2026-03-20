//
//  ArtifactLogger.swift
//  GeminiDesktop
//

import Foundation
import OSLog

/// Writes structured error entries to the app container's log file
/// and to the unified logging system (visible in Console.app).
///
/// Log path: ~/Library/Containers/<bundle-id>/Data/Library/Logs/GeminiDesktop/gemini-desktop.log
///
/// All operations are best-effort — a logging failure is never surfaced to the user.
enum ArtifactLogger {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.geminidesktop",
        category: "ArtifactCapture"
    )

    /// The log file URL resolved from the app's sandboxed Library container.
    /// Returns nil if the path cannot be constructed (should never happen in practice).
    static var logFileURL: URL? {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/GeminiDesktop/gemini-desktop.log")
    }

    /// Appends one structured entry to the log file and emits to os.log.
    /// No-op if the log directory cannot be created.
    static func logError(_ error: Error, context: [String: String] = [:]) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var entry = "[\(timestamp)] ERROR ArtifactCapture: \(error.localizedDescription)\n"
        for (key, value) in context.sorted(by: { $0.key < $1.key }) {
            entry += "  \(key): \(value)\n"
        }

        // Unified logging (visible in Console.app)
        logger.error("\(error.localizedDescription, privacy: .public) — \(context.description, privacy: .public)")

        // File logging — silently no-op on any failure
        guard let logURL = logFileURL else { return }
        let logDir = logURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: logDir, withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = entry.data(using: .utf8) { handle.write(data) }
            } else {
                try entry.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            // Logging failure is intentionally silent
        }
    }
}
