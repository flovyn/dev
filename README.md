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

| Service | URL |
|---------|-----|
| Flovyn App | http://localhost:3000 |
| Flovyn Server | http://localhost:8000 |
| API Docs | http://localhost:8000/api/docs |
| Jaeger UI | http://localhost:16686 |

## Commands

```bash
mise tasks               # List all commands
mise run status          # Show running containers
mise run logs            # View logs
mise run clean           # Remove all data
mise run db-server       # Connect to server database
mise run db-app          # Connect to app database
```
