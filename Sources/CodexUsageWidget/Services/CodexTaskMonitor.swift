import Combine
import Foundation

struct CodexJSONLineBuffer {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}

enum CodexRolloutTaskEventParser {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(line: Data, metadata: CodexTaskMetadata) -> CodexTaskEvent? {
        guard line.range(of: Data("task_started".utf8)) != nil
                || line.range(of: Data("task_complete".utf8)) != nil
                || line.range(of: Data("turn_aborted".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let eventType = payload["type"] as? String,
              let turnID = payload["turn_id"] as? String,
              !turnID.isEmpty
        else { return nil }

        let outerDate = (object["timestamp"] as? String).flatMap(parseISO8601)
        switch eventType {
        case "task_started":
            guard let occurredAt = epochDate(payload["started_at"]) ?? outerDate else { return nil }
            return CodexTaskEvent(
                turnID: turnID,
                occurredAt: occurredAt,
                metadata: metadata,
                kind: .started
            )

        case "task_complete":
            guard let occurredAt = epochDate(payload["completed_at"]) ?? outerDate else { return nil }
            return CodexTaskEvent(
                turnID: turnID,
                occurredAt: occurredAt,
                metadata: metadata,
                kind: .completed
            )

        case "turn_aborted":
            guard let occurredAt = epochDate(payload["completed_at"]) ?? outerDate else { return nil }
            return CodexTaskEvent(
                turnID: turnID,
                occurredAt: occurredAt,
                metadata: metadata,
                kind: .aborted
            )

        default:
            return nil
        }
    }

    private static func epochDate(_ value: Any?) -> Date? {
        number(value).map { Date(timeIntervalSince1970: $0) }
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func parseISO8601(_ value: String) -> Date? {
        fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value)
    }
}

final class CodexTaskActivityPersistence {
    private static let storageKey = "CodexUsage.taskActivity.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CodexTaskActivityPersistedState {
        guard let data = defaults.data(forKey: Self.storageKey),
              let state = try? JSONDecoder().decode(CodexTaskActivityPersistedState.self, from: data),
              state.schemaVersion == 1 || state.schemaVersion == CodexTaskActivityPersistedState.version
        else { return .empty }
        if state.schemaVersion == 1 {
            return CodexTaskActivityPersistedState(
                baselineEstablished: state.baselineEstablished,
                replayNotBefore: nil,
                recentCompletions: state.recentCompletions,
                terminalIdentities: state.terminalIdentities
            )
        }
        return state
    }

