//
//  SettingsView.swift
//  GeminiMac
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import KeyboardShortcuts
import WebKit
import ServiceManagement

struct SettingsView: View {
    let coordinator: AppCoordinator

    @AppStorage("pageZoom") private var pageZoom: Double = 1.0
    @State private var showingResetAlert = false
    @State private var isClearing = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch MenuBar at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !newValue
                        }
                    }
            } header: {
                Text("General")
            } footer: {
                Text("Automatically start Gemini in the menu bar when you log in")
            }

            Section {
                HStack {
                    Text("Toggle Chat Bar:")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .bringToFront)
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Press this shortcut from any app to show/hide the Chat Bar")
            }

            Section {
                HStack {
                    Text("Text Size:")
                    Slider(value: $pageZoom, in: 0.8...1.2, step: 0.01) {
                        Text("Text Size")
                    }
                    .onChange(of: pageZoom) { _, newValue in
                        coordinator.webView.pageZoom = newValue
                    }
                    Text("\(Int(pageZoom * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 50, alignment: .trailing)
                }
            } header: {
                Text("Appearance")
            }

            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Reset Website Data")
                        Text("Clears cookies, cache, and login sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        showingResetAlert = true
                    } label: {
                        if isClearing {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Text("Reset")
                        }
                    }
                    .disabled(isClearing)
                }
            } header: {
                Text("Privacy")
            }

        }
        .formStyle(.grouped)
        .alert("Reset Website Data?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                clearWebsiteData()
            }
        } message: {
            Text("This will clear all cookies, cache, and login sessions. You will need to sign in to Gemini again.")
        }
    }

    private func clearWebsiteData() {
        isClearing = true
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            dataStore.removeData(ofTypes: dataTypes, for: records) {
                DispatchQueue.main.async {
                    isClearing = false
                }
            }
        }
    }
}
