#!/bin/bash
# Installs Lifelog: builds the menu-bar app (which records, and schedules the timeline + R2 uploads),
# the on-device speech engine, whisper fallback models and the `lifelog` CLI; starts it at login;
# and deploys the Cloudflare side (cloud/deploy.sh).
set -euo pipefail
cd "$(dirname "$0")"
SRC="$(pwd)"
DATA="${LIFELOG_DIR:-$HOME/Lifelog}"
APPDIR="$HOME/Applications"
AGENTS="$HOME/Library/LaunchAgents"
UIDN=$(id -u)

need() { command -v "$1" >/dev/null || { echo "✗ $1 not found — $2" >&2; exit 1; }; }
[ "$(uname -s)" = Darwin ] || { echo "✗ Lifelog's recorder is a macOS app; run this on a Mac" >&2; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || { echo "✗ macOS 14 (Sonoma) or newer is required" >&2; exit 1; }
need swiftc "install Xcode or the command line tools: xcode-select --install"
need swift "install Xcode or the command line tools: xcode-select --install"
need python3 "install the command line tools: xcode-select --install"
need brew "install Homebrew from https://brew.sh"

echo "→ dependencies"
for f in ffmpeg whisper-cpp; do brew list "$f" >/dev/null 2>&1 || brew install "$f"; done
command -v wrangler >/dev/null || echo "  ! wrangler not found — cloud sync is off until you: brew install node && npm i -g wrangler"
command -v claude >/dev/null || echo "  ! claude CLI not found — AI analysis will be skipped until you install Claude Code"

echo "→ models"
mkdir -p "$DATA/models" "$DATA/logs" "$DATA/bin"
[ -f "$DATA/models/ggml-large-v3-turbo-q5_0.bin" ] || curl -L --fail -o "$DATA/models/ggml-large-v3-turbo-q5_0.bin" \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
[ -f "$DATA/models/ggml-silero-v5.1.2.bin" ] || curl -L --fail -o "$DATA/models/ggml-silero-v5.1.2.bin" \
  https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin

echo "→ recorder app"
./build.sh
launchctl bootout "gui/$UIDN/com.lifelog.recorder" 2>/dev/null || true
pkill -x Lifelog 2>/dev/null || true
mkdir -p "$APPDIR"
rm -rf "$APPDIR/Lifelog.app"
/bin/cp -R build/Lifelog.app "$APPDIR/"

echo "→ speech engine (Parakeet Ultra + Nemotron 3 diarization + CAM++ voices, on-device)"
(cd asr && swift build -c release 2>&1 | grep -E "error|Build complete")
mkdir -p "$DATA/bin"
/bin/cp -f asr/.build/release/lifelog-asr "$DATA/bin/lifelog-asr"
"$DATA/bin/lifelog-asr" warmup >/dev/null 2>&1 && echo "  models downloaded & compiled" || echo "  ! warmup failed — will fall back to whisper until fixed"

echo "→ CLI"
/bin/cp -f pipeline/lifelog.py pipeline/agentlogs.py pipeline/report.html "$DATA/bin/"
chmod +x "$DATA/bin/lifelog.py"
mkdir -p "$HOME/.local/bin"
ln -sf "$DATA/bin/lifelog.py" "$HOME/.local/bin/lifelog"

echo "→ login item"
mkdir -p "$AGENTS"
NODEDIR=$(dirname "$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)")
WRANGLERDIR=$(dirname "$(command -v wrangler 2>/dev/null || echo /opt/homebrew/bin/wrangler)")
CLAUDEDIR=$(dirname "$(command -v claude 2>/dev/null || echo /opt/homebrew/bin/claude)")
ENVPATH="$NODEDIR:$WRANGLERDIR:$CLAUDEDIR:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# The app runs the pipeline itself (timeline every 30 min, uploads every 10 min + when you get back online).
# It reads its job environment from here, so it works whether launchd or Finder started it.
python3 - "$DATA/.env.json" "$ENVPATH" "$(command -v python3)" <<'PY'
import json, os, sys
env = {"PATH": sys.argv[2], "PYTHON": sys.argv[3]}
for k in ("CLAUDE_CONFIG_DIR", "LIFELOG_DIR"):
    if os.environ.get(k):
        env[k] = os.environ[k]
open(sys.argv[1], "w").write(json.dumps(env, indent=2))
PY
EXTRA_ENV="<key>PATH</key><string>$ENVPATH</string>"
[ -n "${CLAUDE_CONFIG_DIR:-}" ] && EXTRA_ENV="$EXTRA_ENV<key>CLAUDE_CONFIG_DIR</key><string>$CLAUDE_CONFIG_DIR</string>"
[ -n "${LIFELOG_DIR:-}" ] && EXTRA_ENV="$EXTRA_ENV<key>LIFELOG_DIR</key><string>$LIFELOG_DIR</string>"

# older installs had separate process/sync agents — the app does that now
for a in process sync; do
  launchctl bootout "gui/$UIDN/com.lifelog.$a" 2>/dev/null || true
  rm -f "$AGENTS/com.lifelog.$a.plist"
done

cat > "$AGENTS/com.lifelog.recorder.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.lifelog.recorder</string>
  <key>ProgramArguments</key><array><string>$APPDIR/Lifelog.app/Contents/MacOS/Lifelog</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>EnvironmentVariables</key><dict>$EXTRA_ENV</dict>
  <key>StandardErrorPath</key><string>$DATA/logs/recorder.log</string>
  <key>StandardOutPath</key><string>$DATA/logs/recorder.log</string>
</dict></plist>
PLIST
launchctl bootout "gui/$UIDN/com.lifelog.recorder" 2>/dev/null || true
launchctl enable "gui/$UIDN/com.lifelog.recorder"
launchctl bootstrap "gui/$UIDN" "$AGENTS/com.lifelog.recorder.plist"

echo "→ Cloudflare (R2 + D1 + Worker)"
if command -v wrangler >/dev/null && wrangler whoami >/dev/null 2>&1; then
  ./cloud/deploy.sh
else
  echo "  ! wrangler not installed or not logged in — run 'wrangler login' then ./cloud/deploy.sh"
fi

cat <<MSG

✓ Lifelog installed — look for the ◉ icon in your menu bar.

A welcome window walks you through the 4 permissions (Screen Recording, Accessibility, Input Monitoring,
Microphone) and recording your voice. Click "Restart Lifelog" there after granting Screen Recording.

  Left-click ◉   today's breakdown, recent activity, pause, open the timeline
  Right-click ◉  quick menu (pause, update timeline, sync, settings, quit)
  Settings       recording quality, excluded apps, voices, Cloudflare, start at login

The app rebuilds the AI timeline every 30 min and uploads to R2 every 10 min (and whenever you get back online).
Data: $DATA      CLI: lifelog status | process | sync | voices | search "…"
MSG
