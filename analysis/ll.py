#!/usr/bin/env python3
"""ll — the data tool for Lifelog's deep analysis (a Claude coordinator + Sonnet agents, usually in Claude's cloud).

Everything the Mac recorded is in Cloudflare: one raw file per local hour (per-second activity, screen text, transcripts,
events, coding-agent prompts) plus the screenshots. This tool pulls exactly the slice you ask for and renders it.
All times are the person's local time (the tool switches to their timezone itself).

    ll.py status                              what data exists, what's analyzed, which range to do next
    ll.py guide [log|absences|summary]        how to read `log` output + categories / sleep rules / summary style
    ll.py overview DAY [FROM TO]              10-minute rows: activity, app, speech, prompts — to plan chunks
    ll.py log DAY FROM TO [--full]            the time-ordered raw log (what the quick analysis sees); --full = no trimming
    ll.py ocr DAY FROM TO [--grep WORD]       all screen text, every OCR'd frame
    ll.py shot DAY HH:MM:SS                   download the screenshot nearest that second → prints a path to Read
    ll.py transcript DAY FROM TO              everything heard (mic + computer audio), with speakers
    ll.py agents DAY FROM TO [--full]         coding-agent prompts / replies (T3, Claude Code, Codex, Delta) in full
    ll.py search DAY WORDS                    where WORDS appeared that day (screen, speech, prompts, window titles)
    ll.py timeline DAY                        the current timeline (deep where analyzed, quick elsewhere) + summary
    ll.py sleep [--days 7]                    recent nights' sleep, for judging tonight's
    ll.py stitch OUT FILE...                  merge chunk files into one, sorted, and report gaps / overlaps
    ll.py check FILE                          validate a segments file
    ll.py write FILE                          validate + save a segments file as a deep-analysis run (overrides quick)

DAY = YYYY-MM-DD; FROM/TO = HH:MM[:SS] (TO may be 24:00, or smaller than FROM to cross midnight).
Segments file: {"from": "YYYY-MM-DD HH:MM:SS", "to": "...", "segments": [{"start", "end", "category", "activity",
"detail", "app"}], "summaries": [{"day", "text"}], "note": "..."}  — times local, segments contiguous from `from` to `to`.

Env: LIFELOG_URL, LIFELOG_TOKEN (the analyst token), LIFELOG_DEVICE (default mac). --local reads ~/Lifelog/lifelog.db instead.
Stdlib only.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import gzip
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "pipeline"))
import lifelog as L  # noqa: E402  (the same log renderer the laptop uses)

CACHE = Path(os.environ.get("LIFELOG_CACHE", "/tmp/lifelog-cache"))
LOCAL = "--local" in sys.argv
if LOCAL:
    sys.argv.remove("--local")
L.CFG = dict(L.DEFAULTS)
_cfg_file = L.ROOT / "config.json"
_cfg = json.loads(_cfg_file.read_text()) if _cfg_file.exists() else {}
if LOCAL:
    L.CFG.update(_cfg)
URL = (os.environ.get("LIFELOG_URL") or _cfg.get("cloudUrl") or "").rstrip("/")
TOKEN = os.environ.get("LIFELOG_TOKEN") or _cfg.get("analystToken") or ""
DEVICE = os.environ.get("LIFELOG_DEVICE", "mac")


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------- cloud access

def http(path: str, body: dict | None = None, raw: bool = False):
    if not URL:
        die("set LIFELOG_URL and LIFELOG_TOKEN (or use --local on the Mac)")
    headers = {"content-type": "application/json", "user-agent": "lifelog-analyst"}
    if TOKEN:  # without one, an egress proxy that injects the Authorization header (a network secret) must supply it
        headers["authorization"] = f"Bearer {TOKEN}"
    req = urllib.request.Request(URL + path, data=json.dumps(body).encode() if body is not None else None,
                                 method="POST" if body is not None else "GET", headers=headers)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read()
                return (data, dict(r.headers)) if raw else json.loads(data)
        except urllib.error.HTTPError as e:
            if e.code == 401:
                die("the Worker rejected the request (401): LIFELOG_TOKEN is missing or wrong in this environment")
            if e.code < 500 or attempt == 3:
                die(f"{path}: HTTP {e.code} {e.read()[:300].decode(errors='replace')}")
        except urllib.error.URLError as e:
            if attempt == 3:
                die(f"{path}: {e.reason} (is this environment allowed to reach {URL}?)")
        time.sleep(2 * (attempt + 1))


_status = None


def status_data() -> dict:
    global _status
    if _status is None:
        if LOCAL:
            con = local_db()
            _status = {"tz": L.local_tz(), "raw_hours": [], "runs": [dict(r) for r in con.execute("SELECT * FROM deep_runs ORDER BY ts_end DESC LIMIT 30")],
                       "last_deep_segment": None, "now": time.time(), "local": True}
            last = con.execute("SELECT MAX(ts) FROM samples").fetchone()[0]
            _status["last_data"] = last
        else:
            _status = http(f"/api/deep/status?device={DEVICE}")
            _status["last_data"] = max((h["last_ts"] or 0 for h in _status["raw_hours"]), default=None)
        if _status.get("tz"):
            os.environ["TZ"] = _status["tz"]
            time.tzset()
    return _status


_local = None


def local_db() -> sqlite3.Connection:
    global _local
    if _local is None:
        _local = sqlite3.connect(f"file:{L.DB_PATH}?mode=ro", uri=True)
        _local.row_factory = sqlite3.Row
    return _local


def hour_file(h: dict) -> dict:
    CACHE.mkdir(parents=True, exist_ok=True)
    f = CACHE / f"{DEVICE}_{h['day']}_{h['hour']}_{int(h.get('updated') or 0)}.json.gz"
    if not f.exists():
        data, _ = http("/api/raw/" + urllib.parse.quote(h["key"], safe=""), raw=True)
        f.write_bytes(data)
    return json.loads(gzip.decompress(f.read_bytes()))


def db_for(a: float, b: float) -> sqlite3.Connection:
    """a database holding everything recorded in [a, b) — the local one, or an in-memory copy built from the raw hours"""
    if LOCAL:
        return local_db()
    st = status_data()
    con = sqlite3.connect(":memory:")
    con.row_factory = sqlite3.Row
    L.migrate(con)
    for h in st["raw_hours"]:
        if h["ts_end"] > a and h["ts_start"] < b:
            data = hour_file(h)
            for t, tab in data["tables"].items():
                if not tab["cols"]:
                    continue
                have = {r[1] for r in con.execute(f"PRAGMA table_info({t})")}
                idx = [i for i, c in enumerate(tab["cols"]) if c in have]
                cols = [tab["cols"][i] for i in idx]
                con.executemany(f"INSERT OR REPLACE INTO {t}({','.join(cols)}) VALUES({','.join('?' * len(cols))})",
                                [[r[i] for i in idx] for r in tab["rows"]])
    return con


# ---------------------------------------------------------------- time helpers

def at(day: str, hhmm: str) -> float:
    status_data()
    if hhmm == "24:00":
        return L.day_bounds(day)[1]
    parts = [int(x) for x in hhmm.split(":")]
    h, m, s = (parts + [0, 0])[:3]
    return L.day_bounds(day)[0] + h * 3600 + m * 60 + s


def span(day: str, a: str, b: str) -> tuple[float, float]:
    x, y = at(day, a), at(day, b)
    if y <= x:
        y += 86400  # crossed midnight
    return x, y


def stamp(ts: float) -> str:
    return dt.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")


def parse_stamp(s: str) -> float:
    status_data()
    return dt.datetime.strptime(s.strip(), "%Y-%m-%d %H:%M:%S").timestamp()


def hms(ts: float) -> str:
    return L.hms(ts)


# ---------------------------------------------------------------- commands

def cmd_status(_):
    st = status_data()
    print(f"timezone {st.get('tz')}; now {stamp(time.time())}")
    if st.get("last_data"):
        print(f"latest recorded data: {stamp(st['last_data'])}")
    by_day = collections.defaultdict(list)
    for h in st["raw_hours"]:
        by_day[h["day"]].append(h["hour"])
    for d, hs in sorted(by_day.items()):
        print(f"  raw data {d}: hours {', '.join(hs)}")
    runs = sorted(st.get("runs", []), key=lambda r: r["ts_start"])
    if runs:
        print("deep-analysis runs so far:")
        for r in runs[-12:]:
            print(f"  #{r['id']} {stamp(r['ts_start'])} → {stamp(r['ts_end'])} (written {stamp(r['created'])})")
    else:
        print("no deep-analysis runs yet")
    rng = next_range(st)
    if rng:
        a, b = rng
        print(f"\nnext range to analyze: {stamp(a)} → {stamp(b)} ({(b - a) / 3600:.1f} h)"
              + ("  — more than 14 h: do the first 14 h this run" if b - a > 14 * 3600 else ""))
    else:
        print("\nnothing new to analyze")


def next_range(st: dict) -> tuple[float, float] | None:
    """the first stretch of the last LIFELOG_HORIZON_HOURS (30) that no deep run covers yet"""
    last_data = st.get("last_data")
    if not last_data:
        return None
    horizon = max(time.time() - float(os.environ.get("LIFELOG_HORIZON_HOURS", 30)) * 3600,
                  min((h["ts_start"] for h in st["raw_hours"]), default=last_data))
    cov = []
    for r in sorted(st.get("runs", []), key=lambda r: r["ts_start"]):
        if cov and r["ts_start"] <= cov[-1][1]:
            cov[-1][1] = max(cov[-1][1], r["ts_end"])
        else:
            cov.append([r["ts_start"], r["ts_end"]])
    t = horizon
    for a, b in cov:
        if a <= t < b:
            t = b
    if t >= last_data - 60:
        return None
    end = min([a for a, _ in cov if a > t] + [last_data])
    last = st.get("last_deep_segment")
    if last and abs(last["ts_end"] - t) < 2 and last["ts_end"] - last["ts_start"] < 6 * 3600:
        t = last["ts_start"]  # the newest deep segment may have been cut off by the end of the data: redo it
    return t, end


def cmd_guide(a):
    if a.topic == "absences":
        print(L.ABSENCE_PROMPT)
    elif a.topic == "summary":
        print(L.SUMMARY_PROMPT)
    else:
        print(L.SYSTEM_PROMPT)
        print("\nCategories:", ", ".join(L.CATEGORIES))


def cmd_overview(a):
    x, y = span(a.day, a.frm or "00:00", a.to or "24:00")
    con = db_for(x, y)
    thr = L.CFG["idleThresholdSeconds"]
    rows = collections.defaultdict(lambda: {"n": 0, "act": 0, "keys": 0, "scroll": 0, "lock": 0, "mic": 0, "apps": collections.Counter()})
    for s in con.execute("SELECT * FROM samples WHERE ts>=? AND ts<? ORDER BY ts", (x, y)):
        r = rows[int((s["ts"] - x) // 600)]
        r["n"] += 1
        if s["locked"]:
            r["lock"] += 1
        elif (s["idle"] or 0) < thr:
            r["act"] += 1
            r["apps"][(s["app"] or "?") + (" · " + (s["title"] or "")[:40] if s["title"] else "")] += 1
        r["keys"] += s["keys"] or 0
        r["scroll"] += s["scroll"] or 0
        if s["mic_db"] is not None and s["mic_db"] >= L.CFG["micSpeechThresholdDb"]:
            r["mic"] += 1
    prompts = collections.Counter()
    for e in con.execute("SELECT ts, sender FROM agent_events WHERE kind='prompt' AND ts>=? AND ts<?", (x, y)):
        prompts[(int((e["ts"] - x) // 600), e["sender"] or "?")] += 1
    words = collections.Counter()
    for t in con.execute("SELECT ts_start, text FROM transcripts WHERE ts_start>=? AND ts_start<?", (x, y)):
        words[int((t["ts_start"] - x) // 600)] += len((t["text"] or "").split())
    print("from   rec  active locked keys  scroll  mic-s words  prompts(you/agt/other)  main app · window")
    for i in range(int((y - x) // 600) + 1):
        r = rows.get(i)
        if not r:
            continue
        top = r["apps"].most_common(1)[0][0] if r["apps"] else "—"
        p = f"{prompts[(i, 'you')]}/{prompts[(i, 'agent')] + prompts[(i, 'scheduled')]}/{prompts[(i, '?')]}"
        print(f"{hms(x + i * 600)[:5]}  {r['n']:>4} {r['act']:>6} {r['lock']:>6} {r['keys']:>5} {r['scroll']:>7} {r['mic']:>5} {words[i]:>5}  {p:>13}  {top[:70]}")


def cmd_log(a):
    x, y = span(a.day, a.frm, a.to)
    text, n = L.build_log(db_for(x, y), x, y, max_chars=10 ** 9 if a.full else 110_000)
    print(text if n else "(no data recorded in this range)")
    print(f"\n[{n} seconds of samples, {len(text):,} chars]", file=sys.stderr)


def cmd_ocr(a):
    x, y = span(a.day, a.frm, a.to)
    con, prev = db_for(x, y), None
    for s in con.execute("SELECT ts, app, title, ocr FROM screenshots WHERE ts>=? AND ts<? AND ocr IS NOT NULL ORDER BY ts", (x, y)):
        text = " | ".join(L.norm_lines(s["ocr"]))
        if not text or text == prev or (a.grep and a.grep.lower() not in text.lower()):
            continue
        prev = text
        print(f"[{hms(s['ts'])}] {s['app']} — {s['title'] or ''}\n  {text}\n")


def cmd_shot(a):
    ts = at(a.day, a.time)
    out = Path(a.out or "/tmp/lifelog-shots")
    out.mkdir(parents=True, exist_ok=True)
    if LOCAL:
        r = local_db().execute("SELECT * FROM screenshots WHERE ts BETWEEN ? AND ? ORDER BY ABS(ts-?) LIMIT 1", (ts - 120, ts + 120, ts)).fetchone()
        if not r:
            die("no screenshot within 2 minutes")
        src = L.ROOT / r["path"]
        if not src.exists():
            die(f"{src.name} is no longer on this Mac (only in R2) — use the cloud mode")
        dest = out / f"{a.day}_{hms(r['ts']).replace(':', '')}.jpg"
        dest.write_bytes(src.read_bytes())
        print(f"{dest}  (taken {hms(r['ts'])}, {r['app']} — {r['title'] or ''})")
        return
    data, headers = http(f"/api/shot?device={DEVICE}&day={a.day}&ts={ts}", raw=True)
    h = {k.lower(): v for k, v in headers.items()}
    real = float(h.get("x-shot-ts", ts))
    dest = out / f"{a.day}_{hms(real).replace(':', '')}.jpg"
    dest.write_bytes(data)
    print(f"{dest}  (taken {hms(real)}, {urllib.parse.unquote(h.get('x-shot-app', ''))} — {urllib.parse.unquote(h.get('x-shot-title', ''))})")


def cmd_transcript(a):
    x, y = span(a.day, a.frm, a.to)
    con = db_for(x, y)
    for t in con.execute("SELECT t.*, v.name AS vname FROM transcripts t LEFT JOIN voices v ON v.id=t.speaker_id "
                         "WHERE t.ts_start>=? AND t.ts_start<? ORDER BY t.ts_start", (x, y)):
        who = ("MIC" if t["source"] == "mic" else "COMPUTER AUDIO") + (f" · {L.voice_label(t['vname'], t['speaker_id'])}" if t["speaker_id"] else "")
        print(f"[{hms(t['ts_start'])}–{hms(t['ts_end'])} {who}] {t['text']}")


def cmd_agents(a):
    x, y = span(a.day, a.frm, a.to)
    con = db_for(x, y)
    th = {r["id"]: r for r in con.execute("SELECT * FROM t3_threads")}
    for e in con.execute("SELECT * FROM agent_events WHERE ts>=? AND ts<? ORDER BY ts", (x, y)):
        who = {"you": "PROMPT FROM THE USER" + (" (phone)" if e["via"] == "mobile" else ""), "agent": "PROMPT FROM ANOTHER AGENT",
               "scheduled": "SCHEDULED PROMPT"}.get(e["sender"], "PROMPT (sender unknown)") if e["kind"] == "prompt" else "AGENT REPLY"
        src = th.get(e["from_thread"]) if e["from_thread"] else None
        text = e["text"] or ""
        if not a.full:
            text = " ".join(text.split())[:400]
        print(f"[{hms(e['ts'])} {who} · {L.agent_label(e)}" + (f" · from “{src['title']}”" if src else "") + f"]\n{text}\n")


def cmd_search(a):
    x, y = L.day_bounds(a.day)
    status_data()
    con, w = db_for(x, y), " ".join(a.words).lower()
    hits = []
    for s in con.execute("SELECT ts, app, title, url, ocr FROM screenshots WHERE ts>=? AND ts<? ORDER BY ts", (x, y)):
        blob = " ".join(filter(None, (s["title"], s["url"], s["ocr"])))
        i = blob.lower().find(w)
        if i >= 0:
            hits.append((s["ts"], "screen", f"{s['app']}: …{' '.join(blob[max(0, i - 60):i + 100].split())}…"))
    for t in con.execute("SELECT ts_start, text FROM transcripts WHERE ts_start>=? AND ts_start<?", (x, y)):
        if w in (t["text"] or "").lower():
            hits.append((t["ts_start"], "heard", t["text"][:160]))
    for e in con.execute("SELECT ts, kind, title, text FROM agent_events WHERE ts>=? AND ts<?", (x, y)):
        if w in ((e["text"] or "") + " " + (e["title"] or "")).lower():
            hits.append((e["ts"], f"agent {e['kind']}", f"{e['title'] or ''}: {' '.join((e['text'] or '').split())[:140]}"))
    last = {}
    for ts, kind, text in sorted(hits):
        if ts - last.get(kind, -1e9) < 30:  # the same thing on screen for a while: one hit per 30 s
            continue
        last[kind] = ts
        print(f"{hms(ts)}  [{kind}] {text}")
    if not hits:
        print("no matches")


def timeline(day: str) -> tuple[list[dict], str]:
    if LOCAL:
        con = sqlite3.connect(L.DB_PATH)
        con.row_factory = sqlite3.Row
        d = L.day_data(con, day)
    else:
        d = http(f"/api/day/{day}?device={DEVICE}")
    return d.get("segments", []), d.get("summary", "")


def cmd_timeline(a):
    status_data()
    segs, summary = timeline(a.day)
    for g in segs:
        print(f"{hms(g['s'])}–{hms(g['e'])} [{g['c']}]{' (deep)' if g.get('deep') else ''} {g['activity']} — {g.get('detail') or ''}")
    if summary:
        print("\nSummary:\n" + summary)


def cmd_sleep(a):
    status_data()
    today = dt.date.today()
    for i in range(a.days, 0, -1):
        day = (today - dt.timedelta(days=i)).isoformat()
        segs, _ = timeline(day)
        sl = [g for g in segs if g["c"] == "sleep"]
        print(f"{day}: " + (", ".join(f"{hms(g['s'])[:5]}–{hms(g['e'])[:5]}" for g in sl) if sl else "no sleep segment"))


def load_file(path: str) -> dict:
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError) as e:
        die(f"{path}: {e}")


def problems(doc: dict, whole: bool = True) -> list[str]:
    out = []
    try:
        a, b = parse_stamp(doc["from"]), parse_stamp(doc["to"])
    except (KeyError, ValueError) as e:
        return [f"bad from/to: {e}"]
    prev = a
    cats = set(L.CATEGORIES)
    for i, g in enumerate(doc.get("segments", [])):
        try:
            s, e = parse_stamp(g["start"]), parse_stamp(g["end"])
        except (KeyError, ValueError) as ex:
            out.append(f"segment {i}: bad start/end ({ex})")
            continue
        if g.get("category") not in cats:
            out.append(f"segment {i} ({g.get('start')}): category {g.get('category')!r} is not one of {sorted(cats)}")
        if not g.get("activity"):
            out.append(f"segment {i} ({g['start']}): empty activity")
        if e <= s:
            out.append(f"segment {i} ({g['start']}): ends before it starts")
        if s < a - 1 or e > b + 1:
            out.append(f"segment {i} ({g['start']}–{g['end']}): outside {doc['from']} → {doc['to']}")
        if s > prev + 1:
            out.append(f"gap {stamp(prev)} → {g['start']} ({s - prev:.0f}s uncovered)")
        elif s < prev - 1:
            out.append(f"overlap: segment {i} starts {g['start']} but the previous one ends {stamp(prev)}")
        prev = max(prev, e)
    if whole and prev < b - 1:
        out.append(f"not covered at the end: {stamp(prev)} → {doc['to']}")
    if not doc.get("segments"):
        out.append("no segments")
    return out


def cmd_check(a):
    doc = load_file(a.file)
    p = problems(doc)
    print("\n".join(p) if p else f"ok: {len(doc['segments'])} segments, {doc['from']} → {doc['to']}")
    sys.exit(1 if p else 0)


def cmd_stitch(a):
    docs = [load_file(f) for f in a.files]
    segs = sorted((g for d in docs for g in d.get("segments", [])), key=lambda g: g.get("start", ""))
    out = {"from": min(d["from"] for d in docs), "to": max(d["to"] for d in docs), "segments": segs}
    Path(a.out).write_text(json.dumps(out, ensure_ascii=False, indent=1))
    p = problems(out)
    print(f"wrote {a.out}: {len(segs)} segments, {out['from']} → {out['to']}")
    print("problems to fix before writing:\n  " + "\n  ".join(p) if p else "no gaps or overlaps")


def cmd_write(a):
    doc = load_file(a.file)
    p = problems(doc)
    if p:
        die("fix these first:\n  " + "\n  ".join(p))
    if LOCAL:
        die("write goes to the cloud; run without --local")
    body = {"device": DEVICE, "ts_start": parse_stamp(doc["from"]), "ts_end": parse_stamp(doc["to"]), "note": doc.get("note", ""),
            "segments": [{"s": parse_stamp(g["start"]), "e": parse_stamp(g["end"]), "c": g["category"], "activity": g["activity"],
                          "detail": g.get("detail", ""), "app": g.get("app", "")} for g in doc["segments"]],
            "summaries": doc.get("summaries", [])}
    r = http("/api/deep/ingest", body)
    print(f"saved deep run #{r['run']}: {r['segments']} segments, {doc['from']} → {doc['to']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    p = sub.add_parser("guide"); p.add_argument("topic", nargs="?", choices=["log", "absences", "summary"], default="log")
    p = sub.add_parser("overview"); p.add_argument("day"); p.add_argument("frm", nargs="?"); p.add_argument("to", nargs="?")
    for name in ("log", "ocr", "transcript", "agents"):
        p = sub.add_parser(name); p.add_argument("day"); p.add_argument("frm"); p.add_argument("to")
        if name in ("log", "agents"):
            p.add_argument("--full", action="store_true")
        if name == "ocr":
            p.add_argument("--grep")
    p = sub.add_parser("shot"); p.add_argument("day"); p.add_argument("time"); p.add_argument("--out")
    p = sub.add_parser("search"); p.add_argument("day"); p.add_argument("words", nargs="+")
    p = sub.add_parser("timeline"); p.add_argument("day")
    p = sub.add_parser("sleep"); p.add_argument("--days", type=int, default=7)
    p = sub.add_parser("stitch"); p.add_argument("out"); p.add_argument("files", nargs="+")
    p = sub.add_parser("check"); p.add_argument("file")
    p = sub.add_parser("write"); p.add_argument("file")
    a = ap.parse_args()
    globals()["cmd_" + a.cmd](a)


if __name__ == "__main__":
    main()
