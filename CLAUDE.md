# CLAUDE.md

Guidance for Claude Code (claude.ai/code) in this repo.

## What this is

Study project: production-grade full-stack template. `prd.md` (in `.MY-FILES/`) defines target architecture. Codebase mid-migration — backend fully on target stack (TypeScript, Drizzle, Pino, Zod, Express 5), frontend fully on target stack (React 19, TanStack Router v1, TanStack Query v5, Tailwind v4).

Follow target patterns: TypeScript, ESM, Drizzle, Pino, Zod, TanStack Router/Query, Tailwind v4.

## Commands

### Backend (`backend/nodejs/`)
```bash
npm run dev          # tsx watch, port 3000 (OTEL SDK preloaded via NODE_OPTIONS)
npm run build        # tsc
npm start            # node dist/index.js (OTEL SDK preloaded via --import)
npm run db:generate  # drizzle-kit generate → db/mysql/migrations/
npm run db:migrate   # drizzle-kit migrate (runs pending migrations)
npm run db:seed      # run db/mysql/seed/seed.sql
npx tsc --noEmit     # type-check without emit
```

### Frontend (`front/react/`)
```bash
npm run dev      # Vite, port 5173
npm run build    # tsc + vite build
npm run preview
npx tsc --noEmit # type-check without emit
```

### Environment setup (native dev)
Copy `.env.example` to `backend/nodejs/.env` and set at minimum:
```
DATABASE_URL=mysql://root:password@localhost:3306/template
VITE_API_BASE_URL=http://localhost:3000/api/v1   # frontend .env
# Observability (optional — defaults work for native dev)
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://localhost:4318/v1/traces
OTEL_SERVICE_NAME=backend-nodejs
GF_ADMIN_PASSWORD=changeme
```

### Full stack via `manage.sh`
```bash
./manage.sh              # interactive menu (recommended)
./manage.sh start [native|docker]
./manage.sh stop  [native|docker]
./manage.sh status
./manage.sh logs  [backend|frontend|db|all]
./manage.sh rebuild [native|docker]
./manage.sh reset-db [native|docker]
./manage.sh monitoring [start|stop]   # observability stack (Docker only)
```

- **native mode**: DB in Docker (`docker-compose.db-dev.yml`), BE+FE via `npm run dev` (hot reload, :5173/:3000)
- **docker mode**: all services via `docker-compose.yml` (:80/:3000)
- **monitoring**: merged `docker-compose.observability.yml` — Grafana :3001, Prometheus :9090, Tempo :3200, Loki :3100

### First run (required before `manage.sh start`)
```bash
cd backend/nodejs && npm run db:generate   # generates db/mysql/migrations/ from schema
```
Migrations must exist before Docker or native start — `manage.sh` runs them post-healthcheck but cannot generate them.

### Smoke tests
```bash
GF_ADMIN_PASSWORD=changeme ./scripts/smoke-test-observability.sh
```
Verifies all observability signals end-to-end: backend health, metrics, otelcol, Prometheus, Loki, Tempo, Grafana. Run after the full stack + observability is up.

## Architecture

### Backend (`backend/nodejs/src/`)

TypeScript 5, ESM, Express 5. Layered per resource:

```
config.ts              — Zod-validated env config (single source of truth)
logger.ts              — Pino structured JSON logger
instrumentation.ts     — OTEL SDK preload: BatchSpanProcessor → otelcol; preloaded via
                         NODE_OPTIONS='--import' — runs before index.ts, bypasses Zod
db/client.ts           — Drizzle + mysql2 pool; db/schema/*.ts for schemas
errors.ts              — AppError(status, code, message)
middleware/
  requestLogger.ts     — request logger (requestId + metrics recording on res.finish)
  metrics.ts           — prom-client: Histogram, Counter, Gauge; metricsHandler for /metrics
  errorHandler.ts      — centralised error → AppError mapping
  validate.ts          — Zod request validation middleware
storage/               — StorageProvider interface + LocalStorage impl
events/                — DomainEventBus interface + NoOpEventBus impl
{resource}/
  *.schema.ts          — Drizzle table def + Zod validation schemas
  *.service.ts         — business logic, talks to db
  *.controller.ts      — req/res handling, calls service
  *.router.ts          — Express router, mounts controller handlers
index.ts               — bootstrap: create app, mount routers, start server; DB pool gauge
                         polling; ordered shutdown (HTTP → DB pool → OTEL SDK flush)
migrate.ts             — standalone migrator (not imported by index.ts); Docker runs it via
                         `node dist/migrate.js`; reads `MIGRATIONS_DIR` env var or falls back
                         to `../../db/mysql/migrations` relative to dist/ (works locally only)
```

