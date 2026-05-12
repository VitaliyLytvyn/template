#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${DEPLOY_MODE:-docker}"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
DB_COMPOSE_FILE="$SCRIPT_DIR/db/mysql/docker-compose.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
	cat <<EOF
Usage: $0 <command> [options]

Commands:
  start       Start all services
  stop        Stop all services
  status      Show service status
  logs        Show logs (use: logs [service])
  rebuild     Rebuild and restart services
  reset-db    Drop and recreate database

Options:
  --mode <native|docker>  Deployment mode (default: docker or \$DEPLOY_MODE)

EOF
	exit 1
}

wait_for_db() {
	log_info "Waiting for MySQL..."
	local retries=30
	while [ $retries -gt 0 ]; do
		if docker exec app-mysql mysqladmin ping -h localhost --silent 2>/dev/null; then
			log_info "MySQL is ready"
			return 0
		fi
		retries=$((retries - 1))
		sleep 2
	done
	log_error "MySQL failed to start"
	return 1
}

start_native() {
	log_info "Starting in NATIVE mode..."

	log_info "Starting MySQL in Docker..."
	docker compose -f "$DB_COMPOSE_FILE" up -d
	wait_for_db

	log_info "Starting Backend..."
	cd "$SCRIPT_DIR/backend/nodejs"
	if [ ! -d "node_modules" ]; then
		npm install
	fi
	cp .env.example .env 2>/dev/null || true
	npm start &
	BE_PID=$!
	echo "$BE_PID" >"$SCRIPT_DIR/.backend.pid"

	log_info "Starting Frontend..."
	cd "$SCRIPT_DIR/front/react"
	if [ ! -d "node_modules" ]; then
		npm install
	fi
	npm run dev &
	FE_PID=$!
	echo "$FE_PID" >"$SCRIPT_DIR/.frontend.pid"

	log_info "Native services started"
	log_info "Backend:  http://localhost:3000"
	log_info "Frontend: http://localhost:5173"
}

start_docker() {
	log_info "Starting in DOCKER mode..."
	docker compose -f "$COMPOSE_FILE" up -d --build
	log_info "Docker services started"
	log_info "Backend:  http://localhost:3000"
	log_info "Frontend: http://localhost:5173"
}

stop_native() {
	log_info "Stopping native services..."

	if [ -f "$SCRIPT_DIR/.backend.pid" ]; then
		kill "$(cat "$SCRIPT_DIR/.backend.pid")" 2>/dev/null || true
		rm -f "$SCRIPT_DIR/.backend.pid"
		log_info "Backend stopped"
	fi

	if [ -f "$SCRIPT_DIR/.frontend.pid" ]; then
		kill "$(cat "$SCRIPT_DIR/.frontend.pid")" 2>/dev/null || true
		rm -f "$SCRIPT_DIR/.frontend.pid"
		log_info "Frontend stopped"
	fi

	log_info "Stopping MySQL..."
	docker compose -f "$DB_COMPOSE_FILE" down
}

stop_docker() {
	log_info "Stopping Docker services..."
	docker compose -f "$COMPOSE_FILE" down
}

status_native() {
	echo "=== Native Mode Status ==="
	echo ""

	echo "MySQL (Docker):"
	docker compose -f "$DB_COMPOSE_FILE" ps 2>/dev/null || echo "  Not running"
	echo ""

	echo "Backend:"
	if [ -f "$SCRIPT_DIR/.backend.pid" ] && kill -0 "$(cat "$SCRIPT_DIR/.backend.pid")" 2>/dev/null; then
		echo "  Running (PID: $(cat "$SCRIPT_DIR/.backend.pid"))"
	else
		echo "  Not running"
	fi
	echo ""

	echo "Frontend:"
	if [ -f "$SCRIPT_DIR/.frontend.pid" ] && kill -0 "$(cat "$SCRIPT_DIR/.frontend.pid")" 2>/dev/null; then
		echo "  Running (PID: $(cat "$SCRIPT_DIR/.frontend.pid"))"
	else
		echo "  Not running"
	fi
}

status_docker() {
	echo "=== Docker Mode Status ==="
	docker compose -f "$COMPOSE_FILE" ps
}

logs_native() {
	local service="${1:-}"
	case "$service" in
	mysql | db) docker compose -f "$DB_COMPOSE_FILE" logs -f ;;
	backend) tail -f "$SCRIPT_DIR/backend/nodejs/.log" 2>/dev/null || log_warn "No log file found" ;;
	frontend) tail -f "$SCRIPT_DIR/front/react/.log" 2>/dev/null || log_warn "No log file found" ;;
	*) docker compose -f "$DB_COMPOSE_FILE" logs -f ;;
	esac
}

logs_docker() {
	docker compose -f "$COMPOSE_FILE" logs -f "${1:-}"
}

rebuild_native() {
	log_info "Rebuilding native services..."
	stop_native

	cd "$SCRIPT_DIR/backend/nodejs"
	rm -rf node_modules
	npm install

	cd "$SCRIPT_DIR/front/react"
	rm -rf node_modules
	npm install

	log_info "Starting services..."
	cd "$SCRIPT_DIR"
	start_native
}

rebuild_docker() {
	log_info "Rebuilding Docker services..."
	docker compose -f "$COMPOSE_FILE" up -d --build
}

reset_db_native() {
	log_warn "Resetting database..."
	docker compose -f "$DB_COMPOSE_FILE" down -v
	docker compose -f "$DB_COMPOSE_FILE" up -d
	wait_for_db
	log_info "Database reset complete"
}

reset_db_docker() {
	log_warn "Resetting database..."
	docker compose -f "$COMPOSE_FILE" down -v mysql
	docker compose -f "$COMPOSE_FILE" up -d mysql
	log_info "Database reset complete"
}

case "${1:-}" in
start)
	if [ "$MODE" = "native" ]; then start_native; else start_docker; fi
	;;
stop)
	if [ "$MODE" = "native" ]; then stop_native; else stop_docker; fi
	;;
status)
	if [ "$MODE" = "native" ]; then status_native; else status_docker; fi
	;;
logs)
	if [ "$MODE" = "native" ]; then logs_native "${2:-}"; else logs_docker "${2:-}"; fi
	;;
rebuild)
	if [ "$MODE" = "native" ]; then rebuild_native; else rebuild_docker; fi
	;;
reset-db)
	if [ "$MODE" = "native" ]; then reset_db_native; else reset_db_docker; fi
	;;
*)
	usage
	;;
esac
