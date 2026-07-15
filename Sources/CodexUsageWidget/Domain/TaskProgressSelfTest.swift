import Foundation

enum TaskProgressSelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures.append(message)
            }
        }

        let board = TaskBoard(refreshedAt: Date(), columns: [
            column(.active, count: 2),
            column(.pending, count: 1),
            column(.scheduled, count: 4),
            column(.done, count: 1)
        ])
        let progress = TaskProgress(board: board)
        expect(progress.trackedCount == 4, "scheduled automations must not affect conversation progress")
        expect(progress.completedCount == 1, "completed conversations should be counted")
        expect(progress.percent == 25, "one of four completed tasks should be 25 percent")

        let completed = TaskProgress(board: TaskBoard(refreshedAt: Date(), columns: [
            column(.done, count: 3)
        ]))
        expect(completed.percent == 100, "all completed tasks should report 100 percent")

        let scheduledOnly = TaskProgress(board: TaskBoard(refreshedAt: Date(), columns: [
            column(.scheduled, count: 2)
        ]))
        expect(scheduledOnly.trackedCount == 0, "scheduled-only boards should have no tracked conversations")
        expect(scheduledOnly.percent == nil, "empty conversation progress should be unavailable")

        let defensive = TaskProgress(board: TaskBoard(refreshedAt: Date(), columns: [
            column(.active, count: -2),
            column(.done, count: -1)
        ]))
        expect(defensive.trackedCount == 0, "invalid negative counts should clamp to zero")
        expect(defensive.percent == nil, "invalid negative counts must not create a percentage")

        if failures.isEmpty {
            print("task progress self-test passed")
            return true
        }

        for failure in failures {
            fputs("task progress self-test failed: \(failure)\n", stderr)
        }
        return false
    }

    private static func column(_ kind: TaskColumnKind, count: Int) -> TaskColumn {
        TaskColumn(id: kind, title: kind.rawValue, count: count, items: [])
    }
}
