//
//  ChatBarContent.swift
//  GeminiDesktop
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import WebKit

struct ChatBarView: View {
    let webView: WKWebView
    let onExpandToMain: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Minimal top bar with controls - fixed height
            TopControlBar(onExpand: onExpandToMain)
                .frame(height: 26)
            
            // WebView content - fills remaining space
            GeminiWebView(webView: webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Top Control Bar
struct TopControlBar: NSViewRepresentable {
    let onExpand: () -> Void
    
    func makeNSView(context: Context) -> TopBarView {
        let view = TopBarView()
        view.onExpand = onExpand
        return view
    }
    
    func updateNSView(_ nsView: TopBarView, context: Context) {}
}

class TopBarView: NSView {
    var onExpand: (() -> Void)?
    private var closeButton: NSButton!
    private var expandButton: NSButton!
    
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 26)
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
        setupButtons()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        
        // Add subtle bottom border
        let border = CALayer()
        border.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.15).cgColor
        border.frame = CGRect(x: 0, y: 0, width: 10000, height: 0.5)
        layer?.addSublayer(border)
    }
    
    private func setupButtons() {
        // Close button (left side) - with more padding
        closeButton = NSButton(frame: NSRect(x: 12, y: 5, width: 16, height: 16))
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeAction)
        (closeButton.cell as? NSButtonCell)?.imageScaling = .scaleProportionallyDown
        
        // Add hover effect
        let closeTrackingArea = NSTrackingArea(
            rect: closeButton.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: ["button": "close"]
        )
        closeButton.addTrackingArea(closeTrackingArea)
        addSubview(closeButton)
        
        // Expand button (right side) - with more padding
        expandButton = NSButton(frame: NSRect(x: 0, y: 5, width: 16, height: 16))
        expandButton.bezelStyle = .circular
        expandButton.isBordered = false
        expandButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Expand")
        expandButton.contentTintColor = .tertiaryLabelColor
        expandButton.target = self
        expandButton.action = #selector(expandAction)
        (expandButton.cell as? NSButtonCell)?.imageScaling = .scaleProportionallyDown
        
        // Add hover effect
        let expandTrackingArea = NSTrackingArea(
            rect: expandButton.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: ["button": "expand"]
        )
        expandButton.addTrackingArea(expandTrackingArea)
        addSubview(expandButton)
    }
    
    override func mouseEntered(with event: NSEvent) {
        guard let userInfo = event.trackingArea?.userInfo,
              let buttonType = userInfo["button"] as? String else { return }
        
        let button = buttonType == "close" ? closeButton : expandButton
        button?.contentTintColor = .secondaryLabelColor
    }
    
    override func mouseExited(with event: NSEvent) {
        guard let userInfo = event.trackingArea?.userInfo,
              let buttonType = userInfo["button"] as? String else { return }
        
        let button = buttonType == "close" ? closeButton : expandButton
        button?.contentTintColor = .tertiaryLabelColor
    }
    
    override func layout() {
        super.layout()
        // Position expand button on the right with more padding
        expandButton.frame.origin.x = bounds.width - expandButton.frame.width - 12
    }
    
    @objc private func closeAction() {
        window?.orderOut(nil)
    }
    
    @objc private func expandAction() {
        onExpand?()
    }
    
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
