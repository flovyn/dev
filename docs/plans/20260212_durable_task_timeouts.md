# Implementation Plan: Durable Task Timeouts

**Design Doc:** `dev/docs/design/20260212_durable_task_timeouts.md`
**Date:** 2026-02-12

## Overview

Implement server-side task timeout enforcement for agent tasks, with proper scheduler integration and new SDK combinators for partial completion handling.

## Phase 1: Schema + Server-Side Timeout Enforcement ✅

### TODO

- [x] **1.1 Add migration for `deadline_at` column**
  - File: `flovyn-server/server/migrations/20260212193255_task_deadline.sql`
  - Add `deadline_at TIMESTAMPTZ` column to `task_execution`
  - Add index `idx_task_deadline` for scheduler queries

- [x] **1.2 Update TaskExecution domain model**
  - File: `flovyn-server/crates/core/src/domain/task.rs`
  - Add `deadline_at: Option<DateTime<Utc>>` field
  - Update `new_full()` constructor

- [x] **1.3 Update task repository for deadline**
  - File: `flovyn-server/server/src/repository/task_repository.rs`
  - Update `create()` to store `deadline_at`
  - Add `find_expired_tasks(limit: i64)` method
  - Add `timeout_task(id: Uuid)` method with advisory lock

- [x] **1.4 Update agent task scheduling to set deadline**
  - File: `flovyn-server/server/src/api/grpc/agent_dispatch.rs`
  - In `schedule_agent_task()`: calculate `deadline_at = now + timeout_ms`
  - Pass deadline to task creation

- [x] **1.5 Add timeout detection to scheduler**
  - File: `flovyn-server/server/src/scheduler.rs`
  - Add `task_timeout_check_interval` (500ms)
  - Add `timeout_expired_tasks()` function
  - Resume agent on task timeout

### Verification
```bash
# Run integration tests
cd flovyn-server && mise run test:integration

# Manual test: schedule task with 5s timeout, verify it times out
```

## Phase 2: SDK Combinators ✅

### TODO

- [x] **2.1 Add `agent_join_all_settled` combinator**
  - File: `sdk-rust/worker-sdk/src/agent/combinators.rs` - Added `SettledResult` type
  - File: `sdk-rust/worker-sdk/src/agent/context.rs` - Added trait method
  - File: `sdk-rust/worker-sdk/src/agent/context_impl.rs` - Implemented method
  - Returns `SettledResult { completed, failed, cancelled }` after all tasks reach terminal state
  - Does NOT fail-fast on individual failures

- [x] **2.2 Add `agent_select_ok` combinator**
  - Already implemented in `sdk-rust/worker-sdk/src/agent/context_impl.rs`
  - Returns first successful task, skipping failures
  - Only errors if ALL tasks fail

- [x] **2.3 Update error types**
  - File: `sdk-rust/worker-sdk/src/error.rs`
  - `TaskTimedOut { task_id, error }` already exists
  - `AllTasksFailed(String)` already exists

- [x] **2.4 Remove non-durable `agent_join_all_with_timeout`**
  - Not needed - this combinator never existed
  - Users should use task-level timeouts via `ScheduleAgentTaskOptions::timeout()`

### Verification
```bash
# Run SDK tests
cd sdk-rust && mise run test
```

## Phase 3: E2E Tests ✅

### TODO

- [x] **3.1 Add E2E test: task timeout triggers agent resume**
  - File: `sdk-rust/worker-sdk/tests/e2e/agent_tests.rs`
  - Test `test_server_side_task_timeout` - schedules 3 tasks with 1s timeout
  - Task worker has 5s delay (sleeps)
  - Verifies agent resumes and handles timeout via `join_all_settled`
  - All tasks end up with FAILED status (due to timeout)

- [x] **3.2 Add E2E test: `agent_join_all_settled` partial completion**
  - Test `test_agent_join_all_settled_partial_completion`
  - Schedule 3 tasks with generous timeout (tasks complete before timeout)
  - Verify `SettledResult` correctly reports all 3 completed

- [x] **3.3 Add E2E test: `agent_select_ok` skips failures**
  - Test `test_agent_select_ok_skips_failures`
  - Schedule 3 tasks: first fails, second fails, third succeeds
  - Verify agent completes and returns result from successful task
  - Also verifies `remainingTasks` count in output

### Verification
```bash
# Run E2E tests
cd sdk-rust && mise run test:e2e
```

## Phase 4: Observability (Optional)

### TODO

- [ ] **4.1 Add task timeout event**
  - Publish `TaskTimedOut` event to NATS when task times out
  - Include task_id, agent_id, deadline, started_at

- [ ] **4.2 Add metrics**
  - `flovyn_task_timeouts_total` counter
  - Label by queue, kind

## Files to Modify

### flovyn-server
- `server/migrations/YYYYMMDDHHMMSS_task_deadline.sql` (new)
- `crates/core/src/domain/task.rs`
- `server/src/repository/task_repository.rs`
- `server/src/api/grpc/agent_dispatch.rs`
- `server/src/scheduler.rs`

### sdk-rust
- `worker-sdk/src/agent/combinators.rs`
- `worker-sdk/src/error.rs`
- `worker-sdk/tests/e2e/agent_tests.rs`
- `worker-sdk/tests/e2e/fixtures/agents.rs`

## Testing Commands

```bash
# Server unit + integration tests
cd flovyn-server && mise run test && mise run test:integration

# SDK tests
cd sdk-rust && mise run test

# E2E tests (requires server running)
cd sdk-rust && mise run test:e2e

# Lint all
cd flovyn-server && mise run lint
cd sdk-rust && mise run lint
```

## Risks

1. **Scheduler load** - If many tasks have short timeouts, scheduler may have many expired tasks to process
   - Mitigation: Batch processing with LIMIT, advisory locks prevent duplicates

2. **Clock skew** - If server clocks are out of sync, timeouts may fire early/late
   - Mitigation: Use single database clock (`NOW()`) for all deadline calculations

3. **Test flakiness** - Timeout tests are timing-sensitive
   - Mitigation: Use generous timeouts in tests (5s task timeout, 30s test timeout)
