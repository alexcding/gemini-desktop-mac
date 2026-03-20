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

    func captureLastResponse(suggestedFilename: String?, previewMetadata: ArtifactMetadata) {
        Task {
            captureProgress = .started
            do {
                captureProgress = .converting
                let markdown = try await captureResponseMarkdown()
                captureProgress = .saving
                let filename = suggestedFilename?.isEmpty == false
                    ? suggestedFilename!
                    : defaultArtifactFilename()
                await saveArtifact(markdown: markdown, metadata: previewMetadata, filename: filename)
            } catch AppIntentError.stillStreaming {
                // Streaming is transient — no log entry, no "Open Log" button
                captureProgress = .streaming
                try? await Task.sleep(for: .seconds(3))
                self.captureProgress = nil
            } catch AppIntentError.notAuthenticated {
                // Page not ready — transient user state, not a system error, no log entry
                captureProgress = .failed(error: AppIntentError.notAuthenticated.localizedDescription)
                try? await Task.sleep(for: .seconds(3))
                self.captureProgress = nil
            } catch {
                ArtifactLogger.logError(error)
                captureProgress = .failed(error: error.localizedDescription)
                // No auto-dismiss — persistent banner, dismissed by user via ×
            }
        }
    }

    /// Extracts the last Gemini response as Markdown.
    /// Runs HTML extraction on @MainActor (evaluateJavaScript), then converts
    /// HTML→Markdown on a background task. Does not fetch metadata.
    func captureResponseMarkdown() async throws -> String {
        try await waitForPageReady(timeout: 10)

        let script = UserScripts.createCaptureScript(
            lastResponseSelector: GeminiSelectors.shared.lastResponseSelector
        )
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

        return await Task(priority: .userInitiated) {
            HTMLToMarkdown.convert(htmlString)
        }.value
    }

    /// Fetches conversation metadata from the DOM. Never throws.
    /// Returns partial metadata (Swift-side fields only) if the page is not ready
    /// or the JS extraction fails.
    func fetchMetadataPreview() async -> ArtifactMetadata {
        var metadata = ArtifactMetadata.empty()
        guard webViewModel.isPageReady else { return metadata }

        let script = UserScripts.createMetadataScript()
        return await withCheckedContinuation { continuation in
            webViewModel.wkWebView.evaluateJavaScript(script) { result, _ in
                guard let jsonString = result as? String,
                      !jsonString.isEmpty,
                      let data = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continuation.resume(returning: metadata)
                    return
                }

                metadata.conversationUrl = json["conversation_url"] as? String
                metadata.conversationId = json["conversation_id"] as? String
                metadata.conversationTitle = json["conversation_title"] as? String
                metadata.responseIndex = json["response_index"] as? Int
                metadata.geminiModel = json["gemini_model"] as? String
                metadata.request = json["request"] as? String
                metadata.attachments = json["attachments"] as? [String] ?? []
                metadata.webkitVersion = json["webkit_version"] as? String
                metadata.jscVersion = json["jsc_version"] as? String

                continuation.resume(returning: metadata)
            }
        }
    }

    func saveArtifact(markdown: String, metadata: ArtifactMetadata, filename: String) async {
        do {
            let savedFilename = try await performFileIO(
                markdown: markdown, metadata: metadata, filename: filename
            )
            captureProgress = .completed(filename: savedFilename)
            try await Task.sleep(for: .seconds(2))
            self.captureProgress = nil
        } catch {
            ArtifactLogger.logError(error, context: [
                "filename_attempted": filename,
                "conversation_url": metadata.conversationUrl ?? ""
            ])
            captureProgress = .failed(error: error.localizedDescription)
            // No auto-dismiss — persistent banner, dismissed by user via ×
        }
    }

    nonisolated private func performFileIO(
        markdown: String,
        metadata: ArtifactMetadata,
        filename: String
    ) async throws -> String {
        return try await Task.detached(priority: .userInitiated) {
            let content = metadata.toYAMLFrontmatter() + markdown
            let bookmarkStore = BookmarkStore()

            // Priority 1: user-configured bookmark directory
            if let savedFilename = try bookmarkStore.withBookmarkedURL(
                for: .artifactsDirectoryBookmark
            ) { dirURL in
                let url = try AppCoordinator.resolveUniqueURL(in: dirURL, filename: filename)
                try content.write(to: url, atomically: true, encoding: .utf8)
                return url.lastPathComponent
            } {
                return savedFilename
            }

            // Priority 2: ~/Downloads/Artifacts (entitlement-based, no bookmark needed)
            let downloadsArtifacts = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/Artifacts", isDirectory: true)
            try FileManager.default.createDirectory(
                at: downloadsArtifacts, withIntermediateDirectories: true
            )
            let url = try AppCoordinator.resolveUniqueURL(in: downloadsArtifacts, filename: filename)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url.lastPathComponent
        }.value
    }

    func dismissInjectionBanner() {
        injectionBannerMessage = nil
    }

    func dismissCaptureProgress() {
        captureProgress = nil
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

    /// Returns a unique file URL inside dirURL by appending -1, -2, … suffixes until no collision.
    nonisolated private static func resolveUniqueURL(in dirURL: URL, filename: String) throws -> URL {
        var url = dirURL.appendingPathComponent(filename, isDirectory: false)
        var counter = 1
        let maxRetries = 100

        while FileManager.default.fileExists(atPath: url.path) && counter < maxRetries {
            let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            var ext = URL(fileURLWithPath: filename).pathExtension
            if ext.isEmpty { ext = "md" }
            url = dirURL.appendingPathComponent("\(stem)-\(counter).\(ext)", isDirectory: false)
            counter += 1
        }

        if counter >= maxRetries {
            throw AppIntentError.fileCollisionLimitExceeded
        }

        return url
    }

}


extension AppCoordinator {

    struct Constants {
        static let dockOffset: CGFloat = 50
        static let mainWindowIdentifier = "main"
        static let mainWindowTitle = "Gemini Desktop"
    }

}
