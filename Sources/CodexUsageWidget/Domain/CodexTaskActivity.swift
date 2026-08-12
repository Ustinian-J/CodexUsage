import Foundation

enum CodexTaskTimestamp {
    static let maximumUnixTime: Double = 253_402_300_799

    static func date(unixTime: Double) -> Date? {
        guard unixTime.isFinite,
              unixTime >= 0,
              unixTime <= maximumUnixTime
        else { return nil }
        return Date(timeIntervalSince1970: unixTime)
    }
}

enum CodexTaskIdentifier {
    static let maximumUTF8ByteCount = 512

    static func validated(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.utf8.count <= maximumUTF8ByteCount
        else { return nil }
        return value
    }
}

enum CodexTaskMonitorAvailability: Equatable {
    case starting
    case ready
    case unavailable(String)
}

enum CodexTaskOutcome: String, Codable, Equatable {
    case completed
    case interrupted
}

struct CodexTaskMetadata: Codable, Equatable {
    let threadID: String
    let title: String
    let projectName: String?
    let sourceLabel: String?

    init(threadID: String, title: String, projectName: String?, sourceLabel: String? = nil) {
        self.threadID = threadID
        self.title = title
        self.projectName = projectName
        self.sourceLabel = sourceLabel
    }
}

enum CodexTaskEventKind: Equatable {
    case started
    case completed
    case aborted
}

struct CodexTaskEvent: Equatable {
    let identity: String
    let turnID: String
    let occurredAt: Date
    let metadata: CodexTaskMetadata
    let kind: CodexTaskEventKind

    init(
        turnID: String,
        occurredAt: Date,
        metadata: CodexTaskMetadata,
        kind: CodexTaskEventKind
    ) {
        self.identity = Self.stableIdentity(turnID: turnID, threadID: metadata.threadID)
        self.turnID = turnID
        self.occurredAt = occurredAt
        self.metadata = metadata
        self.kind = kind
    }

    static func stableIdentity(turnID: String, threadID: String) -> String {
        if UUID(uuidString: turnID) != nil {
            return turnID.lowercased()
        }
        return threadID + ":" + turnID
    }
}

struct CodexRunningTask: Codable, Equatable, Identifiable {
    let id: String
    let turnID: String
    let threadID: String
    let title: String
    let projectName: String?
    let sourceLabel: String?
    let startedAt: Date

    init(
        id: String,
        turnID: String,
        threadID: String,
        title: String,
        projectName: String?,
        sourceLabel: String? = nil,
        startedAt: Date
    ) {
        self.id = id
        self.turnID = turnID
        self.threadID = threadID
        self.title = title
        self.projectName = projectName
        self.sourceLabel = sourceLabel
        self.startedAt = startedAt
    }
}

struct CodexTaskCompletion: Codable, Equatable, Identifiable {
    let id: String
    let turnID: String
    let threadID: String
    let title: String
    let projectName: String?
    let sourceLabel: String?
    let completedAt: Date
    let outcome: CodexTaskOutcome
    var readAt: Date?

    init(
        id: String,
        turnID: String,
        threadID: String,
        title: String,
        projectName: String?,
        sourceLabel: String? = nil,
        completedAt: Date,
        outcome: CodexTaskOutcome,
        readAt: Date?
    ) {
        self.id = id
        self.turnID = turnID
        self.threadID = threadID
        self.title = title
        self.projectName = projectName
        self.sourceLabel = sourceLabel
        self.completedAt = completedAt
        self.outcome = outcome
        self.readAt = readAt
    }
}

struct CodexTaskActivitySnapshot: Equatable {
    let availability: CodexTaskMonitorAvailability
    let runningTasks: [CodexRunningTask]
    let recentCompletions: [CodexTaskCompletion]
    let remoteHosts: [String]

    init(
        availability: CodexTaskMonitorAvailability,
        runningTasks: [CodexRunningTask],
        recentCompletions: [CodexTaskCompletion],
        remoteHosts: [String] = []
    ) {
        self.availability = availability
        self.runningTasks = runningTasks
        self.recentCompletions = recentCompletions
        self.remoteHosts = remoteHosts
    }

