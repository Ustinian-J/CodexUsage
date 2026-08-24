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

        expect(CodexTaskTimestamp.date(unixTime: 0) == Date(timeIntervalSince1970: 0), "Unix epoch must be valid")
        expect(
            CodexTaskTimestamp.date(unixTime: CodexTaskTimestamp.maximumUnixTime) != nil,
            "the final second of year 9999 must be valid"
        )
        for invalidTime in [
            -1,
            CodexTaskTimestamp.maximumUnixTime + 1,
            Double.infinity,
            -Double.infinity,
            Double.nan
        ] {
            expect(
                CodexTaskTimestamp.date(unixTime: invalidTime) == nil,
                "non-finite and out-of-range Unix timestamps must be rejected"
            )
        }
        expect(CodexTaskIdentifier.validated("turn-id") == "turn-id", "normal task identifiers must be accepted")
        expect(CodexTaskIdentifier.validated("") == nil, "empty task identifiers must be rejected")
        expect(
            CodexTaskIdentifier.validated(String(repeating: "x", count: 513)) == nil,
            "task identifiers larger than 512 bytes must be rejected"
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
        expect(
            !CodexTaskReplayPolicy.shouldRetain(staleStart, origin: .baseline, scanWatermark: base),
            "stale unmatched baseline starts must be filtered during replay"
        )
        expect(
            CodexTaskReplayPolicy.shouldRetain(staleStart, origin: .live, scanWatermark: base)
                && CodexTaskReplayPolicy.shouldRetain(staleStart, origin: .recovery, scanWatermark: base),
            "long-running live and recovery tasks must never be age-pruned"
        )
        var longRunning = CodexTaskActivityReducer(persisted: .empty)
        _ = longRunning.apply(staleStart, origin: .live)
        expect(
            longRunning.snapshot(availability: .ready).runningCount == 1,
            "a live task running longer than twelve hours must remain active"
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
        let invalidEpochLine = """
        {"timestamp":"2026-08-04T09:38:34.218Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"\(turnA)","completed_at":253402300800}}
        """
        let invalidEpochFallback = CodexRolloutTaskEventParser.parse(
            line: Data(invalidEpochLine.utf8),
            metadata: metadata
        )
        let expectedOuterFormatter = ISO8601DateFormatter()
        expectedOuterFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        expect(
            invalidEpochFallback?.occurredAt == expectedOuterFormatter.date(from: "2026-08-04T09:38:34.218Z"),
            "an invalid payload epoch must fall back to the valid outer ISO8601 timestamp"
        )
        let oversizedTurnLine = """
        {"timestamp":"2026-08-04T09:38:34.218Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"\(String(repeating: "x", count: 513))","completed_at":1785836314}}
        """
        expect(
            CodexRolloutTaskEventParser.parse(line: Data(oversizedTurnLine.utf8), metadata: metadata) == nil,
            "oversized local turn identifiers must be rejected"
        )

        var lineBuffer = CodexJSONLineBuffer()
        let split = line.index(line.startIndex, offsetBy: line.count / 2)
        expect(lineBuffer.append(Data(line[..<split].utf8)).isEmpty, "partial JSON line must be buffered")
        let completedLines = lineBuffer.append(Data((line[split...] + "\n").utf8))
        expect(completedLines.count == 1, "newline must release exactly one buffered JSON line")

        var boundedLineBuffer = CodexJSONLineBuffer(maximumLineBytes: 32)
        expect(
            boundedLineBuffer.append(Data(repeating: 120, count: 33)).isEmpty,
            "an oversized partial line must not be emitted"
        )
        expect(
            boundedLineBuffer.bufferedByteCount <= 32,
            "partial JSON buffering must remain within its configured limit"
        )
        let recoveredLines = boundedLineBuffer.append(Data("\n{\"kind\":\"ready\"}\n".utf8))
        expect(
            recoveredLines == [Data("{\"kind\":\"ready\"}".utf8)],
            "line buffering must recover after discarding one oversized line"
        )
        var largeCompletedLineBuffer = CodexJSONLineBuffer(maximumLineBytes: 256 * 1024)
        let largeCompletedLine = Data(repeating: 120, count: 129 * 1024) + Data([10])
        expect(
            largeCompletedLineBuffer.append(largeCompletedLine).count == 1
                && largeCompletedLineBuffer.releasedLargeBufferCount == 1,
            "completed large lines must release their retained storage"
        )
        boundedLineBuffer.reset()
        expect(
            boundedLineBuffer.append(Data("ok\n".utf8)) == [Data("ok".utf8)],
            "reset must clear the oversized-line discard state"
        )

        var eventBatchBuffer = CodexTaskEventBatchBuffer(maximumEventCount: 2)
        var emittedBatchSizes: [Int] = []
        for index in 0..<5 {
            let event = CodexTaskEvent(
                turnID: "batch-\(index)",
                occurredAt: base.addingTimeInterval(Double(index)),
                metadata: metadata,
                kind: .completed
            )
            if let batch = eventBatchBuffer.append(event) {
                emittedBatchSizes.append(batch.count)
            }
        }
        emittedBatchSizes.append(eventBatchBuffer.finish().count)
        expect(
            emittedBatchSizes == [2, 2, 1] && eventBatchBuffer.bufferedEventCount == 0,
            "local replay events must be emitted in fixed-size batches"
        )

        expect(
            CodexRemoteHost.parseList("codex, build-box\nCODEX") == ["codex", "build-box"],
            "remote host aliases must be validated and deduplicated case-insensitively"
        )
        expect(CodexRemoteHost.validated("-oProxyCommand=bad") == nil, "SSH option injection must be rejected")
        expect(CodexRemoteHost.validated("host;touch") == nil, "remote shell metacharacters must be rejected")
        var attemptBudget = RemoteConnectionAttemptBudget()
        expect(
            attemptBudget.beginAttempt() == 1
                && attemptBudget.beginAttempt() == 2
                && attemptBudget.beginAttempt() == 3
                && attemptBudget.beginAttempt() == nil
                && !attemptBudget.canRetry,
            "one manual remote-monitor cycle must allow exactly three connection attempts"
        )
        attemptBudget.reset()
        expect(
            attemptBudget.beginAttempt() == 1 && attemptBudget.canRetry,
            "a later manual refresh must reset the three-attempt budget"
        )
        let remoteScript = RemoteCodexTaskMonitor.remoteScript
        expect(
            remoteScript.contains("if not isinstance(root, dict):")
                && remoteScript.contains("if not isinstance(payload, dict):"),
            "remote malformed JSON shapes must be skipped before field access"
        )
        expect(
            remoteScript.contains("sources, initial_complete = discover_sources(home)")
                && remoteScript.contains("if not initial_complete:")
                && remoteScript.contains("except OSError:")
                && remoteScript.contains("return {}, False")
                && remoteScript.contains("return 3"),
            "an incomplete remote initial scan must exit without advancing its checkpoint"
        )

        let remoteLine = """
        {"kind":"event","event":"started","turn_id":"019fda07-3333-7777-8888-111111111111","occurred_at":1786000040,"thread_id":"remote-thread","title":"Remote build","project_name":"backend"}
        """
        let remoteEvent = RemoteCodexTaskEnvelope.parse(line: Data(remoteLine.utf8), host: "codex")
        expect(remoteEvent?.metadata.sourceLabel == "codex", "remote events must retain their SSH source label")
        expect(remoteEvent?.metadata.projectName == "backend", "remote events must retain the project basename")
        if let remoteEvent {
            var remoteReducer = CodexTaskActivityReducer(persisted: .empty)
            _ = remoteReducer.apply(remoteEvent, origin: .baseline)
            expect(
                remoteReducer.removeRunningTasks(sourceLabel: "CODEX"),
                "disabling a remote host must remove its running tasks case-insensitively"
            )
        } else {
            failures.append("normalized remote task event must parse")
        }

        let remoteUntitledLine = """
        {"kind":"event","event":"started","turn_id":"019fda07-4444-7777-8888-111111111111","occurred_at":1786000041,"thread_id":"remote-untitled","project_name":"backend"}
        """
        expect(
            RemoteCodexTaskEnvelope.parse(line: Data(remoteUntitledLine.utf8), host: "codex")?.metadata.title == "Codex 任务",
            "missing remote titles must use a generic label instead of conversation preview text"
        )

        let remoteScanStartedLine = """
        {"kind":"scan_started","scan_started_at":\(base.timeIntervalSince1970)}
        """
        let remoteScanStarted = try? JSONDecoder().decode(
            RemoteCodexTaskEnvelope.self,
            from: Data(remoteScanStartedLine.utf8)
        )
        expect(remoteScanStarted?.scanWatermark == base, "remote scans must announce their watermark before replay")
        let remoteReadyLine = """
        {"kind":"ready","scan_started_at":\(base.timeIntervalSince1970)}
        """
        let remoteReady = try? JSONDecoder().decode(RemoteCodexTaskEnvelope.self, from: Data(remoteReadyLine.utf8))
        expect(remoteReady?.scanWatermark == base, "remote ready must repeat the remote scan-start watermark")
        let invalidRemoteReady = try? JSONDecoder().decode(
            RemoteCodexTaskEnvelope.self,
            from: Data(#"{"kind":"ready"}"#.utf8)
        )
        expect(invalidRemoteReady?.scanWatermark == nil, "ready without a remote watermark must be rejected")
        let oversizedRemoteReady = try? JSONDecoder().decode(
            RemoteCodexTaskEnvelope.self,
            from: Data(#"{"kind":"ready","scan_started_at":253402300800}"#.utf8)
        )
        expect(oversizedRemoteReady?.scanWatermark == nil, "out-of-range remote watermarks must be rejected")
        let oversizedRemoteEvent = """
        {"kind":"event","event":"completed","turn_id":"019fda07-7777-7777-8888-111111111111","occurred_at":253402300800,"thread_id":"remote-oversized","title":"Remote task"}
        """
        expect(
            RemoteCodexTaskEnvelope.parse(line: Data(oversizedRemoteEvent.utf8), host: "codex") == nil,
            "out-of-range remote event timestamps must be rejected"
        )
        let oversizedRemoteIdentifier = """
        {"kind":"event","event":"completed","turn_id":"\(String(repeating: "x", count: 513))","occurred_at":1786000041,"thread_id":"remote-thread","title":"Remote task"}
        """
        expect(
            RemoteCodexTaskEnvelope.parse(line: Data(oversizedRemoteIdentifier.utf8), host: "codex") == nil,
            "oversized remote task identifiers must be rejected"
        )
        let oversizedRemoteThread = """
        {"kind":"event","event":"completed","turn_id":"019fda07-8888-7777-8888-111111111111","occurred_at":1786000041,"thread_id":"\(String(repeating: "x", count: 513))","title":"Remote task"}
        """
        expect(
            RemoteCodexTaskEnvelope.parse(line: Data(oversizedRemoteThread.utf8), host: "codex") == nil,
            "oversized remote thread identifiers must be rejected"
        )
        if let remoteWatermark = remoteReady?.scanWatermark {
            let firstScan = RemoteCodexReplayWindow(
                scanWatermark: remoteWatermark,
                recoveryCheckpoint: nil
            )
            expect(
                firstScan.origin(for: CodexTaskEvent(
                    turnID: "019fda07-5555-7777-8888-111111111111",
                    occurredAt: remoteWatermark.addingTimeInterval(1),
                    metadata: metadata,
                    kind: .completed
                )) == .live,
                "an event written during the first remote scan must remain live"
            )
            let reconnect = RemoteCodexReplayWindow(
                scanWatermark: remoteWatermark,
                recoveryCheckpoint: remoteWatermark.addingTimeInterval(-60)
            )
            expect(
                reconnect.origin(for: CodexTaskEvent(
                    turnID: "019fda07-6666-7777-8888-111111111111",
                    occurredAt: remoteWatermark.addingTimeInterval(1),
                    metadata: metadata,
                    kind: .completed
                )) == .recovery,
                "an event after the persisted remote watermark must be recovered after reconnect"
            )
            let clockRollback = RemoteCodexReplayWindow(
                scanWatermark: remoteWatermark,
                recoveryCheckpoint: remoteWatermark.addingTimeInterval(8 * 60 * 60)
            )
            expect(
                clockRollback.replayNotBefore == remoteWatermark,
                "remote clock rollback must clamp a future checkpoint to the current scan watermark"
            )
            let beforeRollbackScanTerminal = CodexTaskEvent(
                turnID: "rollback-terminal",
                occurredAt: remoteWatermark.addingTimeInterval(-60),
                metadata: metadata,
                kind: .completed
            )
            expect(
                clockRollback.origin(for: beforeRollbackScanTerminal) == .recovery,
                "remote clock rollback must recover terminal events before the new scan watermark"
            )
            let staleRollbackStart = CodexTaskEvent(
                turnID: "rollback-stale-start",
                occurredAt: remoteWatermark.addingTimeInterval(-13 * 60 * 60),
                metadata: metadata,
                kind: .started
            )
            let staleRollbackOrigin = clockRollback.origin(for: staleRollbackStart)
            expect(
                !CodexTaskReplayPolicy.shouldRetain(
                    staleRollbackStart,
                    origin: staleRollbackOrigin,
                    scanWatermark: remoteWatermark,
                    clockRolledBack: clockRollback.clockRolledBack
                ),
                "remote clock rollback must still discard stale replayed starts"
            )
            expect(firstScan.acceptsReady(watermark: remoteWatermark), "ready must confirm the announced watermark")
            expect(
                !firstScan.acceptsReady(watermark: remoteWatermark.addingTimeInterval(1)),
                "ready with a different watermark must be rejected"
            )
        }

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
            let remotePersistence = CodexRemoteTaskCheckpointPersistence(defaults: defaults)
            if let oldCheckpoint = try? JSONEncoder().encode(["codex": base]) {
                defaults.set(oldCheckpoint, forKey: "CodexUsage.remoteTaskCheckpoints.v1")
            }
            expect(
                remotePersistence.load().isEmpty,
                "legacy local-clock remote checkpoints must not migrate into remote-clock recovery"
            )
            remotePersistence.save(["codex": base])
            expect(remotePersistence.load()["codex"] == base, "remote recovery checkpoints must round-trip")
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
