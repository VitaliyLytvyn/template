#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDS_DIR="$REPO_ROOT/.pids"
LOGS_DIR="$REPO_ROOT/logs"
BACKEND_PID="$PIDS_DIR/backend.pid"
FRONTEND_PID="$PIDS_DIR/frontend.pid"

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
  local mode="$1"
  local compose_file
  [[ "$mode" == "docker" ]] && compose_file="$REPO_ROOT/docker-compose.yml" \
                             || compose_file="$REPO_ROOT/docker-compose.db-dev.yml"
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

# ── commands ──────────────────────────────────────────────────────────────────
cmd_start() {
  local mode="$1"
  check_prereqs
  mkdir -p "$PIDS_DIR"

  if [[ "$mode" == "native" ]]; then
    mkdir -p "$LOGS_DIR"
    info "Starting DB only in Docker..."
    docker compose -f "$REPO_ROOT/docker-compose.db-dev.yml" up -d
    wait_db native

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

    success "Native started — Backend: http://localhost:3000  Frontend: http://localhost:5173"

  else
    info "Building images and starting all containers..."
    docker compose -f "$REPO_ROOT/docker-compose.yml" up -d --build
    wait_db docker

    info "Running migrations..."
    docker compose -f "$REPO_ROOT/docker-compose.yml" exec backend node dist/migrate.js

    info "Seeding..."
    docker compose -f "$REPO_ROOT/docker-compose.yml" exec -T db \
      mysql -utemplate_user -ptemplate_pass template_db \
      < "$REPO_ROOT/db/mysql/seed/seed.sql" 2>/dev/null || true

    success "Docker started — Frontend: http://localhost  Backend: http://localhost:3000"
  fi
}

cmd_stop() {
  local mode="$1"
  check_prereqs

  if [[ "$mode" == "native" ]]; then
    for pid_file in "$BACKEND_PID" "$FRONTEND_PID"; do
      if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        kill "$pid" 2>/dev/null || true
        rm -f "$pid_file"
      fi
    done
    docker compose -f "$REPO_ROOT/docker-compose.db-dev.yml" down
    success "Native stopped"
  else
    docker compose -f "$REPO_ROOT/docker-compose.yml" down
    success "Docker stopped"
  fi
}

cmd_status() {
  echo -e "\n${C_BOLD}Docker containers:${C_RESET}"
  local full_ps db_ps
  full_ps=$(docker compose -f "$REPO_ROOT/docker-compose.yml" ps 2>/dev/null || true)
  db_ps=$(docker compose -f "$REPO_ROOT/docker-compose.db-dev.yml" ps 2>/dev/null || true)
  if echo "$full_ps" | grep -q "Up"; then
    echo "$full_ps"
  elif echo "$db_ps" | grep -q "Up"; then
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
  echo
}

cmd_logs() {
  local target="$1"
  case "$target" in
    backend)
      if [[ -f "$LOGS_DIR/backend.log" ]]; then
        tail -f "$LOGS_DIR/backend.log"
      else
        docker compose -f "$REPO_ROOT/docker-compose.yml" logs -f backend
      fi
      ;;
    frontend)
      if [[ -f "$LOGS_DIR/frontend.log" ]]; then
        tail -f "$LOGS_DIR/frontend.log"
      else
        docker compose -f "$REPO_ROOT/docker-compose.yml" logs -f frontend
      fi
      ;;
    db)
      docker compose -f "$REPO_ROOT/docker-compose.yml" logs -f db 2>/dev/null || \
      docker compose -f "$REPO_ROOT/docker-compose.db-dev.yml" logs -f db
      ;;
    all)
      if [[ -f "$LOGS_DIR/backend.log" ]] || [[ -f "$LOGS_DIR/frontend.log" ]]; then
        tail -f "$LOGS_DIR/backend.log" "$LOGS_DIR/frontend.log" 2>/dev/null || true
      else
        docker compose -f "$REPO_ROOT/docker-compose.yml" logs -f backend frontend
      fi
      ;;
  esac
}

