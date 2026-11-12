#!/bin/bash
# Pipeline benchmarks: `lifelog sync`, `lifelog process` and `lifelog report` on a snapshot of your database, with
# stand-ins for everything external — a local mock Worker (bench/mock_worker.py), a `claude` that answers instantly
# and records how much it was sent, and a `wrangler` that records what it was asked to upload. Nothing leaves the Mac.
#
#   bench/pipeline.sh [sync|process|report ...]      default: all three
#   PIPELINE=/path/to/other/lifelog.py bench/pipeline.sh sync     the same run against another version
#
# One JSON line per benchmark: cpu_s (user+sys of the CLI and its children), wall_s, max_rss_mb, plus what went out
# (bytes to the Worker, wrangler calls, Claude prompt KB). Env: LIFELOG_DIR (source, ~/Lifelog), BENCH_OUT, RUNS (3),
# BENCH_SCREENS (frames for the sync's new 10-minute slot; default: the ones bench/recorder.sh copied).
set -eu
cd "$(dirname "$0")/.."
REPO=$PWD
LL="${LIFELOG_DIR:-$HOME/Lifelog}"
OUT="${BENCH_OUT:-${TMPDIR:-/tmp}/lifelog-bench}"
RUNS="${RUNS:-3}"
SCREENS="${BENCH_SCREENS:-$OUT/screens}"
mkdir -p "$OUT"
SNAP="$OUT/snapshot.db"
if [ ! -f "$SNAP" ]; then
  # one read transaction; sqlite3's .backup restarts on every write the recorder makes and may never finish
  sqlite3 "file:$LL/lifelog.db?mode=ro" "VACUUM INTO '$SNAP'"
fi
[ -d "$SCREENS" ] || { echo "no frames in $SCREENS: run bench/recorder.sh first or set BENCH_SCREENS" >&2; exit 1; }

STUBS="$OUT/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/claude" <<'EOF'
#!/bin/bash
# records the prompt size; answers with an empty but valid result
n=$(wc -c | tr -d ' ')
echo "$n" >> "$BENCH_STATS/claude"
case "$*" in
  *absences*) echo '{"is_error":false,"result":"","structured_output":{"absences":[]}}' ;;
  *segments*) echo '{"is_error":false,"result":"","structured_output":{"segments":[]}}' ;;
  *) echo '{"is_error":false,"result":"A day."}' ;;
esac
EOF
cat > "$STUBS/wrangler" <<'EOF'
#!/bin/bash
# records uploads (a real `wrangler r2 object put` of a 150 MB bundle costs ~3 s CPU and ~380 MB RSS in Node)
f=""; prev=""
for a in "$@"; do [ "$prev" = "--file" ] && f=$a; prev=$a; done
echo "$1 $2 $3 $( [ -n "$f" ] && stat -f %z "$f" || echo 0)" >> "$BENCH_STATS/wrangler"
EOF
chmod +x "$STUBS/claude" "$STUBS/wrangler"

PORT=$((20000 + RANDOM % 20000))
rm -f "$OUT/mock.json"  # counters belong to this server
python3 "$REPO/bench/mock_worker.py" "$PORT" "$OUT/mock.json" &
MOCK=$!
trap 'kill $MOCK 2>/dev/null' EXIT
sleep 0.5

setup() {  # → $DIR: a fresh LIFELOG_DIR with the snapshot and one new, finished 10-minute slot of frames
  DIR=$(mktemp -d "$OUT/pl.XXXX")
  cp -c "$SNAP" "$DIR/lifelog.db" 2>/dev/null || cp "$SNAP" "$DIR/lifelog.db"
  python3 - "$LL/config.json" "$DIR/config.json" "$PORT" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))
c.update(cloudUrl=f"http://127.0.0.1:{sys.argv[3]}", cloudToken="bench", analystToken="", phoneToken="",
         agentLogHosts=[], agentLogDelta=False, wranglerLocal="", localMediaKeepDays=1)
