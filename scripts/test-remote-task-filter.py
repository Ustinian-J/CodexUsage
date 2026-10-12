#!/usr/bin/env python3
"""Exercise the embedded remote reader against real SQLite and JSONL fixtures."""
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import time

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift").read_text()
script = source.split('static let remoteScript = """\n', 1)[1].rsplit('\n"""', 1)[0]
# The embedded script uses only escaped backslashes in its Swift string literal.
script = script.replace("\\\\", "\\").split("\ntry:\n    sys.exit(main())", 1)[0]
reader = {}
exec(compile(script, "RemoteCodexTaskMonitor.remoteScript", "exec"), reader)
output = []
reader["emit"] = output.append

with tempfile.TemporaryDirectory(prefix="codexs-task-filter-") as directory:
    home = Path(directory)
    database = sqlite3.connect(home / "state_5.sqlite")
    database.execute("CREATE TABLE threads (id TEXT, rollout_path TEXT, title TEXT, cwd TEXT, created_at INTEGER, thread_source TEXT, source TEXT)")
    internal_source = json.dumps({"subagent": {"other": "guardian"}})
    fixtures = [
        ("user", "user", "vscode"),
        ("scheduled", "automation", "vscode"),
        ("guardian", "guardian_review", "vscode"),
        ("child", "subagent", internal_source),
        ("future-internal", "future-kind", internal_source),
    ]
    for thread, kind, origin in fixtures:
        path = home / (thread + ".jsonl")
        event = {"type": "event_msg", "payload": {"type": "task_started", "turn_id": thread + "-turn", "started_at": time.time()}}
        path.write_text(json.dumps(event) + "\n")
        database.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?)", (thread, str(path), thread, "/fixture", 0, kind, origin))
    database.commit()
    database.close()

    sources, complete = reader["discover_sources"](str(home))
    assert complete and {row[0] for row in sources.values()} == {"user", "scheduled"}, sources
    assert {entry["thread_id"] for entry in output if entry["kind"] == "excluded_thread"} == {"guardian", "child", "future-internal"}
    reader["discover_sources"](str(home))
    assert len(output) == 3, "Repeated discovery must not repeat exclusion messages"
    for path, metadata in sources.items():
        assert reader["read_file"](path, metadata, {})
    assert {entry["thread_id"] for entry in output if entry["kind"] == "event"} == {"user", "scheduled"}

    # The JSONL-only path must use the same policy when no database is available.
    for kind, origin in [("guardian_review", "vscode"), (None, {"subagent": {"other": "guardian"}})]:
        path = home / "fallback.jsonl"
        path.write_text(json.dumps({"type": "session_meta", "payload": {"id": "fallback-internal", "thread_source": kind, "source": origin}}) + "\n")
        row, readable = reader["fallback_source"](str(path))
        assert readable and row is None

    path = home / "liveness.jsonl"
    metadata = ("live-thread", "fixture", None, 0)
    started = {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "live-turn", "started_at": 1000}}
    path.write_text(json.dumps(started) + "\n")
    os.utime(path, (1000, 1000))
    cursors, samples = {}, {}
    assert reader["read_file"](str(path), metadata, cursors)
    live_sources = {str(path): metadata}
    real_probe = reader["open_rollout_paths"]
    reader["open_rollout_paths"] = lambda candidates: (set(), True)
    confirmed = reader["confirmed_tasks"]
    active = [{"thread_id": "live-thread", "turn_id": "live-turn"}]
    assert confirmed(live_sources, cursors, samples, 1040) == active, "One closed sample must not erase task confidence"
    assert confirmed(live_sources, cursors, samples, 1050) == []
    reader["open_rollout_paths"] = lambda candidates: ({str(path)}, True)
    assert confirmed(live_sources, cursors, samples, 1060) == active, "An open quiet rollout must remain confirmed"
    reader["open_rollout_paths"] = lambda candidates: (set(), False)
    assert confirmed(live_sources, cursors, samples, 1070) == [], "An unavailable open-file probe cannot confirm an old task"
    os.utime(path, (1070, 1070))
    assert reader["read_file"](str(path), metadata, cursors)
    assert confirmed(live_sources, cursors, samples, 1071) == active, "Recent activity must recover task confidence"
    reader["open_rollout_paths"] = lambda candidates: (set(), True)
    assert confirmed({}, cursors, samples, 1120) == active
    assert confirmed({}, cursors, samples, 1130) == [], "A removed rollout without an end event must remain unknown"
    with path.open("a") as handle:
        handle.write(json.dumps({"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "live-turn", "completed_at": 1140}}) + "\n")
    assert reader["read_file"](str(path), metadata, cursors)
    assert confirmed(live_sources, cursors, samples, 1150) == [] and not samples, "Only a terminal event clears the tracked turn"
    path.write_text(json.dumps(started) + "\n")
    assert reader["read_file"](str(path), metadata, cursors)
    assert confirmed(live_sources, cursors, samples, time.time()) == active
    path.write_text("")
    assert reader["read_file"](str(path), metadata, cursors)
    assert confirmed(live_sources, cursors, samples, time.time()) == [], "Truncated logs cannot certify previous active turns"
    reader["open_rollout_paths"] = real_probe

# Run the real polling loop on a virtual clock: failed reads must not advance
# recovery checkpoints, and the next complete discovery must restore freshness.
class EndFixture(Exception):
    pass

class Clock:
    tick = 0

    def time(self):
        return 2000 + self.tick

    def sleep(self, seconds):
        self.tick += seconds
        if self.tick > 30:
            raise EndFixture()

clock = Clock()
reader.update(time=clock, discover_home=lambda: "/fixture",
              discover_sources=lambda home: ({"/fixture/log": ("thread", "title", None, 0)}, True),
              read_file=lambda *args: not 10 <= clock.tick < 20,
              confirmed_tasks=lambda *args: [])
output.clear()
try:
    reader["main"]()
except EndFixture:
    pass
assert [item["kind"] for item in output] == ["scan_started", "ready", "error", "healthy", "healthy"], output
assert [item["scan_started_at"] for item in output if item["kind"] == "healthy"] == [2020, 2030]
assert all("confirmed_tasks" in item for item in output if item["kind"] in ("ready", "healthy"))

print("remote task reader regression passed: internal filtering, quiet/open/missing tasks, heartbeat failure and recovery")
