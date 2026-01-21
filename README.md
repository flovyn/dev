# Flovyn Development Environment

## Quick Start

```bash
# Self-hosted mode (single org)
mise run setup-self-hosted    # Start infra + migrate
mise run server               # Terminal 1
mise run app                  # Terminal 2

# SaaS mode (multi-org)
mise run setup-saas           # Start infra + migrate
mise run server saas          # Terminal 1
mise run app                  # Terminal 2
```

## Services

| Service | URL | Port Variable |
|---------|-----|---------------|
| Flovyn App | http://localhost:3000 | `APP_PORT` |
| Flovyn Server HTTP | http://localhost:8000 | `SERVER_HTTP_PORT` |
| Flovyn Server gRPC | localhost:9090 | `SERVER_GRPC_PORT` |
| API Docs | http://localhost:8000/api/docs | |
| Jaeger UI | http://localhost:16686 | |

## Configuration

All configuration is in `.env`. Copy and modify as needed:

### Application Ports

```bash
APP_PORT=3000              # flovyn-app port
SERVER_HTTP_PORT=8000      # flovyn-server HTTP port
SERVER_GRPC_PORT=9090      # flovyn-server gRPC port
```

### Remote Access (Tailscale, etc.)

```bash
APP_URL=https://your-host.example.ts.net
```

This configures:
- flovyn-app as OIDC issuer
- flovyn-server to trust flovyn-app as OIDC provider

### Running Multiple Instances

Change ports in `.env` to avoid conflicts:

```bash
APP_PORT=3001
SERVER_HTTP_PORT=8001
SERVER_GRPC_PORT=9091
APP_URL=http://localhost:3001
FLOVYN_GRPC_SERVER_URL=http://localhost:9091
```

## Commands

```bash
mise tasks               # List all commands
mise run status          # Show running containers
mise run logs            # View logs
mise run clean           # Remove all data
mise run db-server       # Connect to server database
mise run db-app          # Connect to app database
```

## SDK Examples

Run Rust SDK examples using the centralized `.env`:

```bash
mise run example:hello       # Hello world worker
mise run example:ecommerce   # E-commerce order processing
mise run example:pipeline    # Data pipeline ETL
mise run example:patterns    # Workflow patterns (timers, promises, etc.)
mise run example:standalone  # Standalone long-running tasks
```

### Worker Configuration

```bash
FLOVYN_GRPC_SERVER_URL=http://localhost:9090
FLOVYN_WORKER_TOKEN=fwt_dev_worker
FLOVYN_ORG_ID=550e8400-e29b-41d4-a716-446655440000
```

## Development Credentials (self-hosted)

| Type | Key | Org |
|------|-----|-----|
| REST API (Admin) | `flovyn_sk_dev_admin` | dev |
| gRPC (Worker) | `fwt_dev_worker` | dev |
