import Foundation
@testable import SwiftPriorityCache
import Testing

private func withTempDirectory(_ body: (URL) async throws -> SwiftPriorityCache) async throws {
    let tmpRoot = FileManager.default.temporaryDirectory
    let dir = tmpRoot.appending(path: "SwiftPriorityCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = try await body(dir)
    try await cache.checkIntegrity()
}

private func data(ofSize size: Int) -> Data {
    Data(repeating: 0xAB, count: size)
}

private func url(_ path: String) -> URL {
    // path should include an extension when you want one, e.g. "/a/b.jpg"
    URL(string: "https://example.com\(path)")!
}

private extension SwiftPriorityCache {
    func checkIntegrity() throws {
        // 1) priorities must be non-increasing
        let values = index.items.values
        if values.count > 1 {
            for i in 1 ..< values.count {
                let prev = values[values.index(values.startIndex, offsetBy: i - 1)]
                let curr = values[values.index(values.startIndex, offsetBy: i)]
                #expect(
                    prev.priority >= curr.priority
                )
            }
        }

        // 2) totalSize must equal the sum of item sizes
        let summedSizes = values.map { $0.size }.reduce(0, +)
        #expect(
            summedSizes == index.totalSize
        )

        // 3) totalSize must not exceed maxTotalSize
        #expect(
            index.totalSize <= index.maxTotalSize
        )

        // 4) each indexed file must exist on disk with the recorded size
        var actualTotal: UInt64 = 0
        for (hash, item) in index.items {
            let fileName = item.pathExtension.isEmpty ? hash : "\(hash).\(item.pathExtension)"
            let fileURL = directory.appending(path: fileName, directoryHint: .notDirectory)

            #expect(
                fileURL.isExistingRegularFile
            )

            let data = try Data(contentsOf: fileURL)
            actualTotal += UInt64(data.count)
            #expect(
                UInt64(data.count) == item.size
            )
        }

        // 5) there must not be any orphaned files on disk
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        )
        #expect(urls.count == index.items.count + 1)
    }
}

