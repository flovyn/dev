# Implementation Plan: Task Idempotency Key

**Date:** 2026-01-02
**Design Document:** [Unified Idempotency Key Design](../design/20260101_unified_idempotency.md)

## Overview

Extend idempotency key support to task launching. Currently:
- **Workflows**: ✅ Support idempotency keys via `StartWorkflowRequest.idempotency_key`
- **Promises**: ✅ Support idempotency keys via `CreatePromiseCommand.idempotency_key`
- **Tasks (SubmitTask)**: ⚠️ Proto fields exist but logic not implemented
- **Tasks (ScheduleTaskCommand)**: ❌ No idempotency key fields

This plan implements full idempotency key support for tasks.

## Use Cases

1. **External task correlation**: A workflow schedules a task with an idempotency key (e.g., `job:batch_12345`), allowing external systems to look up task status by key
2. **Deduplication**: Prevent duplicate task creation when the same workflow re-executes (replay) or when external systems retry submissions
3. **Webhook correlation**: External systems can resolve task state by idempotency key (future work)

## Current State Analysis

### SubmitTaskRequest (standalone tasks)
```protobuf
message SubmitTaskRequest {
  ...
  optional string idempotency_key = 8;           // EXISTS but unused
  optional int64 idempotency_key_ttl_seconds = 9; // EXISTS but unused
  ...
}
```
The proto fields exist but `task_execution.rs:submit_task()` always returns `idempotency_key_new: true` without checking.

### ScheduleTaskCommand (workflow tasks)
```protobuf
message ScheduleTaskCommand {
  string kind = 1;
  bytes input = 2;
  string task_execution_id = 3;  // Client-generated UUID (internal idempotency)
  optional int32 max_retries = 4;
  optional int64 timeout_ms = 5;
  optional string queue = 6;
  optional int32 priority_seconds = 7;
  // NO idempotency_key field
}
```
Uses client-generated UUID for internal idempotency (replay safety), but no user-facing idempotency key.

### IdempotencyKeyRepository

Already supports `task_execution_id` column in `idempotency_key` table. Methods:
- `claim_or_get()` - handles workflow/task claim-then-register pattern
- `register()` - associates key with workflow_execution_id or task_execution_id
- `clear_for_execution(id, ExecutionType::Task)` - clears key for failed tasks

## Implementation Phases

### Phase 1: Protobuf Changes

**Goal:** Add idempotency key fields to `ScheduleTaskCommand`.

**Files to modify:**
- `server/proto/flovyn.proto`

**Changes:**
```protobuf
message ScheduleTaskCommand {
  string kind = 1;
  bytes input = 2;
  string task_execution_id = 3;
  optional int32 max_retries = 4;
  optional int64 timeout_ms = 5;
  optional string queue = 6;
  optional int32 priority_seconds = 7;
  // NEW: Idempotency key for external correlation
  optional string idempotency_key = 8;
  // NEW: TTL for idempotency key (default: 86400 = 24 hours)
  optional int64 idempotency_key_ttl_seconds = 9;
}
```

### Phase 2: Repository Layer

**Goal:** Add `create_for_task()` method following the promise pattern.

**Files to modify:**
- `flovyn-server/server/src/repository/idempotency_key_repository.rs`

**Changes:**
1. Add `create_for_task()` method:
```rust
/// Create an idempotency key entry for a task.
///
/// This is called when a task is scheduled with an idempotency key.
/// The key can later be used to look up the task for status checks.
pub async fn create_for_task(
    &self,
    tenant_id: Uuid,
    key: &str,
    task_execution_id: Uuid,
    expires_at: DateTime<Utc>,
) -> Result<(), IdempotencyError>;
```

2. Add `find_task_by_key()` method (for future use):
```rust
/// Look up a task by its idempotency key.
pub async fn find_task_by_key(
    &self,
    tenant_id: Uuid,
    key: &str,
) -> Result<Option<Uuid>, sqlx::Error>;
```

### Phase 3: Command Handler Integration

**Goal:** Process idempotency key when handling `ScheduleTaskCommand`.

**Files to modify:**
- `flovyn-server/server/src/api/grpc/workflow_dispatch.rs`

