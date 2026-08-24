import Combine
import Darwin
import Foundation

struct CodexJSONLineBuffer {
    static let defaultMaximumLineBytes = 8 * 1024 * 1024
    private static let retainedCapacityLimit = 128 * 1024

    private let maximumLineBytes: Int
    private var buffer = Data()
    private var discardingOversizedLine = false
    private(set) var releasedLargeBufferCount = 0

    init(maximumLineBytes: Int = Self.defaultMaximumLineBytes) {
        self.maximumLineBytes = max(1, maximumLineBytes)
    }

    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var segmentStart = data.startIndex
        var index = segmentStart

        while index < data.endIndex {
            guard data[index] == 10 else {
                index = data.index(after: index)
                continue
            }

            if !discardingOversizedLine {
                let segment = data[segmentStart..<index]
                if buffer.count + segment.count <= maximumLineBytes {
                    buffer.append(contentsOf: segment)
                    if !buffer.isEmpty {
                        lines.append(buffer)
                    }
                }
            }
            clearCompletedLine()
            discardingOversizedLine = false
            index = data.index(after: index)
            segmentStart = index
        }

        if segmentStart < data.endIndex, !discardingOversizedLine {
            let segment = data[segmentStart..<data.endIndex]
            if buffer.count + segment.count <= maximumLineBytes {
                buffer.append(contentsOf: segment)
            } else {
                releaseBuffer()
                discardingOversizedLine = true
            }
        }
        return lines
    }

    mutating func reset() {
        releaseBuffer(countRelease: false)
        discardingOversizedLine = false
    }

    private mutating func clearCompletedLine() {
        if buffer.count > Self.retainedCapacityLimit {
            releaseBuffer()
        } else {
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private mutating func releaseBuffer(countRelease: Bool = true) {
        buffer = Data()
        if countRelease { releasedLargeBufferCount += 1 }
    }
}

struct CodexTaskEventBatchBuffer {
    static let defaultMaximumEventCount = 256

    private let maximumEventCount: Int
    private var events: [CodexTaskEvent] = []

    init(maximumEventCount: Int = Self.defaultMaximumEventCount) {
        self.maximumEventCount = max(1, maximumEventCount)
        events.reserveCapacity(self.maximumEventCount)
    }

    var bufferedEventCount: Int { events.count }

    mutating func append(_ event: CodexTaskEvent) -> [CodexTaskEvent]? {
        events.append(event)
        guard events.count >= maximumEventCount else { return nil }
        return drain()
    }

    mutating func finish() -> [CodexTaskEvent] {
        drain()
    }

    private mutating func drain() -> [CodexTaskEvent] {
        guard !events.isEmpty else { return [] }
        let batch = events
        events.removeAll(keepingCapacity: true)
        return batch
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
              let turnID = CodexTaskIdentifier.validated(payload["turn_id"] as? String)
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
        number(value).flatMap(CodexTaskTimestamp.date(unixTime:))
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

final class CodexRemoteTaskCheckpointPersistence {
    private static let storageKey = "CodexUsage.remoteTaskCheckpoints.v2"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String: Date] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let values = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return values
    }

    func save(_ values: [String: Date]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

final class CodexTaskActivityStore: ObservableObject {
    @Published private(set) var snapshot: CodexTaskActivitySnapshot
    var onNewCompletion: ((CodexTaskCompletion) -> Void)?

    private let homeDirectory: URL
    private let persistence: CodexTaskActivityPersistence
    private let remoteCheckpointPersistence: CodexRemoteTaskCheckpointPersistence
    private var reducer: CodexTaskActivityReducer
    private var baselineEstablished: Bool
    private var replayNotBefore: Date?
    private var localMonitor: CodexTaskMonitor?
    private var remoteMonitors: [String: RemoteCodexTaskMonitor] = [:]
    private var remoteMonitorIDs: [String: UUID] = [:]
    private var remoteCheckpoints: [String: Date]
    private var sourceAvailability: [String: CodexTaskMonitorAvailability] = ["local": .starting]
    private var configuredRemoteHosts: [String] = []
    private var remoteMonitoringEnabled = false
    private var started = false

    init(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        defaults: UserDefaults = .standard
    ) {
        self.homeDirectory = homeDirectory
        let persistence = CodexTaskActivityPersistence(defaults: defaults)
        self.persistence = persistence
        let remoteCheckpointPersistence = CodexRemoteTaskCheckpointPersistence(defaults: defaults)
        self.remoteCheckpointPersistence = remoteCheckpointPersistence
        self.remoteCheckpoints = remoteCheckpointPersistence.load()
        let persisted = persistence.load()
        self.reducer = CodexTaskActivityReducer(persisted: persisted)
        self.baselineEstablished = persisted.baselineEstablished
        self.replayNotBefore = persisted.replayNotBefore
        self.snapshot = reducer.snapshot(availability: .starting)
    }

    func start(remoteHosts: [String] = [], remoteMonitoringEnabled: Bool = false) {
        guard !started else { return }
        started = true
        configuredRemoteHosts = normalizedRemoteHosts(remoteHosts)
        self.remoteMonitoringEnabled = remoteMonitoringEnabled
        let monitor = CodexTaskMonitor(
            homeDirectory: homeDirectory,
            baselineEstablished: baselineEstablished,
            replayNotBefore: replayNotBefore
        ) { [weak self] update in
            DispatchQueue.main.sync {
                self?.handleLocal(update)
            }
        }
        self.localMonitor = monitor
        monitor.start()
        if remoteMonitoringEnabled { synchronizeRemoteMonitors() }
        publishAndPersist()
    }

    func stop() {
        started = false
        localMonitor?.stop()
        localMonitor = nil
        for monitor in remoteMonitors.values { monitor.stop() }
        remoteMonitors.removeAll()
        remoteMonitorIDs.removeAll()
        sourceAvailability = ["local": .starting]
    }

    func configureRemoteHosts(_ hosts: [String]) {
        let normalized = normalizedRemoteHosts(hosts)
        guard normalized != configuredRemoteHosts else { return }
        configuredRemoteHosts = normalized
        guard started else { return }
        removeUnconfiguredRemoteMonitors()
        if remoteMonitoringEnabled { synchronizeRemoteMonitors() }
        publishAndPersist()
    }

    func setRemoteMonitoringEnabled(_ enabled: Bool) {
        guard enabled != remoteMonitoringEnabled else { return }
        remoteMonitoringEnabled = enabled
        guard started else { return }
        if enabled {
            synchronizeRemoteMonitors()
        } else {
            for (key, monitor) in remoteMonitors {
                monitor.stop()
                sourceAvailability.removeValue(forKey: "remote:\(key)")
                _ = reducer.removeRunningTasks(sourceLabel: key)
            }
            remoteMonitors.removeAll()
            remoteMonitorIDs.removeAll()
        }
        publishAndPersist()
    }

    func refreshRemoteMonitoring() {
        guard started, remoteMonitoringEnabled else { return }
        removeUnconfiguredRemoteMonitors()
        for host in configuredRemoteHosts {
            let key = host.lowercased()
            if let monitor = remoteMonitors[key] {
                if sourceAvailability["remote:\(key)"] == .ready { continue }
                remoteMonitorIDs.removeValue(forKey: key)
                remoteMonitors.removeValue(forKey: key)
                monitor.stop()
            }
            startRemoteMonitor(host: host)
        }
    }

    func markRead(_ identity: String) {
        guard reducer.markRead(identity) else { return }
        publishAndPersist()
    }

    func markAllRead() {
        guard reducer.markAllRead() else { return }
        publishAndPersist()
    }

    private func handleLocal(_ update: CodexTaskMonitorUpdate) {
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
                publishAndPersist()
            }
            for completion in completions {
                onNewCompletion?(completion)
            }

        case .ready:
            if !baselineEstablished {
                baselineEstablished = true
            }
            sourceAvailability["local"] = .ready
            publishAndPersist()

        case let .checkpoint(date):
            guard replayNotBefore == nil || date > replayNotBefore! else { return }
            replayNotBefore = date
            publishAndPersist()

        case let .inactiveLocalTasks(identities):
            guard reducer.removeRunningTasks(localIdentities: identities) else { return }
            publishAndPersist()

        case let .unavailable(message):
            sourceAvailability["local"] = .unavailable(message)
            publishAndPersist()
        }
    }

    private func handleRemote(_ update: RemoteCodexTaskMonitorUpdate, host: String, monitorID: UUID) {
        let key = host.lowercased()
        guard remoteMonitoringEnabled,
              remoteMonitorIDs[key] == monitorID,
              configuredRemoteHosts.contains(where: {
            $0.caseInsensitiveCompare(host) == .orderedSame
        }) else { return }
        let sourceID = "remote:\(key)"
        switch update {
        case let .events(events, origin):
            var changed = false
            var completions: [CodexTaskCompletion] = []
            for event in events {
                let transition = reducer.apply(event, origin: origin)
                changed = changed || transition.changed
                if let completion = transition.newCompletion { completions.append(completion) }
            }
            if changed { publishAndPersist() }
            for completion in completions { onNewCompletion?(completion) }

        case let .connecting(attempt, maximum):
            sourceAvailability[sourceID] = .connecting(attempt, maximum)
            publishAndPersist()

        case let .ready(checkpoint):
            remoteCheckpoints[host.lowercased()] = checkpoint
            remoteCheckpointPersistence.save(remoteCheckpoints)
            sourceAvailability[sourceID] = .ready
            publishAndPersist()

        case let .unavailable(message):
            sourceAvailability[sourceID] = .unavailable(message)
            publishAndPersist()
        }
    }

    private func removeUnconfiguredRemoteMonitors() {
        let desired = Set(configuredRemoteHosts.map { $0.lowercased() })
        let removedKeys = remoteMonitors.keys.filter { !desired.contains($0) }
        for key in removedKeys {
            remoteMonitors.removeValue(forKey: key)?.stop()
            remoteMonitorIDs.removeValue(forKey: key)
            sourceAvailability.removeValue(forKey: "remote:\(key)")
            _ = reducer.removeRunningTasks(sourceLabel: key)
        }
    }

    private func synchronizeRemoteMonitors() {
        removeUnconfiguredRemoteMonitors()
        for host in configuredRemoteHosts where remoteMonitors[host.lowercased()] == nil {
            startRemoteMonitor(host: host)
        }
    }

    private func startRemoteMonitor(host: String) {
        let key = host.lowercased()
        let monitorID = UUID()
        sourceAvailability["remote:\(key)"] = .starting
        let monitor = RemoteCodexTaskMonitor(
            host: host,
            recoveryCheckpoint: remoteCheckpoints[key]
        ) { [weak self] update in
            DispatchQueue.main.async {
                self?.handleRemote(update, host: host, monitorID: monitorID)
            }
        }
        remoteMonitors[key] = monitor
        remoteMonitorIDs[key] = monitorID
        monitor.authorize()
    }

    private func normalizedRemoteHosts(_ hosts: [String]) -> [String] {
        CodexRemoteHost.parseList(hosts.joined(separator: ","))
    }

    private func combinedAvailability() -> CodexTaskMonitorAvailability {
        let orderedKeys = sourceAvailability.keys.sorted()
        for key in orderedKeys {
            if case let .unavailable(message) = sourceAvailability[key] { return .unavailable(message) }
        }
        for key in orderedKeys {
            if case let .connecting(attempt, maximum) = sourceAvailability[key] {
                return .connecting(attempt, maximum)
            }
        }
        if sourceAvailability.values.contains(.starting) { return .starting }
        return .ready
    }

    private func publishAndPersist() {
        snapshot = reducer.snapshot(
            availability: combinedAvailability(),
            remoteHosts: configuredRemoteHosts,
            remoteMonitoringEnabled: remoteMonitoringEnabled
        )
        persistence.save(reducer.persistedState(
            baselineEstablished: baselineEstablished,
            replayNotBefore: replayNotBefore
        ))
    }
}

private enum CodexTaskMonitorUpdate {
    case events([CodexTaskEvent], CodexTaskEventOrigin)
    case inactiveLocalTasks(Set<String>)
    case ready
    case checkpoint(Date)
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

private enum CodexTaskReadError: Error {
    case unavailable
}

final class CodexBoundedPipeCollector: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var handle: FileHandle?
    private var data = Data()
    private var exceededLimit = false
    private var didFinish = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func start(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] readable in
            self?.consume(readable.availableData)
        }
    }

    func result(timeout: DispatchTimeInterval) -> Data? {
        guard finished.wait(timeout: .now() + timeout) == .success else {
            cancel()
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return exceededLimit ? nil : data
    }

    func cancel() {
        lock.lock()
        let currentHandle = handle
        handle = nil
        lock.unlock()
        currentHandle?.readabilityHandler = nil
    }

    private func consume(_ chunk: Data) {
        if chunk.isEmpty {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return
            }
            didFinish = true
            let currentHandle = handle
            handle = nil
            lock.unlock()
            currentHandle?.readabilityHandler = nil
            finished.signal()
            return
        }

        lock.lock()
        if chunk.count <= maximumBytes - data.count {
            data.append(chunk)
        } else {
            exceededLimit = true
        }
        lock.unlock()
    }
}