cmd_rebuild() {
  local mode="$1"
  cmd_stop "$mode"
  info "Installing dependencies..."
  (cd "$REPO_ROOT/backend/nodejs" && npm install)
  (cd "$REPO_ROOT/front/react" && npm install)
  cmd_start "$mode"
}

cmd_reset_db() {
  local mode="$1"
  check_prereqs
  echo -en "${C_YELLOW}⚠${C_RESET} Drop all DB data and restart? [y/N]: "
  read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; return 0; }

  if [[ "$mode" == "native" ]]; then
    docker compose -f "$REPO_ROOT/docker-compose.db-dev.yml" down -v
    cmd_start native
  else
    docker compose -f "$REPO_ROOT/docker-compose.yml" down -v db 2>/dev/null || \
      docker compose -f "$REPO_ROOT/docker-compose.yml" rm -fsv db
    docker compose -f "$REPO_ROOT/docker-compose.yml" up -d db
    wait_db docker
    docker compose -f "$REPO_ROOT/docker-compose.yml" exec backend node dist/migrate.js
  fi
}

# ── menu ──────────────────────────────────────────────────────────────────────
show_menu() {
  echo -e "\n${C_BOLD}${C_CYAN}  Template Manager${C_RESET}\n"
  echo -e "  ${C_CYAN} 1)${C_RESET} Start   — docker  ${C_DIM}(all services in containers, :80 / :3000)${C_RESET}"
  echo -e "  ${C_CYAN} 2)${C_RESET} Start   — native  ${C_DIM}(DB in Docker, BE+FE local, :5173 / :3000)${C_RESET}"
  echo -e "  ${C_CYAN} 3)${C_RESET} Stop    — docker"
  echo -e "  ${C_CYAN} 4)${C_RESET} Stop    — native"
  echo -e "  ${C_CYAN} 5)${C_RESET} Status"
  echo -e "  ${C_CYAN} 6)${C_RESET} Logs    — backend"
  echo -e "  ${C_CYAN} 7)${C_RESET} Logs    — frontend"
  echo -e "  ${C_CYAN} 8)${C_RESET} Logs    — db"
  echo -e "  ${C_CYAN} 9)${C_RESET} Rebuild — docker  ${C_DIM}(reinstall deps + rebuild images)${C_RESET}"
  echo -e "  ${C_CYAN}10)${C_RESET} Rebuild — native"
  echo -e "  ${C_CYAN}11)${C_RESET} Reset DB — docker ${C_DIM}(drop volume, re-migrate, re-seed)${C_RESET}"
  echo -e "  ${C_CYAN}12)${C_RESET} Reset DB — native"
  echo -e "  ${C_CYAN} 0)${C_RESET} Exit\n"
  echo -en "Choice: "
}

run_menu() {
  while true; do
    show_menu
    read -r choice
    case "$choice" in
      1)  cmd_start   docker  ;;
      2)  cmd_start   native  ;;
      3)  cmd_stop    docker  ;;
      4)  cmd_stop    native  ;;
      5)  cmd_status          ;;
      6)  cmd_logs    backend ;;
      7)  cmd_logs    frontend;;
      8)  cmd_logs    db      ;;
      9)  cmd_rebuild docker  ;;
      10) cmd_rebuild native  ;;
      11) cmd_reset_db docker ;;
      12) cmd_reset_db native ;;
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
    start)    cmd_start    "${1:-docker}" ;;
    stop)     cmd_stop     "${1:-docker}" ;;
    status)   cmd_status ;;
    logs)     cmd_logs     "${1:-all}" ;;
    rebuild)  cmd_rebuild  "${1:-docker}" ;;
    reset-db) cmd_reset_db "${1:-docker}" ;;
    help|--help|-h)
      cat <<'EOF'
Usage: ./manage.sh [command] [mode]

  (no args)                    Interactive menu
  start   [docker|native]      Start services
  stop    [docker|native]      Stop services
  status                       Show running services and processes
  logs    [backend|frontend|db|all]
  rebuild [docker|native]      Stop, reinstall deps, start
  reset-db [docker|native]     Drop DB volume and restart
EOF
      ;;
    *) error "Unknown command: $COMMAND. Run ./manage.sh help"; exit 1 ;;
  esac
fi
