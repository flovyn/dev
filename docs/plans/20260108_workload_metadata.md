# Implementation Plan: Workload Metadata

**Design Document**: [20260104_workload-metadata.md](../design/20260104_workload_metadata.md)

## Overview

Add `metadata` JSONB column to workflow and task executions, rename `labels` to `metadata` in proto/REST APIs, and add filtering support.

## TODO List

### Phase 1: Database & Domain Model

- [x] Create migration `20260108162851_add_execution_metadata.sql`
- [x] Add `metadata: Option<serde_json::Value>` to `WorkflowExecution` domain model
- [x] Add `metadata: Option<serde_json::Value>` to `TaskExecution` domain model
- [x] Update `WorkflowExecution::new()` to accept metadata parameter
- [x] Update `TaskExecution::new()` and `new_with_id()` to accept metadata parameter
- [x] Run `cargo check` to verify compilation
- [x] **Update this TODO list and document findings**

**Findings:**
- Updated 11 call sites with `None` placeholder for metadata
- Call sites span REST handlers, gRPC handlers, and service layer
- Child workflows and workflow-internal tasks get `None` metadata (future: could inherit from parent)
- Migration adds GIN index with `jsonb_path_ops` for efficient `@>` containment queries

---

### Phase 2: Repository Layer

- [x] Update `WorkflowRepository::create()` to persist metadata
- [x] Update `WorkflowRepository::create_with_executor()` to persist metadata
- [x] Update `WorkflowRepository::get()` to fetch metadata
- [x] Update `WorkflowRepository::find_lock_and_mark_running()` to fetch metadata
- [x] Update `WorkflowRepository::list_with_filters()` to fetch metadata
- [x] Update `WorkflowRepository::list_children()` to fetch metadata
- [x] Update `TaskRepository::create()` to persist metadata
- [x] Update `TaskRepository::get()` to fetch metadata
- [x] Update `TaskRepository::find_lock_and_mark_running()` to fetch metadata
- [x] Update `TaskRepository::list_by_workflow_execution_id()` to fetch metadata
- [x] Update `TaskRepository::list_standalone_tasks()` to fetch metadata
- [x] `IdempotencyKeyRepository::create_workflow_atomically()` uses `create_with_executor` - no change needed
- [x] Run `cargo check` to verify compilation
- [x] **Update this TODO list and document findings**

**Findings:**
- All SELECT and INSERT queries updated to include metadata column
- TaskRepository doesn't have `create_with_executor` - uses single `create()` method
- IdempotencyKeyRepository delegates to WorkflowRepository::create_with_executor

---

### Phase 3: Proto & gRPC Changes

- [x] Rename `labels` to `metadata` in `StartWorkflowRequest` (proto line 155)
- [x] Rename `labels` to `metadata` in `SubmitTaskRequest` (proto line 329)
- [x] Regenerate protobuf code (cargo build)
- [x] Add `proto_metadata_to_json()` helper function to convert HashMap to serde_json::Value
- [x] Update `workflow_dispatch.rs` to read metadata from request
- [x] Update `task_execution.rs` to read metadata from request
- [x] Add `metadata` field to service layer request structs:
  - `server/src/service/workflow_launcher.rs::StartWorkflowRequest`
  - `server/src/service/task_launcher.rs::StartTaskRequest`
  - `crates/core/src/launchers.rs::StartWorkflowRequest`
  - `crates/core/src/launchers.rs::StartTaskRequest`
- [x] Update callers in `plugin_adapters.rs` and `flovyn-server/eventhook/processor.rs`
- [x] Run `cargo check --features all-plugins` to verify compilation
- [x] **Update this TODO list and document findings**

**Findings:**
- Proto `map<string, string>` becomes HashMap<String, String> which we convert to JSON
- Empty metadata maps are converted to None (not stored) for efficiency
- Core crate and server have parallel request structs that both need metadata field
- Eventhook plugin gets `metadata: None` for now (future: could extract from payload)

---

### Phase 4: REST API Changes

- [x] Rename `labels` to `metadata` in `TriggerWorkflowRequest`
- [x] Add `metadata` to `CreateTaskRequest`
- [x] Add `metadata: Option<serde_json::Value>` to `WorkflowExecutionResponse`
- [x] Add `metadata: Option<serde_json::Value>` to `TaskResponse`
- [x] Update `From<&WorkflowExecution>` impl
- [x] Update `From<&TaskExecution>` impl
- [x] Update REST handlers to pass metadata to domain model creation
- [x] OpenAPI schemas auto-updated via utoipa `ToSchema` derive
- [x] Run `cargo check` to verify compilation
- [x] **Update this TODO list and document findings**

