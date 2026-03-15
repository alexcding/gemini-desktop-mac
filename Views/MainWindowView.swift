//
//  MainWindowContent.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit

struct MainWindowView: View {
    @Binding var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow
    @AppStorage(UserDefaultsKeys.useCustomToolbarColor.rawValue) private var useCustomToolbarColor: Bool = false
    @AppStorage(UserDefaultsKeys.toolbarColorHex.rawValue) private var toolbarColorHex: String = "#34A853"

    var body: some View {
        GeminiWebView(webView: coordinator.webViewModel.wkWebView)
            .background(WindowAccessor { window in
                setupWindowAppearance(window)
            })
            .onAppear {
                coordinator.openWindowAction = { id in
                    openWindow(id: id)
                }
            }
            .onChange(of: useCustomToolbarColor) { _, _ in applyColorToAllWindows() }
            .onChange(of: toolbarColorHex) { _, _ in applyColorToAllWindows() }
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

    private var mainWindows: [NSWindow] {
        coordinator.findMainWindow().map { [$0] } ?? []
    }

    private func setupWindowAppearance(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.collectionBehavior.insert(.fullScreenPrimary)
        applyColor(to: window)
    }

    private func applyColor(to window: NSWindow) {
        if useCustomToolbarColor, let color = Color(toolbarColorHex) {
            window.backgroundColor = NSColor(color)
        } else {
            window.backgroundColor = GeminiDesktopApp.Constants.toolbarColor
        }
    }

    private func applyColorToAllWindows() {
        mainWindows.forEach { applyColor(to: $0) }
    }

    private func minimizeToPrompt() {
        mainWindows.first?.orderOut(nil)
        coordinator.showChatBar()
    }
}

// Helper to access NSWindow from SwiftUI for one-time setup
struct WindowAccessor: NSViewRepresentable {
    var onWindowAvailable: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let nsView = NSView()
        DispatchQueue.main.async {
            if let window = nsView.window {
                onWindowAvailable(window)
            }
        }
        return nsView
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
