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

    /// Message handler name for conversation started notification
    static let conversationStartedHandler = "conversationStarted"

    /// Creates all user scripts to be injected into the WebView
    static func createAllScripts() -> [WKUserScript] {
        var scripts: [WKUserScript] = [
            createConversationObserverScript(),
            createIMEFixScript()
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

    /// Creates a script that observes for conversation start and notifies Swift
    private static func createConversationObserverScript() -> WKUserScript {
        WKUserScript(
            source: conversationObserverSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    /// Creates the IME fix script that resolves the double-enter issue
    /// when using input method editors (e.g., Chinese, Japanese, Korean input)
    private static func createIMEFixScript() -> WKUserScript {
        WKUserScript(
            source: imeFixSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
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

    /// JavaScript to fix IME double-enter issue on Gemini
    /// When using IME (e.g., Chinese/Japanese input), pressing Enter after completing
    /// composition would require a second Enter to send. This script detects when
    /// IME composition just ended and automatically clicks the send button.
    /// https://update.greasyfork.org/scripts/532717/阻止Gemini两次点击.user.js
    private static let imeFixSource = """
    (function() {
        'use strict';

        // IME state tracking
        let imeActive = false;
        let imeJustEnded = false;
        let lastImeEndTime = 0;
        const IME_BUFFER_TIME = 300; // Response time after IME ends (milliseconds)

        // Check if IME input just finished
        function justFinishedImeInput() {
            return imeJustEnded || (Date.now() - lastImeEndTime < IME_BUFFER_TIME);
        }

        // Handle IME composition events
        document.addEventListener('compositionstart', function(e) {
            console.log('[IME Debug] compositionstart:', {
                data: e.data,
                target: e.target?.tagName,
                previousImeActive: imeActive
            });
            imeActive = true;
            imeJustEnded = false;
        }, true);

        document.addEventListener('compositionupdate', function(e) {
            console.log('[IME Debug] compositionupdate:', {
                data: e.data,
                target: e.target?.tagName
            });
        }, true);

        document.addEventListener('compositionend', function(e) {
            console.log('[IME Debug] compositionend:', {
                data: e.data,
                target: e.target?.tagName,
                previousImeActive: imeActive
            });
            imeActive = false;
            imeJustEnded = true;
            lastImeEndTime = Date.now();
            console.log('[IME Debug] IME ended, setting imeJustEnded=true, lastImeEndTime=' + lastImeEndTime);
            setTimeout(() => {
                imeJustEnded = false;
                console.log('[IME Debug] Buffer time expired, imeJustEnded reset to false');
            }, IME_BUFFER_TIME);
        }, true);

        // Find and click the send button
        function findAndClickSendButton() {
            console.log('[IME Debug] findAndClickSendButton called');
            const selectors = [
                'button[type="submit"]',
                'button.send-button',
                'button.submit-button',
                '[aria-label="发送"]',
                '[aria-label="Send"]',
                'button:has(svg[data-icon="paper-plane"])',
                '#send-button',
            ];

            for (const selector of selectors) {
                const buttons = document.querySelectorAll(selector);
                console.log('[IME Debug] Checking selector:', selector, 'found:', buttons.length);
                for (const button of buttons) {
                    const isVisible = button.offsetParent !== null;
                    const isDisplayed = getComputedStyle(button).display !== 'none';
                    console.log('[IME Debug] Button check:', {
                        selector: selector,
                        disabled: button.disabled,
                        isVisible: isVisible,
                        isDisplayed: isDisplayed,
                        classList: button.className,
                        ariaLabel: button.getAttribute('aria-label')
                    });
                    if (button &&
                        !button.disabled &&
                        isVisible &&
                        isDisplayed) {
                        console.log('[IME Debug] Clicking button:', button);
                        button.click();
                        return true;
                    }
                }
            }

            // Fallback: try form submission
            const activeElement = document.activeElement;
            console.log('[IME Debug] No button found, trying form submission. Active element:', activeElement?.tagName);
            if (activeElement && (activeElement.tagName === 'TEXTAREA' || activeElement.tagName === 'INPUT')) {
                const form = activeElement.closest('form');
                if (form) {
                    console.log('[IME Debug] Found form, dispatching submit event');
                    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
                    return true;
                }
            }

            console.log('[IME Debug] No send button or form found');
            return false;
        }

        // Listen for Enter key
        document.addEventListener('keydown', function(e) {
            // Only log Enter key events to reduce noise
            if (e.key === 'Enter' || e.keyCode === 13) {
                console.log('[IME Debug] Enter keydown:', {
                    shiftKey: e.shiftKey,
                    ctrlKey: e.ctrlKey,
                    altKey: e.altKey,
                    imeActive: imeActive
                });
            }

            // Submit on Enter (but not Shift+Enter for new line, and not during IME composition)
            if ((e.key === 'Enter' || e.keyCode === 13) &&
                !e.shiftKey && !e.ctrlKey && !e.altKey &&
                !imeActive) {
                console.log('[IME Debug] Enter detected, attempting to click send button');
                if (findAndClickSendButton()) {
                    console.log('[IME Debug] Send button clicked successfully');
                    e.stopImmediatePropagation();
                    e.preventDefault();
                    return false;
                } else {
                    console.log('[IME Debug] Failed to find/click send button');
                }
            }
        }, true);

        // Enhance input elements
        function enhanceInputElement(input) {
            console.log('[IME Debug] Enhancing input element:', input.tagName, input.id, input.className);
            const originalKeyDown = input.onkeydown;

            input.onkeydown = function(e) {
                // Submit on Enter (but not Shift+Enter, and not during IME)
                if ((e.key === 'Enter' || e.keyCode === 13) &&
                    !e.shiftKey && !e.ctrlKey && !e.altKey &&
                    !imeActive) {
                    console.log('[IME Debug] Enhanced input: Enter detected');
                    if (findAndClickSendButton()) {
                        console.log('[IME Debug] Enhanced input: Send button clicked');
                        e.stopPropagation();
                        e.preventDefault();
                        return false;
                    }
                }
                if (originalKeyDown) return originalKeyDown.call(this, e);
            };
        }

        // Process existing and new input elements
        function processInputElements() {
            document.querySelectorAll('textarea, input[type="text"]').forEach(enhanceInputElement);
        }

        // Initial processing after page load
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', function() {
                setTimeout(processInputElements, 1000);
            });
        } else {
            setTimeout(processInputElements, 1000);
        }

        // Monitor DOM changes for new input elements
        if (window.MutationObserver) {
            const observer = new MutationObserver((mutations) => {
                mutations.forEach((mutation) => {
                    if (mutation.addedNodes && mutation.addedNodes.length > 0) {
                        mutation.addedNodes.forEach((node) => {
                            if (node.nodeType === 1) {
                                if (node.tagName === 'TEXTAREA' ||
                                    (node.tagName === 'INPUT' && node.type === 'text')) {
                                    enhanceInputElement(node);
                                }

                                const inputs = node.querySelectorAll ?
                                    node.querySelectorAll('textarea, input[type="text"]') : [];
                                if (inputs.length > 0) {
                                    inputs.forEach(enhanceInputElement);
                                }
                            }
                        });
                    }
                });
            });

            observer.observe(document.body, {
                childList: true,
                subtree: true
            });
        }
    })();
    """

    /// JavaScript to observe when a conversation starts and notify Swift
    private static let conversationObserverSource = """
    (function() {
        const handler = '\(conversationStartedHandler)';
        const targetSelector = 'infinite-scroller[data-test-id="chat-history-container"]';
        let notified = false;

        function checkAndNotify() {
            if (notified) return;
            const scroller = document.querySelector(targetSelector);
            if (!scroller) return;
            const hasContent = scroller.querySelector('response-container') !== null
                            || scroller.querySelector('[aria-label="Good response"]') !== null
                            || scroller.querySelector('[aria-label="Bad response"]') !== null;
            if (hasContent) {
                notified = true;
                window.webkit.messageHandlers[handler].postMessage(true);
            }
        }

        const observer = new MutationObserver(checkAndNotify);
        observer.observe(document.body, { childList: true, subtree: true });
        checkAndNotify();
    })();
    """
}
