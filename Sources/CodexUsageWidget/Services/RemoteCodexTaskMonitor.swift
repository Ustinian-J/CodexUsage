import Foundation

enum CodexRemoteHost {
    static func validated(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 255,
              value.first?.isLetter == true || value.first?.isNumber == true,
              value.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) })
        else { return nil }
        return value
    }

    static func parseList(_ rawValue: String) -> [String] {
        var seen = Set<String>()
        return rawValue
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .compactMap { validated(String($0)) }
            .filter { seen.insert($0.lowercased()).inserted }
    }
}

enum RemoteCodexTaskMonitorUpdate {
    case events([CodexTaskEvent], CodexTaskEventOrigin)
    case ready(Date)
    case unavailable(String)
}

struct RemoteCodexTaskEnvelope: Decodable {
    let kind: String
    let event: String?
    let turnID: String?
    let occurredAt: Double?
    let threadID: String?
    let title: String?
    let projectName: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case event
        case turnID = "turn_id"
        case occurredAt = "occurred_at"
        case threadID = "thread_id"
        case title
        case projectName = "project_name"
    }

    static func parse(line: Data, host: String) -> CodexTaskEvent? {
        guard let envelope = try? JSONDecoder().decode(Self.self, from: line),
              envelope.kind == "event",
              let eventName = envelope.event,
              let turnID = envelope.turnID,
              !turnID.isEmpty,
              let occurredAt = envelope.occurredAt,
              occurredAt.isFinite,
              let threadID = envelope.threadID,
              !threadID.isEmpty
        else { return nil }

        let kind: CodexTaskEventKind
        switch eventName {
        case "started": kind = .started
        case "completed": kind = .completed
        case "aborted": kind = .aborted
        default: return nil
        }
        return CodexTaskEvent(
            turnID: turnID,
            occurredAt: Date(timeIntervalSince1970: occurredAt),
            metadata: CodexTaskMetadata(
                threadID: threadID,
                title: compactTaskTitle(envelope.title ?? "Codex 任务"),
                projectName: envelope.projectName,
                sourceLabel: host
            ),
            kind: kind
        )
    }
}

final class RemoteCodexTaskMonitor {
    private let host: String
    private let onUpdate: (RemoteCodexTaskMonitorUpdate) -> Void
    private let queue: DispatchQueue
    private var process: Process?
    private var restartWorkItem: DispatchWorkItem?
    private var lineBuffer = CodexJSONLineBuffer()
    private var pendingReplay: [CodexTaskEvent] = []
    private var recoveryCheckpoint: Date?
    private var streamReady = false
    private var stopped = false

