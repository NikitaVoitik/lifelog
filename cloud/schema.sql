-- One row per device-day: per-minute activity, app totals, first/last activity.
CREATE TABLE IF NOT EXISTS day_stats(
  device TEXT, day TEXT, day_start REAL, first REAL, last REAL,
  minutes_json TEXT, apps_json TEXT, updated REAL,
  PRIMARY KEY(device, day));
CREATE TABLE IF NOT EXISTS segments(
  device TEXT, ts_start REAL, ts_end REAL, category TEXT, activity TEXT, detail TEXT, app TEXT,
  PRIMARY KEY(device, ts_start));
CREATE TABLE IF NOT EXISTS transcripts(
  device TEXT, ts_start REAL, ts_end REAL, source TEXT, text TEXT, speaker TEXT,
  PRIMARY KEY(device, ts_start, source));
CREATE TABLE IF NOT EXISTS summaries(day TEXT PRIMARY KEY, text TEXT, updated REAL);
-- Media lives in R2 as tar bundles (10-min screenshot slots, hourly audio). files_json indexes members
-- so single frames / audio ranges can be served with R2 range reads.
CREATE TABLE IF NOT EXISTS bundles(
  key TEXT PRIMARY KEY, device TEXT, kind TEXT, day TEXT, slot TEXT, bytes INTEGER, files_json TEXT, created REAL);
CREATE INDEX IF NOT EXISTS bundles_day ON bundles(device, day, kind);
CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, name TEXT, kind TEXT, last_seen REAL);
-- Raw hours: everything the Mac recorded in one local hour (per-second activity, screen text, transcripts, events, agent
-- prompts) as R2 objects <device>/raw/<day>/<HH>.json.gz — what the cloud deep analysis reads.
CREATE TABLE IF NOT EXISTS raw_hours(
  device TEXT, day TEXT, hour TEXT, key TEXT, ts_start REAL, ts_end REAL, last_ts REAL, bytes INTEGER, tz TEXT, updated REAL,
  PRIMARY KEY(device, day, hour));
-- Deep analysis (Claude coordinator + Sonnet agents in Claude's cloud): each run owns [ts_start, ts_end) and overrides the
-- laptop's quick timeline there.
CREATE TABLE IF NOT EXISTS deep_runs(
  id INTEGER PRIMARY KEY AUTOINCREMENT, device TEXT, ts_start REAL, ts_end REAL, created REAL, note TEXT);
CREATE INDEX IF NOT EXISTS deep_runs_dev ON deep_runs(device, ts_start);
CREATE TABLE IF NOT EXISTS deep_segments(
  device TEXT, ts_start REAL, ts_end REAL, category TEXT, activity TEXT, detail TEXT, app TEXT, run_id INTEGER,
  PRIMARY KEY(device, ts_start));
CREATE TABLE IF NOT EXISTS deep_summaries(device TEXT, day TEXT, text TEXT, updated REAL, PRIMARY KEY(device, day));