enum CodexRolloutOpenFileProbe {
    private static let maximumCandidateCount = 128
    private static let maximumOutputBytes = 2 * 1_024 * 1_024

    enum ProbeError: Error {
        case unavailable
        case invalidOutput
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    static func parseOpenPaths(_ data: Data) -> Set<String> {
        var paths = Set<String>()
        for rawField in data.split(separator: 0, omittingEmptySubsequences: true) {
            let field = rawField.drop(while: { $0 == 10 || $0 == 13 })
            guard field.first == Character("n").asciiValue,
                  let path = String(data: Data(field.dropFirst()), encoding: .utf8),
                  path.hasPrefix("/")
            else { continue }
            paths.insert(normalizedPath(path))
        }
        return paths
    }

    static func run(candidatePaths: [String]) -> Result<Set<String>, ProbeError> {
        let candidates = Array(Set(candidatePaths.map(normalizedPath))).sorted()
        guard !candidates.isEmpty else { return .success([]) }
        guard candidates.count <= maximumCandidateCount else { return .failure(.unavailable) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-P", "-w", "-S", "2", "-F0n", "--"] + candidates

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let outputCollector = CodexBoundedPipeCollector(maximumBytes: maximumOutputBytes)
        let errorCollector = CodexBoundedPipeCollector(maximumBytes: maximumOutputBytes)
        outputCollector.start(output.fileHandleForReading)
        errorCollector.start(error.fileHandleForReading)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            outputCollector.cancel()
            errorCollector.cancel()
            return .failure(.unavailable)
        }

        if exited.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            outputCollector.cancel()
            errorCollector.cancel()
            return .failure(.unavailable)
        }
        guard let data = outputCollector.result(timeout: .seconds(1)),
              let errorData = errorCollector.result(timeout: .seconds(1))
        else {
            return .failure(.invalidOutput)
        }

