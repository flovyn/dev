# Flovyn Full Stack Development Environment
# Usage: just <recipe>

# Default scenario
scenario := "self-hosted"

# List available recipes
default:
    @just --list

# Start infrastructure services
start scenario=scenario:
    ./dev.sh start {{scenario}}

# Stop infrastructure services
stop:
    ./dev.sh stop

# Start flovyn-server (run setup-self-hosted or setup-saas first)
server scenario=scenario:
    @docker ps --format '{{{{.Names}}}}' | grep -q flovyn-postgres-server || (echo "Error: Infrastructure not running. Run 'just setup-self-hosted' or 'just setup-saas' first." && exit 1)
    ./dev.sh server {{scenario}}

# Start flovyn-app (run setup-self-hosted or setup-saas first)
app:
    @docker ps --format '{{{{.Names}}}}' | grep -q flovyn-postgres-app || (echo "Error: Infrastructure not running. Run 'just setup-self-hosted' or 'just setup-saas' first." && exit 1)
    ./dev.sh app

# Show service status
status:
    ./dev.sh status

# Show logs (optionally for a specific service)
logs service="":
    ./dev.sh logs {{service}}

# Run all database migrations
migrate:
    ./dev.sh migrate

# Remove all containers and data
clean:
    ./dev.sh clean

# Full setup for self-hosted development
setup-self-hosted: start migrate
    @echo ""
    @echo "Setup complete! Run 'just server' and 'just app' in separate terminals."

# Full setup for SaaS development
setup-saas:
    ./dev.sh start saas
    ./dev.sh migrate
    @echo ""
    @echo "Setup complete! Run 'just server saas' and 'just app' in separate terminals."

# Connect to server database (interactive)
db-server:
    docker exec -it flovyn-postgres-server psql -U flovyn -d flovyn

# Connect to app database (interactive)
db-app:
    docker exec -it flovyn-postgres-app psql -U flovyn-app -d flovyn-app

# Query server database
query-server sql:
    docker exec flovyn-postgres-server psql -U flovyn -d flovyn -c "{{sql}}"

# Query app database
query-app sql:
    docker exec flovyn-postgres-app psql -U flovyn-app -d flovyn-app -c "{{sql}}"

# Open Jaeger UI
jaeger:
    open http://localhost:16686

# Open Flovyn App
open-app:
    open http://localhost:3000

# Open API docs
open-docs:
    open http://localhost:8000/api/docs
