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

    var body: some View {
        GeminiWebView(webView: coordinator.webViewModel.wkWebView)
            .onAppear {
                coordinator.openWindowAction = { id in
                    openWindow(id: id)
                }
                // Apply Always on Top setting on launch with a delay to ensure window exists
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let alwaysOnTop = UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTop.rawValue)
                    coordinator.setAlwaysOnTop(alwaysOnTop)
                }
            }
            // Re-apply always on top when window becomes key (after switching from other apps)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard let window = notification.object as? NSWindow,
                      window.identifier?.rawValue == AppCoordinator.Constants.mainWindowIdentifier ||
                      window.title == AppCoordinator.Constants.mainWindowTitle else { return }
                let alwaysOnTop = UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTop.rawValue)
                if alwaysOnTop {
                    window.level = .floating
                    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                }
            }
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
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == AppCoordinator.Constants.mainWindowIdentifier || $0.title == AppCoordinator.Constants.mainWindowTitle }) {
            if !(window is NSPanel) {
                window.orderOut(nil)
            }
        }
        coordinator.showChatBar()
    }
}
