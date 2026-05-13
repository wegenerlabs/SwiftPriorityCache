import Combine
import Foundation
import OrderedCollections

public struct SwiftPriorityCacheItem: Codable, Sendable, Equatable {
    public let priority: UInt64
    public let size: UInt64
    public let pathExtension: String
}

public struct SwiftPriorityCacheIndex: Codable, Sendable, Equatable {
    public var maxTotalSize: UInt64
    public var items = OrderedDictionary<String, SwiftPriorityCacheItem>()
}

public extension SwiftPriorityCacheIndex {
    var totalSize: UInt64 {
        items.values.map { $0.size }.reduce(0, +)
    }
}

public actor SwiftPriorityCache {
    public let directory: URL
    public private(set) var index: SwiftPriorityCacheIndex
    public let availabilityNotifier: CacheAvailabilityNotifier?

    /// Loads a cache in the default directory. Creates a new cache if none exists.
    public init(defaultMaxTotalSize: UInt64, availabilityNotifier: CacheAvailabilityNotifier?) throws {
        try self.init(defaultMaxTotalSize: defaultMaxTotalSize, directory: SwiftPriorityCache.makeDirectory(), availabilityNotifier: availabilityNotifier)
    }

    /// Loads a cache in a custom directory that must already exist. Creates a new cache if none exists.
    public init(defaultMaxTotalSize: UInt64, directory: URL, availabilityNotifier: CacheAvailabilityNotifier?) throws {
        assert(directory.isExistingDirectory)
        self.directory = directory
        index = try SwiftPriorityCache.makeIndex(defaultMaxTotalSize: defaultMaxTotalSize, directory: directory)
        try SwiftPriorityCache.saveIndex(index: index, directory: directory)
        self.availabilityNotifier = availabilityNotifier
    }

    /// Adds an item to the cache. Evicts other items if necessary. Returns true if the item was cached.
    public func save(priority: UInt64, data: Data, remoteURL: URL) throws -> Bool {
        // Check capacity
        let size = UInt64(data.count)
        guard canSave(priority: priority, size: size, remoteURL: remoteURL) else {
            return false
        }
        // Store item on disk
        let hash = remoteURL.sha256
        try data.write(
            to: localURL(hash: hash, pathExtension: remoteURL.pathExtension),
            options: .atomic
        )
        // Update index
        try updateIndex(priority: priority, size: size, remoteURL: remoteURL)
        // Notify listeners
        notify(events: [CacheAvailabilityEvent(hash: hash, isAvailable: true)])
        return true
    }

    /// Changes the priority of a cached item. Returns true if the item is cached and if the priority was changed.
    public func changePriority(_ priority: UInt64, remoteURL: URL) throws -> Bool {
        // Determine if the index needs to change
        guard let oldItem = index.items[remoteURL.sha256], oldItem.priority != priority else {
            return false
        }
        // Update index
        try updateIndex(priority: priority, size: oldItem.size, remoteURL: remoteURL)
        return true
    }

    private func updateIndex(priority: UInt64, size: UInt64, remoteURL: URL) throws {
        // Remove any item with the same key
        index.items.removeValue(forKey: remoteURL.sha256)
        // Insert the item ahead of other items with equal or lower priority
        // Items with equal priority are evicted FIFO
        let insertionIndex: Int = index.items.values.firstIndex { item in
            item.priority <= priority
        } ?? index.items.values.endIndex
        index.items.updateValue(SwiftPriorityCacheItem(priority: priority, size: size, pathExtension: remoteURL.pathExtension), forKey: remoteURL.sha256, insertingAt: insertionIndex)
        // Evict items if necessary and persist index
        try finalize()
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
        var events = [CacheAvailabilityEvent]()
        while index.totalSize > index.maxTotalSize {
            let element = index.items.removeLast()
            try FileManager.default.removeItem(at: localURL(hash: element.key, pathExtension: element.value.pathExtension))
            events.append(CacheAvailabilityEvent(hash: element.key, isAvailable: false))
        }
        // Persist index
        try SwiftPriorityCache.saveIndex(index: index, directory: directory)
        // Notify listeners
        notify(events: events)
    }

    private func localURL(hash: String, pathExtension: String) -> URL {
        let fileName = pathExtension.isEmpty ? hash : "\(hash).\(pathExtension)"
        return directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// Remove the item representing the given remoteURL from the cache
    public func remove(remoteURL: URL) throws {
        if let localURL = localURL(remoteURL: remoteURL) {
            try FileManager.default.removeItem(at: localURL)
        }
        let hash = remoteURL.sha256
        if let _ = index.items.removeValue(forKey: hash) {
            try SwiftPriorityCache.saveIndex(index: index, directory: directory)
        }
        // Notify listeners
        notify(events: [CacheAvailabilityEvent(hash: hash, isAvailable: false)])
    }

    /// Removes all cached items and resets the index. The maximum total size is retained.
    public func clear() throws {
        let events = index.items.keys.map { CacheAvailabilityEvent(hash: $0, isAvailable: false) }
        try directory.clearDirectory()
        index = SwiftPriorityCacheIndex(maxTotalSize: index.maxTotalSize)
        try SwiftPriorityCache.saveIndex(index: index, directory: directory)
        // Notify listeners
        notify(events: events)
    }

    private func notify(events: [CacheAvailabilityEvent]) {
        guard !events.isEmpty else {
            return
        }
        DispatchQueue.main.async { [weak availabilityNotifier] in
            availabilityNotifier?.notify(events: events)
        }
    }
}
