//
//  ChatBar.swift
//  GeminiMac
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit
import WebKit

class ChatBar: NSPanel, NSWindowDelegate {

    private static let defaultWidth: CGFloat = 500
    private static let defaultHeight: CGFloat = 200

    private var initialSize: NSSize {
        let width = UserDefaults.standard.double(forKey: "panelWidth")
        let height = UserDefaults.standard.double(forKey: "panelHeight")
        return NSSize(
            width: width > 0 ? width : Self.defaultWidth,
            height: height > 0 ? height : Self.defaultHeight
        )
    }

    // Expanded height: 70% of screen height or initial height, whichever is larger
    private var expandedHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(screenHeight * 0.7, initialSize.height)
    }

    private var isExpanded = false
    private var pollingTimer: Timer?
    private weak var webView: WKWebView?
    var onExpandedChange: ((Bool) -> Void)?

    // Returns true if in a conversation (not on start page)
    private let checkConversationScript = """
        (function() {
            const scroller = document.querySelector('infinite-scroller[data-test-id="chat-history-container"]');
            if (!scroller) { return false; }
            const hasResponseContainer = scroller.querySelector('response-container') !== null;
            const hasRatingButtons = scroller.querySelector('[aria-label="Good response"], [aria-label="Bad response"]') !== null;
            return hasResponseContainer || hasRatingButtons;
        })();
        """

    init(contentView: NSView) {
        let width = UserDefaults.standard.double(forKey: "panelWidth")
        let height = UserDefaults.standard.double(forKey: "panelHeight")
        let initWidth = width > 0 ? width : Self.defaultWidth
        let initHeight = height > 0 ? height : Self.defaultHeight

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: initWidth, height: initHeight),
            styleMask: [
                .nonactivatingPanel,
                .resizable,
                .borderless
            ],
            backing: .buffered,
            defer: false
        )

        self.contentView = contentView
        self.delegate = self

        configureWindow()
        configureAppearance()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, let content = self.contentView else { return }
            self.findWebView(in: content)
            print("[ChatBar] WebView found: \(self.webView != nil)")
            self.startPolling()
        }
    }

    private func findWebView(in view: NSView) {
        if let wk = view as? WKWebView {
            self.webView = wk
            return
        }
        for subview in view.subviews {
            findWebView(in: subview)
        }
    }

    private func configureWindow() {
        isFloatingPanel = true
        level = .floating
        isMovable = true
        isMovableByWindowBackground = true

        collectionBehavior.insert(.fullScreenAuxiliary)
        collectionBehavior.insert(.canJoinAllSpaces)

        minSize = NSSize(width: 300, height: 150)
        maxSize = NSSize(width: 900, height: 900)
    }

    private func configureAppearance() {
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false

        if let contentView = contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 30
            contentView.layer?.masksToBounds = true
            contentView.layer?.borderWidth = 0.5
            contentView.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    private func startPolling() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkForConversation()
            }
        }
    }

    private func checkForConversation() {
        guard !isExpanded else { return }
        guard let webView = webView else { return }

        webView.evaluateJavaScript(checkConversationScript) { [weak self] result, _ in
            if let inConversation = result as? Bool, inConversation {
                DispatchQueue.main.async {
                    self?.expandToNormalSize()
                }
            }
        }
    }

    private func expandToNormalSize() {
        guard !isExpanded else { return }
        isExpanded = true
        pollingTimer?.invalidate()
        onExpandedChange?(true)

        let currentFrame = self.frame

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            let newFrame = NSRect(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y,
                width: currentFrame.width,
                height: self.expandedHeight
            )
            self.animator().setFrame(newFrame, display: true)
        }
    }

    func resetToInitialSize() {
        isExpanded = false
        pollingTimer?.invalidate()
        onExpandedChange?(false)

        let currentFrame = frame

        setFrame(NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y,
            width: currentFrame.width,
            height: initialSize.height
        ), display: true)

        startPolling()
    }

    /// Called when panel is shown - check if we should be expanded or initial size
    func checkAndAdjustSize() {
        guard let webView = webView else { return }

        webView.evaluateJavaScript(checkConversationScript) { [weak self] result, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let inConversation = result as? Bool, inConversation {
                    // In conversation - ensure expanded
                    if !self.isExpanded {
                        self.expandToNormalSize()
                    }
                } else {
                    // On start page - ensure initial size
                    if self.isExpanded {
                        self.resetToInitialSize()
                    }
                }
            }
        }
    }

    deinit {
        pollingTimer?.invalidate()
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        // Only persist size when in initial (non-expanded) state
        guard !isExpanded else { return }

        UserDefaults.standard.set(frame.width, forKey: "panelWidth")
        UserDefaults.standard.set(frame.height, forKey: "panelHeight")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
