# Implementation Plan: Workload Discovery

**Design Document**: [workload-discovery.md](../design/workload-discovery.md)

## Overview

Implement workload discovery to enable listing and inspecting registered workers, workflow definitions, and task definitions. This provides operational visibility and enables the CLI to browse available workloads before triggering them.

**Status**: Completed (Phases 1-16)

---

## TODO List

### Phase 1: Database Migration

- [x] **1.1** Create migration file `flovyn-server/server/migrations/YYYYMMDD_workload_discovery.sql`
  - Drop existing `worker_task_capability` table
  - Drop existing `worker_workflow_capability` table
  - Drop existing `worker` table
  - Create new `worker` table with `space_id`, `status`, `registered_at` columns
  - Create `workflow_definition` table with all fields from design doc
  - Create `task_definition` table with all fields from design doc
  - Create new `worker_workflow_capability` join table with FK to `workflow_definition`
  - Create new `worker_task_capability` join table with FK to `task_definition`
  - Add all indexes specified in design doc

### Phase 2: Domain Types

- [x] **2.1** Create `flovyn-server/server/src/domain/workflow_definition.rs`
  - Add `WorkflowDefinition` struct with all fields from design doc
  - Add `AvailabilityStatus` enum: `Available`, `Unavailable`, `Degraded`
  - Add `WorkflowDefinitionWithWorkers` aggregate type
  - Add `WorkerSummary` struct for embedded worker info

- [x] **2.2** Create `flovyn-server/server/src/domain/task_definition.rs`
  - Add `TaskDefinition` struct with all fields from design doc
  - Add `TaskDefinitionWithWorkers` aggregate type

- [x] **2.3** Update `flovyn-server/server/src/domain/worker.rs`
  - Add `WorkerStatus` enum: `Online`, `Offline`, `Degraded`
  - Add `status()` method that derives status from `last_heartbeat_at`
  - Add `WorkerWithCapabilities` aggregate type
  - Update `Worker` struct to include `space_id` and `registered_at`

- [x] **2.4** Create `flovyn-server/server/src/domain/discovery.rs` for query params
  - Add `ListDefinitionsParams` struct
  - Add `ListWorkersParams` struct

- [x] **2.5** Update `flovyn-server/server/src/domain/mod.rs`
  - Export new modules: `workflow_definition`, `task_definition`, `discovery`

### Phase 3: Workflow Definition Repository

- [x] **3.1** Create `flovyn-server/server/src/repository/workflow_definition_repository.rs`
  - Implement `upsert()` - find or create definition during registration
  - Implement `get()` - get by ID
  - Implement `find_by_kind()` - find by tenant/space/kind
  - Implement `list()` - list all definitions for tenant with pagination
  - Implement `update_availability()` - update availability status
  - Implement `touch_registration()` - update `last_registered_at`

- [x] **3.2** Add `get_with_workers()` method
  - Join with `worker_workflow_capability` and `worker` tables
  - Return `WorkflowDefinitionWithWorkers` with worker list

- [x] **3.3** Update `flovyn-server/server/src/repository/mod.rs`
  - Export `WorkflowDefinitionRepository`

### Phase 4: Task Definition Repository

- [x] **4.1** Create `flovyn-server/server/src/repository/task_definition_repository.rs`
  - Implement `upsert()` - find or create definition during registration
  - Implement `get()` - get by ID
  - Implement `find_by_kind()` - find by tenant/space/kind
  - Implement `list()` - list all definitions for tenant with pagination
  - Implement `update_availability()` - update availability status
  - Implement `touch_registration()` - update `last_registered_at`

- [x] **4.2** Add `get_with_workers()` method
  - Join with `worker_task_capability` and `worker` tables
  - Return `TaskDefinitionWithWorkers` with worker list

- [x] **4.3** Update `flovyn-server/server/src/repository/mod.rs`
  - Export `TaskDefinitionRepository`