Drizzle migrations output to `db/mysql/migrations/` (Flyway-compatible naming `V001__name.sql`).

**Middleware mount order in `app.ts`** (order matters):
1. `cors`, `express.json`
2. `/metrics` — mounted before requestLogger so Prometheus scrapes are not logged
3. `requestLogger` — records `http_requests_total` + `http_request_duration_seconds` on `res.finish`
4. resource routers, static uploads, health, errorHandler

### Frontend (`front/react/src/`)

React 19, TypeScript, Vite 6, TanStack Router v1 (file-based), TanStack Query v5, Tailwind v4.

```
routes/                — file-based routes (TanStack Router)
  __root.tsx           — root layout
  index.tsx            — home /
  {resource}/          — resource routes ($id.tsx, $id.edit.tsx, create.tsx, index.tsx)
api/                   — typed fetch wrappers per resource (no raw fetch in components)
```

Route file naming: `$id.tsx` → `/products/123`, `$id.edit.tsx` → `/products/123/edit`.
Route tree auto-generated into `routeTree.gen.ts` — do not edit manually.

### Database (`db/mysql/`)
- MySQL 8.4 (Docker only)
- Migrations: `db/mysql/migrations/V001__name.sql`
- Seed: `db/mysql/seed/seed.sql` — idempotent (runs only if table empty)

### Observability (`observability/`)

```
otelcol/config.yaml    — OTLP receiver (4317 gRPC, 4318 HTTP) → batch → Tempo; health_check :13133
tempo/config.yaml      — trace storage, single-node
prometheus/prometheus.yml — scrapes backend:3000/metrics every 15s
loki/config.yaml       — log storage, single-node inmemory ring
promtail/config.yaml   — Docker socket SD → labels service/container; json pipeline extracts
                         level + trace_id; ships to Loki
grafana/provisioning/  — datasources (Prometheus, Loki, Tempo) + dashboard provider
grafana/dashboards/
  backend-overview.json — request rate, error rate, P50/P95/P99, heap, event loop, DB pool, logs
```

Run command:
```bash
GF_ADMIN_PASSWORD=changeme \
  docker compose -f docker-compose.yml -f docker-compose.observability.yml up --build
```
Must run merged — not standalone. Observability services share the default network to resolve `backend:3000`.

**Known**: Loki and Tempo return HTTP 503 from `/ready` in single-node mode with `inmemory` kvstore — expected, does not affect functionality.

### API contract
Base path: `/api/v1`. All responses JSON.
- Error: `{ error: { code: string, message: string } }`
- List: `{ data: T[], meta: { total, page, limit } }`
- Single: `{ data: T }`
- Health: `GET /health` → `{ status, uptime, db }`
- Metrics: `GET /metrics` → Prometheus text format (optional bearer token via `METRICS_TOKEN`)

## Extension points

| Concern | How |
|---|---|
| S3 storage | Implement `S3Storage` vs `StorageProvider` interface, swap in `config.ts` |
| Kafka | Implement `KafkaEventBus` vs `DomainEventBus`, inject in `app.ts` / `index.ts` |
| OTEL metrics push | Add `OTLPMetricExporter` to `instrumentation.ts` (currently pull-based via prom-client) |
| OTEL logs pipeline | Add `OTLPLogExporter` to NodeSDK (currently logs go stdout → Promtail → Loki) |
| Tail sampling | Add `tail_sampling` processor in `observability/otelcol/config.yaml` |
| New resource | Add `{resource}/` dir with schema/service/controller/router; mount router in `app.ts` |
| Auth | Middleware layer before routers |

## Requirements

- All backend implementations must expose `GET /health` → `{ status, uptime, db }`.

## Code style

**Backend**: 2-space indent, semicolons, single quotes, `snake_case` filenames, `camelCase` vars. All DB queries through Drizzle (no raw SQL except migrations/seed).

**Frontend**: no semicolons, `PascalCase` component files, functional only, early returns for loading/error states. All server state via TanStack Query (no manual `useEffect` fetching).

## Docker notes

- `docker-compose.yml` build stanzas use `network: host` — required for WSL2 where Docker bridge DNS fails during `npm ci`.
- `MIGRATIONS_DIR=/app/migrations` set in docker-compose; migrations volume-mounted (`db/mysql/migrations:/app/migrations:ro`). Don't rely on relative `__dirname` paths from `dist/` inside containers.
- `VITE_API_BASE_URL` defaults to `/api/v1` when env var unset — correct for Docker (nginx proxies `/api/` to backend). For native dev, set to `http://localhost:3000/api/v1` in `front/react/.env`.
- Observability compose uses `:?` syntax (`${GF_ADMIN_PASSWORD:?...}`) — Docker fails fast if `GF_ADMIN_PASSWORD` unset.