        guard (process.terminationStatus == 0 || process.terminationStatus == 1),
              errorData.isEmpty
        else {
            return .failure(.unavailable)
        }

        let openPaths = parseOpenPaths(data).intersection(candidates)
        if process.terminationStatus == 0, openPaths.isEmpty {
            return .failure(.invalidOutput)
        }
        return .success(openPaths)
    }
}

private final class CodexTaskMonitor {
    private let homeDirectory: URL
    private let onUpdate: (CodexTaskMonitorUpdate) -> Void
    private let queue = DispatchQueue(label: "CodexS.task-monitor", qos: .utility)
    private let fileManager = FileManager.default
    private var timer: DispatchSourceTimer?
    private var sourcesByPath: [String: CodexTaskSource] = [:]
    private var cursorsByPath: [String: CodexTaskFileCursor] = [:]
    private var modificationDatesByPath: [String: Date] = [:]
    private var potentialRunningIdentityByPath: [String: String] = [:]
    private var livenessTracker = CodexTaskLivenessTracker()
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
            self?.modificationDatesByPath.removeAll()
            self?.potentialRunningIdentityByPath.removeAll()
            self?.livenessTracker.reset()
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
        let scanWatermark = Date()
        let checkpointCandidate = shouldDiscover ? scanWatermark : nil
        let discoverySucceeded = shouldDiscover ? discoverNewSources() : false

