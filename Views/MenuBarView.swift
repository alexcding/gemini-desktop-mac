//
//  MenuBarContentView.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import AppKit

struct MenuBarView: View {
    @Binding var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button {
                coordinator.openMainWindow()
            } label: {
                Label("Open Gemini Desktop", systemImage: "macwindow")
            }

            Divider()

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