    func save(_ state: CodexTaskActivityPersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

final class CodexTaskActivityStore: ObservableObject {
    @Published private(set) var snapshot: CodexTaskActivitySnapshot
    var onNewCompletion: ((CodexTaskCompletion) -> Void)?

    private let homeDirectory: URL
    private let persistence: CodexTaskActivityPersistence
    private var reducer: CodexTaskActivityReducer
    private var baselineEstablished: Bool
    private var replayNotBefore: Date?
    private var monitor: CodexTaskMonitor?

    init(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        defaults: UserDefaults = .standard
    ) {
        self.homeDirectory = homeDirectory
        let persistence = CodexTaskActivityPersistence(defaults: defaults)
        self.persistence = persistence
        let persisted = persistence.load()
        self.reducer = CodexTaskActivityReducer(persisted: persisted)
        self.baselineEstablished = persisted.baselineEstablished
        self.replayNotBefore = persisted.replayNotBefore
        self.snapshot = reducer.snapshot(availability: .starting)
    }

    func start() {
        guard monitor == nil else { return }
        let monitor = CodexTaskMonitor(
            homeDirectory: homeDirectory,
            baselineEstablished: baselineEstablished,
            replayNotBefore: replayNotBefore
        ) { [weak self] update in
            DispatchQueue.main.async {
                self?.handle(update)
            }
        }
        self.monitor = monitor
        monitor.start()
    }

    func stop() {
        monitor?.stop()
        monitor = nil
    }

    func markRead(_ identity: String) {
        guard reducer.markRead(identity) else { return }
        publishAndPersist(availability: snapshot.availability)
    }

    func markAllRead() {
        guard reducer.markAllRead() else { return }
        publishAndPersist(availability: snapshot.availability)
    }

    private func handle(_ update: CodexTaskMonitorUpdate) {
        switch update {
        case let .events(events, origin):
            var changed = false
            var completions: [CodexTaskCompletion] = []
            for event in events {
                let transition = reducer.apply(event, origin: origin)
                changed = changed || transition.changed
                if let completion = transition.newCompletion {
                    completions.append(completion)
                }
            }
            if changed {
                publishAndPersist(availability: snapshot.availability)
            }
            for completion in completions {
                onNewCompletion?(completion)
            }

        case .ready:
            _ = reducer.removeRunningTasks(startedBefore: Date().addingTimeInterval(-12 * 60 * 60))
            if !baselineEstablished {
                baselineEstablished = true
            }
            publishAndPersist(availability: .ready)

        case let .checkpoint(date):
            guard replayNotBefore == nil || date > replayNotBefore! else { return }
            replayNotBefore = date
            publishAndPersist(availability: snapshot.availability)

        case let .reconcile(cutoff):
            guard reducer.removeRunningTasks(startedBefore: cutoff) else { return }
            publishAndPersist(availability: snapshot.availability)

        case let .unavailable(message):
            snapshot = reducer.snapshot(availability: .unavailable(message))
        }
    }

    private func publishAndPersist(availability: CodexTaskMonitorAvailability) {
        snapshot = reducer.snapshot(availability: availability)
        persistence.save(reducer.persistedState(
            baselineEstablished: baselineEstablished,
            replayNotBefore: replayNotBefore
        ))
    }
}

private enum CodexTaskMonitorUpdate {
    case events([CodexTaskEvent], CodexTaskEventOrigin)
    case ready
    case checkpoint(Date)
    case reconcile(Date)
    case unavailable(String)
}

private struct CodexTaskSource {
    let path: String
    let metadata: CodexTaskMetadata
    let createdAt: Date
}

private struct CodexTaskFileCursor {
    var offset: UInt64 = 0
    var fileNumber: UInt64?
    var lineBuffer = CodexJSONLineBuffer()
}

private struct CodexTaskReadBatch {
    let events: [CodexTaskEvent]
    let replayed: Bool
}

private enum CodexTaskReadError: Error {
    case unavailable
}

private final class CodexTaskMonitor {
    private let homeDirectory: URL
    private let onUpdate: (CodexTaskMonitorUpdate) -> Void
    private let queue = DispatchQueue(label: "CodexS.task-monitor", qos: .utility)
    private let fileManager = FileManager.default
    private var timer: DispatchSourceTimer?
    private var sourcesByPath: [String: CodexTaskSource] = [:]
    private var cursorsByPath: [String: CodexTaskFileCursor] = [:]
    private var initialScanCompleted = false
    private var baselineEstablished: Bool
    private var tickCount = 0
    private let startedAt: Date
    private var replayNotBefore: Date

    init(
        homeDirectory: URL,
        baselineEstablished: Bool,
        replayNotBefore: Date?,
        onUpdate: @escaping (CodexTaskMonitorUpdate) -> Void
    ) {
        let startedAt = Date()
        self.homeDirectory = homeDirectory
        self.baselineEstablished = baselineEstablished
        self.startedAt = startedAt
        self.replayNotBefore = replayNotBefore ?? startedAt
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.attemptInitialScan()
            self.installTimer()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.sourcesByPath.removeAll()
            self?.cursorsByPath.removeAll()
        }
    }

    private func installTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        self.timer = timer
        timer.resume()
    }

