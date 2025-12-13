import SwiftUI
import KeyboardShortcuts
import WebKit
import ServiceManagement

struct SettingsView: View {
    @Binding var coordinator: AppCoordinator
    @AppStorage("pageZoom") private var pageZoom: Double = 1.0
    @AppStorage("showWindowAtLaunch") private var showWindowAtLaunch: Bool = true
    @State private var showingResetAlert = false
    @State private var isClearing = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch MenuBar at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        } catch { launchAtLogin = !newValue }
                    }
                Toggle("Show Window at Launch", isOn: $showWindowAtLaunch)
            }
            Section("Keyboard Shortcuts") {
                HStack {
                    Text("Toggle Chat Bar:")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .bringToFront)
                }
            }
            Section("Appearance") {
                HStack {
                    Text("Text Size:")
                    Slider(value: $pageZoom, in: 0.8...1.2, step: 0.01)
                        .onChange(of: pageZoom) { coordinator.webView.pageZoom = $1 }
                    Text("\(Int(pageZoom * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 50, alignment: .trailing)
                }
            }
            Section("Privacy") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Reset Website Data")
                        Text("Clears cookies, cache, and login sessions")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset", role: .destructive) { showingResetAlert = true }
                        .disabled(isClearing)
                        .overlay { if isClearing { ProgressView().scaleEffect(0.7) } }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Reset Website Data?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) { clearWebsiteData() }
        } message: {
            Text("This will clear all cookies, cache, and login sessions. You will need to sign in to Gemini again.")
        }
    }

    private func clearWebsiteData() {
        isClearing = true
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: types) { records in
            dataStore.removeData(ofTypes: types, for: records) {
                DispatchQueue.main.async { isClearing = false }
            }
        }
    }
}
