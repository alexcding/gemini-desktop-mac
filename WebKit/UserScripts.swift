//
//  UserScripts.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-15.
//

import WebKit

/// Collection of user scripts injected into WKWebView
enum UserScripts {

    /// Message handler name for console log bridging
    static let consoleLogHandler = "consoleLog"

    /// Message handler name for conversation state push updates
    static let conversationStateHandler = "conversationState"

    /// Creates all user scripts to be injected into the WebView
    static func createAllScripts() -> [WKUserScript] {
        var scripts: [WKUserScript] = [
            createIMEFixScript(),
            createConversationObserverScript()
        ]

        #if DEBUG
        scripts.insert(createConsoleLogBridgeScript(), at: 0)
        #endif

        return scripts
    }

    /// Creates a script that bridges console.log to native Swift
    private static func createConsoleLogBridgeScript() -> WKUserScript {
        WKUserScript(
            source: consoleLogBridgeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// Creates the IME fix script that resolves the double-enter issue
    /// when using input method editors (e.g., Chinese, Japanese, Korean input)
    private static func createIMEFixScript() -> WKUserScript {
        WKUserScript(
            source: imeFixSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    /// Creates a MutationObserver-based script that pushes conversation
    /// state changes to native code (replaces a 1Hz JS poll).
    private static func createConversationObserverScript() -> WKUserScript {
        WKUserScript(
            source: conversationObserverSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    // MARK: - Script Sources

    /// JavaScript to bridge console.log to native Swift via WKScriptMessageHandler
    private static let consoleLogBridgeSource = """
    (function() {
        const originalLog = console.log;
        console.log = function(...args) {
            originalLog.apply(console, args);
            try {
                const message = args.map(arg => {
                    if (typeof arg === 'object') {
                        return JSON.stringify(arg, null, 2);
                    }
                    return String(arg);
                }).join(' ');
                window.webkit.messageHandlers.\(consoleLogHandler).postMessage(message);
            } catch (e) {}
        };
    })();
    """

    /// JavaScript to fix IME Enter issue on Gemini
    private static let imeFixSource = """
    (function() {
        'use strict';

        let imeActive = false;
        let imeEverUsed = false;
        let compositionEndTime = 0;
        const BUFFER_TIME = 300;

        function isInIMEWindow() {
            return imeActive || (Date.now() - compositionEndTime < BUFFER_TIME);
        }

        document.addEventListener('compositionstart', function() {
            imeActive = true;
            imeEverUsed = true;
        }, true);

        document.addEventListener('compositionend', function() {
            imeActive = false;
            compositionEndTime = Date.now();
        }, true);

        document.addEventListener('keydown', function(e) {
            if (!imeEverUsed) return;
            if (e.key !== 'Enter' || e.shiftKey || e.ctrlKey || e.altKey) return;

            if (isInIMEWindow() || e.isComposing || e.keyCode === 229) {
                e.stopImmediatePropagation();
                e.preventDefault();
            }
        }, true);

        document.addEventListener('beforeinput', function(e) {
            if (!imeEverUsed) return;
            if (e.inputType !== 'insertParagraph' && e.inputType !== 'insertLineBreak') return;

            if (isInIMEWindow()) {
                e.stopImmediatePropagation();
                e.preventDefault();
            }
        }, true);
    })();
    """

    /// Pushes conversation state to native via MutationObserver instead of polling.
    /// Posts `{ inConversation: Bool }` only on transitions.
    private static let conversationObserverSource = """
    (function() {
        'use strict';
        let lastState = null;
        let scheduled = false;

        function isInConv() {
            const scroller = document.querySelector('infinite-scroller[data-test-id="chat-history-container"]');
            if (!scroller) return false;
            if (scroller.querySelector('response-container') !== null) return true;
            if (scroller.querySelector('[aria-label="Good response"], [aria-label="Bad response"]') !== null) return true;
            return false;
        }

        function publish() {
            const state = isInConv();
            if (state === lastState) return;
            lastState = state;
            try {
                window.webkit.messageHandlers.\(conversationStateHandler).postMessage({ inConversation: state });
            } catch (e) {}
        }

        function schedule() {
            if (scheduled) return;
            scheduled = true;
            setTimeout(function() { scheduled = false; publish(); }, 100);
        }

        const observer = new MutationObserver(schedule);

        function start() {
            if (!document.body) return;
            observer.observe(document.body, { childList: true, subtree: true });
            publish();
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', start, { once: true });
        } else {
            start();
        }

        // SPA navigations don't reload the page; re-check on history changes.
        const origPush = history.pushState;
        const origReplace = history.replaceState;
        history.pushState = function() { origPush.apply(this, arguments); schedule(); };
        history.replaceState = function() { origReplace.apply(this, arguments); schedule(); };
        window.addEventListener('popstate', schedule);
    })();
    """
}
