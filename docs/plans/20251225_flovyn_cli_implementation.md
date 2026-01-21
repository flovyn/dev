# Flovyn CLI Implementation Plan

**Design Document**: [Flovyn CLI Design](../design/flovyn-cli.md)

## Overview

This plan implements the Flovyn CLI progressively, with each phase delivering a complete, usable feature. After each phase, the CLI is functional and can be used for real work.

## Current State

- **Existing**: `POST /api/tenants/{slug}/workflows/{kind}/trigger` and SSE streaming endpoints
- **Existing**: `GET /api/tenants/{slug}/workflow-executions` (list workflows)
- **Existing**: `cli/` with `flovyn` binary
- **Existing**: `crates/rest-client/` with shared REST client
- **Missing**: Get workflow endpoint, task endpoints, cancel endpoint

## Guiding Principles

1. **End-to-end per phase**: Each phase adds server endpoint + CLI command together
2. **Usable at every step**: After each phase, the CLI works for real tasks
3. **CLI first, TUI later**: TUI is a polish feature, not a blocker

---

## Phase 1: CLI Foundation + `workflows trigger` ✅ COMPLETED

**Goal**: Basic CLI that can trigger workflows using existing API.

### TODO

- [x] **1.1** Create `flovyn-server/cli/Cargo.toml`
- [x] **1.2** Add `cli` to workspace members
- [x] **1.3** Create `flovyn-server/cli/src/config.rs`
  - `Config` struct: server URL, tenant, auth config
  - `AuthConfig::ApiKey { key }` variant
  - `Config::load()` from `flovyn-server/~/.config/flovyn/config.toml`
  - Environment variable overrides: `FLOVYN_SERVER`, `FLOVYN_TENANT`, `FLOVYN_API_KEY`
- [x] **1.4** Create `crates/rest-client/` (shared REST client crate)
  - `FlovynClient` struct wrapping `reqwest::Client`
  - `trigger_workflow()` and `list_workflows()` methods
- [x] **1.5** Create `flovyn-server/cli/src/commands/mod.rs` and `flovyn-server/commands/workflows.rs`
  - `WorkflowsCommand` enum with `Trigger` and `List` variants
- [x] **1.6** Create `flovyn-server/cli/src/main.rs`
  - Global options: `--server`, `--tenant`, `--api-key`, `--profile`, `--output`
- [x] **1.7** Test: trigger workflow from CLI
  ```bash
  flovyn workflows trigger order-processing --input '{"orderId": "123"}'
  ```

**Usable after Phase 1**: Can trigger workflows from command line.

---

## Phase 2: `workflows list` ✅ COMPLETED

**Goal**: List workflow executions with filtering.

### TODO

- [x] **2.1** Add `WorkflowRepository::list_with_filters()` in server
  - Parameters: `tenant_id`, `status` (optional), `kind` (optional), `limit`, `offset`
  - SQL with dynamic WHERE clauses
  - Returns: `(Vec<WorkflowExecution>, total_count)`
- [x] **2.2** Add `list_workflows` handler in `flovyn-server/server/src/api/rest/workflows.rs`
  - Endpoint: `GET /api/tenants/:tenant_slug/workflow-executions`
  - Query params: `status`, `kind`, `limit` (default 20), `offset` (default 0)
  - Response: `ListWorkflowsResponse { workflows, total, limit, offset }`
- [x] **2.3** Add OpenAPI annotations and register route
- [x] **2.4** Add `tabled` dependency to CLI for table output
- [x] **2.5** Create `flovyn-server/crates/cli/src/output.rs`
  - `OutputFormat` enum: `Table`, `Json`
  - `workflow_list()` using tabled
- [x] **2.6** Add `client.list_workflows()` method in `crates/rest-client/`
- [x] **2.7** Implement `flovyn workflows list` command
  - Flags: `--status`, `--kind`, `--limit`, `--offset`
  - Render as table or JSON based on `--output`
- [x] **2.8** Test: 5 integration tests with testcontainers
  - `test_rest_list_workflows_empty`
  - `test_rest_list_workflows_with_results`
  - `test_rest_list_workflows_status_filter`
  - `test_rest_list_workflows_pagination`
  - `test_rest_list_workflows_tenant_not_found`

**Usable after Phase 2**: Can trigger and list workflows.

---

## Phase 3: `workflows get` ✅ COMPLETED

**Goal**: Get detailed information about a specific workflow.

**Reference**: Kotlin `WorkflowExecutionController.getWorkflowExecution()`

### TODO

