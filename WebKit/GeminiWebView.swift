//
//  GeminiWebView.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-15.
//

import WebKit
import Combine

/// Observable wrapper around WKWebView with Gemini-specific functionality
@Observable
class GeminiWebView {

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

    // MARK: - Private Properties

    private var backObserver: NSKeyValueObservation?
    private var forwardObserver: NSKeyValueObservation?
    private var urlObserver: NSKeyValueObservation?

    // MARK: - Initialization

    init() {
        self.wkWebView = Self.createWebView()
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

    private static func createWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        for script in UserScripts.createAllScripts() {
            configuration.userContentController.addUserScript(script)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.customUserAgent = userAgent

        let savedZoom = UserDefaults.standard.double(forKey: UserDefaultsKeys.pageZoom.rawValue)
        webView.pageZoom = savedZoom > 0 ? savedZoom : defaultPageZoom

        return webView
    }

    private func setupObservers() {
        backObserver = wkWebView.observe(\.canGoBack, options: [.new, .initial]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.canGoBack = !self.isAtHome && webView.canGoBack
            }
        }

        forwardObserver = wkWebView.observe(\.canGoForward, options: [.new, .initial]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.canGoForward = webView.canGoForward
            }
        }

        urlObserver = wkWebView.observe(\.url, options: .new) { [weak self] webView, _ in
            DispatchQueue.main.async {
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
