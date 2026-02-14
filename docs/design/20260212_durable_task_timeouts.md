# Durable Task Timeouts

**Date:** 2026-02-12
**Status:** Draft
**Scope:** Agent task timeout enforcement, retry behavior, and partial completion handling

## Problem Statement

Agent tasks currently accept `timeout_ms` and `max_retries` parameters, but:

1. **Timeouts are not enforced** - `timeout_ms` is passed to the server but never checked
2. **Tasks can run forever** - No deadline tracking or automatic timeout
3. **Partial timeouts not handled** - When running parallel tasks, there's no way to get partial results if some tasks timeout
4. **No durable timeout** - `agent_join_all_with_timeout` uses local polling (not crash-safe)

## Goals

1. Server-side timeout enforcement for agent tasks
2. Automatic task failure when timeout expires
3. Proper agent wake-up on task timeout (same as task completion)
4. New combinators for partial completion scenarios
5. Retry behavior that respects timeouts

## Non-Goals

- Workflow task timeouts (already handled via timers)
- Agent execution timeouts (separate feature)
- Timeout configuration at agent definition level

## Current State

### What Exists

**SDK (`worker-sdk/src/agent/context.rs`):**
```rust
pub struct ScheduleAgentTaskOptions {
    pub queue: Option<String>,
    pub timeout: Option<Duration>,      // Passed but not enforced
    pub max_retries: Option<u32>,       // Works correctly
    pub idempotency_key: Option<String>,
}
```

**Proto (`proto/agent.proto`):**
```protobuf
message ScheduleAgentTaskHeader {
  optional int64 timeout_ms = 5;        // Stored but not used
}
```

**Database (`task_execution` table):**
- No `deadline_at` column
- No timeout tracking
- Has `last_heartbeat_at` for worker liveness

**Scheduler (`scheduler.rs`):**
- Handles workflow timers via `fire_expired_timers()`
- Handles promises via `fire_expired_promises()`
- Does NOT handle task timeouts

### Retry Behavior (Working)

```rust
// task_repository.rs - fail_with_retry()
if execution_count <= max_retries {
    // Reset to PENDING for retry
    UPDATE task_execution SET status = 'PENDING', worker_id = NULL
} else {
    // Permanently failed
    UPDATE task_execution SET status = 'FAILED'
}
```

### Agent Resume (Working)

When a task completes or fails:
```rust
// task_execution.rs - handle_agent_task_completion()
if agent.status == "WAITING" && wait_condition_matches {
    agent_repo.resume(agent_id)  // WAITING -> PENDING
}
```

## Design

### 1. Schema Changes

Add `deadline_at` column to `task_execution`:

```sql
-- Migration: YYYYMMDDHHMMSS_task_deadline.sql
ALTER TABLE task_execution
ADD COLUMN deadline_at TIMESTAMPTZ;

-- Index for scheduler queries
CREATE INDEX idx_task_deadline
ON task_execution (deadline_at)
WHERE deadline_at IS NOT NULL
  AND status IN ('PENDING', 'RUNNING');

COMMENT ON COLUMN task_execution.deadline_at IS
  'Absolute deadline for task completion. Set at task creation from timeout_ms.';
```

**Why `deadline_at` instead of `timeout_ms`:**
- Absolute timestamps are easier to query (`deadline_at < NOW()`)
- No need to track "started_at + timeout" calculations
- Consistent with promise table pattern (`timeout_at`)
- Deadline is set when task starts, not when created (timeout counts from execution start)

### 2. Task Creation Changes

**Server-side (`agent_dispatch.rs`):**
```rust
// When scheduling a task
let deadline_at = if let Some(timeout_ms) = header.timeout_ms {
    // Deadline = now + timeout (task starts immediately after creation for agents)
    Some(Utc::now() + Duration::milliseconds(timeout_ms))
} else {
    None
};

let task = TaskExecution::new_full(
    // ... existing params
    deadline_at,  // New parameter
);
```

**Alternative: Deadline from task start**
If timeout should count from when worker picks up the task:
```rust
// In find_lock_and_mark_running()
UPDATE task_execution
SET status = 'RUNNING',
    started_at = NOW(),
    deadline_at = CASE
        WHEN timeout_ms IS NOT NULL THEN NOW() + (timeout_ms || ' milliseconds')::interval
        ELSE deadline_at
    END
WHERE id = $1
```

**Recommendation:** Set deadline at creation time. This is simpler and matches user expectations - "this task should complete within 30 seconds of being scheduled."

### 3. Scheduler Changes

Add task timeout detection to scheduler loop:

