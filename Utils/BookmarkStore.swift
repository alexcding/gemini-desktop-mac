import Foundation

final class BookmarkStore {
    func saveBookmark(for url: URL, key: UserDefaultsKeys) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: key.rawValue)
    }

    func resolveBookmark(for key: UserDefaultsKeys) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key.rawValue) else { return nil }
        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale, let url { try? saveBookmark(for: url, key: key) }
        return url
    }

    func withBookmarkedURL<T>(
        for key: UserDefaultsKeys,
        _ body: (URL) throws -> T
    ) rethrows -> T? {
        guard let url = resolveBookmark(for: key) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return try body(url)
    }
}
