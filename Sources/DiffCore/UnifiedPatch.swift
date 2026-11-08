import Foundation

public enum UnifiedPatch {
    public static func generate(
        oldLabel: String,
        newLabel: String,
        old: [TextLine],
        new: [TextLine],
        diff: DiffResult,
        context: Int = 3
    ) -> String {
        let operations = diff.operations
        let oldHeader = oldLabel.replacingOccurrences(of: "\n", with: "\\n")
        let newHeader = newLabel.replacingOccurrences(of: "\n", with: "\\n")
        var patch = "--- \(oldHeader)\n+++ \(newHeader)\n"
        let context = max(0, context)
        var ranges: [Range<Int>] = []
        for index in operations.indices {
            if case .equal = operations[index] { continue }
            let start = max(0, index - context)
            let end = min(operations.count, index + context + 1)
            if let last = ranges.indices.last, start <= ranges[last].upperBound {
                ranges[last] = ranges[last].lowerBound..<max(ranges[last].upperBound, end)
            } else {
                ranges.append(start..<end)
            }
        }
        if ranges.isEmpty { return patch }

        var oldBefore = Array(repeating: 0, count: operations.count + 1)
        var newBefore = Array(repeating: 0, count: operations.count + 1)
        for index in operations.indices {
            oldBefore[index + 1] = oldBefore[index]
            newBefore[index + 1] = newBefore[index]
            switch operations[index] {
            case .equal: oldBefore[index + 1] += 1; newBefore[index + 1] += 1
            case .delete: oldBefore[index + 1] += 1
            case .insert: newBefore[index + 1] += 1
            }
        }
        for range in ranges {
            let oldCount = oldBefore[range.upperBound] - oldBefore[range.lowerBound]
            let newCount = newBefore[range.upperBound] - newBefore[range.lowerBound]
            let oldStart = oldBefore[range.lowerBound] + (oldCount == 0 ? 0 : 1)
            let newStart = newBefore[range.lowerBound] + (newCount == 0 ? 0 : 1)
            patch += "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n"
            for operation in operations[range] {
                let marker: String
                let line: TextLine
                switch operation {
                case .equal(let index, _): marker = " "; line = old[index]
                case .delete(let index): marker = "-"; line = old[index]
                case .insert(let index): marker = "+"; line = new[index]
                }
                patch += marker + line.content + "\n"
                if line.ending.isEmpty { patch += "\\ No newline at end of file\n" }
            }
        }
        return patch
    }
}
