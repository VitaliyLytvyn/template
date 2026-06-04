#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDS_DIR="$REPO_ROOT/.pids"
LOGS_DIR="$REPO_ROOT/logs"
BACKEND_PID="$PIDS_DIR/backend.pid"
FRONTEND_PID="$PIDS_DIR/frontend.pid"

DC="$REPO_ROOT/docker-compose.yml"
DC_OBS="$REPO_ROOT/docker-compose.observability.yml"
DC_DEV="$REPO_ROOT/docker-compose.db-dev.yml"

# ── colors ────────────────────────────────────────────────────────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_CYAN='\033[0;36m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_RED='\033[0;31m'
C_DIM='\033[2m'

info()    { echo -e "${C_CYAN}▸${C_RESET} $*"; }
success() { echo -e "${C_GREEN}✔${C_RESET} $*"; }
warn()    { echo -e "${C_YELLOW}⚠${C_RESET} $*"; }
error()   { echo -e "${C_RED}✘${C_RESET} $*" >&2; }

# ── public IP (OCI metadata → fallback public IP service → localhost) ─────────
get_host() {
  local ip
  ip=$(curl -sf --max-time 2 http://169.254.169.254/opc/v1/vnics/ 2>/dev/null \
    | grep -o '"publicIp":"[^"]*"' | head -1 | cut -d'"' -f4)
  [[ -n "$ip" ]] && { echo "$ip"; return; }
  ip=$(curl -sf --max-time 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
  [[ -n "$ip" ]] && { echo "$ip"; return; }
  echo "localhost"
}

# ── URL summary ────────────────────────────────────────────────────────────────
# mode: docker | monitoring | native
print_urls() {
  local mode="${1:-docker}"
  local h
  h=$(get_host)
  echo -e "\n${C_BOLD}  URLs${C_RESET}"
  case "$mode" in
    docker)
      echo -e "  ${C_CYAN}Frontend${C_RESET}    http://${h}"
      echo -e "  ${C_CYAN}API${C_RESET}         http://${h}:3000"
      echo -e "  ${C_CYAN}phpMyAdmin${C_RESET}  http://${h}:8080"
      ;;
    monitoring)
      echo -e "  ${C_CYAN}Frontend${C_RESET}    http://${h}"
      echo -e "  ${C_CYAN}API${C_RESET}         http://${h}:3000"
      echo -e "  ${C_CYAN}Grafana${C_RESET}     http://${h}:3001"
      echo -e "  ${C_CYAN}Prometheus${C_RESET}  http://${h}:9090"
      echo -e "  ${C_CYAN}phpMyAdmin${C_RESET}  http://${h}:8080"
      ;;
    native)
      echo -e "  ${C_CYAN}Frontend${C_RESET}    http://${h}:5173"
      echo -e "  ${C_CYAN}Backend${C_RESET}     http://${h}:3000"
      echo -e "  ${C_CYAN}phpMyAdmin${C_RESET}  http://${h}:8080"
      ;;
  esac
  echo
}

# ── prerequisite check ────────────────────────────────────────────────────────
check_prereqs() {
  local missing=()
  for cmd in node npm docker; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if ! docker compose version &>/dev/null 2>&1; then
    missing+=("docker compose")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing prerequisites: ${missing[*]}"
    exit 1
  fi
}

