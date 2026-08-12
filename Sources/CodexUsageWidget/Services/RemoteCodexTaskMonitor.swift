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
    let scanStartedAt: Double?

    enum CodingKeys: String, CodingKey {
        case kind
        case event
        case turnID = "turn_id"
        case occurredAt = "occurred_at"
        case threadID = "thread_id"
        case title
        case projectName = "project_name"
        case scanStartedAt = "scan_started_at"
    }

    static func parse(line: Data, host: String) -> CodexTaskEvent? {
        guard let envelope = try? JSONDecoder().decode(Self.self, from: line),
              envelope.kind == "event",
              let eventName = envelope.event,
              let turnID = CodexTaskIdentifier.validated(envelope.turnID),
              let occurredAt = envelope.occurredAt,
              let occurredAtDate = CodexTaskTimestamp.date(unixTime: occurredAt),
              let threadID = CodexTaskIdentifier.validated(envelope.threadID)
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
            occurredAt: occurredAtDate,
            metadata: CodexTaskMetadata(
                threadID: threadID,
                title: compactTaskTitle(envelope.title ?? "Codex 任务"),
                projectName: envelope.projectName.map { String($0.prefix(255)) },
                sourceLabel: host
            ),
            kind: kind
        )
    }

    var scanWatermark: Date? {
        guard kind == "scan_started" || kind == "ready",
              let scanStartedAt,
              let watermark = CodexTaskTimestamp.date(unixTime: scanStartedAt)
        else { return nil }
        return watermark
    }
}

struct RemoteCodexReplayWindow {
    let scanWatermark: Date
    let replayNotBefore: Date
    let baselineEstablished: Bool
    let clockRolledBack: Bool

    init(scanWatermark: Date, recoveryCheckpoint: Date?) {
        self.scanWatermark = scanWatermark
        self.replayNotBefore = CodexTaskReplayPolicy.replayCutoff(
            previous: recoveryCheckpoint,
            scanWatermark: scanWatermark
        )
        self.baselineEstablished = recoveryCheckpoint != nil
        self.clockRolledBack = CodexTaskReplayPolicy.clockRolledBack(
            previous: recoveryCheckpoint,
            scanWatermark: scanWatermark
        )
    }

    func origin(for event: CodexTaskEvent) -> CodexTaskEventOrigin {
        if clockRolledBack, event.kind != .started {
            return .recovery
        }
        return CodexTaskReplayPolicy.origin(
            for: event.occurredAt,
            replayNotBefore: replayNotBefore,
            baselineEstablished: baselineEstablished
        )
    }

    func acceptsReady(watermark: Date) -> Bool {
        watermark == scanWatermark
    }
}

