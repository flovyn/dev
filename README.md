# Flovyn Development Environment

## Quick Start

```bash
# Self-hosted mode (single org)
just setup-self-hosted    # Start infra + migrate
just server               # Terminal 1
just app                  # Terminal 2

# SaaS mode (multi-org)
just setup-saas           # Start infra + migrate
just server saas          # Terminal 1
just app                  # Terminal 2
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
just                 # List all commands
just status          # Show running containers
just logs            # View logs
just clean           # Remove all data
just db-server       # Connect to server database
just db-app          # Connect to app database
```
