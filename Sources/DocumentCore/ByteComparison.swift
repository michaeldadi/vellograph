import Foundation

public enum ByteComparisonError: LocalizedError {
    case changedDuringRead

    public var errorDescription: String? {
        "A file changed during the byte comparison. Refresh and try again."
    }
}

public enum ByteComparison {
    /// Compares exact bytes with bounded memory. A mutation during the read
    /// invalidates the result instead of reporting an unreliable match.
    public static func areIdentical(_ left: URL, _ right: URL) throws -> Bool {
        let leftBefore = try Stamp(left)
        let rightBefore = try Stamp(right)
        if leftBefore.size != rightBefore.size { return false }

        let leftHandle = try FileHandle(forReadingFrom: left)
        defer { try? leftHandle.close() }
        let rightHandle = try FileHandle(forReadingFrom: right)
        defer { try? rightHandle.close() }
        var identical = true
        while true {
            try Task<Never, Never>.checkCancellation()
            let a = try readBlock(leftHandle)
            let b = try readBlock(rightHandle)
            if a != b { identical = false; break }
            if a.isEmpty { break }
        }
        guard leftBefore == (try Stamp(left)), rightBefore == (try Stamp(right)) else {
            throw ByteComparisonError.changedDuringRead
        }
        return identical
    }

    private static func readBlock(_ handle: FileHandle) throws -> Data {
        var result = Data()
        while result.count < 65_536 {
            let chunk = try handle.read(upToCount: 65_536 - result.count) ?? Data()
            if chunk.isEmpty { break }
            result.append(chunk)
        }
        return result
    }

    private struct Stamp: Equatable {
        let size: UInt64
        let modified: Date?
        let fileNumber: UInt64?

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modified = attributes[.modificationDate] as? Date
            fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        }
    }
}
