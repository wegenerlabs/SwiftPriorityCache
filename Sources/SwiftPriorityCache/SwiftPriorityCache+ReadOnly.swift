import Foundation

/// Public read-only API for `SwiftPriorityCache`.
public extension SwiftPriorityCache {
    /// Determines whether an item can be cached.
    func canSave(priority newPriority: UInt64, size newSize: UInt64, remoteURL newURL: URL) -> Bool {
        if newSize > index.maxTotalSize {
            // Short-circuit: Item is larger than allowed cache size
            return false
        }
        if let capacity = directory.capacity, capacity > 0, newSize > capacity {
            // Short-circuit: Item is larger than available disk capacity
            return false
        }

        // Accumulate size of competing items
        var accumulatedSize: UInt64 = 0
        for (existingKey, existingItem) in index.items {
            guard existingItem.priority >= newPriority else {
                // OK to break because items are sorted by descending priority
                break
            }
            guard existingKey != newURL.sha256 else {
                // Do not count same key item (it will be replaced)
                continue
            }
            accumulatedSize += existingItem.size
            guard accumulatedSize + newSize <= index.maxTotalSize else {
                // Short-circuit: Limit is exceeded
                return false
            }
        }

        return accumulatedSize + newSize <= index.maxTotalSize
    }

    /// Returns true if an item with a given remote URL is cached.
    func contains(remoteURL: URL) -> Bool {
        return index.items[remoteURL.sha256] != nil
    }

    /// Returns a local cache URL for a given remote URL. Does not check existence.
    nonisolated func uncheckedLocalURL(remoteURL: URL) -> URL {
        let fileName = remoteURL.pathExtension.isEmpty ? remoteURL.sha256 : "\(remoteURL.sha256).\(remoteURL.pathExtension)"
        return directory.appending(component: fileName, directoryHint: .notDirectory)
    }

    /// Returns a local cache URL for a given remote URL. Checks existence via the file system.
    nonisolated func localURL(remoteURL: URL) -> URL? {
        let localURL = uncheckedLocalURL(remoteURL: remoteURL)
        if !localURL.isExistingRegularFile {
            return nil
        }
        return localURL
    }

    static func defaultDirectory() throws -> URL {
        // `.cachesDirectory` is not used because this cache is designed to be cleared manually
        return try URL(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
        ).appending(
            component: "SwiftPriorityCache",
            directoryHint: .isDirectory
        )
    }
}
