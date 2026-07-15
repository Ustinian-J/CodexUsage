import Foundation

/// A heuristic completion ratio derived from today's local Codex conversations.
/// Scheduled automations are intentionally excluded because they are recurring
/// work definitions, not conversations that can be completed today.
struct TaskProgress: Equatable {
    let trackedCount: Int
    let completedCount: Int
    let percent: Int?

    init(board: TaskBoard) {
        func count(_ kind: TaskColumnKind) -> Int {
            board.columns
                .filter { $0.id == kind }
                .reduce(0) { $0 + max($1.count, 0) }
        }

        let completed = count(.done)
        let tracked = completed + count(.active) + count(.pending)

        trackedCount = tracked
        completedCount = min(completed, tracked)
        percent = tracked > 0
            ? Int((Double(completedCount) / Double(tracked) * 100).rounded())
            : nil
    }
}
