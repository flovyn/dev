# Implementation Plan: Standalone Tasks

**Design Document**: [standalone-tasks.md](../design/standalone-tasks.md)

## Overview

Enable task execution without workflow context via REST API and enhanced gRPC polling. Standalone tasks are identified by `workflow_execution_id IS NULL`.

**Status**: Completed

---

## TODO List

### Phase 1: Database Migrations

- [x] **1.1** Create migration to add `scheduled_at` column to `task_execution`
  - Add `scheduled_at TIMESTAMPTZ` column (nullable)
  - Add index for standalone task polling:
    ```sql
    CREATE INDEX idx_task_standalone_poll
        ON task_execution (tenant_id, queue, status, scheduled_at)
        WHERE workflow_execution_id IS NULL AND status = 'PENDING';
    ```

- [x] **1.2** Create migration for `task_attempt` table
  - Create table with columns: `id`, `task_execution_id`, `attempt`, `started_at`, `finished_at`, `status`, `output`, `error`, `worker_id`, `created_at`
  - Add foreign key to `task_execution` with `ON DELETE CASCADE`
  - Add unique constraint on `(task_execution_id, attempt)`
  - Add index on `task_execution_id`

### Phase 2: Domain Model

- [x] **2.1** Add `scheduled_at` field to `TaskExecution` in `flovyn-server/domain/task.rs`
  - Add field: `pub scheduled_at: Option<DateTime<Utc>>`
  - Update `new()` and `new_with_id()` constructors to accept `scheduled_at`
  - Update `to_proto()` if needed

- [x] **2.2** Create `TaskAttempt` struct in `flovyn-server/domain/task.rs`
  - Fields: `id`, `task_execution_id`, `attempt`, `started_at`, `finished_at`, `status`, `output`, `error`, `worker_id`
  - Create `TaskAttemptStatus` enum: `Completed`, `Failed`, `Timeout`, `Cancelled`

### Phase 3: Repository Layer

- [x] **3.1** Add `scheduled_at` support to `TaskRepository`
  - Update `create()` to insert `scheduled_at`
  - Update SQL select queries to include `scheduled_at`

- [x] **3.2** Update `find_lock_and_mark_running()` for standalone tasks
  - Add optional `standalone_only: bool` parameter
  - When `standalone_only=true`, add `AND workflow_execution_id IS NULL` filter
  - Add `AND (scheduled_at IS NULL OR scheduled_at <= NOW())` filter
  - Update `ORDER BY` to `scheduled_at ASC NULLS FIRST, created_at ASC`

- [x] **3.3** Add `list_standalone_tasks()` method
  - Parameters: `tenant_id`, `status`, `queue`, `task_type`, `limit`, `offset`
  - Return paginated list with total count
  - Filter by `workflow_execution_id IS NULL`

- [x] **3.4** Add `count_standalone_tasks()` method
  - Parameters: same filters as `list_standalone_tasks()`
  - Return total count for pagination

- [x] **3.5** Add `cancel_task()` method
  - Only allow cancellation of PENDING tasks
  - Return error if task is not PENDING

- [x] **3.6** Create `TaskAttemptRepository`
  - `create(attempt: TaskAttempt)` - insert attempt record
  - `list_by_task_id(task_execution_id)` - get all attempts for a task

- [x] **3.7** Integrate attempt tracking into task completion/failure
  - Update `complete()` to create attempt record with status=COMPLETED
  - Update `fail()` to create attempt record with status=FAILED
  - On failure, check `execution_count < max_retries` to reset to PENDING or mark FAILED

### Phase 4: REST API - DTOs

- [x] **4.1** Create `CreateTaskRequest` DTO in `flovyn-server/api/rest/tasks.rs`
  - Fields: `task_type`, `input`, `queue`, `max_retries`, `scheduled_at`
  - Add serde and utoipa derive macros

- [x] **4.2** Create `TaskResponse` DTO
  - Fields: `id`, `tenant_id`, `task_type`, `status`, `input`, `output`, `error`, `queue`, `execution_count`, `max_retries`, `progress`, `worker_id`, timestamps
  - Match design document JSON structure

- [x] **4.3** Create `ListTasksQuery` DTO
  - Query parameters: `status`, `queue`, `task_type`, `limit`, `offset`
  - Add defaults: `limit=50`, `offset=0`

- [x] **4.4** Create `ListTasksResponse` DTO
  - Fields: `tasks`, `total`, `limit`, `offset`

- [x] **4.5** Create `TaskAttemptResponse` DTO
  - Fields: `attempt`, `started_at`, `finished_at`, `duration_ms`, `status`, `output`, `error`, `worker_id`

- [x] **4.6** Create `ListTaskAttemptsResponse` DTO
  - Fields: `attempts: Vec<TaskAttemptResponse>`

### Phase 5: REST API - Handlers