### Phase 5: Worker Repository Extensions

- [x] **5.1** Update `WorkerRepository` with new schema columns
  - Update `upsert()` to handle `space_id`, `status`, `registered_at`
  - Update `find_by_name()` and `get()` queries for new columns

- [x] **5.2** Add `list()` method
  - Parameters: `tenant_id`, `ListWorkersParams`
  - Return paginated list of workers

- [x] **5.3** Add `get_with_capabilities()` method
  - Join with capability tables and definition tables
  - Return `WorkerWithCapabilities` with full definition objects

- [x] **5.4** Add `find_for_workflow_definition()` method
  - Find all workers that support a given workflow definition

- [x] **5.5** Add `find_for_task_definition()` method
  - Find all workers that support a given task definition

- [x] **5.6** Update capability methods for normalized schema
  - Update `add_workflow_capability()` to take `definition_id` instead of kind
  - Update `add_task_capability()` to take `definition_id` instead of kind

- [x] **5.7** Add `find_stale_workers()` method
  - Find workers with heartbeat older than threshold

- [x] **5.8** Add `mark_offline()` method
  - Update worker status to OFFLINE

### Phase 6: Registration Flow Update

- [x] **6.1** Update `flovyn-server/server/src/api/grpc/worker_lifecycle.rs` - `register_worker()`
  - For each workflow capability:
    - Call `WorkflowDefinitionRepository::upsert()` to create/find definition
    - Call `WorkerRepository::add_workflow_capability()` with definition ID
    - Update `last_registered_at` on definition
  - For each task capability:
    - Call `TaskDefinitionRepository::upsert()` to create/find definition
    - Call `WorkerRepository::add_task_capability()` with definition ID
    - Update `last_registered_at` on definition

- [x] **6.2** Update `send_heartbeat()` to update worker status
  - Set worker status to ONLINE on successful heartbeat

- [x] **6.3** Add `WorkflowDefinitionRepository` and `TaskDefinitionRepository` to `AppState`
  - Initialize in `main.rs`
  - Pass to gRPC service handlers

### Phase 7: REST API - Worker Discovery

- [x] **7.1** Create `flovyn-server/server/src/api/rest/workers.rs`
  - Add module to `flovyn-server/server/src/api/rest/mod.rs`

- [x] **7.2** Implement `GET /api/tenants/{tenant_slug}/workers` handler
  - Parse query params: `limit`, `offset`, `type` (WORKFLOW/TASK/UNIFIED)
  - Call `WorkerRepository::list()`
  - Return `Vec<WorkerResponse>`

- [x] **7.3** Create `WorkerResponse` DTO
  - Fields: `id`, `name`, `type`, `status`, `version`, `host_name`, `last_heartbeat_at`, `registered_at`
  - Use `WorkerStatus` enum for type-safe status

- [x] **7.4** Implement `GET /api/tenants/{tenant_slug}/workers/{worker_id}` handler
  - Call `WorkerRepository::get_with_capabilities()`
  - Return `WorkerWithCapabilitiesResponse`

- [x] **7.5** Create `WorkerWithCapabilitiesResponse` DTO
  - Fields: `worker`, `workflow_capabilities`, `task_capabilities`
  - Include full definition objects (kind, name, description)

- [x] **7.6** Add OpenAPI annotations and register routes

### Phase 8: REST API - Workflow Definition Discovery

- [x] **8.1** Create `flovyn-server/server/src/api/rest/workflow_definitions.rs`
  - Add module to `flovyn-server/server/src/api/rest/mod.rs`

- [x] **8.2** Implement `GET /api/tenants/{tenant_slug}/workflow-definitions` handler
  - Parse query params: `limit`, `offset`, `availability_status`
  - Call `WorkflowDefinitionRepository::list()`
  - Return `Vec<WorkflowDefinitionResponse>`

- [x] **8.3** Create `WorkflowDefinitionResponse` DTO
  - Fields: all definition fields + `worker_count`
  - Compute `worker_count` from joined data or separate query

