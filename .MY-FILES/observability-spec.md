# Observability — Pre-Implementation Spec v2

**Generated:** 2026-05-16  
**Source PRD:** `.MY-FILES/observability.prd.md`  
**Status:** Critic-approved (v2 — second critic round; all critical flaws + optimizations applied)

---

## §1 Summary

Add all three observability pillars (traces, metrics, logs) to the existing Node.js backend using the OpenTelemetry SDK + a Grafana-stack side-car compose file. The backend emits OTLP traces to an OTel Collector (→ Tempo), exposes `/metrics` for Prometheus scrape, and writes JSON logs to stdout tailed by Promtail (→ Loki). Grafana provides unified UI with provisioned datasources and a `backend-overview` dashboard. Infrastructure lives in `docker-compose.observability.yml` (merged with `docker-compose.yml` at runtime). Backend source changes: one new preload file, one new middleware, modifications to `config.ts`, `app.ts`, `requestLogger.ts`, `index.ts`, and `package.json`. No DB schema changes. No frontend changes.

---

## §2 Stack Snapshot

| Layer | Technology | Version |
|---|---|---|
| Runtime | Node.js | 22 LTS |
| Language | TypeScript | 5.7 strict, ESM (NodeNext) |
| Framework | Express | 5 |
| ORM | Drizzle + mysql2 | 0.38 / 3.11 |
| Validation | Zod | 3.23 |
| Logger | Pino | 9 |
| Containerisation | Docker Compose | v2 |
| DB | MySQL | 8.4 |
| OTEL SDK | @opentelemetry/sdk-node | 0.52.x pinned |
| Metrics lib | prom-client | 15.x pinned |
| Trace backend | Grafana Tempo | 2.5 |
| Metrics backend | Prometheus | 2.53 |
| Log backend | Grafana Loki | 3.1 |
| Log shipper | Grafana Promtail | 3.1 |
| Collector | OTel Collector Contrib | 0.105 |
| UI | Grafana | 11.1 |

---

## §3 Architecture Patterns Applied

- **Gate C5 — Observability (OTEL + Grafana):** full three-pillar stack; drives §7, §14.
- All other Gate C patterns: N/A.

---

## §4 Design Decisions

**1. `NODE_OPTIONS` preload instead of `--import` tsx flag.**  
`instrumentation.ts` must be loaded before any app module. Using `NODE_OPTIONS='--import ...' tsx watch src/index.ts` instead of `tsx watch --import ...` avoids tsx flag-parsing gaps and prevents watch-reload from re-running `sdk.start()` and re-registering instrumentations on each file save (tsx hot-reload re-evaluates `index.ts` but `NODE_OPTIONS` instrumentation runs once per process).

**2. `ATTR_SERVICE_NAME` + `resourceFromAttributes` — PRD API corrected.**  
PRD draft used deprecated `SEMRESATTRS_SERVICE_NAME` and `new Resource()`. Current stable otel-js API uses `ATTR_SERVICE_NAME` and `resourceFromAttributes()`. `[ASSUMPTION — verify exact compatible package versions; see §7 Step 8 for pinned matrix]`.

**3. dotenv loaded in `instrumentation.ts`; OTEL env vars bypass Zod config by design.**  
`instrumentation.ts` runs before `index.ts` so dotenv must load here. OTEL vars read directly from `process.env` — intentional bypass of `config.ts`, documented with cross-reference comment in both files. Defaults must stay in sync.

**4. Ordered shutdown with keep-alive drain guard.**  
`clearInterval(dbGaugeInterval)` fires immediately on signal (stops gauge writes). `server.close(cb)` + `server.closeAllConnections()` (Node 18.2+) drains keep-alive sockets. The entire chain runs inside a `Promise.race` with an 8s timeout so `sdk.shutdown()` always flushes the span queue even if sockets stall. `sdk` exported from `instrumentation.ts`, imported by `index.ts`. No SIGTERM handler in `instrumentation.ts`.

**5. `requestLogger.ts` modified for metrics recording only.**  
Trace and log correlation auto-injected by `instrumentation-pino`. Metrics require an addition to `requestLogger.ts`. The `/metrics` path guard is removed (dead code — `/metrics` is mounted before `requestLogger`, so scrape requests never reach it).

**6. `/metrics` mounted before `requestLogger`.**  
Prometheus scrape excluded from access logs. Protected by METRICS_TOKEN bearer check with `WWW-Authenticate: Bearer` on 401.

