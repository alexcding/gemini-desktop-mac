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
    var webViewModel = WebViewModel()

    var openWindowAction: ((String) -> Void)?
    var alwaysOnTop: Bool = UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTop.rawValue)

    var canGoBack: Bool { webViewModel.canGoBack }
    var canGoForward: Bool { webViewModel.canGoForward }

    init() {
        // Observe notifications for window opening
        NotificationCenter.default.addObserver(forName: .openMainWindow, object: nil, queue: .main) { [weak self] _ in
            self?.openMainWindow()
        }
    }

    // MARK: - Navigation

    func goBack() { webViewModel.goBack() }
    func goForward() { webViewModel.goForward() }
    func goHome() { webViewModel.loadHome() }
    func reload() { webViewModel.reload() }
    func openNewChat() { webViewModel.openNewChat() }
    func openTemporaryChat() { webViewModel.openTemporaryChat() }

    // MARK: - Zoom

    func zoomIn() { webViewModel.zoomIn() }
    func zoomOut() { webViewModel.zoomOut() }
    func resetZoom() { webViewModel.resetZoom() }

    // MARK: - Always on Top

    func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        UserDefaults.standard.set(alwaysOnTop, forKey: UserDefaultsKeys.alwaysOnTop.rawValue)
        applyAlwaysOnTop()
    }

    func applyAlwaysOnTop() {
        let level: NSWindow.Level = alwaysOnTop ? .floating : .normal

        // Apply to main window
        if let mainWindow = findMainWindow() {
            mainWindow.level = level
        }

        // Chat bar panel is always floating by design
    }

    // MARK: - Chat Bar

    func showChatBar() {
        // Resume WebView if suspended by inactivity (starts loading before window appears)
        webViewModel.resumeIfSuspended()

        // Hide main window when showing chat bar
        closeMainWindow()

        let position = PanelPosition.current

        if let bar = chatBar {
            // Reposition unless "Remember last position" is selected
            if position != .rememberLast {
                positionChatBar(bar, position: position)
            }
            bar.makeKeyAndOrderFront(nil)
            bar.checkAndAdjustSize()
            return
        }

        let contentView = ChatBarView(
            webViewModel: webViewModel,
            onExpandToMain: { [weak self] in
                self?.expandToMainWindow()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        let bar = ChatBarPanel(contentView: hostingView, webViewModel: webViewModel)

        // Position based on setting
        positionChatBar(bar, position: position)

        bar.makeKeyAndOrderFront(nil)
        chatBar = bar
    }

    /// Positions the chat bar based on the given position setting
    private func positionChatBar(_ bar: ChatBarPanel, position: PanelPosition) {
        guard let screen = NSScreen.screenAtMouseLocation() ?? NSScreen.main else { return }

        if position == .rememberLast {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: UserDefaultsKeys.panelX.rawValue) != nil,
               defaults.object(forKey: UserDefaultsKeys.panelY.rawValue) != nil {
                let saved = NSPoint(x: defaults.double(forKey: UserDefaultsKeys.panelX.rawValue),
                                    y: defaults.double(forKey: UserDefaultsKeys.panelY.rawValue))
                let center = NSPoint(x: saved.x + bar.frame.width / 2, y: saved.y + bar.frame.height / 2)
                if NSScreen.screenStrictly(containing: center) != nil {
                    bar.setFrameOrigin(saved)
                    return
                }
            }
        }

        let origin = screen.point(for: bar.frame.size, position: position, dockOffset: Constants.dockOffset)
        bar.setFrameOrigin(origin)
    }

    /// Repositions the chat bar to its configured position
    func resetChatBarPosition() {
        guard let bar = chatBar else { return }
        positionChatBar(bar, position: PanelPosition.current)
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

    /// Captures selected text from the frontmost app, then shows the chat bar
    /// with that text inserted into the composer.
    func showChatBarWithSelection() {
        SelectionCapture.captureSelectedText { [weak self] selection in
            guard let self = self else { return }
            self.showChatBar()
            if let text = selection, !text.isEmpty {
                self.webViewModel.insertTextIntoComposer(text)
            }
        }
    }

    func expandToMainWindow() {
        // Capture the screen where the chat bar is located before hiding it
        let targetScreen = chatBar.flatMap { bar -> NSScreen? in
            let center = NSPoint(x: bar.frame.midX, y: bar.frame.midY)
            return NSScreen.screen(containing: center)
        } ?? NSScreen.main

        hideChatBar()
        openMainWindow(on: targetScreen)
    }

    func openMainWindow(on targetScreen: NSScreen? = nil) {
        // Resume WebView if suspended by inactivity (starts loading before window appears)
        webViewModel.resumeIfSuspended()

        // Hide chat bar first - WebView can only be in one view hierarchy
        hideChatBar()

        let hideDockIcon = UserDefaults.standard.bool(forKey: UserDefaultsKeys.hideDockIcon.rawValue)
        if !hideDockIcon {
            NSApp.setActivationPolicy(.regular)
        }

        // Find existing main window (may be hidden/suppressed)
        let mainWindow = findMainWindow()

        if let window = mainWindow {
            // Window exists - show it (works for suppressed windows too)
            if let screen = targetScreen {
                centerWindow(window, on: screen)
            }
            window.makeKeyAndOrderFront(nil)
        } else if let openWindowAction = openWindowAction {
            // Window doesn't exist yet - use SwiftUI openWindow to create it
            openWindowAction("main")
            // Position newly created window with retry mechanism
            if let screen = targetScreen {
                centerNewlyCreatedWindow(on: screen)
            }
        }

        applyAlwaysOnTop()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Finds the main window by identifier or title
    private func findMainWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue == Constants.mainWindowIdentifier || $0.title == Constants.mainWindowTitle
        }
    }

    /// Centers a window on the specified screen
    private func centerWindow(_ window: NSWindow, on screen: NSScreen) {
        let origin = screen.centerPoint(for: window.frame.size)
        window.setFrameOrigin(origin)
    }

    /// Centers a newly created window on the target screen with retry mechanism
    private func centerNewlyCreatedWindow(on screen: NSScreen, attempt: Int = 1) {
        let maxAttempts = 5
        let retryDelay = 0.05 // 50ms between attempts

        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self = self else { return }

            if let window = self.findMainWindow() {
                self.centerWindow(window, on: screen)
                self.applyAlwaysOnTop()
            } else if attempt < maxAttempts {
                // Window not found yet, retry
                self.centerNewlyCreatedWindow(on: screen, attempt: attempt + 1)
            }
        }
    }
}


extension AppCoordinator {

    struct Constants {
        static let dockOffset: CGFloat = 50
        static let mainWindowIdentifier = "main"
        static let mainWindowTitle = "Gemini Desktop"
    }

}
