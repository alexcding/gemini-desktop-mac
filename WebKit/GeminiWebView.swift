//
//  GeminiWebView.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
@preconcurrency import WebKit
import Synchronization

struct GeminiWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WebViewContainer {
        let container = WebViewContainer(webView: webView, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: WebViewContainer, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        private let downloadDestination = Mutex<URL?>(nil)

        nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if isExternalURL(url) {
                    NSWorkspace.shared.open(url)
                } else {
                    webView.load(URLRequest(url: url))
                }
            }
            return nil
        }

        nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.canShowMIMEType {
                decisionHandler(.allow)
            } else {
                decisionHandler(.download)
            }
        }

        nonisolated func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        nonisolated func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        nonisolated func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            var destination = downloadsURL.appendingPathComponent(suggestedFilename)

            let fileManager = FileManager.default
            let nameWithoutExtension = destination.deletingPathExtension().lastPathComponent
            let fileExtension = destination.pathExtension

            var counter = 1
            while fileManager.fileExists(atPath: destination.path) {
                let newName = fileExtension.isEmpty
                    ? "\(nameWithoutExtension) (\(counter))"
                    : "\(nameWithoutExtension) (\(counter)).\(fileExtension)"
                destination = downloadsURL.appendingPathComponent(newName)
                counter += 1
            }

            downloadDestination.withLock { $0 = destination }
            return destination
        }

        nonisolated func downloadDidFinish(_ download: WKDownload) {
            let destination = downloadDestination.withLock { $0 }
            guard let destination else { return }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }

        nonisolated func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            let alert = NSAlert()
            alert.messageText = "Download Failed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        nonisolated func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
            completionHandler()
        }

        nonisolated func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }

        nonisolated func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let alert = NSAlert()
            alert.messageText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: GeminiWebView.Constants.textFieldWidth, height: GeminiWebView.Constants.textFieldHeight))
            textField.stringValue = defaultText ?? ""
            alert.accessoryView = textField

            completionHandler(alert.runModal() == .alertFirstButtonReturn ? textField.stringValue : nil)
        }

        nonisolated func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(origin.host.contains(GeminiWebView.Constants.trustedHost) ? .grant : .prompt)
        }

        nonisolated func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @Sendable ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            panel.begin { [completionHandler] response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }

        private func isExternalURL(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            // Only Gemini-related domains stay in the app
            let internalHosts = ["gemini.google.com", "accounts.google.com"]
            let internalSuffixes = [".googleapis.com", ".gstatic.com"]

            if internalHosts.contains(host) { return false }
            for suffix in internalSuffixes {
                if host.hasSuffix(suffix) { return false }
            }
            return true
        }
    }
}

class WebViewContainer: NSView {
    let webView: WKWebView
    let coordinator: GeminiWebView.Coordinator
    private var windowObserverToken: (any Sendable)?

    init(webView: WKWebView, coordinator: GeminiWebView.Coordinator) {
        self.webView = webView
        self.coordinator = coordinator
        super.init(frame: .zero)
        autoresizesSubviews = true
        setupWindowObserver()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        let observer = windowObserverToken
        if let token = observer as? NSObjectProtocol {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func setupWindowObserver() {
        windowObserverToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let keyWindow = notification.object as? NSWindow,
                  self.window === keyWindow else { return }
            self.attachWebView()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && window?.isKeyWindow == true {
            attachWebView()
        }
    }

    override func layout() {
        super.layout()
        if webView.superview === self {
            webView.frame = bounds
        }
    }

    private func attachWebView() {
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        addSubview(webView)
    }
}


extension GeminiWebView {

    struct Constants {
        static let textFieldWidth: CGFloat = 200
        static let textFieldHeight: CGFloat = 24
        static let trustedHost = "google.com"
    }

}
