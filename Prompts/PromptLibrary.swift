//
//  PromptLibrary.swift
//  GeminiDesktop
//

import Foundation
import Observation

@MainActor
@Observable
final class PromptLibrary {
    private(set) var rootNodes: [PromptNode] = []
    private(set) var allFiles: [PromptFile] = []
    private(set) var loadError: String? = nil

    private var watcher: PromptDirectoryWatcher?
    private let bookmarkStore = BookmarkStore()

    func reload() {
        loadError = nil
        rootNodes = []
        allFiles = []

        if let _ = try? bookmarkStore.withBookmarkedURL(for: .promptsDirectoryBookmark, { dirURL in
            self.buildTree(at: dirURL)
        }) {
            // Success
        } else {
            self.loadError = "Prompts directory not accessible"
        }
    }

    func startWatching() {
        guard let dirURL = bookmarkStore.resolveBookmark(for: .promptsDirectoryBookmark) else { return }

        let watcher = PromptDirectoryWatcher()
        watcher.onChange = { [weak self] in
            self?.reload()
        }
        watcher.start(at: dirURL.path)
        self.watcher = watcher
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    private func buildTree(at dirURL: URL) {
        let fileManager = FileManager.default
        let resourceKeys = Set<URLResourceKey>([.isDirectoryKey, .isHiddenKey])

        guard let enumerator = fileManager.enumerator(
            at: dirURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            self.loadError = "Cannot read directory"
            return
        }

        var filesByParent: [URL: [PromptFile]] = [:]
        var dirsByParent: [URL: [URL]] = [:]

        for case let url as URL in enumerator {
            do {
                let values = try url.resourceValues(forKeys: resourceKeys)
                guard let isDir = values.isDirectory else { continue }

                if isDir {
                    // Skip empty directories; we'll add them if they contain files
                    continue
                } else if url.pathExtension.lowercased() == "md" {
                    let file = PromptFile.load(from: url)
                    let parent = url.deletingLastPathComponent()
                    filesByParent[parent, default: []].append(file)
                    allFiles.append(file)
                }
            } catch {
                continue
            }
        }

        // Build tree recursively
        rootNodes = buildNodes(for: dirURL, files: filesByParent, dirs: dirsByParent)
    }

    private func buildNodes(
        for dirURL: URL,
        files filesByParent: [URL: [PromptFile]],
        dirs dirsByParent: [URL: [URL]]
    ) -> [PromptNode] {
        var nodes: [PromptNode] = []

        // Add files in this directory
        if let filesHere = filesByParent[dirURL] {
            for file in filesHere.sorted(by: { $0.displayTitle < $1.displayTitle }) {
                nodes.append(.file(file))
            }
        }

        // Add subdirectories with their own nodes
        let fileManager = FileManager.default
        do {
            let subURLs = try fileManager.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for subURL in subURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let values = try subURL.resourceValues(forKeys: [.isDirectoryKey])
                    guard values.isDirectory == true else { continue }

                    let subNodes = buildNodes(for: subURL, files: filesByParent, dirs: dirsByParent)
                    if !subNodes.isEmpty {
                        nodes.append(.directory(name: subURL.lastPathComponent, children: subNodes))
                    }
                } catch {
                    continue
                }
            }
        } catch {
            // Ignore read errors for subdirectories
        }

        return nodes
    }
}
