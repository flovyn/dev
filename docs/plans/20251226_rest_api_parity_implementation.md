# Implementation Plan: REST API Parity

**Design Document**: [20251226_rest-api-parity.md](../design/20251226_rest_api_parity.md)

## Overview

Implement remaining REST API endpoints to achieve parity with the Kotlin server. This plan covers 5 endpoints across 3 phases, following the established pattern: Server → REST Client → Integration Tests → CLI.

**Status**: All Phases Complete (1-5)

---

## TODO List

### Phase 1: Workflow Retry (Core Operations) ✅

#### 1.1 Server - Repository Layer

- [x] **1.1.1** Add `retry_workflow()` method to `WorkflowRepository`
  - Parameters: `workflow_id: Uuid`, `note: Option<String>`
  - Validate workflow is in FAILED state (return error if not)
  - Reset state to PENDING
  - Clear `error` field
  - Update `updated_at`
  - Return updated workflow

- [x] **1.1.2** Add `RETRY_REQUESTED` event type to `EventRepository`
  - Create event with payload containing note and previous error
  - Append to workflow event log

#### 1.2 Server - REST Handler

- [x] **1.2.1** Create `RetryWorkflowRequest` DTO in `flovyn-server/api/rest/workflows.rs`
  ```rust
  #[derive(Debug, Deserialize, ToSchema)]
  #[serde(rename_all = "camelCase")]
  pub struct RetryWorkflowRequest {
      #[serde(default)]
      pub note: Option<String>,
  }
  ```

- [x] **1.2.2** Create `RetryWorkflowResponse` DTO
  ```rust
  #[derive(Debug, Serialize, ToSchema)]
  #[serde(rename_all = "camelCase")]
  pub struct RetryWorkflowResponse {
      pub workflow_execution_id: Uuid,
      pub status: String,
      pub message: String,
      pub success: bool,
  }
  ```

- [x] **1.2.3** Implement `POST /api/tenants/{tenant_slug}/workflow-executions/{workflow_id}/retry` handler
  - Resolve tenant from slug
  - Verify workflow belongs to tenant
  - Authorize: `state.authorize(principal).update("Workflow", ...)`
  - Call `workflow_repo.retry_workflow()`
  - Record `RETRY_REQUESTED` event
  - Notify workers: `state.notifier.notify_work_available()`
  - Return `RetryWorkflowResponse` with 200 OK

- [x] **1.2.4** Register route in `flovyn-server/api/rest/mod.rs`
  - Add to authenticated routes under workflow routes

- [x] **1.2.5** Add OpenAPI annotations
  - Document request/response schemas
  - Add to Workflows tag

#### 1.3 REST Client

- [x] **1.3.1** Add `RetryWorkflowRequest` to `flovyn-server/crates/rest-client/src/types.rs`
  - Match server DTO structure

- [x] **1.3.2** Add `RetryWorkflowResponse` to `flovyn-server/crates/rest-client/src/types.rs`

- [x] **1.3.3** Add `retry_workflow()` method to `FlovynClient`
  - `retry_workflow(tenant: &str, workflow_id: Uuid, request: RetryWorkflowRequest) -> Result<RetryWorkflowResponse, ClientError>`

#### 1.4 Integration Tests

- [x] **1.4.1** Test `test_rest_retry_workflow_success`
  - Create workflow
  - Complete it with FAILED state (via worker)
  - Call retry endpoint
  - Verify status is PENDING
  - Verify event log contains RETRY_REQUESTED

- [x] **1.4.2** Test `test_rest_retry_workflow_invalid_state`
  - Create workflow
  - Complete it with COMPLETED state
  - Call retry endpoint
  - Expect 400 Bad Request

- [x] **1.4.3** Test `test_rest_retry_workflow_not_found`
  - Call retry with non-existent workflow ID
  - Expect 404 Not Found

#### 1.5 CLI Command

