# Bug: Agent Task Resume Race Condition

## Summary

Agents that schedule tasks via `join_all()` can get stuck in WAITING (or RUNNING) status because of race conditions between task completion and agent suspension, combined with incorrect task ID generation on resume.

## Symptoms

1. Agent schedules a task and suspends with `wait_for_tasks` metadata
2. Task completes (status=COMPLETED)
3. Agent remains in WAITING or RUNNING status - never resumes
4. Multiple tasks are created for the same agent (e.g., 5 tasks when only 1 was expected)

## Root Cause Analysis

### Problem 1: Race Condition in Task Completion Resume

**Timeline that fails:**

1. Agent is RUNNING, calls `join_all(tasks)`
2. `commit_pending_batch()` schedules the task (server creates task with PENDING status)
3. Task worker picks up and executes the task
4. Task completes - `handle_agent_task_completion()` checks `if agent.status() == WAITING`
5. Agent is still RUNNING (hasn't suspended yet) → resume is skipped
6. Agent suspends → transitions to WAITING
7. Nobody resumes the agent → stuck forever

**Code location:** `flovyn-server/server/src/api/grpc/task_execution.rs:191-256`

```rust
async fn handle_agent_task_completion(&self, agent_id: Uuid, task_id: Uuid, action: &str) {
    match self.agent_repo.get(agent_id).await {
        Ok(Some(agent)) => {
            // Only check if agent is WAITING
            if agent.status() != flovyn_core::domain::AgentStatus::Waiting {
                return;  // <-- PROBLEM: Agent might still be RUNNING
            }
            // ... resume logic
        }
        // ...
    }
}
```

### Problem 2: Task ID Changes on Each Resume

**How task IDs are generated:**

```rust
// sdk-rust/worker-sdk/src/agent/context_impl.rs:198-203
fn next_task_id(&self) -> Uuid {
    let segment = self.current_segment.load(Ordering::SeqCst);
    let seq = self.current_sequence.fetch_add(1, Ordering::SeqCst);
    let input = format!("{}-{}-{}", self.agent_execution_id, segment, seq);
    Uuid::new_v5(&Uuid::NAMESPACE_OID, input.as_bytes())
}
```

**How segment is computed on resume:**

```rust
// sdk-rust/worker-sdk/src/agent/context_impl.rs:94-97
let segment = if checkpoint_seq >= 0 {
    (checkpoint_seq + 1) as u64
} else {
    0
};
```

**Timeline:**
- First run: `checkpoint_seq=-1`, `segment=0` → task ID = `UUID_v5(agent_id-0-0)`
- Checkpoint taken: `checkpoint_seq=1`
- Agent suspends
- Resume: `checkpoint_seq=1`, `segment=2` → task ID = `UUID_v5(agent_id-2-0)` - **DIFFERENT!**

This causes new tasks to be created on each resume, since the idempotency key (task_id) is different.

## Partial Fix Attempted

Added a check in `suspend_agent` handler to check if tasks are already complete and resume immediately:

```rust
// After suspend_with_wait_condition(), check if tasks already completed
if let Some(WaitCondition::WaitForTasks(wait_for_tasks)) = &req.wait_condition {
    // ... fetch tasks and check if complete
    if should_resume {
        self.agent_repo.resume(agent_execution_id).await?;
    }
}
```

**Result:** Test is still flaky - sometimes passes, sometimes fails. The partial fix doesn't address Problem 2 (task ID changes).

## Fixes Implemented

### Fix 1: Task ID Determinism (Solution A)

Changed task ID generation to use a simple monotonically increasing counter instead of segment-based IDs:

**Before (broken):**
```rust
fn next_task_id(&self) -> Uuid {
    let segment = self.current_segment.load(Ordering::SeqCst);
    let seq = self.current_sequence.fetch_add(1, Ordering::SeqCst);
    let input = format!("{}-{}-{}", self.agent_execution_id, segment, seq);
    Uuid::new_v5(&Uuid::NAMESPACE_OID, input.as_bytes())
}
```

**After (fixed):**
```rust
fn next_task_id(&self) -> Uuid {
    let counter = self.task_counter.fetch_add(1, Ordering::SeqCst);
    let input = format!("{}:task:{}", self.agent_execution_id, counter);
    Uuid::new_v5(&Uuid::NAMESPACE_OID, input.as_bytes())
}
```

The `task_counter` is initialized from the number of existing tasks for this agent on resume, ensuring stable IDs across suspend/resume cycles.

**File:** `sdk-rust/worker-sdk/src/agent/context_impl.rs`

### Fix 2: Suspend-Time Task Completion Check (Solution B partial)

Added a check in `suspend_agent` handler to immediately resume if tasks are already complete:

```rust
// After suspend_with_wait_condition(), check if tasks already completed
if let Some(WaitCondition::WaitForTasks(wait_for_tasks)) = &req.wait_condition {
    // ... fetch tasks and check if complete
    if should_resume {
        self.agent_repo.resume(agent_execution_id).await?;
    }
}
```

**File:** `flovyn-server/server/src/api/grpc/agent_dispatch.rs`

### Fix 3: Flush Pending Entries Before Completion

Added a `flush_pending()` call before `complete_agent()` to ensure all entries created after the last checkpoint are persisted:

```rust
// In agent_worker.rs poll_and_execute():
Ok(output) => {
    // Flush any pending entries before completing.
    if let Err(e) = ctx_arc.flush_pending().await {
        warn!("Failed to flush pending entries before completion: {}", e);
    }
    self.client.complete_agent(agent_execution_id, &output).await?;
}
```

**File:** `sdk-rust/worker-sdk/src/worker/agent_worker.rs`

## Files Modified

**Server:**
- `server/src/api/grpc/agent_dispatch.rs` - suspend_agent handler with task completion check

**SDK:**
- `worker-sdk/src/agent/context_impl.rs` - Fixed task ID generation, added flush_pending()
- `worker-sdk/src/agent/context.rs` - Added flush_pending() to AgentContext trait
- `worker-sdk/src/worker/agent_worker.rs` - Call flush_pending() before complete_agent()

## Status

- [x] Problem identified
- [x] Root causes documented (2 problems)
- [x] Solution chosen
- [x] Fix implemented
- [x] Tests passing consistently (38/38 agent tests pass)
