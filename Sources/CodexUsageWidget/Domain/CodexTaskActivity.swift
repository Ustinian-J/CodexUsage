import Foundation

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
    let startedAt: Date
}

struct CodexTaskCompletion: Codable, Equatable, Identifiable {
    let id: String
    let turnID: String
    let threadID: String
    let title: String
    let projectName: String?
    let completedAt: Date
    let outcome: CodexTaskOutcome
    var readAt: Date?
}

struct CodexTaskActivitySnapshot: Equatable {
    let availability: CodexTaskMonitorAvailability
    let runningTasks: [CodexRunningTask]
    let recentCompletions: [CodexTaskCompletion]

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
    static func origin(
        for occurredAt: Date,
        replayNotBefore: Date,
        baselineEstablished: Bool
    ) -> CodexTaskEventOrigin {
        guard occurredAt >= replayNotBefore else { return .baseline }
        return baselineEstablished ? .recovery : .live
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

    func snapshot(availability: CodexTaskMonitorAvailability) -> CodexTaskActivitySnapshot {
        CodexTaskActivitySnapshot(
            availability: availability,
            runningTasks: runningByIdentity.values.sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
                return lhs.id < rhs.id
            },
            recentCompletions: completions
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

    mutating func removeRunningTasks(startedBefore cutoff: Date) -> Bool {
        let stale = runningByIdentity.values
            .filter { $0.startedAt < cutoff }
            .map(\.id)
        guard !stale.isEmpty else { return false }
        for identity in stale {
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
            completedAt: event.occurredAt,
            outcome: outcome,
            readAt: nil
        )
        completions.removeAll { $0.id == completion.id }
        completions.insert(completion, at: 0)
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
