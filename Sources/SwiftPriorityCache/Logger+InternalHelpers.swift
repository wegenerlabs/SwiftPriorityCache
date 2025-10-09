import os

enum LoggerCategory: String {
    case makeDirectory
    case capacity
}

extension Logger {
    init(_ category: LoggerCategory) {
        self.init(
            subsystem: SwiftPriorityCache.libraryBundleIdentifier,
            category: category.rawValue
        )
    }

    func error(_ error: Error) {
        log("\(error.localizedDescription, privacy: .public)")
    }
}
