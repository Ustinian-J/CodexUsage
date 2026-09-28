#!/usr/bin/env python3
"""Regression through the real Swift reader, using isolated SQLite, logs and RPC."""
import datetime as dt
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "build/CodexS.app/Contents/MacOS/CodexS"

with tempfile.TemporaryDirectory(prefix="codexusage-integrity-") as tmp:
    base = Path(tmp)
    data = base / ".codex"
    data.mkdir()
    cli = base / "codex"
    cli.write_text(f"#!{sys.executable}\n" + r'''
import json, os, sys, time
if "--version" in sys.argv:
    print("codex-cli 0.0.0-fixture")
    sys.exit(0)
mode = os.environ.get("FIXTURE_MODE", "success")
for raw in sys.stdin:
    message = json.loads(raw)
    ident = message.get("id")
    if not ident: continue
    if ident == 1:
        if mode == "exit": sys.exit(0)
        if mode == "initerror":
            print(json.dumps({"id":1,"error":{"message":"fixture initialize failed"}}), flush=True)
            continue
        if mode == "stderr":
            sys.stderr.write("diagnostic noise\n" * 100000)
            sys.stderr.flush()
        result = {}
        if mode == "initexit":
            print(json.dumps({"id":1,"result":{}}), flush=True)
            sys.exit(0)
    elif ident == 2:
        result = {"account":{"type":"chatgpt","email":"fixture@example.test","planType":"pro"}}
    elif ident == 3:
        if mode in ("error", "initerror"):
            print(json.dumps({"id":3,"error":{"message":"fixture quota failed"}}), flush=True)
            continue
        result = {"rateLimits":{"limitId":"codex","primary":{"usedPercent":11,"windowDurationMins":300,"resetsAt":int(time.time())+3600},"secondary":None}}
    print(json.dumps({"id":ident,"result":result}), flush=True)
''')
    cli.chmod(0o700)
    now = dt.datetime.now(dt.timezone.utc)
    stamp = lambda value: value.isoformat().replace("+00:00", "Z")
    def quota(used, when):
        return {"timestamp":stamp(when), "type":"event_msg", "payload":{"type":"token_count", "rate_limits":{"limit_id":"codex", "primary":{"used_percent":used,"window_minutes":300,"resets_at":int(time.time())+3600},"secondary":None}}}
    def usage(total, when):
        return {"timestamp":stamp(when), "type":"event_msg", "payload":{"type":"token_count", "info":{"total_token_usage":{"input_tokens":total,"total_tokens":total}}}}
    older = data / "older.jsonl"
    newer = data / "newer.jsonl"
    older.write_text(json.dumps(quota(1, now-dt.timedelta(minutes=10)))+"\n")
    newer.write_text("\n".join(json.dumps(event) for event in [
        quota(11, now-dt.timedelta(minutes=1)), usage(1000000,now-dt.timedelta(days=2)), usage(1000100,now),
        {"timestamp":stamp(now),"type":"response_item","payload":{"type":"function_call","name":"exec_command"}}
    ])+"\n")
    db = sqlite3.connect(data/"state_5.sqlite")
    db.execute("CREATE TABLE threads (id TEXT, title TEXT, preview TEXT, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, recency_at INTEGER, created_at INTEGER, archived INTEGER, archived_at INTEGER, model TEXT, rollout_path TEXT)")
    for name, path, updated in [("old",older,int(time.time())+1),("new",newer,int(time.time()))]:
        db.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",(name,name,"fixture",str(base),1000100,updated,updated,updated,0,None,"gpt-5",str(path)))
    db.commit()
    env = dict(os.environ, CODEXUSAGE_HOME_OVERRIDE=str(base), CODEXUSAGE_CACHE_OVERRIDE=str(base/"cache"), CODEX_HOME=str(data), CODEXUSAGE_CODEX_EXECUTABLE=str(cli), CODEXUSAGE_RUNTIME_FILTER="codex")
    def dump(mode="success"):
        started=time.monotonic()
        value=json.loads(subprocess.check_output([str(BINARY),"--dump-json"],env=dict(env,FIXTURE_MODE=mode),timeout=12))
        return value["runtimes"][0]["snapshot"],time.monotonic()-started
    value,_=dump()
    assert value["primary"]["remainingPercent"] == 89 and value["quotaReadSucceeded"]
    assert value["quotaEvidence"]["source"] == "rpc"
    assert value["local"]["todayTokens"] == 100, value["local"]
    assert value["local"]["toolUsages"][0]["callCount"] == 1
    value,_=dump("error")
    assert value["primary"]["remainingPercent"] == 89, "Must compare quota event times, not thread times"
    assert not value["quotaReadSucceeded"] and value["quotaEvidence"]["source"] == "localHistory"
    assert not value["quotaEvidence"]["accountVerified"]
    for mode in ("initerror","exit","initexit","stderr"):
        value,elapsed=dump(mode)
        assert elapsed < 5, (mode,elapsed)
        if mode == "stderr": assert value["quotaReadSucceeded"]
        else: assert not value["quotaReadSucceeded"]
    # Persisted append checkpoints retain cumulative counters and count new events once.
    with newer.open("a") as stream: stream.write(json.dumps(usage(1000150,now))+"\n")
    value,_=dump()
    assert value["local"]["todayTokens"] == 150
    value,_=dump()
    assert value["local"]["todayTokens"] == 150
    # Rotation with the same path, size and mtime must invalidate both cache layers.
    old_stat = newer.stat()
    replacement = data / "replacement.jsonl"
    replacement.write_text(newer.read_text().replace('1000150', '1000160'))
    os.utime(replacement, ns=(old_stat.st_atime_ns, old_stat.st_mtime_ns))
    replacement.replace(newer)
    value,_=dump()
    assert value["local"]["todayTokens"] == 160
    # Missing/unreadable logs must expose coverage independently from event precision.
    newer.unlink()
    value,_=dump()
    assert value["local"]["coverage"]["complete"] is False
    assert value["local"]["todayTokens"] is None
    # Historical records past reset or freshness bounds must not survive failure.
    older.write_text(json.dumps(quota(1,now-dt.timedelta(hours=1)))+"\n")
    value,_=dump("error")
    assert "primary" not in value
print("data integrity integration regressions passed")
