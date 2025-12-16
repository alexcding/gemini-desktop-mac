//
//  AppCoordinator.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit
import WebKit

extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}

@Observable
class AppCoordinator {
    private var chatBar: ChatBarPanel?
    var geminiWebView = GeminiWebView()

    var openWindowAction: ((String) -> Void)?

    var canGoBack: Bool { geminiWebView.canGoBack }
    var canGoForward: Bool { geminiWebView.canGoForward }

    init() {
        // Observe notifications for window opening
        NotificationCenter.default.addObserver(forName: .openMainWindow, object: nil, queue: .main) { [weak self] _ in
            self?.openMainWindow()
        }
    }

    // MARK: - Navigation

    func goBack() { geminiWebView.goBack() }
    func goForward() { geminiWebView.goForward() }
    func goHome() { geminiWebView.loadHome() }
    func reload() { geminiWebView.reload() }

    // MARK: - Zoom

    func zoomIn() { geminiWebView.zoomIn() }
    func zoomOut() { geminiWebView.zoomOut() }
    func resetZoom() { geminiWebView.resetZoom() }

    // MARK: - Chat Bar

    func showChatBar() {
        // Hide main window when showing chat bar
        closeMainWindow()

        if let bar = chatBar {
            // Reuse existing chat bar
            bar.orderFront(nil)
            bar.makeKeyAndOrderFront(nil)
            bar.checkAndAdjustSize()
            return
        }

        let contentView = ChatBarView(
            webView: geminiWebView.wkWebView,
            onExpandToMain: { [weak self] in
                self?.expandToMainWindow()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        let bar = ChatBarPanel(contentView: hostingView)

        // Position at bottom center, above the dock
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let barSize = bar.frame.size
            let x = screenRect.origin.x + (screenRect.width - barSize.width) / 2
            let y = screenRect.origin.y + Constants.dockOffset
            bar.setFrameOrigin(NSPoint(x: x, y: y))
        }

        bar.orderFront(nil)
        bar.makeKeyAndOrderFront(nil)
        chatBar = bar
    }

    func hideChatBar() {
        chatBar?.orderOut(nil)
    }

    func closeMainWindow() {
        // Find and hide the main window
        for window in NSApp.windows {
            if window.identifier?.rawValue == Constants.mainWindowIdentifier || window.title == Constants.mainWindowTitle {
                if !(window is NSPanel) {
                    window.orderOut(nil)
                }
            }
        }
    }

    func toggleChatBar() {
        if let bar = chatBar, bar.isVisible {
            hideChatBar()
        } else {
            showChatBar()
        }
    }

    func expandToMainWindow() {
        hideChatBar()
        openMainWindow()
    }

    func openMainWindow() {
        // Hide chat bar first - WebView can only be in one view hierarchy
        hideChatBar()

        let hideDockIcon = UserDefaults.standard.bool(forKey: UserDefaultsKeys.hideDockIcon.rawValue)
        if !hideDockIcon {
            NSApp.setActivationPolicy(.regular)
        }

        // Find existing main window (may be hidden/suppressed)
        let mainWindow = NSApp.windows.first(where: {
            $0.identifier?.rawValue == Constants.mainWindowIdentifier || $0.title == Constants.mainWindowTitle
        })

        if let window = mainWindow {
            // Window exists - show it (works for suppressed windows too)
            window.makeKeyAndOrderFront(nil)
        } else if let openWindowAction = openWindowAction {
            // Window doesn't exist yet - use SwiftUI openWindow to create it
            openWindowAction("main")
        }

        NSApp.activate(ignoringOtherApps: true)
    }
}


extension AppCoordinator {

    struct Constants {
        static let dockOffset: CGFloat = 50
        static let mainWindowIdentifier = "main"
        static let mainWindowTitle = "Gemini Desktop"
    }

}
