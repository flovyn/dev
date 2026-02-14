# Implementation Plan: Agent Task Cancellation

**Design Doc:** `dev/docs/design/20251219_cancellation_support.md`
**Date:** 2026-02-13

## Overview

Implement task cancellation for agents, enabling patterns like racing tasks with auto-cancel, cancel-and-replace, and graceful handling of cancelled tasks.

## Current State

| Component | Status |
|-----------|--------|
| `TaskStatus::Cancelled` enum | ✅ Exists |
| `TaskRepository::cancel_task()` | ✅ Exists (only cancels PENDING) |
| `CancelTask` RPC handler | ❌ Returns `unimplemented()` |
| SDK `cancel_task()` method | ❌ Missing |
| `select_ok` auto-cancel losers | ❌ Missing |
| Test fixtures | ❌ Placeholders with `unimplemented!()` |

## Phase 1: Server-Side Task Cancellation RPC

### TODO

- [ ] **1.1 Implement CancelTask RPC handler**
  - File: `flovyn-server/server/src/api/grpc/task_execution.rs`
  - Find the `cancel_task` method that returns `Status::unimplemented()`
  - Implement per design doc section 1.2:
    - Parse task_execution_id
    - Get task from repository
    - Check if cancellable (PENDING or RUNNING)
    - Call `task_repo.cancel_task(id)`
    - For agent tasks: check if agent is waiting, resume if needed
  - Handle idempotency (already cancelled = success)

- [ ] **1.2 Update TaskRepository::cancel_task to handle RUNNING**
  - File: `flovyn-server/server/src/repository/task_repository.rs`
  - Current implementation only cancels PENDING tasks
  - Add support for cancelling RUNNING tasks
  - Return enum: `Cancelled`, `AlreadyTerminal`, `NotFound`

- [ ] **1.3 Add agent resume on task cancellation**
  - File: `flovyn-server/server/src/api/grpc/task_execution.rs`
  - When cancelling an agent task, check if agent is waiting for it
  - If agent waiting with `WaitForTasks`, check if condition now satisfied
  - Resume agent if appropriate

### Verification
```bash
cd flovyn-server && mise run test:integration -- cancel
```

---

## Phase 2: SDK Cancel Task API

### TODO

- [ ] **2.1 Add cancel_task to AgentContext trait**
  - File: `sdk-rust/worker-sdk/src/agent/context.rs`
  - Add method signature:
    ```rust
    async fn cancel_task(&self, task_id: Uuid) -> Result<CancelTaskResult>;
    ```
  - Define `CancelTaskResult` enum: `Cancelled`, `AlreadyCompleted`, `AlreadyFailed`, `NotFound`

- [ ] **2.2 Implement cancel_task in AgentContextImpl**
  - File: `sdk-rust/worker-sdk/src/agent/context_impl.rs`
  - Call gRPC `CancelTask` RPC
  - Handle response and errors

- [ ] **2.3 Add cancel_task to MockAgentContext**
  - File: `sdk-rust/worker-sdk/src/testing/mock_agent_context.rs`
  - Implement for testing

- [ ] **2.4 Add CancelTask to worker-core gRPC client**
  - File: `sdk-rust/worker-core/src/client/agent_dispatch.rs`
  - Add `cancel_task(task_id: Uuid)` method

### Verification
```bash
cd sdk-rust && mise run test
```

---

## Phase 3: Cancellation Combinators

### TODO

- [ ] **3.1 Add select_ok_with_cancel combinator**
  - File: `sdk-rust/worker-sdk/src/agent/context.rs` (trait)
  - File: `sdk-rust/worker-sdk/src/agent/context_impl.rs` (impl)
  - Signature:
    ```rust
    async fn select_ok_with_cancel(&self, futures: Vec<AgentTaskFutureRaw>)
        -> Result<(Value, Vec<Uuid>)>;  // Returns (winner_result, cancelled_task_ids)
    ```
  - Behavior: Wait for first success, cancel all remaining tasks

- [ ] **3.2 Add join_all_with_timeout combinator**
  - File: `sdk-rust/worker-sdk/src/agent/context.rs` (trait)
  - File: `sdk-rust/worker-sdk/src/agent/context_impl.rs` (impl)
  - Signature:
    ```rust
    async fn join_all_with_timeout(
        &self,
        futures: Vec<AgentTaskFutureRaw>,
        timeout_ms: u64,
    ) -> Result<JoinAllTimeoutResult>;
    ```
  - Behavior: Wait for all tasks or timeout, cancel remaining on timeout
  - Return completed results + cancelled task IDs

- [ ] **3.3 Update AgentTaskFutureRaw with cancel method**
  - File: `sdk-rust/worker-sdk/src/agent/future.rs`
  - Add `task_id()` getter (if not exists)
  - Consider adding `cancel()` method that takes context reference

### Verification
```bash
cd sdk-rust && mise run test
```

---

