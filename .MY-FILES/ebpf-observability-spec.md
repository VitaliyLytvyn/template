# eBPF Observability Stack — Implementation Spec

SLUG: `ebpf-observability`
PRD: `/home/vit/template/.MY-FILES/ebpf-observability.prd.md`

## Summary

Add a **fully isolated** eBPF observability stack under `ebpf/` that observes the existing
Node.js backend (`:3000`) with zero application code changes. Two pillars:

- **Beyla** — eBPF L7 auto-instrumentation: HTTP traces (→ own Tempo) + RED metrics (Prometheus scrape).
- **Pyroscope continuous profiling** — eBPF CPU flame graphs of host processes, collected by a
  **Grafana Alloy** sidecar (`pyroscope.ebpf`) and pushed to a plain Pyroscope server.

The stack ships its own Grafana, Prometheus, Tempo, Pyroscope, Alloy and a k6 load generator, on
ports that do not collide with the existing observability stack (Grafana :3002, Prometheus :9091,
Tempo :3201, Pyroscope :4040). A standalone `ebpf-manage.sh` (deploy/destroy/status/logs) drives it,
and `scripts/smoke-test-ebpf.sh` verifies all signals end-to-end.

**Who uses it:** template study users comparing kernel-level (eBPF) vs application-level (OTEL SDK)
observability. **Impact:** new files only, **plus one line added to `.gitignore`** (to guarantee
`ebpf/.env` is never committed). No existing source, config, or CI is modified by this spec; the
implementor optionally pastes a documented `ebpf` case into `manage.sh`.

### >>> BLOCKER ESCALATION (orchestrator/user MUST decide before implementation) <<<

**Pyroscope eBPF profiling is broken on this host's kernel (6.17) by a known upstream regression.**

