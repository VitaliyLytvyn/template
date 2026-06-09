#!/usr/bin/env bash
# eBPF observability smoke tests — run after ./ebpf-manage.sh deploy + ~60s of k6 load.
# Backend MUST already be running on :3000 (native or docker).
# Usage:
#   GF_ADMIN_PASSWORD=changeme scripts/smoke-test-ebpf.sh
# NOTE: the Pyroscope-profiles check (#9) is a NON-FATAL WARN — on kernels >= 6.16 the
#   Alloy eBPF profiler is broken by grafana/alloy#4562 unless a fixed Alloy tag is pinned.
set -euo pipefail

BEYLA="${BEYLA:-http://localhost:9400}"
PROMETHEUS="${PROMETHEUS:-http://localhost:9091}"
TEMPO="${TEMPO:-http://localhost:3201}"
PYROSCOPE="${PYROSCOPE:-http://localhost:4040}"
GRAFANA="${GRAFANA:-http://localhost:3002}"
COMPOSE="${COMPOSE:-ebpf/docker-compose.yml}"
PW="${GF_ADMIN_PASSWORD:-changeme}"

PASS=0
FAIL=0
pass() { echo "  [PASS] $1"; ((++PASS)); }
fail() { echo "  [FAIL] $1"; ((++FAIL)); }
warn() { echo "  [WARN] $1"; }
header() { echo; echo "=== $1 ==="; }

# ── 0. Backend reachable (eBPF needs a live process) ────────────────────────────
header "Backend prerequisite"
be=$(curl -sf -o /dev/null -w "%{http_code}" "http://localhost:3000/health" 2>/dev/null || echo "000")
[[ "$be" == "200" ]] && pass "backend /health → 200" || fail "backend not on :3000 → $be (start backend first; Beyla has nothing to attach to)"

# ── 1. Beyla ────────────────────────────────────────────────────────────────────
header "Beyla"
b_status=$(curl -sf -o /dev/null -w "%{http_code}" "$BEYLA/metrics" 2>/dev/null || echo "000")
[[ "$b_status" == "200" ]] && pass "Beyla /metrics → 200" || fail "Beyla /metrics → $b_status"
metrics=$(curl -sf "$BEYLA/metrics" 2>/dev/null || echo "")
grep -q "http_server_request_duration_seconds" <<< "$metrics" \
  && pass "Beyla emitted http_server_request_duration_seconds" \
  || fail "Beyla HTTP metric absent (no L7 captured — is k6 running / backend on :3000?)"

# ── 2. Prometheus ───────────────────────────────────────────────────────────────
header "Prometheus"
p_ready=$(curl -sf -o /dev/null -w "%{http_code}" "$PROMETHEUS/-/ready" 2>/dev/null || echo "000")
[[ "$p_ready" == "200" ]] && pass "Prometheus ready" || fail "Prometheus not ready → $p_ready"

echo "  Waiting up to 30s for Beyla target UP..."
up=false
for _ in $(seq 1 6); do
  t=$(curl -sf "$PROMETHEUS/api/v1/targets" 2>/dev/null || echo "{}")
  echo "$t" | grep -q '"health":"up"' && { up=true; break; }
  sleep 5
done
$up && pass "Beyla target UP in Prometheus" || fail "Beyla target never UP (check host.docker.internal:9400 scrape)"

q=$(curl -sf "$PROMETHEUS/api/v1/query?query=http_server_request_duration_seconds_count" 2>/dev/null | grep -o '"resultType":"[^"]*"' | head -1)
[[ "$q" == '"resultType":"vector"' ]] && pass "Beyla metric queryable in Prometheus" || fail "Beyla metric not in Prometheus yet"

# ── 3. Tempo ────────────────────────────────────────────────────────────────────
header "Tempo"
t_ready=$(curl -s -o /dev/null -w "%{http_code}" "$TEMPO/api/echo" 2>/dev/null || echo "000")
[[ "$t_ready" == "200" ]] && pass "Tempo reachable" || fail "Tempo not reachable → $t_ready"
search=$(curl -sf "$TEMPO/api/search?limit=1&tags=service.name%3Dbackend-nodejs-ebpf" 2>/dev/null || echo "")
echo "$search" | grep -q '"traceID"' \
  && pass "Beyla trace in Tempo (service.name=backend-nodejs-ebpf)" \
  || fail "No Beyla traces in Tempo (OTLP export to localhost:4319/v1/traces working?)"

# ── 4. Pyroscope ────────────────────────────────────────────────────────────────
# NON-FATAL on kernels >= 6.16: grafana/alloy#4562 breaks the eBPF profiler unless a
# fixed Alloy tag is pinned. /ready is still asserted; presence of profiles is a WARN.
header "Pyroscope"
py_ready=$(curl -s -o /dev/null -w "%{http_code}" "$PYROSCOPE/ready" 2>/dev/null || echo "000")
[[ "$py_ready" == "200" ]] && pass "Pyroscope /ready → 200" || fail "Pyroscope /ready → $py_ready"
now=$(date +%s); from=$((now - 300))
prof=$(curl -sf "$PYROSCOPE/pyroscope/render?query=process_cpu:cpu:nanoseconds:cpu:nanoseconds%7B%7D&from=${from}&until=${now}" 2>/dev/null || echo "")
if echo "$prof" | grep -qE '"names"|"flamebearer"'; then
  pass "Pyroscope has CPU profiles (Alloy eBPF working)"
else
  warn "no Pyroscope profiles — on kernel >= 6.16 this is grafana/alloy#4562 (sched_process_free); pin a fixed Alloy tag or accept Pyroscope as a deferred known-limitation. Non-fatal: Beyla pillar still passes."
fi

# ── 5. Grafana ──────────────────────────────────────────────────────────────────
header "Grafana"
gf=$(curl -sf -o /dev/null -w "%{http_code}" "$GRAFANA/api/health" 2>/dev/null || echo "000")
[[ "$gf" == "200" ]] && pass "Grafana healthy" || fail "Grafana not healthy → $gf"
ds=$(curl -sf -u "admin:${PW}" "$GRAFANA/api/datasources" 2>/dev/null || echo "[]")
echo "$ds" | grep -q '"Prometheus"' && pass "Prometheus datasource provisioned" || fail "Prometheus datasource missing"
echo "$ds" | grep -q '"Tempo"'      && pass "Tempo datasource provisioned"      || fail "Tempo datasource missing"
echo "$ds" | grep -q '"Pyroscope"'  && pass "Pyroscope datasource provisioned"  || fail "Pyroscope datasource missing"
for uid in beyla-http-overview pyroscope-flamegraph; do
  d=$(curl -s -o /dev/null -w "%{http_code}" -u "admin:${PW}" "$GRAFANA/api/dashboards/uid/$uid" 2>/dev/null || echo "000")
  [[ "$d" == "200" ]] && pass "dashboard $uid provisioned" || fail "dashboard $uid missing → $d"
done

# ── 6. k6 ───────────────────────────────────────────────────────────────────────
header "k6 load generator"
if command -v docker &>/dev/null; then
  k6st=$(docker compose -f "$COMPOSE" ps k6 2>/dev/null | grep -Eo "running|Up" | head -1 || echo "")
  [[ -n "$k6st" ]] && pass "k6 container running" || fail "k6 container not running"
else
  echo "  Skipped (docker not available)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed (Pyroscope-profiles is WARN-only on kernel >= 6.16)"
echo "════════════════════════════════"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
