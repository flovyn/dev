# Flovyn CLI

A command-line interface for interacting with Flovyn Server to query and manage workflows, tasks, and tenants.

## Goals

1. **Query workflows** - List, filter, and inspect workflow executions
2. **Trigger workflows** - Start new workflow executions from the command line
3. **Inspect state** - View workflow events, task status, and execution details
4. **Stream logs** - Real-time workflow execution logs

## Non-Goals

- Worker functionality (SDK handles this)
- Workflow definition management (not server-side)
- Tenant management (use config file or API directly)

---

## Authentication

The CLI authenticates as a user, supporting the same mechanisms as the REST API:

| Method | Use Case | Implementation |
|--------|----------|----------------|
| **Static API Key** | Simple deployments | Pass via `--api-key` flag or `FLOVYN_API_KEY` env var |
| **OAuth2/OIDC** | Enterprise SSO | Browser-based flow, stores tokens in `~/.config/flovyn/` |

**Configuration file** (`flovyn-server/~/.config/flovyn/config.toml`):
```toml
[default]
server = "http://localhost:8000"
tenant = "acme"

# Option 1: Static API key (or set FLOVYN_API_KEY)
[default.auth]
type = "api_key"
key = "flovyn_sk_live_abc123..."

# Option 2: OAuth2/OIDC
[default.auth]
type = "oauth"
issuer = "https://auth.example.com"
client_id = "flovyn-cli"
```

---

## Command Structure

```
flovyn <resource> <action> [options]
```

### Global Options

| Flag | Env Var | Description |
|------|---------|-------------|
| `--server, -s` | `FLOVYN_SERVER` | Server URL (default: `http://localhost:8000`) |
| `--tenant, -t` | `FLOVYN_TENANT` | Tenant slug |
| `--api-key` | `FLOVYN_API_KEY` | Static API key |
| `--profile, -p` | `FLOVYN_PROFILE` | Config profile name (default: `default`) |
| `--output, -o` | - | Output format: `table`, `json`, `yaml` (default: `table`) |

### Workflows

```bash
# List workflow executions
flovyn workflows list [--status <STATUS>] [--kind <KIND>] [--limit <N>]

# Get workflow details
flovyn workflows get <WORKFLOW_ID>

# Trigger a new workflow
flovyn workflows trigger <KIND> [--input <JSON>] [--input-file <PATH>] \
    [--task-queue <QUEUE>] [--idempotency-key <KEY>]

# View workflow events
flovyn workflows events <WORKFLOW_ID>

# Stream workflow logs (real-time)
flovyn workflows logs <WORKFLOW_ID> [--follow, -f]

# Cancel a running workflow
flovyn workflows cancel <WORKFLOW_ID>
```

**Examples:**
```bash
# List pending workflows
flovyn workflows list --status PENDING

# Trigger workflow with JSON input
flovyn workflows trigger order-processing --input '{"orderId": "123"}'

# Trigger from file
flovyn workflows trigger data-import --input-file ./payload.json

# Follow logs in real-time
flovyn workflows logs abc123 --follow
```

### Tasks

```bash
# List tasks for a workflow
flovyn tasks list --workflow <WORKFLOW_ID>

# Get task details
flovyn tasks get <TASK_ID>
```

### Auth

```bash
# Login via OAuth (opens browser)
flovyn auth login

# Show current identity
flovyn auth whoami

# Logout (clear tokens)
flovyn auth logout
```

---

## Interactive Mode

Ratatui-based TUI for interactive workflow management:

```bash
flovyn              # Opens interactive TUI
flovyn --no-tui     # Disable TUI, use CLI mode only
```

**TUI Features:**
- Workflow list with filtering/sorting
- Real-time status updates (polling)
- Keyboard navigation (vim-style)
- Detail panes for selected items
- Log streaming view

---

## Implementation

### Crate Location

`cli/` - Top-level crate in the workspace (alongside `server/`)

### Dependencies

| Crate | Purpose |
|-------|---------|
| `clap` | Argument parsing with derive |
| `reqwest` | HTTP client for REST API |
| `tokio` | Async runtime |
| `serde` / `serde_json` | JSON serialization |
| `tabled` | Table output formatting (CLI mode) |
| `dirs` | Config file locations |
| `toml` | Config file parsing |
| `keyring` | Secure token storage (optional) |
| `ratatui` | TUI framework |
| `crossterm` | Terminal backend for ratatui |
| `oauth2` | OAuth2 PKCE flow |

### Project Structure

```
cli/
├── Cargo.toml
├── README.md
└── src/
    ├── main.rs           # Entry point, CLI parsing
    ├── config.rs         # Config file handling
    ├── output.rs         # Output formatting (table/json)
    ├── commands/
    │   ├── mod.rs
    │   ├── workflows.rs  # Workflow subcommands
    │   └── auth.rs       # Auth subcommands
    └── tui/
        ├── mod.rs        # TUI app entry point
        ├── app.rs        # App state and event loop
        ├── layout.rs     # Main layout: header, body, footer
        └── panels/       # List and detail panels
```

---

## API Coverage

The CLI uses the REST API. Current endpoints:

| Endpoint | CLI Command | Status |
|----------|-------------|--------|
| `POST /api/tenants/{slug}/workflows/{kind}/trigger` | `workflows trigger` | ✅ Available |
| `GET /api/tenants/{slug}/workflow-executions` | `workflows list` | ❌ **Needs API** |
| `GET /api/tenants/{slug}/workflow-executions/{id}` | `workflows get` | ❌ **Needs API** |
| `GET /api/tenants/{slug}/workflow-executions/{id}/events` | `workflows events` | ❌ **Needs API** |
| `GET /api/tenants/{slug}/workflow-executions/{id}/logs` (SSE) | `workflows logs` | ❌ **Needs API** |
| `POST /api/tenants/{slug}/workflow-executions/{id}/cancel` | `workflows cancel` | ❌ **Needs API** |
| `GET /api/tenants/{slug}/tasks` | `tasks list` | ❌ **Needs API** |

**Action Required:** Add missing REST API endpoints to the server before CLI can fully function.

---

## Phase Plan

### Phase 1: Core CLI & TUI Foundation
- [ ] Project setup with clap
- [ ] Config file parsing
- [ ] Static API key authentication
- [ ] `workflows trigger` command
- [ ] Table and JSON output formats
- [ ] Ratatui TUI scaffold (basic layout, navigation)

### Phase 2: Full Workflow Support
- [ ] Add missing server REST endpoints
- [ ] `workflows list` / `workflows get` / `workflows events`
- [ ] `workflows logs` with SSE streaming
- [ ] `tasks list` / `tasks get`
- [ ] Filtering and pagination
- [ ] TUI workflow list and detail views

### Phase 3: OAuth & Polish
- [ ] OAuth2 PKCE login flow
- [ ] Secure token storage
- [ ] TUI log streaming view
- [ ] Real-time status updates in TUI
