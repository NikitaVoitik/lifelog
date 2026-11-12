#!/usr/bin/env python3
"""lifelog — turns the recorder's raw firehose into "where did my time go".

    lifelog status                     what's being recorded, disk usage
    lifelog process [--day D]          transcribe + analyze + summarize + report (run by launchd every 30 min)
    lifelog transcribe                 run whisper on new audio chunks that contain sound
    lifelog analyze [--day D] [--force]  ask Claude to reconstruct the timeline, hour by hour
    lifelog summarize [--day D]        daily narrative
    lifelog report [--day D] [--open]  build ~/Lifelog/reports/D.html
    lifelog search "words"             full-text search over everything you saw and heard
    lifelog dump --from HH:MM --to HH:MM [--day D]   print the raw log Claude sees (debugging)
    lifelog agents [--day D] [--threads]  your AI-agent prompts (T3, Claude Code, Codex, Delta); --threads = per-thread stats
    lifelog prune --keep-days N        delete screenshots/audio older than N days (text stays)
    lifelog sync [--all-days]          upload media bundles to R2 (wrangler) + timeline to the Worker; frees old local media
    lifelog restore --day D            pull a day's screenshots/audio back from R2
    lifelog enroll [--file F] [--add]  teach it your voice so transcripts say "Me"; --add a second print (e.g. phone audio)
    lifelog voices [name ID NAME | merge ID INTO]   who's been talking; name people once, it remembers

Stdlib only. Needs: ffmpeg, whisper-cli (brew install whisper-cpp), claude CLI.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import glob
import html
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(os.environ.get("LIFELOG_DIR", "~/Lifelog")).expanduser()
DB_PATH = ROOT / "lifelog.db"

DEFAULTS = {
    "analysisModel": "sonnet",
    "summaryModel": "sonnet",
    "whisperModel": str(ROOT / "models/ggml-large-v3-turbo-q5_0.bin"),
    "vadModel": str(ROOT / "models/ggml-silero-v5.1.2.bin"),
    "transcribeLanguage": "auto",       # whisper only
    "transcriber": "fluidaudio",        # "fluidaudio" (Parakeet Ultra + Nemotron 3 speakers, on-device) or "whisper"
    "asrBinary": str(ROOT / "bin/lifelog-asr"),
    "diarize": True,
    "voiceMatchThreshold": 0.72,        # CAM++ cosine: same voice ≈ 0.85 (even on the phone), different people ≈ 0.3–0.6
    "voiceMatchThresholdPhone": 0.72,   # same, for the iPhone's far-field mic
    "voiceMergeThreshold": 0.80,        # folding a whole unnamed voice into a named one rewrites its history: higher bar
    "voiceNamedPreference": 0.03,       # a named voice beats a closer unnamed one only when it's this close
    "micSpeechThresholdDb": -50,
    "sysSoundThresholdDb": -60,
    "idleThresholdSeconds": 60,
    "agentLogHosts": [],                # ssh hosts whose Claude Code / Codex logs to read too, e.g. ["devbox"]
    "agentLogDelta": True,              # read Delta threads via the `delta` CLI
    "agentLogBackfillDays": 2,          # how far back the first scan of a source goes
    "absenceMinMinutes": 45,            # no-interaction stretches this long get a second look from Claude (sleep? nap? out?)
    "claudeConfigDir": "",     # which Claude Code login runs the analysis: "" = whatever the environment says,
                               # "default" = the root login (~/.claude.json), or a config dir like "~/.claude-work"
    "aboutMe": "",  # optional: who you are / what your projects are called — helps Claude label things
    # --- cloud (Cloudflare R2 + D1 + Worker) ---
    "deviceId": "mac",
    "r2Bucket": "lifelog-media",
    "cloudUrl": "",            # https://lifelog.<you>.workers.dev  (set by cloud/deploy.sh)
    "cloudToken": "",          # API token (set by cloud/deploy.sh)
    "localMediaKeepDays": 3,   # screenshots/audio stay on disk this long, then only in R2 (once uploaded)
    "syncOnExpensiveNetwork": False,  # don't upload gigabytes over a phone hotspot
    "bundleMaxBytes": 200_000_000,  # capped at ~94 MB while uploading through the Worker (see bundle_limit)
    "dbBackupEveryDays": 1,
    "dbBackupsToKeep": 7,
    "wranglerLocal": "",       # testing only: persist dir for `wrangler --local`
    "phoneDeviceId": "iphone", # the iPhone app's device id in the cloud ("" = don't pull phone data)
}

CATEGORIES = [
    "coding & AI agents",
    "communication",
    "voice & calls",
    "social media",
    "entertainment",
    "browsing & research",
    "writing & planning",
    "on phone",
    "idle at desk",
    "away",
    "sleep",
    "other",
]

SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS samples(
  ts INTEGER PRIMARY KEY, app TEXT, bundle TEXT, title TEXT, url TEXT,
  idle REAL, keys INTEGER, clicks INTEGER, scroll INTEGER, mouse INTEGER,
  mic_db REAL, sys_db REAL, locked INTEGER);
CREATE TABLE IF NOT EXISTS screenshots(
  id INTEGER PRIMARY KEY, ts REAL, path TEXT, app TEXT, bundle TEXT, title TEXT, url TEXT,
  w INTEGER, h INTEGER, ocr TEXT);
CREATE INDEX IF NOT EXISTS screenshots_ts ON screenshots(ts);
CREATE VIRTUAL TABLE IF NOT EXISTS ocr_fts USING fts5(text);
CREATE TABLE IF NOT EXISTS audio_chunks(
  id INTEGER PRIMARY KEY, source TEXT, ts_start REAL, ts_end REAL, path TEXT,
  peak_db REAL, transcribed INTEGER DEFAULT 0);
CREATE INDEX IF NOT EXISTS audio_chunks_ts ON audio_chunks(ts_start);
CREATE TABLE IF NOT EXISTS events(ts REAL, kind TEXT, detail TEXT);
CREATE TABLE IF NOT EXISTS transcripts(
  id INTEGER PRIMARY KEY, chunk_id INTEGER, source TEXT, ts_start REAL, ts_end REAL, text TEXT, lang TEXT);
CREATE INDEX IF NOT EXISTS transcripts_ts ON transcripts(ts_start);
CREATE INDEX IF NOT EXISTS transcripts_chunk ON transcripts(chunk_id);
CREATE INDEX IF NOT EXISTS transcripts_speaker ON transcripts(speaker_id);
CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(text);
CREATE TABLE IF NOT EXISTS segments(
  id INTEGER PRIMARY KEY, ts_start REAL, ts_end REAL, category TEXT, activity TEXT, detail TEXT, app TEXT);
CREATE INDEX IF NOT EXISTS segments_ts ON segments(ts_start);
CREATE TABLE IF NOT EXISTS analyzed_windows(ts_start REAL PRIMARY KEY, ts_end REAL, partial INTEGER, created REAL);
CREATE TABLE IF NOT EXISTS daily_summaries(day TEXT PRIMARY KEY, text TEXT, created REAL);
CREATE TABLE IF NOT EXISTS uploads(key TEXT PRIMARY KEY, kind TEXT, day TEXT, slot TEXT, bytes INTEGER, files TEXT,
  uploaded REAL, registered INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS cloud_pushes(day TEXT PRIMARY KEY, hash TEXT, pushed REAL);
CREATE TABLE IF NOT EXISTS absence_labels(ts_start REAL PRIMARY KEY, ts_end REAL, kind TEXT, s REAL, e REAL, activity TEXT,
  detail TEXT, created REAL);
CREATE TABLE IF NOT EXISTS agent_events(key TEXT PRIMARY KEY, ts REAL, host TEXT, tool TEXT, account TEXT, session TEXT,
  project TEXT, title TEXT, kind TEXT, text TEXT);
CREATE INDEX IF NOT EXISTS agent_events_ts ON agent_events(ts);
CREATE TABLE IF NOT EXISTS agent_sync(source TEXT PRIMARY KEY, last REAL);
CREATE TABLE IF NOT EXISTS t3_threads(id TEXT PRIMARY KEY, host TEXT, project TEXT, title TEXT, created_by TEXT, source TEXT,
  parent TEXT, relation TEXT, provider TEXT, model TEXT, created REAL, updated REAL, settled REAL, archived INTEGER,
  branch TEXT, worktree TEXT, prs INTEGER);
CREATE TABLE IF NOT EXISTS raw_uploads(day TEXT, hour TEXT, key TEXT, hash TEXT, bytes INTEGER, uploaded REAL,
  PRIMARY KEY(day, hour));
-- deep analysis done in the cloud (a Claude coordinator + Sonnet agents reading the raw hours): it overrides the quick
-- local timeline inside each run's range
CREATE TABLE IF NOT EXISTS deep_runs(id INTEGER PRIMARY KEY, ts_start REAL, ts_end REAL, created REAL, note TEXT);
CREATE TABLE IF NOT EXISTS deep_segments(ts_start REAL PRIMARY KEY, ts_end REAL, category TEXT, activity TEXT, detail TEXT,
  app TEXT, run_id INTEGER);
CREATE TABLE IF NOT EXISTS deep_summaries(day TEXT PRIMARY KEY, text TEXT, updated REAL);
-- the iPhone app's facts (screen on/off/lock, calls, motion, steps, places, battery, sound levels, audio chunks), pulled
-- from the cloud; data is JSON
CREATE TABLE IF NOT EXISTS phone_events(id TEXT PRIMARY KEY, seq INTEGER, ts REAL, kind TEXT, data TEXT, received REAL);
CREATE INDEX IF NOT EXISTS phone_events_ts ON phone_events(ts);
CREATE TABLE IF NOT EXISTS voices(id INTEGER PRIMARY KEY, name TEXT, embedding TEXT, n INTEGER, seconds REAL,
  first_heard REAL, last_heard REAL);
"""


# ---------------------------------------------------------------- basics

def load_config() -> dict:
    path = ROOT / "config.json"
    cfg = {}
    if path.exists():
        try:
            cfg = json.loads(path.read_text())
        except json.JSONDecodeError:
            print("warning: config.json is not valid JSON, using defaults", file=sys.stderr)
    missing = {k: v for k, v in DEFAULTS.items() if k not in cfg}
    if missing and path.exists():
        cfg.update(missing)
        path.write_text(json.dumps(cfg, indent=2, sort_keys=True))
    return {**DEFAULTS, **cfg}


CFG: dict = {}


def connect() -> sqlite3.Connection:
    ROOT.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(DB_PATH, timeout=30)
    con.row_factory = sqlite3.Row
    migrate(con)
    return con


def migrate(con: sqlite3.Connection) -> None:
    """create tables / add columns newer versions need (also used by the cloud analysis tool's in-memory copies)"""
    con.executescript(SCHEMA)
    cols = {r[1] for r in con.execute("PRAGMA table_info(transcripts)")}
    if "speaker_id" not in cols:
        con.execute("ALTER TABLE transcripts ADD COLUMN speaker_id INTEGER")
    cols = {r[1] for r in con.execute("PRAGMA table_info(samples)")}
    if "synth" not in cols:  # input events another process injected (agents driving the cursor); not the user
        con.execute("ALTER TABLE samples ADD COLUMN synth INTEGER")
    cols = {r[1] for r in con.execute("PRAGMA table_info(agent_events)")}
    for c in ("sender", "via", "from_thread"):  # T3 knows who sent each prompt: "you" / "agent" / "scheduled"
        if c not in cols:
            con.execute(f"ALTER TABLE agent_events ADD COLUMN {c} TEXT")


def day_bounds(day: str) -> tuple[float, float]:
    d = dt.datetime.strptime(day, "%Y-%m-%d")
    return d.timestamp(), (d + dt.timedelta(days=1)).timestamp()


def hms(ts: float) -> str:
    return dt.datetime.fromtimestamp(ts).strftime("%H:%M:%S")


def today() -> str:
    return dt.date.today().isoformat()


def fmt_dur(sec: float) -> str:
    sec = int(round(sec))
    h, m = divmod(sec // 60, 60)
    if h:
        return f"{h}h {m:02d}m"
    if m:
        return f"{m}m"
    return f"{sec}s"


def which(name: str) -> str | None:
    extra = ["/opt/homebrew/bin", "/usr/local/bin", str(Path.home() / ".local/bin")]
    return shutil.which(name) or next((str(Path(p) / name) for p in extra if (Path(p) / name).exists()), None)


# ---------------------------------------------------------------- transcription

HALLUCINATIONS = re.compile(
    r"^\W*(thank you\.?|thanks for watching!?|you|bye\.?|\[blank_audio\]|\(.*?\)|\[.*?\]|"
    r"субтитры.*|продолжение следует.*|редактор субтитров.*|ご視聴ありがとうございました.*)\W*$",
    re.I,
)


def close_orphan_chunks(con) -> int:
    """A chunk the recorder never closed (it was killed or crashed mid-chunk) keeps ts_end NULL forever. That used to
    block its hour's audio upload, and so the freeing of that whole day's media (tens of GB), and to make every later
    hour "wait for audio to be transcribed". Chunks are at most a few minutes long, so one still open after 30 min is
    an orphan: end it when its file was last written (often unreadable — no moov atom — and then marked failed)."""
    rows = con.execute("SELECT id, ts_start, path FROM audio_chunks WHERE ts_end IS NULL AND ts_start<?",
                       (time.time() - 1800,)).fetchall()
    for r in rows:
        f = ROOT / r["path"]
        end = min(f.stat().st_mtime, r["ts_start"] + 3600) if f.exists() else r["ts_start"]
        con.execute("UPDATE audio_chunks SET ts_end=? WHERE id=?", (max(end, r["ts_start"]), r["id"]))
    if rows:
        con.commit()
        print(f"  closed {len(rows)} audio chunk(s) the recorder never finished")
    return len(rows)


def pending_chunks(con, limit: int | None) -> list:
    """closed chunks not transcribed yet; silent / missing ones are marked and skipped here"""
    out = []
    for r in con.execute("SELECT * FROM audio_chunks WHERE transcribed=0 AND ts_end IS NOT NULL ORDER BY ts_start").fetchall():
        threshold = CFG["micSpeechThresholdDb"] if r["source"] in ("mic", "phone") else CFG["sysSoundThresholdDb"]
        if not (ROOT / r["path"]).exists():
            con.execute("UPDATE audio_chunks SET transcribed=3 WHERE id=?", (r["id"],))
        elif r["peak_db"] is not None and r["peak_db"] < threshold:
            con.execute("UPDATE audio_chunks SET transcribed=2 WHERE id=?", (r["id"],))  # silent
        else:
            out.append(r)
    con.commit()
    return out[:limit] if limit else out


def transcribe(con: sqlite3.Connection, limit: int | None = None) -> int:
    close_orphan_chunks(con)
    rows = pending_chunks(con, limit)
    if not rows:
        return 0
    asr = Path(CFG["asrBinary"]).expanduser()
    if CFG["transcriber"] == "fluidaudio" and asr.exists():
        try:
            n = transcribe_fluid(con, rows, asr)
            consolidate_voices(con)
            return n
        except Exception as e:  # never lose a run: fall back to whisper
            print(f"  lifelog-asr failed ({e}); falling back to whisper", file=sys.stderr)
            rows = pending_chunks(con, limit)
    elif CFG["transcriber"] == "fluidaudio":
        print(f"  {asr} not found (run install.sh) — using whisper", file=sys.stderr)
    return transcribe_whisper(con, rows)


# ---------------------------------------------------------------- voices (who is talking)

def _norm(v: list[float]) -> list[float]:
    n = sum(x * x for x in v) ** 0.5 or 1.0
    return [x / n for x in v]


def _cos(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b))


def voice_label(row_name, vid) -> str:
    if row_name:
        return row_name
    return f"voice #{vid}" if vid else ""


def _person(vid: int, name: str | None):
    """one person can have several named fingerprints (laptop mic, phone); unnamed voices are each their own person"""
    return ("name", name.strip().lower()) if name else ("id", vid)