        var allReadsSucceeded = true
        var successfullyReadPaths = Set<String>()
        for source in sourcesByPath.values {
            switch readAppendedEvents(from: source, onEvents: { [weak self] events, replayed in
                guard let self else { return }
                if replayed {
                    self.emitReplay(events, sourcePath: source.path, scanWatermark: scanWatermark)
                } else {
                    self.emitSorted(events, sourcePath: source.path, origin: .live)
                }
            }) {
            case .success:
                successfullyReadPaths.insert(source.path)
            case .failure:
                allReadsSucceeded = false
            }
        }

        if let checkpointCandidate, discoverySucceeded {
            reconcileLocalLiveness(
                at: checkpointCandidate,
                successfullyReadPaths: successfullyReadPaths
            )
        }
        if let checkpointCandidate, discoverySucceeded, allReadsSucceeded {
            replayNotBefore = checkpointCandidate
            onUpdate(.checkpoint(checkpointCandidate))
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

        sourcesByPath = Dictionary(
            discovered.map { ($0.path, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let initialScanWatermark = startedAt
        for source in discovered {
            switch readAppendedEvents(from: source, onEvents: { events, _ in
                self.emitReplay(
                    events,
                    sourcePath: source.path,
                    scanWatermark: initialScanWatermark
                )
            }) {
            case .success:
                break
            case .failure:
                onUpdate(.unavailable("暂时无法读取 Codex 本地任务记录"))
                return
            }
        }
        initialScanCompleted = true
        baselineEstablished = true
        replayNotBefore = startedAt
        onUpdate(.checkpoint(startedAt))
        onUpdate(.ready)
    }

    private func discoverNewSources() -> Bool {
        // Keep tailing already discovered files if SQLite is briefly busy or unavailable.
        guard case let .success(discovered) = discoverSources() else { return false }

        let discoveredByPath = Dictionary(
            discovered.map { ($0.path, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let removedPaths = Set(sourcesByPath.keys).subtracting(discoveredByPath.keys)
        for path in removedPaths {
            cursorsByPath.removeValue(forKey: path)
        }
        sourcesByPath = discoveredByPath
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
            guard let threadID = CodexTaskIdentifier.validated(row["id"] as? String),
                  let path = row["rolloutPath"] as? String,
                  fileManager.fileExists(atPath: path)
            else { return nil }

            let normalizedPath = CodexRolloutOpenFileProbe.normalizedPath(path)

            let rawTitle = row["title"] as? String ?? ""
            let cwd = row["cwd"] as? String ?? ""
            let createdAtMilliseconds = (row["createdAtMs"] as? NSNumber)?.doubleValue
                ?? Double(row["createdAtMs"] as? String ?? "")
                ?? 0
            return CodexTaskSource(
                path: normalizedPath,
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
        from source: CodexTaskSource,
        onEvents: ([CodexTaskEvent], Bool) -> Void
    ) -> Result<Void, CodexTaskReadError> {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: source.path)
        } catch {
            return .failure(.unavailable)
        }
        guard let fileSizeNumber = attributes[.size] as? NSNumber else {
            return .failure(.unavailable)
        }
        guard let modificationDate = attributes[.modificationDate] as? Date else {
            return .failure(.unavailable)
        }
        modificationDatesByPath[source.path] = modificationDate

        let fileSize = fileSizeNumber.uint64Value
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let hadCursor = cursorsByPath[source.path] != nil
        var cursor = cursorsByPath[source.path] ?? CodexTaskFileCursor()
        var replayed = !hadCursor
        if fileSize < cursor.offset || (cursor.fileNumber != nil && cursor.fileNumber != fileNumber) {
            cursor.offset = 0
            cursor.fileNumber = fileNumber
            cursor.lineBuffer.reset()
            potentialRunningIdentityByPath.removeValue(forKey: source.path)
            replayed = true
        }
        guard fileSize > cursor.offset else {
            cursor.fileNumber = fileNumber
            cursorsByPath[source.path] = cursor
            return .success(())
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
            let earliestAllowed = source.createdAt.addingTimeInterval(-1)
            var eventBuffer = CodexTaskEventBatchBuffer()
            while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                cursor.offset += UInt64(data.count)
                for line in cursor.lineBuffer.append(data) {
                    guard let event = CodexRolloutTaskEventParser.parse(
                        line: line,
                        metadata: source.metadata
                    ), event.occurredAt >= earliestAllowed else { continue }
                    if let batch = eventBuffer.append(event) {
                        onEvents(batch, replayed)
                    }
                }
            }
            let finalBatch = eventBuffer.finish()
            if !finalBatch.isEmpty {
                onEvents(finalBatch, replayed)
            }
            cursor.fileNumber = fileNumber
            cursorsByPath[source.path] = cursor
            return .success(())
        } catch {
            cursor.fileNumber = fileNumber
            cursorsByPath[source.path] = cursor
            return .failure(.unavailable)
        }
    }

    private func emitReplay(
        _ events: [CodexTaskEvent],
        sourcePath: String,
        scanWatermark: Date
    ) {
        let sorted = events.sorted { $0.occurredAt < $1.occurredAt }
        let grouped = Dictionary(grouping: sorted) { event in
            CodexTaskReplayPolicy.origin(
                for: event.occurredAt,
                replayNotBefore: replayNotBefore,
                baselineEstablished: baselineEstablished
            )
        }
        for origin in [CodexTaskEventOrigin.baseline, .live, .recovery] {
            let retained = (grouped[origin] ?? []).filter {
                CodexTaskReplayPolicy.shouldRetain(
                    $0,
                    origin: origin,
                    scanWatermark: scanWatermark
                )
            }
            emitSorted(retained, sourcePath: sourcePath, origin: origin)
        }
    }

    private func emitSorted(
        _ events: [CodexTaskEvent],
        sourcePath: String,
        origin: CodexTaskEventOrigin
    ) {
        guard !events.isEmpty else { return }
        let sorted = events.sorted { $0.occurredAt < $1.occurredAt }
        for event in sorted {
            switch event.kind {
            case .started:
                potentialRunningIdentityByPath[sourcePath] = event.identity
            case .completed, .aborted:
                if potentialRunningIdentityByPath[sourcePath] == event.identity {
                    potentialRunningIdentityByPath.removeValue(forKey: sourcePath)
                }
            }
        }
        onUpdate(.events(sorted, origin))
    }

    private func reconcileLocalLiveness(
        at sampledAt: Date,
        successfullyReadPaths: Set<String>
    ) {
        let pathsByIdentity = Dictionary(
            grouping: potentialRunningIdentityByPath.keys,
            by: { potentialRunningIdentityByPath[$0]! }
        )
        let verifiablePaths = pathsByIdentity.values
            .filter { paths in
                paths.allSatisfy {
                    modificationDatesByPath[$0] != nil
                        && (sourcesByPath[$0] == nil || successfullyReadPaths.contains($0))
                }
            }
            .flatMap { $0 }
        guard !verifiablePaths.isEmpty else {
            livenessTracker.reset()
            return
        }

        let candidatePaths = verifiablePaths.filter { sourcesByPath[$0] != nil }
        let openPaths: Set<String>
        switch CodexRolloutOpenFileProbe.run(candidatePaths: candidatePaths) {
        case let .success(paths):
            openPaths = paths
        case .failure:
            livenessTracker.reset()
            return
        }

        let observations = verifiablePaths.compactMap { path -> CodexTaskLivenessObservation? in
            guard let taskIdentity = potentialRunningIdentityByPath[path],
                  let modificationDate = modificationDatesByPath[path]
            else { return nil }
            return CodexTaskLivenessObservation(
                taskIdentity: taskIdentity,
                modificationDate: modificationDate,
                isOpen: openPaths.contains(path)
            )
        }
        guard observations.count == verifiablePaths.count else {
            livenessTracker.reset()
            return
        }

        let inactiveIdentities = livenessTracker.observe(observations, at: sampledAt)
        guard !inactiveIdentities.isEmpty else { return }
        potentialRunningIdentityByPath = potentialRunningIdentityByPath.filter { _, identity in
            !inactiveIdentities.contains(identity)
        }
        modificationDatesByPath = modificationDatesByPath.filter { path, _ in
            potentialRunningIdentityByPath[path] != nil || sourcesByPath[path] != nil
        }
        onUpdate(.inactiveLocalTasks(inactiveIdentities))
    }
}

func compactTaskTitle(_ rawValue: String) -> String {
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
