//
//  ChatBarContent.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import WebKit

/// An invisible drag region that initiates window dragging on mouseDown
struct WindowDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }

    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

class WindowDragNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTrackingArea()
    }

    private func setupTrackingArea() {
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
    }
}

struct ChatBarView: View {
    let webViewModel: WebViewModel
    let onExpandToMain: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeminiWebView(webView: webViewModel.wkWebView)

            // Expand button
            Button(action: onExpandToMain) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(16)

            // Invisible drag region in the top bar (between Gemini text and PRO badge)
            VStack {
                HStack {
                    Spacer()
                        .frame(width: Constants.dragRegionLeading)
                    WindowDragView()
                        .frame(maxWidth: .infinity, maxHeight: Constants.dragRegionHeight)
                    Spacer()
                        .frame(width: Constants.dragRegionTrailing)
                }
                .padding(.top, Constants.dragRegionTopPadding)
                Spacer()
            }
        }
    }

    private enum Constants {
        static let dragRegionLeading: CGFloat = 80   // skip past "Gemini" text
        static let dragRegionTrailing: CGFloat = 160 // skip past expand button + PRO badge + avatar
        static let dragRegionHeight: CGFloat = 38
        static let dragRegionTopPadding: CGFloat = 16
    }
}
