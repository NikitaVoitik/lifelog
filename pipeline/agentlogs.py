#!/usr/bin/env python3
"""Pull prompts and agent replies out of Claude Code and Codex session logs.

Runs on this Mac (imported by lifelog.py) and on remote machines, piped over ssh:
    ssh devbox python3 - SINCE < agentlogs.py
Prints one JSON event per line: {key, ts, tool, account, session, project, title, kind, text}
  kind "prompt" = a message sent to an agent; kind "reply" = the agent's last message of that turn, ts = when it finished.
T3 Code threads are read from T3's own database instead of the Claude/Codex logs underneath them: it knows who sent each
message (you from the app or your phone, another agent, a scheduled task), thread titles and which thread started which.
Those prompts carry {sender, via, from_thread}; kind "thread" lines describe T3 threads; one kind "t3native" line lists the
Claude/Codex session ids that belong to T3 threads (their raw-log events are dropped as duplicates).
Python 3.8+, stdlib only (it runs on whatever python3 the remote box has).
"""
import glob
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone

PROMPT_MAX, REPLY_MAX = 3000, 1500
SKIP_PREFIX = ("<command-", "<local-command", "# AGENTS.md", "<environment_context", "<user_instructions", "<turn_aborted",
               "Caveat:", "<task-notification", "[SYSTEM NOTIFICATION", "<permissions", "<user_shell_command",
               # T3 Code housekeeping sessions/messages, not typed by anyone
               "Generate a title that will help the user recognize", "Update on pull request #",
               "You generate concise git branch names", "You generate concise", "You write concise")