- [x] **8.4** Implement `GET /api/tenants/{tenant_slug}/workflow-definitions/{kind}` handler
  - Call `WorkflowDefinitionRepository::find_by_kind()`
  - Return `WorkflowDefinitionResponse`

- [x] **8.5** Add OpenAPI annotations and register routes

### Phase 9: REST API - Task Definition Discovery

- [x] **9.1** Create `flovyn-server/server/src/api/rest/task_definitions.rs`
  - Add module to `flovyn-server/server/src/api/rest/mod.rs`

- [x] **9.2** Implement `GET /api/tenants/{tenant_slug}/task-definitions` handler
  - Parse query params: `limit`, `offset`, `availability_status`
  - Call `TaskDefinitionRepository::list()`
  - Return `Vec<TaskDefinitionResponse>`

- [x] **9.3** Create `TaskDefinitionResponse` DTO
  - Fields: all definition fields + `worker_count`

- [x] **9.4** Implement `GET /api/tenants/{tenant_slug}/task-definitions/{kind}` handler
  - Call `TaskDefinitionRepository::find_by_kind()`
  - Return `TaskDefinitionResponse`

- [x] **9.5** Add OpenAPI annotations and register routes

### Phase 10: REST Client Updates

- [x] **10.1** Add worker discovery types to `flovyn-server/crates/rest-client/src/types.rs`
  - `WorkerResponse`
  - `WorkerWithCapabilitiesResponse`
  - `ListWorkersParams`

- [x] **10.2** Add workflow definition types to `flovyn-server/crates/rest-client/src/types.rs`
  - `WorkflowDefinitionResponse`

- [x] **10.3** Add task definition types to `flovyn-server/crates/rest-client/src/types.rs`
  - `TaskDefinitionResponse`

- [x] **10.4** Add worker methods to `FlovynClient` in `flovyn-server/crates/rest-client/src/client.rs`
  - `list_workers(tenant, params)` - GET `/api/tenants/{tenant}/workers`
  - `get_worker(tenant, worker_id)` - GET `/api/tenants/{tenant}/workers/{worker_id}`

- [x] **10.5** Add workflow definition methods to `FlovynClient`
  - `list_workflow_definitions(tenant)` - GET `/api/tenants/{tenant}/workflow-definitions`
  - `get_workflow_definition(tenant, kind)` - GET `/api/tenants/{tenant}/workflow-definitions/{kind}`

- [x] **10.6** Add task definition methods to `FlovynClient`
  - `list_task_definitions(tenant)` - GET `/api/tenants/{tenant}/task-definitions`
  - `get_task_definition(tenant, kind)` - GET `/api/tenants/{tenant}/task-definitions/{kind}`

### Phase 11: CLI - Worker Commands

- [x] **11.1** Create `flovyn-server/cli/src/commands/workers.rs`
  - Add module to `flovyn-server/cli/src/commands/mod.rs`

- [x] **11.2** Define `WorkersCommand` enum
  ```rust
  pub enum WorkersCommand {
      /// List all workers
      List {
          #[arg(long)]
          worker_type: Option<String>,  // WORKFLOW, TASK, UNIFIED
          #[arg(long, default_value = "50")]
          limit: i64,
          #[arg(long, default_value = "0")]
          offset: i64,
      },
      /// Get worker details
      Get { worker_id: Uuid },
  }
  ```

- [x] **11.3** Implement `WorkersCommand::execute()` method
  - Match on each variant
  - Call appropriate `FlovynClient` method
  - Output results via `Outputter`

- [x] **11.4** Add output methods to `Outputter` in `flovyn-server/cli/src/output.rs`
  - `worker_list()` - table with ID, name, type, status, last heartbeat
  - `worker_get()` - detailed view with capabilities

- [x] **11.5** Register `Workers` command in `flovyn-server/cli/src/main.rs`
  - Add to `Commands` enum with alias `worker`
  - Add match arm in `run()` function