- [x] **1.5.1** Add `Retry` subcommand to `WorkflowsCommand` in `flovyn-server/cli/src/commands/workflows.rs`
  ```rust
  /// Retry a failed workflow
  Retry {
      workflow_id: Uuid,
      #[arg(long)]
      note: Option<String>,
  },
  ```

- [x] **1.5.2** Implement `Retry` handler
  - Call `client.retry_workflow()`
  - Display result via `Outputter`

- [x] **1.5.3** Add output method to `Outputter` in `flovyn-server/cli/src/output.rs`
  - `workflow_retried()` - show retry confirmation

---

### Phase 2: Workflow Children (Debugging) ✅

#### 2.1 Server - Repository Layer

- [x] **2.1.1** Add `list_children()` method to `WorkflowRepository`
  - Parameters: `parent_workflow_execution_id: Uuid`
  - Query `workflow_execution WHERE parent_workflow_execution_id = $1`
  - Return `Vec<WorkflowExecution>`

#### 2.2 Server - REST Handler

- [x] **2.2.1** Create `ChildWorkflowResponse` DTO in `flovyn-server/api/rest/workflows.rs`
  ```rust
  #[derive(Debug, Serialize, ToSchema)]
  #[serde(rename_all = "camelCase")]
  pub struct ChildWorkflowResponse {
      pub child_workflow_execution_id: Uuid,
      pub kind: String,
      pub status: String,
      pub created_at: String,
  }
  ```

- [x] **2.2.2** Create `ListChildrenResponse` DTO
  ```rust
  #[derive(Debug, Serialize, ToSchema)]
  #[serde(rename_all = "camelCase")]
  pub struct ListChildrenResponse {
      pub children: Vec<ChildWorkflowResponse>,
  }
  ```

- [x] **2.2.3** Implement `GET /api/tenants/{tenant_slug}/workflow-executions/{workflow_id}/children` handler
  - Resolve tenant from slug
  - Verify parent workflow belongs to tenant
  - Authorize: `state.authorize(principal).view("Workflow", ...)`
  - Call `workflow_repo.list_children()`
  - Map to `ChildWorkflowResponse`
  - Return `ListChildrenResponse`

- [x] **2.2.4** Register route and add OpenAPI annotations

#### 2.3 REST Client

- [x] **2.3.1** Add `ChildWorkflowResponse` and `ListChildrenResponse` to `types.rs`

- [x] **2.3.2** Add `list_workflow_children()` method to `FlovynClient`
  - `list_workflow_children(tenant: &str, workflow_id: Uuid) -> Result<ListChildrenResponse, ClientError>`

#### 2.4 Integration Tests

- [x] **2.4.1** Test `test_rest_list_workflow_children_empty`
  - Create parent workflow with no children
  - Call children endpoint
  - Expect empty list

- [x] **2.4.2** Test `test_rest_list_workflow_children_with_results`
  - Create parent workflow
  - Start child workflows via gRPC (ScheduleChildWorkflow command)
  - Call children endpoint
  - Verify all children returned with correct status

- [x] **2.4.3** Test `test_rest_list_workflow_children_not_found`
  - Call with non-existent workflow ID
  - Expect 404 Not Found

#### 2.5 CLI Command

- [x] **2.5.1** Add `Children` subcommand to `WorkflowsCommand`
  ```rust
  /// List child workflows
  Children { workflow_id: Uuid },
  ```

- [x] **2.5.2** Implement handler and output formatting
  - Table with columns: ID, Kind, Status, Created At

---

### Phase 3: Workflow Task Attempts (Debugging) ✅

#### 3.1 Server - Repository Layer

- [x] **3.1.1** Verify existing `TaskAttemptRepository::list_by_task_id()` works for workflow-bound tasks
  - The method should work regardless of `workflow_execution_id` value
  - Existing implementation confirmed to work

#### 3.2 Server - REST Handler

- [x] **3.2.1** Implement `GET /api/tenants/{tenant_slug}/workflow-executions/{workflow_id}/tasks/{task_id}/attempts` handler
  - Resolve tenant from slug
  - Verify workflow belongs to tenant
  - Verify task belongs to workflow (`workflow_execution_id` matches)
  - Authorize: `state.authorize(principal).view("TaskExecution", ...)`
  - Call `task_attempt_repo.list_by_task_id()`
  - Return `ListTaskAttemptsResponse` (reuse from standalone tasks)

