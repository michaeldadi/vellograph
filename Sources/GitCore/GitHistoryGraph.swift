import Foundation

public struct GitGraphSegment: Sendable, Equatable {
    public let fromLane: Int
    public let fromRowFraction: Double
    public let toLane: Int
    public let toRowFraction: Double

    public init(fromLane: Int, fromRowFraction: Double, toLane: Int, toRowFraction: Double) {
        self.fromLane = fromLane
        self.fromRowFraction = fromRowFraction
        self.toLane = toLane
        self.toRowFraction = toRowFraction
    }
}

public struct GitGraphRow: Sendable, Equatable {
    public let commitID: String
    public let nodeLane: Int
    public let laneCount: Int
    public let segments: [GitGraphSegment]
}

/// Lays out a topologically ordered commit list as lanes. Parents beyond the
/// loaded history remain as outbound lines at the final row.
public enum GitHistoryGraph {
    public static func rows(for commits: [GitCommit]) -> [GitGraphRow] {
        var active: [String] = []
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)
        for commit in commits {
            let hasIncoming = active.contains(commit.id)
            if !hasIncoming { active.insert(commit.id, at: 0) }
            let before = active
            let lane = before.firstIndex(of: commit.id)!
            active.remove(at: lane)
            for (offset, parent) in commit.parents.enumerated() where !active.contains(parent) {
                active.insert(parent, at: min(lane + offset, active.count))
            }
            var segments: [GitGraphSegment] = []
            if hasIncoming {
                segments.append(.init(fromLane: lane, fromRowFraction: 0,
                                      toLane: lane, toRowFraction: 0.5))
            }
            for (index, id) in before.enumerated() where id != commit.id {
                if let next = active.firstIndex(of: id) {
                    segments.append(.init(fromLane: index, fromRowFraction: 0,
                                          toLane: next, toRowFraction: 1))
                }
            }
            for parent in commit.parents {
                if let next = active.firstIndex(of: parent) {
                    segments.append(.init(fromLane: lane, fromRowFraction: 0.5,
                                          toLane: next, toRowFraction: 1))
                }
            }
            rows.append(GitGraphRow(commitID: commit.id, nodeLane: lane,
                                    laneCount: max(before.count, active.count),
                                    segments: segments))
        }
        return rows
    }
}