json.dump(c, open(sys.argv[2], "w"), indent=1)
EOF
  echo '{"online": true, "expensive": false, "constrained": false}' > "$DIR/.network.json"
  # a slot that ended >10 min ago, today, not yet uploaded: 00:00–00:10 (renamed copies of real frames)
  local day; day=$(date +%F)
  mkdir -p "$DIR/media/$day/screens"
  local i=0
  local src=($(ls "$SCREENS" | sort))
  # a busy slot is ~600 frames / 110–210 MB in real life; cycle the sample frames up to that
  for k in $(seq 0 $((${BENCH_SLOT_FRAMES:-600} - 1))); do
    f=${src[$((k % ${#src[@]}))]}
    n=$(printf '00%02d%02d_000.jpg' $((i / 60)) $((i % 60)))
    cp -c "$SCREENS/$f" "$DIR/media/$day/screens/$n" 2>/dev/null || cp "$SCREENS/$f" "$DIR/media/$day/screens/$n"
    i=$((i + 1))
  done
  mkdir -p "$DIR/stats"
  : > "$DIR/stats/claude"; : > "$DIR/stats/wrangler"
}

measure() {  # name cmd… → one JSON line
  local name=$1; shift
  local tl="$DIR/time.txt"
  cp "$OUT/mock.json" "$DIR/mock0.json" 2>/dev/null || echo '{"requests": 0, "bytes_in": 0}' > "$DIR/mock0.json"
  ( cd "$DIR" && LIFELOG_DIR="$DIR" BENCH_STATS="$DIR/stats" PATH="$STUBS:$PATH" \
      /usr/bin/time -l python3 ${PYARGS:-} "${PIPELINE:-$REPO/pipeline/lifelog.py}" "$@" > "$DIR/out.txt" 2> "$tl" ) || true
  sleep 0.2
  python3 - "$name" "$tl" "$DIR" "$OUT/mock.json" "$DIR/mock0.json" <<'EOF'
import json, re, sys
name, tl, d, mock, mock0 = sys.argv[1:]
t = open(tl).read()
num = lambda k: float(re.search(r"([\d.]+)\s+" + k, t).group(1))
claude = [int(x) for x in open(f"{d}/stats/claude").read().split()]
wr = [l.split() for l in open(f"{d}/stats/wrangler").read().splitlines() if l.strip()]
m1, m0 = json.load(open(mock)), json.load(open(mock0))
m = {k: m1.get(k, 0) - m0.get(k, 0) for k in ("requests", "bytes_in")}  # the mock's counters are cumulative
err = [l for l in t.splitlines() if "Error" in l or "Traceback" in l]
print(json.dumps({"bench": name, "cpu_s": round(num("user") + num("sys"), 2), "wall_s": num("real"),
                  "max_rss_mb": round(num("maximum resident set size") / 1048576, 1),
                  "claude_calls": len(claude), "claude_prompt_kb": round(sum(claude) / 1024, 1),
                  "wrangler_calls": len(wr), "wrangler_mb": round(sum(int(w[-1]) for w in wr) / 1e6, 1),
                  "worker_requests": m["requests"], "worker_mb": round(m["bytes_in"] / 1e6, 2),
                  **({"errors": err[:3]} if err else {})}))
EOF
}

median() {
  python3 -c '
import json, sys, statistics
rows = [json.loads(l) for l in sys.stdin if l.strip()]
out = {"bench": rows[0]["bench"]}
for k, v in rows[0].items():
    if isinstance(v, (int, float)) and k != "bench":
        out[k] = round(statistics.median(r[k] for r in rows), 2)
    elif k == "errors":
        out[k] = v
print(json.dumps(out))'
}

benches=("$@"); [ ${#benches[@]} -gt 0 ] || benches=(sync process report)
for b in "${benches[@]}"; do
  for _ in $(seq "$RUNS"); do
    setup
    case $b in
      sync) measure sync sync ;;
      process) measure process process ;;
      report) measure report report --day "$(date -v-1d +%F)" ;;
    esac
    rm -rf "$DIR"
  done | median
done