- [x] **3.1** Add `get_workflow` handler in `flovyn-server/server/src/api/rest/workflows.rs`
  - Endpoint: `GET /api/tenants/:tenant_slug/workflow-executions/:id`
  - Uses existing `WorkflowRepository::get()`
  - Response: `WorkflowExecutionResponse` (uses RFC3339 timestamps for readability):
    ```rust
    pub struct WorkflowExecutionResponse {
        pub id: Uuid,
        pub tenant_id: Uuid,
        pub kind: String,
        pub task_queue: String,
        pub state: String,                    // PENDING, RUNNING, WAITING, COMPLETED, FAILED, CANCELLED
        pub input: Option<serde_json::Value>,
        pub output: Option<serde_json::Value>,
        pub error: Option<String>,
        pub current_sequence: i32,
        pub workflow_version: Option<String>,
        pub parent_workflow_execution_id: Option<Uuid>,
        pub worker_id: Option<String>,
        pub created_at: DateTime<Utc>,        // RFC3339 for human readability
        pub started_at: Option<DateTime<Utc>>,
        pub completed_at: Option<DateTime<Utc>>,
        pub updated_at: DateTime<Utc>,
    }
    ```

- [x] **3.2** Add OpenAPI annotations and register route

- [x] **3.3** Add `client.get_workflow()` method to `crates/rest-client/`

- [x] **3.4** Implement `flovyn workflows get <ID>` command
  - Table output: id, kind, status, task_queue, created_at, started_at, completed_at
  - Show input/output as formatted JSON
  - Show error if present

- [x] **3.5** Integration tests with testcontainers
  - `test_rest_get_workflow_success`
  - `test_rest_get_workflow_not_found`
  - `test_rest_get_workflow_wrong_tenant`

**Usable after Phase 3**: Can trigger, list, and inspect workflows.

---

## Phase 4: `workflows events` ✅ COMPLETED

**Goal**: View event history for a workflow.

**Reference**: Kotlin `WorkflowExecutionController.getWorkflowExecutionEvents()`

### TODO

- [x] **4.1** Add `get_workflow_events` handler in `flovyn-server/server/src/api/rest/workflows.rs`
  - Endpoint: `GET /api/tenants/:tenant_slug/workflow-executions/:id/events`
  - Query params: `sinceSequence` (optional, for polling/pagination)
  - Uses existing `EventRepository::get_events()` and `get_events_after()`
  - Response: `WorkflowEventsResponse`:
    ```rust
    pub struct WorkflowEventsResponse {
        pub events: Vec<WorkflowEventResponse>,
    }

    pub struct WorkflowEventResponse {
        pub sequence: i32,
        pub event_type: String,           // WORKFLOW_STARTED, TASK_SCHEDULED, etc.
        pub timestamp: DateTime<Utc>,     // RFC3339 for human readability
        pub data: Option<serde_json::Value>, // Event-specific payload
    }
    ```

- [x] **4.2** Add OpenAPI annotations and register route

- [x] **4.3** Add `client.get_workflow_events()` method to `crates/rest-client/`
  - Support `since_sequence` parameter

- [x] **4.4** Implement `flovyn workflows events <ID>` command
  - Table: sequence, event_type, timestamp
  - `--since <SEQ>`: only show events after sequence number
  - JSON: full event details with data payload
  - Note: `--follow` flag deferred to Phase 5 (streaming)

- [x] **4.5** Integration tests with testcontainers
  - `test_rest_get_workflow_events`
  - `test_rest_get_workflow_events_since_sequence`
  - `test_rest_get_workflow_events_not_found`

**Usable after Phase 4**: Full workflow inspection including event history.

---

## Phase 5: `workflows logs` (streaming) ✅ COMPLETED

**Goal**: Stream workflow events in real-time.

### TODO

- [x] **5.1** Add `reqwest-eventsource` dependency to rest-client
  - Added `reqwest-eventsource = "0.6"` and `futures = "0.3"` to `flovyn-server/crates/rest-client/Cargo.toml`

- [x] **5.2** Add `client.stream_workflow()` method
  - Connect to existing SSE endpoint: `/api/tenants/:tenant_slug/stream/workflows/:id`
  - Return async stream of `StreamEvent` with type-safe `StreamEventType` enum
  - Uses `RequestBuilderExt` from `reqwest-eventsource` for SSE support

- [x] **5.3** Implement `flovyn workflows logs <ID>` command
  - Default: fetch current events (uses existing `events` endpoint)
  - `--follow` (`-f`) flag: stream events in real-time via SSE
  - Display events as they arrive with type prefix (`[TOKEN]`, `[PROGRESS]`, `[DATA]`, `[ERROR]`)