# ── DB healthcheck wait ───────────────────────────────────────────────────────
wait_db() {
  local compose_file="$1"
  info "Waiting for DB to be healthy..."
  local tries=0
  while [[ $tries -lt 30 ]]; do
    local status
    status=$(docker compose -f "$compose_file" ps db --format json 2>/dev/null \
      | grep -o '"Health":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    [[ "$status" == "healthy" ]] && { success "DB healthy"; return 0; }
    sleep 3
    tries=$((tries + 1))
  done
  error "DB did not become healthy in time"
  exit 1
}

# ── docker ────────────────────────────────────────────────────────────────────
cmd_start() {
  check_prereqs
  info "Building images and starting all containers..."
  docker compose -f "$DC" up -d --build
  wait_db "$DC"

  info "Running migrations..."
  docker compose -f "$DC" exec backend node dist/migrate.js

  info "Seeding..."
  docker compose -f "$DC" exec -T db \
    mysql -utemplate_user -ptemplate_pass template_db \
    < "$REPO_ROOT/db/mysql/seed/seed.sql" 2>/dev/null || true

  success "Docker started"
  print_urls docker
}

cmd_stop() {
  check_prereqs
  docker compose -f "$DC" down
  success "Docker stopped"
}

cmd_status() {
  echo -e "\n${C_BOLD}Docker containers:${C_RESET}"
  local full_ps obs_ps db_ps
  full_ps=$(docker compose -f "$DC" ps 2>/dev/null || true)
  obs_ps=$(docker compose -f "$DC" -f "$DC_OBS" ps 2>/dev/null || true)
  db_ps=$(docker compose -f "$DC_DEV" ps 2>/dev/null || true)
  if echo "$full_ps" | grep -q "Up\|running"; then
    echo "$full_ps"
  elif echo "$db_ps" | grep -q "Up\|running"; then
    echo "$db_ps"
  else
    echo -e "  ${C_DIM}No containers running${C_RESET}"
  fi

  echo -e "\n${C_BOLD}Native processes:${C_RESET}"
  for label in backend frontend; do
    local pid_file="$PIDS_DIR/${label}.pid"
    if [[ -f "$pid_file" ]]; then
      local pid
      pid=$(cat "$pid_file")
      if kill -0 "$pid" 2>/dev/null; then
        echo -e "  ${C_GREEN}●${C_RESET} $label running (PID $pid)"
      else
        echo -e "  ${C_YELLOW}●${C_RESET} $label stale PID $pid (not running)"
      fi
    else
      echo -e "  ${C_DIM}●${C_RESET} $label not running"
    fi
  done

  # Detect active mode and print URLs
  local obs_running=false docker_running=false native_running=false
  docker compose -f "$DC" -f "$DC_OBS" ps 2>/dev/null | grep -q "Up\|running" && obs_running=true
  docker compose -f "$DC" ps 2>/dev/null | grep -q "Up\|running" && docker_running=true
  [[ -f "$BACKEND_PID" ]] && kill -0 "$(cat "$BACKEND_PID")" 2>/dev/null && native_running=true

  if $obs_running; then
    print_urls monitoring
  elif $docker_running; then
    print_urls docker
  elif $native_running; then
    print_urls native
  else
    echo
  fi
}

cmd_logs() {
  local target="$1"
  case "$target" in
    backend)  docker compose -f "$DC" logs -f backend ;;
    frontend) docker compose -f "$DC" logs -f frontend ;;
    db)       docker compose -f "$DC" logs -f db ;;
    all)      docker compose -f "$DC" logs -f ;;
  esac
}

cmd_rebuild() {
  cmd_stop
  info "Installing dependencies..."
  (cd "$REPO_ROOT/backend/nodejs" && npm install)
  (cd "$REPO_ROOT/front/react" && npm install)
  cmd_start
}

cmd_reset_db() {
  check_prereqs
  echo -en "${C_YELLOW}⚠${C_RESET} Drop all DB data and restart? [y/N]: "
  read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; return 0; }
  docker compose -f "$DC" down -v db 2>/dev/null || \
    docker compose -f "$DC" rm -fsv db
  docker compose -f "$DC" up -d db
  wait_db "$DC"
  docker compose -f "$DC" exec backend node dist/migrate.js
}

# ── observability ─────────────────────────────────────────────────────────────
_obs_password() {
  # Load from repo-root .env if present and var not already set
  if [[ -z "${GF_ADMIN_PASSWORD:-}" && -f "$REPO_ROOT/.env" ]]; then
    local val
    val=$(grep -E "^GF_ADMIN_PASSWORD=" "$REPO_ROOT/.env" | cut -d= -f2- | tr -d "'\"" || true)
    [[ -n "$val" ]] && export GF_ADMIN_PASSWORD="$val"
  fi
  if [[ -z "${GF_ADMIN_PASSWORD:-}" ]]; then
    echo -en "${C_CYAN}▸${C_RESET} Grafana admin password: "
    read -rs GF_ADMIN_PASSWORD
    echo
    export GF_ADMIN_PASSWORD
  fi
}

cmd_monitoring_start() {
  check_prereqs
  _obs_password
  info "Starting app + observability stack..."
  GF_ADMIN_PASSWORD="$GF_ADMIN_PASSWORD" \
    docker compose -f "$DC" -f "$DC_OBS" up -d --build
  wait_db "$DC"

  info "Running migrations..."
  docker compose -f "$DC" -f "$DC_OBS" exec backend node dist/migrate.js

  info "Seeding..."
  docker compose -f "$DC" -f "$DC_OBS" exec -T db \
    mysql -utemplate_user -ptemplate_pass template_db \
    < "$REPO_ROOT/db/mysql/seed/seed.sql" 2>/dev/null || true

  success "Started"
  print_urls monitoring
}

cmd_monitoring_stop() {
  check_prereqs
  docker compose -f "$DC" -f "$DC_OBS" down
  success "App + observability stopped"
}

