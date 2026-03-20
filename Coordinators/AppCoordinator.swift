//
//  AppCoordinator.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit
import WebKit
import Observation

@MainActor
@Observable
class AppCoordinator {
    enum CaptureProgress: Equatable {
        case started
        case converting
        case saving
        case completed(filename: String)
        case failed(error: String)      // persistent banner, shows "Open Log"
        case streaming                  // transient, auto-dismisses after 3s
    }

    private var chatBar: ChatBarPanel?
    var webViewModel = WebViewModel()
    let promptLibrary = PromptLibrary()

    var openWindowAction: ((String) -> Void)?
    private(set) var isInjecting: Bool = false
    private(set) var injectionBannerMessage: String? = nil
    private(set) var captureProgress: CaptureProgress? = nil

    var canGoBack: Bool { webViewModel.canGoBack }
    var canGoForward: Bool { webViewModel.canGoForward }

    init() {
        promptLibrary.reload()
        promptLibrary.startWatching()
    }

    // MARK: - Navigation

    func goBack() { webViewModel.goBack() }
    func goForward() { webViewModel.goForward() }
    func goHome() { webViewModel.loadHome() }
    func reload() { webViewModel.reload() }
    func openNewChat() { webViewModel.openNewChat() }

    // MARK: - Zoom

    func zoomIn() { webViewModel.zoomIn() }
    func zoomOut() { webViewModel.zoomOut() }
    func resetZoom() { webViewModel.resetZoom() }

    // MARK: - Window Management

    func updateActivationPolicy() {
        let hideDock = UserDefaults.standard.bool(forKey: UserDefaultsKeys.hideDockIcon.rawValue)
        NSApp.setActivationPolicy(hideDock ? .accessory : .regular)
    }

    // MARK: - Chat Bar

    func showChatBar() {
        // Hide main window when showing chat bar
        closeMainWindow()

        if let bar = chatBar {
            // Reuse existing chat bar - reposition to current mouse screen
            repositionChatBarToMouseScreen(bar)
            bar.orderFront(nil)
            bar.makeKeyAndOrderFront(nil)
            bar.checkAndAdjustSize()
            return
        }

        let contentView = ChatBarView(
            webView: webViewModel.wkWebView,
            onExpandToMain: { [weak self] in
                self?.expandToMainWindow()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        let bar = ChatBarPanel(
            contentView: hostingView,
            webView: webViewModel.wkWebView,
            onOpenNewChat: { [weak self] in
                self?.webViewModel.openNewChat()
            }
        )

        // Position at bottom center of the screen where mouse is located
        if let screen = NSScreen.screenAtMouseLocation() {
            let origin = screen.bottomCenterPoint(for: bar.frame.size, dockOffset: Constants.dockOffset)
            bar.setFrameOrigin(origin)
        }

        bar.orderFront(nil)
        bar.makeKeyAndOrderFront(nil)
        chatBar = bar
    }

    /// Repositions an existing chat bar to the screen containing the mouse cursor
    private func repositionChatBarToMouseScreen(_ bar: ChatBarPanel) {
        guard let screen = NSScreen.screenAtMouseLocation() else { return }
        let origin = screen.bottomCenterPoint(for: bar.frame.size, dockOffset: Constants.dockOffset)
        bar.setFrameOrigin(origin)
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
        // Capture the screen where the chat bar is located before hiding it
        let targetScreen = chatBar.flatMap { bar -> NSScreen? in
            let center = NSPoint(x: bar.frame.midX, y: bar.frame.midY)
            return NSScreen.screen(containing: center)
        } ?? NSScreen.main

        hideChatBar()
        openMainWindow(on: targetScreen)
    }

    func openMainWindow(on targetScreen: NSScreen? = nil) {
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
            // defaultWindowPlacement handles initial positioning
            openWindowAction("main")
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Finds the main window by identifier or title
    func findMainWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue == Constants.mainWindowIdentifier || $0.title == Constants.mainWindowTitle
        }
    }

    /// Centers a window on the specified screen
    private func centerWindow(_ window: NSWindow, on screen: NSScreen) {
        let origin = screen.centerPoint(for: window.frame.size)
        window.setFrameOrigin(origin)
    }

    // MARK: - Prompts & Artifacts

    func copyPromptToClipboard(_ file: PromptFile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.body, forType: .string)
    }

    func injectPrompt(_ file: PromptFile) {
        Task {
            guard !isInjecting else { return }
            isInjecting = true
            defer { isInjecting = false }

            do {
                try await waitForPageReady(timeout: 30)

                var textToInject = file.body
                if textToInject.count > 16_000 {
                    textToInject = String(textToInject.prefix(16_000))
                }

                let escaped = escapeForJavaScript(textToInject)
                let script = UserScripts.createInjectionScript(
                    escapedText: escaped,
                    richTextareaSelector: GeminiSelectors.shared.richTextareaSelector
                )

                webViewModel.wkWebView.evaluateJavaScript(script) { result, error in
                    if error != nil {
                        self.injectionBannerMessage = "Could not inject prompt into Gemini. Is it loaded?"
                    }
                }
            } catch {
                injectionBannerMessage = "Could not inject: \(error.localizedDescription)"
            }
        }
    }