- **Fact.** Linux **6.16** changed the `sched_process_free` tracepoint format (the `pid` field offset
  moved from 24 to 12). This breaks Alloy's `pyroscope.ebpf` profiler at startup with
  `failed to attach scheduler monitor: ... cannot create bpf perf link` (the "permission denied" text
  is misleading — it is NOT a caps problem). Confirmed: **grafana/alloy#4562** (root cause in Alloy's
  vendored `grafana/opentelemetry-ebpf-profiler` fork), upstream **open-telemetry/opentelemetry-ebpf-profiler#737**
  (CLOSED via PR #738). `[doc: grafana/alloy#4562; otel-ebpf-profiler#737]`
- **Impact on this host.** `uname -r` = `6.17.0-1014-oracle` (≥ 6.16) → `ebpf-alloy` will fail to attach
  and produce **zero flame graphs**. This kills the **Pyroscope pillar** (one of the two PRD Goals).
  Beyla (traces + RED metrics) is unaffected — it does not use `sched_process_free`.
- **Resolution path the implementor MUST take (pick at deploy time, escalate the choice):**
  1. **Preferred — pin a fixed Alloy tag.** The upstream fix (#738) was synced into the Alloy
     `pyroscope.ebpf` profiler rework in the **v1.11.0** release cycle. **Before committing a tag,
     verify on grafana/alloy#4562 / the Alloy CHANGELOG that the chosen tag (≥ the release that closed
     #4562) actually contains the kernel-≥6.16 fix**, then pin `ebpf-alloy` to that exact tag (do NOT use
     `:latest`, do NOT use `v1.5.1` which predates the fix). The spec pins `grafana/alloy:v1.11.0` as a
     **placeholder requiring this verification**. `[ASSUMPTION — exact fixed tag not confirmed at spec
     time; implementor MUST confirm against #4562]`
  2. **Fallback — ship Pyroscope as a documented known-limitation.** If no Alloy release with the fix is
     available/verifiable at deploy time, deploy the stack with the **Beyla pillar functional** and mark
     Pyroscope profiling as **non-functional on kernels ≥ 6.16** (record it in the README / status output).
     The Pyroscope smoke check is a **non-fatal WARN** (already), so the smoke suite still passes for the
     Beyla pillar. Escalate to the user that the PRD's profiling Goal is deferred pending the Alloy fix.
- **This is a category-(b) blocker** (PRD requires Pyroscope; the spec cannot silently ship it broken on
  the target host). Orchestrator/user must confirm path 1 (with a verified tag) or accept path 2.

### Deviations from PRD (resolved from authoritative docs — category-(a) corrections)

1. **Pyroscope eBPF is NOT done by the Pyroscope server.** PRD §Services shows
   `pyroscope: command: [server]` doing eBPF profiling. Current Grafana architecture moved host eBPF
   profiling into **Grafana Alloy** (`pyroscope.ebpf` component, root + `pid: host`), which forwards
   to a plain Pyroscope server `pyroscope.write` endpoint. Without Alloy, the server alone produces no
   flame graphs. The spec adds an `ebpf-alloy` service and keeps `pyroscope` as a plain server.
   `[doc: /grafana/alloy → pyroscope.ebpf component]`
2. **Beyla discovery env var.** PRD uses `BEYLA_OPEN_PORT`. Confirmed valid (env-var form of
   `discovery.instrument.open_ports`). Beyla Prometheus export confirmed via `BEYLA_PROMETHEUS_PORT`
   on path `/metrics`, default example port `9400`. `[doc: /grafana/beyla → prometheus_export, standalone]`
3. **Network model.** Beyla and Alloy require host PID namespace AND must reach the backend process by
   its host-side port; both run `network_mode: host` and reach the stack's Tempo/Pyroscope via
   `localhost:<published-port>`. The remaining services (tempo/prom/grafana/pyroscope/k6) run on a
   dedicated bridge network with DNS. k6 also uses `network_mode: host` so `http://localhost:3000`
   reaches the backend identically in native or docker backend mode (the backend publishes `3000:3000`).
   `[architect-default: host-net containers reach published ports on localhost; verified ports free]`
4. **eBPF profiling is CPU-only — PRD's "memory flame graphs" is deferred.** PRD Goal asks for "CPU
   **and memory** flame graphs"; the embedded OTel eBPF profiler in Alloy's `pyroscope.ebpf` is an
   on-CPU perf-event sampling profiler and emits only `process_cpu` — no memory/allocation profiles.
   Memory profiling needs a non-eBPF language SDK (out of the PRD "no code changes" scope), so the
   memory flame-graph panel is dropped, not shipped as a never-populating panel. Full rationale in Open
   Question 2 (same deviation pattern as the JS-depth gap, Open Question 1).
   `[doc: /grafana/alloy pyroscope.ebpf — on-CPU sampling only]`

### Decisions taken without user confirmation (AskUserQuestion unavailable in subagent — orchestrator should confirm)

- **Pyroscope architecture → Alloy + Pyroscope** (doc-fact, the PRD form is non-functional on current versions).
- **Pyroscope kernel-6.16 blocker → escalate** (see BLOCKER ESCALATION above) — orchestrator/user picks fixed-tag vs known-limitation.
- **Memory flame graphs → deferred (CPU-only)** — eBPF profiler is on-CPU sampling only; memory needs a non-eBPF SDK (PRD no-code-changes scope). See Deviation 4 / Open Question 2.
- **Privileges → fine-grained capabilities** with a `privileged: true` fallback note (aligns with PRD Open Question 5 production intent). **Note:** Alloy `pyroscope.ebpf` additionally requires `user: root` (see Security).
- **manage.sh → standalone `ebpf-manage.sh`** plus a documented paste-in `manage.sh` snippet (no-edit-existing-scripts rule).
- **`.gitignore` → add `ebpf/.env`** (one-line modification of an existing file, manifested in Affected Resources).

## Environment

Detected from repo + host (Phase 0):

| Item | Value | Source |
|---|---|---|
| Host kernel | `6.17.0-1014-oracle` — **≥ 6.16 → HAZARD for Pyroscope eBPF (see BLOCKER ESCALATION); Beyla OK** | `uname -r` |
| Arch | `aarch64` / linux/arm64 | `uname -m` |
| BTF / CO-RE | `/sys/kernel/btf/vmlinux` present (7.6M) ✓ | `ls /sys/kernel/btf/vmlinux` |
| Docker | `29.5.1` | `docker --version` |
| Docker Compose | `v5.1.3` | `docker compose version` |
| Backend port | `:3000` (host-published in both native + docker modes) | `docker-compose.yml:36-37`, CLAUDE.md |
| Target ports free | 3002, 9091, 3201, 4040, 4041, 9400 all free | `ss -ltn` |
| `.gitignore` rule for `.env` | single line `.env` (no `*.env`, no `**/.env`) | `.gitignore` (verified) |
| Existing Grafana | `grafana/grafana:11.1.0` | `docker-compose.observability.yml:46` |
| Existing Tempo | `grafana/tempo:2.5.0` | `docker-compose.observability.yml:13` |
| Existing Prometheus | `prom/prometheus:v2.53.0` | `docker-compose.observability.yml:22` |

**Pinned image versions for the eBPF stack** (match existing-stack majors where shared; eBPF tools pinned
to a recent stable tag rather than `:latest` per repo convention of pinning all images):

| Service | Image | Rationale |
|---|---|---|
| ebpf-beyla | `grafana/beyla:2.0.0` | 2.x uses `discovery.instrument` (config syntax in spec); verify arm64 tag |
| ebpf-alloy | `grafana/alloy:v1.11.0` | **placeholder — MUST be a tag that contains the grafana/alloy#4562 kernel-≥6.16 fix; verify before deploy** (was `v1.5.1`, predates fix) |
| ebpf-pyroscope | `grafana/pyroscope:1.10.0` | plain server (single-binary "all" mode, default `:4040`); arm64 published |
| ebpf-tempo | `grafana/tempo:2.5.0` | match existing stack |
| ebpf-prometheus | `prom/prometheus:v2.53.0` | match existing stack |
| ebpf-grafana | `grafana/grafana:11.1.0` | match existing stack |
| k6 | `grafana/k6:0.54.0` | pin (PRD used `:latest`) |

All image tags are `[architect-default]` pins — the implementor MUST verify each tag has a `linux/arm64`
manifest before first deploy (`docker manifest inspect <image> | grep arm64`). If a pinned tag lacks arm64,
fall back to `:latest` for that single image and record it. For `ebpf-alloy` the tag has an **additional**
hard constraint (kernel-≥6.16 fix present) per the BLOCKER ESCALATION.

## Code Style Conventions

Audited siblings: `docker-compose.observability.yml`, `observability/tempo/config.yaml`,
`observability/prometheus/prometheus.yml`, `observability/grafana/provisioning/**`,
`observability/grafana/dashboards/backend-overview.json`, `manage.sh`,
`scripts/smoke-test-observability.sh`.

- **Compose**: `services:` top-level, 2-space indent, images pinned by tag, named volumes at bottom,
  bind-mounts `./path:/container:ro`, env via `KEY: "value"`, Grafana password via
  `${GF_ADMIN_PASSWORD:?...}` fail-fast syntax. No `version:` key.
- **Grafana provisioning**: `apiVersion: 1`; datasources carry stable `uid`s referenced by dashboards;
  dashboard provider points at `/var/lib/grafana/dashboards`.
- **Dashboard JSON**: top-level `uid`, `title`, `tags`, `schemaVersion: 39`, `time`, `refresh`,
  `panels[]` with `id`, `title`, `type`, `gridPos`, `targets[]` (`datasource.uid`, `expr`, `legendFormat`).
- **Shell scripts**: `#!/usr/bin/env bash` + `set -euo pipefail`; `REPO_ROOT` via `BASH_SOURCE`;
  color vars `C_*`; `info/success/warn/error` helpers; smoke tests use `pass/fail` counters and
  `[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1`. **No comments inside code restating commands**; brief
  section banners only (`# ── section ──`).
- **Comment policy**: configs use sparse `#` WHY-comments only (see prometheus.yml token note). No
  verbose doc blocks.
- **Test reality**: repo has **no automated test runner** for infra — verification is via shell smoke
  scripts (`scripts/smoke-test-observability.sh`). Therefore the eBPF test artifact is a **smoke script**,
  not a unit-test framework. (Per core test-artifact gate.)

## Design Decisions

| Decision | Chosen | Rejected | Rationale + provenance |
|---|---|---|---|
| Pyroscope eBPF collector | Grafana Alloy `pyroscope.ebpf` → Pyroscope server | Pyroscope server self-profiling (PRD) | Server no longer does host eBPF; Alloy is the supported path `[doc: /grafana/alloy pyroscope.ebpf]` |
| Profile types delivered | CPU only (`process_cpu`) | CPU + memory (PRD) | embedded eBPF profiler is on-CPU sampling only; memory needs non-eBPF SDK (no-code-changes scope) `[doc: /grafana/alloy pyroscope.ebpf]` — see Open Q2 |
| Alloy tag (kernel-6.16 fix) | `v1.11.0` placeholder, **verify against #4562** | `v1.5.1` (predates fix) | kernel 6.17 hits sched_process_free regression `[doc: grafana/alloy#4562; otel-ebpf-profiler#737]` |
| Alloy runtime privilege | `user: root` + caps + writable `/tmp/symb-cache` | non-root + caps only | `pyroscope.ebpf` **requires root + host PID ns + fs storage** `[doc: /grafana/alloy pyroscope.ebpf — "must run Alloy as root and within the host PID namespace"]` |
| Beyla→trace sink | Beyla OTLP/HTTP → `ebpf-tempo:4318` via published `4319:4318`, target `…/v1/traces` | gRPC | Existing Tempo enables OTLP gRPC only; eBPF Tempo enables OTLP HTTP to match Beyla default; signal-specific OTLP var used verbatim `[code-fact: observability/tempo/config.yaml:6-9]` `[doc: beyla otel_traces_export]` |
| Beyla trace endpoint config | **env-only** `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (full path) | duplicate in `beyla-config.yml` `otel_traces_export.endpoint` | one source of truth; signal-specific var is used as-is (no `/v1/traces` appended), base var would be; mixing the two risks `/v1/traces/v1/traces` `[doc: OTLP exporter env var semantics]` |
| Beyla metrics | Beyla Prometheus export `:9400/metrics`, scraped by ebpf-prometheus | Beyla→OTLP metrics | RED-metrics dashboards need PromQL; matches existing prom-scrape pattern `[doc: beyla prometheus_export]` |
| Network for Beyla/Alloy/k6 | `network_mode: host` + `pid: host` | bridge + `host-gateway` (PRD k6) | eBPF probes need host PID ns; host net makes `localhost:3000/3201/4040` resolve in native+docker backend modes `[architect-default]` |
| Network for tempo/prom/grafana/pyroscope | dedicated bridge `ebpf-net` | host net | DNS service resolution; only the eBPF/load components need host net `[architect-default]` |
| Privileges (Beyla) | `cap_add: [BPF, PERFMON, NET_ADMIN, SYS_PTRACE, SYS_RESOURCE]` + `security_opt: [apparmor=unconfined]` | `privileged: true` | least-privilege per PRD Open Q5 `[product-call: PRD Open Question 5]`; privileged documented as fallback |
| manage.sh integration | standalone `ebpf-manage.sh` + documented paste-in snippet | edit `manage.sh` | core rule forbids editing existing project scripts `[architect-default: agent rule]` |
| Image tags | pinned (table above) | `:latest` (PRD) | repo pins all images `[code-fact: docker-compose.observability.yml:3,13,22,46]` |
| Grafana anon access | anonymous Viewer enabled | login-only | match existing stack UX `[code-fact: docker-compose.observability.yml:50-51]` |
| `ebpf/.env` secrecy | add `ebpf/.env` line to `.gitignore` | rely on existing `.env` rule | existing `.gitignore` has only `.env` (matches `ebpf/.env` by basename, but spec must not rely on an implicit basename match for a secret) `[code-fact: .gitignore — verified]` |

## Affected Resources

All resources are **new (create)** except `.gitignore`, which gains **one appended line** (modify). No
existing resource is destroyed by this spec.

| Type | Name | Action | Blast radius | prevent_destroy? |
|---|---|---|---|---|
| Existing file | `.gitignore` | **modify** (append `ebpf/.env`) | ensures secret never committed; no behavioral change | N/A |
| Compose service | ebpf-beyla | create | host PID ns read; eBPF probes on backend pid | N/A (stateless) |
| Compose service | ebpf-alloy | create | host PID ns read (root); eBPF perf events | N/A (stateless) |
| Compose service | ebpf-pyroscope | create | profile storage (volume) | volume retains profiles |
| Compose service | ebpf-tempo | create | trace storage (volume), 1h retention | volume |
| Compose service | ebpf-prometheus | create | metric storage (volume) | volume |
| Compose service | ebpf-grafana | create | dashboards (volume) | volume |
| Compose service | k6 | create | generates continuous load on backend :3000 | N/A — see Side-Effect Sweep |
| Named volume | ebpf_pyroscope_data, ebpf_tempo_data, ebpf_prometheus_data, ebpf_grafana_data | create | local disk | retained until `down -v` |
| Bridge network | ebpf-net | create | isolated | N/A |
| Host script | ebpf-manage.sh | create | invokes docker compose | N/A |

## Terraform Module & File Layout

N/A — no Terraform in this repo. Infrastructure is Docker Compose + config files. New file layout:

```
ebpf/                                        [new]
  docker-compose.yml                         [new] all eBPF stack services
  .env.example                               [new] GF_ADMIN_PASSWORD, BACKEND_PORT
  alloy/
    config.alloy                             [new] pyroscope.ebpf → pyroscope.write
  beyla/
    beyla-config.yml                         [new] discovery + prometheus_export (NO trace endpoint — env-only)
  prometheus/
    prometheus.yml                           [new] scrape ebpf-beyla :9400
  tempo/
    config.yaml                              [new] single-node, OTLP http+grpc
  grafana/
    provisioning/
      datasources/datasources.yaml           [new] Prometheus, Tempo, Pyroscope
      dashboards/dashboards.yaml             [new] dashboard provider
    dashboards/
      beyla-http-overview.json               [new]
      pyroscope-flamegraph.json              [new]
  k6/
    load.js                                  [new] continuous traffic
.gitignore                                   [modify] append `ebpf/.env`
ebpf-manage.sh                               [new] repo root — deploy/destroy/status/logs
scripts/smoke-test-ebpf.sh                   [new] end-to-end smoke
```

## Variables & Outputs

`ebpf/.env.example` (mirrors repo `.env.example` style — comment + KEY=value):

```env
# Grafana admin password for the eBPF stack — used by ./ebpf-manage.sh
GF_ADMIN_PASSWORD=changeme
# Backend port the eBPF probes attach to (host-published by manage.sh)
BACKEND_PORT=3000
```

No program outputs; "outputs" are the URLs printed by `ebpf-manage.sh status`.

## State Management

N/A — no Terraform state. Stateful data lives in named Docker volumes (`ebpf_*_data`), retained across
`down` and removed only with `down -v` (the `ebpf-manage.sh destroy` path prompts before `-v`).

## Networking

- **ebpf-net** (bridge): ebpf-tempo, ebpf-prometheus, ebpf-grafana, ebpf-pyroscope — intra-stack DNS.
- **host network**: ebpf-beyla, ebpf-alloy, k6 — need host PID ns / host-port reachability.
- **Cross-network reach**: host-net services publish nothing extra; they reach bridge services through
  the bridge services' **published host ports** (`localhost:4319` Tempo OTLP-HTTP, `localhost:4040`
  Pyroscope, `localhost:9400` is Beyla's own export on host).
- **Port publish map** (host:container):

  | Service | Published | Container | Purpose |
  |---|---|---|---|
  | ebpf-grafana | 3002 | 3000 | UI |
  | ebpf-prometheus | 9091 | 9090 | metrics UI/API |
  | ebpf-tempo | 3201 | 3200 | Tempo HTTP/API |
  | ebpf-tempo | 4319 | 4318 | OTLP HTTP (Beyla → Tempo) |
  | ebpf-pyroscope | 4040 | 4040 | profiling UI/API + write |
  | ebpf-beyla | 9400 | (host net) | Beyla Prometheus export |

  **Port 4318 conflict check**: the existing observability stack publishes 4318 on `otelcol`
  (`docker-compose.observability.yml:6`). **The eBPF stack must NOT be run at the same time as the
  existing observability stack** (both want 4318). Mitigation: `ebpf-tempo` publishes OTLP-HTTP on
  **`4319:4318`** instead, and Beyla targets `http://localhost:4319/v1/traces`. (See Side-Effect Sweep.)

- Beyla → Tempo (host-net Beyla to published Tempo): **single source of truth** —
  `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://localhost:4319/v1/traces` set in compose ONLY.
  This is the **signal-specific** OTLP env var: it is used **verbatim** (Beyla/OTLP does NOT append
  `/v1/traces`). The base var `OTEL_EXPORTER_OTLP_ENDPOINT` is the one that gets the path appended —
  it is **not** used here. `beyla-config.yml` does **not** set `otel_traces_export.endpoint`, to avoid a
  conflicting base-vs-signal precedence that could yield `…/v1/traces/v1/traces` or a silent mismatch.
- Alloy → Pyroscope (host-net Alloy to published Pyroscope): `pyroscope.write` url `http://localhost:4040`.
- ebpf-prometheus scrape of Beyla: Beyla is on host net, so Prometheus (bridge) reaches it via
  `host.docker.internal:9400` with `extra_hosts: ["host.docker.internal:host-gateway"]`.

## Side-Effect Sweep Result

| Resource / risk | Finding | Mitigation | Cost delta |
|---|---|---|---|
| **Kernel ≥ 6.16 breaks Pyroscope eBPF** | host kernel 6.17 hits grafana/alloy#4562 `sched_process_free` regression → Alloy fails to attach, **zero profiles** | **BLOCKER**: pin a fixed Alloy tag (≥ release closing #4562, verify CHANGELOG) OR ship Pyroscope as documented known-limitation; escalated | none (but pillar may be deferred) |
| Port 4318 collision with existing otelcol | Both want host 4318 | ebpf-tempo publishes `4319:4318`; Beyla targets 4319. Do not run both stacks concurrently anyway (CPU). | none |
| Host PID namespace exposure | `pid: host` lets containers see all host processes | Required for eBPF; Beyla caps not `SYS_ADMIN`-broad; Alloy runs root (hard requirement); documented; study env | none |
| eBPF kernel attach | Beyla/Alloy load BPF programs into the host kernel | BTF present (verified); **Beyla** OK on 6.17; **Alloy** gated on fixed tag (above); ~1-5% CPU (PRD Open Q4) | ~3-8% host CPU while running |
| Alloy profiles ALL host processes | `targets_only = false` captures every process, not just backend | Intended for a study box; relabel sets a clean `service_name`; one-line note in config that flame graphs include non-backend procs | none |
| k6 continuous load on backend | 3 VUs hitting :3000 forever → DB writes (POST /products) | k6 `--vus 3`; POST creates rows → **DB growth**. Document; `reset-db` clears. | DB row growth |
| Volume disk growth | tempo (1h retention), prometheus, pyroscope, grafana | Tempo 1h block_retention (match existing); document `destroy -v` | local disk |
| Concurrent run with main observability stack | 2x Grafana/Prom/Tempo + eBPF CPU | Spec warns; `ebpf-manage.sh status` notes existing-stack ports | high CPU |
| Image arm64 availability | pinned tags may lack arm64 | implementor verifies `docker manifest inspect` pre-deploy | none |
| Long pull/first build | images ~ hundreds of MB | first `up` may exceed 5 min on slow links; no CI gate involved | none |

**No destroy/recreate of any existing resource. No `prevent_destroy` concerns** — everything is additive
(the `.gitignore` change appends one line; non-destructive).

## Compatibility & Cutover

| Change | Breaking? | Cutover | Rollback |
|---|---|---|---|
| New `ebpf/` stack | No | `./ebpf-manage.sh deploy` (backend must be up on :3000) | `./ebpf-manage.sh destroy` |
| `.gitignore` += `ebpf/.env` | No (append only) | commit the one-line change | remove the appended line |
| Optional `manage.sh` `ebpf` case paste | No (additive case) | implementor pastes snippet (below) | remove the case block |

- **Pre-deploy**: backend running on :3000 (native or docker); BTF present; `GF_ADMIN_PASSWORD` set or in
  `ebpf/.env`; **Alloy tag verified against grafana/alloy#4562** (or Pyroscope accepted as deferred).
- **Deploy sequence**: `docker compose -f ebpf/docker-compose.yml up -d` → wait Beyla metrics → k6 generates load → traces/profiles flow.
- **Post-deploy validation**: `scripts/smoke-test-ebpf.sh` (Pyroscope check is a non-fatal WARN on kernels ≥6.16).
- **Rollback trigger**: any smoke FAIL, or host CPU unacceptable → `./ebpf-manage.sh destroy`.

### Optional `manage.sh` `ebpf` integration snippet (implementor pastes; spec does NOT edit manage.sh)

PRD asks for `./manage.sh ebpf [start|stop|status|logs]`. The standalone script uses
`deploy|destroy|status|logs`. The delegator below forwards the arg through; the implementor should map
PRD verbs (`start`→`deploy`, `stop`→`destroy`) in the snippet or accept the standalone verbs. Add a
dispatch case (after the `monitoring)` line ~`manage.sh:333`):

```bash
    ebpf)
      sub="${1:-status}"
      case "$sub" in
        start) sub="deploy" ;;
        stop)  sub="destroy" ;;
      esac
      "$REPO_ROOT/ebpf-manage.sh" "$sub" "${@:2}"
      ;;
```

This delegates `./manage.sh ebpf <cmd>` to the standalone script, satisfying the PRD CLI shape (including
the PRD's `start`/`stop` verb names) without duplicating logic. Menu entries (optional) mirror the
monitoring rows.

## Secrets & Config

- Only secret: `GF_ADMIN_PASSWORD`. Sourced from env or `ebpf/.env`. Compose uses
  `${GF_ADMIN_PASSWORD:?...}` fail-fast (matches existing stack); `ebpf/.env.example` is committed.
- **`.gitignore` fact (verified):** the repo `.gitignore` contains only a single `.env` line — **no
  `*.env` and no `**/.env`**. Git's `.env` (no leading slash) matches `ebpf/.env` by basename, but the
  spec must not rely on an implicit basename match for a secret. **This spec appends `ebpf/.env` to
  `.gitignore`** (manifested in Affected Resources) to make the protection explicit and robust.
- No tokens for Prometheus/Tempo/Pyroscope (single-node study stack, anon Grafana Viewer).
- No rotation needed (study/local).

## Cost Estimate

Local/self-hosted on the existing OCI ARM instance — **$0 incremental cloud cost**. Resource overhead
while running: ~3-8% host CPU (eBPF probes + k6 + 6 containers), a few hundred MB RAM, local disk for
volumes. Order of magnitude: negligible for a study box; do not run alongside the main observability
stack on a small instance.

## Security

- **Beyla — least-privilege caps**: `cap_add: [BPF, PERFMON, NET_ADMIN, SYS_PTRACE, SYS_RESOURCE]` rather
  than `privileged: true`. `BPF`+`PERFMON` for program load/perf; `NET_ADMIN` for Beyla socket probes;
  `SYS_PTRACE` for process introspection; `SYS_RESOURCE` for memlock. `security_opt: [apparmor=unconfined]`
  required for BPF on AppArmor hosts. **Fallback**: if attach fails, switch Beyla to `privileged: true`
  and record it.
- **Alloy — root is a HARD REQUIREMENT, not a least-privilege choice.** Grafana docs for `pyroscope.ebpf`:
  *"you must run Grafana Alloy as root and within the host PID namespace."* Therefore `ebpf-alloy` sets
  `user: root` (or `privileged: true` as the simplest fallback) **in addition** to the caps + host PID ns,
  and provisions a **writable symbol-cache** at `/tmp/symb-cache` (named volume) which the profiler needs
  for on-disk symbolization. Caps-only + non-root would fail to attach. `[doc: /grafana/alloy pyroscope.ebpf]`
- **No inbound exposure beyond localhost-published UI ports** (3002/9091/3201/4040). These bind all
  interfaces by default like the existing stack — on a public OCI host, restrict via security list /
  firewall (same caveat as existing observability stack; out of scope to change here).
- **Grafana**: anonymous Viewer + admin password (matches existing). Admin password fail-fast.
- **Secrets**: `GF_ADMIN_PASSWORD` never committed — `ebpf/.env` explicitly added to `.gitignore` (see Secrets & Config).
- **Input validation**: k6 only hits the backend's own validated endpoints; no new attack surface on the app.
- **No `*` IAM / no cloud creds** involved.

## Implementation Steps

0. **`.gitignore`** — append a single line `ebpf/.env` (do not reorder or remove existing lines). This is
   the only modification to an existing file.

1. **`ebpf/tempo/config.yaml`** — single-node Tempo, enable OTLP **both grpc and http** receivers
   (existing stack only enabled grpc; Beyla defaults to OTLP/HTTP). Local storage, 1h retention.

   ```yaml
   server:
     http_listen_port: 3200

   distributor:
     receivers:
       otlp:
         protocols:
           grpc:
             endpoint: 0.0.0.0:4317
           http:
             endpoint: 0.0.0.0:4318

   storage:
     trace:
       backend: local
       local:
         path: /var/tempo

   compactor:
     compaction:
       block_retention: 1h
   ```

2. **`ebpf/beyla/beyla-config.yml`** — discovery + prometheus export ONLY. **Do NOT set
   `otel_traces_export.endpoint` here** — the trace endpoint is configured exclusively via the
   `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` env var in compose (single source of truth; see Networking).

   ```yaml
   discovery:
     instrument:
       - open_ports: 3000

   prometheus_export:
     port: 9400
     path: /metrics
     features:
       - application
       - application_span
       - application_service_graph
   ```

3. **`ebpf/prometheus/prometheus.yml`** — scrape Beyla (host-net) from a bridge container:

   ```yaml
   global:
     scrape_interval: 15s
     evaluation_interval: 15s

   scrape_configs:
     - job_name: beyla
       static_configs:
         - targets: ['host.docker.internal:9400']
       metrics_path: /metrics
   ```

4. **`ebpf/alloy/config.alloy`** — eBPF host **CPU** profiling → Pyroscope (on-CPU sampling only; no
   memory profile — see Open Q2). **Every argument below is verified against the `pyroscope.ebpf`
   component reference** (`forward_to` + `targets` required; `targets_only`, `demangle` are valid
   component args in the fixed Alloy release the implementor pins per the BLOCKER). The relabel rule
   derives a clean `service_name` from the exe basename (avoids `service_name` becoming the full
   `/usr/local/bin/node` path). `targets_only = false` profiles ALL host processes (study intent).

   ```alloy
   logging {
     level = "info"
   }

   discovery.process "all" { }

   discovery.relabel "backend" {
     targets = discovery.process.all.targets
     rule {
       source_labels = ["__meta_process_exe"]
       target_label  = "service_name"
       regex         = ".*/([^/]+)$"
       replacement   = "$1"
       action        = "replace"
     }
   }

   pyroscope.write "local" {
     endpoint {
       url = "http://localhost:4040"
     }
   }

   pyroscope.ebpf "default" {
     targets      = discovery.relabel.backend.output
     forward_to   = [pyroscope.write.local.receiver]
     targets_only = false
   }
   ```

   **Verification gate:** before deploy, confirm `targets_only` (and any other optional arg you keep)
   exists in the **pinned** Alloy tag's `pyroscope.ebpf` reference. If the pinned tag does not document an
   arg, remove it — Alloy **rejects unknown attributes at config load** and the container crash-loops. The
   minimal known-good shape is `pyroscope.ebpf "x" { targets = ...; forward_to = [...] }`. Do NOT add
   `demangle` unless it is in the pinned tag's reference (it is absent from older releases).

5. **`ebpf/grafana/provisioning/datasources/datasources.yaml`** — Prometheus, Tempo, Pyroscope
   (stable uids referenced by dashboards):

   ```yaml
   apiVersion: 1
   datasources:
     - name: Prometheus
       type: prometheus
       uid: ebpf-prometheus
       url: http://ebpf-prometheus:9090
       isDefault: true

     - name: Tempo
       type: tempo
       uid: ebpf-tempo
       url: http://ebpf-tempo:3200

     - name: Pyroscope
       type: grafana-pyroscope-datasource
       uid: ebpf-pyroscope
       url: http://ebpf-pyroscope:4040
   ```

6. **`ebpf/grafana/provisioning/dashboards/dashboards.yaml`** — provider (mirror existing):

   ```yaml
   apiVersion: 1
   providers:
     - name: ebpf
       folder: eBPF
       type: file
       options:
         path: /var/lib/grafana/dashboards
   ```

7. **`ebpf/grafana/dashboards/beyla-http-overview.json`** — see `## Dashboards`. Beyla RED metric base
   name is `http_server_request_duration_seconds` (histogram) with labels `http_request_method`,
   `http_route`, `http_response_status_code`.

8. **`ebpf/grafana/dashboards/pyroscope-flamegraph.json`** — **single CPU flame graph** panel + service
   selector, Pyroscope datasource, profile type `process_cpu:cpu:nanoseconds:cpu:nanoseconds`. **No
   memory flame-graph panel** — the eBPF profiler is on-CPU sampling only and emits no allocation profile
   (PRD memory-flame-graph requirement deferred; see Deviation 4 / Open Q2).

9. **`ebpf/k6/load.js`** — continuous traffic to `http://localhost:3000` (see `## k6 Script`).

10. **`ebpf/docker-compose.yml`** — all services (see `## Compose` block). Verify `ebpf/.env` matches.

11. **`ebpf/.env.example`** — as in `## Variables & Outputs`.

12. **`ebpf-manage.sh`** (repo root) — deploy/destroy/plan(=config)/status/logs with confirmation prompts
    (see `## Manage Script`). `chmod +x`.

13. **`scripts/smoke-test-ebpf.sh`** — see `## Verification Steps` / smoke artifact. `chmod +x`.

14. **(Optional)** paste the `ebpf)` dispatch case into `manage.sh` per `## Compatibility & Cutover`.

## Compose

`ebpf/docker-compose.yml` (paths relative to `ebpf/`):

```yaml
services:
  ebpf-tempo:
    image: grafana/tempo:2.5.0
    networks: [ebpf-net]
    ports:
      - "3201:3200"
      - "4319:4318"
    volumes:
      - ./tempo/config.yaml:/etc/tempo.yaml:ro
      - ebpf_tempo_data:/var/tempo
    command: ["-config.file=/etc/tempo.yaml"]

  ebpf-prometheus:
    image: prom/prometheus:v2.53.0
    networks: [ebpf-net]
    ports:
      - "9091:9090"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ebpf_prometheus_data:/prometheus

  ebpf-pyroscope:
    image: grafana/pyroscope:1.10.0
    # single-binary "all" mode is the image default; no `command:` needed. Default API/write port 4040.
    networks: [ebpf-net]
    ports:
      - "4040:4040"
    volumes:
      - ebpf_pyroscope_data:/data

  ebpf-grafana:
    image: grafana/grafana:11.1.0
    networks: [ebpf-net]
    ports:
      - "3002:3000"
    environment:
      GF_AUTH_ANONYMOUS_ENABLED: "true"
      GF_AUTH_ANONYMOUS_ORG_ROLE: Viewer
      GF_SECURITY_ADMIN_PASSWORD: "${GF_ADMIN_PASSWORD:?GF_ADMIN_PASSWORD must be set}"
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
      - ebpf_grafana_data:/var/lib/grafana

  ebpf-beyla:
    image: grafana/beyla:2.0.0
    pid: "host"
    network_mode: "host"
    cap_add: [BPF, PERFMON, NET_ADMIN, SYS_PTRACE, SYS_RESOURCE]
    security_opt: ["apparmor=unconfined"]
    environment:
      BEYLA_CONFIG_PATH: /config/beyla-config.yml
      BEYLA_OPEN_PORT: "3000"
      BEYLA_PROMETHEUS_PORT: "9400"
      # signal-specific OTLP var — used verbatim, no /v1/traces appended (single source of truth)
      OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://localhost:4319/v1/traces"
      OTEL_SERVICE_NAME: "backend-nodejs-ebpf"
    volumes:
      - ./beyla/beyla-config.yml:/config/beyla-config.yml:ro
      - /sys/fs/cgroup:/sys/fs/cgroup:ro

  ebpf-alloy:
    # TAG GATE: must contain the grafana/alloy#4562 kernel-≥6.16 fix (host kernel is 6.17). Verify before deploy.
    image: grafana/alloy:v1.11.0
    user: root                 # pyroscope.ebpf HARD requirement: must run as root
    pid: "host"
    network_mode: "host"
    cap_add: [BPF, PERFMON, SYS_PTRACE, SYS_RESOURCE]
    security_opt: ["apparmor=unconfined"]
    volumes:
      - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
      - ebpf_alloy_symcache:/tmp/symb-cache   # writable symbol cache required by the eBPF profiler
    command:
      - "run"
      - "/etc/alloy/config.alloy"
      - "--server.http.listen-addr=0.0.0.0:12345"

  k6:
    image: grafana/k6:0.54.0
    network_mode: "host"
    environment:
      BASE_URL: "http://localhost:3000"
    volumes:
      - ./k6/load.js:/scripts/load.js:ro
    command: ["run", "--vus", "3", "--duration", "99999s", "/scripts/load.js"]

networks:
  ebpf-net:
    driver: bridge

volumes:
  ebpf_tempo_data:
  ebpf_prometheus_data:
  ebpf_pyroscope_data:
  ebpf_grafana_data:
  ebpf_alloy_symcache:
```

Note: `ebpf-beyla` and `ebpf-alloy` use `network_mode: host`, so their `networks:`/`ports:` are intentionally
omitted (host net cannot join a bridge). They reach Tempo/Pyroscope via published localhost ports.
**If Alloy still fails to attach after pinning a fixed tag**, switch `user: root` → `privileged: true`
and record it (caps fallback).

## Dashboards

`ebpf/grafana/dashboards/beyla-http-overview.json` (schemaVersion 39, matches existing dashboard shape;
Beyla metric names per Verification Steps):

```json
{
  "uid": "beyla-http-overview",
  "title": "Beyla HTTP Overview (eBPF)",
  "tags": ["ebpf", "beyla"],
  "schemaVersion": 39,
  "time": { "from": "now-15m", "to": "now" },
  "refresh": "10s",
  "panels": [
    {
      "id": 1,
      "title": "Request Rate (req/s) by route",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 },
      "targets": [
        {
          "datasource": { "uid": "ebpf-prometheus" },
          "expr": "sum(rate(http_server_request_duration_seconds_count[1m])) by (http_route)",
          "legendFormat": "{{http_route}}"
        }
      ]
    },
    {
      "id": 2,
      "title": "Error Rate (%) 4xx + 5xx",
      "type": "timeseries",
      "gridPos": { "x": 12, "y": 0, "w": 12, "h": 8 },
      "targets": [
        {
          "datasource": { "uid": "ebpf-prometheus" },
          "expr": "100 * sum(rate(http_server_request_duration_seconds_count{http_response_status_code=~\"4..|5..\"}[1m])) / sum(rate(http_server_request_duration_seconds_count[1m]))",
          "legendFormat": "error %"
        }
      ]
    },
    {
      "id": 3,
      "title": "Latency P50/P95/P99",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 8, "w": 12, "h": 8 },
      "targets": [
        {
          "datasource": { "uid": "ebpf-prometheus" },
          "expr": "histogram_quantile(0.50, sum(rate(http_server_request_duration_seconds_bucket[1m])) by (le))",
          "legendFormat": "p50"
        },
        {
          "datasource": { "uid": "ebpf-prometheus" },
          "expr": "histogram_quantile(0.95, sum(rate(http_server_request_duration_seconds_bucket[1m])) by (le))",
          "legendFormat": "p95"
        },
        {
          "datasource": { "uid": "ebpf-prometheus" },
          "expr": "histogram_quantile(0.99, sum(rate(http_server_request_duration_seconds_bucket[1m])) by (le))",
          "legendFormat": "p99"
        }
      ]
    },
    {
      "id": 4,
      "title": "Latency Heatmap",
      "type": "heatmap",
      "gridPos": { "x": 12, "y": 8, "w": 12, "h": 8 },
      "targets": [
        {
          "datasource": { "uid": "ebpf-prometheus" },
          "expr": "sum(rate(http_server_request_duration_seconds_bucket[1m])) by (le)",
          "legendFormat": "{{le}}",
          "format": "heatmap"
        }
      ]
    },
    {
      "id": 5,
      "title": "Top routes by request count",
      "type": "table",
      "gridPos": { "x": 0, "y": 16, "w": 24, "h": 8 },
      "targets": [
        {
          "datasource": { "uid": "ebpf-prometheus" },
          "expr": "topk(10, sum(rate(http_server_request_duration_seconds_count[5m])) by (http_route, http_request_method))",
          "format": "table",
          "instant": true
        }
      ]
    }
  ]
}
```

`ebpf/grafana/dashboards/pyroscope-flamegraph.json` — **CPU flame graph only**. The PRD-requested memory
flame-graph panel is intentionally **omitted**: Alloy's `pyroscope.ebpf` is an on-CPU sampling profiler
and produces only the `process_cpu` profile type — there is no allocation/memory profile to render (see
Deviation 4 / Open Q2). A single flame-graph panel bound to `process_cpu` is the complete, correct
delivery for the eBPF path:

```json
{
  "uid": "pyroscope-flamegraph",
  "title": "Pyroscope CPU Flame Graph (eBPF)",
  "tags": ["ebpf", "pyroscope", "cpu"],
  "schemaVersion": 39,
  "time": { "from": "now-15m", "to": "now" },
  "refresh": "30s",
  "templating": {
    "list": [
      {
        "name": "service",
        "label": "Service",
        "type": "query",
        "datasource": { "uid": "ebpf-pyroscope" },
        "query": "{ }"
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "title": "CPU Flame Graph",
      "type": "flamegraph",
      "gridPos": { "x": 0, "y": 0, "w": 24, "h": 18 },
      "targets": [
        {
          "datasource": { "uid": "ebpf-pyroscope" },
          "queryType": "profile",
          "profileTypeId": "process_cpu:cpu:nanoseconds:cpu:nanoseconds",
          "labelSelector": "{}"
        }
      ]
    }
  ]
}
```

Note: exact Pyroscope query-editor field names (`profileTypeId`, `labelSelector`, `queryType`) are the
Grafana Pyroscope datasource target shape; if a field name differs in the deployed Grafana 11.1.0 build,
adjust in-UI then export — the dashboard is non-load-bearing for the smoke test (smoke checks Pyroscope
API + dashboard provisioning by UID, not panel internals). `[doc: grafana-pyroscope-datasource]`

## k6 Script

`ebpf/k6/load.js`:

```javascript
import http from 'k6/http'
import { sleep, check } from 'k6'

const BASE = __ENV.BASE_URL || 'http://localhost:3000'

export default function () {
  const health = http.get(`${BASE}/health`)
  check(health, { 'health 200': (r) => r.status === 200 })

  const list = http.get(`${BASE}/api/v1/products`)
  check(list, { 'list 200': (r) => r.status === 200 })

  const created = http.post(
    `${BASE}/api/v1/products`,
    JSON.stringify({ name: `k6-${Date.now()}`, price: 9.99 }),
    { headers: { 'Content-Type': 'application/json' } }
  )
  if (created.status === 201 || created.status === 200) {
    const id = created.json('data.id')
    if (id) http.get(`${BASE}/api/v1/products/${id}`)
  }

  sleep(1)
}
```

Note: the POST body (`name`, `price`) is **verified** against `backend/nodejs/src/products/products.schema.ts`
— `createProductSchema` requires `name` (string 1-255) + `price` (number ≥0); `stock`/`description` are
optional. The body `{ name, price: 9.99 }` is valid as-is — **no change needed**. Endpoints
`/api/v1/products` confirmed in CLAUDE.md API contract and `smoke-test-observability.sh:43`.

## Manage Script

`ebpf-manage.sh` (repo root, mirrors `manage.sh` helpers/colors; menu + subcommands; confirmation on
deploy and destroy). The agent places it at **`/home/vit/template/ebpf-manage.sh`** (impl target dir =
repo root) — NOT in SPEC_DIR. The implementor creates it with this behavior:

- `deploy` — confirm prompt; warn if backend `:3000` not listening; warn if host kernel ≥ 6.16 that
  Pyroscope profiling needs a fixed Alloy tag (grafana/alloy#4562); `docker compose -f ebpf/docker-compose.yml up -d`.
- `destroy` — confirm prompt; `down`; second prompt for `-v` (volumes).
- `plan` — `docker compose -f ebpf/docker-compose.yml config` (dry render).
- `status` — `ps` + printed URLs (Grafana :3002, Prometheus :9091, Tempo :3201, Pyroscope :4040);
  note if existing observability stack ports (3001/9090/3200/4318) are also in use.
- `logs [service|all]` — `docker compose -f ebpf/docker-compose.yml logs -f`.
- Loads `GF_ADMIN_PASSWORD` from env or `ebpf/.env` (same pattern as `manage.sh:_obs_password`).
- Interactive menu when run with no args.

## Verification Steps

Source of truth for `scripts/smoke-test-ebpf.sh` (the companion `smoke.sh` in SPEC_DIR is the artifact;
the implementor copies it to `scripts/smoke-test-ebpf.sh`). Run after `./ebpf-manage.sh deploy` and ~60s
of k6 load, with the backend already up on :3000.

| # | Check | Command (abridged) | Expected | Fatal? |
|---|---|---|---|---|
| 0 | Backend reachable | `curl ... http://localhost:3000/health` | `200` | yes |
| 1 | Beyla metrics endpoint | `curl ... http://localhost:9400/metrics` | `200` | yes |
| 2 | Beyla emitted HTTP metric | `... \| grep http_server_request_duration_seconds` | non-empty | yes |
| 3 | ebpf-prometheus ready | `curl ... http://localhost:9091/-/ready` | `200` | yes |
| 4 | Beyla target UP in Prometheus | poll `http://localhost:9091/api/v1/targets` for `"health":"up"` | up within 30s | yes |
| 5 | Beyla metric queryable | `http://localhost:9091/api/v1/query?query=http_server_request_duration_seconds_count` | `resultType:"vector"` | yes |
| 6 | ebpf-tempo reachable | `curl ... http://localhost:3201/api/echo` | `200` | yes |
| 7 | Beyla trace in Tempo | `http://localhost:3201/api/search?...service.name%3Dbackend-nodejs-ebpf` | `"traceID"` present | yes |
| 8 | Pyroscope ready | `curl ... http://localhost:4040/ready` | `200` | yes |
| 9 | Pyroscope has CPU profiles | `http://localhost:4040/pyroscope/render?query=process_cpu:...{}` | non-empty `flamebearer`/`names` | **WARN only** (kernel ≥6.16 / #4562) |
| 10 | ebpf-grafana healthy | `curl ... http://localhost:3002/api/health` | `200` | yes |
| 11 | Datasources provisioned | `curl -u admin:$PW http://localhost:3002/api/datasources` | `Prometheus`, `Tempo`, `Pyroscope` | yes |
| 12 | Dashboards provisioned | `/api/dashboards/uid/{beyla-http-overview,pyroscope-flamegraph}` | both `200` | yes |
| 13 | k6 running | `docker compose -f ebpf/docker-compose.yml ps k6` | status `running` | yes |

Note: there is **no memory-profile smoke check** — the eBPF profiler emits only `process_cpu` (memory
flame graphs deferred; see Deviation 4 / Open Q2). Check 9 deliberately queries `process_cpu` only.

Edge / failure scenarios the smoke encodes:
- **Backend down** → check 0 FAILs and Beyla checks 2/7 FAIL with a clear message pointing to "start
  backend on :3000 first".
- **Kernel ≥ 6.16 / unfixed Alloy tag** → check 9 emits a **WARN** (non-fatal) naming grafana/alloy#4562,
  so the Beyla pillar still passes the suite.
- **Auth**: Grafana datasource/dashboard checks use `admin:${GF_ADMIN_PASSWORD:-changeme}`.

**Repo has no automated unit-test harness for infra** — verification is the smoke script only (per Code
Style Conventions → Test reality).

## Observability & Rollback

- **Logs**: `./ebpf-manage.sh logs` → all services; per-service via `logs <name>`. Beyla/Alloy log eBPF
  attach success/failure at startup. **Alloy on kernel ≥6.16 with an unfixed tag** logs
  `failed to attach scheduler monitor … sched_process_free` (grafana/alloy#4562) — pin a fixed tag, do
  not chase caps. **Beyla** `failed to load BPF` → fall back to `privileged: true`.
- **Metrics/UI**: Grafana :3002 dashboards (Beyla HTTP Overview, Pyroscope CPU Flame Graph); Prometheus :9091;
  Pyroscope :4040.
- **Rollback**: `./ebpf-manage.sh destroy` (containers + network); `destroy` then confirm volume prompt
  for full wipe. No effect on the existing app/observability stacks (separate compose project + ports,
  except the documented 4318/4319 caveat — never run both stacks at once).

## Risk Summary & Open Questions

Risk table:

| Risk | Severity | Mitigation |
|---|---|---|
| **Kernel ≥ 6.16 breaks Alloy `pyroscope.ebpf` (host is 6.17)** | **High / BLOCKER** | grafana/alloy#4562: pin Alloy tag with the fix (verify CHANGELOG) OR ship Pyroscope as documented known-limitation; escalated to user. Pyroscope smoke check is non-fatal WARN. |
| Alloy `pyroscope.ebpf` config arg not in pinned tag → crash-loop | Med | minimal known-good config (`targets`+`forward_to`); verify any optional arg (`targets_only`, `demangle`) against the pinned tag's reference before deploy |
| Alloy not run as root / no symbol-cache → attach fails | Med | `user: root` + `/tmp/symb-cache` volume set; `privileged: true` fallback documented |
| Beyla trace endpoint double `/v1/traces` | Med | single source of truth: env-only `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (verbatim, no append); file does NOT set `otel_traces_export.endpoint` |
| Beyla eBPF attach fails on AppArmor with fine-grained caps | Med | documented `privileged: true` fallback; kernel 6.17 + BTF verified (Beyla unaffected by #4562) |
| Pinned image tag lacks linux/arm64 | Med | implementor `docker manifest inspect` pre-deploy; `:latest` fallback per image |
| **PRD memory flame graphs not delivered (CPU-only eBPF)** | Low / scope-deviation | eBPF profiler is on-CPU sampling only; memory needs a non-eBPF SDK (no-code-changes scope). Panel + smoke check intentionally omitted; explicitly deferred — see Deviation 4 / Open Q2 |
| `GF_ADMIN_PASSWORD` committed via `ebpf/.env` | Low | `ebpf/.env` explicitly appended to `.gitignore` |
| Pyroscope dashboard panel field names drift across Grafana builds | Low | smoke verifies API + provisioning, not panel internals; adjust in-UI + re-export |
| Concurrent run with main observability stack (port 4318, CPU) | Med | spec mandates not running both; ebpf-tempo uses 4319 |

Open Questions (NON-BLOCKING — each investigated):

1. **JS-level flame graphs depth** (PRD Open Q3). Investigated: Alloy `pyroscope.ebpf` captures native +
   kernel frames; JS function-level frames need the Pyroscope Node.js SDK (non-eBPF), which is out of
   this PRD's "no code changes" scope. Spec delivers native/kernel CPU flame graphs only; noted as a
   future SDK add-on. NON-BLOCKING.
2. **Memory / allocation flame graphs deferred — eBPF profiling is CPU-only** (PRD Goal: "continuous CPU
   **and memory** flame graphs"; PRD §Pyroscope captures "Memory allocation profiles"; PRD §Grafana
   Dashboards lists a "Memory flame graph" panel). Investigated: the embedded OTel eBPF profiler that
   Alloy's `pyroscope.ebpf` runs is an **on-CPU perf-event sampling profiler** — it produces only the
   `process_cpu` profile type and does **not** emit memory/allocation profiles. Memory profiling requires
   a language-runtime SDK (e.g. the Pyroscope Node.js SDK's heap profiler), which is the same non-eBPF,
   code-change-requiring path as the JS-depth gap (Open Q1) and is out of this PRD's "no code changes"
   scope. Therefore this spec **delivers CPU flame graphs only**; the memory flame-graph panel is
   **dropped** (not shipped as a known-empty panel that can never populate), the Pyroscope dashboard is
   retitled "CPU Flame Graph", and no memory smoke check is added. Same deviation pattern as Open Q1;
   flagged here so PRD coverage is honestly represented and an implementor does not expect a memory panel
   that can never render. `[doc: /grafana/alloy pyroscope.ebpf — on-CPU sampling only]` NON-BLOCKING (CPU
   profiling, the eBPF-achievable half of the Goal, is fully delivered; memory is a future SDK add-on).
3. **Beyla TLS/HTTPS** (PRD Open Q2). Investigated: backend is HTTP on :3000 today
   (`docker-compose.yml:36-37`); no HTTPS. If HTTPS is added later, set `BEYLA_OTEL_TRACES_INSECURE` and
   Beyla auto-uses OpenSSL uprobes. NON-BLOCKING for current contract.
4. **Exact arm64 tag availability** — resolved to "implementor verifies before deploy"; not a contract
   blocker. NON-BLOCKING.

The only **BLOCKING** item is the kernel-≥6.16 / Alloy-tag decision (top of spec + Risk table) — it
requires a user/orchestrator product decision, not further investigation.
