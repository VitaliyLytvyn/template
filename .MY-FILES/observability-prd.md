# Observability PRD — Full-Stack Template

## Problem / Motivation

Current stack has Pino structured logging with `requestId` but zero visibility into:
- distributed traces (which DB queries run for a given HTTP request)
- runtime metrics (heap, event loop lag, request rate/latency)
- log aggregation with search and correlation to traces

This PRD defines adding all three observability pillars as a production-grade, study-reference implementation.

## Goals

- All three pillars: **Traces + Metrics + Logs** in a single coherent stack
- Backend-agnostic OTLP pipeline (app → OTel Collector → backends)
- Grafana as unified UI for all three pillars
- Zero app changes needed to enable/disable infra (separate compose file)
- Trace↔log correlation: `traceId`/`spanId` auto-injected into every Pino log line
- Dashboards provisioned as code (reproducible, version-controlled)

## Non-Goals

- Frontend browser tracing (OTEL browser SDK)
- Alerting rules / PagerDuty
- Long-term metrics retention (no Mimir; Prometheus local storage sufficient)
- Probabilistic/tail sampling (100% always-on; document upgrade path only)
- Business/domain metrics (no `products_created_total` etc.)

---

## Instrumentation Strategy

| Signal | Coverage | How |
|--------|----------|-----|
| **Traces** | Auto | `getNodeAutoInstrumentations()` — Express routes, HTTP, mysql2, DNS patched at load time |
| **Logs** | Auto | `@opentelemetry/instrumentation-pino` — injects `traceId`/`spanId` into every Pino log line without touching app code |
| **Metrics** | Near-zero | `prom-client` `/metrics` endpoint — ~30 lines in `middleware/metrics.ts`, zero business-logic changes |

**Zero-code mechanism**: Node.js supports `--import` flag (v18.19+). A single `instrumentation.ts` preloaded via `--import` patches all libraries before app code runs. No `import` statements added to app files.

Works in both dev (`tsx watch --import ./src/instrumentation.ts`) and prod (`node --import ./dist/instrumentation.js`). Confirmed in official OTEL JS docs.

---

## Stack Decisions

| Pillar | Chosen Tool | Rationale |
|--------|------------|-----------|
| Tracing | **Grafana Tempo** | Native Grafana integration, TraceQL, no separate UI |
| Metrics | **Prometheus** | Simple pull-based scrape, single-node, battle-tested |
| Logs | **Loki + Promtail** | Tails stdout JSON from Docker — zero infra-side app changes |
| UI | **Grafana** | Unified: Explore, dashboards, correlation across all pillars |
| Pipeline | **OTel Collector (otelcol-contrib)** | App → one OTLP endpoint; collector fans out |
| Node.js SDK | **@opentelemetry/sdk-node + auto-instrumentations-node** | Express, mysql2, Pino all auto-instrumented; pino instr bundled inside auto-instrumentations-node |
| Sampling | **100% always-on** | Correct for dev/low-volume template |

---

## Architecture

```
Node.js Backend
  ├── instrumentation.ts (preload via --import)
  │     └── NodeSDK:
  │           ├── Express auto-instr   → spans per HTTP request
  │           ├── mysql2 auto-instr    → spans per DB query
  │           ├── pino auto-instr      → traceId/spanId in every log line (auto)
  │           └── OTLP exporter        → otelcol:4318 (HTTP)
  ├── /metrics endpoint (prom-client)
  │     └── scraped by Prometheus
  └── stdout JSON logs (Pino, traceId/spanId injected by OTEL automatically)
        └── tailed by Promtail → Loki

OTel Collector
  ├── receives OTLP (traces)
  └── exports → Tempo

Grafana
  ├── datasource: Tempo (traces)
  ├── datasource: Prometheus (metrics)
  ├── datasource: Loki (logs)
  └── dashboards provisioned from grafana/dashboards/*.json
```

---

## Infrastructure (docker-compose.observability.yml)

New file alongside `docker-compose.yml`. Start with:
```bash
docker compose -f docker-compose.yml -f docker-compose.observability.yml up
```

### Services

| Service | Image | Port(s) | Purpose |
|---------|-------|---------|---------|
| `otelcol` | `otel/opentelemetry-collector-contrib` | 4317 (gRPC), 4318 (HTTP) | OTLP ingestion, fan-out |
| `tempo` | `grafana/tempo` | 3200 | Trace storage + query |
| `prometheus` | `prom/prometheus` | 9090 | Metrics storage + query |
| `loki` | `grafana/loki` | 3100 | Log storage + query |
| `promtail` | `grafana/promtail` | — | Tails Docker container logs → Loki |
| `grafana` | `grafana/grafana` | 3001 | Unified UI |

Grafana on **3001** to avoid conflict with backend on 3000.

### Config Files (new, version-controlled)

```
observability/
  otelcol/config.yaml          — receivers, processors, exporters
  tempo/config.yaml            — local storage, OTLP receiver
  prometheus/prometheus.yml    — scrape: backend:3000/metrics
  loki/config.yaml             — filesystem storage
  promtail/config.yaml         — Docker log discovery
  grafana/
    provisioning/
      datasources/datasources.yaml
      dashboards/dashboards.yaml
    dashboards/
      backend-overview.json    — RED metrics + runtime
```

---

## Backend Changes

### 1. New file: `src/instrumentation.ts` (OTEL SDK preload)

