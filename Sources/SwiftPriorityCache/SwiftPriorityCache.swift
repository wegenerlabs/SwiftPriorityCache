import Foundation
import OrderedCollections

public struct SwiftPriorityCacheItem: Codable, Sendable {
    public let priority: UInt64
    public let size: UInt64
    public let pathExtension: String
}

public struct SwiftPriorityCacheIndex: Codable, Sendable {
    public var maxTotalSize: UInt64
    public var items = OrderedDictionary<String, SwiftPriorityCacheItem>()

    init(maxTotalSize: UInt64) {
        self.maxTotalSize = maxTotalSize
    }
}

public extension SwiftPriorityCacheIndex {
    var totalSize: UInt64 {
        items.values.map { $0.size }.reduce(0, +)
    }
}

public actor SwiftPriorityCache {
    public let directory: URL
    public private(set) var index: SwiftPriorityCacheIndex

    /// Loads a cache in the default directory. Creates a new cache if none exists.
    public init(defaultMaxTotalSize: UInt64) throws {
        try self.init(defaultMaxTotalSize: defaultMaxTotalSize, directory: SwiftPriorityCache.makeDirectory())
    }

    /// Loads a cache in a custom directory. Creates a new cache if none exists.
    public init(defaultMaxTotalSize: UInt64, directory: URL) throws {
        self.directory = directory
        index = try SwiftPriorityCache.makeIndex(defaultMaxTotalSize: defaultMaxTotalSize, directory: directory)
    }

    /// Adds an item to the cache. Evicts other items if necessary. Returns true if the item was cached.
    public func save(priority: UInt64, data: Data, url: URL) throws -> Bool {
        // Check capacity
        let size = UInt64(data.count)
        guard canSave(priority: priority, size: size, url: url) else {
            return false
        }
        // Store item on disk
        try data.write(to: localURL(hash: url.sha256, pathExtension: url.pathExtension))
        // Remove any item with the same key
        index.items.removeValue(forKey: url.sha256)
        // Insert the item ahead of other items with equal or lower priority
        // Items with equal priority are evicted FIFO
        let insertionIndex: Int = index.items.values.firstIndex { item in
            item.priority <= priority
        } ?? index.items.values.endIndex
        index.items.updateValue(SwiftPriorityCacheItem(priority: priority, size: size, pathExtension: url.pathExtension), forKey: url.sha256, insertingAt: insertionIndex)
        // Evict items if necessary and persist index
        try finalize()
        return true
    }

    /// Gets the maximum total size of the cache.
    public var maxTotalSize: UInt64 {
        return index.maxTotalSize
    }

    /// Updates the maximum total size of the cache. Evicts items if necessary.
    public func setMaxTotalSize(_ newMaxTotalSize: UInt64) throws {
        // Update maximum total size of the cache
        index.maxTotalSize = newMaxTotalSize
        // Evict items if necessary and persist index
        try finalize()
    }

    private func finalize() throws {
        // Evict items from the back until the cache is within the size limit
        while index.totalSize > index.maxTotalSize {
            let element = index.items.elements.removeLast()
            try FileManager.default.removeItem(at: localURL(hash: element.key, pathExtension: element.value.pathExtension))
        }
        // Persist index
        try saveIndex()
    }

    private func localURL(hash: String, pathExtension: String) -> URL {
        let fileName = pathExtension.isEmpty ? hash : "\(hash).\(pathExtension)"
        return directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// Removes all cached items and resets the index. The maximum total size is retained.
    public func clear() throws {
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = SwiftPriorityCacheIndex(maxTotalSize: index.maxTotalSize)
        try saveIndex()
    }
}
