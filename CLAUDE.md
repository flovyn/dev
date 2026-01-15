# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the Flovyn full-stack development environment that orchestrates infrastructure and two main applications:
- **flovyn-server** (`../flovyn-server`): Rust workflow orchestration server with REST/gRPC APIs
- **flovyn-app** (`../flovyn-app`): Next.js 15 web application with Better Auth

## Commands

All commands use [Just](https://github.com/casey/just) as a task runner:

```bash
# Full setup (pick one scenario)
just setup-self-hosted    # Single org mode
just setup-saas           # Multi-org mode

# Run services (in separate terminals after setup)
just server               # Start flovyn-server (self-hosted)
just server saas          # Start flovyn-server (saas)
just app                  # Start flovyn-app

# Infrastructure
just start                # Start Docker containers only
just stop                 # Stop all containers
just status               # Show container status
just logs                 # View all logs
just logs <service>       # View specific service logs
just clean                # Remove containers and data

# Database
just migrate              # Run all migrations
just db-server            # Connect to server database (psql)
just db-app               # Connect to app database (psql)
just query-server "SQL"   # Run SQL on server database
just query-app "SQL"      # Run SQL on app database

# Open in browser
just jaeger               # Open Jaeger UI
just open-app             # Open Flovyn App
just open-docs            # Open API docs
```

## Architecture

### Deployment Scenarios

| Scenario | Description | Org Setup |
|----------|-------------|-----------|
| `self-hosted` | Single org, pre-configured | Org slug `dev` matches org in flovyn-app |
| `saas` | Multi-org | Orgs created dynamically via flovyn-app |

### Infrastructure Services (Docker Compose)

| Service | Container | Port | Purpose |
|---------|-----------|------|---------|
| PostgreSQL (Server) | flovyn-postgres-server | 5435 | flovyn-server database |
| PostgreSQL (App) | flovyn-postgres-app | 5433 | flovyn-app database |
| NATS | flovyn-nats | 4222 | Message broker for distributed streaming |
| Jaeger | flovyn-jaeger | 16686 (UI), 4317 (OTLP) | Distributed tracing |

### Application Endpoints

| Service | URL |
|---------|-----|
| Flovyn App | http://localhost:3000 |
| Flovyn Server HTTP | http://localhost:8000 |
| Flovyn Server gRPC | localhost:9090 |
| API Docs (Swagger) | http://localhost:8000/api/docs |
| Jaeger UI | http://localhost:16686 |

### Configuration Files

- `configs/server-self-hosted.toml`: Self-hosted server config with pre-configured dev org
- `configs/server-saas.toml`: SaaS server config for multi-org mode
- `.env`: Environment overrides (ports, secrets)

### Development Credentials (self-hosted)

| Type | Key | Org |
|------|-----|-----|
| REST API (Admin) | `flovyn_sk_dev_admin` | dev |
| gRPC (Worker) | `fwt_dev_worker` | dev |

## Cross-Repository Context

When working on this dev environment, you may need to reference:

- **flovyn-server**: See `../flovyn-server/CLAUDE.md` for server-specific commands and architecture
- **flovyn-app**: See `../flovyn-app/CLAUDE.md` for app-specific commands and architecture

The `dev.sh` script coordinates:
1. Server migrations via `sqlx migrate run --source server/migrations` in flovyn-server
2. App migrations via Better Auth CLI in flovyn-app
3. Server startup via `cargo run` with scenario-specific config
4. App startup via `pnpm dev --filter web`
