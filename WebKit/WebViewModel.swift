//
//  WebViewModel.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-15.
//

import WebKit
import Combine
import UniformTypeIdentifiers

/// Handles console.log messages from JavaScript
@MainActor
class ConsoleLogHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? String {
            print("[WebView] \(body)")
        }
    }
}

/// Receives fileInputClicked messages from JS, presents NSOpenPanel, and
/// passes file data back to JS via callAsyncJavaScript (bypasses CSP).
@MainActor
final class FilePickerHandler: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
    }

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let multiple = body["multiple"] as? Bool,
              let rawNonce = body["nonce"] as? String else { return }
        let nonce = rawNonce.filter { $0.isLetter || $0.isNumber }
        guard !nonce.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // `accept` attribute from the file input is intentionally ignored —
        // Gemini uses accept="" (unrestricted) and NSOpenPanel type filtering
        // requires non-trivial MIME wildcard → UTType conversion.

        panel.begin { [weak self] response in
            guard let self, let webView = self.webView else { return }
            var fileDataArray: [[String: String]] = []
            if response == .OK {
                for url in panel.urls {
                    guard let data = try? Data(contentsOf: url) else { continue }
                    fileDataArray.append([
                        "name": url.lastPathComponent,
                        "type": self.mimeType(for: url),
                        "data": data.base64EncodedString()
                    ])
                }
            }
            webView.callAsyncJavaScript(
                "window.__GeminiDesktop.filesSelectedWithData(nonce, files)",
                arguments: ["nonce": nonce, "files": fileDataArray],
                in: nil,
                in: .page,
                completionHandler: nil
            )
        }
    }

    private func mimeType(for url: URL) -> String {
        guard let utType = UTType(filenameExtension: url.pathExtension),
              let mime = utType.preferredMIMEType else { return "application/octet-stream" }
        return mime
    }
}

/// Buffers batchexecute payloads captured by the fetch interceptor script.
/// Added to WKUserContentController only when debug mode is on at launch.
@MainActor
final class DebugNetworkHandler: NSObject, WKScriptMessageHandler {
    private let maxBufferSize = 20
    private(set) var payloadBuffer: [[String: String]] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        let entry: [String: String] = [
            "url": body["url"] as? String ?? "",
            "payload": body["payload"] as? String ?? ""
        ]
        payloadBuffer.append(entry)
        if payloadBuffer.count > maxBufferSize {
            payloadBuffer.removeFirst()
        }
    }
}

/// Tracks navigation state for page readiness
@MainActor
class WebViewNavigationDelegate: NSObject, WKNavigationDelegate {
    var onPageReady: (() -> Void)?
    var onNavigationStart: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onPageReady?()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        onNavigationStart?()
    }
}

/// Observable wrapper around WKWebView with Gemini-specific functionality
@MainActor
@Observable
class WebViewModel {

    // MARK: - Constants

    static let geminiURL = URL(string: "https://gemini.google.com/app")!
    static let defaultPageZoom: Double = 1.0

    private static let geminiHost = "gemini.google.com"
    private static let geminiAppPath = "/app"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let minZoom: Double = 0.6
    private static let maxZoom: Double = 1.4

    // MARK: - Public Properties

    let wkWebView: WKWebView
    private(set) var canGoBack: Bool = false
    private(set) var canGoForward: Bool = false
    private(set) var isAtHome: Bool = true
    private(set) var isPageReady: Bool = false

    var networkPayloadBuffer: [[String: String]] {
        debugNetworkHandler?.payloadBuffer ?? []
    }

    // MARK: - Private Properties

    private var backObserver: NSKeyValueObservation?
    private var forwardObserver: NSKeyValueObservation?
    private var urlObserver: NSKeyValueObservation?
    private let consoleLogHandler = ConsoleLogHandler()
    private let navigationDelegate = WebViewNavigationDelegate()
    private let filePickerHandler: FilePickerHandler
    private let debugNetworkHandler: DebugNetworkHandler?

    // MARK: - Initialization