**7. Route label: `${req.baseUrl}${req.route?.path ?? ''}` or `'unmatched'`.**  
`req.route?.path` alone returns `/:id` for mounted routers — two different resources with the same sub-path collapse into one time series. Composing `baseUrl + path` gives `/api/v1/products/:id`. Unmatched routes use literal `'unmatched'` (prevents cardinality explosion from scan traffic).

**8. Only required auto-instrumentations enabled.**  
Explicit disable list keeps only `http`, `express`, `mysql2`, `pino`. Alternatively: switch from `getNodeAutoInstrumentations` to an explicit array of 4 instrumentations (avoids maintaining the disable list across auto-instrumentations-node updates). Spec uses the disable-list approach to match PRD; note the alternative in §20.

**9. BatchSpanProcessor with explicit queue config.**  
`maxQueueSize: 2048` (not 512 — collector-down at moderate RPS fills 512 in < 3s). `DiagConsoleLogger` at WARN surfaces drops in stderr (tailed by Promtail).

**10. `prom-client` pull model, not OTEL metrics SDK push.**  
Prometheus scrape. Simpler config, no OTLP metrics pipeline. PRD explicit choice.

**11. DB pool gauges: self-check + event-counter pattern.**  
mysql2 pool internals (`_allConnections`) are not part of the public API. Startup self-check: if fields are absent, log warn and skip gauge registration. Preferred approach: track `acquire`/`release` events on the pool if internals are absent (documented in §7 Step 3).

**12. `trace_id` extracted as Loki field, NOT as a Loki label.**  
Promoting `trace_id` to a Loki label creates an unbounded high-cardinality index. Keep it as a JSON-extracted field for derived-field linking only; `level` is the only promoted label (low cardinality, high utility).

**13. `collectDefaultMetrics` guarded.**  
Guard call with `if (!register.getSingleMetric('process_cpu_user_seconds_total'))` to prevent prom-client crash on double-import (tsx hot-reload edge case).

**14. `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (signal-specific var).**  
OTEL convention: `OTEL_EXPORTER_OTLP_ENDPOINT` is the base URL; the exporter appends `/v1/traces`. Using the signal-specific `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` sets the full URL explicitly and avoids future confusion if metrics/logs exporters are added.

**15. Grafana admin password: no default.**  
`GF_SECURITY_ADMIN_PASSWORD` must be set via env; compose fails-fast if absent. Anonymous Viewer still allowed for dashboard browsing.

**16. Compose files merged at runtime.**  
`docker compose -f docker-compose.yml -f docker-compose.observability.yml up`. Services share default network. Not supported standalone.

---

## §5 API Contract

No new user-facing endpoints.

| Method | Path | Auth? | Response |
|---|---|---|---|
| `GET` | `/metrics` | Bearer token (`METRICS_TOKEN` env var; unauthenticated if unset) | Prometheus text format |

**Example response (excerpt):**
```
# HELP http_requests_total Total HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET",route="/api/v1/products",status_code="200"} 42
http_requests_total{method="GET",route="unmatched",status_code="404"} 3
# HELP http_request_duration_seconds HTTP request latency in seconds
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.05",method="GET",route="/api/v1/products",status_code="200"} 38
```

---

## §6 DB Schema & Migrations

N/A — no database changes.

---

## §7 Backend Implementation Plan

### Step 1 — `backend/nodejs/src/instrumentation.ts` (new)

Full file:

```typescript
import 'dotenv/config'
import { NodeSDK } from '@opentelemetry/sdk-node'
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http'
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node'
import { resourceFromAttributes } from '@opentelemetry/resources'
import { ATTR_SERVICE_NAME } from '@opentelemetry/semantic-conventions'
import { BatchSpanProcessor } from '@opentelemetry/sdk-trace-node'
import { diag, DiagConsoleLogger, DiagLogLevel } from '@opentelemetry/api'

// Surface span drops to stderr (tailed by Promtail → Loki)
diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.WARN)

// OTEL_EXPORTER_OTLP_TRACES_ENDPOINT and OTEL_SERVICE_NAME read from process.env here.
// They intentionally bypass config.ts (Zod not bootstrapped yet at preload time).
// Defaults must stay in sync with config.ts defaults — see cross-reference comment there.
const endpoint = process.env['OTEL_EXPORTER_OTLP_TRACES_ENDPOINT'] ?? 'http://localhost:4318/v1/traces'
const serviceName = process.env['OTEL_SERVICE_NAME'] ?? 'backend-nodejs'

const exporter = new OTLPTraceExporter({ url: endpoint })

