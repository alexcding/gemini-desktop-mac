//
//  PromptDirectoryWatcher.swift
//  GeminiDesktop
//

import Foundation
import CoreServices

final class PromptDirectoryWatcher: @unchecked Sendable {
    var onChange: (@MainActor () -> Void)?
    private var stream: FSEventStreamRef?
    private var debounceItem: DispatchWorkItem?
    private let lock = NSLock()

    func start(at path: String) {
        stop()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = NSArray(object: path)

        let callback: FSEventStreamCallback = { stream, context, numEvents, eventPaths, eventFlags, eventIds in
            let watcher = Unmanaged<PromptDirectoryWatcher>.fromOpaque(context!).takeUnretainedValue()
            watcher.debounce()
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        )

        guard let stream = stream else { return }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        FSEventStreamStart(stream)
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }

        debounceItem?.cancel()
        debounceItem = nil
    }

    private func debounce() {
        lock.lock()
        defer { lock.unlock() }

        debounceItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async { @MainActor [weak self] in
                self?.onChange?()
            }
        }

        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    deinit {
        stop()
    }
}