**New function in `task_repository.rs`:**
```rust
/// Find tasks that have exceeded their deadline
pub async fn find_expired_tasks(&self, limit: i64) -> Result<Vec<TaskExecution>, sqlx::Error> {
    sqlx::query_as::<_, TaskExecution>(
        r#"
        SELECT * FROM task_execution
        WHERE deadline_at < NOW()
          AND status IN ('PENDING', 'RUNNING')
        ORDER BY deadline_at ASC
        LIMIT $1
        "#,
    )
    .bind(limit)
    .fetch_all(&self.pool)
    .await
}

/// Timeout a task atomically (with advisory lock to prevent races)
pub async fn timeout_task(&self, id: Uuid) -> Result<bool, sqlx::Error> {
    // Use advisory lock to prevent duplicate timeout handling across scheduler instances
    let result = sqlx::query_scalar::<_, Option<String>>(
        r#"
        WITH locked AS (
            SELECT pg_advisory_xact_lock(hashtext($1::text))
        )
        UPDATE task_execution
        SET status = 'FAILED',
            error = 'Task exceeded deadline',
            completed_at = NOW(),
            updated_at = NOW()
        WHERE id = $1
          AND status IN ('PENDING', 'RUNNING')
        RETURNING status
        "#,
    )
    .bind(id)
    .fetch_optional(&self.pool)
    .await?;

    Ok(result.is_some())
}
```

**New scheduler loop in `scheduler.rs`:**
```rust
// Add to scheduler intervals (500ms like timers)
let mut task_timeout_interval = tokio::time::interval(Duration::from_millis(500));

loop {
    tokio::select! {
        // ... existing timer/promise handling

        _ = task_timeout_interval.tick() => {
            if let Err(e) = timeout_expired_tasks(&task_repo, &agent_repo, &event_bus).await {
                tracing::error!("Error timing out expired tasks: {}", e);
            }
        }
    }
}

async fn timeout_expired_tasks(
    task_repo: &TaskRepository,
    agent_repo: &AgentExecutionRepository,
    event_bus: &EventBus,
) -> Result<(), Error> {
    let expired = task_repo.find_expired_tasks(100).await?;

    for task in expired {
        if task_repo.timeout_task(task.id).await? {
            tracing::info!(
                task_id = %task.id,
                deadline = ?task.deadline_at,
                "Task timed out"
            );

            // Resume agent if waiting for this task
            if let Some(agent_id) = task.agent_execution_id {
                handle_agent_task_completion(agent_repo, agent_id, task.id, "timeout").await?;
            }

            // Publish event for observability
            event_bus.publish(TaskTimedOutEvent {
                task_id: task.id,
                agent_execution_id: task.agent_execution_id,
                deadline_at: task.deadline_at,
            }).await;
        }
    }

    Ok(())
}
```

### 4. Timeout vs Retry Interaction

**Key Question:** Should a timed-out task be retried?

**Option A: Timeout = Permanent Failure (Recommended)**
- Timeout means the task took too long, retrying won't help
- Agent should handle the failure (maybe try a different approach)
- Simpler mental model

**Option B: Timeout = One Attempt Failed**
- Timeout counts as one failed attempt
- If retries remain, task goes back to PENDING
- Problem: Could create infinite retry loop if task always times out

**Recommendation:** Option A - timeout is permanent failure. If users want retry-on-timeout, they can implement it in the agent logic:

```rust
let result = ctx.schedule_task_with_options("slow-task", input, opts.timeout(30.secs())).await;
if let Err(FlovynError::TaskFailed { error, .. }) if error.contains("exceeded deadline") = result {
    // Retry with longer timeout
    ctx.schedule_task_with_options("slow-task", input, opts.timeout(60.secs())).await
}
```

### 5. New Combinators for Partial Completion

#### `agent_join_all_settled`

Wait for ALL tasks to reach terminal state (COMPLETED, FAILED, or timed out):

```rust
pub struct SettledResult {
    pub completed: Vec<(usize, Value)>,      // (index, result)
    pub failed: Vec<(usize, String)>,        // (index, error)
}

pub async fn agent_join_all_settled(
    ctx: &dyn AgentContext,
    handles: Vec<AgentTaskHandle>,
) -> Result<SettledResult> {
    let task_ids: Vec<Uuid> = handles.iter().map(|h| h.task_id).collect();
    let statuses = ctx.get_task_results_batch(&task_ids).await?;

    let mut completed = Vec::new();
    let mut failed = Vec::new();
    let mut pending = Vec::new();

    for (i, (handle, status)) in handles.iter().zip(statuses.iter()).enumerate() {
        match status.status.as_str() {
            "COMPLETED" => completed.push((i, parse_output(&status.output)?)),
            "FAILED" | "CANCELLED" => failed.push((i, status.error.clone().unwrap_or_default())),
            _ => pending.push(handle.task_id),
        }
    }

    if pending.is_empty() {
        return Ok(SettledResult { completed, failed });
    }

    // Suspend and wait for ALL remaining tasks
    ctx.suspend_for_tasks(&task_ids, WaitMode::All).await?;
    Err(FlovynError::AgentSuspended("Waiting for all tasks to settle".into()))
}
```

**Use case:** "Run these 5 tasks, give me all results even if some fail"

#### `agent_select_ok`

Wait for first SUCCESSFUL task (skip failures):