- [x] **5.1** Create `flovyn-server/api/rest/tasks.rs` module
  - Add module to `flovyn-server/api/rest/mod.rs`

- [x] **5.2** Implement `POST /api/tenants/{tenant_slug}/tasks` handler
  - Resolve tenant from slug
  - Create `TaskExecution` with `workflow_execution_id = None`
  - Return 201 Created with `TaskResponse`

- [x] **5.3** Implement `GET /api/tenants/{tenant_slug}/tasks` handler
  - Parse `ListTasksQuery` parameters
  - Call `list_standalone_tasks()` and `count_standalone_tasks()`
  - Return `ListTasksResponse`

- [x] **5.4** Implement `GET /api/tenants/{tenant_slug}/tasks/{task_id}` handler
  - Fetch task by ID
  - Verify task belongs to tenant
  - Verify task is standalone (`workflow_execution_id IS NULL`)
  - Return `TaskResponse`

- [x] **5.5** Implement `DELETE /api/tenants/{tenant_slug}/tasks/{task_id}` handler
  - Verify task is PENDING
  - Call `cancel_task()`
  - Return 204 No Content

- [x] **5.6** Implement `GET /api/tenants/{tenant_slug}/tasks/{task_id}/attempts` handler
  - Fetch attempts by task ID
  - Return `ListTaskAttemptsResponse`

- [x] **5.7** Register task routes in `flovyn-server/api/rest/mod.rs`
  - Add routes under `/api/tenants/{tenant_slug}/tasks`

### Phase 6: OpenAPI Documentation

- [x] **6.1** Add OpenAPI tags for tasks
  - Add `tasks` tag to `flovyn-server/openapi/mod.rs` or equivalent

- [x] **6.2** Add OpenAPI paths for all task endpoints
  - Document request/response schemas

### Phase 7: gRPC Enhancements

- [x] **7.1** Update `poll_task` to support standalone-only polling
  - Check if request has `workflow_execution_id` context
  - If no workflow context, filter `workflow_execution_id IS NULL`
  - Apply `scheduled_at` filter

- [x] **7.2** Update `fail_task` to handle retry logic with attempts
  - Create attempt record
  - Reset to PENDING if retries remaining
  - Mark FAILED if max retries exceeded

- [x] **7.3** Update `complete_task` to create attempt record
  - Create attempt record with status=COMPLETED

### Phase 8: Worker Notification

- [x] **8.1** Notify workers when standalone task is created
  - Call `WorkerNotifier::notify_work_available()` after task creation in REST handler

### Phase 9: Unit Tests

- [ ] **9.1** Add domain tests for `TaskExecution` with `scheduled_at`
  - Test constructor with `scheduled_at`
  - Test `is_ready()` helper if added

- [ ] **9.2** Add domain tests for `TaskAttempt`
  - Test struct creation
  - Test status enum

- [ ] **9.3** Add repository tests for `TaskRepository` standalone methods
  - Test `list_standalone_tasks()` with various filters
  - Test `cancel_task()` on PENDING and non-PENDING tasks
  - Test `find_lock_and_mark_running()` respects `scheduled_at`

- [ ] **9.4** Add repository tests for `TaskAttemptRepository`
  - Test `create()` and `list_by_task_id()`

### Phase 10: Integration Tests

- [x] **10.1** Test standalone task lifecycle via REST
  - Create task, poll, complete, verify status
  - Test with `scheduled_at` in future (should not be polled)

- [x] **10.2** Test task cancellation
  - Create PENDING task, cancel, verify CANCELLED status
  - Attempt to cancel RUNNING task, expect error

- [x] **10.3** Test retry flow with attempts
  - Create task, fail multiple times, verify attempts recorded
  - Verify max_retries honored

- [x] **10.4** Test listing and filtering
  - Create multiple tasks with different statuses/queues
  - Verify filters work correctly

### Phase 11: REST Client (for CLI)

- [x] **11.1** Add task response types to `flovyn-server/crates/rest-client/src/types.rs`
  - `CreateTaskRequest` - matches server DTO
  - `TaskResponse` - matches server DTO
  - `ListTasksResponse` - with pagination
  - `TaskAttemptResponse` - attempt details
  - `ListTaskAttemptsResponse` - list of attempts

- [x] **11.2** Add task methods to `FlovynClient` in `flovyn-server/crates/rest-client/src/client.rs`
  - `create_task(tenant, request)` - POST `/api/tenants/{tenant}/tasks`
  - `list_tasks(tenant, status, queue, task_type, limit, offset)` - GET with query params
  - `get_task(tenant, task_id)` - GET `/api/tenants/{tenant}/tasks/{task_id}`
  - `cancel_task(tenant, task_id)` - DELETE `/api/tenants/{tenant}/tasks/{task_id}`
  - `get_task_attempts(tenant, task_id)` - GET `/api/tenants/{tenant}/tasks/{task_id}/attempts`

