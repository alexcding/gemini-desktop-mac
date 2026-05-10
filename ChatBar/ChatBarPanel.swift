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

    /// Returns the screen where this panel is currently located
    private var currentScreen: NSScreen? {
        let panelCenter = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screen(containing: panelCenter)
    }

    // Expanded height: 70% of screen height or initial height, whichever is larger
    private var expandedHeight: CGFloat {
        let screenHeight = currentScreen?.visibleFrame.height ?? 800
        return max(screenHeight * Constants.expandedScreenRatio, initialSize.height)
    }

    private var isExpanded = false
    private var positionSaveWork: DispatchWorkItem?
    private var sizeSaveWork: DispatchWorkItem?
    private weak var webViewModel: WebViewModel?

    init(contentView: NSView, webViewModel: WebViewModel) {
        let width = UserDefaults.standard.double(forKey: UserDefaultsKeys.panelWidth.rawValue)
        let height = UserDefaults.standard.double(forKey: UserDefaultsKeys.panelHeight.rawValue)
        let initWidth = width > 0 ? width : Constants.defaultWidth
        let initHeight = height > 0 ? height : Constants.defaultHeight

        self.webViewModel = webViewModel

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

        // Replace the 1Hz JS poll with a push from the page's MutationObserver.
        webViewModel.onConversationStarted = { [weak self] in
            self?.expandToNormalSize()
        }
    }

    private func configureWindow() {
        isFloatingPanel = true
        level = .floating
        isMovable = true
        isMovableByWindowBackground = false

        collectionBehavior.insert(.fullScreenAuxiliary)
        collectionBehavior.insert(.canJoinAllSpaces)

        minSize = NSSize(width: Constants.minWidth, height: Constants.minHeight)
        maxSize = NSSize(width: Constants.maxWidth, height: Constants.maxHeight)

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

    private func expandToNormalSize() {
        guard !isExpanded else { return }
        isExpanded = true

        let currentFrame = self.frame

        guard let screen = currentScreen else { return }
        let visibleFrame = screen.visibleFrame
        let maxAvailableHeight = visibleFrame.maxY - currentFrame.origin.y

        let targetHeight = min(self.expandedHeight, maxAvailableHeight - Constants.topPadding)
        let clampedHeight = max(targetHeight, initialSize.height)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Constants.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            let newFrame = NSRect(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y,
                width: currentFrame.width,
                height: clampedHeight
            )
            self.animator().setFrame(newFrame, display: true)
        }
    }

    func resetToInitialSize() {
        isExpanded = false

        let currentFrame = frame

        setFrame(NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y,
            width: currentFrame.width,
            height: initialSize.height
        ), display: true)
    }

    /// Called when panel is shown - check if we should be expanded or initial size
    func checkAndAdjustSize() {
        webViewModel?.focusComposer()

        let inConversation = webViewModel?.isInConversation ?? false
        if inConversation {
            if !isExpanded { expandToNormalSize() }
        } else {
            if isExpanded { resetToInitialSize() }
        }
    }

    deinit {
        positionSaveWork?.cancel()
        sizeSaveWork?.cancel()
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        guard !isExpanded else { return }

        // Debounce: a single drag fires dozens of resize events.
        sizeSaveWork?.cancel()
        let size = frame.size
        let work = DispatchWorkItem {
            UserDefaults.standard.set(size.width, forKey: UserDefaultsKeys.panelWidth.rawValue)
            UserDefaults.standard.set(size.height, forKey: UserDefaultsKeys.panelHeight.rawValue)
        }
        sizeSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.sizeSaveDebounce, execute: work)
    }

    func windowDidMove(_ notification: Notification) {
        guard PanelPosition.current == .rememberLast else { return }
        positionSaveWork?.cancel()
        let origin = frame.origin
        let work = DispatchWorkItem {
            UserDefaults.standard.set(origin.x, forKey: UserDefaultsKeys.panelX.rawValue)
            UserDefaults.standard.set(origin.y, forKey: UserDefaultsKeys.panelY.rawValue)
        }
        positionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.positionSaveDebounce, execute: work)
    }

    // MARK: - Keyboard Handling

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) &&
           !event.modifierFlags.contains(.shift) &&
           !event.modifierFlags.contains(.option) &&
           event.charactersIgnoringModifiers == "n" {
            openNewChat()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func openNewChat() {
        guard let webView = webViewModel?.wkWebView else { return }
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
        webView.evaluateJavaScript(script) { [weak self] _, _ in
            self?.resetToInitialSize()
        }
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
        static let topPadding: CGFloat = 20
        static let positionSaveDebounce: TimeInterval = 0.3
        static let sizeSaveDebounce: TimeInterval = 0.3
    }
}
