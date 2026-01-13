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
    var webViewModel = WebViewModel()

    var openWindowAction: ((String) -> Void)?

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

    // MARK: - Zoom

    func zoomIn() { webViewModel.zoomIn() }
    func zoomOut() { webViewModel.zoomOut() }
    func resetZoom() { webViewModel.resetZoom() }

    // MARK: - Main Window Management
    
    /// Toggles the main window - if visible, hide it; if hidden, show it
    func toggleMainWindow() {
        guard let window = findMainWindow() else {
            // Window doesn't exist, open it
            openMainWindow()
            return
        }
        
        if window.isVisible {
            // Window is visible, hide it
            window.orderOut(nil)
        } else {
            // Window is hidden, show it
            openMainWindow()
        }
    }

    func openMainWindow(on targetScreen: NSScreen? = nil) {
        let hideDockIcon = UserDefaults.standard.bool(forKey: UserDefaultsKeys.hideDockIcon.rawValue)
        if !hideDockIcon {
            NSApp.setActivationPolicy(.regular)
        }

        // Find existing main window (may be hidden/suppressed)
        let mainWindow = findMainWindow()

        if let window = mainWindow {
            // Window exists - show it
            if let screen = targetScreen {
                centerWindow(window, on: screen)
            }
            window.makeKeyAndOrderFront(nil)
            // Apply always on top setting
            let alwaysOnTop = UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTop.rawValue)
            setAlwaysOnTop(alwaysOnTop)
            // Focus the input field
            focusGeminiInput()
        } else if let openWindowAction = openWindowAction {
            // Window doesn't exist yet - use SwiftUI openWindow to create it
            openWindowAction("main")
            // Position newly created window with retry mechanism
            if let screen = targetScreen {
                centerNewlyCreatedWindow(on: screen)
            }
            // Apply always on top setting with slight delay to ensure window exists
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                let alwaysOnTop = UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTop.rawValue)
                self?.setAlwaysOnTop(alwaysOnTop)
                // Focus the input field after window is ready
                self?.focusGeminiInput()
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }
    
    /// Focuses the Gemini chat input field
    func focusGeminiInput() {
        let focusScript = """
            (function() {
                const input = document.querySelector('rich-textarea[aria-label="Enter a prompt here"]') ||
                              document.querySelector('[contenteditable="true"]') ||
                              document.querySelector('textarea');
                if (input) {
                    input.focus();
                    return true;
                }
                return false;
            })();
            """
        
        webViewModel.wkWebView.evaluateJavaScript(focusScript, completionHandler: nil)
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
            } else if attempt < maxAttempts {
                // Window not found yet, retry
                self.centerNewlyCreatedWindow(on: screen, attempt: attempt + 1)
            }
        }
    }
    func setAlwaysOnTop(_ enable: Bool) {
        // Use a slight delay to ensure the window is fully initialized
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, let window = self.findMainWindow() else { return }
            
            if enable {
                // Set window level to floating (above normal windows)
                window.level = .floating
                // Ensure window can join all spaces and stays visible
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            } else {
                window.level = .normal
                window.collectionBehavior = [.fullScreenAuxiliary]
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
