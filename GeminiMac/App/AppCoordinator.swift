//
//  AppCoordinator.swift
//  GeminiMac
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit
import WebKit
import Combine

extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}

@Observable
class AppCoordinator {
    private var chatBar: ChatBar?
    private var expandedState = ExpandedState()
    let webView: WKWebView
    var canGoBack: Bool = false
    private var backObserver: NSKeyValueObservation?
    private var urlObserver: NSKeyValueObservation?
    private var isAtHome: Bool = true

    var openWindowAction: ((String) -> Void)?

    class ExpandedState: ObservableObject {
        @Published var isExpanded: Bool = false
    }

    private static let geminiURL = URL(string: "https://gemini.google.com/app")!

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let wv = WKWebView(frame: .zero, configuration: configuration)
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsLinkPreview = true

        // Apply saved page zoom
        let savedZoom = UserDefaults.standard.double(forKey: "pageZoom")
        wv.pageZoom = savedZoom > 0 ? savedZoom : 1.0

        wv.load(URLRequest(url: Self.geminiURL))

        self.webView = wv

        backObserver = wv.observe(\.canGoBack, options: [.new, .initial]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.canGoBack = !self.isAtHome && webView.canGoBack
            }
        }

        urlObserver = wv.observe(\.url, options: .new) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.isAtHome, webView.url != Self.geminiURL {
                    self.isAtHome = false
                    self.canGoBack = webView.canGoBack
                }
            }
        }

        // Observe notifications for window opening
        NotificationCenter.default.addObserver(forName: .openMainWindow, object: nil, queue: .main) { [weak self] _ in
            self?.openMainWindow()
        }
    }

    func reloadHomePage() {
        isAtHome = true
        canGoBack = false
        webView.load(URLRequest(url: Self.geminiURL))
    }

    func goBack() {
        isAtHome = false
        webView.goBack()
    }

    func showChatBar() {
        // Hide main window since we share the same WebView
        closeMainWindow()

        if let bar = chatBar {
            // Reuse existing chat bar
            bar.orderFront(nil)
            bar.makeKeyAndOrderFront(nil)
            bar.checkAndAdjustSize()
            return
        }

        let contentView = ChatBarContent(
            webView: webView,
            expandedState: expandedState,
            onExpandToMain: { [weak self] in
                self?.expandToMainWindow()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        let bar = ChatBar(contentView: hostingView)
        bar.onExpandedChange = { [weak self] expanded in
            self?.expandedState.isExpanded = expanded
        }

        // Position at bottom center, above the dock
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let barSize = bar.frame.size
            let x = screenRect.origin.x + (screenRect.width - barSize.width) / 2
            let y = screenRect.origin.y + 50  // 50px above dock
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
            if window.identifier?.rawValue == "main" || window.title == "Gemini" {
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
        NSApp.setActivationPolicy(.regular)
        if let mainWindow = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "main" || $0.title == "Gemini"
        }) {
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?("main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Chat Bar Content View
struct ChatBarContent: View {
    let webView: WKWebView
    @ObservedObject var expandedState: AppCoordinator.ExpandedState
    let onExpandToMain: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeminiWebView(webView: webView)

            Button(action: onExpandToMain) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .offset(x: -2)
        }
    }
}

// MARK: - Main Window Content View
struct MainWindowContent: View {
    let coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GeminiWebView(webView: coordinator.webView)
            .toolbar {
                if coordinator.canGoBack {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            coordinator.goBack()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .help("Back")
                    }
                }

                ToolbarItem(placement: .principal) {
                    Spacer()
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        minimizeToPrompt()
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                    .help("Minimize to Prompt Panel")
                }
            }
    }

    private func minimizeToPrompt() {
        // Close main window and show chat bar
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Gemini" }) {
            if !(window is NSPanel) {
                window.orderOut(nil)
            }
        }
        coordinator.showChatBar()
    }
}
