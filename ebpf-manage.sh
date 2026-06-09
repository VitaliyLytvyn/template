#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DC_EBPF="$REPO_ROOT/ebpf/docker-compose.yml"

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

# ── load Grafana password (env → ebpf/.env → prompt) ────────────────────────────
_password() {
  if [[ -z "${GF_ADMIN_PASSWORD:-}" && -f "$REPO_ROOT/ebpf/.env" ]]; then
    local val
    val=$(grep -E "^GF_ADMIN_PASSWORD=" "$REPO_ROOT/ebpf/.env" | cut -d= -f2- | tr -d "'\"" || true)
    [[ -n "$val" ]] && export GF_ADMIN_PASSWORD="$val"
  fi
  if [[ -z "${GF_ADMIN_PASSWORD:-}" ]]; then
    echo -en "${C_CYAN}▸${C_RESET} Grafana admin password: "
    read -rs GF_ADMIN_PASSWORD
    echo
    export GF_ADMIN_PASSWORD
  fi
}

_backend_check() {
  if ! curl -sf -o /dev/null --max-time 2 "http://localhost:3000/health" 2>/dev/null; then
    warn "Backend not responding on :3000 — Beyla needs a live process to attach to."
    warn "Start it first: ./manage.sh native  (or)  ./manage.sh start"
  else
    success "Backend up on :3000"
  fi
}

cmd_deploy() {
  _password
  _backend_check
  echo -en "${C_YELLOW}⚠${C_RESET} Deploy eBPF stack (privileged eBPF probes, k6 load)? [y/N]: "
  read -r c; [[ "$c" =~ ^[Yy]$ ]] || { info "Aborted."; return 0; }
  if docker compose -f "$REPO_ROOT/docker-compose.observability.yml" ps 2>/dev/null | grep -q "Up\|running"; then
    warn "Main observability stack appears to be running — port 4318/CPU contention. Stop it first."
  fi
  info "Starting eBPF stack..."
  GF_ADMIN_PASSWORD="$GF_ADMIN_PASSWORD" docker compose -f "$DC_EBPF" up -d
  success "eBPF stack started"
  cmd_status
}

cmd_destroy() {
  echo -en "${C_YELLOW}⚠${C_RESET} Stop and remove eBPF containers? [y/N]: "
  read -r c; [[ "$c" =~ ^[Yy]$ ]] || { info "Aborted."; return 0; }
  docker compose -f "$DC_EBPF" down
  echo -en "${C_YELLOW}⚠${C_RESET} Also delete volumes (traces, metrics, profiles, dashboards)? [y/N]: "
  read -r v
  if [[ "$v" =~ ^[Yy]$ ]]; then
    docker compose -f "$DC_EBPF" down -v
    success "eBPF stack and volumes removed"
  else
    success "eBPF stack removed (volumes kept)"
  fi
}

cmd_plan() {
  GF_ADMIN_PASSWORD="${GF_ADMIN_PASSWORD:-changeme}" docker compose -f "$DC_EBPF" config
}

cmd_status() {
  echo -e "\n${C_BOLD}eBPF stack containers:${C_RESET}"
  docker compose -f "$DC_EBPF" ps 2>/dev/null || echo -e "  ${C_DIM}none${C_RESET}"
  echo -e "\n${C_BOLD}  eBPF URLs${C_RESET}"
  echo -e "  ${C_CYAN}Grafana${C_RESET}     http://localhost:3002  ${C_DIM}(admin / \$GF_ADMIN_PASSWORD)${C_RESET}"
  echo -e "  ${C_CYAN}Prometheus${C_RESET}  http://localhost:9091"
  echo -e "  ${C_CYAN}Tempo${C_RESET}       http://localhost:3201"
  echo -e "  ${C_CYAN}Pyroscope${C_RESET}   http://localhost:4040"
  echo
}

cmd_logs() {
  local target="${1:-all}"
  if [[ "$target" == "all" ]]; then
    docker compose -f "$DC_EBPF" logs -f
  else
    docker compose -f "$DC_EBPF" logs -f "$target"
  fi
}

show_menu() {
  echo -e "\n${C_BOLD}${C_CYAN}  eBPF Observability Manager${C_RESET}\n"
  echo -e "  ${C_CYAN}1)${C_RESET} Deploy   ${C_DIM}(start eBPF stack — backend must be on :3000)${C_RESET}"
  echo -e "  ${C_CYAN}2)${C_RESET} Destroy  ${C_DIM}(stop; optional volume wipe)${C_RESET}"
  echo -e "  ${C_CYAN}3)${C_RESET} Status"
  echo -e "  ${C_CYAN}4)${C_RESET} Plan     ${C_DIM}(render compose config)${C_RESET}"
  echo -e "  ${C_CYAN}5)${C_RESET} Logs"
  echo -e "  ${C_CYAN}0)${C_RESET} Exit\n"
  echo -en "Choice: "
}

run_menu() {
  while true; do
    show_menu
    read -r choice
    case "$choice" in
      1) cmd_deploy ;;
      2) cmd_destroy ;;
      3) cmd_status ;;
      4) cmd_plan ;;
      5) cmd_logs all ;;
      0) echo -e "\n${C_DIM}Bye.${C_RESET}\n"; exit 0 ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

if [[ $# -eq 0 ]]; then
  run_menu
else
  COMMAND="$1"; shift || true
  case "$COMMAND" in
    deploy|start)  cmd_deploy ;;
    destroy|stop)  cmd_destroy ;;
    status)        cmd_status ;;
    plan|config)   cmd_plan ;;
    logs)          cmd_logs "${1:-all}" ;;
    help|--help|-h)
      cat <<'EOF'
Usage: ./ebpf-manage.sh [command]

  (no args)   Interactive menu
  deploy      Start the eBPF stack (alias: start)
  destroy     Stop the eBPF stack; optional volume wipe (alias: stop)
  status      Show containers + URLs
  plan        Render docker compose config (alias: config)
  logs [svc]  Tail logs (default: all)
EOF
      ;;
    *) error "Unknown command: $COMMAND. Run ./ebpf-manage.sh help"; exit 1 ;;
  esac
fi
