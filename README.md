# Lifelog

Record everything first, figure out what happened later.

A menu-bar app records the raw firehose. On-device models transcribe the audio and tell voices apart, and Claude turns it all into a timeline accurate to the second, like "typed a prompt in T3 Code thread *lifelog app* for 3 min → 1 min reading/thinking → scrolled X for 6 min".

## What gets recorded

| | how often | stored as |
|---|---|---|
| Frontmost app, window title, browser URL | every second | `samples` table |
| Keystroke / click / scroll / mouse **counts** (never which keys) | every second | `samples` |
| Idle time, screen locked | every second | `samples` |
| Mic level + computer-audio level | every second | `samples` |
| Screenshot of the display under your mouse | up to 1 fps (`screenshotFPS`), only when the screen actually changed | `media/<day>/screens/*.jpg`, `screenshots` |
| OCR of the screen (Apple Vision) | every 10 s + every app/tab switch | `screenshots.ocr` + full-text index |
| Microphone (built-in mic preferred) | continuous, 5-min chunks | `media/<day>/audio/*_mic.m4a` |
| Computer audio (calls, videos) | continuous, 5-min chunks | `media/<day>/audio/*_sys.m4a` |
| Prompts you send to coding agents (and who sent them, for T3), and when each agent finished | each `lifelog process` run | `agent_events`, `t3_threads` |

**Coding-agent logs.** Each timeline run reads Claude Code (`~/.claude*/projects`) and Codex (`~/.codex*/sessions`) session logs on this Mac and on every ssh host in `agentLogHosts` (the parser is piped over ssh as `python3 -`, so only the extracted prompts/replies travel back), plus Delta threads via the `delta` CLI. The timeline then knows the exact prompt you typed in which thread, and when the agent was working versus when you were reading its reply. Harness-injected messages (auto-continuations, compaction summaries, T3 Code title/PR housekeeping) are skipped. Prompts one agent sends another are kept; Claude marks them as background work when you weren't typing. `lifelog agents` pulls now and lists today's prompts.

**T3 Code threads.** If T3 Code runs on a machine (`~/.t3*/userdata/statev2.sqlite`, opened read-only), its threads are read from T3's own database instead of the Claude/Codex logs underneath, which are dropped as duplicates. T3 records who sent each message, so prompts are marked for certain as typed by you (in the app, or from your phone), sent by another agent, or sent by a scheduled task. Agent-to-agent prompts are never counted as your time. Thread titles, projects, which thread started which, model, branch and PRs land in `t3_threads`. The recorder already logs T3's window URL every second, so the timeline names the thread you had open. A prompt you sent from your phone also tells the absence labeller you were awake. `lifelog agents --threads` lists each T3 thread's time on screen and prompts from you, agents and schedules; the daily summary gets the same numbers.

Everything is recorded into `~/Lifelog` (one SQLite DB plus media files), then shipped to Cloudflare (see below). Locally only the last `localMediaKeepDays` (3) days of media are kept. Expect roughly 2–6 GB per active day at 1 fps. Lower `screenshotMaxWidth`/`jpegQuality` if that's too much.

Measured on an M1 Pro: about 19 ms per saved frame (around 2% of one core at 1 fps, zero when the screen is static) and about 0.8 s per OCR pass.

## Cloud (Cloudflare)

```
laptop ──wrangler r2 object put──▶ R2  lifelog-media   tar bundles: 10-min screenshot slots, hourly audio, daily DB backup
       ──HTTPS /api/ingest──────▶ Worker "lifelog" ─▶ D1 "lifelog"   timeline, transcripts, per-minute activity, bundle index
phone / browser ◀── Worker: web viewer + /api/day, single frames & audio served out of the tars with R2 range reads
phone app (later) ──PUT /api/upload, POST /api/ingest──▶ same API, as its own device
```