def assign_voices(con, speakers: list[dict], source: str) -> dict[int, int]:
    """one recording's diarizer slots → persistent voice ids.

    - The diarizer already decided the slots are different people, so no two slots get the same person
      (best matches first). Without this, a whole room collapsed into whichever voice was closest — usually "Me".
    - Named voices are enrolled fingerprints and never move; only `lifelog enroll` changes them. A running centroid
      on "Me" absorbed everyone it was matched to and drifted until it matched nearly any voice.
    - Unnamed voices keep a running centroid so they can settle; a slot that matches nothing starts a new one."""
    thr = CFG["voiceMatchThresholdPhone"] if source == "phone" else CFG["voiceMatchThreshold"]
    slots = [(s["slot"], _norm(s["embedding"]), s.get("seconds", 0) or 0) for s in speakers if s.get("embedding")]
    if not slots:
        return {}
    voices = []
    for v in con.execute("SELECT id, name, embedding, n FROM voices"):
        # your own voice isn't played back through the speakers, so computer audio is never "Me"
        if source == "sys" and (v["name"] or "").strip().lower() == "me":
            continue
        voices.append((v["id"], v["name"], v["n"], json.loads(v["embedding"])))
    cands = []
    for slot, emb, _ in slots:
        for vid, name, _, ve in voices:
            sim = _cos(emb, ve)
            if sim >= thr:
                # a named voice beats a slightly closer unnamed cluster (an early cluster of your own voice
                # shouldn't out-compete your enrollment forever), but not a clearly closer one
                cands.append((sim + (CFG["voiceNamedPreference"] if name else 0.0), slot, vid))
    cands.sort(reverse=True)
    by_id = {v[0]: v for v in voices}
    out: dict[int, int] = {}
    taken: set = set()
    for _, slot, vid in cands:
        who = _person(vid, by_id[vid][1])
        if slot in out or who in taken:
            continue
        out[slot] = vid
        taken.add(who)
    now = time.time()
    for slot, emb, seconds in slots:
        vid = out.get(slot)
        if vid is None:
            out[slot] = con.execute("INSERT INTO voices(name, embedding, n, seconds, first_heard, last_heard) VALUES(NULL,?,1,?,?,?)",
                                    (json.dumps([round(x, 5) for x in emb]), seconds, now, now)).lastrowid
            continue
        _, name, n, old = by_id[vid]
        if name:
            con.execute("UPDATE voices SET n=n+1, seconds=seconds+?, last_heard=? WHERE id=?", (seconds, now, vid))
        else:
            n = min(n, 50)  # running centroid, capped so it can still adapt
            cen = _norm([(o * n + e) / (n + 1) for o, e in zip(old, emb)])
            con.execute("UPDATE voices SET embedding=?, n=n+1, seconds=seconds+?, last_heard=? WHERE id=?",
                        (json.dumps([round(x, 5) for x in cen]), seconds, now, vid))
    return out


def transcribe_fluid(con, rows, binary: Path) -> int:
    """Parakeet Ultra + Nemotron 3 diarization + CAM++ fingerprints via lifelog-asr (one process for the whole batch)."""
    args = [str(binary), "batch"] + ([] if CFG["diarize"] else ["--no-speakers"])
    proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    done = 0
    try:
        for r in rows:
            t0 = time.time()
            proc.stdin.write(json.dumps({"id": r["id"], "path": str(ROOT / r["path"])}) + "\n")
            proc.stdin.flush()
            line = proc.stdout.readline()
            if not line:
                err = proc.stderr.read()[-500:] if proc.poll() is not None else ""
                raise RuntimeError(f"lifelog-asr exited: {err.strip()}")
            res = json.loads(line)
            if not res.get("ok"):
                print(f"  {r['source']} {hms(r['ts_start'])}: failed: {res.get('error')}", file=sys.stderr)
                con.execute("UPDATE audio_chunks SET transcribed=3 WHERE id=?", (r["id"],))
                con.commit()
                continue
            slot_voice = assign_voices(con, res.get("speakers", []), r["source"])
            # words → utterances: split on speaker change or a pause > 1.2 s
            utts: list[dict] = []
            for s, e, w, conf, slot in res.get("words", []):
                vid = slot_voice.get(slot)
                u = utts[-1] if utts else None
                if u and u["vid"] == vid and s - u["e"] <= 1.2 and len(u["words"]) < 120:
                    u["words"].append(w)
                    u["e"] = e
                else:
                    utts.append({"s": s, "e": e, "vid": vid, "words": [w]})
            n = 0
            for u in utts:
                text = " ".join(u["words"]).strip()
                if not text or HALLUCINATIONS.match(text):
                    continue
                cur = con.execute("INSERT INTO transcripts(chunk_id,source,ts_start,ts_end,text,lang,speaker_id) VALUES(?,?,?,?,?,?,?)",
                                  (r["id"], r["source"], r["ts_start"] + u["s"], r["ts_start"] + u["e"], text, None, u["vid"]))
                con.execute("INSERT INTO transcript_fts(rowid,text) VALUES(?,?)", (cur.lastrowid, text))
                n += 1
            con.execute("UPDATE audio_chunks SET transcribed=1 WHERE id=?", (r["id"],))
            con.commit()
            done += 1
            print(f"  {r['source']} {hms(r['ts_start'])}: {res.get('speech', 0):.0f}s speech → {n} lines, "
                  f"{len(slot_voice)} voice(s) in {time.time() - t0:.1f}s")
    finally:
        try:
            proc.stdin.close()
            proc.wait(timeout=30)
        except Exception:
            proc.kill()
    return done


def transcribe_whisper(con: sqlite3.Connection, rows: list) -> int:
    whisper, ffmpeg = which("whisper-cli"), which("ffmpeg")
    if not whisper or not ffmpeg:
        print("transcribe: need whisper-cli and ffmpeg (brew install whisper-cpp ffmpeg)", file=sys.stderr)
        return 0
    model = Path(CFG["whisperModel"]).expanduser()
    if not model.exists():
        print(f"transcribe: whisper model missing at {model} (run install.sh)", file=sys.stderr)
        return 0
    vad = Path(CFG["vadModel"]).expanduser()
    done = 0
    for r in rows:
        src = ROOT / r["path"]
        t0 = time.time()
        with tempfile.TemporaryDirectory() as tmp:
            wav = Path(tmp) / "a.wav"
            p = subprocess.run([ffmpeg, "-nostdin", "-loglevel", "error", "-y", "-i", str(src), "-ar", "16000", "-ac", "1", str(wav)],
                               capture_output=True, text=True)
            if p.returncode != 0:
                print(f"  ffmpeg failed on {r['path']}: {p.stderr.strip()[:200]}", file=sys.stderr)
                con.execute("UPDATE audio_chunks SET transcribed=3 WHERE id=?", (r["id"],))
                con.commit()
                continue
            cmd = [whisper, "-m", str(model), "-f", str(wav), "-l", CFG["transcribeLanguage"], "-oj", "-of", str(Path(tmp) / "out"),
                   "-np", "-t", str(max(4, (os.cpu_count() or 8) - 2))]
            if vad.exists():
                cmd += ["--vad", "--vad-model", str(vad)]
            p = subprocess.run(cmd, capture_output=True, text=True)
            out = Path(tmp) / "out.json"
            if p.returncode != 0 or not out.exists():
                print(f"  whisper failed on {r['path']}: {p.stderr.strip()[-300:]}", file=sys.stderr)
                con.execute("UPDATE audio_chunks SET transcribed=3 WHERE id=?", (r["id"],))
                con.commit()
                continue
            data = json.loads(out.read_text(errors="replace"))
        lang = (data.get("result") or {}).get("language")
        n = 0
        for seg in data.get("transcription", []):
            text = (seg.get("text") or "").strip()
            if not text or HALLUCINATIONS.match(text):
                continue
            a = r["ts_start"] + seg["offsets"]["from"] / 1000
            b = r["ts_start"] + seg["offsets"]["to"] / 1000
            cur = con.execute("INSERT INTO transcripts(chunk_id,source,ts_start,ts_end,text,lang) VALUES(?,?,?,?,?,?)",
                              (r["id"], r["source"], a, b, text, lang))
            con.execute("INSERT INTO transcript_fts(rowid,text) VALUES(?,?)", (cur.lastrowid, text))
            n += 1
        con.execute("UPDATE audio_chunks SET transcribed=1 WHERE id=?", (r["id"],))
        con.commit()
        done += 1
        print(f"  {r['source']} {hms(r['ts_start'])}: {n} segments ({lang}, whisper) in {time.time() - t0:.0f}s")
    return done


def list_voices(con) -> None:
    rows = con.execute("SELECT v.*, (SELECT COUNT(*) FROM transcripts t WHERE t.speaker_id=v.id) AS lines FROM voices v "
                       "ORDER BY (v.name IS NULL), v.seconds DESC").fetchall()
    if not rows:
        print("no voices yet — they appear after the first conversations are transcribed. Enroll yourself: lifelog enroll")
        return
    for v in rows:
        last = dt.datetime.fromtimestamp(v["last_heard"]).strftime("%Y-%m-%d %H:%M") if v["last_heard"] else "-"
        print(f"#{v['id']:<4} {(v['name'] or '(unnamed)'):<16} {fmt_dur(v['seconds'] or 0):>8} talking, {v['lines']:>4} lines, last {last}")
        for t in con.execute("SELECT text FROM transcripts WHERE speaker_id=? ORDER BY ts_start DESC LIMIT 2", (v["id"],)):
            print(f"        “{t['text'][:90]}”")
    print("\nname one:  lifelog voices name <id> <name>   (use 'Me' for yourself)   ·   merge:  lifelog voices merge <id> <into-id>")


def _heard_together(con, vid: int, name: str) -> bool:
    """were voice `vid` and person `name` separate speakers in the same recording? Then they're different people."""
    ids = [r[0] for r in con.execute("SELECT id FROM voices WHERE lower(trim(name))=lower(trim(?))", (name,))]
    if not ids:
        return False
    return con.execute(f"SELECT 1 FROM transcripts a WHERE a.speaker_id=? AND EXISTS (SELECT 1 FROM transcripts b "
                       f"WHERE b.chunk_id=a.chunk_id AND b.speaker_id IN ({','.join('?' * len(ids))})) LIMIT 1",
                       (vid, *ids)).fetchone() is not None


def consolidate_voices(con) -> None:
    """fold unnamed voices into a named one once their centroids are clearly that person (same rule enroll uses)"""
    named = [(v["id"], v["name"], json.loads(v["embedding"])) for v in con.execute("SELECT id, name, embedding FROM voices WHERE name IS NOT NULL")]
    if not named:
        return
    for v in con.execute("SELECT id, embedding FROM voices WHERE name IS NULL").fetchall():
        e = json.loads(v["embedding"])
        sim, vid, name = max((_cos(e, ne), nid, nm) for nid, nm, ne in named)
        if sim >= CFG["voiceMergeThreshold"] and not _heard_together(con, v["id"], name):
            print(f"  voice #{v['id']} is {name} ({sim:.2f})")
            merge_voices(con, v["id"], vid)


def merge_voices(con, src: int, dst: int) -> None:
    a = con.execute("SELECT * FROM voices WHERE id=?", (src,)).fetchone()
    b = con.execute("SELECT * FROM voices WHERE id=?", (dst,)).fetchone()
    if not a or not b or src == dst:
        print("unknown voice id")
        return
    ea, eb = json.loads(a["embedding"]), json.loads(b["embedding"])
    na, nb = min(a["n"], 50), min(b["n"], 50)
    # a named voice keeps its enrolled fingerprint: averaging merged clusters into it is how "Me" drifted onto everyone
    cen = eb if b["name"] else _norm([(x * na + y * nb) / (na + nb) for x, y in zip(ea, eb)])
    con.execute("UPDATE voices SET embedding=?, n=?, seconds=seconds+?, name=COALESCE(name, ?) WHERE id=?",
                (json.dumps(cen), a["n"] + b["n"], a["seconds"] or 0, a["name"], dst))
    con.execute("UPDATE transcripts SET speaker_id=? WHERE speaker_id=?", (dst, src))
    con.execute("DELETE FROM voices WHERE id=?", (src,))
    con.commit()
    print(f"merged voice #{src} into #{dst} ({b['name'] or 'unnamed'})")


