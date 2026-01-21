# Bug: First Task Completion Event Missing from Workflow Replay

**Date**: 2025-12-20
**Severity**: High
**Component**: Workflow Task Event Assembly
**Status**: Fixed

## Summary

When a workflow schedules multiple parallel tasks, the first task's `TaskCompleted` event is consistently missing from the workflow replay events. This causes workflows using `join_all` or similar parallel patterns to hang indefinitely.

## Reproduction

### Test Case
Run the Rust SDK E2E test `test_e2e_parallel_tasks_join_all`:

```bash
FLOVYN_E2E_USE_DEV_INFRA=1 cargo test --test e2e -p flovyn-sdk -- --include-ignored --nocapture test_e2e_parallel_tasks_join_all
```

### Workflow Pattern
```rust
// Schedule 3 tasks in parallel
let task_futures: Vec<_> = items
    .iter()
    .map(|item| ctx.schedule_raw("process-item", json!({ "item": item })))
    .collect();

// Wait for all tasks to complete
let results = join_all(task_futures).await?;
```

## Observed Behavior

### SDK Actions (All Correct)
1. Workflow schedules 3 tasks with execution IDs:
   - Task A: `397c0118-1a7e-5c68-a106-6dd0dc445008`
   - Task B: `7c88f2b3-96fb-5c1e-835f-9f43a52d9759`
   - Task C: `5968ac93-62ad-5de3-a058-b0842cacbe20`

2. Task worker executes all 3 tasks (in order A, B, C)

3. Task worker reports all 3 completions to server:
   ```
   CompleteTask(397c0118...) -> Success
   CompleteTask(7c88f2b3...) -> Success
   CompleteTask(5968ac93...) -> Success
   ```

### Server Response (Bug)
Workflow replay events received by SDK:
```
seq 1: WorkflowStarted
seq 2: TaskScheduled (task A: 397c0118...)
seq 3: TaskScheduled (task B: 7c88f2b3...)
seq 4: TaskScheduled (task C: 5968ac93...)
seq 5: WorkflowSuspended
seq 6: TaskCompleted (task B: 7c88f2b3...)  <- Present
seq 7: TaskCompleted (task C: 5968ac93...)  <- Present
       TaskCompleted (task A: 397c0118...)  <- MISSING!
```

### Result
- `join_all` finds task A has no completion event
- Workflow returns `Suspended` waiting for task A
- Server never sends another workflow task with task A's completion
- Workflow times out

## Expected Behavior

All 3 `TaskCompleted` events should be included in the workflow replay:
```
seq 6: TaskCompleted (task A: 397c0118...)
seq 7: TaskCompleted (task B: 7c88f2b3...)
seq 8: TaskCompleted (task C: 5968ac93...)
```

## Key Observations

1. **Consistent pattern**: The FIRST task to complete is always the one missing
2. **Task execution confirmed**: All tasks execute successfully (logs show processing)
3. **Completion reporting confirmed**: SDK sends all 3 `CompleteTask` gRPC calls successfully
4. **Single-task workflows work**: `test_e2e_timeout_success` (1 task + 1 timer) passes
5. **Only parallel tasks affected**: The bug only manifests with multiple concurrent tasks

## Hypothesis

Possible race condition in the server when handling concurrent task completions:

1. Workflow suspends after scheduling 3 tasks
2. Task A completes first -> server receives `CompleteTask(A)`
3. Server marks workflow as runnable
4. Server begins assembling workflow task events
5. Tasks B and C complete -> server receives `CompleteTask(B)`, `CompleteTask(C)`
6. Server includes B and C in the workflow task (they arrived during assembly?)
7. Task A's completion was processed BEFORE the workflow task assembly started, so it's not included?

## Impact

- All parallel execution patterns are broken (`join_all`, `select`, fan-out/fan-in)
- Workflows using multiple concurrent tasks will hang indefinitely
- Affects SDK tests:
  - `test_e2e_parallel_tasks_join_all`
  - `test_e2e_fan_out_fan_in`
  - `test_e2e_racing_tasks_select`
  - `test_e2e_mixed_parallel_operations`
  - `test_e2e_parallel_large_batch`

## Environment

- Flovyn Server: Docker image from dev infrastructure
- Rust SDK: Current main branch
- Test harness: E2E with Docker containers (PostgreSQL, NATS, Flovyn server)

## Related

- SDK implementation plan: `sdk-rust/.dev/docs/plans/synchronous-scheduling-implementation.md`
- SDK is confirmed working correctly - this is a server-side issue

## Fix

### Root Cause

The bug was caused by a race condition in `flovyn-server/src/api/grpc/task_execution.rs` when recording task completion events. When multiple tasks completed concurrently:

1. Each task completion handler read `workflow.current_sequence` from the workflow table
2. All concurrent handlers would read the same sequence number (e.g., 5)
3. All handlers would try to create events with `sequence = current_sequence + 1` (e.g., 6)
4. Due to the unique constraint on `(workflow_execution_id, sequence_number)`, only one insert would succeed
5. The other inserts would fail silently (warning logged), losing those task completion events
6. The first task to complete (which lost the race) would have its event lost

### Solution

Added a new method `append_with_auto_sequence` in `flovyn-server/src/repository/event_repository.rs` that:

1. Gets the latest sequence number from the event table (not the potentially stale workflow table)
2. Attempts to insert the event with `next_seq = latest_seq + 1`
3. If the insert fails due to unique constraint violation (race condition), retries with a fresh sequence number
4. Retries up to 5 times before failing

Updated `complete_task` and `fail_task` in `flovyn-server/src/api/grpc/task_execution.rs` to use this new atomic method instead of the racy approach.

### Files Changed

- `flovyn-server/src/repository/event_repository.rs`: Added `append_with_auto_sequence` method
- `flovyn-server/src/api/grpc/task_execution.rs`: Updated `complete_task` and `fail_task` to use the new method
- `flovyn-server/tests/integration/workflow_tests.rs`: Added `test_parallel_task_completion_race_condition` test

### Testing

- Added integration test `test_parallel_task_completion_race_condition` that schedules 3 tasks and verifies all completion events are recorded
- All 155 unit tests pass
- All 14 integration tests pass