- [x] **5.4** Test: stream workflow logs
  ```bash
  flovyn workflows logs 550e8400-e29b-41d4-a716-446655440000 --follow
  ```

**Usable after Phase 5**: Real-time workflow monitoring.

---

## Phase 6: `workflows cancel` ✅ COMPLETED

**Goal**: Cancel a running workflow.

**Reference**: Kotlin `WorkflowExecutionController.cancelWorkflowExecution()`

### TODO

- [x] **6.1** Add `cancel_workflow` handler in `flovyn-server/server/src/api/rest/workflows.rs`
  - Endpoint: `POST /api/tenants/:tenant_slug/workflow-executions/:id/cancel`
  - Request body:
    ```rust
    pub struct CancelWorkflowRequest {
        pub reason: Option<String>,
        pub cascade_to_children: bool,  // Default: true
    }
    ```
  - Response with typed enum status:
    ```rust
    pub enum CancelStatus {
        Cancelled,       // "CANCELLED"
        AlreadyTerminal, // "ALREADY_TERMINAL"
    }
    pub struct CancelWorkflowResponse {
        pub status: CancelStatus,
        pub cancelled_children: i32,  // Number of child workflows cancelled
    }
    ```
  - Uses `WorkflowRepository::cancel_with_children()` for cascade support

- [x] **6.2** Add OpenAPI annotations and register route

- [x] **6.3** Add `client.cancel_workflow()` method to `crates/rest-client/`
  - With `CancelStatus` enum for type-safe status handling

- [x] **6.4** Implement `flovyn workflows cancel <ID>` command
  - `--reason <TEXT>`: optional cancellation reason
  - `--cascade`: also cancel child workflows (flag)
  - Display: status and number of cancelled children

- [x] **6.5** Integration tests with testcontainers
  - `test_rest_cancel_workflow_success`
  - `test_rest_cancel_workflow_already_terminal`
  - `test_rest_cancel_workflow_not_found`

**Usable after Phase 6**: Complete workflow lifecycle management.

---

## Phase 7: `workflows tasks` ✅ COMPLETED

**Goal**: Inspect task executions for a workflow.

**Reference**: Kotlin `WorkflowTaskHistoryController.getWorkflowTaskHistory()`

### TODO

- [x] **7.1** Add `get_workflow_tasks` handler in `flovyn-server/server/src/api/rest/workflows.rs`
  - Endpoint: `GET /api/tenants/:tenant_slug/workflow-executions/:id/tasks`
  - Added `TaskRepository::list_by_workflow_execution_id()` method
  - Response `WorkflowTasksResponse`:
    ```rust
    pub struct WorkflowTasksResponse {
        pub tasks: Vec<TaskExecutionSummary>,
    }

    pub struct TaskExecutionSummary {
        pub id: Uuid,
        pub task_type: String,
        pub status: String,                    // PENDING, RUNNING, COMPLETED, FAILED, CANCELLED
        pub queue: String,
        pub execution_count: i32,
        pub max_retries: i32,
        pub progress: Option<f64>,
        pub progress_details: Option<String>,
        pub input: Option<serde_json::Value>,
        pub output: Option<serde_json::Value>,
        pub error: Option<String>,
        pub worker_id: Option<String>,
        pub created_at: DateTime<Utc>,         // RFC3339 for human readability
        pub started_at: Option<DateTime<Utc>>,
        pub completed_at: Option<DateTime<Utc>>,
    }
    ```
  - Note: Individual attempt tracking deferred (current schema only tracks execution_count)

- [x] **7.2** Add OpenAPI annotations and register route

- [x] **7.3** Add `client.get_workflow_tasks()` method to `crates/rest-client/`

- [x] **7.4** Implement `flovyn workflows tasks <WORKFLOW_ID>` command
  - Table: task_id (short), task_type, status, queue, attempts, progress
  - `--output json`: full details

- [x] **7.5** Integration tests with testcontainers
  - `test_rest_get_workflow_tasks_empty`
  - `test_rest_get_workflow_tasks_not_found`

**Usable after Phase 7**: Full workflow + task inspection.

---

## Phase 8: `auth` commands ✅ COMPLETED

**Goal**: Authentication management.

### TODO

- [x] **8.1** Create `flovyn-server/cli/src/commands/auth.rs`
  - Created `AuthCommand` enum with `Whoami`, `Logout`, `Login` variants
  - Added `AuthError` type for auth-specific errors

- [x] **8.2** Implement `flovyn auth whoami`
  - Display current server, tenant, auth method
  - If API key: show masked key (last 4 chars)
  - Detects auth source: CLI flag, environment variable, or config file
  - Supports JSON output format

