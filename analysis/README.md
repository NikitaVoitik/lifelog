# Deep analysis

The Mac makes a quick timeline every 30 minutes (one text-only `claude -p` call per hour). The deep analysis redoes it
at second-level detail, in the cloud, without touching the laptop:

- `ll.py` is the agents' toolkit. It rebuilds any time range from the raw hourly files the Mac uploads to R2
  (`<device>/raw/<day>/<HH>.json.gz`), using the same renderer as the laptop, and fetches screenshots, screen text,
  transcripts, agent threads, phone events and sleep history. `ll.py write` saves a run back through the Worker.
  Run `python3 analysis/ll.py -h` for every command.
- `COORDINATOR.md` is the prompt for the scheduled run: an Opus coordinator plans chunks, runs one Sonnet agent per chunk
  in parallel, decides sleep and absences, stitches, writes the daily summary and saves.
- `CHUNK.md` is the prompt each chunk agent gets.

## Running it

Schedule a Claude Code routine (twice a day is enough: each run catches up on everything since the last) on a checkout of this repo with the contents of `COORDINATOR.md` as
its prompt. Its environment needs:

- `LIFELOG_URL`: your Worker URL (`cloudUrl`)
- `LIFELOG_TOKEN`: the analyst token (`analystToken` in `~/Lifelog/config.json`): read everything, write only results
- network access to the Worker, and permission to `pip install Pillow` (used to shrink screenshots)

Optional: `LIFELOG_DEVICE` (default `mac`), `LIFELOG_CACHE` (default `/tmp/lifelog-cache`), `LIFELOG_HORIZON_HOURS` (30).

Results override the quick timeline inside each run's range, in the web viewer and, after `lifelog sync`, on the Mac.

**Privacy:** the agents read the raw hours *and view screenshots*. Don't set this up if you don't want images of your
screen sent to Claude.

## Locally

`python3 analysis/ll.py --local status` (and every other command) reads `~/Lifelog/lifelog.db` instead of the cloud.