```rust
pub async fn agent_select_ok(
    ctx: &dyn AgentContext,
    handles: Vec<AgentTaskHandle>,
) -> Result<(usize, Value)> {
    let task_ids: Vec<Uuid> = handles.iter().map(|h| h.task_id).collect();
    let statuses = ctx.get_task_results_batch(&task_ids).await?;

    let mut all_failed = true;
    let mut first_error = None;

    for (i, (handle, status)) in handles.iter().zip(statuses.iter()).enumerate() {
        match status.status.as_str() {
            "COMPLETED" => return Ok((i, parse_output(&status.output)?)),
            "FAILED" => {
                if first_error.is_none() {
                    first_error = Some(status.error.clone().unwrap_or_default());
                }
            }
            _ => all_failed = false,  // Still pending
        }
    }

    if all_failed {
        return Err(FlovynError::AllTasksFailed(first_error.unwrap_or_default()));
    }

    // Suspend and wait for ANY task to complete
    ctx.suspend_for_tasks(&task_ids, WaitMode::Any).await?;
    Err(FlovynError::AgentSuspended("Waiting for successful task".into()))
}
```

**Use case:** "Try these 3 providers, give me the first one that succeeds"

### 6. SDK Changes

#### Update `ScheduleAgentTaskOptions`

```rust
impl ScheduleAgentTaskOptions {
    /// Set task timeout. Task will be marked as FAILED if not completed within this duration.
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = Some(timeout);
        self
    }

    /// Set max retries for task failures (NOT timeouts - timeouts are permanent).
    pub fn max_retries(mut self, retries: u32) -> Self {
        self.max_retries = Some(retries);
        self
    }
}
```

#### Update Error Types

```rust
pub enum FlovynError {
    // Existing...
    TaskFailed { task_id: Uuid, error: String },

    // New
    TaskTimedOut { task_id: Uuid, deadline: DateTime<Utc> },
    AllTasksFailed(String),
}
```

### 7. Observability

#### Events

```rust
// Published when task times out
pub struct TaskTimedOutEvent {
    pub task_id: Uuid,
    pub agent_execution_id: Option<Uuid>,
    pub kind: String,
    pub deadline_at: DateTime<Utc>,
    pub started_at: Option<DateTime<Utc>>,
}
```

#### Metrics

- `flovyn_task_timeouts_total` - Counter of timed-out tasks
- `flovyn_task_duration_seconds` - Histogram with timeout label

#### Logs

```
INFO  task_id=abc deadline=2026-02-12T10:30:00Z "Task timed out"
INFO  agent_id=xyz task_id=abc "Resuming agent after task timeout"
```

## Migration Path

### Phase 1: Schema + Basic Enforcement
1. Add `deadline_at` column to `task_execution`
2. Update task creation to set `deadline_at` from `timeout_ms`
3. Add scheduler loop to timeout expired tasks
4. Update agent resume logic to handle timeouts

### Phase 2: SDK Improvements
1. Add `agent_join_all_settled` combinator
2. Add `agent_select_ok` combinator
3. Update error types for better timeout handling

### Phase 3: Observability
1. Add timeout events to event bus
2. Add metrics for timeout tracking
3. Update UI to show timed-out tasks

## Testing Strategy

### Unit Tests
- Task creation with timeout sets correct `deadline_at`
- `find_expired_tasks` returns correct tasks
- `timeout_task` is idempotent (advisory lock prevents duplicates)

### Integration Tests
- Task times out after deadline
- Agent is resumed when task times out
- `agent_join_all_settled` returns partial results
- `agent_select_ok` skips failed tasks

### E2E Tests
- Agent schedules task with 5s timeout
- Task worker sleeps for 10s
- Scheduler times out task
- Agent resumes and handles timeout error

## Alternatives Considered

### 1. Worker-Side Timeout Enforcement
- Worker tracks deadline and self-reports failure
- **Rejected:** Not durable - if worker crashes, timeout never fires

### 2. Separate Timeout Table
- Like `task_attempt` but for timeouts
- **Rejected:** Adds complexity, single column is sufficient

### 3. Timeout as Retry Attempt
- Timeout counts as one failed attempt, retry if retries remain
- **Rejected:** Creates confusing behavior, better to let agent decide

### 4. TIMEOUT Status Instead of FAILED
- Add new `TIMEOUT` status to task_execution
- **Considered:** Could be useful for UI filtering
- **Deferred:** Can add later if needed, FAILED with error message is sufficient

## Open Questions

1. **Default timeout?** Should there be a default timeout for tasks without explicit timeout?
   - Recommendation: No default, explicit is better

2. **Timeout precision?** 500ms scheduler interval means up to 500ms delay in timeout detection
   - Acceptable for most use cases
   - Could reduce interval for latency-sensitive workloads

3. **Heartbeat interaction?** Should heartbeat extend deadline?
   - Recommendation: No, deadline is absolute
   - Worker liveness (heartbeat) is separate concern from task deadline

## References

- Promise timeout pattern: `flovyn-server/server/src/repository/promise_repository.rs`
- Timer firing pattern: `flovyn-server/server/src/repository/event_repository.rs`
- Agent resume logic: `flovyn-server/server/src/api/grpc/task_execution.rs`
