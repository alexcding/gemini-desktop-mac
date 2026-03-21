//
//  PromptsMenuButton.swift
//  GeminiDesktop
//

import SwiftUI

struct PromptsMenuButton: View {
    var coordinator: AppCoordinator
    var injectionMode: String

    var body: some View {
        Menu {
            ForEach(coordinator.promptLibrary.rootNodes, id: \.id) { node in
                AnyView(nodeContent(for: node))
            }
        } label: {
            Image(systemName: "sparkles")
        }
        .disabled(coordinator.isInjecting)
    }

    private func nodeContent(for node: PromptNode) -> some View {
        switch node {
        case .directory(let name, let children):
            return AnyView(
                Menu(name) {
                    ForEach(children, id: \.id) { child in
                        AnyView(nodeContent(for: child))
                    }
                }
            )
        case .file(let file):
            return AnyView(fileMenuButton(for: file))
        }
    }

    @ViewBuilder
    private func fileMenuButton(for file: PromptFile) -> some View {
        let isDeprecated = file.metadata?.deprecated == true

        if let tooltip = file.tooltipContent {
            Button(action: { handleSelection(file) }) {
                Text(file.displayTitle)
                    .foregroundStyle(isDeprecated ? Color.secondary : Color.primary)
            }
            .help(tooltip.formatted())
        } else {
            Button(file.displayTitle, action: { handleSelection(file) })
                .foregroundStyle(isDeprecated ? Color.secondary : Color.primary)
        }
    }

    private func handleSelection(_ file: PromptFile) {
        if case .danger = file.scanResult {
            showDangerAlert(for: file)
        } else {
            executePrompt(file)
        }
    }

    private func showDangerAlert(for file: PromptFile) {
        let alert = NSAlert()
        alert.messageText = "Dangerous Pattern Detected"
        alert.informativeText = "This prompt contains a pattern that could be misused. Are you sure you want to use it?"
        alert.addButton(withTitle: "Use Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            executePrompt(file)
        }
    }

    private func executePrompt(_ file: PromptFile) {
        if injectionMode == "copy" {
            coordinator.copyPromptToClipboard(file)
        } else {
            coordinator.injectPrompt(file)
        }
    }
}