- [x] **8.3** Implement `flovyn auth logout`
  - Clear stored tokens from `~/.config/flovyn/tokens/`
  - Handles missing tokens gracefully

- [x] **8.4** Add OAuth2 dependencies
  ```toml
  oauth2 = "4"
  open = "5"
  url = "2"
  reqwest = { workspace = true }
  ```

- [x] **8.5** Implement `flovyn auth login`
  - Read OAuth config from config file profile
  - OIDC discovery via `.well-known/openid-configuration`
  - Start local HTTP server on random port for callback
  - Open browser with authorization URL (PKCE flow)
  - Wait for callback, exchange code for tokens
  - Store tokens in `flovyn-server/~/.config/flovyn/tokens/<profile>.json`

- [ ] **8.6** Update `Config::load()` to use stored OAuth tokens
  - Note: Deferred to when OAuth is actually tested with a real provider

- [x] **8.7** Test: auth commands work
  ```bash
  flovyn auth whoami           # Shows current auth status
  flovyn auth logout           # Clears stored tokens
  flovyn auth login            # OAuth flow (requires config)
  ```

**Usable after Phase 8**: Full authentication support.

---

## Phase 9: TUI Mode - Core Layout ✅ COMPLETED

**Goal**: Interactive terminal UI with list + detail panel layout.

### TUI Layout

```
┌─────────────────────────────────────────────────────────────────────┐
│ Flovyn - tenant: acme                              server: :8000    │
├──────────────────────────┬──────────────────────────────────────────┤
│ Workflows                │ Detail                                   │
│ ─────────────────────────│ ──────────────────────────────────────── │
│ ▶ abc123  order-proc RUN │ [Overview] [Events] [Logs] [Actions]     │
│   def456  payment    OK  │ ──────────────────────────────────────── │
│   ghi789  shipping   FAIL│ ID:      abc123-def456-...               │
│   jkl012  notify     PEND│ Kind:    order-processing                │
│                          │ Status:  RUNNING                         │
│                          │ Created: 2024-01-15 10:30:00             │
│                          │ Queue:   default                         │
│                          │                                          │
│                          │ Input:                                   │
│                          │ {"orderId": "12345", "userId": "u1"}     │
│                          │                                          │
├──────────────────────────┴──────────────────────────────────────────┤
│ j/k: navigate  Enter: select  Tab: switch tab  q: quit  ?: help     │
└─────────────────────────────────────────────────────────────────────┘
```

### TODO

- [x] **9.1** Add TUI dependencies
  ```toml
  ratatui = "0.29"
  crossterm = "0.28"
  ```

- [x] **9.2** Create `flovyn-server/cli/src/tui/mod.rs`
  - Module exports `run_tui` function

- [x] **9.3** Create `flovyn-server/cli/src/tui/app.rs`
  - `App` struct with state:
    - `workflows: Vec<WorkflowSummary>`
    - `selected_index: usize`
    - `active_panel: ActivePanel` (List or Detail)
    - `detail_tab: DetailTab` (Overview, Events, Logs, Actions)
  - Event loop with crossterm
  - Input handling: j/k navigation, Tab switching, Enter/Esc for panel focus

- [x] **9.4** Create `flovyn-server/cli/src/tui/layout.rs`
  - Main layout: header, body (list + detail), footer
  - `render_header()`: tenant, server info, loading/error status
  - `render_footer()`: context-aware keyboard shortcuts

- [x] **9.5** Create `flovyn-server/cli/src/tui/panels/list.rs`
  - Workflow list panel (left side, 35% width)
  - Status indicators with color coding
  - Highlight selected item
  - Navigation: `j/k` or arrows

- [x] **9.6** Create `flovyn-server/cli/src/tui/panels/detail.rs`
  - Detail panel (right side, 65% width)
  - Tab bar: Overview, Events, Logs, Actions
  - Tab switching with `Tab` or `1/2/3/4`

- [x] **9.7** Create Overview tab content
  - Display workflow fields: id, kind, status, timestamps, queue
  - Input/output JSON (pretty printed, first 10 lines)

- [x] **9.8** Update `main.rs` for TUI mode
  - `flovyn dashboard` or `flovyn ui` → launch TUI
  - Standard subcommands work as before

- [x] **9.9** Implement background data fetching
  - Async task to poll `list_workflows()` every 2s
  - Update list without blocking UI
  - Fetch detail when selection changes
  - Uses tokio channels for async message passing

