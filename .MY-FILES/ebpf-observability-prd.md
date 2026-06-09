# eBPF Observability — PRD

## Problem / Motivation

The existing observability stack is entirely application-level: the Node.js SDK emits traces, `prom-client` emits metrics, Promtail tails Docker logs. This approach requires code instrumentation and misses kernel-level signals entirely.

eBPF (Extended Berkeley Packet Filter) enables observability by running sandboxed programs directly in the Linux kernel — no SDK, no code changes, no restarts. This PRD defines a **fully isolated** eBPF observability stack that targets the existing Node.js backend, demonstrates what the kernel layer sees independently of the application layer, and serves as a study reference for production eBPF patterns.

---

## Goals

- Deploy a self-contained eBPF observability stack under `ebpf/`
- Two eBPF pillars:
  - **Beyla** — automatic L7 HTTP trace capture + RED metrics (no app code changes)
  - **Pyroscope** — continuous CPU and memory flame graphs via eBPF perf events
- Own Grafana + Prometheus + Tempo instances (zero coupling to existing observability stack)
- k6 load generator inside the stack so dashboards always show live data
- Pre-provisioned Grafana dashboards: Beyla HTTP overview, Pyroscope flame graphs
- `./manage.sh ebpf [start|stop|status|logs]` integration

## Non-Goals

- Replace or modify the existing OTEL SDK instrumentation
- Tetragon / security observability (out of scope for this iteration)
- Kubernetes / Cilium / Hubble (Docker-only)
- eBPF network-topology graphs (future)

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Linux kernel ≥ 5.8 | eBPF BTF + CO-RE required by Beyla; Pyroscope needs ≥ 5.4 |
| ARM64 support | Both Beyla and Pyroscope publish `linux/arm64` images |
| Privileged containers | Beyla and Pyroscope require `privileged: true` or `cap_add: [SYS_ADMIN, BPF, PERFMON, NET_ADMIN]` |
| Host PID namespace | `pid: "host"` — so eBPF probes can attach to the node process |
| Backend running | eBPF stack observes the existing backend at port 3000; backend must be started independently (native or docker mode) |

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Host / Docker                       │
│                                                         │
│  Backend Node.js :3000  ←── k6 load gen (continuous)   │
│        ↑                                                │
│        │  eBPF probes (kernel BPF programs)             │
│        │                                                │
│  ┌─────┴──────┐    OTLP/HTTP     ┌──────────────┐      │
│  │   Beyla    │ ────────────────→ │  ebpf-tempo  │      │
│  │  (L7 auto- │                   │   :3201      │      │
│  │   trace)   │ ── prom metrics → │              │      │
│  └────────────┘       ↓          └──────┬───────┘      │
│                 ┌─────────────┐         │               │
│                 │  ebpf-prom  │         │               │
│                 │   :9091     │         │               │
│                 └──────┬──────┘         │               │
│                        │                │               │
│  ┌─────────────┐       └────────────────┼──────────────→│
│  │  Pyroscope  │ ── profiling data ─────┘  ebpf-grafana │
│  │   :4040     │                            :3002        │
│  └─────────────┘                                        │
└─────────────────────────────────────────────────────────┘
```

**Ports (no conflicts with existing stack):**

| Service | Port | Purpose |
|---|---|---|
| ebpf-grafana | 3002 | Dashboards |
| ebpf-prometheus | 9091 | Metrics storage |
| ebpf-tempo | 3201 | Trace storage |
| pyroscope | 4040 | Profiling UI + API |

---

## Directory Structure

```
ebpf/
  docker-compose.yml          — all eBPF stack services
  .env.example                — GF_ADMIN_PASSWORD, BACKEND_HOST
  grafana/
    provisioning/
      datasources/
        datasources.yaml      — Prometheus, Tempo, Pyroscope datasources
      dashboards/
        dashboards.yaml       — dashboard provider config
    dashboards/
      beyla-http-overview.json   — RED metrics + latency heatmap
      pyroscope-flamegraph.json  — CPU + memory flame graph panels
  prometheus/
    prometheus.yml            — scrapes Beyla metrics from beyla:9400
  tempo/
    config.yaml               — single-node, local storage
  k6/
    load.js                   — continuous HTTP traffic script
```

---

## Services

### Beyla

```yaml
beyla:
  image: grafana/beyla:latest
  pid: "host"
  privileged: true            # or cap_add: [SYS_ADMIN, BPF, PERFMON, NET_ADMIN]
  environment:
    BEYLA_OPEN_PORT: "3000"   # attach to process listening on :3000
    BEYLA_TRACE_PRINTER: "disabled"
    OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://ebpf-tempo:4318/v1/traces"
    OTEL_SERVICE_NAME: "backend-nodejs-ebpf"
    BEYLA_PROMETHEUS_PORT: "9400"
  volumes:
    - /sys/fs/cgroup:/sys/fs/cgroup:ro
    - /proc:/proc:ro
  network_mode: "host"        # required to resolve host-side backend process