### Phase 12: CLI Commands

- [x] **12.1** Create `flovyn-server/cli/src/commands/tasks.rs` module
  - Add module to `flovyn-server/cli/src/commands/mod.rs`

- [x] **12.2** Define `TasksCommand` enum with subcommands
  ```rust
  pub enum TasksCommand {
      /// Create a new standalone task
      Create { task_type: String, input: Option<String>, input_file: Option<PathBuf>, queue: String, max_retries: Option<i32>, scheduled_at: Option<String> },
      /// List standalone tasks
      List { status: Option<String>, queue: Option<String>, task_type: Option<String>, limit: i64, offset: i64 },
      /// Get task details
      Get { task_id: Uuid },
      /// Cancel a pending task
      Cancel { task_id: Uuid },
      /// View task attempts
      Attempts { task_id: Uuid },
  }
  ```

- [x] **12.3** Implement `TasksCommand::execute()` method
  - Match on each variant
  - Call appropriate `FlovynClient` method
  - Output results via `Outputter`

- [x] **12.4** Register `Tasks` command in `flovyn-server/cli/src/main.rs`
  - Add to `Commands` enum with alias `task` or `t`
  - Add match arm in `run()` function

### Phase 13: CLI Output Formatting

- [x] **13.1** Add task output methods to `Outputter` in `flovyn-server/cli/src/output.rs`
  - `task_created(&self, response: &TaskResponse)` - show created task
  - `task_list(&self, response: &ListTasksResponse)` - table with ID, type, status, queue, progress
  - `task_get(&self, response: &TaskResponse)` - detailed view
  - `task_cancelled(&self, task_id: Uuid)` - confirmation message
  - `task_attempts(&self, response: &ListTaskAttemptsResponse)` - attempts table

- [x] **13.2** Create `TaskRow` struct for table output
  - Fields: `id`, `task_type`, `status`, `queue`, `progress`, `created_at`
  - Implement `From<&TaskResponse>` for `TaskRow`

- [x] **13.3** Create `TaskAttemptRow` struct for attempts table
  - Fields: `attempt`, `status`, `duration_ms`, `worker_id`, `error` (truncated)

### Phase 14: CLI Integration Tests

- [ ] **14.1** Add CLI task tests
  - Test `flovyn tasks create --task-type test --input '{}'`
  - Test `flovyn tasks list`
  - Test `flovyn tasks get <id>`
  - Test `flovyn tasks cancel <id>`
  - Test `flovyn tasks attempts <id>`

### Phase 15: TUI - Tasks View

- [x] **15.1** Add `ViewMode` enum to switch between Workflows and Tasks
  - Add to `flovyn-server/cli/src/tui/app.rs`
  - `ViewMode::Workflows` (default), `ViewMode::Tasks`
  - Add keybinding `w` for workflows, `t` for tasks

- [x] **15.2** Add task state to `App` struct
  - `tasks: Vec<TaskSummary>` - list of standalone tasks
  - `selected_task_index: usize`
  - `selected_task: Option<TaskResponse>` - detailed task info
  - `task_attempts: Vec<TaskAttemptResponse>` - attempts for selected task

- [x] **15.3** Add `TaskDetailTab` enum
  - `Overview` - task details (type, status, queue, progress)
  - `Attempts` - retry history
  - `Actions` - cancel button

- [x] **15.4** Add background loaders for tasks
  - `spawn_load_tasks()` - fetch task list
  - `spawn_load_task_detail()` - fetch single task details
  - `spawn_load_task_attempts()` - fetch attempts
  - `spawn_cancel_task()` - cancel a pending task

- [x] **15.5** Add `AppMessage` variants for tasks
  - `TasksLoaded(Result<Vec<TaskSummary>, String>)`
  - `TaskDetailLoaded(Box<Result<TaskResponse, String>>)`
  - `TaskAttemptsLoaded(Result<Vec<TaskAttemptResponse>, String>)`
  - `TaskCancelled(Result<String, String>)`

### Phase 16: TUI - Task Panels

- [x] **16.1** Create `flovyn-server/cli/src/tui/panels/task_list.rs` and `task_detail.rs`
  - `render_task_list_panel()` - table with ID, type, status, queue, progress
  - `render_task_detail_panel()` - overview, input/output, timestamps
  - `render_task_attempts_tab()` - attempts table with duration, error

- [x] **16.2** Update `layout.rs` to support task views
  - Render task list when `ViewMode::Tasks`
  - Render task detail panels based on `TaskDetailTab`

- [x] **16.3** Add view mode indicator to header
  - Show `[w]Workflows` or `[t]Tasks` based on current mode
  - Keybinding hints for switching

- [x] **16.4** Add task filtering support
  - Filter by task type, status, queue
  - Reuse existing filter mode pattern