def enroll(con, file: str | None, seconds: int, name: str, add: bool = False) -> None:
    """set a person's voice fingerprint. --add keeps their existing one(s) and adds another — e.g. a recording made on
    the phone, whose far-field mic makes the same voice sound different from the laptop's."""
    binary = Path(CFG["asrBinary"]).expanduser()
    if not binary.exists():
        sys.exit(f"{binary} missing — run install.sh")
    with tempfile.TemporaryDirectory() as tmp:
        path = file
        if not path:
            path = str(Path(tmp) / "me.wav")
            print(f"Recording {seconds}s from the microphone — talk normally (read something out loud)…")
            p = subprocess.run([which("ffmpeg") or "ffmpeg", "-loglevel", "error", "-f", "avfoundation", "-i", ":default",
                                "-t", str(seconds), "-ar", "16000", "-ac", "1", "-y", path])
            if p.returncode != 0:
                sys.exit("recording failed — give your terminal microphone access, or pass --file")
        p = subprocess.run([str(binary), "embed", path], capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit(f"embedding failed: {p.stderr.strip()[-300:]}")
        res = json.loads(p.stdout.strip().splitlines()[-1])
    if res.get("seconds", 0) < 4:
        sys.exit(f"only heard {res.get('seconds', 0):.0f}s of speech — try again a bit closer to the mic")
    emb = _norm(res["embedding"])
    now = time.time()
    row = con.execute("SELECT id FROM voices WHERE lower(trim(name))=lower(trim(?)) ORDER BY id", (name,)).fetchone()
    if row and not add:  # replaces their first fingerprint; any added with --add stay
        con.execute("UPDATE voices SET embedding=?, n=10, last_heard=? WHERE id=?", (json.dumps(emb), now, row["id"]))
        vid = row["id"]
    else:
        vid = con.execute("INSERT INTO voices(name, embedding, n, seconds, first_heard, last_heard) VALUES(?,?,10,0,?,?)",
                          (name, json.dumps(emb), now, now)).lastrowid
    con.commit()
    print(f"enrolled '{name}' as voice #{vid} from {res['seconds']:.0f}s of speech")
    consolidate_voices(con)  # relabel unnamed voices that are clearly this person


# ---------------------------------------------------------------- coding-agent logs (Claude Code, Codex, Delta)

def _iso_ts(s: str) -> float:
    return dt.datetime.fromisoformat(s.replace(" UTC", "Z").replace(" ", "T").replace("Z", "+00:00")).timestamp()


def delta_events(since: float) -> list[dict]:
    """prompts / replies from Delta threads (local app, via its CLI). Only messages not seen before are fetched:
    asking for a page past the end makes the CLI report the thread's message count, which is ~free."""
    def cli(*a):
        return subprocess.run(["delta", "--json", "thread", *a], capture_output=True, text=True, timeout=120)
    state_file = ROOT / ".delta-state.json"  # thread id → {"n": messages seen, "u": number of the last user message}
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    def count(tid):
        m = re.search(r"\((\d+) messages?\)", cli("show", tid, "--format", "messages", "--messages", "999999-999999").stderr)
        return int(m.group(1)) if m else None

    def msg_ts(tid, k):
        p = cli("show", tid, "--format", "messages", "--messages", f"{k}-{k}")
        msgs = (json.loads(p.stdout) or [{}])[0].get("messages", []) if p.returncode == 0 else []
        return _iso_ts(msgs[0]["created_at_utc"]) if msgs and msgs[0].get("created_at_utc") else 0

    def first_after(tid, total):
        """binary search: number of the first message at or after `since` (messages are in time order)"""
        lo, hi = 1, total + 1
        while lo < hi:
            mid = (lo + hi) // 2
            if msg_ts(tid, mid) >= since:
                hi = mid
            else:
                lo = mid + 1
        return lo

    # Delta's own database says when each thread was last prompted; only open threads prompted in the last 6 h
    # (replies to a prompt can keep arriving for hours). Opening a big thread through the CLI takes seconds.
    dbs = glob.glob(str(Path.home() / "Library/Application Support/delta/user_*/data.sqlite"))
    if not dbs:
        return []
    ro = sqlite3.connect(f"file:{dbs[0]}?mode=ro", uri=True, timeout=10)
    threads = [{"id": i, "name": n} for i, n in ro.execute(
        "SELECT id, name FROM app_threads WHERE last_prompted_at >= ?", ((since - 6 * 3600) * 1000,))]
    ro.close()
    cutoff = since - 6 * 3600
    since = cutoff  # first_after() looks for the first message after this
    out = []
    for t in threads:
        tid = t["id"]
        st = state.get(tid)
        if st is None:  # first sight: skip older history without downloading it
            total = count(tid)
            if total is None:
                continue
            start = first_after(tid, total) if total else 1
            st = {"n": start - 1, "u": None}
            if start > 1 and start <= total:  # find which prompt the first fetched replies belong to
                for k in range(start - 1, max(0, start - 30), -1):
                    p = cli("show", tid, "--format", "messages", "--messages", f"{k}-{k}")
                    m = (json.loads(p.stdout) or [{}])[0].get("messages", []) if p.returncode == 0 else []
                    if m and m[0]["role"] == "user":
                        st["u"] = k
                        break
        while True:
            lo = st["n"] + 1
            p = cli("show", tid, "--format", "messages", "--messages", f"{lo}-{lo + 19}")
            if p.returncode != 0:
                m = re.search(r"\((\d+) messages?\)", p.stderr)
                if not m:
                    break  # unreadable thread
                total = int(m.group(1))
                if total < lo:
                    break  # nothing new
                p = cli("show", tid, "--format", "messages", "--messages", f"{lo}-{total}")
                if p.returncode != 0:
                    break
            msgs = (json.loads(p.stdout) or [{}])[0].get("messages", [])
            if not msgs:
                break
            for msg in msgs:
                st["n"] = max(st["n"], msg["number"])
                if not msg.get("created_at_utc"):
                    continue
                ts, text = _iso_ts(msg["created_at_utc"]), (msg.get("buffer") or "").strip()
                base = {"tool": "delta", "account": None, "session": tid, "project": None, "title": t.get("name")}
                if msg["role"] == "user":
                    st["u"] = msg["number"]
                    out.append({**base, "kind": "prompt", "ts": ts, "text": text[:3000], "key": f"delta:{tid}:{msg['number']}"})
                elif st["u"] is not None and text:
                    out.append({**base, "kind": "reply", "ts": ts, "text": text[-1500:], "key": f"delta:{tid}:{st['u']}:r"})
            if len(msgs) < 20:
                break
        state[tid] = st
    state_file.write_text(json.dumps(state))
    return out


def collect_agents(con: sqlite3.Connection) -> dict[str, int]:
    """pull new prompts / replies from this Mac, the configured ssh hosts and Delta into agent_events"""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import agentlogs
    now, counts = time.time(), {}

    def since(src):
        r = con.execute("SELECT last FROM agent_sync WHERE source=?", (src,)).fetchone()
        return r[0] - 600 if r else now - CFG["agentLogBackfillDays"] * 86400

    def store(src, events):
        for e in events:
            if e["kind"] == "thread":
                con.execute("INSERT OR REPLACE INTO t3_threads VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                            (e["key"], src, e.get("project"), e.get("title"), e.get("created_by"), e.get("source"), e.get("parent"),
                             e.get("relation"), e.get("provider"), e.get("model"), e.get("created"), e.get("updated"),
                             e.get("settled"), int(bool(e.get("archived"))), e.get("branch"), e.get("worktree"), e.get("prs")))
            elif e["kind"] == "t3native":  # sessions T3 drives: their raw-log copies are duplicates of the T3 events
                ids = e["ids"]
                for i in range(0, len(ids), 500):
                    chunk = ids[i:i + 500]
                    con.execute(f"DELETE FROM agent_events WHERE host=? AND tool IN ('claude','codex') AND session IN "
                                f"({','.join('?' * len(chunk))})", (src, *chunk))
            else:
                con.execute("INSERT OR REPLACE INTO agent_events(key,ts,host,tool,account,session,project,title,kind,text,"
                            "sender,via,from_thread) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                            (f"{src}:{e['key']}", e["ts"], src, e["tool"], e.get("account"), e.get("session"), e.get("project"),
                             e.get("title"), e["kind"], e.get("text") or "", e.get("sender"), e.get("via"), e.get("from_thread")))
        con.execute("INSERT OR REPLACE INTO agent_sync(source,last) VALUES(?,?)", (src, now))
        con.commit()
        counts[src] = sum(e["kind"] == "prompt" for e in events)

    sources = [("mac", lambda s: agentlogs.scan(s))]
    for host in CFG["agentLogHosts"]:
        def remote(s, host=host):
            p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host, "python3", "-", str(s)],
                               input=Path(agentlogs.__file__).read_text(), capture_output=True, text=True, timeout=180)
            if p.returncode != 0:
                raise RuntimeError((p.stderr.strip().splitlines() or ["unreachable"])[-1][:200])
            return [json.loads(l) for l in p.stdout.splitlines() if l.startswith("{")]
        sources.append((host, remote))
    if CFG["agentLogDelta"] and which("delta"):
        sources.append(("delta", delta_events))
    for src, fn in sources:
        try:
            store(src, fn(since(src)))
        except Exception as e:  # offline devbox, Delta not running … try again next run
            print(f"  agent logs from {src}: skipped ({e})", file=sys.stderr)
    return counts


def agent_label(a) -> str:
    where = ("T3" if a["tool"] == "t3" else a["tool"]) + ("" if a["host"] in ("mac", "delta") else f" on {a['host']}")
    if a["tool"] == "t3":
        name = f"“{a['title'] or 'untitled'}”" + (f" ({a['project']})" if a["project"] else "")
    else:
        name = a["title"] or "/".join(Path(a["project"] or "").parts[-2:])
    return f"{where} · {name}" if name else where


T3_URL = re.compile(r"^t3code://app/#/([^/]+)/([0-9a-f-]{36})")  # project/thread, or draft/<id> for an unsent new thread


def t3_threads(con) -> dict:
    return {r["id"]: r for r in con.execute("SELECT * FROM t3_threads")}


def thread_stats(con, ds: float, de: float) -> list[dict]:
    """per T3 thread: seconds it was on screen while you were active, prompts you / agents / schedules sent, replies"""
    th, stats = t3_threads(con), {}

    def row(tid):
        t = th.get(tid)
        return stats.setdefault(tid, {"id": tid, "title": t["title"] if t else None, "project": t["project"] if t else None,
                                      "host": t["host"] if t else None, "by": t["created_by"] if t else None,
                                      "screen": 0, "you": 0, "agent": 0, "scheduled": 0, "replies": 0})
    idle_thr = CFG["idleThresholdSeconds"]
    for s in con.execute("SELECT url, idle, locked FROM samples WHERE ts>=? AND ts<? AND url LIKE 't3code://%'", (ds, de)):
        m = T3_URL.match(s["url"] or "")
        if m and not s["locked"] and (s["idle"] or 0) < idle_thr:
            r = row("draft" if m.group(1) == "draft" else m.group(2))
            r["screen"] += 1
            if m.group(1) == "draft":
                r["title"] = "new threads being drafted"
    for a in con.execute("SELECT session, kind, sender FROM agent_events WHERE tool='t3' AND ts>=? AND ts<?", (ds, de)):
        r = row(a["session"])
        if a["kind"] == "reply":
            r["replies"] += 1
        elif a["sender"] in ("you", "agent", "scheduled"):
            r[a["sender"]] += 1
    return sorted(stats.values(), key=lambda r: (-r["screen"], -r["you"], -r["agent"]))


# ---------------------------------------------------------------- building the raw log for Claude

def norm_lines(ocr: str | None) -> list[str]:
    out = []
    for ln in (ocr or "").splitlines():
        ln = " ".join(ln.split())
        if len(ln) >= 6 and not re.fullmatch(r"[\d:.,%\s/APMapm-]+", ln):
            out.append(ln)
    return out


def ctx_of(s) -> tuple[str, str, str]:
    return (s["app"] or "", s["title"] or "", s["url"] or "")