- [x] **9.10** Test: TUI launches and navigates
  ```bash
  flovyn dashboard --tenant acme    # Opens TUI
  flovyn ui --tenant acme           # Alias for dashboard
  ```

**Usable after Phase 9**: Interactive workflow browsing with list + detail view.

---

## Phase 10: TUI Detail Tabs ✅ COMPLETED

**Goal**: Implement Events, Logs, and Actions tabs in detail panel.

### TODO

- [x] **10.1** Create Events tab
  - Fetch events via `get_workflow_events()` when tab is selected
  - Table display: sequence, event type, timestamp
  - Color coding by event type (green for completed, red for failed, etc.)

- [x] **10.2** Create Logs tab (placeholder)
  - Infrastructure for log messages added to App state
  - Note: Real-time SSE streaming in TUI deferred (complex integration)
  - Placeholder message displayed

- [x] **10.3** Create Actions tab
  - Cancel action available for RUNNING/PENDING/WAITING workflows
  - `[c]` key to cancel workflow
  - Status feedback displayed in tab
  - Automatic list refresh after cancel

- [ ] **10.4** Add filtering to list panel
  - Note: Deferred to Phase 11 (polish)

- [ ] **10.5** Add keyboard shortcuts help overlay
  - Note: Deferred to Phase 11 (polish)

- [x] **10.6** Test: tabs functional
  - Events tab loads and displays event history
  - Actions tab allows workflow cancellation

**Usable after Phase 10**: TUI with Events and Actions tabs working.

---

## Phase 11: TUI Polish ✅ COMPLETED

**Goal**: Enhanced UX and additional features.

### TODO

- [ ] **11.1** Add trigger workflow dialog
  - Note: Deferred (complex form UI)

- [ ] **11.2** Add task list view
  - Note: Deferred (nested navigation complexity)

- [x] **11.3** Add status-based styling
  - RUNNING: yellow with ▶ indicator
  - COMPLETED: green with ✓ indicator
  - FAILED: red with ✗ indicator
  - PENDING: gray with ○ indicator
  - WAITING: cyan with ◐ indicator
  - CANCELLED: dim with ⊘ indicator

- [x] **11.4** Add filtering
  - `/` to enter filter mode
  - Type to filter by kind, status, or ID
  - `Esc` to clear filter
  - Filter indicator shown in header and list title

- [x] **11.5** Add help overlay
  - `?` to toggle help overlay
  - Shows all keyboard shortcuts grouped by context

- [x] **11.6** Auto-refresh
  - 2-second automatic refresh interval
  - Loading indicator in header
  - `r` to force refresh

**Usable after Phase 11**: Polished TUI with filtering and help.

---

## File Structure

```
cli/
├── Cargo.toml
├── README.md
└── src/
    ├── main.rs              # Entry point, CLI parsing
    ├── config.rs            # Config file handling
    ├── output.rs            # Output formatting (table/json)
    ├── commands/
    │   ├── mod.rs
    │   ├── workflows.rs     # Workflow commands
    │   └── auth.rs          # Auth commands
    └── tui/
        ├── mod.rs           # TUI module entry
        ├── app.rs           # App state, event loop, input handling
        ├── layout.rs        # Main layout: header, body, footer
        └── panels/
            ├── mod.rs
            ├── list.rs      # Workflow list panel (left)
            └── detail.rs    # Detail panel (right) with tabs
```

---

## Testing Strategy

| Phase | What to Test |
|-------|--------------|
| 1 | `flovyn workflows trigger` works against local server |
| 2 | `flovyn workflows list` shows workflows, filters work |
| 3 | `flovyn workflows get` shows correct details |
| 4 | `flovyn workflows events` shows event history |
| 5 | `flovyn workflows logs` streams events |
| 6 | `flovyn workflows cancel` stops running workflow |
| 7 | `flovyn tasks list/get` shows task info |
| 8 | OAuth login flow works end-to-end |
| 9 | TUI launches, list+detail layout renders, navigation works |
| 10 | TUI tabs work: Events loads, Logs streams, Actions executes |
| 11 | TUI trigger dialog, task view, styling, resize handling |

---

## Dependencies Summary

| Phase | New Dependencies |
|-------|------------------|
| 1 | clap, toml, dirs |
| 2 | tabled |
| 5 | reqwest-eventsource |
| 8 | oauth2, open, tiny_http |
| 9-11 | ratatui, crossterm |

---

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| SSE streaming complexity | Phase 5 uses existing server endpoint, test thoroughly |
| OAuth callback handling | Use tiny_http for simple local server |
| TUI cross-platform issues | crossterm handles platform differences |
| Config file location varies by OS | `dirs` crate handles platform-specific paths |
