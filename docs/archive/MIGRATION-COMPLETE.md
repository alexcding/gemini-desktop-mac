# Swift 6 + macOS 15 + Sandbox Migration — Complete

**Date Completed:** March 15, 2026
**Status:** ✅ All 7 phases complete. App builds cleanly with Swift 6 strict concurrency enabled.

---

## Executive Summary

The Gemini Desktop Mac app has been successfully migrated to:
- **Swift 6** with strict concurrency checking enabled (`SWIFT_STRICT_CONCURRENCY = complete`)
- **macOS 15.0** deployment target
- **Full App Sandbox** with all required entitlements declared

**Build Result:** 0 errors, 0 warnings, 0 strict concurrency violations.

---

## Phases Completed

### Phase 1: Entitlements & Build Settings ✅
- Sandbox enabled with 6 required entitlements
- macOS deployment target bumped to 15.0
- Swift version updated to 6.0
- Security-scoped bookmark infrastructure implemented (`BookmarkStore`)

### Phase 2: Actor Isolation ✅
- `@MainActor` applied to `AppCoordinator`, `WebViewModel`, `AppTheme`
- KVO callbacks replaced with `Task { @MainActor in }` (safe threading)
- `Mutex<URL?>` protecting mutable state in `GeminiWebView.Coordinator`
- NotificationCenter pattern eliminated in favor of direct weak reference in `AppDelegate`

### Phase 3: Concurrency Migration ✅
- Replaced all `DispatchQueue.main.asyncAfter` with `Task { @MainActor in } + Task.sleep`
- Adopted `defaultWindowPlacement` for initial window creation
- Kept `centerWindow(_:on:)` for re-show positioning (two distinct problems, two solutions)
- One legitimate `DispatchQueue.main.async` retained in `MainWindowView.makeNSView`

### Phase 4: Polling Timer Elimination ✅
- Replaced 1Hz `Timer` with event-driven `WKScriptMessageHandler`
- `MutationObserver` in JavaScript detects conversation start exactly once
- `ChatBarPanel` registers/deregisters itself directly as handler (no notification bridge)
- CPU overhead eliminated, energy efficiency improved

### Phase 5: AppKit Consolidation ✅
- `NSApp.setActivationPolicy` calls consolidated into `AppCoordinator.updateActivationPolicy()`
- Duplicate `openNewChat()` JavaScript unified (passed as closure)
- Window-finding logic consolidated to `AppCoordinator.findMainWindow()`
- Force-unwrap guarded in download destination logic

### Phase 6: Strict Concurrency Enabled ✅
- `SWIFT_STRICT_CONCURRENCY = complete` in both Debug and Release configurations
- All Sendability violations resolved
- Zero compiler warnings under strict mode

### Phase 7: macOS 15 Opportunistic APIs ✅
- `defaultWindowPlacement` adopted for window creation
- `NSWindow.windowingBehaviors` evaluated (no simplification over existing code)
- `pushWindow` environment evaluated (retained current pattern)

---

## Key Architectural Changes

### Thread Safety Paradigm Shift
**Before:** Mix of `DispatchQueue.main.async`, KVO, implicit main-thread assumptions
**After:** Explicit `@MainActor` annotations, `Task` for async hops, `Mutex` for shared state

### Window Management Clarity
**Before:** Retry-polling loop (`centerNewlyCreatedWindow`) conflating two problems
**After:** Clear separation — `defaultWindowPlacement` for creation, `centerWindow` for re-show

### Notification Cleanup
**Before:** Two separate notification patterns (open main window, conversation started)
**After:** Direct weak reference for app delegate; direct handler registration for web events

### Polling Eliminated
**Before:** 1Hz JavaScript evaluation overhead
**After:** Event-driven through `WKScriptMessageHandler` + `MutationObserver`

---

## Testing Checklist (Regression)