- `cloud/deploy.sh` (run by `install.sh`) creates the bucket and database, deploys the Worker, and stores the URL and token in `config.json`.
- Uploads run every 10 min and immediately when the Mac comes back online. They pause on phone hotspots or Low Data Mode unless `syncOnExpensiveNetwork` is on.
- Media is bundled into tars so it's a few hundred uploads a day instead of tens of thousands, which keeps R2 operation costs at about zero. R2 storage is about $0.015/GB-month: roughly +$1.5–2/month for every month of history you keep.
- `lifelog restore --day D` pulls a day's media back from R2 for the local report. The cloud viewer works from any device: `<cloudUrl>/?token=<cloudToken>` once, then just `<cloudUrl>`.
- The whole API is protected by one bearer token. Anyone with it sees everything, so treat it like a password. Putting [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/applications/) in front of the Worker adds a real login.

Transcription and the Claude analysis still run on the laptop. Only text goes to Claude.

## Deep analysis (Claude's cloud)

The laptop keeps making a quick timeline every 30 min: one `claude -p` call per hour, with no tools and a trimmed log. On top of that, a scheduled **cloud routine** re-analyzes everything every 4 hours at second level, without touching the laptop:

- **Raw data in R2.** Each sync uploads every hour that changed as `<device>/raw/<day>/<HH>.json.gz`: per-second activity, screen text, transcripts, events, agent prompts. That's about 250 kB an hour.
- **`analysis/ll.py`** is the agents' toolkit. It rebuilds any time range from those files, with the same renderer the laptop uses, or with `--full` for nothing trimmed. It also fetches single screenshots out of the R2 bundles, full screen text, transcripts, full agent threads, search, the current timeline and sleep history, and writes results back. `--local` runs it against `~/Lifelog/lifelog.db` instead.
- **`analysis/COORDINATOR.md`** is what the routine runs. An Opus coordinator surveys the range, splits it into chunks and runs one Sonnet agent per chunk in parallel (`analysis/CHUNK.md`: read the full log, look at screenshots, write segments). It then decides sleep and absences with the whole day in view, stitches and checks the chunks, writes the daily summary, and saves it with `ll.py write`.
- **Results override the quick timeline** inside each run's range: in the Worker's `/api/day` (the viewer) and on the Mac (`lifelog sync` pulls them into `deep_runs` / `deep_segments`, and reports use them).
- **The cloud agent gets its own token** (`ANALYST_TOKEN`, from `cloud/deploy.sh`, stored as `analystToken` in config). It can read everything but write only `/api/deep/ingest`.

Each run takes the first stretch of the last 30 h that no deep run covers, up to 14 h at a time. The routine's environment needs `LIFELOG_URL` and `LIFELOG_TOKEN` (the analyst token) and network access to the Worker.

## iPhone

`phone/` is a small iPhone app that covers the time away from the laptop. It records plain facts and uploads them straight to the Worker, so the laptop doesn't need to be on:

- **Mic, always on** (the orange dot stays on). It records 5-minute AAC chunks at 16 kHz mono, the same as the Mac. Music keeps playing, and AirPods stay in high-quality mode, because the phone always uses its built-in mic. A minute-by-minute loudness record also notes whether another app is playing audio. Chunks with nothing above -50 dB aren't uploaded. Audio waits for Wi-Fi unless you allow cellular.
- **Screen:** on and off, locked and unlocked, which gives phone-use sessions and glances. It can't see which app you used.
- **Calls:** start, connect and end, with no numbers. **Motion** (walking, vehicle, still) and **steps** per 5 minutes come from the motion coprocessor.
- **Places:** arrivals, departures and moves of about 500 m, named with Apple's reverse geocoder. There's no continuous GPS.
- **Battery** (charging or unplugged), **audio output** (speaker, AirPods), and recorder gaps.

