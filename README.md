# SwiftPriorityCache
A lightweight, actor-isolated, disk-backed cache written in Swift.

The cache has a maximum size and items are stored with priorities. Lower-priority items are evicted automatically to make room for higher-priority items. There is no cache expiry.

Please refer to the comments in the source code for exact implementation details.

## Quick Start
```swift
import Foundation
import SwiftPriorityCache

// Create or load a cache with a maximum size of 100 MB
let cache = try SwiftPriorityCache(defaultMaxTotalSize: 100 * 1024 * 1024)

// Example URL and data
let url = URL(string: "https://example.com/data.csv")!
let (data, _) = try await URLSession.shared.data(from: url)

// Save with a given priority (higher = more important)
let saved = try await cache.save(priority: 10, data: data, remoteURL: url)
print("Saved: \(saved)")

// Check if the item is cached
if let localURL = cache.localURL(remoteURL: url) {
    print("Cache URL: \(localURL)")
}

// Clear the cache
try await cache.clear()
```

## Dependencies
- CryptoKit
- Foundation
- [OrderedCollections](https://github.com/apple/swift-collections)

## License
MIT License
