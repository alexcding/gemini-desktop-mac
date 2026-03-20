//
//  ArtifactCaptureButton.swift
//  GeminiDesktop
//

import SwiftUI
import AppKit

struct ArtifactCaptureButton: View {
    var coordinator: AppCoordinator
    @State private var showingSheet = false
    @State private var filenameInput = ""
    @State private var prefetchedMetadata: ArtifactMetadata? = nil

    var body: some View {
        Button(action: {
            Task {
                // Pre-fetch metadata before opening the sheet so the disclosure group is populated.
                // fetchMetadataPreview() never throws and completes in <50ms.
                prefetchedMetadata = await coordinator.fetchMetadataPreview()
                showingSheet = true
            }
        }) {
            Image(systemName: "square.and.arrow.down.on.square")
        }
        .disabled(coordinator.captureProgress != nil)
        .sheet(isPresented: $showingSheet) {
            // prefetchedMetadata is always set before showingSheet = true.
            // ArtifactMetadata.empty() is a defensive fallback that should never be reached.
            let metadata = prefetchedMetadata ?? ArtifactMetadata.empty()
            FilenameInputSheet(
                isPresented: $showingSheet,
                filename: $filenameInput,
                initialFilename: coordinator.defaultArtifactFilename(),
                metadata: metadata,
                onSave: {
                    coordinator.captureLastResponse(
                        suggestedFilename: filenameInput,
                        previewMetadata: metadata
                    )
                    showingSheet = false
                }
            )
        }
    }
}

private struct FilenameInputSheet: View {
    @Binding var isPresented: Bool
    @Binding var filename: String
    let initialFilename: String
    let metadata: ArtifactMetadata
    var onSave: () -> Void
    @FocusState private var isFocused: Bool
    @State private var metadataExpanded = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Save Artifact As")
                .font(.headline)

            TextField("Filename (e.g. Gemini-2026-03-20-143022.md)", text: $filename)
                .focused($isFocused)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            DisclosureGroup("Metadata", isExpanded: $metadataExpanded) {
                metadataRows
                    .padding(.top, 4)
            }
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
        .frame(minWidth: 360)
        .onAppear {
            filename = initialFilename
            isFocused = true
            // Use asyncAfter to let AppKit complete its focus-handling cycle before
            // setting the selection range. Without the delay, AppKit overwrites it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let editor = NSApp.keyWindow?.firstResponder as? NSText {
                    let stem = (initialFilename as NSString).deletingPathExtension
                    editor.setSelectedRange(NSRange(location: 0, length: (stem as NSString).length))
                }
            }
        }
    }

    /// Read-only metadata preview. Option B: replace Text rows with TextField bindings.
    private var metadataRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let model = metadata.geminiModel {
                metadataRow(label: "model", value: model)
            }
            if let request = metadata.request {
                metadataRow(label: "request", value: String(request.prefix(80)))
            }
            if let url = metadata.conversationUrl {
                metadataRow(label: "url", value: url)
            }
            metadataRow(
                label: "captured",
                value: metadata.capturedAt.formatted(date: .abbreviated, time: .shortened)
            )
            if !metadata.attachments.isEmpty {
                metadataRow(label: "attachments", value: metadata.attachments.joined(separator: ", "))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(label):")
                .fontWeight(.medium)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