    private func poll() {
        guard initialScanCompleted else {
            attemptInitialScan()
            return
        }

        tickCount += 1
        let shouldDiscover = tickCount % 10 == 0
        let checkpointCandidate = shouldDiscover ? Date() : nil
        let discoverySucceeded = shouldDiscover ? discoverNewSources() : false

        var liveEvents: [CodexTaskEvent] = []
        var replayedEvents: [CodexTaskEvent] = []
        var allReadsSucceeded = true
        for source in sourcesByPath.values {
            switch readAppendedEvents(from: source) {
            case let .success(batch):
                if batch.replayed {
                    replayedEvents.append(contentsOf: batch.events)
                } else {
                    liveEvents.append(contentsOf: batch.events)
                }
            case .failure:
                allReadsSucceeded = false
            }
        }
        emitSorted(liveEvents, origin: .live)
        emitReplay(replayedEvents)

        if let checkpointCandidate, discoverySucceeded, allReadsSucceeded {
            replayNotBefore = checkpointCandidate
            onUpdate(.checkpoint(checkpointCandidate))
        }
        if tickCount % 60 == 0 {
            onUpdate(.reconcile(Date().addingTimeInterval(-12 * 60 * 60)))
        }
    }

    private func attemptInitialScan() {
        let discovered: [CodexTaskSource]
        switch discoverSources() {
        case let .success(sources):
            discovered = sources
        case .failure:
            onUpdate(.unavailable("未找到 Codex 本地任务数据"))
            return
        }

        sourcesByPath = Dictionary(uniqueKeysWithValues: discovered.map { ($0.path, $0) })
        var events: [CodexTaskEvent] = []
        for source in discovered {
            switch readAppendedEvents(from: source) {
            case let .success(batch):
                events.append(contentsOf: batch.events)
            case .failure:
                cursorsByPath.removeAll()
                onUpdate(.unavailable("暂时无法读取 Codex 本地任务记录"))
                return
            }
        }
        emitReplay(events)
        initialScanCompleted = true
        baselineEstablished = true
        replayNotBefore = startedAt
        onUpdate(.checkpoint(startedAt))
        onUpdate(.ready)
    }

    private func discoverNewSources() -> Bool {
        // Keep tailing already discovered files if SQLite is briefly busy or unavailable.
        guard case let .success(discovered) = discoverSources() else { return false }

        for source in discovered {
            sourcesByPath[source.path] = source
        }
        return true
    }

    private func discoverSources() -> Result<[CodexTaskSource], ReadOnlySQLiteError> {
        let codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let dbCandidates = [
            codexDirectory.appendingPathComponent("state_5.sqlite").path,
            codexDirectory.appendingPathComponent("sqlite/state_5.sqlite").path
        ]
        guard let dbPath = dbCandidates.first(where: fileManager.fileExists(atPath:)) else {
            return .failure(.queryFailed(-1, "Codex database not found"))
        }
        guard let sqlitePath = ["/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3"]
            .first(where: fileManager.isExecutableFile(atPath:))
        else { return .failure(.launchFailed("sqlite3 not found")) }

        let columns: Set<String>
        switch runReadOnlySQLiteJSON(
            sqlitePath: sqlitePath,
            dbPath: dbPath,
            query: "PRAGMA table_info(threads);"
        ) {
        case let .success(rows):
            columns = Set(rows.compactMap { $0["name"] as? String })
        case let .failure(error):
            return .failure(error)
        }
        guard columns.contains("id"), columns.contains("rollout_path") else {
            return .failure(.queryFailed(-1, "Unsupported Codex database schema"))
        }

        func selection(_ column: String, alias: String) -> String {
            columns.contains(column) ? "\(column) AS \(alias)" : "'' AS \(alias)"
        }
        let createdAtExpression: String
        if columns.contains("created_at_ms"), columns.contains("created_at") {
            createdAtExpression = "COALESCE(created_at_ms, created_at * 1000)"
        } else if columns.contains("created_at_ms") {
            createdAtExpression = "created_at_ms"
        } else if columns.contains("created_at") {
            createdAtExpression = "created_at * 1000"
        } else {
            createdAtExpression = "0"
        }
        let sourceFilter = columns.contains("thread_source")
            ? "AND (thread_source IS NULL OR thread_source <> 'subagent')"
            : ""
        let query = """
        SELECT id, rollout_path AS rolloutPath,
               \(selection("title", alias: "title")),
               \(selection("preview", alias: "preview")),
               \(selection("cwd", alias: "cwd")),
               \(createdAtExpression) AS createdAtMs
        FROM threads
        WHERE rollout_path IS NOT NULL
          AND rollout_path <> ''
          \(sourceFilter)
        ORDER BY createdAtMs ASC;
        """
        let rows: [[String: Any]]
        switch runReadOnlySQLiteJSON(sqlitePath: sqlitePath, dbPath: dbPath, query: query) {
        case let .success(value):
            rows = value
        case let .failure(error):
            return .failure(error)
        }
        let sources = rows.compactMap { row -> CodexTaskSource? in
            guard let threadID = row["id"] as? String,
                  let path = row["rolloutPath"] as? String,
                  fileManager.fileExists(atPath: path)
            else { return nil }

            let rawTitle = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (row["preview"] as? String)
                ?? ""
            let cwd = row["cwd"] as? String ?? ""
            let createdAtMilliseconds = (row["createdAtMs"] as? NSNumber)?.doubleValue
                ?? Double(row["createdAtMs"] as? String ?? "")
                ?? 0
            return CodexTaskSource(
                path: path,
                metadata: CodexTaskMetadata(
                    threadID: threadID,
                    title: compactTaskTitle(rawTitle),
                    projectName: cwd.isEmpty ? nil : URL(fileURLWithPath: cwd).lastPathComponent
                ),
                createdAt: Date(timeIntervalSince1970: createdAtMilliseconds / 1_000)
            )
        }
        return .success(sources)
    }

