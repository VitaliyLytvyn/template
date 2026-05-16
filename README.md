# Full-Stack Template

## Quick Start

### First run (required once)

```bash
cd backend/nodejs && npm run db:generate
```

### Run

```bash
./manage.sh
```



   1) Start          (all services in containers, :80 / :3000)
   2) Stop
   3) Status
   4) Logs — backend
   5) Logs — frontend
   6) Logs — db
   7) Rebuild        (reinstall deps + rebuild images)
   8) Reset DB       (drop volume, re-migrate, re-seed)
  ─────────────────────────────────────────────────────────────
   9) Monitoring — start  (app + Grafana / Prometheus / Tempo / Loki)
  10) Monitoring — stop
   0) Exit
```

**Docker mode** — full stack in containers. Frontend: http://localhost:80, API: http://localhost:3000.

### Non-interactive

```bash
./manage.sh start
./manage.sh stop
./manage.sh status
./manage.sh logs     [backend|frontend|db|all]
./manage.sh rebuild
./manage.sh reset-db
./manage.sh monitoring [start|stop]
./manage.sh native   [start|stop]   # DB in Docker, BE+FE local
```

## Observability

Full observability stack: distributed tracing (Tempo), metrics (Prometheus), logs (Loki), dashboards (Grafana).

### Start with observability

```bash
GF_ADMIN_PASSWORD=changeme \
  docker compose -f docker-compose.yml -f docker-compose.observability.yml up --build
```

Or via the interactive menu: option **9) Monitoring — start**.

> Must run merged — observability services share the default network with the backend.

### Verify

```bash
GF_ADMIN_PASSWORD=changeme ./scripts/smoke-test-observability.sh
```

Runs ~22 checks across all signals: backend health, metrics, otelcol, Prometheus, Loki, Tempo, Grafana datasources, dashboard, and a collector-down resilience test.

### Endpoints

| Service    | URL                          |
|------------|------------------------------|
| Grafana    | http://localhost:3001 (login: admin / `GF_ADMIN_PASSWORD`) |
| Prometheus | http://localhost:9090        |
| Tempo      | http://localhost:3200        |
| Loki       | http://localhost:3100        |
| `/metrics` | http://localhost:3000/metrics |

### What's collected

- **Traces** — HTTP spans + mysql2 DB spans via OTEL auto-instrumentation → OTel Collector → Tempo
- **Metrics** — `http_requests_total`, `http_request_duration_seconds`, `db_pool_connections_active/idle`, Node.js runtime (heap, GC, event loop) → Prometheus
- **Logs** — Pino JSON stdout with `trace_id` injected → Promtail → Loki
- **Dashboard** — Grafana "Backend Overview": request rate, error rate, P50/P95/P99 latency, heap, event loop lag, DB pool, log panel

### Log → Trace navigation

Click a `trace_id` value in a Loki log line → jumps directly to the Tempo trace.

## Observing

### Status

```bash
./manage.sh status
```

### Logs

```bash
./manage.sh logs backend
./manage.sh logs frontend
./manage.sh logs db
./manage.sh logs all
```

In native mode, logs stream directly to your terminal. In Docker mode, these pull from `docker logs`.

## Notes

- Migrations must exist before `manage.sh start` — run `db:generate` first (see Quick Start).
- Native dev requires `VITE_API_BASE_URL=http://localhost:3000/api/v1` in `front/react/.env`.
- Docker builds use `network: host` — required on WSL2.
- Observability stack is optional — app runs normally without it (OTEL SDK buffers spans, exits cleanly if collector unreachable).
- Loki and Tempo show HTTP 503 on `/ready` in single-node mode — expected, does not affect functionality.