final class RemoteCodexTaskMonitor {
    private let host: String
    private let onUpdate: (RemoteCodexTaskMonitorUpdate) -> Void
    private let queue: DispatchQueue
    private var process: Process?
    private var restartWorkItem: DispatchWorkItem?
    private var lineBuffer = CodexJSONLineBuffer()
    private var replayWindow: RemoteCodexReplayWindow?
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
        queue.async {
            self.stopped = true
            self.restartWorkItem?.cancel()
            self.restartWorkItem = nil
            self.process?.terminationHandler = nil
            self.process?.terminate()
            self.process = nil
            self.lineBuffer.reset()
            self.replayWindow = nil
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
        replayWindow = nil

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
            case "scan_started":
                guard replayWindow == nil,
                      !streamReady,
                      let scanWatermark = envelope.scanWatermark
                else {
                    failProtocol("远程任务主机 \(host) 返回了无效的扫描起点")
                    return
                }
                replayWindow = RemoteCodexReplayWindow(
                    scanWatermark: scanWatermark,
                    recoveryCheckpoint: recoveryCheckpoint
                )

            case "event":
                guard let event = RemoteCodexTaskEnvelope.parse(line: line, host: host) else { continue }
                if streamReady {
                    onUpdate(.events([event], .live))
                } else {
                    guard let replayWindow else {
                        failProtocol("远程任务主机 \(host) 在扫描起点前返回了任务事件")
                        return
                    }
                    let origin = replayWindow.origin(for: event)
                    if CodexTaskReplayPolicy.shouldRetain(
                        event,
                        origin: origin,
                        scanWatermark: replayWindow.scanWatermark,
                        clockRolledBack: replayWindow.clockRolledBack
                    ) {
                        onUpdate(.events([event], origin))
                    }
                }
            case "ready":
                guard let readyWatermark = envelope.scanWatermark,
                      let replayWindow,
                      replayWindow.acceptsReady(watermark: readyWatermark)
                else {
                    failProtocol("远程任务主机 \(host) 返回了不一致的扫描水位线")
                    return
                }
                finishReplay(scanStartedAt: readyWatermark)
            case "error":
                onUpdate(.unavailable("远程任务主机 \(host) 未找到可读的 Codex 会话"))
            default:
                continue
            }
        }
    }

    private func finishReplay(scanStartedAt: Date) {
        streamReady = true
        replayWindow = nil
        recoveryCheckpoint = scanStartedAt
        onUpdate(.ready(scanStartedAt))
    }

    private func failProtocol(_ message: String) {
        onUpdate(.unavailable(message))
        process?.terminate()
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

    static let remoteScript = #"""
import datetime
import glob
import json
import math
import os
import sqlite3
import stat as stat_module
import sys
import time

MAX_LINE_BYTES = 8 * 1024 * 1024
MAX_ID_BYTES = 512

def emit(value):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")), flush=True)

def compact(value):
    first = value.splitlines()[0].strip() if isinstance(value, str) and value else ""
    first = first or "Codex task"
    return first if len(first) <= 72 else first[:71] + "…"

def valid_id(value):
    return isinstance(value, str) and 0 < len(value.encode("utf-8")) <= MAX_ID_BYTES

def project_name(path):
    if not isinstance(path, str):
        return None
    value = path.replace("\\", "/").rstrip("/")
    return value.rsplit("/", 1)[-1] if value else None

def event_time(payload, root, key):
    value = payload.get(key)
    try:
        number = float(value)
        number = number / 1000.0 if number > 100000000000 else number
        if math.isfinite(number) and 0 <= number <= 253402300799:
            return number
    except (TypeError, ValueError):
        pass
    value = root.get("timestamp")
    if not isinstance(value, str):
        return None
    try:
        number = datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        return number if math.isfinite(number) and 0 <= number <= 253402300799 else None
    except (ValueError, OverflowError, OSError):
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
                line = handle.readline(MAX_LINE_BYTES + 1)
                if not line:
                    break
                try:
                    root = json.loads(line)
                except Exception:
                    continue
                if not isinstance(root, dict):
                    continue
                if root.get("type") != "session_meta":
                    continue
                payload = root.get("payload") or {}
                if not isinstance(payload, dict):
                    continue
                candidate_id = payload.get("id") or payload.get("session_id")
                if valid_id(candidate_id):
                    session_id = candidate_id
                project = project_name(payload.get("cwd"))
                source = payload.get("source")
                is_subagent = payload.get("thread_source") == "subagent" or isinstance(source, dict) and "subagent" in source
                break
    except OSError:
        return None, False
    return (None, True) if is_subagent else ((path, session_id, title, project, created), True)

def discover_home():
    candidates = [os.environ.get("CODEX_HOME"), os.path.expanduser("~/.codex")]
    for candidate in candidates:
        if candidate and (os.path.isdir(os.path.join(candidate, "sessions")) or os.path.isfile(os.path.join(candidate, "state_5.sqlite"))):
            return candidate
    return None

def database_sources(home):
    database = next((path for path in (os.path.join(home, "state_5.sqlite"), os.path.join(home, "sqlite", "state_5.sqlite")) if os.path.isfile(path)), None)
    if not database:
        return [], True
    connection = sqlite3.connect("file:" + database + "?mode=ro", uri=True, timeout=2)
    try:
        connection.execute("PRAGMA query_only=ON")
        columns = {row[1] for row in connection.execute("PRAGMA table_info(threads)")}
        if not {"id", "rollout_path"}.issubset(columns):
            return [], False
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
        query = "SELECT id, rollout_path, " + selected("title", "title") + ", " + selected("cwd", "cwd") + ", " + created + " AS created_ms FROM threads WHERE rollout_path IS NOT NULL AND rollout_path <> ''" + source_filter
        result = []
        complete = True
        for thread_id, path, title, cwd, created_ms in connection.execute(query):
            if not valid_id(thread_id) or not isinstance(path, str) or not path:
                continue
            try:
                path_stat = os.stat(path)
            except FileNotFoundError:
                continue
            except OSError:
                complete = False
                continue
            if not stat_module.S_ISREG(path_stat.st_mode):
                continue
            try:
                created = float(created_ms or 0) / 1000.0
            except (TypeError, ValueError):
                created = 0.0
            result.append((path, thread_id, compact(title), project_name(cwd), created))
        return result, complete
    finally:
        connection.close()

def discover_sources(home):
    try:
        rows, database_complete = database_sources(home)
    except Exception:
        return {}, False
    if rows or not database_complete:
        return {row[0]: row[1:] for row in rows}, database_complete
    paths = []
    complete = True
    for directory in (os.path.join(home, "sessions"), os.path.join(home, "archived_sessions")):
        walk_errors = []
        for root, _, files in os.walk(directory, onerror=walk_errors.append):
            paths.extend(os.path.join(root, name) for name in files if name.endswith(".jsonl"))
        if walk_errors:
            complete = False
    sources = {}
    for path in paths:
        row, readable = fallback_source(path)
        if not readable:
            complete = False
        elif row is not None:
            sources[row[0]] = row[1:]
    return sources, complete

def process_line(line, metadata):
    if b"task_started" not in line and b"task_complete" not in line and b"turn_aborted" not in line:
        return
    try:
        root = json.loads(line)
    except Exception:
        return
    if not isinstance(root, dict):
        return
    if root.get("type") != "event_msg":
        return
    payload = root.get("payload") or {}
    if not isinstance(payload, dict):
        return
    event_type = payload.get("type")
    if event_type not in ("task_started", "task_complete", "turn_aborted"):
        return
    turn_id = payload.get("turn_id")
    if not valid_id(turn_id):
        return
    occurred = event_time(payload, root, "started_at" if event_type == "task_started" else "completed_at")
    thread_id, title, project, created = metadata
    if occurred is None or occurred + 1 < created:
        return
    emit({
        "kind": "event",
        "event": {"task_started": "started", "task_complete": "completed", "turn_aborted": "aborted"}[event_type],
        "turn_id": turn_id,
        "occurred_at": occurred,
        "thread_id": thread_id,
        "title": title,
        "project_name": project,
    })

def read_file(path, metadata, cursors):
    try:
        stat = os.stat(path)
        cursor = cursors.get(path, {"offset": 0, "inode": stat.st_ino, "partial": b"", "discarding": False})
        if stat.st_size < cursor["offset"] or stat.st_ino != cursor["inode"]:
            cursor = {"offset": 0, "inode": stat.st_ino, "partial": b"", "discarding": False}
        if stat.st_size == cursor["offset"]:
            cursors[path] = cursor
            return True
        with open(path, "rb") as handle:
            handle.seek(cursor["offset"])
            while True:
                read_limit = MAX_LINE_BYTES + 1 if cursor["discarding"] else MAX_LINE_BYTES + 1 - len(cursor["partial"])
                part = handle.readline(max(1, read_limit))
                if not part:
                    break
                cursor["offset"] += len(part)
                completed = part.endswith(b"\n")
                if cursor["discarding"]:
                    if completed:
                        cursor["discarding"] = False
                    continue
                data = cursor["partial"] + part
                cursor["partial"] = b""
                content_size = len(data) - 1 if completed else len(data)
                if content_size > MAX_LINE_BYTES:
                    cursor["discarding"] = not completed
                    continue
                if completed:
                    process_line(data[:-1], metadata)
                else:
                    cursor["partial"] = data
        cursors[path] = cursor
    except OSError:
        return False
    return True

def main():
    home = discover_home()
    if not home:
        emit({"kind": "error"})
        return 2
    scan_started_at = time.time()
    emit({"kind": "scan_started", "scan_started_at": scan_started_at})
    cursors = {}
    sources, initial_complete = discover_sources(home)
    if not sources:
        emit({"kind": "error"})
        return 2
    for path in sorted(sources):
        if not read_file(path, sources[path], cursors):
            initial_complete = False
    if not initial_complete:
        emit({"kind": "error"})
        return 3
    emit({"kind": "ready", "scan_started_at": scan_started_at})
    tick = 0
    while True:
        time.sleep(1)
        tick += 1
        if tick % 10 == 0:
            discovered, _ = discover_sources(home)
            sources.update(discovered)
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
