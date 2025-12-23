//
//  NSScreen+Extensions.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-23.
//

import AppKit

extension NSScreen {
    /// Returns the screen containing the specified point
    static func screen(containing point: NSPoint) -> NSScreen? {
        screens.first { $0.frame.contains(point) } ?? main
    }

    /// Returns the screen containing the current mouse cursor location
    static func screenAtMouseLocation() -> NSScreen? {
        screen(containing: NSEvent.mouseLocation)
    }

    /// Centers a window of the given size on this screen's visible frame
    func centerPoint(for windowSize: NSSize) -> NSPoint {
        NSPoint(
            x: visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2,
            y: visibleFrame.origin.y + (visibleFrame.height - windowSize.height) / 2
        )
    }

    /// Returns the bottom-center position for a window on this screen with the given offset from dock
    func bottomCenterPoint(for windowSize: NSSize, dockOffset: CGFloat) -> NSPoint {
        NSPoint(
            x: visibleFrame.origin.x + (visibleFrame.width - windowSize.width) / 2,
            y: visibleFrame.origin.y + dockOffset
        )
    }
}
