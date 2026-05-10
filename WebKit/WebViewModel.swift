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

/// Handles MutationObserver-driven conversation state pushes from the page
final class ConversationStateHandler: NSObject, WKScriptMessageHandler {
    weak var model: WebViewModel?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let inConversation = body["inConversation"] as? Bool else { return }
        DispatchQueue.main.async { [weak self] in
            self?.model?.handleConversationState(inConversation)
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

    /// The active web view. Reassigned on suspend/resume so that the WebContent
    /// process is fully released while the user is idle.
    private(set) var wkWebView: WKWebView
    private(set) var canGoBack: Bool = false
    private(set) var canGoForward: Bool = false
    private(set) var isAtHome: Bool = true
    private(set) var isLoading: Bool = true
    private(set) var isInConversation: Bool = false

    /// Called once when the page transitions from start-page → in-conversation.
    var onConversationStarted: (() -> Void)?

    // MARK: - Private Properties

    private var backObserver: NSKeyValueObservation?
    private var forwardObserver: NSKeyValueObservation?
    private var urlObserver: NSKeyValueObservation?
    private var loadingObserver: NSKeyValueObservation?
    private let consoleLogHandler = ConsoleLogHandler()
    private let conversationStateHandler = ConversationStateHandler()
    private var inactivityTimer: Timer?
    private(set) var isSuspended: Bool = false

    // MARK: - Initialization

    init() {
        self.wkWebView = Self.createFullWebView(
            consoleLogHandler: consoleLogHandler,
            conversationStateHandler: conversationStateHandler
        )
        conversationStateHandler.model = self
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

    /// Inserts text into the Gemini composer (rich-textarea / Quill contenteditable).
    /// Retries for a short window so it works even while the page is still loading.
    func insertTextIntoComposer(_ text: String) {
        guard let payload = try? JSONSerialization.data(withJSONObject: [text]),
              let jsonArray = String(data: payload, encoding: .utf8) else { return }

        let script = """
        (function(payload) {
            const text = payload[0];
            const MAX_TRIES = 40;
            const INTERVAL_MS = 75;
            let tries = 0;

            function findEditor() {
                const quill = document.querySelector('div.ql-editor[contenteditable="true"]');
                if (quill) return quill;
                const rich = document.querySelector('rich-textarea[aria-label="Enter a prompt here"]');
                if (rich) {
                    const inner = rich.querySelector('[contenteditable="true"]');
                    if (inner) return inner;
                }
                return document.querySelector('[contenteditable="true"]')
                    || document.querySelector('textarea');
            }

            function attempt() {
                const editor = findEditor();
                if (!editor) {
                    if (++tries < MAX_TRIES) setTimeout(attempt, INTERVAL_MS);
                    return;
                }
                editor.focus();
                if (editor.tagName === 'TEXTAREA' || editor.tagName === 'INPUT') {
                    const start = editor.selectionStart || 0;
                    const end = editor.selectionEnd || 0;
                    editor.value = editor.value.slice(0, start) + text + editor.value.slice(end);
                    editor.dispatchEvent(new Event('input', { bubbles: true }));
                    return;
                }
                try {
                    const dt = new DataTransfer();
                    dt.setData('text/plain', text);
                    const evt = new ClipboardEvent('paste', {
                        bubbles: true, cancelable: true, clipboardData: dt
                    });
                    const delivered = editor.dispatchEvent(evt);
                    if (delivered && !evt.defaultPrevented) {
                        document.execCommand('insertText', false, text);
                    }
                } catch (e) {
                    document.execCommand('insertText', false, text);
                }
            }
            attempt();
        })(\(jsonArray));
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

    /// Focuses the page's primary input field. Used by the chat bar on appearance.
    func focusComposer() {
        let script = """
        (function() {
            const input = document.querySelector('rich-textarea[aria-label="Enter a prompt here"]') ||
                          document.querySelector('[contenteditable="true"]') ||
                          document.querySelector('textarea');
            if (input) { input.focus(); }
        })();
        """
        wkWebView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Conversation State (push from JS)

    func handleConversationState(_ inConversation: Bool) {
        let wasInConversation = isInConversation
        isInConversation = inConversation
        if !wasInConversation && inConversation {
            onConversationStarted?()
        }
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
        // Tear down the WebContent process by replacing the WKWebView with a
        // minimal, unloaded instance. The previous instance (and its process)
        // is released as soon as no view holds it.
        teardownObservers()
        wkWebView.stopLoading()
        wkWebView.navigationDelegate = nil
        wkWebView.uiDelegate = nil
        wkWebView = Self.createIdleWebView()
        canGoBack = false
        canGoForward = false
        isAtHome = true
        isLoading = false
        isInConversation = false
    }

    func resumeIfSuspended() {
        resetInactivityTimer()
        guard isSuspended else { return }
        isSuspended = false
        wkWebView = Self.createFullWebView(
            consoleLogHandler: consoleLogHandler,
            conversationStateHandler: conversationStateHandler
        )
        setupObservers()
        loadHome()
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

    /// Builds a fully configured WKWebView with scripts, handlers, and saved zoom.
    private static func createFullWebView(
        consoleLogHandler: ConsoleLogHandler,
        conversationStateHandler: ConversationStateHandler
    ) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        for script in UserScripts.createAllScripts() {
            configuration.userContentController.addUserScript(script)
        }

        configuration.userContentController.add(conversationStateHandler, name: UserScripts.conversationStateHandler)

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

    /// Builds a minimal idle WKWebView used as a placeholder during suspension.
    /// No scripts, no handlers, no loaded URL — its WebContent process stays unspawned.
    private static func createIdleWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func teardownObservers() {
        backObserver?.invalidate()
        forwardObserver?.invalidate()
        urlObserver?.invalidate()
        loadingObserver?.invalidate()
        backObserver = nil
        forwardObserver = nil
        urlObserver = nil
        loadingObserver = nil
    }

    private func setupObservers() {
        teardownObservers()

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