    private func readAppendedEvents(
        from source: CodexTaskSource
    ) -> Result<CodexTaskReadBatch, CodexTaskReadError> {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: source.path)
        } catch {
            return .failure(.unavailable)
        }
        guard let fileSizeNumber = attributes[.size] as? NSNumber else {
            return .failure(.unavailable)
        }

        let fileSize = fileSizeNumber.uint64Value
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let hadCursor = cursorsByPath[source.path] != nil
        var cursor = cursorsByPath[source.path] ?? CodexTaskFileCursor()
        var replayed = !hadCursor
        if fileSize < cursor.offset || (cursor.fileNumber != nil && cursor.fileNumber != fileNumber) {
            cursor.offset = 0
            cursor.fileNumber = fileNumber
            cursor.lineBuffer.reset()
            replayed = true
        }
        guard fileSize > cursor.offset else {
            cursor.fileNumber = fileNumber
            cursorsByPath[source.path] = cursor
            return .success(CodexTaskReadBatch(events: [], replayed: replayed))
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: source.path))
        } catch {
            return .failure(.unavailable)
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: cursor.offset)
            let data = try handle.readToEnd() ?? Data()
            cursor.offset += UInt64(data.count)
            cursor.fileNumber = fileNumber
            let lines = cursor.lineBuffer.append(data)
            cursorsByPath[source.path] = cursor
            let earliestAllowed = source.createdAt.addingTimeInterval(-1)
            let events = lines.compactMap { line in
                CodexRolloutTaskEventParser.parse(line: line, metadata: source.metadata)
            }.filter { $0.occurredAt >= earliestAllowed }
            return .success(CodexTaskReadBatch(events: events, replayed: replayed))
        } catch {
            return .failure(.unavailable)
        }
    }

    private func emitReplay(_ events: [CodexTaskEvent]) {
        let sorted = events.sorted { $0.occurredAt < $1.occurredAt }
        let grouped = Dictionary(grouping: sorted) { event in
            CodexTaskReplayPolicy.origin(
                for: event.occurredAt,
                replayNotBefore: replayNotBefore,
                baselineEstablished: baselineEstablished
            )
        }
        emitSorted(grouped[.baseline] ?? [], origin: .baseline)
        emitSorted(grouped[.live] ?? [], origin: .live)
        emitSorted(grouped[.recovery] ?? [], origin: .recovery)
    }

    private func emitSorted(_ events: [CodexTaskEvent], origin: CodexTaskEventOrigin) {
        guard !events.isEmpty else { return }
        onUpdate(.events(events.sorted { $0.occurredAt < $1.occurredAt }, origin))
    }
}

private func compactTaskTitle(_ rawValue: String) -> String {
    let firstLine = rawValue
        .split(whereSeparator: \.isNewline)
        .first
        .map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
    let fallback = firstLine.isEmpty ? "Codex 任务" : firstLine
    guard fallback.count > 72 else { return fallback }
    return String(fallback.prefix(71)) + "…"
}