- [x] **3.2.2** Register route in `flovyn-server/api/rest/mod.rs`
  - Add under workflow routes

- [x] **3.2.3** Add OpenAPI annotations
  - Reference existing `TaskAttemptResponse` and `ListTaskAttemptsResponse` schemas

#### 3.3 REST Client

- [x] **3.3.1** Add `get_workflow_task_attempts()` method to `FlovynClient`
  - `get_workflow_task_attempts(tenant: &str, workflow_id: Uuid, task_id: Uuid) -> Result<ListTaskAttemptsResponse, ClientError>`
  - Note: Response type is same as standalone task attempts

#### 3.4 Integration Tests

- [x] **3.4.1** Test `test_rest_get_workflow_task_attempts_empty`
- [x] **3.4.2** Test `test_rest_get_workflow_task_attempts_with_results`
- [x] **3.4.3** Test `test_rest_get_workflow_task_attempts_task_not_in_workflow`
- [x] **3.4.4** Test `test_rest_get_workflow_task_attempts_workflow_not_found`

#### 3.5 CLI Command

- [x] **3.5.1** Add `TaskAttempts` subcommand to `WorkflowsCommand`
  ```rust
  /// View task retry history
  TaskAttempts {
      workflow_id: Uuid,
      task_id: Uuid,
  },
  ```

- [x] **3.5.2** Implement handler and output formatting
  - Reuse `task_attempts()` method from `Outputter`

---

### Phase 4: Task Logs (Observability) ✅

> **Note**: Implemented for standalone tasks. gRPC `LogMessage` endpoint updated to persist logs to database.

#### 4.1 Database Migration

- [x] **4.1.1** Create migration for `task_execution_log` table
  ```sql
  CREATE TABLE task_execution_log (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      task_execution_id UUID NOT NULL REFERENCES task_execution(id) ON DELETE CASCADE,
      level VARCHAR(10) NOT NULL,  -- INFO, WARN, ERROR
      message TEXT NOT NULL,
      timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      metadata JSONB,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );

  CREATE INDEX idx_task_log_task_id ON task_execution_log(task_execution_id);
  CREATE INDEX idx_task_log_timestamp ON task_execution_log(task_execution_id, timestamp);
  ```

#### 4.2 Domain Model

- [x] **4.2.1** Create `TaskLog` struct in `flovyn-server/domain/task.rs`
  - Fields: `id`, `task_execution_id`, `level`, `message`, `timestamp`, `metadata`
  - Add `TaskLogLevel` enum: `Debug`, `Info`, `Warn`, `Error`

#### 4.3 Repository Layer

- [x] **4.3.1** Create `TaskLogRepository`
  - `create(log: TaskLog)` - insert log entry
  - `list_by_task_id(task_id, level_filter, limit, offset)` - paginated query
  - `count_by_task_id(task_id, level_filter)` - for pagination

#### 4.4 gRPC - Log Ingestion

- [x] **4.4.1** Used existing `LogMessage` RPC in proto (already defined)
  ```protobuf
  message LogTaskMessageRequest {
      string task_execution_id = 1;
      string level = 2;  // INFO, WARN, ERROR
      string message = 3;
      google.protobuf.Struct metadata = 4;
  }
  ```

- [x] **4.4.2** Updated `log_message()` gRPC handler to persist logs to database
  - Validate task exists
  - Create log entry via repository

#### 4.5 Server - REST Handler

- [x] **4.5.1** Create `TaskLogResponse` DTO
  ```rust
  #[derive(Debug, Serialize, ToSchema)]
  #[serde(rename_all = "camelCase")]
  pub struct TaskLogResponse {
      pub id: Uuid,
      pub level: String,
      pub message: String,
      pub timestamp: String,
  }
  ```

