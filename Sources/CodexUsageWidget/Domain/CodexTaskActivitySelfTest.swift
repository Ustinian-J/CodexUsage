import Foundation

enum CodexTaskActivitySelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures.append(message)
            }
        }

        let base = Date(timeIntervalSince1970: 1_786_000_000)
        let turnA = "019fda07-562e-7f63-a002-1029fd93e2b8"
        let turnB = "019fda07-15d9-7c32-b610-95ba5d31d28c"
        let metadata = CodexTaskMetadata(
            threadID: "thread-a",
            title: "Build the menu bar reminder",
            projectName: "CodexS"
        )

        expect(
            CodexTaskEvent.stableIdentity(turnID: turnA, threadID: "thread-a")
                == CodexTaskEvent.stableIdentity(turnID: turnA, threadID: "forked-thread"),
            "UUID turn IDs must deduplicate copied rollout history globally"
        )
        expect(
            CodexTaskEvent.stableIdentity(turnID: "legacy-turn", threadID: "thread-a")
                != CodexTaskEvent.stableIdentity(turnID: "legacy-turn", threadID: "thread-b"),
            "non-UUID turn IDs must include the thread ID"
        )

        var reducer = CodexTaskActivityReducer(persisted: .empty)
        let startA = CodexTaskEvent(
            turnID: turnA,
            occurredAt: base,
            metadata: metadata,
            kind: .started
        )
        let startB = CodexTaskEvent(
            turnID: turnB,
            occurredAt: base.addingTimeInterval(1),
            metadata: CodexTaskMetadata(
                threadID: "thread-b",
                title: "Run regression tests",
                projectName: "CodexS"
            ),
            kind: .started
        )
        _ = reducer.apply(startA, origin: .live)
        _ = reducer.apply(startB, origin: .live)
        expect(reducer.snapshot(availability: .ready).runningCount == 2, "two starts must produce two running tasks")

        let completeA = CodexTaskEvent(
            turnID: turnA,
            occurredAt: base.addingTimeInterval(20),
            metadata: metadata,
            kind: .completed
        )
        let firstCompletion = reducer.apply(completeA, origin: .live)
        var snapshot = reducer.snapshot(availability: .ready)
        expect(firstCompletion.newCompletion != nil, "first live terminal event must produce one completion effect")
        expect(snapshot.runningCount == 1, "completing one concurrent task must leave the other running")
        expect(snapshot.unreadCount == 1, "live completion must be unread")
        expect(snapshot.showsRed && snapshot.showsYellow && !snapshot.showsGreen, "running plus unread must show red and yellow")

        let duplicateCompletion = reducer.apply(completeA, origin: .recovery)
        expect(!duplicateCompletion.changed, "duplicate terminal events must be idempotent")
        expect(duplicateCompletion.newCompletion == nil, "duplicate terminal events must not notify")

        expect(reducer.markAllRead(at: base.addingTimeInterval(21)), "mark all read must change unread state")
        snapshot = reducer.snapshot(availability: .ready)
        expect(snapshot.unreadCount == 0 && !snapshot.showsYellow, "mark all read must turn off yellow")

        let abortB = CodexTaskEvent(
            turnID: turnB,
            occurredAt: base.addingTimeInterval(30),
            metadata: startB.metadata,
            kind: .aborted
        )
        _ = reducer.apply(abortB, origin: .live)
        snapshot = reducer.snapshot(availability: .ready)
        expect(snapshot.runningCount == 0, "aborted task must stop running")
        expect(snapshot.showsGreen && snapshot.showsYellow, "idle plus unread must show green and yellow")
        expect(snapshot.recentCompletions.first?.outcome == .interrupted, "aborted task must not be reported as completed")

        let copiedStart = reducer.apply(startA, origin: .recovery)
        expect(!copiedStart.changed, "a copied start after a terminal event must not revive the task")

        var baseline = CodexTaskActivityReducer(persisted: .empty)
        _ = baseline.apply(startA, origin: .baseline)
        let baselineTerminal = baseline.apply(completeA, origin: .baseline)
        expect(baselineTerminal.newCompletion == nil, "baseline history must not notify")
        expect(baseline.snapshot(availability: .ready).unreadCount == 0, "baseline history must not become unread")

        let staleStart = CodexTaskEvent(
            turnID: "019f0000-0000-7000-8000-000000000000",
            occurredAt: base.addingTimeInterval(-13 * 60 * 60),
            metadata: metadata,
            kind: .started
        )
        _ = baseline.apply(staleStart, origin: .baseline)
        expect(
            baseline.removeRunningTasks(startedBefore: base.addingTimeInterval(-12 * 60 * 60)),
            "stale unmatched baseline starts must be pruned"
        )

        var consecutive = CodexTaskActivityReducer(persisted: .empty)
        _ = consecutive.apply(startA, origin: .live)
        let newerStart = CodexTaskEvent(
            turnID: "019fda07-2222-7777-8888-111111111111",
            occurredAt: base.addingTimeInterval(60),
            metadata: metadata,
            kind: .started
        )
        _ = consecutive.apply(newerStart, origin: .live)
        expect(
            consecutive.snapshot(availability: .ready).runningTasks.map(\.turnID) == [newerStart.turnID],
            "a newer turn in the same thread must replace a missing terminal start"
        )

        expect(
            CodexTaskReplayPolicy.origin(
                for: base.addingTimeInterval(-1),
                replayNotBefore: base,
                baselineEstablished: true
            ) == .baseline,
            "events before the persisted scan watermark must remain baseline history"
        )
        expect(
            CodexTaskReplayPolicy.origin(
                for: base.addingTimeInterval(1),
                replayNotBefore: base,
                baselineEstablished: false
            ) == .live,
            "a completion written during first scan must be treated as live"
        )

        var longHistory = CodexTaskActivityReducer(persisted: .empty)
        for index in 0..<8_300 {
            let event = CodexTaskEvent(
                turnID: String(format: "019f%04x-0000-7000-8000-%012x", index, index),
                occurredAt: base.addingTimeInterval(Double(index - 9_000)),
                metadata: metadata,
                kind: .completed
            )
            let transition = longHistory.apply(event, origin: .baseline)
            expect(transition.newCompletion == nil, "baseline history beyond the terminal ledger must never notify")
        }
        expect(
            longHistory.snapshot(availability: .ready).unreadCount == 0,
            "replaying more than the terminal ledger capacity must not create unread history"
        )

        let line = """
        {"timestamp":"2026-08-04T09:38:34.218Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"\(turnA)","completed_at":1785836314,"duration_ms":82106,"last_agent_message":"must not be retained"}}
        """
        let parsed = CodexRolloutTaskEventParser.parse(
            line: Data(line.utf8),
            metadata: metadata
        )
        expect(parsed?.turnID == turnA, "rollout parser must read turn_id")
        expect(parsed?.occurredAt == Date(timeIntervalSince1970: 1_785_836_314), "payload epoch must win over outer timestamp")
        if parsed?.kind != .completed {
            failures.append("task_complete must parse as completed")
        }

        var lineBuffer = CodexJSONLineBuffer()
        let split = line.index(line.startIndex, offsetBy: line.count / 2)
        expect(lineBuffer.append(Data(line[..<split].utf8)).isEmpty, "partial JSON line must be buffered")
        let completedLines = lineBuffer.append(Data((line[split...] + "\n").utf8))
        expect(completedLines.count == 1, "newline must release exactly one buffered JSON line")

        if case .success = runReadOnlySQLiteJSON(
            sqlitePath: "/path/that/does/not/exist/sqlite3",
            dbPath: "/path/that/does/not/exist/state.sqlite",
            query: "SELECT 1"
        ) {
            failures.append("SQLite launch failures must remain distinguishable from an empty successful query")
        }

        let suiteName = "CodexUsage.task-activity-self-test.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let persistence = CodexTaskActivityPersistence(defaults: defaults)
            let saved = CodexTaskActivityPersistedState(
                baselineEstablished: true,
                replayNotBefore: base,
                recentCompletions: snapshot.recentCompletions,
                terminalIdentities: reducer.persistedState(
                    baselineEstablished: true,
                    replayNotBefore: base
                ).terminalIdentities
            )
            persistence.save(saved)
            expect(persistence.load() == saved, "task activity persistence must round-trip")
        } else {
            failures.append("could not create task activity UserDefaults suite")
        }

        if failures.isEmpty {
            print("task activity self-test passed")
            return true
        }

        for failure in failures {
            print("task activity self-test failed: \(failure)")
        }
        return false
    }
}
