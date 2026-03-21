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

    /// Message handler name for file input clicked notification
    static let fileInputClickedHandler = "fileInputClicked"

    /// Message handler name for debug network payload capture
    static let debugNetworkCaptureHandler = "debugNetworkCapture"

    /// Creates all user scripts to be injected into the WebView
    nonisolated static func createAllScripts() -> [WKUserScript] {
        var scripts: [WKUserScript] = [
            createConversationObserverScript(),
            createIMEFixScript(),
            createFilePickerScript()
        ]

        #if DEBUG
        scripts.insert(createConsoleLogBridgeScript(), at: 0)
        #endif

        return scripts
    }

    /// Creates a script that bridges console.log to native Swift
    nonisolated private static func createConsoleLogBridgeScript() -> WKUserScript {
        WKUserScript(
            source: consoleLogBridgeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// Creates a script that observes for conversation start and notifies Swift
    nonisolated private static func createConversationObserverScript() -> WKUserScript {
        WKUserScript(
            source: conversationObserverSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    /// Creates the IME fix script that resolves the double-enter issue
    /// when using input method editors (e.g., Chinese, Japanese, Korean input)
    nonisolated private static func createIMEFixScript() -> WKUserScript {
        WKUserScript(
            source: imeFixSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
    }

    /// Creates a script that intercepts file input clicks and routes them through
    /// the native file picker bridge.
    nonisolated private static func createFilePickerScript() -> WKUserScript {
        WKUserScript(
            source: filePickerSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    /// Creates a script that extracts conversation metadata from the Gemini DOM.
    /// Returns a JSON string. Each field is individually wrapped in try/catch.
    /// All extraction expressions are sourced from GeminiSelectors.shared.metadata
    /// (user-patchable via gemini-selectors.json — no recompile needed for selector updates).
    /// GeminiSelectors.shared is backed by a static let — safe from nonisolated context.
    nonisolated static func createMetadataScript() -> String {
        let entries = GeminiSelectors.shared.metadata
        var blocks: [String] = []

        for (key, expr) in entries {
            let exprs = expr.expressions
            let isArrayField = key == "attachments"  // only array-valued field in current schema
            if exprs.count == 1 {
                blocks.append(singleExprBlock(key: key, expr: exprs[0], isArrayField: isArrayField))
            } else {
                blocks.append(multiExprBlock(key: key, exprs: exprs))
            }
        }

        return """
        (function() {
            var result = {};
            \(blocks.joined(separator: "\n    "))
            return JSON.stringify(result);
        })();
        """
    }

    /// Generates a JS try/catch block that evaluates one expression and assigns to result[key].
    /// isArrayField: if true, skips the empty-string check (arrays are never empty strings).
    /// On catch, sets result[key] to null (scalar) or [] (array).
    nonisolated private static func singleExprBlock(key: String, expr: String, isArrayField: Bool) -> String {
        if isArrayField {
            return """
            try { result["\(key)"] = (\(expr)); } catch(e) { result["\(key)"] = []; }
            """
        } else {
            return """
            try { var _v = (\(expr)); result["\(key)"] = (_v !== null && _v !== undefined && _v !== '') ? _v : null; } catch(e) { result["\(key)"] = null; }
            """
        }
    }

    /// Generates an IIFE that tries each expression in order, assigning the first
    /// non-null non-empty result to result[key]. Falls through to null if all fail.
    nonisolated private static func multiExprBlock(key: String, exprs: [String]) -> String {
        var lines: [String] = ["(function() {"]
        for expr in exprs {
            lines.append("""
                try { var _v = (\(expr)); if (_v !== null && _v !== undefined && _v !== '') { result["\(key)"] = _v; return; } } catch(e) {}
            """)
        }
        lines.append("""
            result["\(key)"] = null;
        })();
        """)
        return lines.joined(separator: "\n")
    }

    /// Generates the metadataProbe JS — one IIFE per metadata field.
    /// Uses eval (safe: evaluateJavaScript bypasses page CSP; expressions come from GeminiSelectors, not page).
    /// Array-valued fields (attachments) use JSON.stringify for the value.
    nonisolated private static func metadataProbeBlocks() -> String {
        let entries = GeminiSelectors.shared.metadata
        var blocks: [String] = []

        for (key, expr) in entries {
            let exprs = expr.expressions
            let isArrayField = key == "attachments"
            // Build JS array literal of expression strings, escaping backslashes and double quotes
            let jsExprs = exprs.map { e -> String in
                let escaped = e
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }.joined(separator: ", ")

            let valueExpr = isArrayField
                ? "JSON.stringify(_v).slice(0, 120)"
                : "String(_v).slice(0, 120)"
            let nullCheck = isArrayField
                ? "_v !== null && _v !== undefined"
                : "_v !== null && _v !== undefined && _v !== ''"

            blocks.append("""
            (function() {
                var field = "\(key)";
                var exprs = [\(jsExprs)];
                for (var i = 0; i < exprs.length; i++) {
                    try {
                        var _v = eval(exprs[i]);
                        if (\(nullCheck)) {
                            metadataProbe.push({ field: field, matchedIndex: i, value: \(valueExpr) });
                            return;
                        }
                    } catch(e) {}
                }
                metadataProbe.push({ field: field, matchedIndex: null, value: null });
            })();
            """)
        }

        return blocks.joined(separator: "\n")
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

    /// JavaScript that intercepts hidden file input clicks and routes them to
    /// the native NSOpenPanel via WKScriptMessageHandler.
    ///
    /// Flow: input.click() intercept → postMessage → Swift NSOpenPanel
    ///   → evaluateJavaScript callback → fetch(gemini-file://) → DataTransfer → input.files
    private static let filePickerSource = """
    (function() {
        window.__GeminiDesktop = window.__GeminiDesktop || {};

        var pendingFileInput = null;
        var pendingNonce = null;

        // Intercept programmatic clicks on hidden file inputs.
        // WKWebView drops these silently (gesture token expired by the time
        // Gemini's async code calls click()). We route them native instead.
        var origClick = HTMLInputElement.prototype.click;
        HTMLInputElement.prototype.click = function() {
            if (this.type === 'file') {
                pendingFileInput = this;
                pendingNonce = Math.random().toString(36).slice(2);
                window.webkit.messageHandlers.\(fileInputClickedHandler).postMessage({
                    multiple: this.multiple,
                    accept: this.accept || '',
                    nonce: pendingNonce
                });
            } else {
                origClick.call(this);
            }
        };

        // Called by Swift after NSOpenPanel completes.
        // fileDataArray: array of {name, type, data} objects with base64-encoded data,
        // or empty on cancel. Data is passed via callAsyncJavaScript (not fetch) to
        // bypass Gemini's Content-Security-Policy connect-src restrictions.
        window.__GeminiDesktop.filesSelectedWithData = function(nonce, fileDataArray) {
            if (nonce !== pendingNonce) { return; } // stale response from a previous picker
            var input = pendingFileInput;
            pendingFileInput = null;
            pendingNonce = null;
            if (!input || !fileDataArray || !fileDataArray.length) { return; }

            try {
                var dt = new DataTransfer();
                fileDataArray.forEach(function(fd) {
                    var binary = atob(fd.data);
                    var bytes = new Uint8Array(binary.length);
                    for (var i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
                    dt.items.add(new File([bytes.buffer], fd.name, { type: fd.type }));
                });
                input.files = dt.files; // supported in WebKit via DataTransfer
                input.dispatchEvent(new Event('change', { bubbles: true }));
                input.dispatchEvent(new Event('input', { bubbles: true }));
            } catch (err) {
                console.error('[GeminiDesktop] File data error:', err);
            }
        };
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

    // MARK: - Prompt Injection

    nonisolated static func createInjectionScript(escapedText: String, richTextareaSelector: String) -> String {
        """
        (function() {
            const textarea = document.querySelector('\(richTextareaSelector)');
            if (!textarea) return false;

            try {
                const text = '\(escapedText)';
                if (document.execCommand('insertText', false, text)) {
                    return true;
                }

                // Fallback: use InputEvent
                const dt = new DataTransfer();
                dt.items.add(new File([text], 'paste', { type: 'text/plain' }));
                const pasteEvent = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true });
                textarea.dispatchEvent(pasteEvent);

                const inputEvent = new InputEvent('input', { data: text, bubbles: true, inputType: 'insertText' });
                textarea.dispatchEvent(inputEvent);
                return true;
            } catch (e) {
                return false;
            }
        })();
        """
    }

    // MARK: - Artifact Capture

    nonisolated static func createCaptureScript(lastResponseSelector: String) -> String {
        """
        (function() {
            // Check if still streaming — look for structural CSS class (language-agnostic)
            const isStreaming = document.querySelector('button.send-button.stop') !== null;

            if (isStreaming) {
                return '__streaming__';
            }

            const responseEl = document.querySelector('\(lastResponseSelector)');
            return responseEl ? responseEl.innerHTML : '';
        })();
        """
    }

    // MARK: - Debug Capture Scripts

    /// DOM capture: selector probe + all data-test-id elements + structural data-ved/jsaction nodes.
    /// selectorJSON: JSON string of { fieldName: cssSelector } pairs built by AppCoordinator.
    nonisolated static func createDOMCaptureScript(selectorJSON: String) -> String {
        """
        (function() {
            try {
                var selectors = \(selectorJSON);

                // 1. Selector probe — hit/miss + element details for each field
                var selectorProbe = Object.keys(selectors).map(function(field) {
                    var sel = selectors[field];
                    var el = document.querySelector(sel);
                    return {
                        field: field,
                        selector: sel,
                        found: el !== null,
                        tag: el ? el.tagName : null,
                        classes: el ? (el.className || '').toString().slice(0, 100) : null,
                        dataTestId: el ? el.getAttribute('data-test-id') : null,
                        ariaLabel: el ? el.getAttribute('aria-label') : null,
                        textSnippet: el ? el.textContent.trim().slice(0, 80) : null
                    };
                });

                // 2. All visible data-test-id elements (primary lookup table for replacements)
                var dataTestIds = Array.from(document.querySelectorAll('[data-test-id]'))
                    .filter(function(el) { return el.offsetParent !== null; })
                    .map(function(el) {
                        return {
                            tag: el.tagName,
                            dataTestId: el.getAttribute('data-test-id'),
                            ariaLabel: el.getAttribute('aria-label'),
                            text: el.textContent.trim().slice(0, 60)
                        };
                    });

                // 3. Structural Wiz elements, capped at 200
                var structural = Array.from(document.querySelectorAll('[data-ved], [jsaction]'))
                    .slice(0, 200)
                    .map(function(el) {
                        return {
                            tag: el.tagName,
                            classes: (el.className || '').toString().slice(0, 80),
                            dataVed: el.getAttribute('data-ved'),
                            jsaction: (el.getAttribute('jsaction') || '').slice(0, 100),
                            jscontroller: el.getAttribute('jscontroller')
                        };
                    });

                // 4. Metadata expression probe
                var metadataProbe = [];
                \(metadataProbeBlocks())

                return JSON.stringify({
                    selectorProbe: selectorProbe,
                    dataTestIds: dataTestIds,
                    structural: structural,
                    metadataProbe: metadataProbe
                });
            } catch(e) {
                return JSON.stringify({ error: e.message });
            }
        })();
        """
    }

    /// WIZ state capture: serializes window.WIZ_global_data.
    nonisolated static func createWIZCaptureScript() -> String {
        """
        (function() {
            try {
                return JSON.stringify(window.WIZ_global_data || {});
            } catch(e) {
                return JSON.stringify({ error: e.message });
            }
        })();
        """
    }

    /// Fetch interceptor — injected at document start when debug mode is on.
    /// Passively buffers batchexecute payloads and posts them to the
    /// 'debugNetworkCapture' WKScriptMessageHandler.
    nonisolated static func createFetchInterceptorScript() -> String {
        """
        (function() {
            if (window.__GeminiDesktopDebugIntercepted) return;
            window.__GeminiDesktopDebugIntercepted = true;
            var originalFetch = window.fetch;
            window.fetch = function() {
                var url = arguments[0];
                var options = arguments[1];
                if (url && url.toString().includes('/batchexecute') && options && options.body) {
                    try {
                        window.webkit.messageHandlers.\(debugNetworkCaptureHandler).postMessage({
                            url: url.toString(),
                            payload: options.body.toString().slice(0, 8000)
                        });
                    } catch(e) {}
                }
                return originalFetch.apply(this, arguments);
            };
        })();
        """
    }
}
