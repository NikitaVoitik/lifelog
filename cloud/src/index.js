// Lifelog cloud API.
//
//   GET  /api/ping                         → { ok, devices }
//   GET  /api/days?device=mac              → [{ day, first, last }]
//   GET  /api/day/:day?device=mac          → everything the viewer needs for one day
//   GET  /api/file/:bundleKey/:member      → one screenshot / audio file out of a tar bundle (Range supported)
//   GET  /api/raw/:key                     → a plain R2 object (Range supported)
//   POST /api/ingest                       → { device, deviceName?, deviceKind?, days?: [...], bundles?: [...], summaries?: [...] }
//   PUT  /api/upload/:device/:path         → stream a file into R2 at devices/:device/:path   (for the phone app)
//   GET  /api/shot?device&day&ts           → the screenshot nearest to ts (within 2 min)
//   GET  /api/deep/status?device=mac       → raw hours available + deep-analysis runs so far (for the cloud analyst)
//   POST /api/deep/ingest                  → { device, ts_start, ts_end, segments: [{s,e,c,activity,detail,app}], summaries?, note? }
//   GET  /api/deep/since?device&since      → deep runs (with segments) + summaries created after `since` (the Mac pulls these)
//
// Auth: "Authorization: Bearer <API_TOKEN>" or the ll_token cookie (the viewer sets it so <img>/<audio> work).
// ANALYST_TOKEN (optional, for the cloud analysis agent) may read everything but only write via /api/deep/ingest.

const CATEGORIES = [
  "coding & AI agents", "communication", "voice & calls", "social media", "entertainment",
  "browsing & research", "writing & planning", "idle at desk", "away", "other",
];
const DEEP_CATEGORIES = new Set([...CATEGORIES, "sleep"]);

const TYPES = { jpg: "image/jpeg", jpeg: "image/jpeg", heic: "image/heic", png: "image/png", m4a: "audio/mp4", mp3: "audio/mpeg",
  wav: "audio/wav", json: "application/json", gz: "application/gzip", tar: "application/x-tar" };

const json = (data, status = 200, extra = {}) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...extra } });

function tokenFrom(req) {
  const h = req.headers.get("authorization") || "";
  if (h.startsWith("Bearer ")) return h.slice(7).trim();
  const m = (req.headers.get("cookie") || "").match(/(?:^|;\s*)ll_token=([^;]+)/);
  return m ? decodeURIComponent(m[1]) : "";
}