    init(
        host: String,
        recoveryCheckpoint: Date?,
        onUpdate: @escaping (RemoteCodexTaskMonitorUpdate) -> Void
    ) {
        self.host = host
        self.recoveryCheckpoint = recoveryCheckpoint
        self.onUpdate = onUpdate
        self.queue = DispatchQueue(label: "CodexS.remote-task-monitor.\(host)", qos: .utility)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.process == nil, !self.stopped else { return }
            self.launch()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.restartWorkItem?.cancel()
            self.restartWorkItem = nil
            self.process?.terminationHandler = nil
            self.process?.terminate()
            self.process = nil
            self.lineBuffer.reset()
            self.pendingReplay.removeAll()
        }
    }

    private func launch() {
        guard CodexRemoteHost.validated(host) == host,
              FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh")
        else {
            onUpdate(.unavailable("远程任务主机配置无效：\(host)"))
            return
        }

        streamReady = false
        lineBuffer.reset()
        pendingReplay.removeAll()

        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=yes",
            host,
            Self.remoteCommand
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.queue.async {
                guard self.process === finished else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                guard !self.stopped else { return }
                self.onUpdate(.unavailable("远程任务主机 \(self.host) 暂时不可用"))
                self.scheduleRestart()
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            onUpdate(.unavailable("无法启动远程任务监听：\(host)"))
            scheduleRestart()
        }
    }

    private func consume(_ data: Data) {
        for line in lineBuffer.append(data) {
            guard let envelope = try? JSONDecoder().decode(RemoteCodexTaskEnvelope.self, from: line) else {
                continue
            }
            switch envelope.kind {
            case "event":
                guard let event = RemoteCodexTaskEnvelope.parse(line: line, host: host) else { continue }
                if streamReady {
                    onUpdate(.events([event], .live))
                } else {
                    pendingReplay.append(event)
                }
            case "ready":
                finishReplay()
            case "error":
                onUpdate(.unavailable("远程任务主机 \(host) 未找到可读的 Codex 会话"))
            default:
                continue
            }
        }
    }

    private func finishReplay() {
        let events = pendingReplay.sorted { $0.occurredAt < $1.occurredAt }
        pendingReplay.removeAll()
        if let checkpoint = recoveryCheckpoint {
            let grouped = Dictionary(grouping: events) { event in
                CodexTaskReplayPolicy.origin(
                    for: event.occurredAt,
                    replayNotBefore: checkpoint,
                    baselineEstablished: true
                )
            }
            for origin in [CodexTaskEventOrigin.baseline, .recovery] {
                let batch = grouped[origin] ?? []
                if !batch.isEmpty { onUpdate(.events(batch, origin)) }
            }
        } else if !events.isEmpty {
            onUpdate(.events(events, .baseline))
        }

        streamReady = true
        let checkpoint = Date()
        recoveryCheckpoint = checkpoint
        onUpdate(.ready(checkpoint))
    }

    private func scheduleRestart() {
        guard !stopped, restartWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            guard !self.stopped, self.process == nil else { return }
            self.launch()
        }
        restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 10, execute: workItem)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let remoteCommand = "$SHELL -lc " + shellQuote(
        "python3 -u -c " + shellQuote(remoteScript)
    )

    private static let remoteScript = #"""
import datetime
import glob
import json
import os
import sqlite3
import sys
import time

def emit(value):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")), flush=True)

def compact(value):
    first = (value or "").splitlines()[0].strip() if value else ""
    first = first or "Codex task"
    return first if len(first) <= 72 else first[:71] + "…"

def project_name(path):
    value = (path or "").replace("\\", "/").rstrip("/")
    return value.rsplit("/", 1)[-1] if value else None

def event_time(payload, root, key):
    value = payload.get(key)
    try:
        number = float(value)
        return number / 1000.0 if number > 100000000000 else number
    except (TypeError, ValueError):
        pass
    value = root.get("timestamp")
    if not isinstance(value, str):
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None

def fallback_source(path):
    session_id = os.path.splitext(os.path.basename(path))[0]
    title = "Codex task"
    project = None
    created = 0.0
    is_subagent = False
    try:
        with open(path, "rb") as handle:
            for _ in range(100):
                line = handle.readline()
                if not line:
                    break
                try:
                    root = json.loads(line)
                except Exception:
                    continue
                if root.get("type") != "session_meta":
                    continue
                payload = root.get("payload") or {}
                session_id = payload.get("id") or payload.get("session_id") or session_id
                project = project_name(payload.get("cwd"))
                source = payload.get("source")
                is_subagent = payload.get("thread_source") == "subagent" or isinstance(source, dict) and "subagent" in source
                break
    except OSError:
        pass
    return None if is_subagent else (path, session_id, title, project, created)

def discover_home():
    candidates = [os.environ.get("CODEX_HOME"), os.path.expanduser("~/.codex")]
    for candidate in candidates:
        if candidate and (os.path.isdir(os.path.join(candidate, "sessions")) or os.path.isfile(os.path.join(candidate, "state_5.sqlite"))):
            return candidate
    return None