export const sdk = new NodeSDK({
  resource: resourceFromAttributes({
    [ATTR_SERVICE_NAME]: serviceName,
  }),
  spanProcessor: new BatchSpanProcessor(exporter, {
    maxQueueSize: 2048,
    maxExportBatchSize: 64,
    scheduledDelayMillis: 500,
  }),
  instrumentations: [
    getNodeAutoInstrumentations({
      // Keep only: http, express, mysql2, pino (all enabled by default)
      '@opentelemetry/instrumentation-fs': { enabled: false },
      '@opentelemetry/instrumentation-dns': { enabled: false },
      '@opentelemetry/instrumentation-net': { enabled: false },
      '@opentelemetry/instrumentation-undici': { enabled: false },
      '@opentelemetry/instrumentation-winston': { enabled: false },
      '@opentelemetry/instrumentation-bunyan': { enabled: false },
      '@opentelemetry/instrumentation-connect': { enabled: false },
      '@opentelemetry/instrumentation-hapi': { enabled: false },
      '@opentelemetry/instrumentation-koa': { enabled: false },
      '@opentelemetry/instrumentation-fastify': { enabled: false },
      '@opentelemetry/instrumentation-restify': { enabled: false },
      '@opentelemetry/instrumentation-pg': { enabled: false },
      '@opentelemetry/instrumentation-mongodb': { enabled: false },
      '@opentelemetry/instrumentation-redis': { enabled: false },
      '@opentelemetry/instrumentation-redis-4': { enabled: false },
      '@opentelemetry/instrumentation-ioredis': { enabled: false },
      '@opentelemetry/instrumentation-graphql': { enabled: false },
      '@opentelemetry/instrumentation-grpc': { enabled: false },
    }),
  ],
})

sdk.start()
// Shutdown handled by index.ts in ordered sequence — do NOT add SIGTERM handler here.
```

### Step 2 — `backend/nodejs/src/middleware/metrics.ts` (new)

Full file:

```typescript
import { register, collectDefaultMetrics, Histogram, Counter, Gauge } from 'prom-client'
import type { RequestHandler } from 'express'

// Guard against double-registration on tsx hot-reload
if (!register.getSingleMetric('process_cpu_user_seconds_total')) {
  collectDefaultMetrics()
}

export const httpRequestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request latency in seconds',
  labelNames: ['method', 'route', 'status_code'] as const,
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
})

export const httpRequestTotal = new Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status_code'] as const,
})

export const dbPoolActive = new Gauge({
  name: 'db_pool_connections_active',
  help: 'Active DB pool connections',
})

export const dbPoolIdle = new Gauge({
  name: 'db_pool_connections_idle',
  help: 'Idle DB pool connections',
})

export const metricsHandler: RequestHandler = async (_req, res) => {
  res.set('Content-Type', register.contentType)
  res.end(await register.metrics())
}
```

### Step 3 — DB pool gauge polling (additions to `backend/nodejs/src/db/client.ts` and `index.ts`)

**`db/client.ts`** — export the raw pool alongside existing exports:

```typescript
export { pool }  // add alongside: export const db = drizzle(pool, ...)
```

**`index.ts`** — after existing imports, add:

```typescript
import { dbPoolActive, dbPoolIdle } from './middleware/metrics.js'
import { sdk } from './instrumentation.js'
```

After pool is available (immediately after `import { db, closePool, pool }`), add gauge polling:

```typescript
// mysql2 pool internal fields are not part of the public API.
// Self-check: if fields absent, skip gauge registration and log a warning.
// [ASSUMPTION — verify against mysql2 3.11 source; field names may change on patch bumps]
// Alternative if internals absent: subscribe to pool 'acquire'/'release' events instead.
const poolInternals = (pool as unknown as {
  pool?: { _allConnections?: unknown[]; _freeConnections?: unknown[] }
}).pool

let dbGaugeInterval: ReturnType<typeof setInterval> | null = null

if (poolInternals?._allConnections !== undefined) {
  dbGaugeInterval = setInterval(() => {
    const total = poolInternals._allConnections?.length ?? 0
    const free = poolInternals._freeConnections?.length ?? 0
    dbPoolActive.set(total - free)
    dbPoolIdle.set(free)
  }, 5000)
} else {
  logger.warn('mysql2 pool internals unavailable — db_pool_connections gauges will not be populated')
}
```

### Step 4 — `backend/nodejs/src/middleware/requestLogger.ts` (modified)

Add after existing imports:

```typescript
import { httpRequestDuration, httpRequestTotal } from './metrics.js'
```

In `res.on('finish')` callback, after `logger.info(...)`:

```typescript
    // /metrics is mounted before this middleware — this branch fires for all other routes.
    const route = req.route
      ? `${req.baseUrl}${req.route.path as string}`
      : 'unmatched'
    const durationSec = (Date.now() - start) / 1000
    httpRequestDuration.observe(
      { method: req.method, route, status_code: String(res.statusCode) },
      durationSec,
    )
    httpRequestTotal.inc({ method: req.method, route, status_code: String(res.statusCode) })