### Phase 12: CLI - Workflow Definition Commands

- [x] **12.1** Update `flovyn-server/cli/src/commands/workflows.rs`
  - Add `Definitions` subcommand to `WorkflowsCommand`
  - Add optional `kind` argument for single definition lookup

- [x] **12.2** Implement definition subcommands
  - `flovyn workflows definitions` - list all workflow definitions
  - `flovyn workflows definitions <kind>` - get specific definition

- [x] **12.3** Add output methods to `Outputter`
  - `workflow_definitions_list()` - table with kind, name, status, worker count
  - `workflow_definition_get()` - detailed view

### Phase 13: CLI - Task Definition Commands

- [x] **13.1** Update `flovyn-server/cli/src/commands/tasks.rs`
  - Add `Definitions` subcommand to `TasksCommand`
  - Add optional `kind` argument for single definition lookup

- [x] **13.2** Implement definition subcommands
  - `flovyn tasks definitions` - list all task definitions
  - `flovyn tasks definitions <kind>` - get specific definition

- [x] **13.3** Add output methods to `Outputter`
  - `task_definitions_list()` - table with kind, name, status, worker count
  - `task_definition_get()` - detailed view

### Phase 14: Integration Tests - Server

- [x] **14.1** Test full registration-to-discovery flow (E2E)
  - `test_worker_registration_creates_definitions`:
    1. Register worker via gRPC with workflow capabilities (`order-processing`, `payment-flow`)
    2. Register same worker with task capabilities (`send-email`, `process-payment`)
    3. Query `GET /workflow-definitions` - verify both workflow definitions exist
    4. Query `GET /task-definitions` - verify both task definitions exist
    5. Query `GET /workers` - verify worker is listed with ONLINE status
    6. Query `GET /workers/{id}` - verify capabilities are linked correctly
  - `test_multiple_workers_same_definition`:
    1. Register worker-1 with workflow capability `order-processing`
    2. Register worker-2 with workflow capability `order-processing`
    3. Query `GET /workflow-definitions/order-processing` - verify worker_count = 2
    4. Query definition detail - verify both workers are listed
  - `test_worker_heartbeat_updates_status`:
    1. Register worker via gRPC
    2. Query `GET /workers` - verify status is ONLINE
    3. Wait for heartbeat timeout (or mock time)
    4. Query `GET /workers` - verify status is OFFLINE

- [x] **14.2** Test worker discovery endpoints
  - `test_rest_list_workers_empty`
  - `test_rest_list_workers_with_results`
  - `test_rest_list_workers_type_filter`
  - `test_rest_get_worker_with_capabilities`
  - `test_rest_get_worker_not_found`

- [x] **14.3** Test workflow definition discovery endpoints
  - `test_rest_list_workflow_definitions_empty`
  - `test_rest_list_workflow_definitions_with_results`
  - `test_rest_get_workflow_definition`
  - `test_rest_get_workflow_definition_not_found`

- [x] **14.4** Test task definition discovery endpoints
  - `test_rest_list_task_definitions_empty`
  - `test_rest_list_task_definitions_with_results`
  - `test_rest_get_task_definition`
  - `test_rest_get_task_definition_not_found`

- [x] **14.5** Test definition metadata from registration
  - `test_definition_metadata_from_capability`:
    1. Register worker with workflow capability including metadata (name, description, timeout, tags)
    2. Query `GET /workflow-definitions/{kind}`
    3. Verify name, description, timeout_seconds, tags match registration
  - `test_task_definition_with_schemas`:
    1. Register worker with task capability including input_schema, output_schema
    2. Query `GET /task-definitions/{kind}`
    3. Verify schemas are stored and returned correctly

### Phase 15: TUI - Worker View

- [x] **15.1** Add `ViewMode::Workers` to TUI app state
  - Keybinding: `W` (uppercase) for workers view
  - Update view mode indicator in header

