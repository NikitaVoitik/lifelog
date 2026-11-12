# Benchmarks

Resource benchmarks that replay **your own recorded data** through Lifelog's real code paths. Inputs are copied into
`$BENCH_OUT` (default `$TMPDIR/lifelog-bench`), never into the repo, and nothing is uploaded or sent to Claude.

```bash
bench/recorder.sh                 # frames, audio, mic, tick (median of 5 runs)
bench/recorder.sh thumbs ocr      # change-detector equivalence check; OCR cost
bench/pipeline.sh                 # lifelog sync / process / report on a snapshot of your DB
PIPELINE=/tmp/old/lifelog.py bench/pipeline.sh sync    # same run against another version (agentlogs.py and
                                                       # report.html must sit next to it)
```

| bench | what it measures |
|---|---|
| `frames` | CPU per frame ScreenCaptureKit delivers (every real frame + a caret-blink near-duplicate that must be dropped), KB per saved JPEG, and a stage breakdown (thumbnail / CGImage / JPEG) |
| `thumbs` | whether the change detector keeps/drops the same frames as the original CoreGraphics thumbnail |
| `audio`, `mic` | CPU per second of system audio (48 kHz stereo sample buffers) and mic audio through the AAC chunk writer |
| `ocr` | CPU and wall time per OCR pass, and which mode (accurate / fast fallback) ran |
| `tick` | the per-second sample insert |
| `sync` | `lifelog sync` with one new, busy 10-minute slot (600 frames): CPU, RSS, bytes to the Worker, wrangler calls |
| `process` | `lifelog process` with Claude stubbed: CPU, RSS, number and size of Claude prompts |
| `report` | `lifelog report` for yesterday |

The pipeline bench takes a consistent snapshot with `VACUUM INTO` (one read transaction). Don't use sqlite3's
`.backup` on the live database: it restarts on every write the recorder makes and can spin for as long as you let it.

## Results (M1 Pro, 2026-11-12)

Micro-benchmarks (median of runs):

| | before | after |
|---|---|---|
| frames: CPU per delivered frame | 17.6 ms | 5.5 ms |
| system audio: CPU per audio-second | 2.4 ms (48 kHz stereo in) | 1.0 ms (16 kHz mono in) |
| mic: CPU per audio-second | 1.9 ms | 0.9 ms |
| OCR while accurate mode is broken system-wide | 0 of 14 frames recognised | 14 of 14 (fast fallback) |
| sync: CPU per run | 2.1 s + 1 wrangler call (~3 s CPU, ~380 MB) | 1.4 s, no wrangler |
| local media pinned by orphaned audio chunks | 46 GB | freed on the next sync |

The recorder, live: the old and the new build running side by side on the same screen with identical configs
(mic off in both, so as not to disturb the real recorder):

| | old | new |
|---|---|---|
| frames only, 3 min | 3.78% of a core | 1.75% |
| frames + system audio, 3 min | 6.22% | 3.14% |
| frames, mostly idle user, 4 min | 2.95% | 0.66% |

The micro-benchmarks miss two things the live runs caught: ScreenCaptureKit's IOSurface is much slower for the
CPU to read than the bench's buffers (so encode from a copy), and system audio's cost is mostly in receiving
48 kHz stereo buffers from another process (so ask for 16 kHz mono). Check changes to the capture path live.

OCR is the largest recorder cost when it works, about one pass every 8.5 s while active. Accurate mode with
language correction was ~240–460 ms CPU per pass; without it (now the setting) ~90–150 ms, keeping ~94% of the
same words. Fast mode, the fallback while accurate is broken, keeps ~42%.
