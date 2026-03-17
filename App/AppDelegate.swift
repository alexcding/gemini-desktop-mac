//
//  AppDelegate.swift
//  GeminiDesktop
//

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: AppCoordinator?

    nonisolated(unsafe) static weak var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    var appCoordinator: AppCoordinator? {
        coordinator
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { await self.coordinator?.openMainWindow() }
        return true
    }
}
