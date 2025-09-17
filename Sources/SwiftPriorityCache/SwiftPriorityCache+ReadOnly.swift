import Foundation

/// Public read-only API for `SwiftPriorityCache`.
public extension SwiftPriorityCache {
    /// Determines whether an item can be cached.
    func canSave(priority newPriority: UInt64, size newSize: UInt64, url newURL: URL) -> Bool {
        if newSize > index.maxTotalSize {
            // Short-circuit: Item is larger than allowed cache size
            return false
        }
        if let capacity =  directory.capacity, newSize > capacity {
            // Short-circuit: Item is larger than available disk capacity
            return false
        }

        // Accumulate size of items with greater priority, except same-key item
        var accumulatedSize: UInt64 = 0
        for (existingKey, existingItem) in index.items {
            if existingItem.priority > newPriority {
                if existingKey != newURL.sha256 {
                    accumulatedSize += existingItem.size
                    if accumulatedSize + newSize > index.maxTotalSize {
                        // Short-circuit: Limit is exceeded
                        return false
                    }
                }
            } else {
                // OK to break because items are sorted by descending priority
                break
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
}