### Phase 17: TUI - Task Actions

- [x] **17.1** Implement task cancellation in TUI
  - Only show cancel option for PENDING tasks
  - Confirm action, show result

- [x] **17.2** Add progress bar rendering for tasks
  - Show visual progress indicator (0-100%)
  - Created `flovyn-server/cli/src/tui/widgets.rs` with `progress_bar()` helper
  - Task list shows compact 8-char progress bar: `████████░░ 80%`
  - Task detail shows larger 20-char progress bar in overview tab

- [x] **17.3** Add keyboard shortcuts help for tasks
  - Update help overlay with task-specific bindings

---

## File Changes Summary

### Server (`server/`)

| File | Changes |
|------|---------|
| `flovyn-server/migrations/YYYYMMDD_standalone_tasks.sql` | Add `scheduled_at`, create `task_attempt` table, indexes |
| `flovyn-server/src/domain/task.rs` | Add `scheduled_at` field, `TaskAttempt` struct |
| `flovyn-server/src/repository/task_repository.rs` | Add standalone methods, `scheduled_at` support |
| `flovyn-server/src/repository/task_attempt_repository.rs` | New file for attempt CRUD |
| `flovyn-server/src/repository/mod.rs` | Export `TaskAttemptRepository` |
| `flovyn-server/src/api/rest/tasks.rs` | New file with REST handlers |
| `flovyn-server/src/api/rest/mod.rs` | Register task routes |
| `flovyn-server/src/api/grpc/task_execution.rs` | Enhance poll/complete/fail for standalone |

### REST Client (`crates/rest-client/`)

| File | Changes |
|------|---------|
| `flovyn-server/src/types.rs` | Add task request/response types |
| `flovyn-server/src/client.rs` | Add task CRUD methods |

### CLI (`cli/`)

| File | Changes |
|------|---------|
| `flovyn-server/src/commands/tasks.rs` | New file with `TasksCommand` enum and handlers |
| `flovyn-server/src/commands/mod.rs` | Export `tasks` module |
| `flovyn-server/src/main.rs` | Register `Tasks` command with alias |
| `flovyn-server/src/output.rs` | Add task output formatting methods |
| `flovyn-server/src/tui/app.rs` | Add `ViewMode`, task state, task loaders |
| `flovyn-server/src/tui/layout.rs` | Support task view rendering |
| `flovyn-server/src/tui/widgets.rs` | New file with reusable widgets (progress bar) |
| `flovyn-server/src/tui/panels/task_list.rs` | New file with task list panel |
| `flovyn-server/src/tui/panels/task_detail.rs` | New file with task detail panels |
| `flovyn-server/src/tui/panels/mod.rs` | Export task panels and widgets |

---

## Notes

- The existing `TaskExecution` already has `workflow_execution_id: Option<Uuid>`, so standalone tasks are already partially supported at the data model level.
- Queue-based routing is already implemented - no label matching needed.
- Worker pools are explicitly out of scope per design doc.
- CRON/interval scheduling is a separate feature.
- Manual resolution and task logs are deferred features.

---

## CLI Usage Examples

```bash
# Create a standalone task
flovyn tasks create send-email --input '{"to": "user@example.com", "subject": "Hello"}'

# Create with delayed execution
flovyn tasks create send-email --input-file email.json --scheduled-at "2025-01-15T10:00:00Z"

# Create with custom queue and retries
flovyn tasks create process-file --queue high-priority --max-retries 5 --input '{}'

# List all standalone tasks
flovyn tasks list

# List with filters
flovyn tasks list --status PENDING --queue default --limit 100

# Get task details
flovyn tasks get 550e8400-e29b-41d4-a716-446655440000

# Cancel a pending task
flovyn tasks cancel 550e8400-e29b-41d4-a716-446655440000

# View task attempts (retry history)
flovyn tasks attempts 550e8400-e29b-41d4-a716-446655440000

# JSON output for scripting
flovyn tasks list --output json | jq '.tasks[] | select(.status == "FAILED")'
```

---

## TUI Usage

Launch the dashboard and switch to tasks view:

```bash
# Launch dashboard (default: workflows view)
flovyn dashboard

# Keyboard shortcuts in TUI:
# t         - Switch to Tasks view
# w         - Switch to Workflows view
# j/k       - Navigate up/down in list
# Enter     - View task details
# Tab       - Switch tabs (Overview/Attempts/Actions)
# c         - Cancel task (in Actions tab, PENDING only)
# /         - Filter tasks
# r         - Refresh
# q         - Quit
```

Tasks view displays:
- **List panel**: Task ID, type, status, queue, progress, created time
- **Overview tab**: Full task details, input/output, timestamps
- **Attempts tab**: Retry history with duration, status, errors
- **Actions tab**: Cancel button for PENDING tasks