- [x] **15.2** Add worker state to `App` struct
  - `workers: Vec<WorkerSummary>` - list of workers
  - `selected_worker_index: usize`
  - `selected_worker: Option<WorkerWithCapabilitiesResponse>` - detailed worker info

- [x] **15.3** Add `WorkerDetailTab` enum
  - `Overview` - worker details (name, type, status, host, heartbeat)
  - `Capabilities` - workflow and task capability lists

- [x] **15.4** Add background loaders for workers
  - `spawn_load_workers()` - fetch worker list
  - `spawn_load_worker_detail()` - fetch single worker details with capabilities

- [x] **15.5** Add `AppMessage` variants for workers
  - `WorkersLoaded(Result<Vec<WorkerSummary>, String>)`
  - `WorkerDetailLoaded(Box<Result<WorkerWithCapabilitiesResponse, String>>)`

- [x] **15.6** Create `flovyn-server/cli/src/tui/panels/worker_list.rs`
  - Display worker list with status indicators
  - Color coding: green for ONLINE, yellow for DEGRADED, red for OFFLINE
  - Show worker type icon/label

- [x] **15.7** Create `flovyn-server/cli/src/tui/panels/worker_detail.rs`
  - Overview tab: worker details, timestamps, metadata
  - Capabilities tab: lists of workflow and task definitions

- [x] **15.8** Update `flovyn-server/cli/src/tui/panels/mod.rs`
  - Export `worker_list` and `worker_detail` modules

- [x] **15.9** Update `flovyn-server/cli/src/tui/layout.rs` to support worker views
  - Render worker list when `ViewMode::Workers`
  - Render worker detail panels based on `WorkerDetailTab`

- [x] **15.10** Add keyboard shortcuts for worker view
  - Update help overlay with worker-specific bindings
  - `W` to switch to workers view, `w` for workflows, `t` for tasks

### Phase 16: TUI - Definition Views

- [x] **16.1** Add definition browsing to workflow/task views
  - Add keybinding `d` to toggle between executions and definitions
  - `is_definition_mode: bool` flag in app state

- [x] **16.2** Create `flovyn-server/cli/src/tui/panels/workflow_definition_list.rs`
  - Display workflow definitions with availability status
  - Show worker count, latest version

- [x] **16.3** Create `flovyn-server/cli/src/tui/panels/task_definition_list.rs`
  - Display task definitions with availability status
  - Show worker count

- [x] **16.4** Add background loaders for definitions
  - `spawn_load_workflow_definitions()` - fetch workflow definition list
  - `spawn_load_task_definitions()` - fetch task definition list

- [x] **16.5** Update layout to render definition lists
  - When in definition mode, show definitions instead of executions
  - Detail panel shows definition info with worker list

### Phase 17: Availability Monitoring (Optional)

- [x] **17.1** Create background job for stale worker detection
  - Periodically check `find_stale_workers()` (e.g., every 30s)
  - Mark stale workers as OFFLINE

- [x] **17.2** Update definition availability on worker status change
  - When all workers for a definition go offline, mark definition UNAVAILABLE
  - When a worker comes online, mark supported definitions AVAILABLE

---

## File Changes Summary

### Server (`server/`)

