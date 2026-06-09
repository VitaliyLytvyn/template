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

### Viewing traces — step by step

**1. Start the monitoring stack**
```bash
./manage.sh monitoring start   # or menu option 9
```

**2. Generate traffic** (traces only appear after real requests)
```bash
curl http://localhost:3000/api/v1/products
# or use the frontend at http://localhost
```

**3. Open Grafana** → http://localhost:3001 (login: `admin` / your `GF_ADMIN_PASSWORD`)

**4. Find a trace via search**
- Left sidebar → **Explore**
- Datasource dropdown → **Tempo**
- Tab: **Search**
- Set `Service Name` = `backend-nodejs`
- Click **Run query** → list of recent traces appears
- Click any row → waterfall view with HTTP span + DB child spans

**5. Find a trace via logs (recommended — shows full context)**
- Left sidebar → **Explore**
- Datasource dropdown → **Loki**
- Query: `{service_name="backend-nodejs"}`
- Click **Run query** → log lines appear
- Expand any log line → click the `trace_id` value → Grafana opens that exact trace in Tempo

**6. Use the pre-built dashboard**
- Left sidebar → **Dashboards** → **Backend Overview**
- Bottom panel: **Logs** — each row has `trace_id` as a clickable link to Tempo

### Log → Trace navigation

Click a `trace_id` value in a Loki log line → jumps directly to the Tempo trace.

## eBPF Observability

> **What is eBPF?** eBPF is like a security camera wired directly into the building's electrical panel — it watches everything that moves through the system (HTTP calls, CPU work, memory pressure) without needing anyone to install cameras in individual rooms. The application code never knows it's being watched. Contrast this with the OTEL SDK approach above, which is more like asking each room to report its own activity.

Two pillars ship in this stack:

- **Beyla** — intercepts real HTTP traffic at the kernel level. Produces L7 traces (who called what, how long it took) and RED metrics (Rate, Errors, Duration) — zero lines of Node.js changed.
- **Pyroscope + Alloy** — records which functions the CPU spends time on, every second, as a flame graph. You see exactly where the backend is slow without a profiler attached in code.

The eBPF stack is **fully isolated** — its own Grafana, Prometheus, Tempo, Pyroscope on non-colliding ports. Both stacks can run simultaneously.

### Start

```bash
cp ebpf/.env.example ebpf/.env   # first time only
./ebpf-manage.sh
```

Or non-interactive:

```bash
GF_ADMIN_PASSWORD=changeme ./ebpf-manage.sh deploy
GF_ADMIN_PASSWORD=changeme ./ebpf-manage.sh destroy
./ebpf-manage.sh status
./ebpf-manage.sh logs [beyla|alloy|pyroscope|grafana|all]
```

> Requires the backend running on `:3000` first (`./manage.sh start` or `./manage.sh native start`). Beyla attaches to that process via eBPF — nothing to profile without it.

### Endpoints

| Service    | URL                                                    |
|------------|--------------------------------------------------------|
| Grafana    | http://localhost:3002 (login: admin / `GF_ADMIN_PASSWORD`) |
| Prometheus | http://localhost:9091                                  |
| Tempo      | http://localhost:3201                                  |
| Pyroscope  | http://localhost:4040                                  |

### What's collected

- **Traces** — Beyla captures every HTTP request/response at the kernel socket level → Tempo. No SDK, no `traceId` injection needed.
- **RED metrics** — `http_request_duration_seconds`, `http_requests_total` (by route, method, status) → Prometheus, scraped from Beyla's `/metrics` on host port `9400`.
- **CPU flame graphs** — Alloy's `pyroscope.ebpf` samples on-CPU time of all host processes every 10s → Pyroscope. Shows which functions consumed CPU — not just that it was slow.
- **Dashboards** — Grafana ships two pre-provisioned dashboards: "Beyla HTTP Overview" (request rate, error rate, latency percentiles) and "Pyroscope Flame Graph" (CPU breakdown by process + function).

> **CPU-only profiling:** eBPF on-CPU sampling captures CPU time, not memory/allocations. Memory flame graphs require a language SDK (outside this "zero code changes" scope).

### Viewing traces — step by step

**1. Backend must be running first**
```bash
./manage.sh start         # or ./manage.sh native start
```

**2. Deploy the eBPF stack**
```bash
GF_ADMIN_PASSWORD=changeme ./ebpf-manage.sh deploy
```

**3. Wait ~60 seconds** — k6 (bundled load generator) runs continuously; Beyla needs a few requests before traces appear in Tempo.

**4. Open Grafana** → http://localhost:3002 (login: `admin` / your `GF_ADMIN_PASSWORD`)

**5. Find a trace**
- Left sidebar → **Explore**
- Datasource dropdown → **Tempo** (points to `:3201`)
- Tab: **Search**
- Set `Service Name` = `backend-nodejs` (or leave blank to see all)
- Click **Run query** → list of HTTP spans captured at kernel level
- Click any row → waterfall view: method, path, status, duration

**6. Use the pre-built dashboard**
- Left sidebar → **Dashboards** → **Beyla HTTP Overview**
- Shows request rate, error rate, P50/P95/P99 latency by route — all from eBPF, no SDK

> No `trace_id` appears in application logs for eBPF traces — Beyla operates at the kernel socket level, not inside the Node.js process. Log correlation is only available with the OTEL SDK stack above.

### Verify

```bash
GF_ADMIN_PASSWORD=changeme ./scripts/smoke-test-ebpf.sh
```

Runs 17 checks: backend reachability, Beyla metrics + traces, Prometheus scrape, Alloy → Pyroscope pipeline, Grafana datasources + dashboards. Backend must be running and k6 load must have run ~60s for trace checks to pass.

### Architecture — how signals flow

```
  Backend process (:3000)
        │
        ├──[eBPF socket hook]──► Beyla ──► Tempo   :3201  (traces)
        │                              └──► Prometheus :9091 (RED metrics)
        │                                       │
        │                                  Grafana :3002
        │                                  "Beyla HTTP Overview"
        │
        └──[eBPF CPU sampler]──► Alloy ──► Pyroscope :4040  (flame graphs)
                                                │
                                           Grafana :3002
                                           "Pyroscope Flame Graph"

  k6 load generator ──► POST /api/v1/products  (creates continuous traffic)
```

### Known limitations

- **Pyroscope on kernel ≥ 6.16** — a kernel change in Linux 6.16 shifted a tracepoint field used by Alloy's eBPF profiler. If Alloy fails to attach (check `./ebpf-manage.sh logs alloy`), Pyroscope will show no data. Beyla traces and metrics are unaffected. Workaround: switch `ebpf-alloy` to `privileged: true` in `ebpf/docker-compose.yml`.
- **k6 creates real DB rows** — the load generator POSTs to `/api/v1/products` continuously. Clear with `./manage.sh reset-db` after testing.
- **Do not run alongside the main observability stack** — `ebpf-tempo` uses port `4318` for OTLP; the main otelcol also binds `4318`. Run one stack at a time.

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
