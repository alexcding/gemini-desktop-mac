//
//  ArtifactCaptureButton.swift
//  GeminiDesktop
//

import SwiftUI

struct ArtifactCaptureButton: View {
    var coordinator: AppCoordinator
    @State private var showingSheet = false
    @State private var filenameInput = ""

    var body: some View {
        Button(action: { showingSheet = true }) {
            Image(systemName: "square.and.arrow.down.on.square")
        }
        .disabled(coordinator.captureProgress != nil)
        .overlay(alignment: .bottom) {
            if coordinator.captureProgress != nil {
                ProgressIndicator(progress: coordinator.captureProgress)
                    .offset(y: 30)
            }
        }
        .sheet(isPresented: $showingSheet) {
            FilenameInputSheet(
                isPresented: $showingSheet,
                filename: $filenameInput,
                initialFilename: coordinator.defaultArtifactFilename(),
                onSave: {
                    coordinator.captureLastResponse(suggestedFilename: filenameInput)
                    showingSheet = false
                }
            )
        }
    }
}

private struct ProgressIndicator: View {
    let progress: AppCoordinator.CaptureProgress?

    var body: some View {
        HStack(spacing: 8) {
            switch progress {
            case .started, .converting, .saving, .streaming:
                ProgressView()
                    .scaleEffect(0.75)
            case .completed, .failed, nil:
                EmptyView()
            }

            Text(statusLabel)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(8)
        .background(.regularMaterial)
        .cornerRadius(6)
    }

    private var statusLabel: String {
        switch progress {
        case .started:
            return "Starting…"
        case .converting:
            return "Converting…"
        case .saving:
            return "Saving…"
        case .completed(let filename):
            return "Saved: \(filename)"
        case .failed(let error):
            return "Error: \(error)"
        case .streaming:
            return "Still streaming…"
        case nil:
            return ""
        }
    }
}

private struct FilenameInputSheet: View {
    @Binding var isPresented: Bool
    @Binding var filename: String
    let initialFilename: String
    var onSave: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Save Artifact As")
                .font(.headline)

            TextField("Filename (e.g. Gemini-2026-03-19-143022.md)", text: $filename)
                .focused($isFocused)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(filename.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 300)
        .onAppear {
            filename = initialFilename
            isFocused = true
            DispatchQueue.main.async {
                NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
            }
        }
    }
}