**Changes in `submit_workflow_commands()`:**
1. Extract idempotency key from `ScheduleTaskCommand` when present
2. After creating task, call `IdempotencyKeyRepository::create_for_task()`
3. Handle `IdempotencyError::KeyConflict` (log warning, don't fail)

### Phase 4: SubmitTask Implementation

**Goal:** Implement idempotency key logic for standalone tasks.

**Files to modify:**
- `flovyn-server/server/src/api/grpc/task_execution.rs`

**Changes in `submit_task()`:**
1. If `idempotency_key` is provided:
   - Check if key already exists (find existing task)
   - If exists and task matches, return existing task with `idempotency_key_new: false`
   - If exists for different task, return error
   - If not exists, create task and register key
2. Update response to reflect actual idempotency status

### Phase 5: Integration Tests

**Location:** `flovyn-server/server/tests/integration/task_tests.rs`

**Test cases:**
1. `test_schedule_task_with_idempotency_key` - Workflow schedules task with key, key is registered
2. `test_schedule_task_idempotency_key_duplicate` - Same key on replay returns existing task
3. `test_submit_task_with_idempotency_key` - Standalone task with key
4. `test_submit_task_idempotency_key_existing` - Returns existing task for same key
5. `test_task_without_idempotency_key_backward_compatible` - Existing tests still work

## TODO List

### Phase 1: Protobuf Changes ✅
- [x] Add `idempotency_key` field to `ScheduleTaskCommand` (field 8)
- [x] Add `idempotency_key_ttl_seconds` field to `ScheduleTaskCommand` (field 9)
- [x] Run `cargo build` to regenerate protobuf code
- [x] Verify generated code compiles

### Phase 2: Repository Layer ✅
- [x] Add `create_for_task()` method using claim-then-register pattern
- [x] Add `find_task_by_key()` method for future lookups
- [x] Handle idempotent case (same task_id with same key = success)
- [x] Handle conflict case (different task_id with same key = error)

### Phase 3: Command Handler Integration ✅
- [x] Extract idempotency key from `ScheduleTaskCommand` in `submit_workflow_commands()`
- [x] Call `create_for_task()` after task creation when key is present
- [x] Calculate TTL (default 24 hours if not specified)
- [x] Handle `IdempotencyError::TaskKeyConflict` (log warning, continue)

### Phase 4: SubmitTask Implementation ✅
- [x] Implement idempotency key lookup in `submit_task()`
- [x] Return existing task for duplicate key (idempotent behavior)
- [x] Return error for key collision (different task)
- [x] Update response fields correctly (`idempotency_key_new`)

### Phase 5: Integration Tests ✅
- [x] Verified backward compatibility with existing standalone task tests (21 passed)
- [x] Verified backward compatibility with existing workflow tests (oracle_tests: 12 passed)
- [x] Added REST API idempotency key tests:
  - `test_rest_create_task_with_idempotency_key` - Create task with key, verify response
  - `test_rest_create_task_idempotency_key_duplicate` - Duplicate key returns existing task
  - `test_rest_create_task_idempotency_key_conflict` - Different kind with same key returns 409

### Phase 6: Validation & Cleanup ✅
- [x] Run full test suite (unit tests pass)
- [x] Update SDK proto and code to support new fields
- [x] Verify SDK builds and lib tests pass (202 passed)

## Test Strategy

### Unit Tests (Repository Layer)

```rust
#[cfg(test)]
mod tests {
    #[sqlx::test(fixtures("tenant", "workflow", "task"))]
    async fn test_create_for_task_and_lookup(pool: PgPool) {
        // Create key for task, lookup by key
    }

    #[sqlx::test(fixtures("tenant", "workflow", "task"))]
    async fn test_create_for_task_key_conflict(pool: PgPool) {
        // Same key, different task = conflict
    }

    #[sqlx::test(fixtures("tenant", "workflow", "task"))]
    async fn test_create_for_task_idempotent(pool: PgPool) {
        // Same key, same task = success (idempotent)
    }
}
```

### Integration Tests

```rust
/// Workflow that schedules a task with an idempotency key
pub struct TaskWithKeyWorkflow;

#[async_trait]
impl DynamicWorkflow for TaskWithKeyWorkflow {
    fn kind(&self) -> &str { "task-with-key-workflow" }

    async fn execute(&self, ctx: &dyn WorkflowContext, input: DynamicInput) -> Result<DynamicOutput> {
        let key = input.get("idempotencyKey").and_then(|v| v.as_str()).unwrap();

        // Schedule task with idempotency key
        let result = ctx.task::<Value>("some-task")
            .with_idempotency_key(key)
            .input(json!({"data": "test"}))
            .execute()
            .await?;

        Ok(result.into())
    }
}

#[tokio::test]
async fn test_schedule_task_with_idempotency_key() {
    // 1. Start workflow that schedules task with key
    // 2. Verify task is created
    // 3. Verify idempotency key is registered
    // 4. Complete task
    // 5. Verify workflow completes
}
```

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Existing tests break | Proto changes are additive, existing code unaffected |
| Key collision with workflows/promises | Existing constraint allows only one execution type per key |
| SDK compatibility | New fields are optional, old SDKs work without changes |

## Notes

- Default TTL should be 24 hours (86400 seconds) if not specified
- Key format convention: use prefixes like `job:`, `batch:` for namespacing
- Unlike promises, tasks are typically short-lived, so TTL should match task lifecycle
- Future work: REST API to query task by idempotency key