    static let starting = CodexTaskActivitySnapshot(
        availability: .starting,
        runningTasks: [],
        recentCompletions: []
    )

    var runningCount: Int { runningTasks.count }
    var unreadCount: Int { recentCompletions.filter { $0.readAt == nil }.count }
    var showsRed: Bool { runningCount > 0 }
    var showsYellow: Bool { unreadCount > 0 }
    var showsGreen: Bool { availability == .ready && runningCount == 0 }
}

struct CodexTaskActivityPersistedState: Codable, Equatable {
    static let version = 2
    static let empty = CodexTaskActivityPersistedState(
        baselineEstablished: false,
        replayNotBefore: nil,
        recentCompletions: [],
        terminalIdentities: []
    )

    let schemaVersion: Int
    var baselineEstablished: Bool
    var replayNotBefore: Date?
    var recentCompletions: [CodexTaskCompletion]
    var terminalIdentities: [String]

    init(
        baselineEstablished: Bool,
        replayNotBefore: Date?,
        recentCompletions: [CodexTaskCompletion],
        terminalIdentities: [String]
    ) {
        self.schemaVersion = Self.version
        self.baselineEstablished = baselineEstablished
        self.replayNotBefore = replayNotBefore
        self.recentCompletions = recentCompletions
        self.terminalIdentities = terminalIdentities
    }
}

enum CodexTaskEventOrigin: Equatable, Hashable {
    case baseline
    case live
    case recovery
}

enum CodexTaskReplayPolicy {
    private static let staleBaselineStartAge: TimeInterval = 12 * 60 * 60

    static func origin(
        for occurredAt: Date,
        replayNotBefore: Date,
        baselineEstablished: Bool
    ) -> CodexTaskEventOrigin {
        guard occurredAt >= replayNotBefore else { return .baseline }
        return baselineEstablished ? .recovery : .live
    }

    static func replayCutoff(previous: Date?, scanWatermark: Date) -> Date {
        guard let previous else { return scanWatermark }
        return min(previous, scanWatermark)
    }

    static func clockRolledBack(previous: Date?, scanWatermark: Date) -> Bool {
        guard let previous else { return false }
        return scanWatermark < previous
    }

    static func shouldRetain(
        _ event: CodexTaskEvent,
        origin: CodexTaskEventOrigin,
        scanWatermark: Date,
        clockRolledBack: Bool = false
    ) -> Bool {
        guard event.kind == .started,
              origin == .baseline || clockRolledBack
        else { return true }
        return event.occurredAt >= scanWatermark.addingTimeInterval(-staleBaselineStartAge)
    }
}

struct CodexTaskActivityTransition {
    let changed: Bool
    let newCompletion: CodexTaskCompletion?

    static let unchanged = CodexTaskActivityTransition(changed: false, newCompletion: nil)
}

struct CodexTaskActivityReducer {
    private static let completionLimit = 50
    private static let terminalIdentityLimit = 8_192

    private var runningByIdentity: [String: CodexRunningTask] = [:]
    private var completions: [CodexTaskCompletion]
    private var terminalIdentitySet: Set<String>
    private var terminalIdentityOrder: [String]

    init(persisted: CodexTaskActivityPersistedState) {
        completions = Array(persisted.recentCompletions.prefix(Self.completionLimit))
        terminalIdentityOrder = Array(persisted.terminalIdentities.suffix(Self.terminalIdentityLimit))
        terminalIdentitySet = Set(terminalIdentityOrder)
    }

    func persistedState(
        baselineEstablished: Bool,
        replayNotBefore: Date?
    ) -> CodexTaskActivityPersistedState {
        CodexTaskActivityPersistedState(
            baselineEstablished: baselineEstablished,
            replayNotBefore: replayNotBefore,
            recentCompletions: completions,
            terminalIdentities: terminalIdentityOrder
        )
    }

