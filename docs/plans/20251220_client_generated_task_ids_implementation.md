# Implementation Plan: Client-Generated Task Execution IDs

**Design Document**: [client-generated-task-ids.md](../design/client-generated-task-ids.md)

## Overview

Enable SDK to generate task execution IDs client-side by extending `ScheduleTaskCommand` to create `TaskExecution` records inline, eliminating the need for a separate `SubmitTask` gRPC call.

**Status**: Implemented (Server-side)

---

## TODO List

### Phase 1: Proto Changes

- [x] **1.1** Extend `ScheduleTaskCommand` in `proto/flovyn.proto`
  - Add `optional int32 max_retries = 4;`
  - Add `optional int64 timeout_ms = 5;`
  - Add `optional string queue = 6;`
  - Add `optional int32 priority_seconds = 7;`

- [x] **1.2** Run `cargo build` to regenerate Rust code from proto

### Phase 2: Repository Layer

- [x] **2.1** Add `TaskRepository` to `WorkflowDispatchService`
  - Added `task_repo: Arc<TaskRepository>` field
  - Updated `new()` to initialize `task_repo`

### Phase 3: ScheduleTask Command Handling

- [x] **3.1** Add ScheduleTask handling in `submit_workflow_commands`
  - Parse `task_execution_id` from command (validate UUID format)
  - Check if TaskExecution already exists via `task_repo.get()`
  - If exists: validate task_type and workflow_id match (idempotency)
  - If not exists: create TaskExecution with client-provided ID

- [x] **3.2** Implement idempotency validation
  - Different task_type returns `FAILED_PRECONDITION`
  - Different workflow returns `FAILED_PRECONDITION`

- [x] **3.3** Implement TaskExecution creation
  - Get queue from command or default to workflow's `task_queue`
  - Get max_retries from command or default to 3
  - Use `TaskExecution::new_with_id()` with client-provided ID
  - Set traceparent from workflow
  - Call `task_repo.create()`

- [x] **3.4** Add metrics recording after task creation

### Phase 4: Error Handling

- [x] **4.1** Add UUID validation error handling
  - Returns `INVALID_ARGUMENT` for invalid UUID format

- [x] **4.2** Add task ID collision error handling
  - Returns `FAILED_PRECONDITION` for mismatched task_type or workflow

- [x] **4.3** Add duplicate key handling
  - Handles race condition with duplicate key errors gracefully

### Phase 5: Testing

- [x] **5.1** All existing unit tests pass (155 tests)
- [x] **5.2** All existing integration tests pass (13 tests)
- [ ] **5.3** SDK-level integration test (requires SDK update to use client-generated IDs)

### Phase 6: Documentation

- [x] **6.1** Update comments in `workflow_dispatch.rs`
  - Documented ScheduleTask flow with client-generated IDs

---

## File Changes Summary

| File | Changes |
|------|---------|
| `proto/flovyn.proto` | Add 4 optional fields to ScheduleTaskCommand |
| `flovyn-server/src/api/grpc/workflow_dispatch.rs` | Add `task_repo`, add ScheduleTask handling with task creation |

---

## Notes

- The `timeout_ms` field in ScheduleTaskCommand is for future use - task timeout not currently implemented in server
- `priority_seconds` is stored but not used for task scheduling (tasks use creation order)
- Event creation happens even for idempotent retries to maintain event log consistency
- SDK needs to be updated to generate task IDs client-side and use the new optional fields
