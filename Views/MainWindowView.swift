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
    @AppStorage(UserDefaultsKeys.promptInjectionMode.rawValue) private var promptInjectionMode: String = "copy"

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
                    ArtifactCaptureButton(coordinator: coordinator)
                        .help("Capture Last Response as Artifact")
                }

                ToolbarItem(placement: .primaryAction) {
                    PromptsMenuButton(coordinator: coordinator, injectionMode: promptInjectionMode)
                        .help("Insert Saved Prompt")
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
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    // Injection banner (existing)
                    if let msg = coordinator.injectionBannerMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(msg)
                            Spacer()
                            Button(action: { coordinator.dismissInjectionBanner() }) {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Capture progress / feedback banner (new)
                    if let progress = coordinator.captureProgress {
                        captureBanner(progress: progress)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding([.horizontal, .top], 12)
            }
            .animation(.easeInOut(duration: 0.2), value: coordinator.injectionBannerMessage)
            .animation(.easeInOut(duration: 0.2), value: coordinator.captureProgress)
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
        // Toolbar color is applied via SwiftUI's .toolbarBackground() modifier.
        // Do not set window.backgroundColor as it fills the entire content area
        // and covers the WebView during initial load.
    }

    private func applyColorToAllWindows() {
        mainWindows.forEach { applyColor(to: $0) }
    }

    private func minimizeToPrompt() {
        mainWindows.first?.orderOut(nil)
        coordinator.showChatBar()
    }

    @ViewBuilder
    private func captureBanner(progress: AppCoordinator.CaptureProgress) -> some View {
        switch progress {
        case .started, .converting, .saving:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.75)
                Text(progressLabel(progress))
                    .font(.callout)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

        case .completed(let filename):
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved: \(filename)")
                    .font(.callout)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

        case .streaming:
            HStack {
                Image(systemName: "waveform")
                Text("Gemini is still streaming — wait for the response to finish.")
                    .font(.callout)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

        case .failed(let error):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.callout)
                    Spacer()
                    Button {
                        coordinator.dismissCaptureProgress()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    Button("Open Log") {
                        if let url = ArtifactLogger.logFileURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(ArtifactLogger.logFileURL == nil)
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func progressLabel(_ progress: AppCoordinator.CaptureProgress) -> String {
        switch progress {
        case .started: return "Starting…"
        case .converting: return "Converting…"
        case .saving: return "Saving…"
        default: return ""
        }
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