All functional tests pass:
- ✅ App launches normally (dock icon visible)
- ✅ App launches with "Hide Dock Icon" (accessory mode)
- ✅ App launches with "Hide Window at Launch"
- ✅ Main Gemini window loads and fully functional
- ✅ Back/forward navigation works
- ✅ Zoom in/out/reset works and persists
- ✅ New Chat (Cmd+N) works
- ✅ Chat bar opens via keyboard shortcut
- ✅ Chat bar opens via menu bar
- ✅ Chat bar auto-expands when Gemini responds (event-driven, no polling)
- ✅ Chat bar Esc dismisses
- ✅ Chat bar Cmd+N resets to initial size
- ✅ Expand from chat bar to main window works
- ✅ Multi-display: chat bar on correct screen
- ✅ File download lands in ~/Downloads
- ✅ File upload via picker works
- ✅ Settings persist across restarts
- ✅ Theme switching (Light/Dark/System) works
- ✅ Custom toolbar color persists
- ✅ Launch at login toggle works
- ✅ Reset website data clears session
- ✅ Full screen mode works

---

## Files Modified

### Core Concurrency Changes
- `Coordinators/AppCoordinator.swift` — @MainActor, eliminated notification pattern
- `WebKit/WebViewModel.swift` — @MainActor, KVO callback fix, Task.sleep
- `WebKit/GeminiWebView.swift` — Mutex, nonisolated delegate methods
- `ChatBar/ChatBarPanel.swift` — eliminated polling timer, WKScriptMessageHandler registration
- `App/AppDelegate.swift` — weak coordinator reference
- `App/GeminiDesktopApp.swift` — SWIFT_VERSION updated, coordinator wiring

### New Files
- `Utils/BookmarkStore.swift` — security-scoped bookmark management

### Configuration
- `Resources/GeminiDesktop.entitlements` — full sandbox + 6 required capabilities
- `GeminiDesktop.xcodeproj/project.pbxproj` — MACOSX_DEPLOYMENT_TARGET=15.0, SWIFT_VERSION=6.0, SWIFT_STRICT_CONCURRENCY=complete

---

## Compiler Validation

```
$ xcodebuild -scheme GeminiDesktop -destination 'platform=macOS' build
...
** BUILD SUCCEEDED **
```

- Swift version: 6.0
- Deployment target: macOS 15.0
- Strict concurrency: enabled
- Errors: 0
- Warnings: 0

---

## Deployment Readiness

The app is now ready for:
1. **App Sandbox submission** to the Mac App Store (all entitlements declared, hardened runtime enabled)
2. **Swift 6 ecosystem adoption** (future framework updates will work correctly with strict concurrency)
3. **Future macOS features** (built on macOS 15 APIs with forward compatibility)
4. **Performance improvements** (event-driven architecture, eliminated polling overhead)

---

## Next Steps (Future Work)

These items remain out of scope for this migration but are now architecturally ready:

1. **Prompts & Artifacts Feature**
   - `BookmarkStore` is ready to support user-selected directories
   - Security-scoped bookmarks will persist directory access
   - Copy-to-clipboard UI can be added to toolbar

2. **Code Sign & Notarization**
   - App is fully sandboxed and ready for Apple notarization
   - Consider signing with a developer certificate before distribution

3. **Integration Tests**
   - Swift 6 strict concurrency makes concurrency bugs visible at compile time
   - Unit tests can now safely assume `@MainActor` isolation guarantees

---

## Migration Insights

### What Worked Well
- **Phased approach** — enabled strict concurrency in Phase 6 only, after all foundations were solid
- **`Mutex` from Synchronization framework** — proper tool for macOS 15 / Swift 6
- **Direct weak references** — simpler and safer than notification patterns
- **Event-driven design** — replacing polling with `WKScriptMessageHandler` had the highest architectural impact

### Challenges Overcome
- **AppKit/SwiftUI boundary** — mixed declarative and imperative window lifecycle required careful ownership rules
- **WebKit delegate thread assumptions** — delegates are not `@MainActor` guaranteed; required `nonisolated` methods
- **Notification token leaks** — eliminated two separate notification patterns to avoid this class of bug

### Lessons Learned
- **Do not use `nonisolated(unsafe)`** — appears simple but defeats the purpose of strict concurrency
- **Do not use `MainActor.assumeIsolated` in callbacks** — crashes at runtime if threading assumptions change
- **`Task { @MainActor in }` is idiomatic** — safe hop regardless of caller thread
- **Security-scoped bookmarks must be implemented first** — sandboxing without them causes silent file access failures

---

## References

- `docs/research-swift6-migration.md` — detailed audit of concurrency patterns, AppKit surface, entitlements
- `docs/plan-swift6-migration.md` — step-by-step implementation plan with completion tracking
- `docs/research-boris-tane-workflow.md` — the annotation-driven workflow that produced this migration quality
