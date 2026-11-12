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

| | before | after |
|---|---|---|
| frames: CPU per delivered frame | 17.6 ms | 6.7 ms |
| OCR (accurate mode broken system-wide) | 0 of 14 frames recognised | 14 of 14 (fast fallback, 114 ms CPU each) |
| sync: CPU per run | 2.1 s + 1 wrangler call (~3 s CPU, ~380 MB) | 1.4 s, no wrangler |
| local media pinned by orphaned audio chunks | 46 GB | freed on the next sync |
