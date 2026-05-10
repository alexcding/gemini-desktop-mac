import SwiftUI
import KeyboardShortcuts
import WebKit
import ServiceManagement

struct SettingsView: View {
    let coordinator: AppCoordinator
    @AppStorage(UserDefaultsKeys.pageZoom.rawValue) private var pageZoom: Double = Constants.defaultPageZoom
    @AppStorage(UserDefaultsKeys.hideWindowAtLaunch.rawValue) private var hideWindowAtLaunch: Bool = false
    @AppStorage(UserDefaultsKeys.hideDockIcon.rawValue) private var hideDockIcon: Bool = false
    @AppStorage(UserDefaultsKeys.appTheme.rawValue) private var appTheme: String = AppTheme.system.rawValue
    @AppStorage(UserDefaultsKeys.userAgentOption.rawValue) private var userAgentOption: String = UserAgentOption.safari.rawValue
    @AppStorage(UserDefaultsKeys.customUserAgent.rawValue) private var customUserAgent: String = ""
    @AppStorage(UserDefaultsKeys.panelPosition.rawValue) private var panelPosition: String = PanelPosition.bottomCenter.rawValue

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
                Toggle("Hide Desktop Window at Launch", isOn: $hideWindowAtLaunch)
                Toggle("Hide Dock Icon", isOn: $hideDockIcon)
                    .onChange(of: hideDockIcon) { _, newValue in
                        NSApp.setActivationPolicy(newValue ? .accessory : .regular)
                    }
            }
            Section("Chat Bar") {
                HStack {
                    Label("Position on Screen", systemImage: "rectangle.bottomthird.inset.filled")
                    Spacer()
                    Picker("", selection: $panelPosition) {
                        ForEach([PanelPosition.bottomLeft, .bottomCenter, .bottomRight], id: \.rawValue) { pos in
                            Text(pos.displayName).tag(pos.rawValue)
                        }
                        Divider()
                        Text(PanelPosition.rememberLast.displayName).tag(PanelPosition.rememberLast.rawValue)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: panelPosition) { _, _ in
                        coordinator.resetChatBarPosition()
                    }
                }
                HStack {
                    Label("Keyboard Shortcut", systemImage: "command")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .bringToFront)
                }
                HStack {
                    VStack(alignment: .leading) {
                        Label("Quick Ask with Selection", systemImage: "text.cursor")
                        Text("Opens the chat bar and pastes the selected text from the frontmost app. Requires Accessibility permission.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .bringToFrontWithSelection)
                }
            }
            Section("Appearance") {
                HStack {
                    Text("Theme:")
                    Spacer()
                    Picker("", selection: $appTheme) {
                        ForEach(AppTheme.allCases, id: \.rawValue) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .onChange(of: appTheme) { _, newValue in
                        (AppTheme(rawValue: newValue) ?? .system).apply()
                    }
                }
                HStack {
                    Text("Text Size: \(Int((pageZoom * 100).rounded()))%")
                    Spacer()
                    Stepper("",
                            value: $pageZoom,
                            in: Constants.minPageZoom...Constants.maxPageZoom,
                            step: Constants.pageZoomStep)
                        .onChange(of: pageZoom) { coordinator.webViewModel.wkWebView.pageZoom = $1 }
                        .labelsHidden()
                }
            }
            Section("User Agent") {
                HStack {
                    Text("Browser Identity:")
                    Spacer()
                    Picker("", selection: $userAgentOption) {
                        ForEach(UserAgentOption.allCases, id: \.rawValue) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .onChange(of: userAgentOption) { _, _ in
                        coordinator.webViewModel.applyUserAgent()
                    }
                }
                if userAgentOption == UserAgentOption.custom.rawValue {
                    TextField("Custom User Agent", text: $customUserAgent, prompt: Text("Enter custom user agent string"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            coordinator.webViewModel.applyUserAgent()
                        }
                }
                Text(currentUserAgentDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var currentUserAgentDescription: String {
        let option = UserAgentOption(rawValue: userAgentOption) ?? .safari
        return option.settingsDescription(custom: customUserAgent)
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

extension SettingsView {

    struct Constants {
        static let defaultPageZoom: Double = 1.0
        static let minPageZoom: Double = 0.6
        static let maxPageZoom: Double = 1.4
        static let pageZoomStep: Double = 0.01
    }

}
