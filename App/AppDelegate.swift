//
//  AppDelegate.swift
//  GeminiDesktop
//

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: AppCoordinator?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { await self.coordinator?.openMainWindow() }
        return true
    }
}