## Phase 4: Implement Test Fixtures

### TODO

- [ ] **4.1 Implement RacingTasksWithCancelAgent**
  - File: `sdk-rust/worker-sdk/tests/e2e/fixtures/agents.rs`
  - Remove `unimplemented!()` stub
  - Use `select_ok_with_cancel` to race tasks and cancel losers
  - Return winner result and cancellation info

- [ ] **4.2 Implement CancelAndReplaceAgent**
  - File: `sdk-rust/worker-sdk/tests/e2e/fixtures/agents.rs`
  - Remove `unimplemented!()` stub
  - Schedule slow task, wait briefly, cancel, schedule fast replacement
  - Verify replacement completes

- [ ] **4.3 Implement JoinAllWithCancelledHandleAgent**
  - File: `sdk-rust/worker-sdk/tests/e2e/fixtures/agents.rs`
  - Remove `unimplemented!()` stub
  - Schedule tasks, cancel one explicitly, call join_all
  - Verify cancelled task handled gracefully

- [ ] **4.4 Implement ParallelWithFailuresAgent**
  - File: `sdk-rust/worker-sdk/tests/e2e/fixtures/agents.rs`
  - Remove `unimplemented!()` stub
  - Use join_all_settled with some failing tasks
  - Process partial results

- [ ] **4.5 Implement BatchSchedulingAgent**
  - File: `sdk-rust/worker-sdk/tests/e2e/fixtures/agents.rs`
  - Remove `unimplemented!()` stub
  - Schedule batch of tasks, some with cancellation

- [ ] **4.6 Implement CancelIdempotencyAgent**
  - File: `sdk-rust/worker-sdk/tests/e2e/fixtures/agents.rs`
  - Remove `unimplemented!()` stub
  - Cancel same task multiple times, verify idempotent

### Verification
```bash
cd sdk-rust && mise run test:e2e
```

---

## Phase 5: E2E Tests

### TODO

- [ ] **5.1 Verify test_agent_racing_tasks_with_cancellation passes**
  - Should pass after implementing RacingTasksWithCancelAgent

- [ ] **5.2 Verify test_agent_cancel_and_replace passes**
  - Should pass after implementing CancelAndReplaceAgent

- [ ] **5.3 Verify test_agent_join_all_with_cancelled_handle passes**
  - Should pass after implementing JoinAllWithCancelledHandleAgent

- [ ] **5.4 Verify test_agent_parallel_with_failure passes**
  - Should pass after implementing ParallelWithFailuresAgent

- [ ] **5.5 Verify test_agent_batch_api_scheduling passes**
  - Should pass after implementing BatchSchedulingAgent

- [ ] **5.6 Verify test_agent_cancel_idempotency passes**
  - Should pass after implementing CancelIdempotencyAgent

- [ ] **5.7 Verify test_agent_racing_tasks_select passes**
  - Review existing test, may need updates

- [ ] **5.8 Verify test_agent_cancel_completed_task passes**
  - Test cancelling already-completed task returns appropriate result

### Verification
```bash
cd sdk-rust && mise run test:e2e
# All 8 currently-failing tests should pass
```

---

## Files to Modify

### flovyn-server
- `server/src/api/grpc/task_execution.rs` - Implement CancelTask RPC
- `server/src/repository/task_repository.rs` - Update cancel_task for RUNNING

### sdk-rust
- `worker-core/src/client/agent_dispatch.rs` - Add cancel_task gRPC call
- `worker-sdk/src/agent/context.rs` - Add cancel_task, new combinators
- `worker-sdk/src/agent/context_impl.rs` - Implement new methods
- `worker-sdk/src/agent/future.rs` - Add task_id getter
- `worker-sdk/src/testing/mock_agent_context.rs` - Mock implementations
- `worker-sdk/tests/e2e/fixtures/agents.rs` - Implement 6 placeholder agents

---

## Testing Commands

```bash
# Server unit + integration tests
cd flovyn-server && mise run test && mise run test:integration

# SDK tests
cd sdk-rust && mise run test

# E2E tests (requires server running)
cd sdk-rust && mise run test:e2e

# Run specific failing tests
cd sdk-rust && cargo test --test e2e test_agent_cancel -- --ignored --nocapture

# Lint all
cd flovyn-server && mise run lint
cd sdk-rust && mise run lint
```

---

## Risks

1. **Race conditions** - Task may complete between cancel check and cancel execution
   - Mitigation: Use atomic status update with WHERE clause

2. **Agent resume timing** - Agent may miss cancellation if not waiting yet
   - Mitigation: Check and resume at both task completion and agent suspension

3. **Idempotency** - Multiple cancel requests for same task
   - Mitigation: Return success for already-cancelled tasks

---

## Success Criteria

- [ ] All 8 currently-failing E2E tests pass
- [ ] No regressions in existing tests (78 passing)
- [ ] Cancel + resume works reliably (no flaky tests)
