import CryptoKit
import Foundation
import os

extension URL {
    var isExistingDirectory: Bool {
        return (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    var isExistingRegularFile: Bool {
        return (try? resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    var sha256: String {
        let bytes = Data(absoluteString.utf8)
        let digest = SHA256.hash(data: bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var capacity: UInt64? {
        do {
            guard let capacity = try resourceValues(
                forKeys: [
                    .volumeAvailableCapacityKey,
                ]
            ).volumeAvailableCapacity else {
                return nil
            }
            guard capacity > 0 else {
                return nil
            }
            return UInt64(capacity)
        } catch {
            Logger(.capacity).error(error)
            return nil
        }
    }

    func clearDirectory() throws {
        assert(isExistingDirectory)
        let contents = try FileManager.default.contentsOfDirectory(
            at: self,
            includingPropertiesForKeys: nil,
            options: []
        )
        for item in contents {
            try FileManager.default.removeItem(at: item)
        }
    }
}
