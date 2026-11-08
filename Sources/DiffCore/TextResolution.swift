import Foundation

public enum TextChangeChoice: String, Sendable, CaseIterable {
    case left = "A"
    case right = "B"
    case both = "Both"
    case neither = "Neither"
}

public enum TextResolutionError: Error, Equatable, LocalizedError {
    case unresolvedChange(Int)

    public var errorDescription: String? {
        switch self {
        case .unresolvedChange(let id): "Choose a result for change \(id + 1) before building the output."
        }
    }
}

public enum TextResolution {
    public static func resolve(
        left: [TextLine], right: [TextLine], diff: DiffResult,
        choices: [Int: TextChangeChoice]
    ) throws -> [TextLine] {
        var output: [TextLine] = []
        var cursor = 0
        for hunk in diff.hunks {
            try Task<Never, Never>.checkCancellation()
            guard let choice = choices[hunk.id] else {
                throw TextResolutionError.unresolvedChange(hunk.id)
            }
            output += left[cursor..<hunk.oldRange.lowerBound]
            switch choice {
            case .left: output += left[hunk.oldRange]
            case .right: output += right[hunk.newRange]
            case .both: output += left[hunk.oldRange] + right[hunk.newRange]
            case .neither: break
            }
            cursor = hunk.oldRange.upperBound
        }
        output += left[cursor...]
        return output
    }
}
