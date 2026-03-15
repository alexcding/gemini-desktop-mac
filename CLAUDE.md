# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Gemini Desktop for macOS is an unofficial macOS desktop wrapper for Google Gemini (`https://gemini.google.com/app`). It's a SwiftUI + AppKit app using WKWebView to host the Gemini web interface with native macOS enhancements.

**Requirements:** macOS 14.0 (Sonoma)+, Xcode 15+

## Build & Run

Open `GeminiDesktop.xcodeproj` in Xcode and run with Cmd+R. There is no command-line build script — this is an Xcode-native project.

Dependencies are managed via Swift Package Manager and resolved automatically by Xcode:
- **KeyboardShortcuts** v2.4.0 — global keyboard shortcut recording in Settings

## Architecture

**Pattern: MVVM + Coordinator**

- **`AppCoordinator`** — Central hub using `@Observable`. Manages both the main window and floating chat bar, controls WebView lifecycle, and coordinates multi-screen window positioning.
- **`WebViewModel`** — Observable wrapper around `WKWebView`. Tracks nav state, zoom level (persisted to UserDefaults), and home-page detection.
- **`ChatBarPanel`** — Custom `NSPanel` subclass for the floating chat overlay. Handles click-outside dismissal via `NSEvent.addGlobalMonitorForEvents`, JavaScript evaluation to focus input/trigger new chats, auto-expansion when a conversation starts (via polling), and size persistence.

**Key constraint:** A WKWebView can only exist in one view hierarchy at a time. `AppCoordinator` manages moving the single shared WebView between the main window and the chat bar panel.

**JavaScript injection** (`WebKit/UserScripts.swift`) handles two cases:
1. IME fix — resolves double-Enter issue for Chinese/Japanese/Korean input by tracking composition state and auto-clicking send after composition ends.
2. Console log bridge (DEBUG builds only) — routes `console.log` to Swift.

## Code Organization

```
App/            # @main app + AppDelegate
ChatBar/        # Floating panel (NSPanel subclass + SwiftUI view)
Coordinators/   # AppCoordinator (central state & navigation)
WebKit/         # GeminiWebView (NSViewRepresentable), WebViewModel, UserScripts
Views/          # MainWindowView, SettingsView, MenuBarView
Utils/          # UserDefaultsKeys (settings keys + theme helpers), NSScreen extensions
Resources/      # Assets, entitlements, Info.plist
```

## Settings & State Persistence

All user preferences are stored in `UserDefaults` via keys defined in `Utils/UserDefaultsKeys.swift`. This includes panel dimensions, zoom level, theme, custom toolbar colors, and window visibility options.

## Toolbar Theming

The app uses Google's official Gemini colors for the toolbar: `#34A853` (light) and `#81C995` (dark), applied via `NSAppearance` observation in `GeminiDesktopApp.swift`. Custom colors are also user-configurable in Settings.