**Findings:**
- Changed `labels: HashMap<String, String>` to `metadata: Option<serde_json::Value>` for flexibility
- Added `#[serde(skip_serializing_if = "Option::is_none")]` for cleaner JSON output
- OpenAPI schemas automatically regenerated via utoipa derive macros

---

### Phase 5: Event Sourcing

- [x] Define `WorkflowStartedEventData` struct with metadata field
- [x] Update `WORKFLOW_STARTED` event creation to include metadata
- [x] Consider metadata in event replay (if needed for state reconstruction)
- [x] Run `cargo check` to verify compilation
- [x] **Update this TODO list and document findings**

**Findings:**
- Skipped creating `WorkflowStartedEventData` struct - using inline JSON with serde_json::json! macro instead
- Updated WORKFLOW_STARTED event in `workflow_dispatch.rs` to include metadata in event_data JSON
- Updated `FlovynEvent` helpers: `workflow_created`, `workflow_started`, `task_created`, `task_started`, `task_completed`, `task_failed` - all now include metadata
- Event replay not needed: metadata is stored on execution records, not reconstructed from events
- WorkflowSnapshot/TaskSnapshot (legacy SSE streaming) not updated - metadata is on the execution itself

---

### Phase 6: Filtering Support

- [x] Add `ListWorkflowsParams` with metadata filter
- [x] Add `ListTasksParams` with metadata filter
- [x] Update `WorkflowRepository::list()` to support metadata filtering
- [x] Update `TaskRepository::list()` to support metadata filtering
- [x] Implement metadata query param parsing in REST handlers
- [x] Run `cargo check` to verify compilation
- [x] **Update this TODO list and document findings**

**Findings:**
- Used JSON format for metadata filter instead of `metadata.key=value` format for simplicity: `?metadata={"customerId":"CUST-123"}`
- PostgreSQL JSONB containment operator (`@>`) provides efficient filtering using GIN index
- Updated both server REST API query types and rest-client types
- CLI commands updated to pass `metadata: None` (future: add CLI flag for metadata filtering)

---

### Phase 7: Validation & Constraints

- [x] Add validation for metadata size limit (64KB)
- [x] Add validation for key count (max 50)
- [x] Add validation for reserved prefix `_flovyn_`
- [x] Return appropriate error responses for validation failures
- [x] Run `cargo check` to verify compilation
- [x] **Update this TODO list and document findings**

**Findings:**
- Created `flovyn-server/server/src/util/metadata_validator.rs` with `validate_metadata()` function
- Validation checks: must be object, max 50 keys, max 64KB size, no `_flovyn_` prefix in keys
- REST handlers return 400 Bad Request for validation failures
- gRPC handlers return Status::invalid_argument for validation failures
- Added comprehensive unit tests for all validation cases

---

### Phase 8: Tests

- [x] Unit test: metadata validation (size, key count, reserved prefix)
- [x] Integration test: create workflow with metadata via gRPC
- [x] Integration test: create workflow with metadata via REST
- [x] Integration test: create task with metadata via gRPC (N/A - tasks via gRPC are submitted within workflows)
- [x] Integration test: create task with metadata via REST
- [x] Integration test: list workflows with metadata filter
- [x] Integration test: list tasks with metadata filter
- [x] Integration test: verify metadata persisted and returned
- [x] Integration test: workflow without metadata (None)
- [x] Integration test: validate reserved prefix rejection
- [x] Integration test: validate too many keys rejection
- [x] Run unit test suite
- [x] **Update this TODO list and document findings**

**Findings:**
- 9 unit tests for metadata validation all pass
- 259 total lib unit tests pass
- Created `flovyn-server/server/tests/integration/metadata_tests.rs` with 9 integration tests:
  - REST API tests (7):
    - `test_rest_workflow_with_metadata` - create workflow with metadata, verify retrieval
    - `test_rest_workflow_without_metadata` - create workflow without metadata, verify null
    - `test_rest_list_workflows_metadata_filter` - filter workflows by metadata
    - `test_rest_workflow_metadata_reserved_prefix_rejected` - validation of reserved prefix
    - `test_rest_task_with_metadata` - create task with metadata, verify retrieval
    - `test_rest_list_tasks_metadata_filter` - filter tasks by metadata
    - `test_rest_task_metadata_too_many_keys` - validation of key count limit
  - gRPC (SDK) tests (2):
    - `test_grpc_workflow_with_metadata` - create workflow with metadata via SDK, verify via REST
    - `test_grpc_workflow_without_metadata` - verify null metadata when not provided via SDK
