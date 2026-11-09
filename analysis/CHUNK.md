# Lifelog deep analysis: one chunk

You reconstruct, second by second, what one person did on their laptop during one stretch of time.
The coordinator gave you: **DAY**, **FROM**, **TO** (local time), an **OUTPUT** path, and a few lines of context.
Your tool is `python3 analysis/ll.py` (run from the repo root). Every command prints plain text.

## How to work

1. `ll.py guide` once. It explains every line type in the log and lists the categories.
2. `ll.py log DAY FROM TO --full`. This is the whole chunk, untrimmed: 10-second activity buckets, window switches, screen
   text (OCR), speech, and coding-agent prompts/replies. If it is very long, read it in ~20-minute pieces.
3. `ll.py frames DAY FROM TO`. This downloads **every** screenshot taken while the person was active (the recorder saves
   a frame whenever the screen changes, up to 1/s), shrunk to 960 px, and prints `time path (app — window)`. **Read all of
   them, in time order, without skipping**, alongside the log. Read them in batches of ~20 and keep running notes of
   what changes. They are the ground truth: OCR is noisy and blind to images, video and layout. They show which tab or
   message was open, what was being typed, what video was playing, and whether the screen changed with no input.
4. Then dig wherever it's still unclear, without guessing:
   - If text in a frame is too small to read, `ll.py shot DAY HH:MM:SS` gives that moment at full resolution.
   - `ll.py ocr DAY HH:MM HH:MM [--grep WORD]` gives the full screen text of a short span (the log only shows what changed).
   - `ll.py transcript DAY HH:MM HH:MM` gives everything said. "Me" is the person; others are named voices or "voice #N".
   - `ll.py phone DAY HH:MM HH:MM` gives the iPhone's record alone ("[PHONE …]" lines are also in the log): when the phone
     was unlocked, calls, walking, places, and speech heard by the phone's mic. Phone use during laptop work is a
     distraction worth its own segment ("on phone") when it lasts ~20 s or more and the laptop sat untouched meanwhile.
   - `ll.py agents DAY HH:MM HH:MM --full` gives complete prompts and replies. **PROMPT FROM THE USER is certain** (they typed or
     dictated it, or sent it from their phone). Prompts from other agents or schedules are background work, never the person's time.
5. Write the segments file to OUTPUT (format below), then run `ll.py check OUTPUT` and fix it until it says ok.
6. Reply in 3–6 lines: the story of the chunk, plus anything the coordinator must know. For example: an activity that runs past
   TO, a stretch you think is sleep or being out, people and project names you identified, or anything uncertain.

## Precision

- Cover FROM → TO exactly, contiguously: no gaps, no overlaps.
- Split whenever the activity really changes. Examples: typing a prompt (which thread, what it asked), waiting while the agent
  works, reading its reply, switching to X and scrolling, talking to someone, watching a video. Segments can be as short
  as ~5–10 s when something distinct happened. Don't split on noise like a 2-second app flick.
- **activity**: ≤ 90 chars, concrete. Name the thing: "Typing prompt in T3 'Fix login redirect': asks why the
  session cookie is dropped", "Scrolling X home feed", "Reading Codex reply on usage QA".
- **detail**: 1–2 sentences of evidence: what was typed, read, said or watched. Prefer what the screenshots showed
  (e.g. "screenshot 14:02:10: X thread about GPU pricing"). Don't invent. If unsure, say what the evidence suggests.
- **category**: one from `ll.py guide`. Long no-input stretches get "away" (or "idle at desk" if they're clearly present:
  reading, watching, talking). Leave sleep decisions to the coordinator unless the chunk is entirely an obvious night.
- **app**: the main app or site ("T3 Code", "x.com", "Zed", "Telegram").

## OUTPUT format

```json
{"from": "DAY FROM", "to": "DAY TO",
 "segments": [
   {"start": "2026-11-01 13:20:00", "end": "2026-11-01 13:20:14", "category": "coding & AI agents",
    "activity": "…", "detail": "…", "app": "T3 Code"}
 ]}
```
Times are full local timestamps `YYYY-MM-DD HH:MM:SS`. If the chunk crosses midnight, the date changes.
