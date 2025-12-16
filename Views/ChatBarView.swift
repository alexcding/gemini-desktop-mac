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
        ZStack(alignment: .topLeading) {
            GeminiWebViewRepresentable(webView: webView)

            Button(action: onExpandToMain) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: Constants.buttonFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: Constants.buttonSize, height: Constants.buttonSize)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(Constants.buttonPadding)
            .offset(x: Constants.buttonOffsetX)
        }
    }
}

extension ChatBarView {

    struct Constants {
        static let buttonFontSize: CGFloat = 14
        static let buttonSize: CGFloat = 38
        static let buttonPadding: CGFloat = 16
        static let buttonOffsetX: CGFloat = -2
    }

}
