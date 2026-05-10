//
//  SelectionCapture.swift
//  GeminiDesktop
//

import AppKit
import ApplicationServices

enum SelectionCapture {

    private static let pollInterval: TimeInterval = 0.01
    private static let pollTimeout: TimeInterval = 0.25

    /// Captures currently selected text from the frontmost app by simulating Cmd+C,
    /// preserving and restoring the user's existing pasteboard contents.
    /// Calls completion on the main queue with the captured string, or nil if no selection.
    static func captureSelectedText(completion: @escaping (String?) -> Void) {
        guard ensureAccessibilityPermission() else {
            completion(nil)
            return
        }

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let initialChangeCount = pasteboard.changeCount

        postCopyKeystroke()

        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(pollTimeout)
            while pasteboard.changeCount == initialChangeCount && Date() < deadline {
                Thread.sleep(forTimeInterval: pollInterval)
            }

            let captured: String? = {
                guard pasteboard.changeCount != initialChangeCount else { return nil }
                let text = pasteboard.string(forType: .string)
                return (text?.isEmpty ?? true) ? nil : text
            }()

            DispatchQueue.main.async {
                restorePasteboard(pasteboard, items: snapshot)
                completion(captured)
            }
        }
    }

    // MARK: - Accessibility Permission

    @discardableResult
    static func ensureAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Pasteboard Snapshot / Restore

    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
            var map: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    map[type] = data
                }
            }
            return map
        }
    }

    private static func restorePasteboard(_ pb: NSPasteboard, items snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        let newItems: [NSPasteboardItem] = snapshot.map { map in
            let item = NSPasteboardItem()
            for (type, data) in map {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(newItems)
    }

    // MARK: - Keystroke Posting

    private static func postCopyKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 0x08

        let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
