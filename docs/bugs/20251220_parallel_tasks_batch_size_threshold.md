# Bug: Workflow Not Woken After Task Completions (5+ Tasks)

**Date**: 2025-12-20
**Severity**: High
**Component**: Workflow Task Scheduling / Task Completion Handling
**Status**: Fixed

## Summary

When a workflow schedules 5 or more parallel tasks, the workflow is never woken up after all tasks complete. The workflow remains suspended indefinitely. Workflows with 4 or fewer tasks work correctly.

## Reproduction

### Test Case
```bash
FLOVYN_E2E_USE_DEV_INFRA=1 cargo test --test e2e -p flovyn-sdk -- --include-ignored test_e2e_parallel_large_batch
```

### Workflow Pattern
```rust
// Schedule N tasks in parallel
let task_futures: Vec<_> = items
    .iter()
    .map(|item| ctx.schedule_raw("process-item", json!({ "item": item })))
    .collect();

// Wait for all tasks to complete
let results = join_all(task_futures).await?;
```

## Observed Behavior

### With 4 Tasks (PASSES)
```
[WorkflowContextImpl::new] Received 1 events (WorkflowStarted)
[ParallelTasksWorkflow] Scheduling 4 tasks
[ProcessItemTask] Processing items 1-4
[WorkflowContextImpl::new] Received 10 events (4 TaskScheduled + 4 TaskCompleted + ...)
[ParallelTasksWorkflow] join_all completed with 4 results
```

### With 5+ Tasks (FAILS)
```
[WorkflowContextImpl::new] Received 1 events (WorkflowStarted)
[ParallelTasksWorkflow] Scheduling 5 tasks
[ProcessItemTask] Processing items 1-5
<workflow never replayed - no second WorkflowContextImpl::new>
<test times out after 60s>
```

## Key Observations

1. **Exact threshold**: 4 tasks work, 5 tasks fail
2. **All tasks execute**: The task worker processes all tasks successfully
3. **No replay**: After task completion, the workflow is never woken for replay
4. **SDK is correct**: SDK sends all task completions to server (confirmed via logging)

## Timeline

1. Workflow execution #1: Schedules 5 tasks, suspends
2. Task worker: Executes all 5 tasks, reports completions to server
3. Expected: Server wakes workflow for replay with TaskCompleted events
4. Actual: Workflow is never woken, remains suspended indefinitely

## Affected Tests

- `test_e2e_parallel_large_batch` (10 items)
- Any workflow scheduling 5+ parallel tasks

## Working Tests (4 or fewer tasks)

- `test_e2e_parallel_tasks_join_all` (3 items)
- `test_e2e_timeout_success` (1 task + 1 timer)
- `test_comprehensive_with_task_scheduling` (1 task)

## Related SDK Fix

Note: An SDK-side fix was also applied in this session:
- `run_raw()` operation event field name: Server uses `"name"` but SDK was looking for `"operationName"`
- Fixed by checking both field names: `.get_string("operationName").or_else(|| operation_event.get_string("name"))`

## Environment

- Flovyn Server: Docker image from dev infrastructure
- Rust SDK: Current main branch
- Test harness: E2E with Docker containers (PostgreSQL, NATS, Flovyn server)

## Fix

### Root Cause

Two related race conditions were causing this bug:

1. **Bug #004 (Sequence Number Race)**: When multiple tasks complete concurrently, they all read the same `workflow.current_sequence` and try to insert events with the same sequence number. Due to the unique constraint, all but one fail silently, losing task completion events.

2. **Bug #005 (Resume Race)**: The `resume()` function only works when `state = 'WAITING'`. If the workflow is `RUNNING` when tasks complete, those `resume()` calls are no-ops. After the workflow goes back to WAITING, there are no more task completions to trigger a resume.

With 5+ tasks, the probability of hitting these race conditions increases significantly, making the bug manifest consistently.

### Solution

1. **Bug #004 Fix**: Added `append_with_auto_sequence()` in `event_repository.rs` that uses PostgreSQL advisory locks (`pg_advisory_xact_lock`) to serialize event insertions for a given workflow. This eliminates race conditions without needing retries - each concurrent task completion waits for its turn to insert.

2. **Bug #005 Fix**: After setting workflow state to WAITING in `submit_workflow_commands()`, check if there are new events that arrived while the workflow was RUNNING. If so, immediately resume the workflow.

3. **Event Ordering Fix**: Updated `append_batch()` to use atomic sequence assignment with retry (same pattern as `append_with_auto_sequence`). Also deferred `TaskExecution` record creation until AFTER `append_batch` succeeds. This ensures `TASK_SCHEDULED` events are always written before tasks become visible to workers, preventing `TASK_COMPLETED` events from appearing before their corresponding `TASK_SCHEDULED` events in the event log.

4. **Worker Notification**: Added `notify_work_available()` calls after `resume()` in both `complete_task`/`fail_task` and the bug #005 fix to ensure workers are promptly notified when work is available.

### Files Changed

- `flovyn-server/src/repository/event_repository.rs`: Added `append_with_auto_sequence` method, updated `append_batch` to use atomic sequence assignment
- `flovyn-server/src/api/grpc/task_execution.rs`: Updated `complete_task` and `fail_task` to use atomic sequence assignment and notify workers
- `flovyn-server/src/api/grpc/workflow_dispatch.rs`: Added check for new events after setting state to WAITING, deferred task creation until after events are appended
- `flovyn-server/tests/integration/workflow_tests.rs`: Added `test_parallel_task_large_batch` test (10 tasks)

### Testing

- Added integration test `test_parallel_task_large_batch` that schedules 10 tasks
- All 15 integration tests pass

### Additional Fix: Resume Check Logic

A subsequent fix was needed for the resume check after setting workflow to WAITING state. The original sequence-based check (`final_sequence > expected_final_seq`) failed in scenarios where task completions happened BETWEEN when the SDK called `get_events` and when the server fetched `existing_events` in `submit_workflow_commands`. In this case, `existing_events` already included the task completions, so the sequence comparison couldn't detect that the SDK had missed them.

The fix uses a **semantic check** instead of sequence comparison: re-fetch all events from the database and check if all scheduled tasks have corresponding completion events. If they do, but the SDK is still suspending, it must have missed the completions:

```rust
// Re-fetch events to get absolute latest state
let latest_events = self.event_repo.get_events(workflow_id).await;

// Extract task IDs from TASK_SCHEDULED and TASK_COMPLETED events
let scheduled_task_ids = /* ... extract from TASK_SCHEDULED events ... */;
let completed_task_ids = /* ... extract from TASK_COMPLETED/TASK_FAILED events ... */;

// If all scheduled tasks have completed but SDK is suspending, it missed completions
if !scheduled_task_ids.is_empty()
    && scheduled_task_ids.iter().all(|id| completed_task_ids.contains(id)) {
    // Resume immediately
}
```

This fix enables true parallel task scheduling with `join_all` to work correctly regardless of timing.
