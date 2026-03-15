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
                updateWindowAppearance(window)
            })
            .onAppear {
                coordinator.openWindowAction = { id in
                    openWindow(id: id)
                }
            }
            .onChange(of: useCustomToolbarColor) { _, _ in updateAllWindows() }
            .onChange(of: toolbarColorHex) { _, _ in updateAllWindows() }
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

    private func updateWindowAppearance(_ window: NSWindow) {
        if useCustomToolbarColor, let color = Color(toolbarColorHex) {
            window.backgroundColor = NSColor(color)
        } else {
            // Revert to default
            window.backgroundColor = GeminiDesktopApp.Constants.toolbarColor
        }
        
        // This ensures the background color is used for the title bar/toolbar area
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        
        // Ensure the green traffic light enters native Full Screen mode
        if !window.collectionBehavior.contains(.fullScreenPrimary) {
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
    }

    private func updateAllWindows() {
        for window in NSApp.windows {
            if (window.identifier?.rawValue == AppCoordinator.Constants.mainWindowIdentifier || window.title == AppCoordinator.Constants.mainWindowTitle) && !(window is NSPanel) {
                updateWindowAppearance(window)
            }
        }
    }

    private func minimizeToPrompt() {
        // Close main window and show chat bar
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == AppCoordinator.Constants.mainWindowIdentifier || $0.title == AppCoordinator.Constants.mainWindowTitle }) {
            if !(window is NSPanel) {
                window.orderOut(nil)
            }
        }
        coordinator.showChatBar()
    }
}

// Helper to access NSWindow from SwiftUI
struct WindowAccessor: NSViewRepresentable {
    var onWindowReceived: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let nsView = NSView()
        DispatchQueue.main.async {
            if let window = nsView.window {
                onWindowReceived(window)
            }
        }
        return nsView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            onWindowReceived(window)
        }
    }
}