def build_log(con: sqlite3.Connection, start: float, end: float, max_chars: int = 110_000) -> tuple[str, int]:
    """Compact, time-ordered text rendering of everything recorded in [start, end). Returns (text, n_samples)."""
    samples = con.execute("SELECT * FROM samples WHERE ts>=? AND ts<? ORDER BY ts", (start, end)).fetchall()
    shots = con.execute("SELECT ts, app, title, url, ocr FROM screenshots WHERE ts>=? AND ts<? ORDER BY ts", (start, end)).fetchall()
    trans = con.execute("SELECT t.*, v.name AS vname FROM transcripts t LEFT JOIN voices v ON v.id=t.speaker_id "
                        "WHERE t.ts_start>=? AND t.ts_start<? ORDER BY t.ts_start", (start, end)).fetchall()
    events = con.execute("SELECT * FROM events WHERE ts>=? AND ts<? ORDER BY ts", (start, end)).fetchall()
    agents = con.execute("SELECT * FROM agent_events WHERE ts>=? AND ts<? ORDER BY ts", (start, end)).fetchall()
    threads = t3_threads(con)
    phone = phone_entries(con, start, end)
    if not samples and not phone:
        return "", 0

    # 10-second buckets
    BUCKET = 10
    buckets: dict[int, list] = collections.defaultdict(list)
    for s in samples:
        buckets[int(s["ts"] // BUCKET * BUCKET)].append(s)

    entries: list[tuple[float, int, str]] = []  # (ts, order, text)
    prev_ctx = None
    run: dict | None = None  # consecutive buckets with the same "shape" get merged into one line
    last_bucket_ts = None

    def flush():
        nonlocal run
        if not run:
            return
        a, b, sig = run["a"], run["b"] + BUCKET, run["sig"]
        n = (b - a) // BUCKET
        span = f"{hms(a)}–{hms(b)}" if n > 1 else hms(a)
        robot = f"  AUTOMATED INPUT {run['synth']} (injected by software, not the user)" if run["synth"] else ""
        if sig[0] == "quiet":
            what = "SCREEN LOCKED, " if sig[1] else ""
            text = f"{span}  {what}no keyboard/mouse input (idle up to {int(run['idle'])}s), audio quiet{robot}"
        else:
            parts = [span]
            if run["locked"]:
                parts.append("SCREEN LOCKED")
            if run["keys"]:
                parts.append(f"keys {run['keys']}" + (f" (~{run['keys'] // n}/10s)" if n > 1 else ""))
            if run["clicks"]:
                parts.append(f"clicks {run['clicks']}")
            if run["scroll"]:
                parts.append(f"scroll {run['scroll']:,}px")
            if run["mouse"] >= 40:
                parts.append(f"mouse {run['mouse']:,}px")
            if run["mic"] is not None:
                parts.append(f"MIC up to {run['mic']:.0f}dB")
            if run["sys"] is not None:
                parts.append(f"computer-audio up to {run['sys']:.0f}dB")
            if not (run["keys"] or run["clicks"] or run["scroll"]) and run["idle"] > 15:
                parts.append(f"no typing/clicking (idle up to {int(run['idle'])}s)")
            text = "  ".join(parts) + robot
        entries.append((a, 1, text))
        run = None

    for bts in sorted(buckets):
        ss = buckets[bts]
        if last_bucket_ts is not None and bts - last_bucket_ts > 60:
            flush()
            entries.append((last_bucket_ts + BUCKET, 0, f"{hms(last_bucket_ts + BUCKET)}–{hms(bts)}  [NO DATA: laptop asleep, recorder off or paused]"))
        last_bucket_ts = bts
        locked = any(s["locked"] for s in ss)
        ctx = collections.Counter(ctx_of(s) for s in ss).most_common(1)[0][0]
        keys = sum(s["keys"] or 0 for s in ss)
        clicks = sum(s["clicks"] or 0 for s in ss)
        scroll = sum(s["scroll"] or 0 for s in ss)
        mouse = sum(s["mouse"] or 0 for s in ss)
        synth = sum((s["synth"] or 0) if "synth" in s.keys() else 0 for s in ss)
        mics =[s["mic_db"] for s in ss if s["mic_db"] is not None]
        syss = [s["sys_db"] for s in ss if s["sys_db"] is not None]
        mic = max(mics) if mics else None
        sysd = max(syss) if syss else None
        idle = max((s["idle"] or 0) for s in ss)
        mic_loud = mic is not None and mic >= CFG["micSpeechThresholdDb"]
        sys_loud = sysd is not None and sysd >= CFG["sysSoundThresholdDb"]

        if ctx != prev_ctx:
            flush()
            app, title, url = ctx
            m = T3_URL.match(url)
            t3 = threads.get(m.group(2)) if m else None
            if m and m.group(1) == "draft":
                url = "drafting a new T3 thread (not sent yet)"
            elif t3:  # name the T3 thread on screen instead of its opaque URL
                url = (f"T3 thread “{t3['title']}” ({t3['project']}" + (f", on {t3['host']}" if t3["host"] != "mac" else "")
                       + (", started by an agent" if t3["created_by"] == "agent" else "") + ")")
            entries.append((bts, 0, f"@ {app}" + (f" — “{title}”" if title else "") + (f" — {url}" if url else "")))
            prev_ctx = ctx

        quiet = keys == 0 and clicks == 0 and scroll == 0 and mouse < 40 and not mic_loud and not sys_loud
        # typing bursts stay at 10-s resolution for up to 1 minute per line so pauses remain visible
        sig = (("quiet", locked) if quiet else (keys > 0, clicks > 0, scroll > 0, mouse >= 40, mic_loud, sys_loud, locked)) + (synth > 0,)
        max_len = 6 * 60 if quiet or not keys else 60
        if run and run["sig"] == sig and bts - run["b"] == BUCKET and bts - run["a"] < max_len:
            run["b"] = bts
        else:
            flush()
            run = {"a": bts, "b": bts, "sig": sig, "keys": 0, "clicks": 0, "scroll": 0, "mouse": 0, "synth": 0,
                   "mic": None, "sys": None, "idle": 0, "locked": locked}
        run["keys"] += keys
        run["synth"] += synth
        run["clicks"] += clicks
        run["scroll"] += scroll
        run["mouse"] += mouse
        run["idle"] = max(run["idle"], idle)
        if mic_loud:
            run["mic"] = max(run["mic"] or -999, mic)
        if sys_loud:
            run["sys"] = max(run["sys"] or -999, sysd)
    flush()

    # screen text: show what's NEW on screen
    prev_lines: set[str] = set()
    last_ocr_at = -1e9
    prev_shot_ctx = None
    ocr_entries = []
    for sh in shots:
        lines = norm_lines(sh["ocr"])
        if not lines:
            continue
        sctx = (sh["app"], sh["title"], sh["url"])
        new = [ln for ln in lines if ln not in prev_lines]
        prev_lines = set(lines)
        if sctx != prev_shot_ctx:
            text = " | ".join(lines)[:900]
            label = "screen text (new view)"
        else:
            if sh["ts"] - last_ocr_at < 15:
                continue
            text = " | ".join(new)[:450]
            label = "new on screen"
            if len(text) < 25:
                continue
        prev_shot_ctx = sctx
        last_ocr_at = sh["ts"]
        ocr_entries.append((sh["ts"], 2, f"    [{label} {hms(sh['ts'])}] {text}"))

    trans_entries = []
    for t in trans:
        who = {"mic": "MIC", "phone": "PHONE MIC"}.get(t["source"], "COMPUTER AUDIO")
        label = voice_label(t["vname"], t["speaker_id"])
        if label:
            who += f" · {label}"
        trans_entries.append((t["ts_start"], 3, f"    [{who} {hms(t['ts_start'])}–{hms(t['ts_end'])}] “{t['text']}”"))
    ev_entries = [(e["ts"], 0, f"{hms(e['ts'])}  [EVENT: {e['kind']} {e['detail'] or ''}]".rstrip()) for e in events
                  if e["kind"] in ("sleep", "wake", "pause", "resume", "locked", "unlocked", "start", "stop")]
    # autonomous agent swarms (night shifts, delegations) shouldn't drown the user's own activity
    busy = sum(a["sender"] not in ("agent", "scheduled") for a in agents) > 80
    background = {a["session"] for a in agents if a["tool"] == "t3" and a["kind"] == "prompt" and a["sender"] != "you"} - \
                 {a["session"] for a in agents if a["tool"] == "t3" and a["sender"] == "you"}
    for a in agents:
        text = " ".join((a["text"] or "").split())
        label, at = agent_label(a), hms(a["ts"])
        if a["kind"] == "prompt":
            if a["sender"] == "you":
                via = " from your phone" if a["via"] == "mobile" else ""
                ev_entries.append((a["ts"], 4, f"    [PROMPT YOU SENT{via} · {label} {at}] “{text[:160 if busy else 700]}”"))
            elif a["sender"] == "agent":
                src = threads.get(a["from_thread"]) if a["from_thread"] else None
                frm = f" from thread “{src['title']}”" if src else ""
                ev_entries.append((a["ts"], 4, f"    [AGENT-TO-AGENT PROMPT{frm} → {label} {at}] “{text[:120]}”"))
            elif a["sender"] == "scheduled":
                ev_entries.append((a["ts"], 4, f"    [SCHEDULED-TASK PROMPT → {label} {at}] “{text[:120]}”"))
            else:
                ev_entries.append((a["ts"], 4, f"    [AGENT PROMPT SENT · {label} {at}] “{text[:160 if busy else 700]}”"))
        else:
            short = busy or (a["tool"] == "t3" and a["session"] in background)
            ev_entries.append((a["ts"], 4, f"    [AGENT FINISHED · {label} {at}] “{text[:100 if short else 220]}”"))

    def render(ocr_list):
        allents = sorted(entries + ocr_list + trans_entries + ev_entries + phone, key=lambda e: (e[0], e[1]))
        return "\n".join(e[2] for e in allents)

    text = render(ocr_entries)
    while len(text) > max_chars and ocr_entries:
        ocr_entries = ocr_entries[::2] if len(ocr_entries) > 4 else []
        text = render(ocr_entries)
    return text, max(len(samples), len(phone))


def _pdata(e) -> dict:
    try:
        return json.loads(e["data"] or "{}")
    except (json.JSONDecodeError, TypeError):
        return {}


def phone_entries(con, start: float, end: float) -> list[tuple[float, int, str]]:
    """The iPhone's facts in [start, end) as log lines: screen sessions, sound runs, calls, motion, steps, places, battery…"""
    try:
        evs = con.execute("SELECT * FROM phone_events WHERE ts>=? AND ts<? ORDER BY ts", (start - 3600, end)).fetchall()
    except sqlite3.OperationalError:
        return []
    out: list[tuple[float, int, str]] = []
    add = lambda ts, text: out.append((ts, 0, text)) if start <= ts < end else None

    # screen: unlocked sessions and glances (screen on without unlocking)
    on_at = unlock_at = None
    used = False  # unlocked at some point since the screen came on
    for e in evs:
        if e["kind"] != "screen":
            continue
        st, ts = _pdata(e).get("state"), e["ts"]
        if st == "on":
            on_at = on_at or ts
        elif st == "unlocked":
            unlock_at = unlock_at or ts
            on_at = on_at or ts
            used = True
        elif st in ("locked", "off"):
            if unlock_at is not None:
                if ts > start:
                    add(max(unlock_at, start), f"{hms(max(unlock_at, start))}–{hms(ts)}  [PHONE UNLOCKED, in use {fmt_dur(ts - unlock_at)}]")
            elif on_at is not None and st == "off" and not used and ts - on_at >= 2:
                add(on_at, f"{hms(on_at)}–{hms(ts)}  [PHONE screen on, not unlocked ({fmt_dur(ts - on_at)}) — glance / notification]")
            if st == "off":
                on_at, used = None, False
            unlock_at = None
    if unlock_at is not None:
        add(max(unlock_at, start), f"{hms(max(unlock_at, start))}–…  [PHONE UNLOCKED, still in use at {hms(min(end, time.time()))}]")

    # sound around the phone, per minute → runs of the same kind
    run = None
    def flush_sound():
        if run and run["b"] > start:
            a = max(run["a"], start)
            kind = run["k"]
            what = {"quiet": "quiet", "sound": "sound / voices nearby"}[kind[0]]
            other = ", ANOTHER APP PLAYING AUDIO (music/video/podcast)" if kind[1] else ""
            add(a, f"{hms(a)}–{hms(run['b'])}  [PHONE MIC: {what}{other}; avg {run['avg'] / run['n']:.0f}dB, peak {run['peak']:.0f}dB]")
    for e in evs:
        if e["kind"] != "sound":
            continue
        d = _pdata(e)
        k = ("sound" if (d.get("loud_s") or 0) >= 3 else "quiet", bool(d.get("other_audio")))
        if run and run["k"] == k and e["ts"] - run["b"] <= 61 and run["b"] - run["a"] < 30 * 60:
            run["b"] = e["ts"] + 60; run["n"] += 1; run["avg"] += d.get("avg_db", -160); run["peak"] = max(run["peak"], d.get("peak_db", -160))
        else:
            flush_sound()
            run = {"a": e["ts"], "b": e["ts"] + 60, "k": k, "n": 1, "avg": d.get("avg_db", -160), "peak": d.get("peak_db", -160)}
    flush_sound()

    # steps → walks (consecutive 5-minute bins)
    walk = None
    def flush_walk():
        if walk:
            add(walk["a"], f"{hms(walk['a'])}–{hms(walk['b'])}  [PHONE STEPS: {walk['steps']:,} steps, ~{walk['m']:,} m]")
    for e in evs:
        if e["kind"] != "steps":
            continue
        d = _pdata(e)
        b = d.get("to") or e["ts"] + 300
        if walk and e["ts"] - walk["b"] <= 1:
            walk["b"] = b; walk["steps"] += d.get("steps", 0); walk["m"] += d.get("meters", 0)
        else:
            flush_walk()
            walk = {"a": e["ts"], "b": b, "steps": d.get("steps", 0), "m": d.get("meters", 0)}
    flush_walk()

    last_out = None
    for e in evs:
        d, ts, k = _pdata(e), e["ts"], e["kind"]
        if k == "call":
            add(ts, f"{hms(ts)}  [PHONE CALL {d.get('state')}{' (outgoing)' if d.get('outgoing') else ''}"
                    f"{' on hold' if d.get('on_hold') else ''} · call {d.get('call', '')}]")
        elif k == "motion":
            add(ts, f"{hms(ts)}  [PHONE MOTION: {d.get('activity')} ({d.get('confidence')} confidence)]")
        elif k == "visit":
            place = d.get("place") or f"{d.get('lat', 0):.4f},{d.get('lon', 0):.4f}"
            if d.get("arrival") and start <= d["arrival"] < end and not d.get("departure"):
                add(d["arrival"], f"{hms(d['arrival'])}  [PHONE PLACE: arrived at {place} (±{d.get('acc')} m)]")
            if d.get("departure"):
                since = f" (there since {hms(d['arrival'])})" if d.get("arrival") else ""
                add(d["departure"], f"{hms(d['departure'])}  [PHONE PLACE: left {place}{since}]")
        elif k == "location":
            sp = d.get("speed", -1)
            add(ts, f"{hms(ts)}  [PHONE LOCATION: {d.get('lat', 0):.4f},{d.get('lon', 0):.4f} ±{d.get('acc')} m"
                    + (f", moving {sp * 3.6:.0f} km/h" if sp and sp > 0.5 else "") + "]")
        elif k == "battery" and "state" in d:
            add(ts, f"{hms(ts)}  [PHONE BATTERY: {d.get('state')} {d.get('level')}%]")
        elif k == "route":
            o = ", ".join(x.split(":", 1)[-1] for x in d.get("outputs", []))
            if o != last_out:
                add(ts, f"{hms(ts)}  [PHONE AUDIO OUTPUT: {o}]")
                last_out = o
        elif k == "mic" and d.get("state") in ("on", "off", "interrupted", "failed", "stalled"):
            why = d.get("reason") or d.get("error") or ""
            add(ts, f"{hms(ts)}  [PHONE RECORDER: mic {d.get('state')}{' — ' + why if why else ''}]")
        elif k == "app" and d.get("state") in ("launch", "terminate"):
            add(ts, f"{hms(ts)}  [PHONE RECORDER: app {'started' if d['state'] == 'launch' else 'terminated (phone record stops until reopened)'}"
                    f"{' — ' + d['reason'] if d.get('reason') else ''}]")
    return out


SYSTEM_PROMPT = """You reconstruct exactly how a person spent their time on their laptop, from a raw activity log.

The log is time-ordered (local time, HH:MM:SS). Line types:
- "@ App — “window title” — url"  : the frontmost app/window changed to this.
- "HH:MM:SS keys N clicks N scroll Npx mouse Npx MIC -NNdB computer-audio -NNdB" : one 10-second bucket of input activity.
  keys = keystrokes (typing), scroll = scrolling distance (reading/feeds), MIC level near/above -40dB = someone talking near the laptop,
  computer-audio = sound playing from the computer (video, music, the other side of a call).
- "AUTOMATED INPUT N" on an input line: N clicks/keys/scrolls that software injected (a coding agent driving the cursor in a UI
  test, an automation tool). They are NOT the user and are already excluded from keys/clicks/mouse and from idle. Long stretches of
  automated input with no real input mean an agent was working the machine on its own — the user may be asleep or away.
- "A–B no keyboard/mouse input" : nothing touched, audio quiet. Short gaps (≤2 min) inside work usually mean reading or thinking;
  long gaps usually mean away from the laptop — use context (screen locked, what was on screen, what came after) to decide.
- "[new on screen …]" / "[screen text (new view) …]" : OCR of the screen. Use it to see WHAT was being read, written or watched
  (chat thread names, tweets, code files, video titles, prompt text).
- "[MIC …]" / "[COMPUTER AUDIO …]" : speech transcripts. MIC = the user and anyone physically nearby. COMPUTER AUDIO = call partner, videos, etc.
  After the source comes the speaker: "Me" is the user; other names are people the user identified; "voice #N" is an unidentified voice
  (the same number is the same person across the day). If there are no speaker labels, infer who is talking from context.
- "[NO DATA …]" / "[EVENT …]" : laptop asleep, recorder paused, screen locked, etc.
- "[PROMPT YOU SENT · T3 · “thread title” (project) …]" : the exact message the user sent in T3 Code (their coding-agent app),
  known for certain to be from them. "from your phone" = sent from the T3 phone app, not the laptop — they were awake and on their
  phone then, even if the laptop was untouched. Otherwise the typing/dictation right before it was writing this prompt — name the
  thread and say what was asked.
  "[AGENT-TO-AGENT PROMPT …]" / "[SCHEDULED-TASK PROMPT …]" : sent by another agent or a schedule, not the user — background work,
  never the user's time (mention it only as context, e.g. "while 5 delegated agents ran").
- "[AGENT PROMPT SENT · tool · thread …]" : a message sent to a coding agent outside T3 (Claude Code / Codex CLI, Delta), with the
  thread/project. The sender isn't recorded: if there was no typing just before it (keys on the laptop, or dictation on the MIC),
  it was most likely agent-to-agent background work.
- "[AGENT FINISHED …]" : that agent finished its turn (start of its final reply). Between a prompt and its FINISHED line the agent was
  working: the user was waiting, multitasking, or watching it. After FINISHED they usually read the reply.
  "on <host>" means the agent ran on that remote machine (e.g. a devbox over ssh) — still the user's own work.
- "@ T3 Code — … — T3 thread “title” (project)" : the T3 thread the user had open on screen.
- "[PHONE …]" lines come from the user's iPhone (it's always with them, so it covers time away from the laptop too):
  "PHONE UNLOCKED, in use 4m" = they were using their phone (which app is unknown); "PHONE screen on, not unlocked" = a glance
  or a notification; "PHONE MIC" = sound around the phone per run of minutes ("ANOTHER APP PLAYING AUDIO" = music, a video or
  a podcast playing on the phone); "[PHONE MIC · speaker …]" = speech transcribed from the phone's mic ("Me" is the user);
  "PHONE CALL" = a phone/FaceTime/WhatsApp call; "PHONE MOTION" = walking / running / cycling / vehicle / still;
  "PHONE STEPS" = walking; "PHONE PLACE" = arrived at / left a place; "PHONE LOCATION" = a move of ~500 m+;
  "PHONE BATTERY: charging" (at night it often means the phone is on the nightstand); "PHONE RECORDER" = the phone stopped or
  resumed recording (gaps in phone data are not evidence of anything).
  Phone use while the laptop is idle is "on phone" time; phone use during laptop work is a distraction worth naming.

Produce segments that cover the whole window contiguously (from the first to the last timestamp given), in order, no overlaps.
Be granular and concrete: split whenever the activity really changes — e.g. "typing a prompt in T3 Code thread 'lifelog app'" for 3 minutes,
then "reading Claude's response / thinking" for 1 minute, then "scrolling X home feed". Don't create segments shorter than ~20 seconds
unless they're meaningful; merge noise like a 5-second app switch into the surrounding segment.
- activity: short, specific, names the thing (app + which chat/thread/file/site/video/person). ≤ 90 chars.
- detail: 1–2 sentences of concrete specifics you can actually see in the log (what was asked, what topic was discussed, which tweets/videos).
  Don't invent; if unsure, say what the evidence suggests.
- category: one of the allowed values. "on phone" = using the phone (unlocked) and not the laptop. "voice & calls" for talking (in person near the laptop or on a call). "idle at desk" = present but not interacting
  (reading long text without scrolling, thinking). "away" = not at the laptop (long idle, locked, asleep, no data).
  Use "away" for absences even at night — a second pass looks at long absences across the whole day and decides if they were sleep.
- app: the main app or website (e.g. "T3 Code", "x.com", "YouTube", "Discord").
Times must be HH:MM:SS within the window."""


def segment_schema() -> dict:
    return {
        "type": "object",
        "properties": {
            "segments": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "start": {"type": "string"},
                        "end": {"type": "string"},
                        "category": {"type": "string", "enum": CATEGORIES},
                        "activity": {"type": "string"},
                        "detail": {"type": "string"},
                        "app": {"type": "string"},
                    },
                    "required": ["start", "end", "category", "activity", "detail", "app"],
                },
            }
        },
        "required": ["segments"],
    }


def ask_claude(prompt: str, system: str, model: str, schema: dict | None = None, timeout: int = 600):
    claude = which("claude")
    if not claude:
        raise RuntimeError("claude CLI not found (install Claude Code)")
    cmd = [claude, "-p", "--model", model, "--tools", "", "--no-session-persistence", "--strict-mcp-config",
           "--setting-sources", "", "--output-format", "json", "--system-prompt", system]
    if schema:
        cmd += ["--json-schema", json.dumps(schema)]
    env = dict(os.environ)
    acct = CFG.get("claudeConfigDir") or ""
    if acct == "default":
        env.pop("CLAUDE_CONFIG_DIR", None)
    elif acct:
        env["CLAUDE_CONFIG_DIR"] = str(Path(acct).expanduser())
    p = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=timeout, cwd=tempfile.gettempdir(), env=env)
    if p.returncode != 0:
        raise RuntimeError(f"claude failed ({p.returncode}): {(p.stderr or p.stdout).strip()[-500:]}")
    out = json.loads(p.stdout)
    if out.get("is_error"):
        raise RuntimeError(f"claude error: {str(out.get('result'))[:500]}")
    if schema:
        if isinstance(out.get("structured_output"), dict):
            return out["structured_output"]
        res = out.get("result", "")
        m = re.search(r"\{.*\}", res, re.S)
        return json.loads(m.group(0) if m else res)
    return out.get("result", "")


def parse_hms(day_start: float, s: str, lo: float) -> float:
    h, m, *rest = [int(x) for x in s.strip().split(":")]
    sec = rest[0] if rest else 0
    ts = day_start + h * 3600 + m * 60 + sec
    if ts < lo - 3600:  # crossed midnight
        ts += 86400
    return ts


