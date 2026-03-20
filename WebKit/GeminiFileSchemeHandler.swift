//
//  GeminiFileSchemeHandler.swift
//  GeminiDesktop
//

import WebKit
import UniformTypeIdentifiers

/// Custom URL scheme handler that serves locally selected files to the Gemini web page.
///
/// Files are registered under `gemini-file://[uuid]/[filename]` URLs and served
/// directly from disk on request. This allows JS to reconstruct File objects from
/// native NSOpenPanel selections without base64 encoding.
final class GeminiFileSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "gemini-file"

    private let lock = NSLock()
    private var registry: [String: URL] = [:]           // uuid → local file URL
    private var activeTasks: Set<ObjectIdentifier> = []  // tasks currently in flight

    // MARK: - Registry

    /// Register an array of local file URLs. Returns the corresponding gemini-file:// URLs.
    func register(files: [URL]) -> [String] {
        lock.withLock {
            files.map { fileURL in
                let uuid = UUID().uuidString
                registry[uuid] = fileURL
                var allowedChars = CharacterSet.urlPathAllowed
                allowedChars.remove("\"")
                let encoded = fileURL.lastPathComponent
                    .addingPercentEncoding(withAllowedCharacters: allowedChars) ?? fileURL.lastPathComponent
                return "\(Self.scheme)://\(uuid)/\(encoded)"
            }
        }
    }

    /// Clear all registered files. Call before presenting a new NSOpenPanel.
    /// Note: in-flight gemini-file:// fetches from the previous selection will
    /// fail after this is called. This is acceptable — the JS error handler
    /// handles fetch failures gracefully.
    func clearRegistry() {
        lock.withLock { registry = [:] }
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let taskId = ObjectIdentifier(urlSchemeTask)
        lock.withLock { _ = activeTasks.insert(taskId) }

        guard let url = urlSchemeTask.request.url,
              let uuid = url.host else {
            failTask(urlSchemeTask, id: taskId, error: URLError(.badURL))
            return
        }

        let fileURL: URL? = lock.withLock { registry[uuid] }
        guard let fileURL else {
            failTask(urlSchemeTask, id: taskId, error: URLError(.fileDoesNotExist))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let data = try Data(contentsOf: fileURL)
                let mimeType = self.mimeType(for: fileURL)
                let headers: [String: String] = [
                    "Content-Type": mimeType,
                    "Content-Length": "\(data.count)",
                    "Access-Control-Allow-Origin": "*"
                ]
                guard let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                ) else {
                    self.failTask(urlSchemeTask, id: taskId, error: URLError(.unknown))
                    return
                }

                let shouldProceed = self.lock.withLock {
                    self.activeTasks.remove(taskId) != nil
                }
                guard shouldProceed else { return }
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                self.failTask(urlSchemeTask, id: taskId, error: error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        lock.withLock { _ = activeTasks.remove(ObjectIdentifier(urlSchemeTask)) }
    }

    // MARK: - Private

    private func failTask(_ task: any WKURLSchemeTask, id: ObjectIdentifier, error: Error) {
        let shouldProceed = lock.withLock {
            activeTasks.remove(id) != nil
        }
        guard shouldProceed else { return }
        task.didFailWithError(error)
    }

    private func mimeType(for url: URL) -> String {
        guard let utType = UTType(filenameExtension: url.pathExtension),
              let mime = utType.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }
}