def database_sources(home):
    database = next((path for path in (os.path.join(home, "state_5.sqlite"), os.path.join(home, "sqlite", "state_5.sqlite")) if os.path.isfile(path)), None)
    if not database:
        return []
    connection = sqlite3.connect("file:" + database + "?mode=ro", uri=True, timeout=2)
    try:
        connection.execute("PRAGMA query_only=ON")
        columns = {row[1] for row in connection.execute("PRAGMA table_info(threads)")}
        if not {"id", "rollout_path"}.issubset(columns):
            return []
        def selected(column, alias):
            return column + " AS " + alias if column in columns else "'' AS " + alias
        if "created_at_ms" in columns and "created_at" in columns:
            created = "COALESCE(created_at_ms, created_at * 1000)"
        elif "created_at_ms" in columns:
            created = "created_at_ms"
        elif "created_at" in columns:
            created = "created_at * 1000"
        else:
            created = "0"
        source_filter = " AND (thread_source IS NULL OR thread_source <> 'subagent')" if "thread_source" in columns else ""
        query = "SELECT id, rollout_path, " + selected("title", "title") + ", " + selected("preview", "preview") + ", " + selected("cwd", "cwd") + ", " + created + " AS created_ms FROM threads WHERE rollout_path IS NOT NULL AND rollout_path <> ''" + source_filter
        result = []
        for thread_id, path, title, preview, cwd, created_ms in connection.execute(query):
            if not path or not os.path.isfile(path):
                continue
            result.append((path, thread_id, compact(title or preview), project_name(cwd), float(created_ms or 0) / 1000.0))
        return result
    finally:
        connection.close()

def discover_sources(home):
    try:
        rows = database_sources(home)
    except Exception:
        rows = []
    if rows:
        return {row[0]: row[1:] for row in rows}
    paths = []
    for directory in (os.path.join(home, "sessions"), os.path.join(home, "archived_sessions")):
        paths.extend(glob.glob(os.path.join(directory, "**", "*.jsonl"), recursive=True))
    rows = [fallback_source(path) for path in paths]
    return {row[0]: row[1:] for row in rows if row is not None}

def read_file(path, metadata, cursors):
    try:
        stat = os.stat(path)
        cursor = cursors.get(path, {"offset": 0, "inode": stat.st_ino, "partial": b""})
        if stat.st_size < cursor["offset"] or stat.st_ino != cursor["inode"]:
            cursor = {"offset": 0, "inode": stat.st_ino, "partial": b""}
        if stat.st_size == cursor["offset"]:
            cursors[path] = cursor
            return
        with open(path, "rb") as handle:
            handle.seek(cursor["offset"])
            appended = handle.read()
        cursor["offset"] += len(appended)
        data = cursor["partial"] + appended
        lines = data.split(b"\n")
        cursor["partial"] = lines.pop()
        cursors[path] = cursor
    except OSError:
        return

    thread_id, title, project, created = metadata
    for line in lines:
        if b"task_started" not in line and b"task_complete" not in line and b"turn_aborted" not in line:
            continue
        try:
            root = json.loads(line)
        except Exception:
            continue
        if root.get("type") != "event_msg":
            continue
        payload = root.get("payload") or {}
        event_type = payload.get("type")
        if event_type not in ("task_started", "task_complete", "turn_aborted"):
            continue
        turn_id = payload.get("turn_id")
        if not isinstance(turn_id, str) or not turn_id:
            continue
        occurred = event_time(payload, root, "started_at" if event_type == "task_started" else "completed_at")
        if occurred is None or occurred + 1 < created:
            continue
        emit({
            "kind": "event",
            "event": {"task_started": "started", "task_complete": "completed", "turn_aborted": "aborted"}[event_type],
            "turn_id": turn_id,
            "occurred_at": occurred,
            "thread_id": thread_id,
            "title": title,
            "project_name": project,
        })

def main():
    home = discover_home()
    if not home:
        emit({"kind": "error"})
        return 2
    cursors = {}
    sources = discover_sources(home)
    if not sources:
        emit({"kind": "error"})
        return 2
    for path in sorted(sources):
        read_file(path, sources[path], cursors)
    emit({"kind": "ready"})
    tick = 0
    while True:
        time.sleep(1)
        tick += 1
        if tick % 10 == 0:
            sources.update(discover_sources(home))
        for path in sorted(sources):
            read_file(path, sources[path], cursors)

try:
    sys.exit(main())
except KeyboardInterrupt:
    pass
except Exception:
    emit({"kind": "error"})
    sys.exit(2)
"""#
}