| File | Changes |
|------|---------|
| `flovyn-server/migrations/YYYYMMDD_workload_discovery.sql` | Drop/recreate worker tables, add definition tables |
| `flovyn-server/src/domain/mod.rs` | Export new modules |
| `flovyn-server/src/domain/workflow_definition.rs` | New: `WorkflowDefinition`, `AvailabilityStatus` |
| `flovyn-server/src/domain/task_definition.rs` | New: `TaskDefinition` |
| `flovyn-server/src/domain/worker.rs` | Add `WorkerStatus`, update `Worker` struct |
| `flovyn-server/src/domain/discovery.rs` | New: query param structs |
| `flovyn-server/src/repository/mod.rs` | Export new repositories |
| `flovyn-server/src/repository/workflow_definition_repository.rs` | New: workflow definition CRUD |
| `flovyn-server/src/repository/task_definition_repository.rs` | New: task definition CRUD |
| `flovyn-server/src/repository/worker_repository.rs` | Add discovery methods, update for new schema |
| `flovyn-server/src/api/rest/mod.rs` | Register new routes |
| `flovyn-server/src/api/rest/workers.rs` | New: worker discovery endpoints |
| `flovyn-server/src/api/rest/workflow_definitions.rs` | New: workflow definition discovery endpoints |
| `flovyn-server/src/api/rest/task_definitions.rs` | New: task definition discovery endpoints |
| `flovyn-server/src/api/grpc/worker_lifecycle.rs` | Update registration to create definitions |

### REST Client (`crates/rest-client/`)

| File | Changes |
|------|---------|
| `flovyn-server/src/types.rs` | Add worker, workflow definition, task definition types |
| `flovyn-server/src/client.rs` | Add discovery client methods |

### CLI (`cli/`)

| File | Changes |
|------|---------|
| `flovyn-server/src/commands/mod.rs` | Export `workers` module |
| `flovyn-server/src/commands/workers.rs` | New: `WorkersCommand` enum and handlers |
| `flovyn-server/src/commands/workflows.rs` | Add `Definitions` subcommand |
| `flovyn-server/src/commands/tasks.rs` | Add `Definitions` subcommand |
| `flovyn-server/src/main.rs` | Register `Workers` command |
| `flovyn-server/src/output.rs` | Add discovery output methods |
| `flovyn-server/src/tui/app.rs` | Add `ViewMode::Workers`, worker state, definition mode |
| `flovyn-server/src/tui/layout.rs` | Support worker and definition views |
| `flovyn-server/src/tui/panels/mod.rs` | Export worker and definition panels |
| `flovyn-server/src/tui/panels/worker_list.rs` | New: worker list panel |
| `flovyn-server/src/tui/panels/worker_detail.rs` | New: worker detail panel |
| `flovyn-server/src/tui/panels/workflow_definition_list.rs` | New: workflow definition list panel |
| `flovyn-server/src/tui/panels/task_definition_list.rs` | New: task definition list panel |

---

## Dependencies

```
Phase 1 (Migration) → Phase 2 (Domain) → Phase 3-5 (Repositories) → Phase 6 (Registration)
                                                                            ↓
                                                                   Phase 7-9 (REST API)
                                                                            ↓
                                                                   Phase 10 (REST Client)
                                                                            ↓
                                                                   Phase 11-13 (CLI Commands)
                                                                            ↓
                                                                   Phase 14 (Tests)
                                                                            ↓
                                                                   Phase 15-16 (TUI)

Phase 17 (Availability Monitoring) is optional and can be done after Phase 16.
```

---

## Notes

- **Schema Migration**: The migration drops and recreates worker-related tables. No data migration is needed since this is MVP and no production data exists.

- **Capability Metadata**: The design document mentions rich capability metadata (description, timeout, tags) from gRPC registration. This metadata should be extracted from the protobuf `WorkflowCapability` and `TaskCapability` messages during registration.

- **Space Support**: `space_id` is included in the schema but can be `NULL` initially. Full space support is deferred.

- **Availability Monitoring (Phase 17)**: This is marked optional because the system works without automatic availability updates. Workers are simply marked ONLINE/OFFLINE based on heartbeat status.

---

## CLI Usage Examples

```bash
# List all workers
flovyn workers list
flovyn workers list --type WORKFLOW
flovyn workers list --type TASK --limit 10

# Get worker details
flovyn workers get 550e8400-e29b-41d4-a716-446655440001

# List workflow definitions
flovyn workflows definitions

# Get specific workflow definition
flovyn workflows definitions order-processing

# List task definitions
flovyn tasks definitions

# Get specific task definition
flovyn tasks definitions send-email

# JSON output for scripting
flovyn workers list --output json | jq '.[] | select(.status == "OFFLINE")'
flovyn workflows definitions --output json
```

