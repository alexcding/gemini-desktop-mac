//
//  WebViewModel.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-15.
//

import AppKit
import WebKit
import Combine

/// Handles console.log messages from JavaScript
class ConsoleLogHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? String {
            print("[WebView] \(body)")
        }
    }
}

/// Observable wrapper around WKWebView with Gemini-specific functionality
@Observable
class WebViewModel {

    // MARK: - Constants

    static let geminiURL = URL(string: "https://gemini.google.com/app")!
    static let defaultPageZoom: Double = 1.0

    private static let geminiHost = "gemini.google.com"
    private static let geminiAppPath = "/app"
    private static var userAgent: String { UserAgentOption.currentUserAgentString }
    private static let minZoom: Double = 0.6
    private static let maxZoom: Double = 1.4
    private static let inactivityTimeout: TimeInterval = 10 * 60 // 10 minutes

    // MARK: - Public Properties

    let wkWebView: WKWebView
    private(set) var canGoBack: Bool = false
    private(set) var canGoForward: Bool = false
    private(set) var isAtHome: Bool = true
    private(set) var isLoading: Bool = true

    // MARK: - Private Properties

    private var backObserver: NSKeyValueObservation?
    private var forwardObserver: NSKeyValueObservation?
    private var urlObserver: NSKeyValueObservation?
    private var loadingObserver: NSKeyValueObservation?
    private let consoleLogHandler = ConsoleLogHandler()
    private var inactivityTimer: Timer?
    private(set) var isSuspended: Bool = false

    // MARK: - Initialization

    init() {
        self.wkWebView = Self.createWebView(consoleLogHandler: consoleLogHandler)
        setupObservers()
        loadHome()
        resetInactivityTimer()
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

    // MARK: - Inactivity Suspension

    func resetInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: Self.inactivityTimeout, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.suspendIfInactive() }
        }
    }

    private func suspendIfInactive() {
        guard !isSuspended else { return }
        // Don't suspend while any regular app window is visible to the user.
        // Exclude menu bar extra windows (they sit at statusBar level and above,
        // and are always "visible" even when the app is hidden).
        if NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized && $0.level <= .floating }) {
            resetInactivityTimer()
            return
        }
        isSuspended = true
        wkWebView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    func resumeIfSuspended() {
        resetInactivityTimer()
        guard isSuspended else { return }
        isSuspended = false
        loadHome()
    }

    func openNewChat() {
        let script = """
        (function() {
            const event = new KeyboardEvent('keydown', {
                key: 'o',
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

    func openTemporaryChat() {
        let script = """
        (function() {
            const TEMP_CHAT_SELECTORS = [
                '[data-test-id="temp-chat-button"]',
                'button[aria-label*="Temporary chat" i]',
                '[data-test-id="temporary-chat"]'
            ];
            const SIDEBAR_SELECTORS = [
                'button[aria-label*="Main menu" i]',
                'button[aria-label*="Open sidebar" i]',
                'button[aria-label*="sidebar" i]',
                'button[data-test-id="side-nav-toggle"]'
            ];

            function findFirst(selectors) {
                for (const sel of selectors) {
                    try {
                        const el = document.querySelector(sel);
                        if (el) return el;
                    } catch(e) {}
                }
                return null;
            }

            function waitForElement(selectors, timeoutMs) {
                return new Promise(function(resolve) {
                    const found = findFirst(selectors);
                    if (found) { resolve(found); return; }
                    let resolved = false;
                    const observer = new MutationObserver(function() {
                        const el = findFirst(selectors);
                        if (el && !resolved) {
                            resolved = true;
                            observer.disconnect();
                            resolve(el);
                        }
                    });
                    observer.observe(document.body, { childList: true, subtree: true });
                    setTimeout(function() {
                        if (!resolved) {
                            resolved = true;
                            observer.disconnect();
                            resolve(null);
                        }
                    }, timeoutMs);
                });
            }

            function clickTemporaryChat(button, closeMenu) {
                button.click();
                if (closeMenu) {
                    setTimeout(function() {
                        const sidebar = findFirst(SIDEBAR_SELECTORS);
                        if (sidebar) sidebar.click();
                    }, 100);
                }
            }

            if (document.activeElement instanceof HTMLElement) {
                document.activeElement.blur();
            }

            const button = findFirst(TEMP_CHAT_SELECTORS);
            if (button) {
                clickTemporaryChat(button, false);
                return;
            }

            const sidebar = findFirst(SIDEBAR_SELECTORS);
            if (!sidebar) { return; }

            sidebar.click();
            waitForElement(TEMP_CHAT_SELECTORS, 500).then(function(btn) {
                if (!btn) { return; }
                clickTemporaryChat(btn, true);
            });
        })();
        """
        wkWebView.evaluateJavaScript(script, completionHandler: nil)
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

    func applyUserAgent() {
        let newUA = Self.userAgent
        guard wkWebView.customUserAgent != newUA else { return }
        wkWebView.customUserAgent = newUA
        wkWebView.reload()
    }

    // MARK: - Private Setup

    private static func createWebView(consoleLogHandler: ConsoleLogHandler) -> WKWebView {
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
        webView.allowsMagnification = true
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

        loadingObserver = wkWebView.observe(\.isLoading, options: [.new, .initial]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                self?.isLoading = webView.isLoading
            }
        }

        urlObserver = wkWebView.observe(\.url, options: .new) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let currentURL = webView.url else { return }

                // Reset inactivity timer on real navigation, not on the suspend blank load
                if currentURL.absoluteString != "about:blank" && !self.isSuspended {
                    self.resetInactivityTimer()
                }

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
