//
//  CheckForUpdatesView.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-18.
//

import SwiftUI
import Sparkle

/// A SwiftUI view that wraps the Sparkle updater check functionality.
/// This view observes the updater's canCheckForUpdates property and enables/disables accordingly.
struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: checkForUpdatesViewModel.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

/// A view model that publishes changes from the Sparkle updater.
/// This allows SwiftUI views to reactively update when the updater's state changes.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