@Suite
struct SwiftPriorityCacheTests {
    @Test
    func simpleExample() async throws {
        try await withTempDirectory { dir in
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: 100 * 1024 * 1024, directory: dir)

            // Load remote data
            let url = URL(string: "https://example.com/data.csv")!
            let (data, _) = try await URLSession.shared.data(from: url)
            try #require(data.count > 0)

            // Save with a given priority
            let saved = try await cache.save(priority: 10, data: data, remoteURL: url)
            #expect(saved)

            // Check if the item is cached
            if await cache.contains(remoteURL: url),
               let localURL = cache.localURL(remoteURL: url)
            {
                let cachedData = try Data(contentsOf: localURL)
                #expect(cachedData == data)
            }

            // Check index item
            let key = url.sha256
            assert(key == "16c128e58778706ecf5969cfacbdedd39516e682f42c1b638c067e8fbf2f4f94")
            let item = await cache.index.items[url.sha256]!
            #expect(item.priority == 10)
            #expect(item.size == data.count)
            #expect(item.pathExtension == "csv")

            // Check cache integrity
            try await cache.checkIntegrity()

            // Remove the item
            try await cache.remove(remoteURL: url)
            #expect(await cache.index.totalSize == 0)

            return cache
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

            try await cache.checkIntegrity()
            try await cache.clear()
            #expect(indexURL.isExistingRegularFile)

            return cache
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

            return cache
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

            return cache
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

            return cache
        }
    }

    @Test
    func clearRemovesFilesResetsIndexButKeepsMax() async throws {
        try await withTempDirectory { dir in
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: 512, directory: dir)

            try #require(await cache.save(priority: 1, data: data(ofSize: 100), remoteURL: url("/c.dat")))
            let beforeClearMax = await cache.maxTotalSize
            #expect(await cache.index.items.count == 1)

            try await cache.checkIntegrity()
            try await cache.clear()

            // retained
            #expect(await cache.maxTotalSize == beforeClearMax)
            let idxAfterClear = await cache.index
            #expect(idxAfterClear.items.isEmpty)

            // Files are removed; localURL should be nil
            #expect(cache.localURL(remoteURL: url("/c.dat")) == nil)
            // And directory should exist again
            #expect(dir.isExistingDirectory)

            return cache
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

            return cache
        }
    }

    @Test
    func urlHelpers() async throws {
        try await withTempDirectory { dir in
            #expect(dir.isExistingDirectory)
            #expect(!dir.isExistingRegularFile)
            #expect(dir.capacity! > 0)
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: 0, directory: dir)
            try await cache.checkIntegrity()
            try await cache.clear() // trigger index save
            let indexURL = dir.appending(path: "SwiftPriorityCacheIndex.json", directoryHint: .notDirectory)
            #expect(!indexURL.isExistingDirectory)
            #expect(indexURL.isExistingRegularFile)

            return cache
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
            #expect(await cache.canSave(priority: 2, size: 8, remoteURL: newMemberURL))

            // vary size
            #expect(!(await cache.canSave(priority: 0, size: 2, remoteURL: newMemberURL)))
            #expect(await cache.canSave(priority: 0, size: 1, remoteURL: newMemberURL))

            // vary url
            #expect(!(await cache.canSave(priority: 0, size: 8, remoteURL: newMemberURL)))
            #expect(await cache.canSave(priority: 0, size: 8, remoteURL: existingMemberURL))

            return cache
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

            return cache
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

            return cache
        }
    }

    @Test
    func fifoEvictionOrder() async throws {
        try await withTempDirectory { dir in
            let cache = try SwiftPriorityCache(defaultMaxTotalSize: 2, directory: dir)
            let url1 = url("/pics/photo1.png")
            let url2 = url("/pics/photo2.png")
            let url3 = url("/pics/photo3.png")

            try #require(await cache.save(priority: 1, data: data(ofSize: 1), remoteURL: url1))
            try #require(await cache.save(priority: 1, data: data(ofSize: 1), remoteURL: url2))
            #expect(cache.localURL(remoteURL: url1) != nil)
            #expect(cache.localURL(remoteURL: url2) != nil)

            #expect(await cache.canSave(priority: 1, size: 1, remoteURL: url1)) // replace: can save
            #expect(await cache.canSave(priority: 1, size: 1, remoteURL: url2)) // replace: can save
            #expect(await cache.canSave(priority: 0, size: 1, remoteURL: url3) == false) // lower pri: cannot save
            #expect(await cache.canSave(priority: 1, size: 1, remoteURL: url3) == false) // equal pri: cannot save
            #expect(await cache.canSave(priority: 2, size: 1, remoteURL: url3)) // higher pri: can save

            try #require(await cache.save(priority: 2, data: data(ofSize: 1), remoteURL: url3)) // evicts url1
            #expect(cache.localURL(remoteURL: url1) == nil)
            #expect(cache.localURL(remoteURL: url2) != nil)
            #expect(cache.localURL(remoteURL: url3) != nil)

            return cache
        }
    }

    @Test
    func defaultDirectoryCache() async throws {
        let url1 = try SwiftPriorityCache.defaultDirectory()
        let url2 = try SwiftPriorityCache.makeDirectory()
        #expect(url1 == url2)
        #expect(url1.lastPathComponent == "com.wegenerlabs.SwiftPriorityCache")

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url2.path, isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)

        let resourceValues = try url2.resourceValues(forKeys: [.isDirectoryKey, .isExcludedFromBackupKey])
        #expect(resourceValues.isDirectory == true)
        #expect(resourceValues.isExcludedFromBackup == true)

        let defaultMaxTotalSize: UInt64 = 6
        var cache: SwiftPriorityCache? = try SwiftPriorityCache(defaultMaxTotalSize: defaultMaxTotalSize)
        #expect(await cache?.directory == url2)

        let filePriority: UInt64 = 2
        let fileSize: UInt64 = 5
        let fileData = data(ofSize: Int(fileSize))
        let fileURL = url("/pics/photo1.png")
        #expect(try await cache!.save(priority: filePriority, data: fileData, remoteURL: fileURL))
        let localURL = cache!.localURL(remoteURL: fileURL)!
        #expect(try Data(contentsOf: localURL) == fileData)
        let expectedIndex = SwiftPriorityCacheIndex(
            maxTotalSize: defaultMaxTotalSize,
            items: [
                fileURL.sha256: SwiftPriorityCacheItem(priority: filePriority, size: fileSize, pathExtension: "png"),
            ]
        )
        #expect(await cache!.index == expectedIndex)
        try await cache?.clear()

        cache = nil
        try FileManager.default.removeItem(at: url2)
    }
}
