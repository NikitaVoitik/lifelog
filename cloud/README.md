# Lifelog cloud (Cloudflare)

A single Worker (`src/index.js`) in front of an R2 bucket (media) and a D1 database (timeline). It also serves the web
viewer (`public/index.html`, a copy of `pipeline/report.html` that `deploy.sh` refreshes on every deploy).

## Deploy

```bash
npm i -g wrangler && wrangler login
./deploy.sh            # idempotent; install.sh runs it too
```

`deploy.sh` creates the R2 bucket (`r2Bucket` in `~/Lifelog/config.json`, default `lifelog-media`) and the D1 database
`lifelog` if they don't exist, applies `schema.sql` (plus small migrations), deploys the Worker, sets the three token
secrets, and writes `cloudUrl`, `cloudToken`, `analystToken` and `phoneToken` into `~/Lifelog/config.json`.

`wrangler.toml` is generated from `wrangler.example.toml` on the first deploy and is gitignored, because it holds your
D1 database id. Check the Worker without deploying: `wrangler deploy --dry-run --config wrangler.example.toml`.

## Tokens

Every `/api/*` request needs `Authorization: Bearer <token>` (the viewer also accepts an `ll_token` cookie).

| Secret | Config key | Allowed |
|---|---|---|
| `API_TOKEN` | `cloudToken` | everything |
| `ANALYST_TOKEN` | `analystToken` | any `GET`, plus `POST /api/deep/ingest` |
| `PHONE_TOKEN` | `phoneToken` | `PUT /api/upload/<PHONE_DEVICE>/…`, `POST /api/phone/events`, `GET /api/phone/status` |

`PHONE_DEVICE` (Worker variable) defaults to `iphone`. Rotating a token: delete it from `config.json`, re-run
`deploy.sh`, then rebuild the phone app if it was `phoneToken`.

## API

| Route | What |
|---|---|
| `GET /api/ping` | health + known devices |
| `GET /api/days`, `GET /api/day/YYYY-MM-DD` | days with data; one day's timeline, stats, transcripts (deep results override quick ones) |
| `GET /api/file/<bundle>/<name>`, `GET /api/shot?day=&ts=` | one file out of a media tar (R2 range read); nearest screenshot |
| `GET /api/raw/<key>` | any R2 object (raw hours, bundles) |
| `POST /api/ingest` | the Mac's timeline, transcripts, stats and bundle index |
| `PUT /api/object/<key>` | the Mac's uploads to R2 (≤ ~95 MB; larger files go through `wrangler r2 object put`) |
| `PUT /api/upload/<device>/<path>`, `POST /api/phone/events`, `GET /api/phone/since`, `GET /api/phone/status` | iPhone data |
| `GET /api/deep/status`, `GET /api/deep/since`, `POST /api/deep/ingest` | deep-analysis state and results |

Most routes take `?device=` (default `mac`).

## Removing it

`wrangler delete` (Worker), `wrangler d1 delete lifelog`, and empty + delete the R2 bucket in the dashboard.