- Added metadata field to rest-client types: `TriggerWorkflowRequest`, `CreateTaskRequest`, `WorkflowExecutionResponse`, `TaskResponse`
- Fixed JSON query param parsing: added `deserialize_json_query` helper in `flovyn-server/server/src/util/json_query.rs` to deserialize JSON strings from URL query parameters
- Updated existing integration tests to include `metadata: None` in request structs
- All 9 metadata integration tests pass
- Pre-existing compilation errors in eventhook integration tests (unrelated to metadata)

---

### Phase 9: SDK Support

- [x] Rename `labels` to `metadata` in proto/flovyn.proto (StartWorkflowRequest, SubmitTaskRequest)
- [x] Update core/src/client/workflow_dispatch.rs to pass metadata
- [x] Update core/src/client/task_execution.rs to pass metadata
- [x] Update sdk/src/client/flovyn_client.rs:
  - [x] Rename `labels` to `metadata` in `StartWorkflowOptions`
  - [x] Update `with_metadata()` to accept `IntoIterator` for ergonomic array syntax
  - [x] Add `with_metadata_entry(key, value)` for chaining individual entries
  - [x] Update `start_workflow_with_options()` to pass metadata
- [x] Update ffi/src/client.rs to pass None for metadata
- [x] Run `cargo check` to verify compilation
- [x] Run `cargo test` in sdk-rust
- [x] **Update this TODO list and document findings**

**Findings:**
- Proto `map<string, string> metadata` generates `HashMap<String, String>` in Rust
- SDK uses `StartWorkflowOptions.metadata: HashMap<String, String>` (was `labels`)
- Core client methods now take `metadata: Option<HashMap<String, String>>`
- FFI layer passes `None` for metadata (future: expose via FFI interface)
- Ergonomic API: `with_metadata([("k", "v")])` and `with_metadata_entry("k", "v")` chaining
- 202 core tests pass, 345 SDK lib tests pass

---

## Implementation Notes

### Migration SQL

```sql
-- File: server/migrations/YYYYMMDDHHMMSS_add_execution_metadata.sql
ALTER TABLE workflow_execution ADD COLUMN metadata JSONB;
ALTER TABLE task_execution ADD COLUMN metadata JSONB;

-- GIN indexes for efficient containment queries (@>)
CREATE INDEX idx_workflow_execution_metadata ON workflow_execution USING GIN (metadata jsonb_path_ops);
CREATE INDEX idx_task_execution_metadata ON task_execution USING GIN (metadata jsonb_path_ops);
```

### Domain Model Changes

```rust
// crates/core/src/domain/workflow.rs
pub struct WorkflowExecution {
    // ... existing fields
    pub metadata: Option<serde_json::Value>,
}

// crates/core/src/domain/task.rs
pub struct TaskExecution {
    // ... existing fields
    pub metadata: Option<serde_json::Value>,
}
```

### Filtering Query Pattern

```sql
-- Filter by single key
SELECT * FROM workflow_execution
WHERE tenant_id = $1
  AND metadata @> '{"customerId": "CUST-123"}'::jsonb;

-- Filter by multiple keys (AND)
SELECT * FROM workflow_execution
WHERE tenant_id = $1
  AND metadata @> '{"customerId": "CUST-123", "region": "us-east"}'::jsonb;
```

### REST Query Param Format

Uses JSON format for metadata filter (simpler than dot notation):

```
GET /api/tenants/{tenant}/workflows?metadata={"customerId":"CUST-123"}
GET /api/tenants/{tenant}/workflows?metadata={"customerId":"CUST-123","region":"us-east"}
```

Note: URL-encode the JSON in practice: `?metadata=%7B%22customerId%22%3A%22CUST-123%22%7D`

### Validation Constants

```rust
const MAX_METADATA_SIZE_BYTES: usize = 65536; // 64KB
const MAX_METADATA_KEYS: usize = 50;
const RESERVED_PREFIX: &str = "_flovyn_";
```

### SDK Usage

```rust
// Option 1: Array literal (recommended for static metadata)
let options = StartWorkflowOptions::new()
    .with_metadata([("customerId", "CUST-123"), ("region", "us-east")]);

client.start_workflow_with_options("my-workflow", input, options).await?;

// Option 2: Chaining individual entries
let options = StartWorkflowOptions::new()
    .with_metadata_entry("customerId", "CUST-123")
    .with_metadata_entry("region", "us-east");

// Option 3: From HashMap (for dynamic metadata)
let metadata: HashMap<String, String> = get_metadata_from_somewhere();
let options = StartWorkflowOptions::new().with_metadata(metadata);
```

### Backward Compatibility

- Existing executions will have `metadata = NULL`
- Nullable column ensures zero storage overhead for empty metadata
- No breaking changes to existing API consumers (metadata is optional)
- SDK `with_labels()` renamed to `with_metadata()` (breaking change for SDK users)