The phone uses its own `PHONE_TOKEN`, which `cloud/deploy.sh` creates as `phoneToken` in config and the build compiles in. It can only upload: `PUT /api/upload/iphone/…` and `POST /api/phone/events`. On the Mac, `lifelog sync` pulls new events (`/api/phone/since`) into `phone_events`, downloads non-silent audio for the normal transcription (source `phone`, so your voice is still "Me"), and includes everything in the raw hours. The log then has `[PHONE …]` lines, `ll.py phone` shows the phone alone, and the overview gains `phone-s` / `steps` columns. The timeline has an **on phone** category.

Build and install: `phone/build.sh`. It needs Xcode, a paired iPhone in developer mode, and `LIFELOG_TEAM` (or `phoneTeam` in config) set to your Apple team id. `phone/build.sh --sim` only compiles.

iOS can't start recording from the background. If the app is killed (force-quit, reboot, or iOS reclaiming memory), a location wake-up brings it back for everything except the mic, and it sends a "Lifelog stopped listening" notification.

## Speech: who said what

`lifelog-asr` (in `asr/`, built on [FluidAudio](https://github.com/FluidInference/FluidAudio)) runs everything on-device with Core ML:

1. **Silero VAD** finds the speech, so silence costs nothing.
2. **Parakeet Ultra** transcribes it, with word timings. It covers 25 languages; for others set `"transcriber": "whisper"`.
3. **Nemotron 3 Diarization**, the speaker model from NVIDIA's Nemotron 3.5 Transcribe, works out who spoke when. It handles overlap and up to 8 voices per recording.
4. **CAM++** fingerprints each voice. The CLI matches fingerprints to known voices, so the same person keeps the same identity across recordings and days.

On an M1 Pro, 44 s of two-person conversation took about 1.4 s once warm, using roughly 170 MB of RAM.

Teach it your voice from **Settings → Voices → Start…** (or the welcome window). Name or merge people there too. The same from the terminal:

```bash
lifelog enroll                 # 20 s of you talking → transcripts say "Me"
lifelog voices                 # every voice heard: talk time + sample lines
lifelog voices name 7 Alex     # name one; applies retroactively
lifelog voices merge 9 7       # same person split into two voices? merge them
```

Mic transcripts are you and the room. Computer audio is the other side of calls and videos. Names show up in Claude's timeline, the reports and the cloud viewer. Whisper stays installed as an automatic fallback.

## Install

```bash
./install.sh
```

A welcome window walks you through the four permissions (**Screen Recording, Accessibility, Input Monitoring, Microphone**) and recording your voice. Click *Restart Lifelog* after granting Screen Recording. Lifelog starts at login; turn that off in Settings → General.

## The menu-bar app

- **Left-click ◉:** a panel with what's recording right now (screen, mic with a live level, computer audio, keys, window titles). It also shows today's time by category with Claude's one-line summary and the last few activities. At the bottom is the status of the timeline and cloud jobs, with *Update now* / *Sync now*, and *Open Timeline*.
- **Right-click ◉:** a quick menu to pause for 15 min, 1 h or until resumed, update the timeline, sync, open Settings or quit.
- **Settings** has five tabs:
  - *General:* start at login, how often to rebuild the timeline, which Claude model, "about you".
  - *Recording:* screenshot rate and resolution, OCR, mic and computer audio, apps to never screenshot.
  - *Voices:* enroll, rename and merge people; engine and matching strictness.
  - *Cloud:* Worker URL and token, test connection, upload interval, hotspot uploads, how long media stays on the Mac.
  - *Permissions*.

  Recording changes apply within a second, with no restart.
- **Icon:** ◉ while recording, ⏸ while paused, ⚠ when a permission is missing.

The app runs the pipeline itself at low priority. It rebuilds the timeline every 30 min, skipping it in Low Power Mode. It uploads every 10 min, right after each timeline run, and as soon as the Mac is back online. Job output goes to `~/Lifelog/logs/process.log` and `sync.log`.

## Use

```bash
lifelog status                  # what's recording, what's pending, cloud state
lifelog process                 # transcribe + analyze + summarize + build report (the app does this every 30 min)
open ~/Lifelog/reports/$(date +%F).html      # or ◉ → Open Timeline
lifelog search "dinner"         # anything you saw on screen or said/heard
lifelog sync                    # upload now (otherwise automatic)
lifelog restore --day 2026-11-01            # bring a day's media back from R2
lifelog analyze --day 2026-11-01 --force     # redo a day's timeline
lifelog dump --from 14:00 --to 15:00         # see exactly what Claude sees
```

Apps in `excludedBundleIDs` (password managers by default) are never screenshotted.

## Config — `~/Lifelog/config.json`

Recorder settings: `screenshotFPS`, `ocrInterval`, `screenshotMaxWidth`, `jpegQuality`, `recordMic`, `preferBuiltInMic`, `recordSystemAudio`, `recordAudioWhenLocked`, `excludedBundleIDs`.
Pipeline settings: `transcriber` (`fluidaudio` | `whisper`), `diarize`, `voiceMatchThreshold` (0.72), `analysisModel` (default `sonnet`), `summaryModel`, `transcribeLanguage` (whisper only), `micSpeechThresholdDb`, `claudeConfigDir` (which Claude Code login runs the analysis: `default` = the root login, or a config dir), `aboutMe` (tell Claude your project and friend names so its labels are sharper), `agentLogHosts` (e.g. `["devbox"]`), `agentLogDelta` (true), `agentLogBackfillDays` (2).
Cloud settings: `r2Bucket`, `cloudUrl`, `cloudToken`, `deviceId`, `localMediaKeepDays`, `syncOnExpensiveNetwork`, `dbBackupEveryDays`, `dbBackupsToKeep`.

Everything here is also in Settings. App-only keys: `processEveryMinutes` (30), `syncEveryMinutes` (10). Edits made in Settings apply immediately. If you edit the file by hand, use ◉ → ⏻ → Restart Lifelog.

## Notes

- Recording people near you or on calls can require their consent depending on where you live. Pause it, or set `recordMic: false`, when that matters.
- macOS periodically re-asks you to confirm screen recording. That's the OS, not a bug.
- If you rebuild without an Apple Development signing identity, macOS treats it as a new app and asks for permissions again.

## Layout

```
recorder/                menu-bar app (Swift, AppKit + SwiftUI)
  Recorder.swift         capture: ScreenCaptureKit, AVAudioEngine, CGEventTap, AX titles/URLs, Vision OCR, SQLite
  Controller.swift       1-second sampling tick, pause/resume, sleep/wake, live config reload
  Model.swift            what the UI shows + the timeline/sync scheduler
  App.swift              status item, panel, quick menu, Settings/Welcome windows
  PopoverView.swift      the panel
  SettingsView.swift     Settings tabs, welcome, voices, voice enrollment
  Support.swift          config.json, running the CLI, permissions, login item, palette
  main.swift             entry point + self-tests (--check, --selftest-*, --render-ui DIR)
tools/make-icon.swift    draws recorder/AppIcon.icns
asr/                     lifelog-asr: Parakeet Ultra + Nemotron 3 diarization + CAM++ voice fingerprints (Swift, FluidAudio)
pipeline/lifelog.py      CLI: transcription, voices, Claude timeline + summary, HTML report, search, R2 sync
pipeline/agentlogs.py    T3 Code / Claude Code / Codex reader (runs locally and on ssh hosts)
analysis/ll.py           data tool for the deep cloud analysis; COORDINATOR.md / CHUNK.md are its playbooks
pipeline/report.html     report / viewer (local file or served by the Worker)
phone/                   iPhone app (SwiftUI): project.yml (xcodegen), Sources/{App,Mic,Sensors,Uploader,Store}.swift, build.sh
tools/make-phone-icon.swift  draws the iPhone icon
cloud/                   Worker (src/index.js), D1 schema, wrangler.toml, deploy.sh
build.sh / install.sh / uninstall.sh
```