    func snapshot(
        availability: CodexTaskMonitorAvailability,
        remoteHosts: [String] = []
    ) -> CodexTaskActivitySnapshot {
        CodexTaskActivitySnapshot(
            availability: availability,
            runningTasks: runningByIdentity.values.sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
                return lhs.id < rhs.id
            },
            recentCompletions: completions,
            remoteHosts: remoteHosts
        )
    }

    mutating func apply(
        _ event: CodexTaskEvent,
        origin: CodexTaskEventOrigin
    ) -> CodexTaskActivityTransition {
        switch event.kind {
        case .started:
            guard !terminalIdentitySet.contains(event.identity),
                  runningByIdentity[event.identity] == nil
            else { return .unchanged }

            if runningByIdentity.values.contains(where: {
                $0.threadID == event.metadata.threadID && $0.startedAt >= event.occurredAt
            }) {
                return .unchanged
            }

            let superseded = runningByIdentity.values
                .filter { $0.threadID == event.metadata.threadID && $0.id != event.identity }
                .map(\.id)
            for identity in superseded {
                runningByIdentity.removeValue(forKey: identity)
            }
            runningByIdentity[event.identity] = CodexRunningTask(
                id: event.identity,
                turnID: event.turnID,
                threadID: event.metadata.threadID,
                title: event.metadata.title,
                projectName: event.metadata.projectName,
                sourceLabel: event.metadata.sourceLabel,
                startedAt: event.occurredAt
            )
            return CodexTaskActivityTransition(changed: true, newCompletion: nil)

        case .completed:
            return applyTerminal(event, outcome: .completed, origin: origin)

        case .aborted:
            return applyTerminal(event, outcome: .interrupted, origin: origin)
        }
    }

    mutating func markRead(_ identity: String, at date: Date = Date()) -> Bool {
        guard let index = completions.firstIndex(where: { $0.id == identity }),
              completions[index].readAt == nil
        else { return false }

        completions[index].readAt = date
        return true
    }

    mutating func markAllRead(at date: Date = Date()) -> Bool {
        var changed = false
        for index in completions.indices where completions[index].readAt == nil {
            completions[index].readAt = date
            changed = true
        }
        return changed
    }

    mutating func removeRunningTasks(sourceLabel: String) -> Bool {
        let identities = runningByIdentity.values
            .filter { $0.sourceLabel?.caseInsensitiveCompare(sourceLabel) == .orderedSame }
            .map(\.id)
        guard !identities.isEmpty else { return false }
        for identity in identities {
            runningByIdentity.removeValue(forKey: identity)
        }
        return true
    }

    private mutating func applyTerminal(
        _ event: CodexTaskEvent,
        outcome: CodexTaskOutcome,
        origin: CodexTaskEventOrigin
    ) -> CodexTaskActivityTransition {
        let removedRunning = runningByIdentity.removeValue(forKey: event.identity) != nil
        guard !terminalIdentitySet.contains(event.identity) else {
            return CodexTaskActivityTransition(changed: removedRunning, newCompletion: nil)
        }

        rememberTerminalIdentity(event.identity)
        guard origin != .baseline else {
            return CodexTaskActivityTransition(changed: true, newCompletion: nil)
        }

        let completion = CodexTaskCompletion(
            id: event.identity,
            turnID: event.turnID,
            threadID: event.metadata.threadID,
            title: event.metadata.title,
            projectName: event.metadata.projectName,
            sourceLabel: event.metadata.sourceLabel,
            completedAt: event.occurredAt,
            outcome: outcome,
            readAt: nil
        )
        completions.removeAll { $0.id == completion.id }
        completions.append(completion)
        completions.sort {
            if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
            return $0.id < $1.id
        }
        if completions.count > Self.completionLimit {
            completions.removeLast(completions.count - Self.completionLimit)
        }
        return CodexTaskActivityTransition(changed: true, newCompletion: completion)
    }

    private mutating func rememberTerminalIdentity(_ identity: String) {
        terminalIdentitySet.insert(identity)
        terminalIdentityOrder.removeAll { $0 == identity }
        terminalIdentityOrder.append(identity)
        while terminalIdentityOrder.count > Self.terminalIdentityLimit {
            let removed = terminalIdentityOrder.removeFirst()
            terminalIdentitySet.remove(removed)
        }
    }
}
