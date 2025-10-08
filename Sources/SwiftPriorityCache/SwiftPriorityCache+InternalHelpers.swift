import Foundation

extension SwiftPriorityCache {
    private static func indexURL(directory: URL) -> URL {
        return directory.appending(path: "SwiftPriorityCacheIndex.json", directoryHint: .notDirectory)
    }

    static func makeDirectory() throws -> URL {
        let url = try defaultDirectory()
        if !url.isExistingDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func makeIndex(defaultMaxTotalSize: UInt64, directory: URL) throws -> SwiftPriorityCacheIndex {
        let url = indexURL(directory: directory)
        if url.isExistingRegularFile {
            return try JSONDecoder().decode(SwiftPriorityCacheIndex.self, from: Data(contentsOf: url))
        } else {
            return SwiftPriorityCacheIndex(maxTotalSize: defaultMaxTotalSize)
        }
    }

    static func saveIndex(index: SwiftPriorityCacheIndex, directory: URL) throws {
        let data = try JSONEncoder().encode(index)
        let tmpURL = FileManager
            .default
            .temporaryDirectory
            .appending(
                component: "SwiftPriorityCacheIndex-\(UUID().uuidString).json",
                directoryHint: .notDirectory
            )
        try data.write(to: tmpURL, options: .atomic)
        let dstURL = SwiftPriorityCache.indexURL(directory: directory)
        _ = try FileManager.default.replaceItemAt(dstURL, withItemAt: tmpURL)
    }
}
