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

    @AppStorage(UserDefaultsKeys.useCustomToolbarColor.rawValue) private var useCustomToolbarColor: Bool = false
    @AppStorage(UserDefaultsKeys.toolbarColorHex.rawValue) private var toolbarColorHex: String = "#34A853"

    var body: some Scene {
        WindowGroup(AppCoordinator.Constants.mainWindowTitle, id: Constants.mainWindowID) {
            MainWindowView(coordinator: $coordinator)
                .toolbarBackground(useCustomToolbarColor ? (Color(toolbarColorHex) ?? .clear) : Color(nsColor: Constants.toolbarColor), for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
                .frame(minWidth: Constants.mainWindowMinWidth, minHeight: Constants.mainWindowMinHeight)
                .onAppear { appDelegate.coordinator = coordinator }
        }
        .handlesExternalEvents(matching: [Constants.mainWindowID])
        .defaultSize(width: Constants.mainWindowDefaultWidth, height: Constants.mainWindowDefaultHeight)
        .defaultWindowPlacement { _, _ in WindowPlacement(.center) }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button {
                    coordinator.openNewChat()
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
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
            SettingsView(coordinator: $coordinator)
        }
        .defaultSize(width: Constants.settingsWindowDefaultWidth, height: Constants.settingsWindowDefaultHeight)

        MenuBarExtra {
            MenuBarView(coordinator: $coordinator)
        } label: {
            Image(systemName: Constants.menuBarIcon)
                .onAppear {
                    coordinator.updateActivationPolicy()
                    let hideWindowAtLaunch = UserDefaults.standard.bool(forKey: UserDefaultsKeys.hideWindowAtLaunch.rawValue)

                    if hideWindowAtLaunch {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(Constants.hideWindowDelay))
                            for window in NSApp.windows {
                                if window.identifier?.rawValue == Constants.mainWindowID || window.title == AppCoordinator.Constants.mainWindowTitle {
                                    window.orderOut(nil)
                                }
                            }
                        }
                    }
                }
        }
        .menuBarExtraStyle(.menu)
    }

    init() {
        // Apply saved theme and activation policy on launch
        AppTheme.current.apply()
        coordinator.updateActivationPolicy()

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
                // Dark Mode: Green 200 (#81C995)
                return NSColor(red: 129.0/255.0, green: 201.0/255.0, blue: 149.0/255.0, alpha: 1.0)
            } else {
                // Light Mode: Green 500 (#34A853)
                return NSColor(red: 52.0/255.0, green: 168.0/255.0, blue: 83.0/255.0, alpha: 1.0)
            }
        }
        static let menuBarIcon = "sparkle"

        // Timing
        static let hideWindowDelay: TimeInterval = 0.1
    }
}