```

**What Beyla captures (no code changes):**
- HTTP request/response traces (method, route, status, duration)
- Span attributes: `http.method`, `http.route`, `http.status_code`, `http.request.body.size`
- Automatic service graph (if multiple services)
- RED metrics: request rate, error rate, duration histogram

### Pyroscope

```yaml
pyroscope:
  image: grafana/pyroscope:latest
  ports:
    - "4040:4040"
  pid: "host"
  privileged: true
  command:
    - "server"
  volumes:
    - pyroscope_data:/data
    - /sys/fs/cgroup:/sys/fs/cgroup:ro
    - /proc:/proc:ro
```

Pyroscope uses eBPF perf events for system-wide CPU profiling. Node.js process appears automatically by PID/name in the UI.

**What Pyroscope captures:**
- CPU flame graphs (where time is spent, down to function level)
- Memory allocation profiles
- Goroutine / async traces (Node.js: via V8 profiler integration or eBPF perf)
- Continuous profiling — no sampling gaps, always-on

### k6 Load Generator

```yaml
k6:
  image: grafana/k6:latest
  command: run --vus 5 --duration 99999s /scripts/load.js
  volumes:
    - ./k6/load.js:/scripts/load.js:ro
  environment:
    BASE_URL: "http://host-gateway:3000"  # reaches host-side backend
  extra_hosts:
    - "host-gateway:host-gateway"
```

`k6/load.js` script hits:
- `GET /health` — every 1s
- `GET /api/v1/products` — every 2s
- `POST /api/v1/products` + `GET /api/v1/products/:id` — every 5s

This ensures Beyla always has L7 traces flowing and Pyroscope flame graphs populate.

---

## Grafana Dashboards

### Beyla HTTP Overview (`beyla-http-overview.json`)
Panels:
- Request rate (req/s) — grouped by route
- Error rate (%) — 4xx + 5xx
- P50 / P95 / P99 latency
- Latency heatmap (histogram_quantile over time)
- Top slow routes table
- Active spans (if Tempo trace count available)

Datasource: ebpf-prometheus (for metrics) + ebpf-tempo (for trace exemplars)

### Pyroscope Flame Graph (`pyroscope-flamegraph.json`)
Panels:
- CPU flame graph (Pyroscope datasource, `process_cpu:cpu:nanoseconds:cpu:nanoseconds`)
- Memory flame graph
- Service selector dropdown

---

## manage.sh Integration

Add `ebpf` subcommand alongside existing `monitoring`:

```bash
./manage.sh ebpf start    # docker compose -f ebpf/docker-compose.yml up -d
./manage.sh ebpf stop     # docker compose -f ebpf/docker-compose.yml down
./manage.sh ebpf status   # show running containers + URLs
./manage.sh ebpf logs     # tail logs for all ebpf stack services
```

Status output includes:
```
eBPF stack:
  Grafana:    http://localhost:3002  (admin / $GF_ADMIN_PASSWORD)
  Prometheus: http://localhost:9091
  Tempo:      http://localhost:3201
  Pyroscope:  http://localhost:4040
```

Prerequisite check in `ebpf start`: warn if backend is not running on :3000 (Beyla needs a live process to attach to).

---

## Environment Variables

`ebpf/.env.example`:
```env
GF_ADMIN_PASSWORD=changeme
BACKEND_HOST=host-gateway   # host where Node.js backend runs
BACKEND_PORT=3000
```

---

## Smoke Test

`scripts/smoke-test-ebpf.sh` — verifies:
1. Beyla Prometheus metrics endpoint responds (`/metrics`)
2. At least one Beyla trace in Tempo (query Tempo API)
3. Pyroscope `/ready` returns 200
4. Grafana `/api/health` returns 200
5. k6 is running (container status check)

---

## Signal Comparison (Study Value)

| Signal | Existing SDK stack | eBPF stack (Beyla) |
|---|---|---|
| HTTP traces | Manual OTEL SDK, Node.js only | Automatic, kernel-level, language-agnostic |
| HTTP metrics | `prom-client` (explicit) | Beyla auto-generated RED metrics |
| CPU profiling | None | Pyroscope continuous flame graphs |
| Kernel syscalls | None | Visible in Pyroscope kernel frames |
| Zero code changes | No | Yes — Beyla attaches externally |
| TLS/HTTPS traffic | Partial (SDK hooks) | Yes (Beyla uses uprobes on OpenSSL) |

---

## Open Questions

1. **Kernel version**: Oracle Cloud ARM64 instance kernel version needs verification (`uname -r`). Beyla requires ≥ 5.8 with BTF enabled (`/sys/kernel/btf/vmlinux` must exist).
2. **Beyla TLS**: If backend adds HTTPS later, Beyla needs `BEYLA_OTEL_TRACES_INSECURE=true` and OpenSSL uprobe mode.
3. **Pyroscope Node.js profiling depth**: eBPF perf-based profiling sees native frames; for JS-level flame graphs, Pyroscope Node.js SDK (non-eBPF) may need to complement.
4. **Resource overhead**: Beyla eBPF programs add ~1-3% CPU overhead; Pyroscope sampling adds ~2-5%. Acceptable for a study template.
5. **`privileged: true` vs fine-grained caps**: Production deployments should use `cap_add: [BPF, PERFMON, NET_ADMIN, SYS_PTRACE]` instead of full privileged mode.