Loaded via `--import` before any app module. Patches Express, mysql2, and Pino automatically — **no changes to existing source files for traces or logs**.

```typescript
import { NodeSDK } from '@opentelemetry/sdk-node'
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http'
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node'
import { Resource } from '@opentelemetry/resources'
import { SEMRESATTRS_SERVICE_NAME } from '@opentelemetry/semantic-conventions'

const sdk = new NodeSDK({
  resource: new Resource({ [SEMRESATTRS_SERVICE_NAME]: 'backend-nodejs' }),
  traceExporter: new OTLPTraceExporter({ url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT }),
  instrumentations: [getNodeAutoInstrumentations({
    '@opentelemetry/instrumentation-fs': { enabled: false }, // noisy
    // instrumentation-pino bundled inside auto-instrumentations-node — enabled by default
  })],
})

sdk.start()

process.on('SIGTERM', () => sdk.shutdown())
```

`@opentelemetry/instrumentation-pino` is bundled inside `@opentelemetry/auto-instrumentations-node`. It auto-injects `trace_id`, `span_id`, `trace_flags` into every Pino log record. **`requestLogger.ts` requires no changes.**

### 2. New file: `src/middleware/metrics.ts`

Expose `/metrics` using `prom-client`:

```typescript
import { register, collectDefaultMetrics, Histogram, Counter, Gauge } from 'prom-client'

collectDefaultMetrics() // Node.js runtime: heap, GC, event loop

export const httpRequestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request latency',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
})

export const httpRequestTotal = new Counter({
  name: 'http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
})

export const dbPoolActive = new Gauge({ name: 'db_pool_connections_active', help: 'Active DB pool connections' })
export const dbPoolIdle   = new Gauge({ name: 'db_pool_connections_idle',   help: 'Idle DB pool connections' })

export const metricsHandler: RequestHandler = async (_req, res) => {
  res.set('Content-Type', register.contentType)
  res.end(await register.metrics())
}
```

Mount in `app.ts`: `app.get('/metrics', metricsHandler)`

Record per-request in `requestLogger.ts` on `res.finish`.

### 3. Modified: `package.json` — scripts

```json
"dev":   "tsx watch --import ./src/instrumentation.ts src/index.ts",
"start": "node --import ./dist/instrumentation.js dist/index.js"
```

### 4. Modified: `config.ts` — new env vars

```typescript
OTEL_EXPORTER_OTLP_ENDPOINT: z.string().default('http://otelcol:4318/v1/traces'),
OTEL_SERVICE_NAME: z.string().default('backend-nodejs'),
```

### 5. Modified: `docker-compose.yml` — backend env vars

```yaml
OTEL_EXPORTER_OTLP_ENDPOINT: http://otelcol:4318/v1/traces
OTEL_SERVICE_NAME: backend-nodejs
```

---

## New npm Dependencies

```
@opentelemetry/sdk-node
@opentelemetry/auto-instrumentations-node
@opentelemetry/exporter-trace-otlp-http
@opentelemetry/api
@opentelemetry/resources
@opentelemetry/semantic-conventions
prom-client
```

`@opentelemetry/instrumentation-pino` ships inside `auto-instrumentations-node` — no separate install needed.

---

## Grafana Dashboard: `backend-overview.json`

Panels:
- Request rate (req/s) — `rate(http_requests_total[1m])`
- Error rate (%) — `rate(http_requests_total{status_code=~"5.."}[1m])`
- P50/P95/P99 latency — `histogram_quantile(0.95, ...)`
- Node.js heap used — `nodejs_heap_size_used_bytes`
- Event loop lag — `nodejs_eventloop_lag_seconds`
- DB pool active connections

Linked to Loki datasource (log panel) and Tempo via `traceId` field.

---

## File Structure After Implementation

```
template/
  docker-compose.observability.yml     ← new
  observability/
    otelcol/config.yaml                ← new
    tempo/config.yaml                  ← new
    prometheus/prometheus.yml          ← new
    loki/config.yaml                   ← new
    promtail/config.yaml               ← new
    grafana/
      provisioning/
        datasources/datasources.yaml   ← new
        dashboards/dashboards.yaml     ← new
      dashboards/
        backend-overview.json          ← new
  backend/nodejs/src/
    instrumentation.ts                 ← new
    middleware/metrics.ts              ← new
    middleware/requestLogger.ts        ← unchanged (traceId/spanId auto-injected by OTEL)
    config.ts                          ← modified (OTEL env vars)
    app.ts                             ← modified (mount /metrics)
  backend/nodejs/package.json          ← modified (deps + scripts)
```

---

## Open Questions / Upgrade Paths

1. **Tail sampling** — add `tail_sampling` processor in otelcol config for production (sample by error status or latency threshold)
2. **Mimir** — swap Prometheus for Mimir when horizontal scaling needed (same PromQL, push via OTLP)
3. **Grafana Alloy** — replace Promtail (deprecated; Alloy is the successor); config syntax is River/Alloy DSL
4. **Frontend tracing** — `@opentelemetry/sdk-web` + `FetchInstrumentation` for browser spans
5. **Alerting** — Grafana Alerting rules on RED metrics (error rate > 1%, P95 > 500ms)
6. **Auth for /metrics** — add bearer token or IP allowlist before exposing to Prometheus in real prod
7. **OTLP logs pipeline** — add `OTLPLogExporter` to NodeSDK to send logs via OTLP in addition to stdout (enables log storage without Promtail)