    init() {
        let webView = Self.createWebView(consoleLogHandler: consoleLogHandler)
        let filePickerHandler = FilePickerHandler(webView: webView)

        self.wkWebView = webView
        self.filePickerHandler = filePickerHandler

        // Initialize debugNetworkHandler before any closure captures self — Swift requires
        // all stored `let` properties to be set before self can appear in closures.
        let debugModeEnabled = UserDefaults.standard.bool(
            forKey: UserDefaultsKeys.debugModeEnabled.rawValue
        )
        if debugModeEnabled {
            let handler = DebugNetworkHandler()
            self.debugNetworkHandler = handler
            webView.configuration.userContentController.add(
                handler,
                name: UserScripts.debugNetworkCaptureHandler
            )
            let interceptorScript = WKUserScript(
                source: UserScripts.createFetchInterceptorScript(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            webView.configuration.userContentController.addUserScript(interceptorScript)
        } else {
            self.debugNetworkHandler = nil
        }

        // Register file picker message handler after WebView exists
        webView.configuration.userContentController.add(
            filePickerHandler,
            name: UserScripts.fileInputClickedHandler
        )

        self.wkWebView.navigationDelegate = navigationDelegate

        navigationDelegate.onPageReady = { [weak self] in
            self?.isPageReady = true
        }
        navigationDelegate.onNavigationStart = { [weak self] in
            self?.isPageReady = false
        }

        setupObservers()
        loadHome()
    }

    // MARK: - Navigation

    func loadHome() {
        isAtHome = true
        canGoBack = false
        wkWebView.load(URLRequest(url: Self.geminiURL))
    }

    func goBack() {
        isAtHome = false
        wkWebView.goBack()
    }

    func goForward() {
        wkWebView.goForward()
    }

    func reload() {
        wkWebView.reload()
    }

    func openNewChat() {
        let script = """
        (function() {
            const event = new KeyboardEvent('keydown', {
                key: 'O',
                code: 'KeyO',
                keyCode: 79,
                which: 79,
                shiftKey: true,
                metaKey: true,
                bubbles: true,
                cancelable: true,
                composed: true
            });
            document.activeElement.dispatchEvent(event);
            document.dispatchEvent(event);
        })();
        """
        wkWebView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Response Capture

    func isStreamingResponse() async -> Bool {
        let script = """
        (function() {
            return document.querySelector("button[aria-label='Stop response']") !== null;
        })();
        """

        do {
            if let result = try await wkWebView.evaluateJavaScript(script) as? NSNumber {
                return result.boolValue
            }
        } catch {
            return false
        }
        return false
    }

    // MARK: - Zoom

    func zoomIn() {
        let newZoom = min((wkWebView.pageZoom * 100 + 1).rounded() / 100, Self.maxZoom)
        setZoom(newZoom)
    }

    func zoomOut() {
        let newZoom = max((wkWebView.pageZoom * 100 - 1).rounded() / 100, Self.minZoom)
        setZoom(newZoom)
    }

    func resetZoom() {
        setZoom(Self.defaultPageZoom)
    }

    private func setZoom(_ zoom: Double) {
        wkWebView.pageZoom = zoom
        UserDefaults.standard.set(zoom, forKey: UserDefaultsKeys.pageZoom.rawValue)
    }

    // MARK: - Private Setup

    private static func createWebView(
        consoleLogHandler: ConsoleLogHandler
    ) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Add user scripts
        for script in UserScripts.createAllScripts() {
            configuration.userContentController.addUserScript(script)
        }

        // Register console log message handler (debug only)
        #if DEBUG
        configuration.userContentController.add(consoleLogHandler, name: UserScripts.consoleLogHandler)
        #endif

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.customUserAgent = userAgent
        #if DEBUG
        webView.isInspectable = true
        #endif

        let savedZoom = UserDefaults.standard.double(forKey: UserDefaultsKeys.pageZoom.rawValue)
        webView.pageZoom = savedZoom > 0 ? savedZoom : defaultPageZoom

        return webView
    }

    private func setupObservers() {
        backObserver = wkWebView.observe(\.canGoBack, options: [.new, .initial]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.canGoBack = !self.isAtHome && webView.canGoBack
            }
        }

        forwardObserver = wkWebView.observe(\.canGoForward, options: [.new, .initial]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.canGoForward = webView.canGoForward
            }
        }

        urlObserver = wkWebView.observe(\.url, options: .new) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let currentURL = webView.url else { return }

                let isGeminiApp = currentURL.host == Self.geminiHost &&
                                  currentURL.path.hasPrefix(Self.geminiAppPath)

                if isGeminiApp {
                    self.isAtHome = true
                    self.canGoBack = false
                } else {
                    self.isAtHome = false
                    self.canGoBack = webView.canGoBack
                }
            }
        }
    }
}
