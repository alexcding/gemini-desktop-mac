//
//  GeminiWebView.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import WebKit

struct GeminiWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WebViewContainer {
        let container = WebViewContainer(webView: webView, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: WebViewContainer, context: Context) {
        if container.webView !== webView {
            container.swapWebView(to: webView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        private var downloadDestination: URL?

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if isExternalURL(url) {
                    NSWorkspace.shared.open(url)
                } else {
                    webView.load(URLRequest(url: url))
                }
            }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.canShowMIMEType {
                decisionHandler(.allow)
            } else {
                decisionHandler(.download)
            }
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            var destination = downloadsURL.appendingPathComponent(suggestedFilename)

            var counter = 1
            let fileManager = FileManager.default
            let nameWithoutExtension = destination.deletingPathExtension().lastPathComponent
            let fileExtension = destination.pathExtension

            while fileManager.fileExists(atPath: destination.path) {
                let newName = fileExtension.isEmpty
                    ? "\(nameWithoutExtension) (\(counter))"
                    : "\(nameWithoutExtension) (\(counter)).\(fileExtension)"
                destination = downloadsURL.appendingPathComponent(newName)
                counter += 1
            }

            downloadDestination = destination
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let destination = downloadDestination else { return }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            let alert = NSAlert()
            alert.messageText = "Download Failed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let alert = NSAlert()
            alert.messageText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: GeminiWebView.Constants.textFieldWidth, height: GeminiWebView.Constants.textFieldHeight))
            textField.stringValue = defaultText ?? ""
            alert.accessoryView = textField

            completionHandler(alert.runModal() == .alertFirstButtonReturn ? textField.stringValue : nil)
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(origin.host.contains(GeminiWebView.Constants.trustedHost) ? .grant : .prompt)
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }

        private func isExternalURL(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
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
    private(set) var webView: WKWebView
    let coordinator: GeminiWebView.Coordinator
    private var windowObserver: NSObjectProtocol?

    init(webView: WKWebView, coordinator: GeminiWebView.Coordinator) {
        self.webView = webView
        self.coordinator = coordinator
        super.init(frame: .zero)
        autoresizesSubviews = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Swaps the underlying webview. Used when WebViewModel rebuilds its
    /// WKWebView (e.g. on resume from inactivity suspension).
    func swapWebView(to newWebView: WKWebView) {
        guard webView !== newWebView else { return }
        if webView.superview === self {
            webView.removeFromSuperview()
        }
        webView = newWebView
        if window != nil {
            attachWebView()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Replace any prior observer with one scoped to the current window.
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
            windowObserver = nil
        }

        guard let window = window else { return }

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.attachWebView()
        }

        if window.isKeyWindow {
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