def ts_of(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


MACHINE = re.compile(r"^<[a-z][a-z0-9_\-]*[\s>]")  # harness-injected blocks (<codex_internal_context …>, <environment_context> …)


def clean(text):
    text = re.sub(r"<system-reminder>.*?</system-reminder>", "", text or "", flags=re.S).strip()
    if not text or text.startswith(SKIP_PREFIX) or MACHINE.match(text) \
            or text.startswith("This session is being continued from a previous conversation"):
        return ""
    return text


def blocks_text(content, kinds):
    if isinstance(content, str):
        return content
    return "\n".join(b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") in kinds)


def claude_file(path, account):
    title = sess = cwd = None
    out, turn = [], None

    def close():
        if turn and turn.get("last"):
            out.append({"kind": "reply", "ts": turn["last"], "text": turn.get("reply", "")[:REPLY_MAX], "key": turn["key"] + ":r"})

    with open(path, errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            t = d.get("type")
            if t == "ai-title":
                title = d.get("aiTitle") or title
                continue
            if t not in ("user", "assistant") or d.get("isSidechain") or not d.get("timestamp"):
                continue
            sess, cwd = d.get("sessionId") or sess, d.get("cwd") or cwd
            ts = ts_of(d["timestamp"])
            content = (d.get("message") or {}).get("content")
            if t == "user":
                if d.get("isMeta") or d.get("isCompactSummary") or (isinstance(content, list) and any(
                        isinstance(b, dict) and b.get("type") == "tool_result" for b in content)):
                    continue
                text = clean(blocks_text(content, ("text",)))
                if not text:
                    continue
                close()
                turn = {"key": "claude:%s" % d.get("uuid")}
                out.append({"kind": "prompt", "ts": ts, "text": text[:PROMPT_MAX], "key": turn["key"]})
            elif turn is not None:
                turn["last"] = ts
                text = blocks_text(content, ("text",)).strip()
                if text:
                    turn["reply"] = text
    close()
    for e in out:
        e.update(tool="claude", account=account, session=sess, project=cwd, title=title)
    return out


def codex_file(path, account):
    meta, out = {}, []
    with open(path, errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            t, p = d.get("type"), d.get("payload") or {}
            if t == "session_meta":
                meta = p
                if not isinstance(p.get("source"), str):  # a sub-agent spawned by another session
                    return []
            elif not d.get("timestamp"):
                continue
            elif t == "response_item" and p.get("type") == "message" and p.get("role") == "user":
                text = clean(blocks_text(p.get("content"), ("input_text",)))
                if text:
                    out.append({"kind": "prompt", "ts": ts_of(d["timestamp"]), "text": text[:PROMPT_MAX],
                                "key": "codex:%s:%s" % (meta.get("id"), d["timestamp"])})
            elif t == "event_msg" and p.get("type") == "task_complete":
                out.append({"kind": "reply", "ts": ts_of(d["timestamp"]), "text": (p.get("last_agent_message") or "")[:REPLY_MAX],
                            "key": "codex:%s:%s:r" % (meta.get("id"), p.get("turn_id"))})
    for e in out:
        e.update(tool="codex", account=account, session=meta.get("id"), project=meta.get("cwd"), title=None)
    return out


T3_IMAGE = re.compile(r"!\[[^\]]*\]\(t3-context://[^)]*\)")


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")


def t3_db(path, since):
    """events + thread descriptions from T3 Code's statev2.sqlite, and the native Claude/Codex session ids it drives"""
    db = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=10)
    cut = iso(since - 6 * 3600)
    projects = dict(db.execute("SELECT project_id, title FROM projection_projects"))
    natives = set()
    for (p,) in db.execute("SELECT payload_json FROM orchestration_v2_projection_provider_threads"):
        ref = (json.loads(p).get("nativeThreadRef") or {}).get("nativeId")
        if ref:
            natives.add(ref)
    threads = {}
    for tid, pid, title, created, updated, p in db.execute(
            "SELECT thread_id, project_id, title, created_at, updated_at, payload_json FROM orchestration_v2_projection_threads"):
        threads[tid] = (pid, title, created, updated, p)

    out, want = [], set()

    def base(tid):
        pid, title = threads.get(tid, (None, None))[:2]
        return {"tool": "t3", "session": tid, "project": projects.get(pid), "title": title}

    runs = {}
    for mid, tid, run, role, created, updated, p in db.execute(
            "SELECT message_id, thread_id, run_id, role, created_at, updated_at, payload_json "
            "FROM orchestration_v2_projection_messages WHERE updated_at >= ?", (cut,)):
        d = json.loads(p)
        if role == "assistant":
            r = runs.get(run)
            if r is None or created >= r["created"]:
                runs[run] = {"created": created, "text": d.get("text") or "", "tid": tid,
                             "updated": max(updated, r["updated"] if r else updated)}
            else:
                r["updated"] = max(r["updated"], updated)
            continue
        if role != "user" or d.get("idleCompaction") or d.get("notification") or d.get("delegatedCompletion"):
            continue
        by, via = d.get("createdBy"), d.get("creationSource")
        if d.get("scheduledTaskId"):
            sender = "scheduled"
        elif by == "user" and via in ("web", "mobile"):
            sender = "you"
        elif by == "agent":
            sender = "agent"
        else:
            continue  # T3's own auto-continue messages
        text = clean(T3_IMAGE.sub("[image]", d.get("text") or ""))
        if not text:
            continue
        e = base(tid)
        e.update(kind="prompt", ts=ts_of(created), text=text[:PROMPT_MAX], key="t3:" + mid, sender=sender, via=via,
                 from_thread=d.get("senderThreadId"))
        out.append(e)
        want.update((tid, d.get("senderThreadId")))
    for run, r in runs.items():
        e = base(r["tid"])
        e.update(kind="reply", ts=ts_of(r["updated"]), text=r["text"][:REPLY_MAX], key="t3:%s:r" % run)
        out.append(e)
        want.add(r["tid"])

    for tid, (pid, title, created, updated, p) in threads.items():
        d = json.loads(p)
        if tid not in want and updated < cut and (d.get("lastVisitedAt") or "") < cut:
            continue
        lin = d.get("lineage") or {}
        out.append({"kind": "thread", "key": tid, "project": projects.get(pid), "title": title,
                    "created_by": d.get("createdBy"), "source": d.get("creationSource"), "parent": lin.get("parentThreadId"),
                    "relation": lin.get("relationshipToParent"), "provider": d.get("providerInstanceId"),
                    "model": (d.get("modelSelection") or {}).get("model"), "created": ts_of(created), "updated": ts_of(updated),
                    "settled": ts_of(d["settledAt"]) if d.get("settledAt") else None,
                    "archived": bool(d.get("archivedAt") or d.get("deletedAt")),
                    "branch": d.get("branch"), "worktree": d.get("worktreePath"), "prs": len(d.get("pullRequests") or [])})
    db.close()
    return out, natives


def scan(since):
    """events from every session file touched since `since` (epoch seconds); events up to 6 h older are re-emitted
    so a long turn's final reply replaces its in-progress version"""
    home = os.path.expanduser("~")
    jobs = []
    for d in glob.glob(os.path.join(home, ".claude*", "projects")):
        jobs += [(p, claude_file, os.path.basename(os.path.dirname(d))) for p in glob.glob(os.path.join(d, "**", "*.jsonl"), recursive=True)]
    for d in glob.glob(os.path.join(home, ".codex*", "sessions")):
        jobs += [(p, codex_file, os.path.basename(os.path.dirname(d))) for p in glob.glob(os.path.join(d, "**", "*.jsonl"), recursive=True)]
    out, natives = [], set()
    for path in glob.glob(os.path.join(home, ".t3*", "userdata", "statev2.sqlite")):
        try:
            ev, nat = t3_db(path, since)
            out += ev
            natives |= nat
        except Exception as ex:  # older/newer T3 schema: fall back to the raw Claude/Codex logs for its threads
            sys.stderr.write("agentlogs: %s: %s\n" % (path, ex))
    for path, fn, account in jobs:
        try:
            if os.path.getmtime(path) < since:
                continue
            out += [e for e in fn(path, account) if e["ts"] >= since - 6 * 3600 and e["session"] not in natives]
        except Exception as ex:  # one broken file never stops the scan
            sys.stderr.write("agentlogs: %s: %s\n" % (path, ex))
    if natives:
        out.append({"kind": "t3native", "key": "t3native", "ids": sorted(natives)})
    return out


if __name__ == "__main__":
    for e in scan(float(sys.argv[1]) if len(sys.argv) > 1 else 0):
        print(json.dumps(e, ensure_ascii=False))