---

## Example Output

### `flovyn workers list`

```
WORKER ID                             NAME              TYPE     STATUS   LAST HEARTBEAT
550e8400-e29b-41d4-a716-446655440001  order-worker      UNIFIED  ONLINE   2s ago
550e8400-e29b-41d4-a716-446655440002  notification-svc  TASK     ONLINE   15s ago
550e8400-e29b-41d4-a716-446655440003  batch-processor   WORKFLOW OFFLINE  5m ago
```

### `flovyn workflows definitions`

```
KIND                  NAME                  STATUS       WORKERS  VERSIONS
order-processing      Order Processing      AVAILABLE    2        1.0.0, 1.1.0
user-onboarding       User Onboarding       AVAILABLE    1        2.0.0
payment-reconcile     Payment Reconcile     UNAVAILABLE  0        1.0.0
```

### `flovyn tasks definitions`

```
KIND                  NAME                  STATUS       WORKERS
send-email            Send Email            AVAILABLE    2
process-image         Process Image         AVAILABLE    1
generate-report       Generate Report       UNAVAILABLE  0
```

---

## TUI Usage

Launch the dashboard and navigate between views:

```bash
# Launch dashboard (default: workflows view)
flovyn dashboard

# Keyboard shortcuts in TUI:
# w         - Switch to Workflows view (executions)
# t         - Switch to Tasks view (executions)
# W         - Switch to Workers view
# d         - Toggle between executions and definitions (in workflows/tasks view)
# j/k       - Navigate up/down in list
# Enter     - View details
# Tab       - Switch tabs in detail panel
# /         - Filter list
# r         - Refresh
# ?         - Show help
# q         - Quit
```

### Workers View

```
┌─────────────────────────────────────────────────────────────────────┐
│ Flovyn - tenant: acme                    [w]Workflows [t]Tasks [W]Workers │
├──────────────────────────┬──────────────────────────────────────────┤
│ Workers                  │ Worker Detail                            │
│ ─────────────────────────│ ──────────────────────────────────────── │
│ ▶ order-worker    ONLINE │ [Overview] [Capabilities]                │
│   notification    ONLINE │ ──────────────────────────────────────── │
│   batch-proc     OFFLINE │ Name:     order-worker                   │
│                          │ Type:     UNIFIED                        │
│                          │ Status:   ● ONLINE                       │
│                          │ Host:     worker-1.local                 │
│                          │ Heartbeat: 2s ago                        │
│                          │                                          │
├──────────────────────────┴──────────────────────────────────────────┤
│ j/k: navigate  Tab: switch tab  w: workflows  t: tasks  ?: help     │
└─────────────────────────────────────────────────────────────────────┘
```

### Definitions View (toggle with `d`)

```
┌─────────────────────────────────────────────────────────────────────┐
│ Flovyn - tenant: acme                              [Definitions]     │
├──────────────────────────┬──────────────────────────────────────────┤
│ Workflow Definitions     │ Definition Detail                        │
│ ─────────────────────────│ ──────────────────────────────────────── │
│ ▶ order-processing  AVAIL│ Kind:        order-processing            │
│   user-onboarding   AVAIL│ Name:        Order Processing            │
│   payment-reconcile UNAV │ Status:      ● AVAILABLE                 │
│                          │ Workers:     2                           │
│                          │ Versions:    1.0.0, 1.1.0                │
│                          │                                          │
│                          │ Workers:                                 │
│                          │   - order-worker (ONLINE)                │
│                          │   - batch-processor (OFFLINE)            │
├──────────────────────────┴──────────────────────────────────────────┤
│ d: executions  j/k: navigate  Tab: switch tab  ?: help              │
└─────────────────────────────────────────────────────────────────────┘
```
