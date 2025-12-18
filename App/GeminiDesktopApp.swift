//
//  GeminiDesktopApp.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import KeyboardShortcuts
import AppKit
import Combine
import Sparkle

// MARK: - Keyboard Shortcut Definition
extension KeyboardShortcuts.Name {
    static let bringToFront = Self("bringToFront", default: nil)
}

// MARK: - Main App
@main
struct GeminiDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State var coordinator = AppCoordinator()
    @Environment(\.openWindow) private var openWindow

    // Sparkle updater controller - handles auto-update lifecycle
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        Window(AppCoordinator.Constants.mainWindowTitle, id: Constants.mainWindowID) {
            MainWindowView(coordinator: $coordinator)
                .toolbarBackground(Color(nsColor: Constants.toolbarColor), for: .windowToolbar)
                .frame(minWidth: Constants.mainWindowMinWidth, minHeight: Constants.mainWindowMinHeight)
        }
        .defaultSize(width: Constants.mainWindowDefaultWidth, height: Constants.mainWindowDefaultHeight)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // Check for Updates command in the app menu
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(after: .toolbar) {
                Button {
                    coordinator.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!coordinator.canGoBack)

                Button {
                    coordinator.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!coordinator.canGoForward)

                Button {
                    coordinator.goHome()
                } label: {
                    Label("Go Home", systemImage: "house")
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Divider()

                Button {
                    coordinator.reload()
                } label: {
                    Label("Reload Page", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button {
                    coordinator.zoomIn()
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .keyboardShortcut("+", modifiers: .command)

                Button {
                    coordinator.zoomOut()
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)

                Button {
                    coordinator.resetZoom()
                } label: {
                    Label("Actual Size", systemImage: "1.magnifyingglass")
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            SettingsView(coordinator: $coordinator, updater: updaterController.updater)
        }
        .defaultSize(width: Constants.settingsWindowDefaultWidth, height: Constants.settingsWindowDefaultHeight)

        MenuBarExtra {
            MenuBarView(coordinator: $coordinator, updater: updaterController.updater)
        } label: {
            Image(systemName: Constants.menuBarIcon)
                .onAppear {
                    let hideWindowAtLaunch = UserDefaults.standard.bool(forKey: UserDefaultsKeys.hideWindowAtLaunch.rawValue)
                    let hideDockIcon = UserDefaults.standard.bool(forKey: UserDefaultsKeys.hideDockIcon.rawValue)

                    if hideDockIcon || hideWindowAtLaunch {
                        NSApp.setActivationPolicy(.accessory)
                        if hideWindowAtLaunch {
                            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.hideWindowDelay) {
                                for window in NSApp.windows {
                                    if window.identifier?.rawValue == Constants.mainWindowID || window.title == AppCoordinator.Constants.mainWindowTitle {
                                        window.orderOut(nil)
                                    }
                                }
                            }
                        }
                    } else {
                        NSApp.setActivationPolicy(.regular)
                    }
                }
        }
        .menuBarExtraStyle(.menu)
    }

    init() {
        KeyboardShortcuts.onKeyDown(for: .bringToFront) { [self] in
            coordinator.toggleChatBar()
        }
    }
}

// MARK: - Constants
extension GeminiDesktopApp {
    struct Constants {
        // Main Window
        static let mainWindowMinWidth: CGFloat = 400
        static let mainWindowMinHeight: CGFloat = 300
        static let mainWindowDefaultWidth: CGFloat = 1000
        static let mainWindowDefaultHeight: CGFloat = 700

        // Settings Window
        static let settingsWindowDefaultWidth: CGFloat = 700
        static let settingsWindowDefaultHeight: CGFloat = 600

        static let mainWindowID = "main"

        // Appearance
        static let toolbarColor: NSColor = NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(red: 43.0/255.0, green: 43.0/255.0, blue: 43.0/255.0, alpha: 1.0)
            } else {
                return NSColor(red: 238.0/255.0, green: 241.0/255.0, blue: 247.0/255.0, alpha: 1.0)
            }
        }
        static let menuBarIcon = "sparkle"

        // Timing
        static let hideWindowDelay: TimeInterval = 0.1
    }
}