# ── native (CLI only) ─────────────────────────────────────────────────────────
cmd_native_start() {
  check_prereqs
  mkdir -p "$PIDS_DIR" "$LOGS_DIR"
  info "Starting DB only in Docker..."
  docker compose -f "$DC_DEV" up -d
  wait_db "$DC_DEV"

  info "Running migrations..."
  (cd "$REPO_ROOT/backend/nodejs" && npm run db:migrate)

  info "Seeding..."
  mysql -utemplate_user -ptemplate_pass -h 127.0.0.1 template_db \
    < "$REPO_ROOT/db/mysql/seed/seed.sql" 2>/dev/null || true

  info "Starting backend (logs → logs/backend.log)..."
  (cd "$REPO_ROOT/backend/nodejs" && npm run dev > "$LOGS_DIR/backend.log" 2>&1 &)
  echo $! > "$BACKEND_PID"

  info "Starting frontend (logs → logs/frontend.log)..."
  (cd "$REPO_ROOT/front/react" && npm run dev > "$LOGS_DIR/frontend.log" 2>&1 &)
  echo $! > "$FRONTEND_PID"

  success "Native started"
  print_urls native
}

cmd_native_stop() {
  for pid_file in "$BACKEND_PID" "$FRONTEND_PID"; do
    if [[ -f "$pid_file" ]]; then
      local pid
      pid=$(cat "$pid_file")
      kill "$pid" 2>/dev/null || true
      rm -f "$pid_file"
    fi
  done
  docker compose -f "$DC_DEV" down
  success "Native stopped"
}

# ── menu ──────────────────────────────────────────────────────────────────────
show_menu() {
  echo -e "\n${C_BOLD}${C_CYAN}  Template Manager${C_RESET}\n"
  echo -e "  ${C_CYAN} 1)${C_RESET} Start          ${C_DIM}(all services in containers, :80 / :3000)${C_RESET}"
  echo -e "  ${C_CYAN} 2)${C_RESET} Stop"
  echo -e "  ${C_CYAN} 3)${C_RESET} Status"
  echo -e "  ${C_CYAN} 4)${C_RESET} Logs — backend"
  echo -e "  ${C_CYAN} 5)${C_RESET} Logs — frontend"
  echo -e "  ${C_CYAN} 6)${C_RESET} Logs — db"
  echo -e "  ${C_CYAN} 7)${C_RESET} Rebuild        ${C_DIM}(reinstall deps + rebuild images)${C_RESET}"
  echo -e "  ${C_CYAN} 8)${C_RESET} Reset DB       ${C_DIM}(drop volume, re-migrate, re-seed)${C_RESET}"
  echo -e "  ${C_DIM}───────────────────────────────────────────${C_RESET}"
  echo -e "  ${C_CYAN} 9)${C_RESET} Monitoring — start ${C_DIM}(app + Grafana / Prometheus / Tempo / Loki)${C_RESET}"
  echo -e "  ${C_CYAN}10)${C_RESET} Monitoring — stop"
  echo -e "  ${C_CYAN} 0)${C_RESET} Exit\n"
  echo -en "Choice: "
}

run_menu() {
  while true; do
    show_menu
    read -r choice
    case "$choice" in
      1)  cmd_start           ;;
      2)  cmd_stop            ;;
      3)  cmd_status          ;;
      4)  cmd_logs backend    ;;
      5)  cmd_logs frontend   ;;
      6)  cmd_logs db         ;;
      7)  cmd_rebuild         ;;
      8)  cmd_reset_db        ;;
      9)  cmd_monitoring_start ;;
      10) cmd_monitoring_stop  ;;
      0)  echo -e "\n${C_DIM}Bye.${C_RESET}\n"; exit 0 ;;
      *)  warn "Invalid choice" ;;
    esac
  done
}

# ── dispatch ──────────────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  run_menu
else
  COMMAND="$1"
  shift || true
  case "$COMMAND" in
    start)      cmd_start ;;
    stop)       cmd_stop ;;
    status)     cmd_status ;;
    logs)       cmd_logs "${1:-all}" ;;
    rebuild)    cmd_rebuild ;;
    reset-db)   cmd_reset_db ;;
    monitoring) cmd_monitoring_"${1:-start}" ;;
    native)     cmd_native_"${1:-start}" ;;
    help|--help|-h)
      cat <<'EOF'
Usage: ./manage.sh [command] [subcommand]

  (no args)              Interactive menu (Docker mode only)
  start                  Start Docker stack
  stop                   Stop Docker stack
  status                 Show running services
  logs [backend|frontend|db|all]
  rebuild                Stop, reinstall deps, rebuild images, start
  reset-db               Drop DB volume and restart
  monitoring [start|stop]  App + full observability stack
  native [start|stop]    Native mode (DB in Docker, BE+FE local)
EOF
      ;;
    *) error "Unknown command: $COMMAND. Run ./manage.sh help"; exit 1 ;;
  esac
fi