function safeEqual(a, b) {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

function parseRange(header, size) {
  const m = /^bytes=(\d*)-(\d*)$/.exec(header || "");
  if (!m) return null;
  let start = m[1] === "" ? null : +m[1], end = m[2] === "" ? null : +m[2];
  if (start === null) { start = Math.max(0, size - end); end = size - 1; }
  if (end === null || end >= size) end = size - 1;
  if (start > end || start >= size) return "invalid";
  return { start, end };
}

/** serve bytes [base, base+size) of an R2 object as if it were its own file */
async function serveSlice(env, req, key, base, size, contentType) {
  if (size === 0) return new Response("", { status: 200, headers: { "content-type": contentType, "content-length": "0" } });
  const r = parseRange(req.headers.get("range"), size);
  if (r === "invalid") return new Response(null, { status: 416, headers: { "content-range": `bytes */${size}` } });
  const start = r ? r.start : 0, end = r ? r.end : size - 1;
  const obj = await env.MEDIA.get(key, { range: { offset: base + start, length: end - start + 1 } });
  if (!obj) return json({ error: "object missing" }, 404);
  const headers = { "content-type": contentType, "accept-ranges": "bytes", "content-length": String(end - start + 1),
    "cache-control": "private, max-age=31536000, immutable" };
  if (r) headers["content-range"] = `bytes ${start}-${end}/${size}`;
  return new Response(obj.body, { status: r ? 206 : 200, headers });
}

const typeOf = name => TYPES[(name.split(".").pop() || "").toLowerCase()] || "application/octet-stream";

function dayTitle(day) {
  const d = new Date(day + "T12:00:00Z");
  return d.toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", timeZone: "UTC" });
}

function shiftDay(day, n) {
  const d = new Date(day + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

async function getDay(env, day, device) {
  const stats = await env.DB.prepare("SELECT * FROM day_stats WHERE device=? AND day=?").bind(device, day).first();
  const dayStart = stats ? stats.day_start : null;
  let segments = [], transcripts = [], shots = [], audio = [];
  if (dayStart !== null) {
    const a = dayStart, b = dayStart + 86400;
    const [seg, tr, bun] = await env.DB.batch([
      env.DB.prepare("SELECT * FROM segments WHERE device=? AND ts_start>=? AND ts_start<? ORDER BY ts_start").bind(device, a, b),
      env.DB.prepare("SELECT * FROM transcripts WHERE device=? AND ts_start>=? AND ts_start<? ORDER BY ts_start").bind(device, a, b),
      env.DB.prepare("SELECT key, kind, files_json FROM bundles WHERE device=? AND day=? ORDER BY slot, key").bind(device, day),
    ]);
    segments = seg.results.map(s => ({ s: s.ts_start, e: s.ts_end, c: s.category, activity: s.activity, detail: s.detail, app: s.app }));
    segments = await mergeDeep(env, device, a, b, segments);
    transcripts = tr.results.map(t => [t.ts_start, t.ts_end, t.source, t.text, t.speaker || ""]);
    for (const row of bun.results) {
      const base = `/api/file/${encodeURIComponent(row.key)}/`;
      for (const f of JSON.parse(row.files_json)) {
        // screens: [name, offset, size, ts, app, title]   audio: [name, offset, size, ts_start, ts_end, source]
        if (row.kind === "screens") shots.push([f[3], base + encodeURIComponent(f[0]), f[4] || "", f[5] || ""]);
        else if (row.kind === "audio") audio.push([f[3], f[4], f[5], base + encodeURIComponent(f[0])]);
      }
    }
    shots.sort((x, y) => x[0] - y[0]);
    audio.sort((x, y) => x[0] - y[0]);
  }
  const summary = await env.DB.prepare("SELECT text FROM deep_summaries WHERE device=? AND day=?").bind(device, day).first()
    || await env.DB.prepare("SELECT text FROM summaries WHERE day=?").bind(day).first();
  return {
    day, device, title: dayTitle(day), dayStart: dayStart ?? Date.parse(day + "T00:00:00Z") / 1000,
    ai: segments.length > 0 && !segments.every(s => s.c === "other" || s.c === "away"),
    segments, minutes: stats ? JSON.parse(stats.minutes_json) : Array.from({ length: 1440 }, () => [0, 0, 0, 0]),
    apps: stats ? JSON.parse(stats.apps_json) : [], shots, transcripts, audio,
    summary: summary ? summary.text : "", first: stats?.first ?? null, last: stats?.last ?? null,
    categories: CATEGORIES, prev: shiftDay(day, -1), next: shiftDay(day, 1), generated: Date.now() / 1000, cloud: true,
  };
}

/** ranges a deep run covered, merged */
async function deepCovered(env, device, a, b) {
  const { results } = await env.DB.prepare("SELECT ts_start, ts_end FROM deep_runs WHERE device=? AND ts_end>? AND ts_start<? ORDER BY ts_start")
    .bind(device, a, b).all();
  const out = [];
  for (const r of results) {
    const s = Math.max(r.ts_start, a), e = Math.min(r.ts_end, b);
    if (out.length && s <= out[out.length - 1][1]) out[out.length - 1][1] = Math.max(out[out.length - 1][1], e);
    else out.push([s, e]);
  }
  return out;
}

/** the laptop's quick segments, with every deep-covered range replaced by the deep segments */
async function mergeDeep(env, device, a, b, quick) {
  const cov = await deepCovered(env, device, a, b);
  if (!cov.length) return quick;
  const out = [];
  for (const q of quick) {
    let pieces = [[q.s, q.e]];
    for (const [x, y] of cov) pieces = pieces.flatMap(([s, e]) => [[s, Math.min(e, x)], [Math.max(s, y), e]]).filter(([s, e]) => e - s >= 1);
    for (const [s, e] of pieces) out.push({ ...q, s, e });
  }
  for (const [x, y] of cov) {
    const { results } = await env.DB.prepare("SELECT * FROM deep_segments WHERE device=? AND ts_start>=? AND ts_start<? ORDER BY ts_start")
      .bind(device, x, y).all();
    for (const d of results) out.push({ s: d.ts_start, e: d.ts_end, c: d.category, activity: d.activity, detail: d.detail, app: d.app, deep: 1 });
  }
  return out.sort((p, q) => p.s - q.s);
}

async function deepStatus(env, device) {
  const [raw, runs] = await env.DB.batch([
    env.DB.prepare("SELECT day, hour, key, ts_start, ts_end, last_ts, bytes, tz, updated FROM raw_hours WHERE device=? ORDER BY day DESC, hour DESC LIMIT 120").bind(device),
    env.DB.prepare("SELECT id, ts_start, ts_end, created, note FROM deep_runs WHERE device=? ORDER BY ts_end DESC LIMIT 30").bind(device),
  ]);
  const last = await env.DB.prepare("SELECT ts_start, ts_end, category, activity FROM deep_segments WHERE device=? ORDER BY ts_start DESC LIMIT 1").bind(device).first();
  return { device, tz: raw.results[0]?.tz || null, raw_hours: raw.results.reverse(), runs: runs.results, last_deep_segment: last || null,
    now: Date.now() / 1000 };
}

async function deepIngest(env, body) {
  const device = String(body.device || "");
  if (!/^[a-z0-9_-]{1,40}$/i.test(device)) return json({ error: "bad device id" }, 400);
  const a = +body.ts_start, b = +body.ts_end;
  if (!(a > 1.6e9 && b > a && b - a <= 3 * 86400)) return json({ error: "bad range" }, 400);
  const segs = Array.isArray(body.segments) ? body.segments : [];
  for (const g of segs) {
    if (!(g.s >= a - 1 && g.e <= b + 1 && g.e > g.s)) return json({ error: `segment outside the range or empty: ${JSON.stringify(g).slice(0, 200)}` }, 400);
    if (!DEEP_CATEGORIES.has(g.c)) return json({ error: `unknown category ${g.c}` }, 400);
  }
  const now = Date.now() / 1000;
  const run = await env.DB.prepare("INSERT INTO deep_runs(device, ts_start, ts_end, created, note) VALUES(?,?,?,?,?) RETURNING id")
    .bind(device, a, b, now, String(body.note || "").slice(0, 2000)).first();
  const stmts = [env.DB.prepare("DELETE FROM deep_segments WHERE device=? AND ts_start>=? AND ts_start<?").bind(device, a, b)];
  for (const c of chunks(segs)) stmts.push(env.DB.prepare(
    `INSERT OR REPLACE INTO deep_segments SELECT ?1, json_extract(value,'$.s'), json_extract(value,'$.e'), json_extract(value,'$.c'),
       json_extract(value,'$.activity'), json_extract(value,'$.detail'), json_extract(value,'$.app'), ?2 FROM json_each(?3)`)
    .bind(device, run.id, JSON.stringify(c)));
  for (const sm of body.summaries || []) {
    if (/^\d{4}-\d{2}-\d{2}$/.test(sm.day) && typeof sm.text === "string" && sm.text)
      stmts.push(env.DB.prepare("INSERT OR REPLACE INTO deep_summaries VALUES(?,?,?,?)").bind(device, sm.day, sm.text, now));
  }
  await env.DB.batch(stmts);
  return json({ ok: true, run: run.id, segments: segs.length });
}

async function deepSince(env, device, since) {
  const { results: runs } = await env.DB.prepare("SELECT * FROM deep_runs WHERE device=? AND created>? ORDER BY created LIMIT 50").bind(device, since).all();
  for (const r of runs) {
    const { results } = await env.DB.prepare("SELECT * FROM deep_segments WHERE device=? AND ts_start>=? AND ts_start<? ORDER BY ts_start")
      .bind(device, r.ts_start, r.ts_end).all();
    r.segments = results.map(d => ({ s: d.ts_start, e: d.ts_end, c: d.category, activity: d.activity, detail: d.detail, app: d.app }));
  }
  const { results: summaries } = await env.DB.prepare("SELECT day, text, updated FROM deep_summaries WHERE device=? AND updated>?").bind(device, since).all();
  return { runs, summaries };
}

/** nearest screenshot to ts (within 2 min), served straight out of its tar bundle */
async function shot(env, req, device, day, ts) {
  const { results } = await env.DB.prepare("SELECT key, files_json FROM bundles WHERE device=? AND day=? AND kind='screens'").bind(device, day).all();
  let best = null;
  for (const row of results) for (const f of JSON.parse(row.files_json)) {
    const d = Math.abs(f[3] - ts);
    if (d <= 120 && (!best || d < best.d)) best = { d, key: row.key, f };
  }
  if (!best) return json({ error: "no screenshot within 2 minutes (not uploaded yet, or the screen didn't change)" }, 404);
  const res = await serveSlice(env, req, best.key, best.f[1], best.f[2], typeOf(best.f[0]));
  const h = new Headers(res.headers);
  h.set("x-shot-ts", String(best.f[3]));
  h.set("x-shot-app", encodeURIComponent(best.f[4] || ""));
  h.set("x-shot-title", encodeURIComponent(best.f[5] || ""));
  return new Response(res.body, { status: res.status, headers: h });
}

const CHUNK = 400;
function chunks(arr) {
  const out = [];
  for (let i = 0; i < arr.length; i += CHUNK) out.push(arr.slice(i, i + CHUNK));
  return out;
}

async function ingest(env, body) {
  const device = String(body.device || "").trim();
  if (!/^[a-z0-9_-]{1,40}$/i.test(device)) return json({ error: "bad device id" }, 400);
  const now = Date.now() / 1000;
  const stmts = [
    env.DB.prepare("INSERT INTO devices(id,name,kind,last_seen) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET last_seen=excluded.last_seen, name=COALESCE(excluded.name, devices.name), kind=COALESCE(excluded.kind, devices.kind)")
      .bind(device, body.deviceName ?? null, body.deviceKind ?? null, now),
  ];
  // Rows go in through json_each so one statement inserts hundreds of rows (D1 caps bound params per query).
  for (const d of body.days || []) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(d.day)) continue;
    const a = d.day_start, b = d.day_start + 86400;
    stmts.push(env.DB.prepare("INSERT OR REPLACE INTO day_stats VALUES(?,?,?,?,?,?,?,?)")
      .bind(device, d.day, a, d.first ?? null, d.last ?? null, JSON.stringify(d.minutes || []), JSON.stringify(d.apps || []), now));
    if (Array.isArray(d.segments)) {
      stmts.push(env.DB.prepare("DELETE FROM segments WHERE device=? AND ts_start>=? AND ts_start<?").bind(device, a, b));
      for (const c of chunks(d.segments)) stmts.push(env.DB.prepare(
        `INSERT OR REPLACE INTO segments SELECT ?1, json_extract(value,'$.s'), json_extract(value,'$.e'), json_extract(value,'$.c'),
           json_extract(value,'$.activity'), json_extract(value,'$.detail'), json_extract(value,'$.app') FROM json_each(?2)`).bind(device, JSON.stringify(c)));
    }
    if (Array.isArray(d.transcripts)) {
      stmts.push(env.DB.prepare("DELETE FROM transcripts WHERE device=? AND ts_start>=? AND ts_start<?").bind(device, a, b));
      for (const c of chunks(d.transcripts)) stmts.push(env.DB.prepare(
        `INSERT OR REPLACE INTO transcripts(device, ts_start, ts_end, source, text, speaker) SELECT ?1, json_extract(value,'$[0]'),
           json_extract(value,'$[1]'), json_extract(value,'$[2]'), json_extract(value,'$[3]'), json_extract(value,'$[4]') FROM json_each(?2)`).bind(device, JSON.stringify(c)));
    }
    if (typeof d.summary === "string" && d.summary) {
      stmts.push(env.DB.prepare("INSERT OR REPLACE INTO summaries VALUES(?,?,?)").bind(d.day, d.summary, now));
    }
  }
  for (const r of body.raw || []) {
    stmts.push(env.DB.prepare("INSERT OR REPLACE INTO raw_hours VALUES(?,?,?,?,?,?,?,?,?,?)")
      .bind(device, r.day, r.hour, r.key, r.start, r.end, r.last_ts ?? null, r.bytes ?? 0, r.tz ?? null, now));
  }
  for (const bnd of body.bundles || []) {
    stmts.push(env.DB.prepare("INSERT OR REPLACE INTO bundles VALUES(?,?,?,?,?,?,?,?)")
      .bind(bnd.key, device, bnd.kind, bnd.day, bnd.slot, bnd.bytes ?? 0, JSON.stringify(bnd.files || []), now));
  }
  await env.DB.batch(stmts);
  return json({ ok: true, statements: stmts.length });
}

async function route(req, env, url) {
  const p = url.pathname;
  const device = url.searchParams.get("device") || "mac";
  let m;
  if (p === "/api/ping") {
    const { results } = await env.DB.prepare("SELECT * FROM devices ORDER BY last_seen DESC").all();
    return json({ ok: true, devices: results });
  }
  if (p === "/api/days" && req.method === "GET") {
    const { results } = await env.DB.prepare("SELECT day, first, last FROM day_stats WHERE device=? ORDER BY day DESC").bind(device).all();
    return json(results);
  }
  if ((m = p.match(/^\/api\/day\/(\d{4}-\d{2}-\d{2})$/)) && req.method === "GET") return json(await getDay(env, m[1], device));
  if ((m = p.match(/^\/api\/file\/([^/]+)\/([^/]+)$/)) && req.method === "GET") {
    const key = decodeURIComponent(m[1]), name = decodeURIComponent(m[2]);
    const row = await env.DB.prepare("SELECT files_json FROM bundles WHERE key=?").bind(key).first();
    if (!row) return json({ error: "no such bundle" }, 404);
    const f = JSON.parse(row.files_json).find(x => x[0] === name);
    if (!f) return json({ error: "no such file in bundle" }, 404);
    return serveSlice(env, req, key, f[1], f[2], typeOf(name));
  }
  if ((m = p.match(/^\/api\/raw\/(.+)$/)) && req.method === "GET") {
    const key = decodeURIComponent(m[1]);
    const head = await env.MEDIA.head(key);
    if (!head) return json({ error: "not found" }, 404);
    return serveSlice(env, req, key, 0, head.size, head.httpMetadata?.contentType || typeOf(key));
  }
  if (p === "/api/shot" && req.method === "GET")
    return shot(env, req, device, url.searchParams.get("day") || "", +url.searchParams.get("ts"));
  if (p === "/api/deep/status" && req.method === "GET") return json(await deepStatus(env, device));
  if (p === "/api/deep/since" && req.method === "GET") return json(await deepSince(env, device, +(url.searchParams.get("since") || 0)));
  if (p === "/api/deep/ingest" && req.method === "POST") return deepIngest(env, await req.json());
  if (p === "/api/ingest" && req.method === "POST") return ingest(env, await req.json());
  if ((m = p.match(/^\/api\/upload\/([a-z0-9_-]{1,40})\/(.+)$/i)) && req.method === "PUT") {
    const key = `devices/${m[1]}/${decodeURIComponent(m[2])}`;
    if (key.includes("..")) return json({ error: "bad path" }, 400);
    const obj = await env.MEDIA.put(key, req.body, { httpMetadata: { contentType: req.headers.get("content-type") || typeOf(key) } });
    return json({ ok: true, key, size: obj.size });
  }
  return json({ error: "not found" }, 404);
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (!url.pathname.startsWith("/api/")) return env.ASSETS.fetch(req);
    if (!env.API_TOKEN) return json({ error: "API_TOKEN secret not set" }, 500);
    const tok = tokenFrom(req);
    if (!safeEqual(tok, env.API_TOKEN)) {
      // the cloud analyst's token: read anything, write only its own analysis results
      const analyst = env.ANALYST_TOKEN && safeEqual(tok, env.ANALYST_TOKEN);
      if (!analyst) return json({ error: "unauthorized" }, 401);
      if (req.method !== "GET" && url.pathname !== "/api/deep/ingest") return json({ error: "analyst token is read-only here" }, 403);
    }
    try {
      return await route(req, env, url);
    } catch (e) {
      return json({ error: String(e && e.message || e) }, 500);
    }
  },
};
