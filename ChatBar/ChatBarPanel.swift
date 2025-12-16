//
//  ChatBar.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit
import WebKit

class ChatBarPanel: NSPanel, NSWindowDelegate {

    private var initialSize: NSSize {
        let width = UserDefaults.standard.double(forKey: UserDefaultsKeys.panelWidth.rawValue)
        let height = UserDefaults.standard.double(forKey: UserDefaultsKeys.panelHeight.rawValue)
        return NSSize(
            width: width > 0 ? width : Constants.defaultWidth,
            height: height > 0 ? height : Constants.defaultHeight
        )
    }

    // Expanded height: 70% of screen height or initial height, whichever is larger
    private var expandedHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(screenHeight * Constants.expandedScreenRatio, initialSize.height)
    }

    private var isExpanded = false
    private var pollingTimer: Timer?
    private weak var webView: WKWebView?

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
        let width = UserDefaults.standard.double(forKey: UserDefaultsKeys.panelWidth.rawValue)
        let height = UserDefaults.standard.double(forKey: UserDefaultsKeys.panelHeight.rawValue)
        let initWidth = width > 0 ? width : Constants.defaultWidth
        let initHeight = height > 0 ? height : Constants.defaultHeight

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

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.webViewSearchDelay) { [weak self] in
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

        minSize = NSSize(width: Constants.minWidth, height: Constants.minHeight)
        maxSize = NSSize(width: Constants.maxWidth, height: Constants.maxHeight)

        // Add global click monitor to dismiss when clicking outside
        setupClickOutsideMonitor()
    }

    private var clickOutsideMonitor: Any?

    private func setupClickOutsideMonitor() {
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, self.isVisible else { return }
            self.orderOut(nil)
        }
    }

    private func configureAppearance() {
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false

        if let contentView = contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = Constants.cornerRadius
            contentView.layer?.masksToBounds = true
            contentView.layer?.borderWidth = Constants.borderWidth
            contentView.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    private func startPolling() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.initialPollingDelay) { [weak self] in
            self?.pollingTimer = Timer.scheduledTimer(withTimeInterval: Constants.pollingInterval, repeats: true) { [weak self] _ in
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

        let currentFrame = self.frame

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Constants.animationDuration
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
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        // Only persist size when in initial (non-expanded) state
        guard !isExpanded else { return }

        UserDefaults.standard.set(frame.width, forKey: UserDefaultsKeys.panelWidth.rawValue)
        UserDefaults.standard.set(frame.height, forKey: UserDefaultsKeys.panelHeight.rawValue)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}


extension ChatBarPanel {

    struct Constants {
        static let defaultWidth: CGFloat = 500
        static let defaultHeight: CGFloat = 200
        static let minWidth: CGFloat = 300
        static let minHeight: CGFloat = 150
        static let maxWidth: CGFloat = 900
        static let maxHeight: CGFloat = 900
        static let cornerRadius: CGFloat = 30
        static let borderWidth: CGFloat = 0.5
        static let expandedScreenRatio: CGFloat = 0.7
        static let animationDuration: Double = 0.3
        static let pollingInterval: TimeInterval = 1.0
        static let initialPollingDelay: TimeInterval = 3.0
        static let webViewSearchDelay: TimeInterval = 0.5

    }
}
