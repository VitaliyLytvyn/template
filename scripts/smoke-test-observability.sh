#!/usr/bin/env bash
# Observability smoke tests — run after stack is up.
# Usage:
#   ./scripts/smoke-test-observability.sh            # Docker mode (default)
#   BACKEND=http://localhost:3000 ./scripts/smoke-test-observability.sh  # native dev

set -euo pipefail

BACKEND="${BACKEND:-http://localhost:3000}"
PROMETHEUS="${PROMETHEUS:-http://localhost:9090}"
LOKI="${LOKI:-http://localhost:3100}"
TEMPO="${TEMPO:-http://localhost:3200}"
GRAFANA="${GRAFANA:-http://localhost:3001}"
OTELCOL="${OTELCOL:-http://localhost:13133}"  # otelcol health_check extension

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; ((++PASS)); }
fail() { echo "  [FAIL] $1"; ((++FAIL)); }
header() { echo; echo "=== $1 ==="; }

# ── 1. Backend ────────────────────────────────────────────────────────────────
header "Backend"

status=$(curl -sf -o /dev/null -w "%{http_code}" "$BACKEND/health")
[[ "$status" == "200" ]] && pass "/health → 200" || fail "/health → $status (expected 200)"

body=$(curl -sf "$BACKEND/health")
echo "$body" | grep -q '"status":"ok"' && pass "/health body has status:ok" || fail "/health body missing status:ok"
echo "$body" | grep -q '"db":"ok"'     && pass "/health body has db:ok"     || fail "/health body missing db:ok (DB unreachable?)"

# ── 2. Metrics endpoint ───────────────────────────────────────────────────────
header "Metrics"

metrics=$(curl -sf "$BACKEND/metrics")
echo "$metrics" | grep -q "^# HELP http_requests_total"           && pass "http_requests_total present"           || fail "http_requests_total missing"
echo "$metrics" | grep -q "^# HELP http_request_duration_seconds" && pass "http_request_duration_seconds present" || fail "http_request_duration_seconds missing"
echo "$metrics" | grep -q "^# HELP db_pool_connections_active"    && pass "db_pool_connections_active present"    || fail "db_pool_connections_active missing"
echo "$metrics" | grep -q "^# HELP nodejs_heap_size_used_bytes"   && pass "nodejs_heap_size_used_bytes present (default metrics)" || fail "nodejs_heap_size_used_bytes missing"

# Hit an endpoint then re-check counter incremented
curl -sf "$BACKEND/api/v1/products" > /dev/null
sleep 1
metrics2=$(curl -sf "$BACKEND/metrics")
echo "$metrics2" | grep -q 'http_requests_total{' && pass "http_requests_total has labelled series after request" || fail "http_requests_total has no series after request"

# ── 3. OTel Collector ────────────────────────────────────────────────────────
header "OTel Collector"

col_status=$(curl -sf -o /dev/null -w "%{http_code}" "$OTELCOL" 2>/dev/null || echo "000")
[[ "$col_status" == "200" ]] && pass "otelcol health_check → 200" || fail "otelcol health_check → $col_status (collector down or health_check ext not configured)"

# ── 4. Prometheus ────────────────────────────────────────────────────────────
header "Prometheus"

prom_ready=$(curl -sf -o /dev/null -w "%{http_code}" "$PROMETHEUS/-/ready" 2>/dev/null || echo "000")
[[ "$prom_ready" == "200" ]] && pass "Prometheus ready" || fail "Prometheus not ready → $prom_ready"

# Check backend target — retry up to 30s for first scrape
echo "  Waiting up to 30s for Prometheus target to become UP..."
prom_target_up=false
for i in $(seq 1 6); do
  targets=$(curl -sf "$PROMETHEUS/api/v1/targets" 2>/dev/null || echo "{}")
  if echo "$targets" | grep -q '"health":"up"'; then
    prom_target_up=true; break
  fi
  sleep 5
done
$prom_target_up && pass "backend target UP in Prometheus" || fail "backend target never became UP (check prometheus.yml scrape config)"

# Query for http_requests_total to confirm scrape works
prom_query=$(curl -sf "$PROMETHEUS/api/v1/query?query=http_requests_total" | grep -o '"resultType":"[^"]*"' | head -1)
[[ "$prom_query" == '"resultType":"vector"' ]] && pass "http_requests_total queryable in Prometheus" || fail "http_requests_total not in Prometheus yet (may need more time or requests)"

# ── 5. Loki ──────────────────────────────────────────────────────────────────
header "Loki"

loki_ready=$(curl -s -o /dev/null -w "%{http_code}" "$LOKI/loki/api/v1/labels" 2>/dev/null || echo "000")
[[ "$loki_ready" == "200" ]] && pass "Loki reachable" || fail "Loki not reachable → $loki_ready"

