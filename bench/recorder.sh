#!/bin/bash
# Recorder micro-benchmarks on your own recorded data (never committed): builds bench/recorder/main.swift with
# recorder/Recorder.swift and prints one JSON line per benchmark (median of RUNS runs).
#
#   bench/recorder.sh [frames|audio|mic|ocr|tick ...]     default: frames audio mic tick
#
# Inputs (override with env): BENCH_SCREENS (dir of real screenshots), BENCH_AUDIO (a real .m4a),
# BENCH_FRAMES (frames to replay, 240), RUNS (5). Works in a throwaway LIFELOG_DIR.
set -eu  # (no pipefail: `ls | head` SIGPIPEs)
cd "$(dirname "$0")/.."
LL="${LIFELOG_DIR:-$HOME/Lifelog}"
OUT="${BENCH_OUT:-${TMPDIR:-/tmp}/lifelog-bench}"
RUNS="${RUNS:-5}"
mkdir -p "$OUT"
pick_day() { ls -d "$LL"/media/20*/screens 2>/dev/null | while read -r d; do [ "$(ls "$d" | wc -l)" -gt 600 ] && echo "$d"; done | tail -1; }
SCREENS="${BENCH_SCREENS:-}"
if [ -z "$SCREENS" ]; then
  # a fixed stretch of 400 consecutive frames from the middle of the most recent busy day
  src="$(pick_day)"; [ -n "$src" ] || { echo "no recorded screenshots under $LL/media; set BENCH_SCREENS" >&2; exit 1; }
  SCREENS="$OUT/screens"
  if [ ! -d "$SCREENS" ]; then
    mkdir -p "$SCREENS"
    total=$(ls "$src" | wc -l); start=$((total / 2))
    ls "$src" | sort | sed -n "$((start + 1)),$((start + 400))p" | while read -r f; do cp "$src/$f" "$SCREENS/"; done
  fi
fi
AUDIO="${BENCH_AUDIO:-}"
if [ -z "$AUDIO" ]; then
  AUDIO="$OUT/audio.m4a"
  if [ ! -f "$AUDIO" ]; then
    # the largest finished sys chunk (most sound) from the last few days
    f=$(ls -S "$LL"/media/20*/audio/*_sys.m4a 2>/dev/null | head -20 | while read -r a; do afinfo "$a" >/dev/null 2>&1 && echo "$a" && break; done)
    [ -n "$f" ] || { echo "no recorded audio under $LL/media; set BENCH_AUDIO" >&2; exit 1; }
    cp "$f" "$AUDIO"
  fi
fi
BIN="$OUT/recorder-bench"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -module-name Lifelog \
  recorder/Recorder.swift bench/recorder/main.swift -o "$BIN" 2>&1 | grep -v warning || true

run() {  # name args… → median line by the first numeric metric
  local name=$1; shift
  local lines=()
  for _ in $(seq "$RUNS"); do
    local dir; dir=$(mktemp -d "$OUT/run.XXXX")
    echo '{"ocr": false}' > "$dir/config.json"
    lines+=("$(LIFELOG_DIR="$dir" "$BIN" "$name" "$@" 2>/dev/null)")
    rm -rf "$dir"
  done
  printf '%s\n' "${lines[@]}" | python3 -c '
import json, sys, statistics
rows = [json.loads(l) for l in sys.stdin if l.strip()]
keys = [k for k in rows[0] if isinstance(rows[0][k], (int, float)) and k != "bench"]
print(json.dumps({"bench": rows[0]["bench"], **{k: round(statistics.median(r[k] for r in rows), 3) for k in keys},
                  **{k: v for k, v in rows[0].items() if isinstance(v, dict)}}))'
}

benches=("$@"); [ ${#benches[@]} -gt 0 ] || benches=(frames audio mic tick)
for b in "${benches[@]}"; do
  case $b in
    frames) run frames "$SCREENS" "${BENCH_FRAMES:-240}" ;;
    audio) run audio "$AUDIO" 300 ;;
    mic) run mic "$AUDIO" 300 ;;
    ocr) RUNS=1 run ocr "$SCREENS" 15 ;;
    tick) run tick 3600 ;;
    thumbs) RUNS=1 run thumbs "$SCREENS" 400 ;;
  esac
done
