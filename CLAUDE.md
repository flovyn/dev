# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the Flovyn full-stack development environment that orchestrates infrastructure and two main applications:
- **flovyn-server** (`../flovyn-server`): Rust workflow orchestration server with REST/gRPC APIs
- **flovyn-app** (`../flovyn-app`): Next.js 15 web application with Better Auth

## Commands

All commands use [Mise](https://mise.jdx.dev/) as a task runner:

```bash
# Full setup (pick one scenario)
mise run setup-self-hosted    # Single org mode
mise run setup-saas           # Multi-org mode

# Run services (in separate terminals after setup)
mise run server               # Start flovyn-server (self-hosted)
mise run server saas          # Start flovyn-server (saas)
mise run app                  # Start flovyn-app

# Infrastructure
mise run start                # Start Docker containers only
mise run stop                 # Stop all containers
mise run status               # Show container status
mise run logs                 # View all logs
mise run logs <service>       # View specific service logs
mise run clean                # Remove containers and data

# Database
mise run migrate              # Run all migrations
mise run db-server            # Connect to server database (psql)
mise run db-app               # Connect to app database (psql)
mise run query-server "SQL"   # Run SQL on server database
mise run query-app "SQL"      # Run SQL on app database

# Open in browser
mise run jaeger               # Open Jaeger UI
mise run open-app             # Open Flovyn App
mise run open-docs            # Open API docs
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
| Flovyn App | http://localhost:3000 (or `APP_URL` from .env) |
| Flovyn Server HTTP | http://localhost:8000 |
| Flovyn Server gRPC | localhost:9090 |
| API Docs (Swagger) | http://localhost:8000/api/docs |
| Jaeger UI | http://localhost:16686 |

### Configuration Files

- `configs/server-self-hosted.toml`: Self-hosted server config with pre-configured dev org
- `configs/server-saas.toml`: SaaS server config for multi-org mode
- `.env`: Environment overrides (ports, secrets, APP_URL)

### Key Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_URL` | `http://localhost:3000` | Base URL for flovyn-app and OIDC issuer |
| `SCENARIO` | `self-hosted` | Deployment scenario |
| `SERVER_POSTGRES_PORT` | `5435` | PostgreSQL port for flovyn-server |
| `APP_POSTGRES_PORT` | `5433` | PostgreSQL port for flovyn-app |

### Remote Access (Tailscale, etc.)

To access from a remote host, set `APP_URL` in `.env`:
```bash
APP_URL=https://your-host.example.ts.net
```

This configures:
- **flovyn-app**: Sets `NEXT_PUBLIC_APP_URL` for base URL and OIDC issuer in tokens
- **flovyn-server**: Configures Better Auth as OIDC provider:
  - `AUTH__BETTER_AUTH__VALIDATION_URL` → `{APP_URL}/api/auth/validate-key`
  - `AUTH__BETTER_AUTH__JWT__JWKS_URI` → `{APP_URL}/.well-known/jwks.json`
  - `AUTH__BETTER_AUTH__JWT__ISSUER` → `{APP_URL}`

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