```

Notes:
- `req.route?.path` alone gives `/:id`; `req.baseUrl` gives `/api/v1/products` — composing gives `/api/v1/products/:id`.
- No `/metrics` guard needed — the endpoint is mounted before `requestLogger`.

### Step 5 — `backend/nodejs/src/index.ts` (modified — ordered shutdown)

Add imports:

```typescript
import { sdk } from './instrumentation.js'
import { dbPoolActive, dbPoolIdle } from './middleware/metrics.js'
```

Replace existing `shutdown` function:

```typescript
const shutdown = async () => {
  logger.info('Shutting down')

  // 1. Stop gauge polling immediately (no new writes mid-drain)
  if (dbGaugeInterval) clearInterval(dbGaugeInterval)

  // 2. Stop accepting new connections + drain keep-alive sockets (Node 18.2+)
  await new Promise<void>((resolve) => {
    server.close(() => resolve())
    server.closeAllConnections()   // force-close idle keep-alive connections
  })

  // 3. Drain DB pool then flush OTEL spans — race against 8s timeout
  await Promise.race([
    (async () => {
      await closePool()
      await sdk.shutdown()
    })(),
    new Promise<void>((_, reject) =>
      setTimeout(() => reject(new Error('Shutdown timeout')), 8000)
    ),
  ]).catch((err) => logger.error({ err }, 'Shutdown error — forcing exit'))

  process.exit(0)
}
```

### Step 6 — `backend/nodejs/src/app.ts` (modified)

Add import after existing imports:

```typescript
import { metricsHandler } from './middleware/metrics.js'
import type { RequestHandler } from 'express'
```

In `createApp`, insert before `app.use(requestLogger)`:

```typescript
  const metricsAuth: RequestHandler = (req, res, next) => {
    const token = process.env['METRICS_TOKEN']
    if (!token) return next()  // unauthenticated if METRICS_TOKEN not set (dev default)
    if (req.headers.authorization !== `Bearer ${token}`) {
      res.setHeader('WWW-Authenticate', 'Bearer')
      res.status(401).end()
      return
    }
    next()
  }

  // Mount before requestLogger: Prometheus scrape requests excluded from access logs
  app.get('/metrics', metricsAuth, metricsHandler)
  app.use(requestLogger)
```

### Step 7 — `backend/nodejs/src/config.ts` (modified)

Add two fields to the Zod schema:

```typescript
  // Cross-reference: also read by instrumentation.ts (OTEL preload — bypasses Zod by design).
  // Defaults in instrumentation.ts must stay in sync with these defaults.
  OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: z.string().default('http://localhost:4318/v1/traces'),
  OTEL_SERVICE_NAME: z.string().default('backend-nodejs'),