def analyze_window(con: sqlite3.Connection, start: float, end: float, partial: bool) -> int:
    log_text, n = build_log(con, start, end)
    if n == 0:
        con.execute("INSERT OR REPLACE INTO analyzed_windows VALUES(?,?,?,?)", (start, end, int(partial), time.time()))
        con.commit()
        return 0
    prev = con.execute("SELECT * FROM segments WHERE ts_end<=? ORDER BY ts_start DESC LIMIT 4", (start + 1,)).fetchall()
    prev_txt = "\n".join(f"{hms(p['ts_start'])}–{hms(p['ts_end'])} [{p['category']}] {p['activity']}" for p in reversed(prev))
    about = CFG.get("aboutMe") or ""
    prompt = (
        (f"About the user: {about}\n\n" if about else "")
        + (f"For continuity, the previous segments were:\n{prev_txt}\n\n" if prev_txt else "")
        + f"Window: {hms(start)} to {hms(end)} on {dt.datetime.fromtimestamp(start):%A %Y-%m-%d}.\n\n"
        + "RAW LOG:\n" + log_text
    )
    res = ask_claude(prompt, SYSTEM_PROMPT, CFG["analysisModel"], segment_schema())
    day_start = dt.datetime.fromtimestamp(start).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    first_ts = con.execute("SELECT MIN(ts) FROM samples WHERE ts>=? AND ts<?", (start, end)).fetchone()[0] or start
    con.execute("DELETE FROM segments WHERE ts_start>=? AND ts_start<?", (start, end))
    count = 0
    for s in res.get("segments", []):
        try:
            a = max(start, parse_hms(day_start, s["start"], start))
            b = min(end, parse_hms(day_start, s["end"], start))
        except (ValueError, KeyError):
            continue
        if b <= a:
            continue
        cat = s.get("category") if s.get("category") in CATEGORIES else "other"
        con.execute("INSERT INTO segments(ts_start,ts_end,category,activity,detail,app) VALUES(?,?,?,?,?,?)",
                    (a, b, cat, s.get("activity", ""), s.get("detail", ""), s.get("app", "")))
        count += 1
    con.execute("INSERT OR REPLACE INTO analyzed_windows VALUES(?,?,?,?)", (start, end, int(partial), time.time()))
    con.commit()
    _ = first_ts
    return count


def analyze(con: sqlite3.Connection, day: str, force: bool = False, include_partial: bool = True) -> None:
    ds, de = day_bounds(day)
    now = time.time()
    for h in range(24):
        a, b = ds + h * 3600, ds + (h + 1) * 3600
        if a > now:
            break
        partial = b > now - 120
        if partial and not include_partial:
            continue
        row = con.execute("SELECT partial FROM analyzed_windows WHERE ts_start=?", (a,)).fetchone()
        if row and not row["partial"] and not force:
            continue
        has = con.execute("SELECT COUNT(*) FROM samples WHERE ts>=? AND ts<?", (a, b)).fetchone()[0]
        if not has:
            if not partial:
                con.execute("INSERT OR REPLACE INTO analyzed_windows VALUES(?,?,?,?)", (a, b, 0, now))
                con.commit()
            continue
        # if transcription is still pending for this hour, wait (unless forced)
        pending = con.execute("SELECT COUNT(*) FROM audio_chunks WHERE transcribed=0 AND ts_start<? AND (ts_end IS NULL OR ts_end>?)",
                              (b, a)).fetchone()[0]
        if pending and not partial and not force:
            print(f"  {hms(a)}: waiting for {pending} audio chunk(s) to be transcribed")
            continue
        t0 = time.time()
        try:
            n = analyze_window(con, a, min(b, now), partial)
            print(f"  analyzed {hms(a)}–{hms(min(b, now))}: {n} segments ({time.time() - t0:.0f}s){' [partial]' if partial else ''}")
        except Exception as e:  # keep going with other hours
            print(f"  analyze {hms(a)} failed: {e}", file=sys.stderr)
    try:
        for kind, a, b, label in label_absences(con, day):
            print(f"  {kind}: {hms(a)[:5]}–{hms(b)[:5]} ({fmt_dur(b - a)}) {label}")
    except Exception as e:
        print(f"  absence labelling failed: {e}", file=sys.stderr)


# ---------------------------------------------------------------- absences (sleep, naps, being out)

# Code only gathers facts it can be sure of (nothing was touched from X to Y, the screen was locked, the mic heard speech);
# Claude decides what the absence was, with the whole day around it as context.
ABSENCE_CATS = ("away", "idle at desk", "sleep")

ABSENCE_PROMPT = """You decide what a person was doing during long stretches when they were not using their laptop.
You get facts recorded by their Mac for each stretch, what they did right before and right after, and their recent sleep history.

Use common sense about humans: people sleep once a day, usually at night, typically 5–10 hours, and night owls sleep into the
late morning or afternoon. A long overnight stretch that ends when they come back is their sleep. Naps are shorter and in the day.
Daytime absences are usually being out or away from the desk (food, errands, people, phone) unless the context says otherwise.
The user talking on the mic during a stretch means they were awake nearby; other voices or faint noise don't.
Coding agents (Claude Code, Codex, Delta — on this Mac or remote machines) keep working on their own while the person is gone, so agent
activity during a stretch is not evidence they were awake or present; only their own input, unlocking the screen, or their voice is.
Messages they themselves sent to their agents (listed per stretch) are certain: one sent from their phone means they were awake
then, wherever they were.
Their iPhone's record is strong evidence when present: unlocking it means awake; walking / a vehicle / arriving at or leaving a
place means out; a quiet phone that's charging and still for hours at night means asleep. A phone that recorded nothing (no
events at all) tells you nothing.
If they probably fell asleep at the desk or left the laptop running, set start to when sleep most likely began (and end to when
they most likely woke) — otherwise leave start/end empty to mean the whole stretch.
Kinds: "sleep" (main sleep), "nap", "away" (awake, elsewhere), "at_desk" (actually at the laptop — watching, reading, thinking;
leave it as recorded), "no_data" (the recorder simply wasn't running / nothing known).
activity: short label, e.g. "Sleep", "Nap", "Out — probably lunch", "Away from laptop". detail: one sentence with your evidence.
Be decisive."""


def absence_schema() -> dict:
    return {
        "type": "object",
        "properties": {"absences": {"type": "array", "items": {
            "type": "object",
            "properties": {
                "id": {"type": "integer"},
                "kind": {"type": "string", "enum": ["sleep", "nap", "away", "at_desk", "no_data"]},
                "start": {"type": "string", "description": "HH:MM:SS or empty"},
                "end": {"type": "string", "description": "HH:MM:SS or empty"},
                "activity": {"type": "string"},
                "detail": {"type": "string"},
            },
            "required": ["id", "kind", "activity", "detail"],
        }}},
        "required": ["absences"],
    }


def find_absences(con, lo: float, hi: float) -> list[dict]:
    """Facts: stretches with no interaction — 'away' / 'idle at desk' / earlier-labelled sleep segments and gaps with
    no data — bridging brief blips (< 3 min). Returns those of at least absenceMinMinutes."""
    segs = con.execute("SELECT * FROM segments WHERE ts_end>? AND ts_start<? ORDER BY ts_start", (lo, hi)).fetchall()
    pieces, prev_end = [], None
    for sg in segs:
        if prev_end is not None and sg["ts_start"] - prev_end > 60:
            pieces.append({"s": prev_end, "e": sg["ts_start"], "absent": True, "cat": "no data", "text": "no data (laptop asleep, off, or recorder not running)"})
        pieces.append({"s": sg["ts_start"], "e": sg["ts_end"], "absent": sg["category"] in ABSENCE_CATS, "cat": sg["category"],
                       "text": f"{sg['activity']} — {sg['detail']}"})
        prev_end = max(prev_end or 0, sg["ts_end"])
    runs, cur = [], []
    for p in pieces:
        if p["absent"] or (cur and p["e"] - p["s"] < 180):
            cur.append(p)
        else:
            if cur: runs.append(cur)
            cur = []
    if cur: runs.append(cur)
    out = []
    for run in runs:
        while run and not run[-1]["absent"]: run.pop()
        if run and run[-1]["e"] - run[0]["s"] >= CFG["absenceMinMinutes"] * 60:
            out.append({"s": run[0]["s"], "e": run[-1]["e"], "pieces": run})
    return out


def describe_absence(con, i: int, ab: dict, last_data: float) -> str:
    a, b = ab["s"], ab["e"]
    lines = [f"## Stretch {i}: {dt.datetime.fromtimestamp(a):%a %H:%M:%S} → {dt.datetime.fromtimestamp(b):%a %H:%M:%S} ({fmt_dur(b - a)})"
             + (" — STILL ONGOING (this is the latest data)" if last_data - b < 600 else "")]
    lines.append("What the recorder saw:")
    for p in ab["pieces"][:14]:
        lines.append(f"  {hms(p['s'])}–{hms(p['e'])} [{p['cat']}] {p['text'][:160]}")
    ev = con.execute("SELECT ts, kind FROM events WHERE ts>=? AND ts<? AND kind IN ('locked','unlocked','sleep','wake','start','stop','pause','resume') ORDER BY ts",
                     (a - 60, b + 60)).fetchall()
    if ev:
        lines.append("Mac events: " + ", ".join(f"{hms(e['ts'])[:5]} {e['kind']}" for e in ev[:20]))
    loud = con.execute("SELECT COUNT(*) FROM samples WHERE ts>=? AND ts<? AND mic_db>-40", (a, b)).fetchone()[0]
    rec = con.execute("SELECT COUNT(*) FROM samples WHERE ts>=? AND ts<?", (a, b)).fetchone()[0]
    lines.append(f"Recorder running for {fmt_dur(rec)} of it; sound near the laptop (mic > -40 dB) in {loud} seconds.")
    mine = con.execute("SELECT ts, via, title, text FROM agent_events WHERE sender='you' AND kind='prompt' AND ts>=? AND ts<? ORDER BY ts",
                       (a, b)).fetchall()
    if mine:
        lines.append(f"Messages the person themselves sent to their AI agents in T3 during this stretch ({len(mine)}):")
        for m in mine[:8]:
            where = "from their phone" if m["via"] == "mobile" else "from a computer"
            lines.append(f"  {hms(m['ts'])[:5]} {where} in “{m['title']}”: “{' '.join((m['text'] or '').split())[:100]}”")
    tr = con.execute("SELECT t.ts_start, t.source, t.text, v.name, t.speaker_id FROM transcripts t LEFT JOIN voices v ON v.id=t.speaker_id "
                     "WHERE t.ts_start>=? AND t.ts_start<? ORDER BY t.ts_start LIMIT 10", (a, b)).fetchall()
    for t in tr:
        lines.append(f"  heard {hms(t['ts_start'])[:5]} [{t['source']} · {voice_label(t['name'], t['speaker_id']) if t['speaker_id'] else '?'}] “{t['text'][:120]}”")
    ph = phone_entries(con, a, b)
    if ph:
        lines.append(f"Their iPhone during this stretch ({len(ph)} facts):")
        lines += ["  " + t for _, _, t in sorted(ph)[:40]]
    before = con.execute("SELECT * FROM segments WHERE ts_end<=? AND category NOT IN ('away','sleep') ORDER BY ts_end DESC LIMIT 3", (a + 1,)).fetchall()
    after = con.execute("SELECT * FROM segments WHERE ts_start>=? AND category NOT IN ('away','sleep') ORDER BY ts_start LIMIT 3", (b - 1,)).fetchall()
    if before:
        lines.append("Right before: " + " | ".join(f"{hms(x['ts_start'])[:5]} {x['activity']}" for x in reversed(before)))
    if after:
        lines.append("Right after: " + " | ".join(f"{hms(x['ts_start'])[:5]} {x['activity']}" for x in after))
    return "\n".join(lines)


def apply_absence(con, ab: dict, kind: str, s: float, e: float, activity: str, detail: str) -> None:
    """Replace the no-interaction segments inside [s, e] with one labelled segment (brief blips are kept)."""
    s, e = max(s, ab["s"]), min(e, ab["e"])
    if kind == "at_desk" or e - s < 60:
        return
    cat = "sleep" if kind in ("sleep", "nap") else "away"
    for sg in con.execute("SELECT * FROM segments WHERE ts_end>? AND ts_start<? AND category IN ('away','idle at desk','sleep')", (s, e)).fetchall():
        if sg["ts_start"] >= s and sg["ts_end"] <= e:
            con.execute("DELETE FROM segments WHERE id=?", (sg["id"],))
        elif sg["ts_start"] < s:
            con.execute("UPDATE segments SET ts_end=? WHERE id=?", (s, sg["id"]))
        else:
            con.execute("UPDATE segments SET ts_start=? WHERE id=?", (e, sg["id"]))
    keep = con.execute("SELECT ts_start, ts_end FROM segments WHERE ts_end>? AND ts_start<? ORDER BY ts_start", (s, e)).fetchall()
    t = s
    for k in list(keep) + [{"ts_start": e, "ts_end": e}]:
        if k["ts_start"] - t >= 60:
            con.execute("INSERT INTO segments(ts_start,ts_end,category,activity,detail,app) VALUES(?,?,?,?,?,?)",
                        (t, k["ts_start"], cat, activity, detail, ""))
        t = max(t, k["ts_end"])


def label_absences(con, day: str) -> list[tuple[str, float, float, str]]:
    """Ask Claude what each long no-interaction stretch around this day was. Decisions are cached per stretch;
    a stretch is only re-asked when it changed (e.g. it was still ongoing and grew by 30+ min)."""
    ds, de = day_bounds(day)
    lo, hi = ds - 12 * 3600, min(de, time.time())
    absences = find_absences(con, lo, hi)
    if not absences:
        return []
    last_data = con.execute("SELECT MAX(ts) FROM samples").fetchone()[0] or hi
    todo, decided = [], []
    for ab in absences:
        c = con.execute("SELECT * FROM absence_labels WHERE ts_start=?", (ab["s"],)).fetchone()
        if c and abs(c["ts_end"] - ab["e"]) < (1800 if last_data - ab["e"] < 600 else 60):
            decided.append((ab, dict(c)))
        else:
            todo.append(ab)
    if todo:
        hist = con.execute("SELECT ts_start, ts_end, activity FROM segments WHERE category='sleep' AND ts_start>=? AND ts_start<? ORDER BY ts_start",
                           (ds - 7 * 86400, lo)).fetchall()
        prompt = (f"Now: {dt.datetime.now():%A %Y-%m-%d %H:%M}.\n"
                  + (f"About the person: {CFG['aboutMe']}\n" if CFG.get("aboutMe") else "")
                  + ("Their recent sleep: " + "; ".join(f"{dt.datetime.fromtimestamp(h['ts_start']):%a %H:%M}–{dt.datetime.fromtimestamp(h['ts_end']):%H:%M} ({h['activity']})" for h in hist)
                     if hist else "No sleep history yet.") + "\n\n"
                  + "\n\n".join(describe_absence(con, i, ab, last_data) for i, ab in enumerate(todo)))
        res = ask_claude(prompt, ABSENCE_PROMPT, CFG["analysisModel"], absence_schema())
        for r in res.get("absences", []):
            try:
                ab = todo[int(r["id"])]
            except (ValueError, IndexError, KeyError):
                continue
            base = dt.datetime.fromtimestamp(ab["s"]).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
            def when(v, default):
                try:
                    return parse_hms(base, v, ab["s"]) if v else default
                except ValueError:
                    return default
            c = {"ts_start": ab["s"], "ts_end": ab["e"], "kind": r.get("kind", "away"),
                 "s": when(r.get("start"), ab["s"]), "e": when(r.get("end"), ab["e"]),
                 "activity": r.get("activity", ""), "detail": r.get("detail", "")}
            if c["e"] == ab["e"] and last_data - ab["e"] < 600:
                c["e"] = -1  # "until the end of the stretch" — keeps following an ongoing night
            con.execute("INSERT OR REPLACE INTO absence_labels(ts_start,ts_end,kind,s,e,activity,detail,created) VALUES(?,?,?,?,?,?,?,?)",
                        (c["ts_start"], c["ts_end"], c["kind"], c["s"], c["e"], c["activity"], c["detail"], time.time()))
            decided.append((ab, c))
    out = []
    for ab, c in decided:
        e = ab["e"] if c["e"] in (-1, None) or c["e"] > ab["e"] else c["e"]
        apply_absence(con, ab, c["kind"], c["s"], e, c["activity"], c["detail"])
        out.append((c["kind"], max(c["s"], ab["s"]), e, c["activity"]))
    con.commit()
    return out


# ---------------------------------------------------------------- summary

