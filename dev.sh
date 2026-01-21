#!/bin/bash
# Flovyn Full Stack Development Environment
#
# Deployment Scenarios:
#   self-hosted  - Single org, pre-configured (default)
#   saas         - Multi-org, dynamic org creation
#
# Usage:
#   ./dev.sh start [scenario]     Start all services
#   ./dev.sh stop                 Stop all services
#   ./dev.sh server [scenario]    Start flovyn-server only
#   ./dev.sh app                  Start flovyn-app only
#   ./dev.sh status               Show service status
#   ./dev.sh logs [service]       Show logs
#   ./dev.sh migrate              Run all migrations
#   ./dev.sh clean                Remove all data

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOVYN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_DIR="$FLOVYN_ROOT/flovyn-server"
APP_DIR="$FLOVYN_ROOT/flovyn-app"

cd "$SCRIPT_DIR"

# Load .env if exists
if [ -f ".env" ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default scenario
SCENARIO="${SCENARIO:-self-hosted}"

print_header() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  Flovyn Full Stack Development Environment${NC}"
    echo -e "${BLUE}============================================${NC}"
}

print_services() {
    echo -e "\n${GREEN}Infrastructure Services:${NC}"
    echo -e "  PostgreSQL (Server): localhost:${SERVER_POSTGRES_PORT:-5435}"
    echo -e "  PostgreSQL (App):    localhost:${APP_POSTGRES_PORT:-5433}"
    echo -e "  NATS:                localhost:${NATS_PORT:-4222}"
    echo -e "  Jaeger UI:           http://localhost:${JAEGER_UI_PORT:-16686}"

    echo -e "\n${GREEN}Application URLs:${NC}"
    echo -e "  Flovyn App:          ${APP_URL:-http://localhost:3000}"
    echo -e "  Flovyn Server HTTP:  http://localhost:8000"
    echo -e "  Flovyn Server gRPC:  localhost:9090"
    echo -e "  API Docs:            http://localhost:8000/api/docs"
}

print_scenario() {
    echo -e "\n${CYAN}Deployment Scenario: ${SCENARIO}${NC}"
    case "$SCENARIO" in
        self-hosted)
            echo -e "  - Single org pre-configured"
            echo -e "  - Org slug: 'dev' (matches org in Flovyn App)"
            echo -e "  - Static API keys supported"
            ;;
        saas)
            echo -e "  - Multi-org mode"
            echo -e "  - Orgs created dynamically"
            echo -e "  - All auth via Flovyn App"
            ;;
    esac
}

wait_for_postgres() {
    local container=$1
    local user=$2
    local db=$3

    echo -e "${YELLOW}Waiting for $container to be ready...${NC}"
    until docker exec $container pg_isready -U $user -d $db > /dev/null 2>&1; do
        sleep 1
    done
    echo -e "${GREEN}$container is ready!${NC}"
}

start_infra() {
    print_header
    echo -e "\n${YELLOW}Starting infrastructure services...${NC}\n"
    docker compose up -d

    wait_for_postgres "flovyn-postgres-server" "flovyn" "flovyn"
    wait_for_postgres "flovyn-postgres-app" "flovyn-app" "flovyn-app"

    print_services
    print_scenario
}

stop_infra() {
    print_header
    echo -e "\n${YELLOW}Stopping infrastructure services...${NC}\n"
    docker compose down
    echo -e "\n${GREEN}Infrastructure stopped!${NC}"
}

start_server() {
    local scenario="${1:-$SCENARIO}"

    echo -e "\n${YELLOW}Starting Flovyn Server (${scenario})...${NC}\n"

    # Select config based on scenario
    local config_file="$SCRIPT_DIR/configs/server-${scenario}.toml"
    if [ ! -f "$config_file" ]; then
        echo -e "${RED}Config not found: $config_file${NC}"
        exit 1
    fi

    cd "$SERVER_DIR"

    export CONFIG_FILE="$config_file"
    export RUST_LOG="${RUST_LOG:-info,flovyn_server=debug}"
    export WORKER_TOKEN_SECRET="${WORKER_TOKEN_SECRET:-dev-secret-key-for-testing-only}"

    echo -e "  Config: $config_file"
    echo -e "  Server: http://localhost:8000"
    echo ""

    cargo run --bin flovyn-server
}

