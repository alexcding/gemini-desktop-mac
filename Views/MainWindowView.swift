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
                // Apply Always on Top setting and restore window position/size on launch with a delay to ensure window exists
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                    let alwaysOnTop = UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTop.rawValue)
                    coordinator.setAlwaysOnTop(alwaysOnTop)
                    self.restoreWindowPositionAndSize()
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
            // Save window position when moved
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)) { notification in
                guard let window = notification.object as? NSWindow,
                      window.identifier?.rawValue == AppCoordinator.Constants.mainWindowIdentifier ||
                      window.title == AppCoordinator.Constants.mainWindowTitle else { return }
                saveWindowPosition(window)
            }
            // Save window size when resized
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
                guard let window = notification.object as? NSWindow,
                      window.identifier?.rawValue == AppCoordinator.Constants.mainWindowIdentifier ||
                      window.title == AppCoordinator.Constants.mainWindowTitle else { return }
                saveWindowSize(window)
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
            }
    }
    
    // MARK: - Window State Persistence
    
    private func restoreWindowPositionAndSize() {
        guard let window = NSApp.windows.first(where: { 
            $0.identifier?.rawValue == AppCoordinator.Constants.mainWindowIdentifier || 
            $0.title == AppCoordinator.Constants.mainWindowTitle 
        }) else { return }
        
        let savedX = UserDefaults.standard.double(forKey: UserDefaultsKeys.mainWindowX.rawValue)
        let savedY = UserDefaults.standard.double(forKey: UserDefaultsKeys.mainWindowY.rawValue)
        let savedWidth = UserDefaults.standard.double(forKey: UserDefaultsKeys.mainWindowWidth.rawValue)
        let savedHeight = UserDefaults.standard.double(forKey: UserDefaultsKeys.mainWindowHeight.rawValue)
        
        // Only restore if we have saved values
        if savedWidth > 0 && savedHeight > 0 {
            let newFrame = NSRect(
                x: savedX,
                y: savedY,
                width: savedWidth,
                height: savedHeight
            )
            window.setFrame(newFrame, display: true)
        }
    }
    
    private func saveWindowPosition(_ window: NSWindow) {
        UserDefaults.standard.set(window.frame.origin.x, forKey: UserDefaultsKeys.mainWindowX.rawValue)
        UserDefaults.standard.set(window.frame.origin.y, forKey: UserDefaultsKeys.mainWindowY.rawValue)
    }
    
    private func saveWindowSize(_ window: NSWindow) {
        UserDefaults.standard.set(window.frame.size.width, forKey: UserDefaultsKeys.mainWindowWidth.rawValue)
        UserDefaults.standard.set(window.frame.size.height, forKey: UserDefaultsKeys.mainWindowHeight.rawValue)
    }
}