- [x] **4.5.2** Create `ListTaskLogsQuery` DTO
  - Fields: `level`, `limit`, `offset`
  - Defaults: `limit=50`, `offset=0`

- [x] **4.5.3** Create `ListTaskLogsResponse` DTO
  - Fields: `logs`, `total`, `limit`, `offset`

- [x] **4.5.4** Implement `GET /api/tenants/{tenant_slug}/tasks/{task_id}/logs` handler for standalone tasks
  - Standard tenant/task validation
  - Query with pagination and level filter
  - Return paginated response

- [x] **4.5.5** Register route

#### 4.6 REST Client

- [x] **4.6.1** Add log response types to `types.rs`

- [x] **4.6.2** Add `get_task_logs()` method to `FlovynClient`

#### 4.7 Integration Tests

- [x] **4.7.1** Test `test_rest_get_task_logs_empty`
- [x] **4.7.2** Test `test_rest_get_task_logs_not_found`
- [x] **4.7.3** Test `test_rest_get_task_logs_level_filter`
- [x] **4.7.4** Test `test_rest_get_task_logs_invalid_level`

#### 4.8 CLI Command

- [x] **4.8.1** Add `Logs` subcommand to `TasksCommand`
  ```rust
  Logs {
      task_id: Uuid,
      #[arg(long)]
      level: Option<String>,
      #[arg(long, default_value = "50")]
      limit: i64,
      #[arg(long, default_value = "0")]
      offset: i64,
  },
  ```

- [x] **4.8.2** Implement handler and output formatting

---

### Phase 5: Task Stream SSE (Observability) ✅

> **Note**: Implemented for standalone tasks. Uses existing `StreamSubscriber` infrastructure that workers already publish to.

#### 5.1 Server - REST Handler

- [x] **5.1.1** Implement `GET /api/tenants/{tenant_slug}/stream/tasks/{task_execution_id}` handler
  - Validate task ownership (task belongs to tenant)
  - Create SSE stream that subscribes to `StreamSubscriber` for task events
  - Use `axum::response::sse::Sse`
  - Include `KeepAlive` (15 second interval)
  - 5-minute inactivity timeout

- [x] **5.1.2** Register route in `flovyn-server/api/rest/mod.rs`

#### 5.2 REST Client

- [x] **5.2.1** Add `stream_task()` method to `FlovynClient`
  - `stream_task(tenant: &str, task_id: Uuid) -> Pin<Box<dyn Stream<Item = Result<StreamEvent, ClientError>> + Send>>`
  - Handle SSE parsing via existing `start_sse_stream()` infrastructure

#### 5.3 CLI Command

- [x] **5.3.1** Add `Watch` subcommand to `TasksCommand`
  ```rust
  /// Watch task stream events in real-time
  Watch { task_id: Uuid },
  ```

- [x] **5.3.2** Implement handler
  - Call `client.stream_task()`
  - Print events with format: `[EVENT_TYPE] id=<id> data=<data>`
  - Support Ctrl+C to exit

---

## File Changes Summary

### Server (`server/`)

| File | Changes |
|------|---------|
| `flovyn-server/src/repository/workflow_repository.rs` | Add `retry_workflow()`, `list_children()` |
| `flovyn-server/src/repository/event_repository.rs` | Add `RETRY_REQUESTED` event type |
| `flovyn-server/src/api/rest/workflows.rs` | Add retry, children, task-attempts handlers and DTOs |
| `flovyn-server/src/api/rest/mod.rs` | Register new routes |
| `flovyn-server/migrations/YYYYMMDD_task_logs.sql` | Phase 4: task_execution_log table |
| `flovyn-server/src/domain/task.rs` | Phase 4: `TaskLog`, `TaskLogLevel` |
| `flovyn-server/src/repository/task_log_repository.rs` | Phase 4: new file |
| `proto/flovyn.proto` | Phase 4: `LogTaskMessageRequest` |
| `flovyn-server/src/api/rest/streaming.rs` | Phase 5: task stream handler |

