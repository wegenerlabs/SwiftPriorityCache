import Foundation
@testable import SwiftPriorityCache
import Testing

private func withTempDirectory(_ body: (URL) async throws -> Void) async throws {
    let tmpRoot = FileManager.default.temporaryDirectory
    let dir = tmpRoot.appending(path: "SwiftPriorityCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}

private func data(ofSize size: Int) -> Data {
    Data(repeating: 0xAB, count: size)
}

private func url(_ path: String) -> URL {
    // path should include an extension when you want one, e.g. "/a/b.jpg"
    URL(string: "https://example.com\(path)")!
}

@Suite
struct SwiftPriorityCacheTests {
    @Test
    func readmeExample() async throws {
        try await withTempDirectory { dir in
            // Create or load a cache with a maximum size of 100 MB
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: 100 * 1024 * 1024, directory: dir)

            // Example URL and data
            let url = URL(string: "https://example.com/data.csv")!
            let (data, _) = try await URLSession.shared.data(from: url)

            // Save with a given priority (higher = more important)
            let saved = try await cache.save(priority: 10, data: data, remoteURL: url)
            print("Saved: \(saved)")

            // Check if the item is cached
            if await cache.contains(remoteURL: url),
               let localURL = cache.localURL(remoteURL: url)
            {
                print("Cache URL: \(localURL)")

                // Load the cached file back into memory
                let cachedData = try Data(contentsOf: localURL)
                print("Cache data size: \(cachedData.count)")
            }

            // Clear the cache
            try await cache.clear()
        }
    }

    @Test
    func initCreatesIndexWithDefaultMaxWhenNew() async throws {
        try await withTempDirectory { dir in
            // Ensure there's no pre-existing index file
            let indexURL = dir.appending(path: "SwiftPriorityCacheIndex.json", directoryHint: .notDirectory)
            #expect(!indexURL.isExistingRegularFile)

            let defaultMax: UInt64 = 1024
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: defaultMax, directory: dir)

            // The in-memory index should reflect the default max for a brand new cache
            #expect(await cache.maxTotalSize == defaultMax)

            // A brand-new index is not persisted until finalize/save/clear happens
            #expect(!indexURL.isExistingRegularFile)

            try await cache.clear()
            #expect(indexURL.isExistingRegularFile)
        }
    }

    @Test
    func saveInsertsByPriorityAndEvictsLowestUntilWithinMax() async throws {
        try await withTempDirectory { dir in
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: 120, directory: dir)

            // Save two items that fit exactly
            try #require(await cache.save(priority: 10, data: data(ofSize: 60), remoteURL: url("/img/high.jpg")))
            try #require(await cache.save(priority: 5, data: data(ofSize: 60), remoteURL: url("/img/low.jpg")))
            #expect(await cache.maxTotalSize == 120)
            #expect(await cache.contains(remoteURL: url("/img/high.jpg")))
            #expect(await cache.contains(remoteURL: url("/img/low.jpg")))
            #expect(await cache.index.totalSize == 120)

            // Add a third item that would push total to 180; lowest-priority (5) should be evicted.
            try #require(await cache.save(priority: 7, data: data(ofSize: 60), remoteURL: url("/img/mid.jpg")))

            // Post-eviction: should have priorities [10, 7], total 120; "low" removed from disk and index.
            let items = await cache.index.items
            let priorities = items.values.map { $0.priority }
            #expect(priorities == [10, 7])
            #expect(await cache.index.totalSize == 120)
            #expect(await cache.contains(remoteURL: url("/img/high.jpg")))
            #expect(await cache.contains(remoteURL: url("/img/mid.jpg")))
            #expect(!(await cache.contains(remoteURL: url("/img/low.jpg"))))
        }
    }

    @Test
    func saveWithSameKeyReplacesItemAndUpdatesIndex() async throws {
        try await withTempDirectory { dir in
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: 1000, directory: dir)
            let remote = url("/asset/file.bin")

            // Initial save
            try #require(await cache.save(priority: 3, data: data(ofSize: 200), remoteURL: remote))
            let idx1 = await cache.index
            #expect(idx1.items.count == 1)
            #expect(idx1.totalSize == 200)
            #expect(idx1.items[remote.sha256]?.priority == 3)

            // Save again with same key but different size/priority
            try #require(await cache.save(priority: 9, data: data(ofSize: 350), remoteURL: remote))
            let idx2 = await cache.index
            #expect(idx2.items.count == 1) // replaced, not duplicated
            #expect(idx2.totalSize == 350)
            #expect(idx2.items[remote.sha256]?.priority == 9)
            #expect(idx2.items[remote.sha256]?.size == 350)
        }
    }

    @Test
    func setMaxTotalSizeEvictsAsNeeded() async throws {
        try await withTempDirectory { dir in
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: 1000, directory: dir)

            try #require(await cache.save(priority: 10, data: data(ofSize: 30), remoteURL: url("/a.png")))
            try #require(await cache.save(priority: 5, data: data(ofSize: 30), remoteURL: url("/b.png")))
            #expect(await cache.index.totalSize == 60)

            // Lower max to force eviction of the lowest-priority item
            try await cache.setMaxTotalSize(30)

            #expect(await cache.maxTotalSize == 30)
            #expect(await cache.index.totalSize == 30)
            #expect(await cache.contains(remoteURL: url("/a.png")))
            #expect(!(await cache.contains(remoteURL: url("/b.png"))))
        }
    }

    @Test
    func clearRemovesFilesResetsIndexButKeepsMax() async throws {
        try await withTempDirectory { dir in
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: 512, directory: dir)

            try #require(await cache.save(priority: 1, data: data(ofSize: 100), remoteURL: url("/c.dat")))
            let beforeClearMax = await cache.maxTotalSize
            #expect(await cache.index.items.count == 1)

            try await cache.clear()

            // retained
            #expect(await cache.maxTotalSize == beforeClearMax)
            let idxAfterClear = await cache.index
            #expect(idxAfterClear.items.isEmpty)

            // Files are removed; localURL should be nil
            #expect(cache.localURL(remoteURL: url("/c.dat")) == nil)
            // And directory should exist again
            #expect(dir.isExistingDirectory)
        }
    }

    @Test
    func localURLHelpersMatchExpectedFilenames() async throws {
        try await withTempDirectory { dir in
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: 1000, directory: dir)
            let remoteWithExt = url("/pics/photo.png")
            let remoteNoExt = url("/docs/readme")

            try #require(await cache.save(priority: 4, data: data(ofSize: 10), remoteURL: remoteWithExt))
            try #require(await cache.save(priority: 4, data: data(ofSize: 10), remoteURL: remoteNoExt))

            // uncheckedLocalURL uses hash + optional extension
            let uncheckedExtURL = cache.uncheckedLocalURL(remoteURL: remoteWithExt)
            let uncheckedNoURL = cache.uncheckedLocalURL(remoteURL: remoteNoExt)
            let uncheckedExt = uncheckedExtURL.lastPathComponent
            let uncheckedNo = uncheckedNoURL.lastPathComponent

            #expect(uncheckedExt.hasSuffix(".png"))
            // no extension when remote has none
            #expect(!uncheckedNo.contains("."))

            // localURL should see both as existing files
            #expect(cache.localURL(remoteURL: remoteWithExt) != nil)
            #expect(cache.localURL(remoteURL: remoteNoExt) != nil)
        }
    }

    @Test
    func urlHelpers() async throws {
        try await withTempDirectory { dir in
            #expect(dir.isExistingDirectory)
            #expect(!dir.isExistingRegularFile)
            #expect(dir.capacity! > 0)
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: 0, directory: dir)
            try await cache.clear() // trigger index save
            let indexURL = dir.appending(path: "SwiftPriorityCacheIndex.json", directoryHint: .notDirectory)
            #expect(!indexURL.isExistingDirectory)
            #expect(indexURL.isExistingRegularFile)
        }
    }

    @Test
    func canSave() async throws {
        try await withTempDirectory { dir in
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: 8, directory: dir)
            let existingMemberURL = url("/pics/photo.png")
            let newMemberURL = url("/docs/readme")
            try #require(await cache.save(priority: 1, data: data(ofSize: 7), remoteURL: existingMemberURL))

            // vary priority
            #expect(!(await cache.canSave(priority: 0, size: 8, remoteURL: newMemberURL)))
            #expect(await cache.canSave(priority: 1, size: 8, remoteURL: newMemberURL))

            // vary size
            #expect(!(await cache.canSave(priority: 0, size: 2, remoteURL: newMemberURL)))
            #expect(await cache.canSave(priority: 0, size: 1, remoteURL: newMemberURL))

            // vary url
            #expect(!(await cache.canSave(priority: 0, size: 8, remoteURL: newMemberURL)))
            #expect(await cache.canSave(priority: 0, size: 8, remoteURL: existingMemberURL))
        }
    }

    @Test
    func testRemove() async throws {
        try await withTempDirectory { dir in
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: 100, directory: dir)
            let remoteURL = url("/pics/photo.png")
            try #require(await cache.save(priority: 6, data: data(ofSize: 100), remoteURL: remoteURL))
            try #require(await cache.index.totalSize == 100)
            let localURL = cache.localURL(remoteURL: remoteURL)!
            try #require(localURL.isExistingRegularFile)

            // remove
            try await cache.remove(remoteURL: remoteURL)
            #expect(await cache.index.totalSize == 0)
            #expect(cache.localURL(remoteURL: remoteURL) == nil)
        }
    }

    @Test
    func changePriority() async throws {
        try await withTempDirectory { dir in
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: 8, directory: dir)
            let existingMemberURL = url("/pics/photo.png")
            let newMemberURL = url("/docs/readme")
            try #require(await cache.save(priority: 2, data: data(ofSize: 8), remoteURL: existingMemberURL))

            // try to insert another item with priority 1
            #expect(!(await cache.canSave(priority: 1, size: 8, remoteURL: newMemberURL)))

            // change existing item priority to zero
            try #require(await cache.changePriority(0, remoteURL: existingMemberURL))

            // try again to insert another item with priority 1
            #expect(await cache.canSave(priority: 1, size: 8, remoteURL: newMemberURL))
        }
    }
}
