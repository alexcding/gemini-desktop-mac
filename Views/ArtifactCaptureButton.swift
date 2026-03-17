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
        .sheet(isPresented: $showingSheet) {
            FilenameInputSheet(
                isPresented: $showingSheet,
                filename: $filenameInput,
                onSave: {
                    coordinator.captureLastResponse(suggestedFilename: filenameInput)
                    showingSheet = false
                }
            )
        }
    }
}

private struct FilenameInputSheet: View {
    @Binding var isPresented: Bool
    @Binding var filename: String
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Save Artifact As")
                .font(.headline)

            TextField("Filename (without .md extension)", text: $filename)
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
            filename = ""
        }
    }
}