```

### Step 8 — `backend/nodejs/package.json` (modified)

**scripts:**
```json
"dev":   "NODE_OPTIONS='--import ./src/instrumentation.ts' tsx watch src/index.ts",
"start": "node --import ./dist/instrumentation.js dist/index.js"
```

Note on dev script: `NODE_OPTIONS` evaluates `instrumentation.ts` once per process launch. tsx file-watch reloads re-evaluate `index.ts` only — SDK is not re-registered on each save. On Windows, use cross-env: `cross-env NODE_OPTIONS='--import ./src/instrumentation.ts' tsx watch src/index.ts`.

**dependencies — pinned exact versions** `[ASSUMPTION — run `npm view @opentelemetry/sdk-node versions` to confirm latest stable before install; otel-js publishes sdk-node + core + semconv in coordinated releases]`:

```json
"@opentelemetry/api": "1.9.0",
"@opentelemetry/auto-instrumentations-node": "0.48.0",
"@opentelemetry/exporter-trace-otlp-http": "0.52.1",
"@opentelemetry/resources": "1.25.1",
"@opentelemetry/sdk-node": "0.52.1",
"@opentelemetry/sdk-trace-node": "1.25.1",
"@opentelemetry/semantic-conventions": "1.25.1",
"prom-client": "15.1.3"
```

`@opentelemetry/sdk-trace-node` required because `BatchSpanProcessor` is imported directly (Step 1).

---

## §8 Frontend Implementation Plan

N/A — PRD explicitly excludes frontend browser tracing.

---

## §9–§11 Real-time / WebSocket / Events / AI Plans

N/A.

---

## §12 Validation & Error Handling

No new Zod schemas. No new error codes.

`/metrics` errors: propagate to existing `errorHandler`. Config validation: OTEL vars have `.default()` — no throw on missing vars; app starts and serves without collector running.

---

## §13 Auth & Security Notes

- `/metrics` protected by METRICS_TOKEN bearer check (Step 6) with `WWW-Authenticate: Bearer` on 401. If `METRICS_TOKEN` unset: unauthenticated (acceptable in Docker internal network; set token before any internet-facing deploy).
- New env var: `METRICS_TOKEN` (optional string). Add to `.env.example` with comment.
- No auth changes to existing `/api/v1/*` routes.
- Span attributes: `http.url` may include query params — no PII in current product API; acceptable.
- DB spans: `db.statement` parameterised (Drizzle); no raw user input.
- `diag` WARN logger writes to stderr; tailed by Promtail; no PII in OTEL diagnostic messages.
- No CORS delta.

---

## §14 Observability & Telemetry

### Collector + backend routing

| Signal | Path |
|---|---|
| Traces | Backend → OTLP HTTP `otelcol:4318/v1/traces` → Collector batch → OTLP gRPC `tempo:4317` → Tempo |
| Metrics | Prometheus scrapes `backend:3000/metrics` every 15s |
| Logs | Backend stdout JSON → Docker log driver → Promtail Docker SD → Loki push `loki:3100` |

OTEL SDK init: `backend/nodejs/src/instrumentation.ts` (preload via `NODE_OPTIONS`).  
Resource attrs: `service.name` from `OTEL_SERVICE_NAME`.

### Distributed tracing

| Span name | Layer | Auto/Manual | Key attributes |
|---|---|---|---|
| `GET /api/v1/products` | HTTP server | Auto (Express instr) | `http.method`, `http.route`, `http.status_code`, `net.peer.ip` |
| `mysql.query` | DB | Auto (mysql2 instr) | `db.system=mysql`, `db.name`, `db.statement` (parameterised) |
| `GET /health` | HTTP server | Auto | same HTTP attrs |

Propagation: W3C TraceContext. Sampling: 100% always-on.

### Metrics

| Metric name | Instrument | Unit | Labels | Where emitted |
|---|---|---|---|---|
| `http_requests_total` | Counter | requests | `method`, `route`, `status_code` | `requestLogger.ts` `res.finish` |
| `http_request_duration_seconds` | Histogram | seconds | `method`, `route`, `status_code` | `requestLogger.ts` `res.finish` |
| `db_pool_connections_active` | Gauge | connections | — | `index.ts` setInterval (if pool internals available) |
| `db_pool_connections_idle` | Gauge | connections | — | `index.ts` setInterval |
| `nodejs_heap_size_used_bytes` | Gauge (default) | bytes | — | `collectDefaultMetrics()` |
| `nodejs_eventloop_lag_seconds` | Histogram (default) | seconds | — | `collectDefaultMetrics()` |
| `nodejs_gc_duration_seconds` | Histogram (default) | seconds | `kind` | `collectDefaultMetrics()` |
| `process_cpu_seconds_total` | Counter (default) | seconds | — | `collectDefaultMetrics()` |

Cardinality: `method` (4), `route` (finite patterns + `"unmatched"`), `status_code` (bounded range). Safe.

### Structured logging

Pino 9 JSON stdout. `instrumentation-pino` auto-injects:

```json
{
  "level": "info", "time": 1716000000000, "msg": "request completed",
  "requestId": "...", "method": "GET", "statusCode": 200, "responseTimeMs": 42,
  "trace_id": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
  "span_id": "f1e2d3c4b5a69870",
  "trace_flags": "01"
}
```

`trace_id` field name confirmed for `@opentelemetry/instrumentation-pino`. `[ASSUMPTION — verify field name after install; update Promtail `json` expression and Loki derived-field regex if `traceId` is emitted instead]`.

### Grafana Dashboards

**Dashboard: `backend-overview`**
- UID: `backend-overview`, Folder: `Template`
- Provisioned from `observability/grafana/dashboards/backend-overview.json`

| Panel | Datasource | Viz | Query |
|---|---|---|---|
| Request Rate (req/s) | Prometheus | Time series | `sum(rate(http_requests_total[1m])) by (route)` |
| Error Rate (%) | Prometheus | Time series | `100 * sum(rate(http_requests_total{status_code=~"5.."}[1m])) / sum(rate(http_requests_total[1m]))` |
| P50 Latency | Prometheus | Time series | `histogram_quantile(0.5, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, route))` |
| P95 Latency | Prometheus | Time series | `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, route))` |
| P99 Latency | Prometheus | Time series | `histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, route))` |
| Heap Used | Prometheus | Time series | `nodejs_heap_size_used_bytes` |
| Event Loop Lag | Prometheus | Time series | `nodejs_eventloop_lag_seconds` |
| DB Pool Active | Prometheus | Stat | `db_pool_connections_active` |
| Logs | Loki | Logs | `{service="backend"}` |
| Traces link | — | — | Explore → Tempo (via derived field from log trace_id) |

Loki→Tempo derived field: regex `"trace_id"\s*:\s*"([0-9a-f]{32})"` maps to Tempo trace ID. `trace_id` is extracted as a Loki **field** (not a Loki label — high cardinality).

Dashboard JSON: generate via Grafana UI after provisioning, export, commit. `[ASSUMPTION]`

### Alerting / Frontend observability

N/A — PRD non-goals.

### Health check

`GET /health` unchanged. OTel Collector unavailability non-fatal — SDK buffers 2048 spans, retries.

---

## §15 Infra & Deployment Notes

### New env vars

| Var | Required | Default | Native dev | Docker value |
|---|---|---|---|---|
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | No | `http://localhost:4318/v1/traces` | `http://localhost:4318/v1/traces` | `http://otelcol:4318/v1/traces` |
| `OTEL_SERVICE_NAME` | No | `backend-nodejs` | `backend-nodejs` | `backend-nodejs` |
| `METRICS_TOKEN` | No | unset (open) | unset | set for prod |
| `GF_ADMIN_PASSWORD` | **Yes** | none (fail-fast) | any string | secure string |

`.env.example` additions:
```
# Observability
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://localhost:4318/v1/traces
OTEL_SERVICE_NAME=backend-nodejs
# METRICS_TOKEN=changeme   # uncomment to protect /metrics
GF_ADMIN_PASSWORD=changeme  # required for grafana admin login
```

### `docker-compose.yml` — backend service additions

```yaml
backend:
  environment:
    # ... existing vars ...
    OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: http://otelcol:4318/v1/traces
    OTEL_SERVICE_NAME: backend-nodejs
    # METRICS_TOKEN: ${METRICS_TOKEN}
```

### New file: `docker-compose.observability.yml`

```yaml
services:
  otelcol:
    image: otel/opentelemetry-collector-contrib:0.105.0
    ports:
      - "4317:4317"
      - "4318:4318"
    volumes:
      - ./observability/otelcol/config.yaml:/etc/otelcol-contrib/config.yaml:ro
    command: ["--config=/etc/otelcol-contrib/config.yaml"]

  tempo:
    image: grafana/tempo:2.5.0
    ports:
      - "3200:3200"
    volumes:
      - ./observability/tempo/config.yaml:/etc/tempo.yaml:ro
      - tempo_data:/var/tempo
    command: ["-config.file=/etc/tempo.yaml"]

  prometheus:
    image: prom/prometheus:v2.53.0
    ports:
      - "9090:9090"
    volumes:
      - ./observability/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus

  loki:
    image: grafana/loki:3.1.0
    ports:
      - "3100:3100"
    volumes:
      - ./observability/loki/config.yaml:/etc/loki/config.yaml:ro
      - loki_data:/loki
    command: ["-config.file=/etc/loki/config.yaml"]

  promtail:
    image: grafana/promtail:3.1.0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./observability/promtail/config.yaml:/etc/promtail/config.yaml:ro
    command: ["-config.file=/etc/promtail/config.yaml"]

  grafana:
    image: grafana/grafana:11.1.0
    ports:
      - "3001:3000"
    environment:
      GF_AUTH_ANONYMOUS_ENABLED: "true"
      GF_AUTH_ANONYMOUS_ORG_ROLE: Viewer
      GF_SECURITY_ADMIN_PASSWORD: "${GF_ADMIN_PASSWORD:?GF_ADMIN_PASSWORD must be set}"
    volumes:
      - ./observability/grafana/provisioning:/etc/grafana/provisioning:ro
      - ./observability/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana_data:/var/lib/grafana

volumes:
  tempo_data:
  prometheus_data:
  loki_data:
  grafana_data:
```

Note: `:?` in `${GF_ADMIN_PASSWORD:?...}` causes docker compose to fail-fast if var unset.

**Run command:**
```bash
GF_ADMIN_PASSWORD=changeme docker compose -f docker-compose.yml -f docker-compose.observability.yml up --build
```

Do NOT run observability compose alone — Prometheus cannot resolve `backend:3000`.

### Config files (all new, version-controlled)

**`observability/otelcol/config.yaml`:**
```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    send_batch_size: 64
    timeout: 1s

exporters:
  otlp/tempo:
    endpoint: tempo:4317
    tls:
      insecure: true

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp/tempo]
```

**`observability/tempo/config.yaml`:**
```yaml
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317

storage:
  trace:
    backend: local
    local:
      path: /var/tempo

compactor:
  compaction:
    block_retention: 1h
```

**`observability/prometheus/prometheus.yml`:**
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: backend-nodejs
    static_configs:
      - targets: ['backend:3000']
    metrics_path: /metrics
    # Uncomment if METRICS_TOKEN set:
    # bearer_token: <token>
```

**`observability/loki/config.yaml`:**
```yaml
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
```

**`observability/promtail/config.yaml`:**
```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
    relabel_configs:
      # Map Docker Compose service name → Loki 'service' label
      - source_labels: ['__meta_docker_container_label_com_docker_compose_service']
        target_label: service
      - source_labels: ['__meta_docker_container_name']
        regex: '/(.+)'
        target_label: container
    pipeline_stages:
      - json:
          expressions:
            level: level
            trace_id: trace_id   # extracted as field, NOT promoted to label (high cardinality)
      - labels:
          level:                 # only 'level' promoted to Loki label (low cardinality)
```

With this config `service` = Docker Compose service name. Backend service in `docker-compose.yml` is `backend` → Loki label `service="backend"`. Dashboard query: `{service="backend"}`.

**`observability/grafana/provisioning/datasources/datasources.yaml`:**
```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus
    url: http://prometheus:9090
    isDefault: true

  - name: Loki
    type: loki
    uid: loki
    url: http://loki:3100
    jsonData:
      derivedFields:
        - name: TraceID
          matcherRegex: '"trace_id"\s*:\s*"([0-9a-f]{32})"'
          url: '${__value.raw}'
          datasourceUid: tempo

  - name: Tempo
    type: tempo
    uid: tempo
    url: http://tempo:3200
    jsonData:
      tracesToLogsV2:
        datasourceUid: loki
        filterByTraceID: true
      lokiSearch:
        datasourceUid: loki
      serviceMap:
        datasourceUid: prometheus
```

**`observability/grafana/provisioning/dashboards/dashboards.yaml`:**
```yaml
apiVersion: 1
providers:
  - name: default
    folder: Template
    type: file
    options:
      path: /var/lib/grafana/dashboards
```

**`observability/grafana/dashboards/backend-overview.json`:**  
Generate from Grafana UI → panels per §14 → export → commit. Set `"uid": "backend-overview"`. `[ASSUMPTION]`

---

## §16 Side-Effect Sweep Result

**DB / persistence:** No new tables, columns, FKs, migrations. ✓  
**API:** Additive. `/metrics` is new, unauthenticated or bearer-protected. ✓  
**Events / Frontend:** N/A. ✓  
**Filesystem:** Logs to stdout; no new dirs. ✓  
**Docker:**
- Migrator reachable: N/A. ✓
- `VITE_*` vars: N/A. ✓
- nginx proxy: N/A (`/metrics` not proxied; Prometheus scrapes backend directly). ✓
- Build networking: N/A (observability images pre-built). ✓

**Observability:**
- Spans: auto-covered (Express + mysql2). ✓
- Cardinality: bounded. `"unmatched"` for 404s. `trace_id` NOT a Loki label. ✓
- `trace_id`/`span_id` in logs: auto-injected. ✓
- PII scrubbed: no PII in current API. ✓

**Security:**
- `/metrics` bearer + `WWW-Authenticate` header. ✓
- No hardcoded secrets. ✓
- No CORS delta. ✓

---

## §17 Compatibility & Rollout Sweep Result

**Rollback:** Revert `NODE_OPTIONS` in scripts, revert `app.ts`/`requestLogger.ts`/`index.ts` additions, remove OTEL env vars from compose. No data loss. No down-migration. ✓  
**API/DB/Distributed/Frontend:** All N/A or non-breaking. ✓  
**New service dep:** OTel Collector — non-fatal if down (SDK buffers 2048 spans, retries). ✓

---

## §18 Seed Data

N/A.

---

## §19 Verification Steps

### Golden path (Docker merged)

1. Set env and start:
   ```bash
   GF_ADMIN_PASSWORD=changeme \
   docker compose -f docker-compose.yml -f docker-compose.observability.yml up --build
   ```

2. Confirm all containers running:
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.observability.yml ps
   ```

3. Generate traces:
   ```bash
   curl http://localhost:3000/api/v1/products
   # → 200 { data: [...], meta: {...} }
   ```

4. Verify `/metrics`:
   ```bash
   curl http://localhost:3000/metrics | grep http_requests_total
   # → http_requests_total{method="GET",route="/api/v1/products",status_code="200"} 1
   ```

5. Prometheus target UP:
   - `http://localhost:9090/targets` → `backend-nodejs` state: UP

6. Trace in Tempo:
   - Grafana `http://localhost:3001` (login: admin / changeme)
   - Explore → Tempo → Search → recent trace
   - Verify: root = HTTP GET `/api/v1/products`, child = `mysql.query`

7. Logs in Loki with trace_id:
   - Explore → Loki → `{service="backend"}`
   - Log lines contain `trace_id` (32-char hex)

8. Log → Trace derived field:
   - Click `trace_id` value in log line → navigates to Tempo trace

9. Dashboard loaded:
   - Dashboards → Template → Backend Overview → all panels show data

### Error scenarios

10. 404:
    ```bash
    curl http://localhost:3000/api/v1/products/99999
    # → 404
    ```
    `/metrics` shows `route="unmatched", status_code="404"` incremented.

11. 400:
    ```bash
    curl -X POST http://localhost:3000/api/v1/products -H 'Content-Type: application/json' -d 'bad'
    ```
    `/metrics` shows `status_code="400"` or `"500"` counter.

### Resilience

12. Collector-down (negative-path):
    ```bash
    docker compose -f docker-compose.yml -f docker-compose.observability.yml stop otelcol
    curl http://localhost:3000/api/v1/products
    # → 200 (app continues)
    ```
    Backend logs: `WARN` from DiagConsoleLogger; no unhandled rejection. Restart otelcol → spans resume.

### Teardown / span flush

13. Ordered shutdown validation:
    ```bash
    docker compose -f docker-compose.yml -f docker-compose.observability.yml stop backend
    # Wait for container to exit (should be < 10s)
    ```
    - Container exits within 8s (shutdown timeout guard). No hang.
    - Inspect Tempo for traces timestamped within the last second before stop — confirms `sdk.shutdown()` flushed final batch.

### Native dev mode

14. Start DB + backend only:
    ```bash
    docker compose -f docker-compose.db-dev.yml up -d
    cd backend/nodejs && npm run dev
    # → Server started, port 3000
    # → If no collector running: WARN in stderr (OTEL export failed); app serves normally
    # → Verify log line contains trace_id field after a curl
    ```

---

## §20 Risk Summary & Open Questions

### Risk table

| Risk | Breaking? | Data-loss? | Perf impact? | Severity | Mitigation |
|---|---|---|---|---|---|
| OTel Collector down | No | Spans dropped | None | Low | SDK buffers 2048, retries, WARN in stderr |
| mysql2 pool internals renamed in patch bump | No | No | None | Low | Null-safe; WARN + no gauge if absent; pin mysql2 |
| OTEL package version incompatibility | No | No | None | Medium | Pinned exact versions; verify types compile on install |
| Promtail Docker socket permission (WSL2) | No | No | None | Low | Add `user: root` to promtail service if permission denied |
| `trace_id` field name drift across pino instrumentation versions | No | No | None | Low | Verify field name after install; update Promtail json expression + Loki regex if `traceId` emitted |
| Grafana anonymous Viewer exposes dashboards | No | No | None | Low | Acceptable dev; remove `GF_AUTH_ANONYMOUS_ENABLED` for staging/prod |
| 8s shutdown timeout too short under heavy load | No | Final-batch spans dropped | None | Low | Bump to 15s for prod; acceptable for dev template |

### Upgrade paths

1. **Tail sampling** — add `tail_sampling` processor in `otelcol/config.yaml`. No app code change.
2. **Grafana Alerting** — alert rules on error rate > 1% and P95 > 500ms. Add `grafana/provisioning/alerting/` rules YAML.
3. **Promtail → Grafana Alloy** — Promtail deprecated upstream. Alloy uses River DSL. Replace `promtail` service.
4. **Frontend browser tracing** — `@opentelemetry/sdk-web` + `FetchInstrumentation` in `front/react/src/main.tsx`. Inject `traceparent` on all API calls.
5. **OTLP logs pipeline** — add `OTLPLogExporter` + OTEL log bridge Pino transport to `instrumentation.ts`. Enables Loki ingestion without Promtail.
6. **Prometheus → Mimir** — swap when horizontal scaling needed. Same PromQL, push via OTLP.
7. **`/metrics` Prometheus auth** — add `bearer_token` to Prometheus scrape config to match `METRICS_TOKEN`.
8. **getNodeAutoInstrumentations → explicit array** — replace disable-list approach with `[new HttpInstrumentation(), new ExpressInstrumentation(), new MySQL2Instrumentation(), new PinoInstrumentation()]`. Cleaner; no need to maintain disable list across package updates.