SUMMARY_PROMPT = ("You write a brutally honest, specific daily time report for the person whose timeline this is. Address them as 'you'. "
          "Format (markdown, no title): one short paragraph of the overall story of the day; then '**Where it went**' with 4–7 bullets "
          "of the biggest time sinks with durations; then '**Patterns**' with 2–4 bullets (context switching, fragmentation, "
          "think-vs-type ratio, doomscroll stretches, deep work streaks — only what the data supports). Under 300 words. "
          "Sleep is normal, not lost time: never call the day 'offline' or count sleep against them. Judge only the waking day; "
          "you may mention when they woke up / went to bed. 'away' during the day = genuinely away from the laptop (errands, food, phone).")


def summarize(con: sqlite3.Connection, day: str) -> str | None:
    ds, de = day_bounds(day)
    segs = con.execute("SELECT * FROM segments WHERE ts_start>=? AND ts_start<? ORDER BY ts_start", (ds, de)).fetchall()
    if not segs:
        return None
    totals = collections.Counter()
    for s in segs:
        if s["category"] != "sleep":
            totals[s["category"]] += s["ts_end"] - s["ts_start"]
    sleep = [s for s in segs if s["category"] == "sleep"]
    lines = [f"{hms(s['ts_start'])[:5]}–{hms(s['ts_end'])[:5]} ({fmt_dur(s['ts_end'] - s['ts_start'])}) [{s['category']}] {s['activity']} — {s['detail']}"
             for s in segs if s["category"] != "sleep"]
    tstats = [t for t in thread_stats(con, ds, de) if t["screen"] >= 60 or t["you"]]
    agent_only = sum(1 for t in thread_stats(con, ds, de) if not t["you"] and (t["agent"] or t["scheduled"]))
    threads_txt = ("\n\nT3 coding-agent threads (exact: time the thread was on screen while active, prompts you typed):\n"
                   + "\n".join(f"- “{t['title']}” ({t['project']}): {fmt_dur(t['screen'])} on screen, {t['you']} prompts from you"
                               + (f", {t['agent']} from other agents" if t["agent"] else "") for t in tstats[:15])
                   + (f"\nPlus {agent_only} threads that only agents/schedules prompted (background work)." if agent_only else "")
                   ) if tstats else ""
    prompt = (
        f"Day: {dt.datetime.strptime(day, '%Y-%m-%d'):%A %Y-%m-%d}"
        + (f" (it is {dt.datetime.now():%H:%M} now — the day is still in progress)" if day == today() else "") + "\n"
        + ("Sleep: " + ", ".join(f"{hms(s['ts_start'])[:5]}–{hms(s['ts_end'])[:5]} ({fmt_dur(s['ts_end'] - s['ts_start'])})" for s in sleep) + "\n"
           if sleep else "")
        + "Awake totals: " + ", ".join(f"{k} {fmt_dur(v)}" for k, v in totals.most_common()) + "\n\n"
        + "Timeline (awake):\n" + "\n".join(lines) + threads_txt
    )
    system = SUMMARY_PROMPT
    text = ask_claude(prompt, system, CFG["summaryModel"])
    con.execute("INSERT OR REPLACE INTO daily_summaries VALUES(?,?,?)", (day, text, time.time()))
    con.commit()
    return text


# ---------------------------------------------------------------- report

def domain(url: str) -> str:
    m = re.match(r"^[a-z]+://(?:www\.)?([^/:?#]+)", url or "")
    return m.group(1) if m else ""


def fallback_segments(con, ds, de) -> list[dict]:
    """No AI yet: group consecutive samples by app/site, mark idle stretches."""
    idle_thr = CFG["idleThresholdSeconds"]
    segs: list[dict] = []
    for s in con.execute("SELECT ts, app, url, idle, locked FROM samples WHERE ts>=? AND ts<? ORDER BY ts", (ds, de)):
        idle = s["locked"] or (s["idle"] or 0) >= idle_thr
        label = "away" if idle else (domain(s["url"]) or s["app"] or "?")
        cat = "away" if idle else "other"
        if segs and segs[-1]["activity"] == label and s["ts"] - segs[-1]["e"] <= 90:
            segs[-1]["e"] = s["ts"] + 1
        else:
            segs.append({"s": s["ts"], "e": s["ts"] + 1, "c": cat, "activity": label, "detail": "", "app": label})
    merged: list[dict] = []
    for g in segs:  # fold blips < 20s into the previous segment
        if merged and g["e"] - g["s"] < 20:
            merged[-1]["e"] = g["e"]
        else:
            merged.append(g)
    return merged


def deep_covered(con, ds: float, de: float) -> list[tuple[float, float]]:
    """merged [start, end) ranges inside [ds, de) that a cloud deep-analysis run has covered"""
    out = []
    for a, b in con.execute("SELECT ts_start, ts_end FROM deep_runs WHERE ts_end>? AND ts_start<? ORDER BY ts_start", (ds, de)):
        a, b = max(a, ds), min(b, de)
        if out and a <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out


def merged_segments(con, ds: float, de: float) -> list[dict]:
    """the quick local timeline, with every range the deep cloud analysis covered replaced by its segments"""
    cov = deep_covered(con, ds, de)
    out = []
    for r in con.execute("SELECT * FROM segments WHERE ts_start>=? AND ts_start<? ORDER BY ts_start", (ds, de)):
        pieces = [(r["ts_start"], r["ts_end"])]
        for a, b in cov:  # clip the quick segment around covered ranges
            pieces = [q for (x, y) in pieces for q in ((x, min(y, a)), (max(x, b), y)) if q[1] - q[0] >= 1]
        out += [{"ts_start": x, "ts_end": y, **{k: r[k] for k in ("category", "activity", "detail", "app")}} for x, y in pieces]
    for a, b in cov:
        out += [dict(r) for r in con.execute("SELECT * FROM deep_segments WHERE ts_start>=? AND ts_start<? ORDER BY ts_start", (a, b))]
    return sorted(out, key=lambda x: x["ts_start"])