start_app() {
    echo -e "\n${YELLOW}Starting Flovyn App...${NC}\n"

    cd "$APP_DIR"

    export DATABASE_URL="postgresql://flovyn-app:flovyn-app@localhost:${APP_POSTGRES_PORT:-5433}/flovyn-app"
    export BETTER_AUTH_SECRET="${BETTER_AUTH_SECRET:-dev-secret-key-for-testing-only}"
    export NEXT_PUBLIC_APP_URL="${APP_URL:-http://localhost:3000}"

    echo -e "  Database: $DATABASE_URL"
    echo -e "  App URL:  $NEXT_PUBLIC_APP_URL"
    echo ""

    pnpm --filter web dev
}

migrate_all() {
    print_header
    echo -e "\n${YELLOW}Running all migrations...${NC}\n"

    # Server migrations
    echo -e "${CYAN}[1/2] Flovyn Server migrations...${NC}"
    cd "$SERVER_DIR"
    DATABASE_URL="postgres://flovyn:flovyn@localhost:${SERVER_POSTGRES_PORT:-5435}/flovyn" \
        sqlx migrate run --source server/migrations

    # App migrations (Better Auth)
    echo -e "\n${CYAN}[2/2] Flovyn App (Better Auth) migrations...${NC}"
    cd "$APP_DIR/apps/web"
    echo "y" | DATABASE_URL="postgresql://flovyn-app:flovyn-app@localhost:${APP_POSTGRES_PORT:-5433}/flovyn-app" \
        BETTER_AUTH_SECRET="${BETTER_AUTH_SECRET:-}" \
        pnpm dlx @better-auth/cli migrate --config lib/auth/better-auth-server.ts

    echo -e "\n${GREEN}All migrations complete!${NC}"
}

status() {
    print_header
    echo -e "\n${YELLOW}Container Status:${NC}\n"
    docker compose ps
    print_services
}

logs() {
    local service="${1:-}"
    if [ -z "$service" ]; then
        docker compose logs -f
    else
        docker compose logs -f "$service"
    fi
}

clean() {
    print_header
    echo -e "\n${RED}WARNING: This will remove all containers and data!${NC}"
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        docker compose down -v
        echo -e "\n${GREEN}Cleaned up all containers and volumes.${NC}"
    else
        echo -e "\n${YELLOW}Cancelled.${NC}"
    fi
}

usage() {
    print_header
    echo -e "\nUsage: $0 <command> [options]\n"
    echo "Commands:"
    echo "  start [scenario]    Start infrastructure (default: self-hosted)"
    echo "  stop                Stop all infrastructure services"
    echo "  server [scenario]   Start flovyn-server (self-hosted|saas)"
    echo "  app                 Start flovyn-app"
    echo "  status              Show service status"
    echo "  logs [service]      Show logs"
    echo "  migrate             Run all database migrations"
    echo "  clean               Remove all containers and data"
    echo ""
    echo "Scenarios:"
    echo "  self-hosted         Single org, pre-configured (default)"
    echo "  saas                Multi-org, dynamic org creation"
    echo ""
    echo "Examples:"
    echo "  $0 start                    # Start infra for self-hosted"
    echo "  $0 start saas               # Start infra for SaaS"
    echo "  $0 server                   # Run server (self-hosted config)"
    echo "  $0 server saas              # Run server (SaaS config)"
    echo "  $0 app                      # Run app (in another terminal)"
    echo ""
}

case "${1:-}" in
    start)
        SCENARIO="${2:-self-hosted}"
        start_infra
        ;;
    stop)
        stop_infra
        ;;
    server)
        start_server "${2:-self-hosted}"
        ;;
    app)
        start_app
        ;;
    status)
        status
        ;;
    logs)
        logs "${2:-}"
        ;;
    migrate)
        migrate_all
        ;;
    clean)
        clean
        ;;
    *)
        usage
        exit 1
        ;;
esac
