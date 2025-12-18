//
//  MenuBarContentView.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit
import Sparkle

struct MenuBarView: View {
    @Binding var coordinator: AppCoordinator
    let updater: SPUUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button {
                coordinator.openMainWindow()
            } label: {
                Label("Open Gemini Desktop", systemImage: "macwindow")
            }

            Button {
                coordinator.toggleChatBar()
            } label: {
                Label("Toggle Chat Bar", systemImage: "rectangle.bottomhalf.inset.filled")
            }

            Divider()

            CheckForUpdatesView(updater: updater)

            SettingsLink {
                Label("Settings...", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .onAppear {
            coordinator.openWindowAction = { id in
                openWindow(id: id)
            }
        }
    }
}