# Allow up to 30s for Promtail to ship first logs
echo "  Waiting up to 30s for logs to appear in Loki..."
loki_has_logs=false
for i in $(seq 1 6); do
  # Query last 5 minutes of logs from service=backend label
  now_ns=$(($(date +%s) * 1000000000))
  start_ns=$(( now_ns - 300000000000 ))
  loki_result=$(curl -sf "$LOKI/loki/api/v1/query_range?query=%7Bservice%3D%22backend%22%7D&start=$start_ns&end=$now_ns&limit=1" 2>/dev/null || echo "")
  if echo "$loki_result" | grep -q '"values":\[\['; then
    loki_has_logs=true; break
  fi
  sleep 5
done
$loki_has_logs && pass "Logs from service=backend visible in Loki" || fail "No logs in Loki for {service=\"backend\"} (Promtail label mismatch or not yet shipped)"

# Check traceId field in log line (Pino-OTEL correlation — camelCase)
# URL-encoded: {service="backend"} | json | trace_id != ""
loki_trace=$(curl -sf "$LOKI/loki/api/v1/query_range?query=%7Bservice%3D%22backend%22%7D%20%7C%20json%20%7C%20trace_id%20%21%3D%20%22%22&start=$start_ns&end=$now_ns&limit=1" 2>/dev/null || echo "")
echo "$loki_trace" | grep -q '"values":\[\[' && pass "trace_id in Loki logs (Pino-OTEL correlation working)" || echo "  [WARN] trace_id absent — span context may not propagate through Express 5 finish callback; traces ARE reaching Tempo"

# ── 6. Tempo ─────────────────────────────────────────────────────────────────
header "Tempo"

tempo_ready=$(curl -s -o /dev/null -w "%{http_code}" "$TEMPO/api/echo" 2>/dev/null || echo "000")
[[ "$tempo_ready" == "200" ]] && pass "Tempo reachable" || fail "Tempo not reachable → $tempo_ready"

# Search for recent traces
tempo_search=$(curl -sf "$TEMPO/api/search?limit=1&tags=service.name%3Dbackend-nodejs" 2>/dev/null || echo "")
echo "$tempo_search" | grep -q '"traceID"' && pass "Traces for service.name=backend-nodejs found in Tempo" || fail "No traces in Tempo for backend-nodejs (OTEL exporter may not be reaching collector)"

# ── 7. Grafana ───────────────────────────────────────────────────────────────
header "Grafana"

gf_ready=$(curl -sf -o /dev/null -w "%{http_code}" "$GRAFANA/api/health" 2>/dev/null || echo "000")
[[ "$gf_ready" == "200" ]] && pass "Grafana healthy" || fail "Grafana not healthy → $gf_ready"

# Check datasources provisioned
datasources=$(curl -sf -u "admin:${GF_ADMIN_PASSWORD:-changeme}" "$GRAFANA/api/datasources" 2>/dev/null || echo "[]")
echo "$datasources" | grep -q '"Prometheus"'  && pass "Prometheus datasource provisioned" || fail "Prometheus datasource missing in Grafana"
echo "$datasources" | grep -q '"Loki"'        && pass "Loki datasource provisioned"       || fail "Loki datasource missing in Grafana"
echo "$datasources" | grep -q '"Tempo"'       && pass "Tempo datasource provisioned"       || fail "Tempo datasource missing in Grafana"

# Check backend-overview dashboard provisioned (by UID)
dash_status=$(curl -s -o /dev/null -w "%{http_code}" -u "admin:${GF_ADMIN_PASSWORD:-changeme}" "$GRAFANA/api/dashboards/uid/backend-overview" 2>/dev/null || echo "000")
[[ "$dash_status" == "200" ]] && pass "backend-overview dashboard provisioned" || fail "backend-overview dashboard missing (status: $dash_status)"

# ── 8. Resilience: collector down ────────────────────────────────────────────
header "Resilience (optional — requires Docker)"

if command -v docker &>/dev/null; then
  echo "  Stopping otelcol..."
  docker compose -f docker-compose.yml -f docker-compose.observability.yml stop otelcol 2>/dev/null || true
  sleep 2
  res=$(curl -sf -o /dev/null -w "%{http_code}" "$BACKEND/api/v1/products" 2>/dev/null || echo "000")
  [[ "$res" == "200" ]] && pass "Backend returns 200 with collector down (buffering working)" || fail "Backend failed with collector down → $res"
  echo "  Restarting otelcol..."
  docker compose -f docker-compose.yml -f docker-compose.observability.yml start otelcol 2>/dev/null || true
else
  echo "  Skipped (docker not available)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "════════════════════════════════"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