    func captureLastResponse(suggestedFilename: String?) {
        Task {
            captureProgress = .started
            do {
                captureProgress = .converting
                let markdown = try await captureLastResponseAsString()

                captureProgress = .saving
                let filename = suggestedFilename?.isEmpty == false ? suggestedFilename! :
                    defaultArtifactFilename()
                await saveArtifact(markdown: markdown, filename: filename)
            } catch {
                captureProgress = .failed(error: error.localizedDescription)

                // Auto-dismiss error state after 3 seconds
                try? await Task.sleep(for: .seconds(3))
                self.captureProgress = nil
            }
        }
    }

    func captureLastResponseAsString() async throws -> String {
        try await waitForPageReady(timeout: 10)

        // Step 1: Extract raw HTML from the response element (<100ms, unblocks WebView)
        let script = UserScripts.createCaptureScript(lastResponseSelector: GeminiSelectors.shared.lastResponseSelector)
        let htmlString: String = try await withCheckedThrowingContinuation { continuation in
            webViewModel.wkWebView.evaluateJavaScript(script) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let html = result as? String {
                    if html == "__streaming__" {
                        continuation.resume(throwing: AppIntentError.stillStreaming)
                    } else if html.isEmpty {
                        continuation.resume(throwing: AppIntentError.noResponseAvailable)
                    } else {
                        continuation.resume(returning: html)
                    }
                } else {
                    continuation.resume(throwing: AppIntentError.noResponseAvailable)
                }
            }
        }

        // Step 2: Convert HTML to Markdown in background (100-500ms, off main thread)
        let markdown = await Task(priority: .userInitiated) {
            HTMLToMarkdown.convert(htmlString)
        }.value

        return markdown
    }

    func saveArtifact(markdown: String, filename: String) async {
        do {
            let savedFilename = try await performFileIO(markdown: markdown, filename: filename)
            captureProgress = .completed(filename: savedFilename)

            // Auto-dismiss success state after 2 seconds
            try await Task.sleep(for: .seconds(2))
            self.captureProgress = nil
        } catch {
            captureProgress = .failed(error: error.localizedDescription)

            // Auto-dismiss error state after 3 seconds
            try? await Task.sleep(for: .seconds(3))
            self.captureProgress = nil
        }
    }

    nonisolated private func performFileIO(markdown: String, filename: String) async throws -> String {
        return try await Task.detached(priority: .userInitiated) {
            let bookmarkStore = BookmarkStore()

            let finalURL = try bookmarkStore.withBookmarkedURL(for: .artifactsDirectoryBookmark) { dirURL in
                var url = dirURL.appendingPathComponent(filename, isDirectory: false)
                var counter = 1
                let maxRetries = 100

                while FileManager.default.fileExists(atPath: url.path) && counter < maxRetries {
                    let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                    var ext = URL(fileURLWithPath: filename).pathExtension
                    if ext.isEmpty {
                        ext = "md"
                    }
                    let newName = "\(stem)-\(counter).\(ext)"
                    url = dirURL.appendingPathComponent(newName, isDirectory: false)
                    counter += 1
                }

                if counter >= maxRetries {
                    throw AppIntentError.fileCollisionLimitExceeded
                }

                // Unconditionally prepend YAML header
                let iso8601 = ISO8601DateFormatter().string(from: Date())
                let header = "---\ncaptured_at: \(iso8601)\nsource: gemini.google.com\n---\n\n"
                let content = header + markdown

                try content.write(to: url, atomically: true, encoding: .utf8)
                return url
            }

            guard let url = finalURL else {
                throw AppIntentError.directoryUnavailable
            }

            return url.lastPathComponent
        }.value
    }

    func dismissInjectionBanner() {
        injectionBannerMessage = nil
    }

    func waitForPageReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)

        while !webViewModel.isPageReady {
            if Date() > deadline {
                throw AppIntentError.notAuthenticated
            }
            try await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
        }
    }

    private func escapeForJavaScript(_ text: String) -> String {
        var escaped = text
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "'", with: "\\'")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\0", with: "\\0")
        return escaped
    }

    func defaultArtifactFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Gemini-\(formatter.string(from: Date())).md"
    }

}


extension AppCoordinator {

    struct Constants {
        static let dockOffset: CGFloat = 50
        static let mainWindowIdentifier = "main"
        static let mainWindowTitle = "Gemini Desktop"
    }

}