### REST Client (`crates/rest-client/`)

| File | Changes |
|------|---------|
| `flovyn-server/src/types.rs` | Add retry, children, task logs response types |
| `flovyn-server/src/client.rs` | Add `retry_workflow()`, `list_workflow_children()`, `get_workflow_task_attempts()`, `get_workflow_task_logs()`, `stream_workflow_tasks()` |

### CLI (`cli/`)

| File | Changes |
|------|---------|
| `flovyn-server/src/commands/workflows.rs` | Add `Retry`, `Children`, `TaskAttempts`, `TaskLogs`, `WatchTasks` subcommands |
| `flovyn-server/src/output.rs` | Add output methods for new commands |

---

## Dependencies

```
Phase 1 (Retry) → Independent, can start immediately
Phase 2 (Children) → Independent, can start immediately
Phase 3 (Task Attempts) → Independent, can start immediately

Phase 4 (Task Logs) → Requires SDK changes for log ingestion
Phase 5 (Task Stream) → Requires Phase 4 or parallel event infrastructure
```

**Recommendation**: Implement Phases 1-3 first as they require no infrastructure changes. Defer Phases 4-5 until there's active demand for task-level observability.

---

## Notes

- **Event Sourcing**: Workflow retry creates a new event (`RETRY_REQUESTED`) in the event log, maintaining audit trail.

- **Task Attempts Reuse**: The `TaskAttemptResponse` and `ListTaskAttemptsResponse` DTOs already exist from standalone tasks. The workflow task attempts endpoint reuses these.

- **Child Workflows**: Child workflows are already tracked via `parent_workflow_execution_id` in `workflow_execution` table. No migration needed.

- **Task Logs Deferral**: Phase 4 (Task Logs) requires SDK changes for workers to emit logs. This is significant work and should only be prioritized when there's active need for task-level logging.

- **SSE Infrastructure**: Phase 5 can leverage existing `StreamSubscriber` from workflow streaming, but may need dedicated task event channel.

---

## CLI Usage Examples

### Phase 1: Workflow Retry
```bash
# Retry a failed workflow
flovyn workflows retry 550e8400-e29b-41d4-a716-446655440000

# Retry with a note
flovyn workflows retry 550e8400-e29b-41d4-a716-446655440000 --note "Fixed bug in payment processor"
```

### Phase 2: Workflow Children
```bash
# List child workflows
flovyn workflows children 550e8400-e29b-41d4-a716-446655440000
```

### Phase 3: Workflow Task Attempts
```bash
# View retry history for a specific task
flovyn workflows task-attempts 550e8400-e29b-41d4-a716-446655440000 660e8400-e29b-41d4-a716-446655440001
```

### Phase 4: Task Logs
```bash
# View task logs
flovyn workflows task-logs 550e8400... 660e8400... --level ERROR --limit 50
```

### Phase 5: Watch Tasks
```bash
# Watch task state changes in real-time
flovyn workflows watch-tasks 550e8400-e29b-41d4-a716-446655440000
```

---

## Example Output

### `flovyn workflows retry <id>`
```
Workflow 550e8400-e29b-41d4-a716-446655440000 reset for retry.
Status: PENDING
Workers will pick it up automatically.
```

### `flovyn workflows children <id>`
```
CHILD ID                              KIND              STATUS     CREATED
660e8400-e29b-41d4-a716-446655440001  process-order     COMPLETED  2024-01-15 10:30:00
660e8400-e29b-41d4-a716-446655440002  send-notification RUNNING    2024-01-15 10:31:00
660e8400-e29b-41d4-a716-446655440003  update-inventory  PENDING    2024-01-15 10:32:00
```

### `flovyn workflows task-attempts <workflow-id> <task-id>`
```
ATTEMPT  STATUS     DURATION  WORKER              ERROR
1        FAILED     2150ms    worker-pod-abc123   Connection timeout
2        FAILED     1200ms    worker-pod-abc123   Connection timeout
3        COMPLETED  500ms     worker-pod-xyz789   -
```