def day_data(con: sqlite3.Connection, day: str, deep: bool = True) -> dict:
    ds, de = day_bounds(day)
    rows = merged_segments(con, ds, de) if deep else \
        con.execute("SELECT * FROM segments WHERE ts_start>=? AND ts_start<? ORDER BY ts_start", (ds, de)).fetchall()
    ai = bool(rows)
    segs = ([{"s": r["ts_start"], "e": r["ts_end"], "c": r["category"], "activity": r["activity"], "detail": r["detail"], "app": r["app"]}
             for r in rows] if ai else fallback_segments(con, ds, de))

    idle_thr = CFG["idleThresholdSeconds"]
    minutes = [[0, 0, 0, 0] for _ in range(1440)]  # active seconds, keys, mic-loud seconds, sys-loud seconds
    apps = collections.Counter()
    first = last = None
    for s in con.execute("SELECT * FROM samples WHERE ts>=? AND ts<? ORDER BY ts", (ds, de)):
        mi = int((s["ts"] - ds) // 60)
        if not 0 <= mi < 1440:
            continue
        first = first or s["ts"]
        last = s["ts"]
        active = not s["locked"] and (s["idle"] or 0) < idle_thr
        if active:
            minutes[mi][0] += 1
            apps[domain(s["url"]) or s["app"] or "?"] += 1
        minutes[mi][1] += s["keys"] or 0
        if s["mic_db"] is not None and s["mic_db"] >= CFG["micSpeechThresholdDb"]:
            minutes[mi][2] += 1
        if s["sys_db"] is not None and s["sys_db"] >= CFG["sysSoundThresholdDb"]:
            minutes[mi][3] += 1

    shots = [[r["ts"], "../" + r["path"], r["app"] or "", r["title"] or ""] for r in
             con.execute("SELECT ts, path, app, title FROM screenshots WHERE ts>=? AND ts<? ORDER BY ts", (ds, de))]
    trans = [[r["ts_start"], r["ts_end"], r["source"], r["text"], voice_label(r["vname"], r["speaker_id"])] for r in
             con.execute("SELECT t.*, v.name AS vname FROM transcripts t LEFT JOIN voices v ON v.id=t.speaker_id "
                         "WHERE t.ts_start>=? AND t.ts_start<? ORDER BY t.ts_start", (ds, de))]
    audio = [[r["ts_start"], r["ts_end"] or r["ts_start"] + 300, r["source"], "../" + r["path"]] for r in
             con.execute("SELECT * FROM audio_chunks WHERE ts_start>=? AND ts_start<? ORDER BY ts_start", (ds, de))]
    summ = (deep and con.execute("SELECT text FROM deep_summaries WHERE day=?", (day,)).fetchone()) or \
        con.execute("SELECT text FROM daily_summaries WHERE day=?", (day,)).fetchone()

    d = dt.datetime.strptime(day, "%Y-%m-%d")
    data = {
        "day": day,
        "title": f"{d:%A, %B} {d.day}",
        "dayStart": ds,
        "ai": ai,
        "segments": segs,
        "minutes": minutes,
        "apps": apps.most_common(15),
        "shots": shots,
        "transcripts": trans,
        "audio": audio,
        "summary": summ["text"] if summ else "",
        "first": first,
        "last": last,
        "categories": CATEGORIES,
        "prev": (d - dt.timedelta(days=1)).strftime("%Y-%m-%d"),
        "next": (d + dt.timedelta(days=1)).strftime("%Y-%m-%d"),
        "generated": time.time(),
        "cloudViewer": f"{CFG['cloudUrl'].rstrip('/')}/?day={day}" if CFG.get("cloudUrl") else "",
    }
    return data


def report(con: sqlite3.Connection, day: str) -> Path:
    data = day_data(con, day)
    template = (Path(__file__).resolve().parent / "report.html").read_text()
    out = ROOT / "reports" / f"{day}.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    out.write_text(template.replace("/*__DATA__*/null", payload).replace("__TITLE__", html.escape(data["title"])))
    return out


# ---------------------------------------------------------------- misc commands

def status(con: sqlite3.Connection) -> None:
    ds, de = day_bounds(today())
    last = con.execute("SELECT MAX(ts) FROM samples").fetchone()[0]
    age = time.time() - last if last else None
    print(f"data dir   : {ROOT}")
    print(f"recorder   : {'RUNNING' if age is not None and age < 10 else 'not recording'}"
          + (f" (last sample {fmt_dur(age)} ago)" if age is not None else ""))
    q = lambda sql, *a: con.execute(sql, a).fetchone()[0]
    print(f"today      : {fmt_dur(q('SELECT COUNT(*) FROM samples WHERE ts>=?', ds))} logged, "
          f"{q('SELECT COUNT(*) FROM screenshots WHERE ts>=?', ds)} screenshots, "
          f"{q('SELECT COUNT(*) FROM audio_chunks WHERE ts_start>=?', ds)} audio chunks, "
          f"{q('SELECT COUNT(*) FROM transcripts WHERE ts_start>=?', ds)} transcript lines, "
          f"{q('SELECT COUNT(*) FROM segments WHERE ts_start>=?', ds)} timeline segments")
    print(f"pending    : {q('SELECT COUNT(*) FROM audio_chunks WHERE transcribed=0 AND ts_end IS NOT NULL')} chunks to transcribe")
    ag = con.execute("SELECT host, COUNT(*) FROM agent_events WHERE ts>=? AND kind='prompt' GROUP BY host", (ds,)).fetchall()
    who = dict(con.execute("SELECT COALESCE(sender,'unknown'), COUNT(*) FROM agent_events WHERE ts>=? AND kind='prompt' GROUP BY 1", (ds,)).fetchall())
    print(f"agents     : {sum(n for _, n in ag)} prompts today" + (" (" + ", ".join(f"{h} {n}" for h, n in ag) + ")" if ag else "")
          + (f"; from you {who.get('you', 0)}, agents {who.get('agent', 0)}, schedules {who.get('scheduled', 0)}, sender unknown {who.get('unknown', 0)}" if who else ""))
    pl = con.execute("SELECT MAX(ts), COUNT(*) FROM phone_events WHERE ts>=?", (ds,)).fetchone()
    if pl[1] or CFG.get("phoneDeviceId"):
        print(f"phone      : {pl[1]} events today" + (f", latest {fmt_dur(time.time() - pl[0])} ago" if pl[0] else "")
              + f"; {q('SELECT COUNT(*) FROM audio_chunks WHERE source=? AND ts_start>=?', 'phone', ds)} audio chunks")
    engine = "Parakeet Ultra + Nemotron 3 speakers" if CFG["transcriber"] == "fluidaudio" and Path(CFG["asrBinary"]).expanduser().exists() else "whisper"
    me = con.execute("SELECT COUNT(*) FROM voices WHERE lower(name)='me'").fetchone()[0]
    print(f"speech     : {engine}; {q('SELECT COUNT(*) FROM voices')} voices known"
          + ("" if me else " — run `lifelog enroll` so it knows which voice is you"))
    total = sum(f.stat().st_size for f in (ROOT / "media").rglob("*") if f.is_file()) if (ROOT / "media").exists() else 0
    print(f"disk       : media {total / 1e9:.2f} GB, db {DB_PATH.stat().st_size / 1e6:.0f} MB, free {shutil.disk_usage(ROOT).free / 1e9:.0f} GB")
    up = con.execute("SELECT COUNT(*), COALESCE(SUM(bytes),0), MAX(uploaded) FROM uploads").fetchone()
    net = ROOT / ".network.json"
    netinfo = json.loads(net.read_text()) if net.exists() else {}
    print(f"cloud      : {up[0]} objects / {up[1] / 1e9:.2f} GB in R2 bucket '{CFG['r2Bucket']}'"
          + (f", last upload {fmt_dur(time.time() - up[2])} ago" if up[2] else "")
          + (f"; viewer {CFG['cloudUrl']}" if CFG.get("cloudUrl") else "; Worker not deployed (cloud/deploy.sh)"))
    if netinfo:
        print(f"network    : {'online' if netinfo.get('online') else 'offline'}{' (expensive — uploads paused)' if netinfo.get('expensive') and not CFG['syncOnExpensiveNetwork'] else ''}")
    log = ROOT / "logs/recorder.log"
    if log.exists():
        tail = log.read_text(errors="replace").splitlines()[-5:]
        print("recorder log tail:\n  " + "\n  ".join(tail))


def search(con: sqlite3.Connection, query: str, limit: int = 40) -> None:
    fts = " ".join(f'"{w}"' for w in query.split())
    hits = []
    for r in con.execute("SELECT s.ts, s.app, s.title, snippet(ocr_fts, 0, '[', ']', '…', 12) AS snip FROM ocr_fts "
                         "JOIN screenshots s ON s.id=ocr_fts.rowid WHERE ocr_fts MATCH ? ORDER BY s.ts DESC LIMIT ?", (fts, limit)):
        hits.append((r["ts"], f"screen  {r['app']} — {r['title'][:50]}: {r['snip']}"))
    for r in con.execute("SELECT t.ts_start, t.source, snippet(transcript_fts, 0, '[', ']', '…', 16) AS snip FROM transcript_fts "
                         "JOIN transcripts t ON t.id=transcript_fts.rowid WHERE transcript_fts MATCH ? ORDER BY t.ts_start DESC LIMIT ?", (fts, limit)):
        hits.append((r["ts_start"], f"heard({r['source']})  {r['snip']}"))
    for r in con.execute("SELECT ts_start, activity, detail FROM segments WHERE activity LIKE ? OR detail LIKE ? ORDER BY ts_start DESC LIMIT ?",
                         (f"%{query}%", f"%{query}%", limit)):
        hits.append((r["ts_start"], f"timeline  {r['activity']} — {r['detail'][:80]}"))
    for ts, line in sorted(hits, reverse=True)[:limit]:
        print(f"{dt.datetime.fromtimestamp(ts):%Y-%m-%d %H:%M:%S}  {line}")
    if not hits:
        print("no matches")


def prune(con: sqlite3.Connection, keep_days: int) -> None:
    cutoff = (dt.date.today() - dt.timedelta(days=keep_days)).isoformat()
    media = ROOT / "media"
    freed = 0
    for d in sorted(media.iterdir()) if media.exists() else []:
        if d.is_dir() and d.name < cutoff:
            freed += sum(f.stat().st_size for f in d.rglob("*") if f.is_file())
            shutil.rmtree(d)
            print(f"  removed media for {d.name}")
    print(f"freed {freed / 1e9:.2f} GB (text, OCR, transcripts and timeline are kept)")


# ---------------------------------------------------------------- cloud sync: R2 (via wrangler) + Worker API

class Lock:
    """non-blocking file lock so launchd runs never overlap"""
    def __init__(self, name: str):
        import fcntl
        self.f = open(ROOT / f".{name}.lock", "w")
        try:
            fcntl.flock(self.f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.ok = True
        except OSError:
            self.ok = False


def wrangler(args: list[str], timeout: int = 1800) -> subprocess.CompletedProcess:
    w = which("wrangler")
    if not w:
        raise RuntimeError("wrangler not found (npm i -g wrangler)")
    env = {**os.environ, "WRANGLER_SEND_METRICS": "false", "WRANGLER_LOG": "warn"}
    return subprocess.run([w, *args], capture_output=True, text=True, timeout=timeout, env=env, cwd=tempfile.gettempdir())


def r2_target() -> list[str]:
    return ["--local", "--persist-to", CFG["wranglerLocal"]] if CFG.get("wranglerLocal") else ["--remote"]


R2_HTTP_MAX = 95_000_000  # Workers accept request bodies up to 100 MB; bigger files go through wrangler


def r2_put(key: str, path: Path, ctype: str) -> None:
    """through the Worker's PUT /api/object (one HTTPS request, no Node process per file); wrangler for big files,
    local test mode, or if the Worker refuses"""
    size = path.stat().st_size
    if CFG.get("cloudUrl") and not CFG.get("wranglerLocal") and size <= R2_HTTP_MAX:
        import urllib.parse, urllib.request
        try:
            with open(path, "rb") as f:
                req = urllib.request.Request(CFG["cloudUrl"].rstrip("/") + "/api/object/" + urllib.parse.quote(key), data=f,
                                             method="PUT", headers={"authorization": f"Bearer {CFG['cloudToken']}",
                                                                    "content-type": ctype, "content-length": str(size),
                                                                    "user-agent": "lifelog-cli"})
                with urllib.request.urlopen(req, timeout=600) as r:
                    if json.loads(r.read()).get("size") == size:
                        return
        except Exception as e:  # e.g. an older Worker without /api/object: fall back
            print(f"  (direct upload of {key} failed: {e}; using wrangler)")
    p = wrangler(["r2", "object", "put", f"{CFG['r2Bucket']}/{key}", "--file", str(path), "--content-type", ctype, *r2_target()])
    if p.returncode != 0:
        raise RuntimeError(f"wrangler put {key} failed: {(p.stderr or p.stdout).strip()[-400:]}")


def r2_get(key: str, dest: Path) -> None:
    p = wrangler(["r2", "object", "get", f"{CFG['r2Bucket']}/{key}", "--file", str(dest), *r2_target()])
    if p.returncode != 0:
        raise RuntimeError(f"wrangler get {key} failed: {(p.stderr or p.stdout).strip()[-400:]}")


def r2_delete(key: str) -> None:
    wrangler(["r2", "object", "delete", f"{CFG['r2Bucket']}/{key}", *r2_target()])


def network_ok() -> tuple[bool, str]:
    if CFG.get("wranglerLocal"):
        return True, "local test mode"
    f = ROOT / ".network.json"
    if f.exists():
        try:
            info = json.loads(f.read_text())
            if not info.get("online"):
                return False, "offline"
            if (info.get("expensive") or info.get("constrained")) and not CFG["syncOnExpensiveNetwork"]:
                return False, "on an expensive/low-data network (hotspot) — skipping; set syncOnExpensiveNetwork to override"
        except (json.JSONDecodeError, OSError):
            pass
    import socket
    try:
        socket.create_connection(("api.cloudflare.com", 443), timeout=4).close()
        return True, "online"
    except OSError:
        return False, "offline"


def api(path: str, body: dict | None = None, method: str = "POST") -> dict:
    import urllib.request
    url = CFG["cloudUrl"].rstrip("/") + path
    data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "authorization": f"Bearer {CFG['cloudToken']}", "content-type": "application/json", "user-agent": "lifelog-cli"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def bundle_limit() -> int:
    """bundles that fit one PUT through the Worker; a bigger one goes through `wrangler`, a Node process that costs
    ~3 s CPU and ~380 MB per 150 MB bundle — every 10 minutes"""
    direct = bool(CFG.get("cloudUrl")) and not CFG.get("wranglerLocal")
    return min(CFG["bundleMaxBytes"], R2_HTTP_MAX - 1_000_000) if direct else CFG["bundleMaxBytes"]


def make_tar(files: list[tuple[Path, str]], out: Path) -> list[list]:
    """uncompressed tar (JPEG/AAC are already compressed); returns [[name, data_offset, size], ...]"""
    import tarfile
    with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as tf:
        for path, name in files:
            tf.add(path, arcname=name, recursive=False)
    with tarfile.open(out, "r") as tf:
        return [[m.name, m.offset_data, m.size] for m in tf.getmembers() if m.isfile()]


def split_by_size(files: list[Path], max_bytes: int) -> list[list[Path]]:
    parts, cur, size = [], [], 0
    for f in files:
        sz = f.stat().st_size
        if cur and size + sz > max_bytes:
            parts.append(cur)
            cur, size = [], 0
        cur.append(f)
        size += sz
    if cur:
        parts.append(cur)
    return parts


def screen_slot(name: str) -> str | None:
    """HHMMSS_mmm.jpg → 'HHM0' (10-minute slot)"""
    m = re.match(r"^(\d{2})(\d{2})\d{2}", name)
    return f"{m.group(1)}{int(m.group(2)) // 10 * 10:02d}" if m else None


def local_media_days() -> list[str]:
    media = ROOT / "media"
    return sorted(d.name for d in media.iterdir() if d.is_dir() and re.fullmatch(r"\d{4}-\d{2}-\d{2}", d.name)) if media.exists() else []


def uploaded_index(con, days: list[str]) -> tuple[dict, dict]:
    """which files of these days are already in R2. Only the days asked for: every bundle's file list is a few hundred
    entries of JSON, and parsing all of history (35 MB and growing ~5 MB a day) took most of each sync's CPU."""
    done: dict[tuple, set] = collections.defaultdict(set)
    parts: dict[tuple, int] = collections.defaultdict(int)
    for r in con.execute(f"SELECT kind, day, slot, files FROM uploads WHERE kind IN ('screens','audio') AND day IN ({','.join('?' * len(days))})",
                         days):
        k = (r["kind"], r["day"], r["slot"])
        done[k].update(f[0] for f in json.loads(r["files"]))
        parts[k] += 1
    return done, parts


def upload_bundle(con, kind: str, day: str, slot: str, part: int, entries: list[tuple[Path, list]]) -> int:
    """entries: (file, extra-metadata). Uploads one tar, records it. Returns bytes."""
    device = CFG["deviceId"]
    key = f"{device}/{kind}/{day}/{slot}-{part}.tar"
    with tempfile.TemporaryDirectory() as tmp:
        tar = Path(tmp) / "b.tar"
        members = make_tar([(f, f.name) for f, _ in entries], tar)
        meta = {f.name: extra for f, extra in entries}
        files = [[name, off, size, *meta[name]] for name, off, size in members]
        nbytes = tar.stat().st_size
        r2_put(key, tar, "application/x-tar")
    con.execute("INSERT OR REPLACE INTO uploads VALUES(?,?,?,?,?,?,?,0)", (key, kind, day, slot, nbytes, json.dumps(files), time.time()))
    con.commit()
    return nbytes


def upload_media(con, now: float) -> tuple[int, int]:
    media = ROOT / "media"
    if not media.exists():
        return 0, 0
    days = local_media_days()
    done, parts = uploaded_index(con, days)
    n_bundles = n_bytes = 0
    for daydir in [media / d for d in days]:
        day = daydir.name
        ds, de = day_bounds(day)
        # screenshots → 10-minute slots
        groups: dict[str, list[Path]] = collections.defaultdict(list)
        for f in (daydir / "screens").glob("*.jpg") if (daydir / "screens").exists() else []:
            if screen_slot(f.name):
                groups[screen_slot(f.name)].append(f)
        for slot, files in sorted(groups.items()):
            slot_start = ds + int(slot[:2]) * 3600 + int(slot[2:]) * 60
            if slot_start + 600 > now - 90:
                continue  # still being written
            k = ("screens", day, slot)
            new = sorted(f for f in files if f.name not in done[k])
            if not new:
                continue
            meta = {Path(r["path"]).name: [r["ts"], r["app"] or "", (r["title"] or "")[:120]] for r in con.execute(
                "SELECT ts, path, app, title FROM screenshots WHERE ts>=? AND ts<?", (slot_start - 1, slot_start + 601))}
            for chunk in split_by_size(new, bundle_limit()):
                entries = [(f, meta.get(f.name, [0, "", ""])) for f in chunk]
                n_bytes += upload_bundle(con, "screens", day, slot, parts[k], entries)
                parts[k] += 1
                n_bundles += 1
                print(f"  ↑ screens {day} {slot}: {len(chunk)} frames")
        # audio → hourly bundles (only when every chunk that started in the hour is closed)
        hours: dict[str, list] = collections.defaultdict(list)
        for r in con.execute("SELECT * FROM audio_chunks WHERE ts_start>=? AND ts_start<? AND source!='phone' ORDER BY ts_start", (ds, de)):
            hours[f"{dt.datetime.fromtimestamp(r['ts_start']).hour:02d}"].append(r)
        for hour, rows in sorted(hours.items()):
            if any(r["ts_end"] is None for r in rows) or ds + (int(hour) + 1) * 3600 > now - 60:
                continue
            k = ("audio", day, hour)
            entries = [(ROOT / r["path"], [r["ts_start"], r["ts_end"], r["source"]]) for r in rows
                       if (ROOT / r["path"]).exists() and Path(r["path"]).name not in done[k]]
            if not entries:
                continue
            n_bytes += upload_bundle(con, "audio", day, hour, parts[k], entries)
            parts[k] += 1
            n_bundles += 1
            print(f"  ↑ audio {day} {hour}:00: {len(entries)} chunks")
    return n_bundles, n_bytes


def local_tz() -> str:
    try:
        return os.path.realpath("/etc/localtime").split("zoneinfo/", 1)[1]
    except (IndexError, OSError):
        return time.tzname[0]


RAW_TABLES = ("samples", "screenshots", "transcripts", "events", "agent_events", "phone_events")


def export_hour(con, start: float, end: float) -> dict:
    """everything recorded in [start, end) as plain rows — the cloud analysis rebuilds a local DB from these"""
    tables = {}
    for t in RAW_TABLES:
        col = "ts_start" if t == "transcripts" else "ts"
        cur = con.execute(f"SELECT * FROM {t} WHERE {col}>=? AND {col}<? ORDER BY {col}", (start, end))
        cols = [c[0] for c in cur.description]
        rows = [list(r) for r in cur.fetchall()]
        if t == "screenshots":  # the image itself is in R2 (bundles); keep just its file name
            i = cols.index("path")
            for r in rows:
                r[i] = Path(r[i] or "").name
        tables[t] = {"cols": cols, "rows": rows}
    ae, sm = tables["agent_events"], tables["samples"]
    si, fi, ui = ae["cols"].index("session"), ae["cols"].index("from_thread"), sm["cols"].index("url")
    threads = {r[si] for r in ae["rows"]} | {r[fi] for r in ae["rows"]}
    threads |= {m.group(2) for r in sm["rows"] for m in [T3_URL.match(r[ui] or "")] if m}
    threads.discard(None)
    cur = con.execute(f"SELECT * FROM t3_threads WHERE id IN ({','.join('?' * len(threads))})", tuple(threads)) if threads else None
    tables["t3_threads"] = {"cols": [c[0] for c in cur.description] if cur else [], "rows": [list(r) for r in cur.fetchall()] if cur else []}
    # only the voices heard this hour: with the whole table, every new voice changed every hour and re-uploaded days of data
    tr = tables["transcripts"]; vi = tr["cols"].index("speaker_id")
    vids = sorted({r[vi] for r in tr["rows"] if r[vi] is not None})
    tables["voices"] = {"cols": ["id", "name"], "rows": [list(r) for r in con.execute(
        f"SELECT id, name FROM voices WHERE id IN ({','.join('?' * len(vids))}) ORDER BY id", vids)]} if vids else {"cols": ["id", "name"], "rows": []}
    return {"v": 1, "device": CFG["deviceId"], "tz": local_tz(), "start": start, "end": end, "tables": tables}


def upload_raw(con, now: float) -> tuple[int, int]:
    """upload each hour of the last 3 days as raw/<day>/<HH>.json.gz whenever its content changed
    (the current hour too, so the cloud analysis sees fresh data; later transcripts / agent replies re-upload it)"""
    import gzip, hashlib
    n = size = 0
    regs = []
    for i in (2, 1, 0):
        day = (dt.date.today() - dt.timedelta(days=i)).isoformat()
        ds, _ = day_bounds(day)
        for h in range(24):
            a = ds + h * 3600
            if a > now:
                break
            if not (con.execute("SELECT 1 FROM samples WHERE ts>=? AND ts<? LIMIT 1", (a, a + 3600)).fetchone()
                    or con.execute("SELECT 1 FROM phone_events WHERE ts>=? AND ts<? LIMIT 1", (a, a + 3600)).fetchone()):
                continue
            up = con.execute("SELECT uploaded FROM raw_uploads WHERE day=? AND hour=?", (day, f"{h:02d}")).fetchone()
            late = up and con.execute("SELECT 1 FROM phone_events WHERE ts>=? AND ts<? AND received>? LIMIT 1",
                                      (a, a + 3600, up[0])).fetchone()
            if now - a > 26 * 3600 and up and not late:
                continue  # settled long ago (unless the phone delivered something for it since)
            data = export_hour(con, a, a + 3600)
            blob = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode()
            digest = hashlib.sha1(blob).hexdigest()
            hour = f"{h:02d}"
            row = con.execute("SELECT hash FROM raw_uploads WHERE day=? AND hour=?", (day, hour)).fetchone()
            if row and row["hash"] == digest:
                continue
            key = f"{CFG['deviceId']}/raw/{day}/{hour}.json.gz"
            with tempfile.TemporaryDirectory() as tmp:
                f = Path(tmp) / "h.json.gz"
                f.write_bytes(gzip.compress(blob, 6))
                r2_put(key, f, "application/gzip")
                b = f.stat().st_size
            last = max([r[0] for r in data["tables"]["samples"]["rows"]]
                       + [r[2] for r in data["tables"]["phone_events"]["rows"]], default=a)
            regs.append({"day": day, "hour": hour, "key": key, "start": a, "end": a + 3600, "last_ts": last, "bytes": b, "tz": data["tz"]})
            con.execute("INSERT OR REPLACE INTO raw_uploads VALUES(?,?,?,?,?,?)", (day, hour, key, digest, b, time.time()))
            con.commit()
            n, size = n + 1, size + b
    for i in range(0, len(regs), 50):
        api("/api/ingest", {"device": CFG["deviceId"], "raw": regs[i:i + 50]})
    return n, size


def pull_phone(con) -> tuple[int, int]:
    """bring the iPhone's events (and its audio chunks, for transcription) from the cloud into the local DB"""
    import urllib.parse, urllib.request
    dev = CFG.get("phoneDeviceId")
    if not dev:
        return 0, 0
    # phone audio is already in R2: drop local copies once transcribed
    for r in con.execute("SELECT path FROM audio_chunks WHERE source='phone' AND transcribed!=0").fetchall():
        (ROOT / r["path"]).unlink(missing_ok=True)
    row = con.execute("SELECT last FROM agent_sync WHERE source='phone'").fetchone()
    seq = int(row[0]) if row else 0
    n_ev = n_audio = 0
    while True:
        res = api(f"/api/phone/since?device={dev}&seq={seq}", method="GET")
        evs = res.get("events", [])
        for e in evs:
            con.execute("INSERT OR IGNORE INTO phone_events(id, seq, ts, kind, data, received) VALUES(?,?,?,?,?,?)",
                        (e["id"], e["seq"], e["ts"], e["kind"], json.dumps(e.get("data") or {}), e.get("received")))
            d = e.get("data") or {}
            if e["kind"] == "audio" and d.get("key") and not d.get("silent"):
                rel = f"phone/{Path(d['key']).name}"
                dest = ROOT / rel
                if not con.execute("SELECT 1 FROM audio_chunks WHERE path=?", (rel,)).fetchone():
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    req = urllib.request.Request(CFG["cloudUrl"].rstrip("/") + "/api/raw/" + urllib.parse.quote(d["key"], safe=""),
                                                 headers={"authorization": f"Bearer {CFG['cloudToken']}", "user-agent": "lifelog-cli"})
                    with urllib.request.urlopen(req, timeout=300) as r, open(dest, "wb") as f:
                        shutil.copyfileobj(r, f)
                    con.execute("INSERT INTO audio_chunks(source, ts_start, ts_end, path, peak_db) VALUES('phone',?,?,?,?)",
                                (d.get("start", e["ts"]), d.get("end", e["ts"] + 300), rel, d.get("peak_db")))
                    n_audio += 1
            seq = max(seq, e["seq"])
            n_ev += 1
        con.execute("INSERT OR REPLACE INTO agent_sync(source,last) VALUES('phone',?)", (seq,))
        con.commit()
        if not res.get("more"):
            break
    return n_ev, n_audio


def pull_deep(con) -> int:
    """bring the cloud's deep-analysis runs into the local DB (reports and the menu bar then show them)"""
    since = con.execute("SELECT MAX(created) FROM deep_runs").fetchone()[0] or 0
    res = api(f"/api/deep/since?device={CFG['deviceId']}&since={since}", method="GET")
    for run in res.get("runs", []):
        con.execute("INSERT OR REPLACE INTO deep_runs VALUES(?,?,?,?,?)", (run["id"], run["ts_start"], run["ts_end"], run["created"], run.get("note")))
        con.execute("DELETE FROM deep_segments WHERE ts_start>=? AND ts_start<?", (run["ts_start"], run["ts_end"]))
        con.executemany("INSERT OR REPLACE INTO deep_segments VALUES(?,?,?,?,?,?,?)",
                        [(g["s"], g["e"], g["c"], g["activity"], g.get("detail"), g.get("app"), run["id"]) for g in run["segments"]])
    for sm in res.get("summaries", []):
        con.execute("INSERT OR REPLACE INTO deep_summaries VALUES(?,?,?)", (sm["day"], sm["text"], sm["updated"]))
    con.commit()
    return len(res.get("runs", []))


def register_bundles(con) -> int:
    rows = con.execute("SELECT * FROM uploads WHERE registered=0 AND kind IN ('screens','audio')").fetchall()
    for i in range(0, len(rows), 8):
        batch = rows[i:i + 8]
        api("/api/ingest", {"device": CFG["deviceId"], "deviceName": os.uname().nodename, "deviceKind": "mac", "bundles": [
            {"key": r["key"], "kind": r["kind"], "day": r["day"], "slot": r["slot"], "bytes": r["bytes"], "files": json.loads(r["files"])}
            for r in batch]})
        con.executemany("UPDATE uploads SET registered=1 WHERE key=?", [(r["key"],) for r in batch])
        con.commit()
    return len(rows)


def push_days(con, days: list[str]) -> int:
    import hashlib
    pushed = 0
    for day in days:
        d = day_data(con, day, deep=False)  # the Worker merges in the deep results itself
        if not d["first"]:
            continue
        payload = {"day": day, "day_start": d["dayStart"], "first": d["first"], "last": d["last"], "minutes": d["minutes"],
                   "apps": d["apps"], "segments": d["segments"], "transcripts": d["transcripts"], "summary": d["summary"]}
        h = hashlib.sha1(json.dumps(payload, sort_keys=True).encode()).hexdigest()
        row = con.execute("SELECT hash FROM cloud_pushes WHERE day=?", (day,)).fetchone()
        if row and row["hash"] == h:
            continue
        api("/api/ingest", {"device": CFG["deviceId"], "deviceName": os.uname().nodename, "deviceKind": "mac", "days": [payload]})
        con.execute("INSERT OR REPLACE INTO cloud_pushes VALUES(?,?,?)", (day, h, time.time()))
        con.commit()
        pushed += 1
        print(f"  ↑ timeline {day}: {len(payload['segments'])} segments, {len(payload['transcripts'])} transcript lines")
    return pushed


def backup_db(con) -> None:
    import gzip
    last = con.execute("SELECT MAX(uploaded) FROM uploads WHERE kind='db'").fetchone()[0]
    if last and time.time() - last < CFG["dbBackupEveryDays"] * 86400 - 600:
        return
    key = f"{CFG['deviceId']}/db/lifelog-{dt.datetime.now():%Y-%m-%d_%H%M}.db.gz"
    with tempfile.TemporaryDirectory() as tmp:
        snap = Path(tmp) / "snap.db"
        dst = sqlite3.connect(snap)
        con.backup(dst)
        dst.close()
        gz = Path(tmp) / "snap.db.gz"
        with open(snap, "rb") as fi, gzip.open(gz, "wb", compresslevel=6) as fo:
            shutil.copyfileobj(fi, fo, 1 << 20)
        r2_put(key, gz, "application/gzip")
        size = gz.stat().st_size
    con.execute("INSERT OR REPLACE INTO uploads VALUES(?,?,?,?,?,?,?,1)", (key, "db", today(), "", size, "[]", time.time()))
    con.commit()
    print(f"  ↑ database backup {size / 1e6:.0f} MB")
    old = con.execute("SELECT key FROM uploads WHERE kind='db' ORDER BY uploaded DESC LIMIT -1 OFFSET ?", (CFG["dbBackupsToKeep"],)).fetchall()
    for r in old:
        r2_delete(r["key"])
        con.execute("DELETE FROM uploads WHERE key=?", (r["key"],))
    con.commit()


def free_local_media(con) -> None:
    keep = CFG["localMediaKeepDays"]
    if keep is None or keep < 0:
        return
    cutoff = (dt.date.today() - dt.timedelta(days=keep)).isoformat()
    done, _ = uploaded_index(con, [d for d in local_media_days() if d < cutoff])
    registered = {r[0] for r in con.execute("SELECT key FROM uploads WHERE registered=1")}
    unregistered = con.execute("SELECT COUNT(*) FROM uploads WHERE registered=0 AND kind IN ('screens','audio')").fetchone()[0]
    if unregistered and CFG.get("cloudUrl"):
        return  # wait until the Worker knows about every bundle
    _ = registered
    for daydir in [ROOT / "media" / d for d in local_media_days() if d < cutoff]:
        day = daydir.name
        missing = 0
        for f in (daydir / "screens").glob("*.jpg") if (daydir / "screens").exists() else []:
            if f.name not in done[("screens", day, screen_slot(f.name) or "")]:
                missing += 1
        audio_names = set().union(*[v for (k, d, _), v in done.items() if k == "audio" and d == day]) if done else set()
        for f in (daydir / "audio").glob("*.m4a") if (daydir / "audio").exists() else []:
            if f.name not in audio_names:
                missing += 1
        if missing:
            print(f"  keeping media for {day}: {missing} file(s) not uploaded yet")
            continue
        freed = sum(f.stat().st_size for f in daydir.rglob("*") if f.is_file())
        shutil.rmtree(daydir)
        print(f"  freed {freed / 1e9:.2f} GB locally for {day} (it's in R2; `lifelog restore --day {day}` brings it back)")


def sync(con, all_days: bool = False) -> None:
    lock = Lock("sync")
    if not lock.ok:
        print("sync already running")
        return
    ok, why = network_ok()
    if not ok:
        print(f"sync skipped: {why}")
        return
    if not which("wrangler"):
        print("sync skipped: wrangler not installed", file=sys.stderr)
        return
    t0 = time.time()
    try:
        close_orphan_chunks(con)
        n, b = upload_media(con, time.time())
        print(f"media: {n} bundle(s), {b / 1e6:.1f} MB uploaded")
        if CFG.get("cloudUrl") and CFG.get("cloudToken"):
            try:
                ne, na = pull_phone(con)
                if ne:
                    print(f"phone: {ne} event(s), {na} audio chunk(s) pulled")
            except Exception as e:
                print(f"phone pull failed: {e}", file=sys.stderr)
            n, b = upload_raw(con, time.time())
            if n:
                print(f"raw data: {n} hour(s), {b / 1e3:.0f} kB uploaded")
            register_bundles(con)
            if all_days:
                days = [r[0] for r in con.execute("SELECT DISTINCT date(ts,'unixepoch','localtime') FROM samples ORDER BY 1")]
            else:
                days = [(dt.date.today() - dt.timedelta(days=i)).isoformat() for i in (2, 1, 0)]
            push_days(con, days)
            got = pull_deep(con)
            if got:
                print(f"deep analysis: {got} new run(s) pulled from the cloud")
        else:
            print("cloud API not configured (run cloud/deploy.sh) — media uploaded to R2 only")
        backup_db(con)
        free_local_media(con)
    except Exception as e:
        print(f"sync error: {e}", file=sys.stderr)
    print(f"sync done in {time.time() - t0:.0f}s")


def restore(con, day: str) -> None:
    rows = con.execute("SELECT * FROM uploads WHERE day=? AND kind IN ('screens','audio') ORDER BY key", (day,)).fetchall()
    if not rows:
        print(f"nothing uploaded for {day}")
        return
    import tarfile
    for r in rows:
        dest = ROOT / "media" / day / ("screens" if r["kind"] == "screens" else "audio")
        dest.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory() as tmp:
            tar = Path(tmp) / "b.tar"
            r2_get(r["key"], tar)
            with tarfile.open(tar) as tf:
                tf.extractall(dest, filter="data")
        print(f"  ↓ {r['key']}")
    print(f"restored media for {day}")


def process(con: sqlite3.Connection, day: str | None) -> None:
    lock = Lock("process")
    if not lock.ok:
        print("process already running")
        return
    days = [day] if day else [today()]
    if not day:
        y = (dt.date.today() - dt.timedelta(days=1)).isoformat()
        ys, ye = day_bounds(y)
        unfinished = con.execute("SELECT COUNT(*) FROM analyzed_windows WHERE ts_start>=? AND ts_start<? AND partial=1", (ys, ye)).fetchone()[0]
        has_data = con.execute("SELECT COUNT(*) FROM samples WHERE ts>=? AND ts<?", (ys, ye)).fetchone()[0]
        done = con.execute("SELECT COUNT(*) FROM analyzed_windows WHERE ts_start>=? AND ts_start<? AND partial=0", (ys, ye)).fetchone()[0]
        if has_data and (unfinished or done < 24):
            days.insert(0, y)
    print("collecting coding-agent logs…")
    got = collect_agents(con)
    if got:
        print("  new prompts: " + ", ".join(f"{k} {v}" for k, v in got.items()))
    print("transcribing…")
    transcribe(con)
    for d in days:
        print(f"analyzing {d}…")
        analyze(con, d)
        try:
            if summarize(con, d):
                print(f"  summary written")
        except Exception as e:
            print(f"  summary failed: {e}", file=sys.stderr)
        print(f"  report: {report(con, d)}")
    # (the menu-bar app runs `lifelog sync` right after this finishes)


def main() -> None:
    global CFG
    CFG = load_config()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    p = sub.add_parser("process"); p.add_argument("--day")
    p = sub.add_parser("transcribe"); p.add_argument("--limit", type=int)
    p = sub.add_parser("analyze"); p.add_argument("--day", default=None); p.add_argument("--force", action="store_true")
    p = sub.add_parser("summarize"); p.add_argument("--day", default=None)
    p = sub.add_parser("report"); p.add_argument("--day", default=None); p.add_argument("--open", action="store_true")
    p = sub.add_parser("search"); p.add_argument("query"); p.add_argument("--limit", type=int, default=40)
    p = sub.add_parser("dump"); p.add_argument("--day", default=None); p.add_argument("--from", dest="frm", required=True); p.add_argument("--to", required=True)
    p = sub.add_parser("prune"); p.add_argument("--keep-days", type=int, required=True)
    p = sub.add_parser("sync"); p.add_argument("--all-days", action="store_true")
    p = sub.add_parser("voices", help="list / name / merge the voices heard so far")
    p.add_argument("action", nargs="?", choices=["list", "name", "merge"], default="list")
    p.add_argument("args", nargs="*")
    p = sub.add_parser("enroll", help="teach it your voice (or someone else's with --name)")
    p.add_argument("--file"); p.add_argument("--seconds", type=int, default=20); p.add_argument("--name", default="Me")
    p.add_argument("--add", action="store_true", help="add another fingerprint (e.g. from phone audio) instead of replacing")
    p = sub.add_parser("restore"); p.add_argument("--day", required=True)
    p = sub.add_parser("agents", help="pull T3 / Claude Code / Codex / Delta logs now and list today's prompts")
    p.add_argument("--day", default=None)
    p.add_argument("--threads", action="store_true", help="per-T3-thread stats instead: time on screen, prompts by you/agents")
    a = ap.parse_args()
    con = connect()
    day = getattr(a, "day", None) or today()
    if a.cmd == "status":
        status(con)
    elif a.cmd == "process":
        process(con, a.day)
    elif a.cmd == "transcribe":
        print(f"transcribed {transcribe(con, a.limit)} chunk(s)")
    elif a.cmd == "analyze":
        analyze(con, day, force=a.force)
    elif a.cmd == "summarize":
        print(summarize(con, day) or "no segments yet — run analyze first")
    elif a.cmd == "report":
        out = report(con, day)
        print(out)
        if a.open:
            subprocess.run(["open", str(out)])
    elif a.cmd == "search":
        search(con, a.query, a.limit)
    elif a.cmd == "dump":
        ds, _ = day_bounds(day)
        f = lambda s: ds + sum(int(x) * m for x, m in zip(s.split(":"), (3600, 60, 1)))
        print(build_log(con, f(a.frm), f(a.to))[0])
    elif a.cmd == "prune":
        prune(con, a.keep_days)
    elif a.cmd == "sync":
        sync(con, a.all_days)
    elif a.cmd == "voices":
        if a.action == "list":
            list_voices(con)
        elif a.action == "name" and len(a.args) >= 2:
            con.execute("UPDATE voices SET name=? WHERE id=?", (" ".join(a.args[1:]), int(a.args[0].lstrip("#"))))
            con.commit()
            print(f"voice #{a.args[0].lstrip('#')} is now '{' '.join(a.args[1:])}' (everywhere, including past days)")
        elif a.action == "merge" and len(a.args) == 2:
            merge_voices(con, int(a.args[0].lstrip("#")), int(a.args[1].lstrip("#")))
        else:
            print("usage: lifelog voices [list] | name <id> <name> | merge <id> <into-id>")
    elif a.cmd == "enroll":
        enroll(con, a.file, a.seconds, a.name, a.add)
    elif a.cmd == "restore":
        restore(con, a.day)
    elif a.cmd == "agents":
        print("new prompts:", collect_agents(con) or "none")
        ds, de = day_bounds(day)
        if a.threads:
            print(f"{'on screen':>9}  {'you':>3} {'agt':>3} {'sch':>3}  thread")
            for t in thread_stats(con, ds, de):
                where = [x for x in (t["project"], t["host"] if t["host"] not in (None, "mac") else None) if x]
                name = (t["title"] or t["id"][:8]) + (f" ({', '.join(where)})" if where else "")
                print(f"{fmt_dur(t['screen']) if t['screen'] else '':>9}  {t['you'] or '':>3} {t['agent'] or '':>3} {t['scheduled'] or '':>3}  "
                      f"{'↳ ' if t['by'] == 'agent' else ''}{name[:90]}")
            return
        mark = {"you": "you>", "agent": "agt>", "scheduled": "sch>"}
        for r in con.execute("SELECT * FROM agent_events WHERE ts>=? AND ts<? ORDER BY ts", (ds, de)):
            text = " ".join((r["text"] or "").split())
            m = "   <" if r["kind"] == "reply" else mark.get(r["sender"], "   >")
            print(f"{hms(r['ts'])} {m} {agent_label(r)[:56]:<56} {text[:80]}")


if __name__ == "__main__":
    main()
