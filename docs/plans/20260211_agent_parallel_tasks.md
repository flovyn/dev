# Agent Parallel Task Support

## Overview

Enable agents to schedule multiple tasks in parallel and wait for them using `join_all` and `select` combinators, consistent with workflow execution patterns.

## Current State

- Agents can schedule tasks via `ctx.schedule_task_raw()` which immediately suspends
- Server supports `wait_for_task` (single task) in `SuspendAgentRequest`
- No support for waiting on multiple tasks simultaneously

## Goal

Support parallel task patterns in agents:
```rust
// Schedule multiple tasks (non-blocking)
let task1 = ctx.schedule_task_handle("task-a", input1);
let task2 = ctx.schedule_task_handle("task-b", input2);
let task3 = ctx.schedule_task_handle("task-c", input3);

// Wait for all (like workflow join_all)
let results = ctx.join_all(vec![task1, task2, task3]).await?;

// Or wait for first (like workflow select)
let (index, result) = ctx.select(vec![task1, task2]).await?;
```

## Schema Changes

### Proto Changes (`agent.proto`)

```protobuf
// Add to SuspendAgentRequest oneof
message SuspendAgentRequest {
  string agent_execution_id = 1;

  oneof wait_condition {
    string wait_for_signal = 2;
    string wait_for_task = 4;           // Single task (existing)
    WaitForTasks wait_for_tasks = 5;    // Multiple tasks (NEW)
  }

  optional string reason = 3;
}

// New message for multi-task waiting
message WaitForTasks {
  repeated string task_ids = 1;
  WaitMode mode = 2;
}

enum WaitMode {
  WAIT_MODE_UNSPECIFIED = 0;
  WAIT_MODE_ALL = 1;   // Resume when ALL tasks complete
  WAIT_MODE_ANY = 2;   // Resume when ANY task completes
}

// =============================================================================
// Batch APIs for Performance
// =============================================================================

// Batch task status check (required for parallel tasks)
rpc GetAgentTaskResults(GetAgentTaskResultsRequest) returns (GetAgentTaskResultsResponse);

message GetAgentTaskResultsRequest {
  string agent_execution_id = 1;
  repeated string task_execution_ids = 2;
}

message GetAgentTaskResultsResponse {
  repeated TaskResultEntry results = 1;
}

message TaskResultEntry {
  string task_execution_id = 1;
  string status = 2;              // PENDING, RUNNING, COMPLETED, FAILED, CANCELLED
  optional bytes output = 3;       // If COMPLETED
  optional string error = 4;       // If FAILED
}

// Batch task scheduling (optional optimization)
rpc ScheduleAgentTasks(stream ScheduleAgentTasksChunk) returns (ScheduleAgentTasksResponse);

message ScheduleAgentTasksChunk {
  oneof chunk {
    ScheduleAgentTasksBatchHeader header = 1;
    ScheduleAgentTaskEntry task_entry = 2;
  }
}

message ScheduleAgentTasksBatchHeader {
  string agent_execution_id = 1;
  optional string queue = 2;
}

message ScheduleAgentTaskEntry {
  string task_kind = 1;
  bytes input = 2;
  optional string idempotency_key = 3;
  optional int32 max_retries = 4;
  optional int64 timeout_ms = 5;
}

message ScheduleAgentTasksResponse {
  repeated ScheduleTaskResultEntry results = 1;
}

message ScheduleTaskResultEntry {
  string task_execution_id = 1;
  bool idempotency_key_used = 2;
  bool idempotency_key_new = 3;
}
```

### Database Changes

No schema changes needed. The `metadata` JSONB field on `agent_execution` already supports arbitrary data:
```json
{
  "wait_for_tasks": ["task-id-1", "task-id-2", "task-id-3"],
  "wait_mode": "ALL"
}
```

### Performance: gRPC Call Counts

| Scenario | Without Batch | With Batch |
|----------|---------------|------------|
| 10 parallel tasks | ~30 calls | 4 calls |
| 100 parallel tasks | ~300 calls | 4 calls |

Batch APIs reduce O(n) to O(1) for status checks.

## Implementation Phases

### Phase 1: Proto and Server Foundation ✅ COMPLETED

**TODO:**
- [x] Add `WaitForTasks` message and `WaitMode` enum to `agent.proto`
- [x] Add `wait_for_tasks` to `SuspendAgentRequest` oneof
- [x] Add `GetAgentTaskResults` batch RPC (required for performance)
- [x] Add `CancelAgentTask` RPC for task cancellation
- [x] Update `suspend_agent` in `agent_dispatch.rs` to handle `wait_for_tasks`
- [x] Implement `get_agent_task_results` batch handler
- [x] Add `get_by_ids` batch method to `TaskRepository`
- [x] Add integration tests for multi-task suspension (ALL and ANY modes)
- [x] Add integration tests for batch status check
- [x] Add integration tests for task cancellation
- [x] Add `ScheduleAgentTasks` batch RPC

### Phase 2: Server Resume Logic ✅ COMPLETED

**TODO:**
- [x] Update task completion handler in `task_execution.rs` to check multi-task wait conditions
- [x] Implement `WAIT_MODE_ALL` logic: only resume when all tasks complete
- [x] Implement `WAIT_MODE_ANY` logic: resume on first task completion
- [x] Add helper method `should_resume_agent_for_multi_task()`
- [x] Optimize: batch query task statuses in one SQL call
- [x] Add integration tests for agent resume with multi-task conditions

### Phase 3: SDK Client Layer ✅ COMPLETED

**TODO:**
- [x] Add `suspend_agent_for_tasks()` method to `AgentDispatch` client
- [x] Add `get_task_results_batch()` method for batch status check
- [x] Add `schedule_tasks_batch()` method
- [x] Add `WaitMode` enum to SDK
- [x] Update proto generation in SDK
- [ ] Add unit tests for new client methods (deferred - tested via E2E in Phase 5)

### Phase 4: SDK Agent Context API ✅ COMPLETED

Note: Implemented using `AgentTaskHandle` + combinators instead of `std::future::Future`,
which is more appropriate for checkpoint-based agents.

**TODO:**
- [x] Add `AgentTaskHandle` struct (task ID + kind + index)
- [x] Add `schedule_task_handle()` method - returns `AgentTaskHandle` (non-blocking)
- [x] Add `agent_join_all()` combinator - batch check, suspend with WaitMode::All
- [x] Add `agent_select()` combinator - batch check, suspend with WaitMode::Any
- [x] Add `agent_join_all_outcomes()` for collecting all outcomes (no fail-fast)
- [x] Add `TaskOutcome` enum (Completed, Failed, Cancelled, Pending)
- [x] Ensure combinators use batch API internally (get_task_results_batch)
- [x] Keep existing `schedule_task_raw()` for simple single-task use case
- [x] Add idempotency key support via scheduled_task_counter

### Phase 5: E2E Integration Tests ✅ COMPLETED

**TODO:**
- [x] `test_agent_parallel_tasks_join_all` - Basic parallel with join_all
- [ ] `test_agent_fan_out_fan_in` - Fan-out/fan-in pattern (deferred - covered by join_all)
- [x] `test_agent_racing_tasks_select` - First to complete wins
- [x] `test_agent_parallel_large_batch` - Large batch (10 tasks)
- [x] `test_agent_parallel_with_failure` - One task fails in batch, agent handles gracefully
- [ ] `test_agent_parallel_idempotency` - Idempotency keys work correctly (covered by existing tests)
- [x] `test_agent_mixed_parallel_sequential` - Mix of parallel and sequential tasks
- [x] `test_concurrent_agents_parallel_tasks` - Multiple agents with parallel tasks
- [x] `test_agent_batch_api_scheduling` - Verify batch scheduling API works correctly

---

## Detailed Design

### AgentTaskFuture (implements std::future::Future)

```rust
/// Future representing a scheduled task.
/// Implements Future for compatibility with workflow combinators.
pub struct AgentTaskFuture {
    task_id: Uuid,
    task_kind: String,
    index: usize,  // For ordering in join_all results
    ctx: Weak<AgentContextImpl>,  // Reference to context for status checks
    completed: Option<Result<Value>>,  // Cached result once complete
}

impl AgentTaskFuture {
    pub fn task_id(&self) -> Uuid {
        self.task_id
    }

    pub fn task_kind(&self) -> &str {
        &self.task_kind
    }
}

// Implement Future trait for compatibility with join_all/select
impl Future for AgentTaskFuture {
    type Output = Result<Value>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.get_mut();

        // Return cached result if already complete
        if let Some(result) = this.completed.take() {
            return Poll::Ready(result);
        }

        // Check is done via batch API in combinator, not here
        // Individual poll just checks local state set by combinator
        Poll::Pending
    }
}

// Mark as Unpin for combinator compatibility
impl Unpin for AgentTaskFuture {}
```

### AgentContext API Extensions

```rust
#[async_trait]
pub trait AgentContext {
    // Existing (blocking) - unchanged for backwards compatibility
    async fn schedule_task_raw(&self, kind: &str, input: Value) -> Result<Value>;

    // New (non-blocking) - schedules task, returns Future
    async fn schedule_task(&self, kind: &str, input: Value) -> Result<AgentTaskFuture>;

    // With options
    async fn schedule_task_with_options(
        &self,
        kind: &str,
        input: Value,
        options: ScheduleTaskOptions,
    ) -> Result<AgentTaskFuture>;
}

// Reuse workflow combinators - they work with any Future
use flovyn_worker_sdk::workflow::combinators::{join_all, select, join_n};
```

### Implementation Flow

#### schedule_task()
1. Generate stable idempotency key based on `scheduled_task_counter`
2. Call `ScheduleAgentTask` gRPC (or batch via `ScheduleAgentTasks`)
3. Increment counter
4. Return `AgentTaskFuture` with task_id (don't suspend yet)

#### join_all() with AgentTaskFutures

The combinator needs agent-specific handling. We wrap the workflow combinator:

```rust
/// Agent-aware join_all that uses batch API
pub async fn agent_join_all(
    ctx: &dyn AgentContext,
    futures: Vec<AgentTaskFuture>,
) -> Result<Vec<Value>> {
    if futures.is_empty() {
        return Ok(vec![]);
    }

    let task_ids: Vec<Uuid> = futures.iter().map(|f| f.task_id()).collect();

    loop {
        // Batch fetch all statuses in ONE call
        let statuses = ctx.get_task_results_batch(&task_ids).await?;

        let mut results: Vec<Option<Value>> = vec![None; futures.len()];
        let mut all_complete = true;

        for (i, status) in statuses.iter().enumerate() {
            match status {
                TaskStatus::Completed(v) => results[i] = Some(v.clone()),
                TaskStatus::Failed(e) => return Err(FlovynError::TaskFailed(e.clone())),
                TaskStatus::Cancelled => return Err(FlovynError::TaskCancelled),
                TaskStatus::Pending | TaskStatus::Running => all_complete = false,
            }
        }

        if all_complete {
            return Ok(results.into_iter().map(|r| r.unwrap()).collect());
        }

        // Not all done - checkpoint and suspend
        ctx.checkpoint_current_state().await?;
        ctx.suspend_for_tasks(&task_ids, WaitMode::All).await?;

        // Agent will be resumed here after tasks complete
        // Loop continues to check statuses again
    }
}
```

#### select() with AgentTaskFutures

```rust
/// Agent-aware select that uses batch API
pub async fn agent_select(
    ctx: &dyn AgentContext,
    futures: Vec<AgentTaskFuture>,
) -> Result<(usize, Value)> {
    if futures.is_empty() {
        return Err(FlovynError::InvalidArgument("select requires at least one future"));
    }

    let task_ids: Vec<Uuid> = futures.iter().map(|f| f.task_id()).collect();

    loop {
        // Batch fetch all statuses
        let statuses = ctx.get_task_results_batch(&task_ids).await?;

        // Return first completed
        for (i, status) in statuses.iter().enumerate() {
            match status {
                TaskStatus::Completed(v) => return Ok((i, v.clone())),
                TaskStatus::Failed(e) => return Err(FlovynError::TaskFailed(e.clone())),
                _ => continue,
            }
        }

        // None complete yet - checkpoint and suspend
        ctx.checkpoint_current_state().await?;
        ctx.suspend_for_tasks(&task_ids, WaitMode::Any).await?;

        // Agent will be resumed here after any task completes
    }
}
```

### Batch API Implementation (Server)

```rust
// In agent_dispatch.rs
async fn get_agent_task_results(
    &self,
    request: GetAgentTaskResultsRequest,
) -> Result<GetAgentTaskResultsResponse> {
    let agent_id: Uuid = request.agent_execution_id.parse()?;
    let task_ids: Vec<Uuid> = request.task_execution_ids
        .iter()
        .map(|id| id.parse())
        .collect::<Result<_, _>>()?;

    // Single SQL query for all tasks
    let tasks = self.task_repo.get_batch(&task_ids).await?;

    // Verify all tasks belong to this agent
    for task in &tasks {
        if task.agent_execution_id != Some(agent_id) {
            return Err(Status::permission_denied("Task not owned by agent"));
        }
    }

    let results = tasks.iter().map(|task| TaskResultEntry {
        task_execution_id: task.id.to_string(),
        status: task.status.to_string(),
        output: task.output.clone(),
        error: task.error.clone(),
    }).collect();

    Ok(GetAgentTaskResultsResponse { results })
}
```

### Server Resume Logic

In `task_execution.rs` when task completes:

```rust
// Check if agent is waiting for multiple tasks
if let Some(wait_tasks) = metadata.get("wait_for_tasks") {
    let task_ids: Vec<String> = serde_json::from_value(wait_tasks)?;
    let wait_mode = metadata.get("wait_mode").and_then(|m| m.as_str()).unwrap_or("ALL");

    match wait_mode {
        "ALL" => {
            // Check if ALL tasks are complete
            let all_complete = check_all_tasks_complete(&task_ids).await?;
            if all_complete {
                agent_repo.resume(agent_id).await?;
            }
        }
        "ANY" => {
            // Resume immediately (this task just completed)
            agent_repo.resume(agent_id).await?;
        }
    }
}
```

---

## Test Fixtures

### Test Agents

```rust
use flovyn_worker_sdk::agent::combinators::{agent_join_all, agent_select};

/// Agent that schedules multiple tasks in parallel using join_all
struct ParallelTasksAgent;

#[async_trait]
impl DynamicAgent for ParallelTasksAgent {
    fn kind(&self) -> &str { "parallel-tasks-agent" }

    async fn execute(&self, ctx: &dyn AgentContext, input: DynamicAgentInput) -> Result<DynamicAgentOutput> {
        let items: Vec<String> = input.get("items")
            .and_then(|v| v.as_array())
            .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
            .unwrap_or_else(|| vec!["a".into(), "b".into(), "c".into()]);

        // Schedule all tasks (non-blocking) - returns Vec<AgentTaskFuture>
        let mut futures = Vec::new();
        for item in &items {
            let future = ctx.schedule_task("process-item", json!({"item": item})).await?;
            futures.push(future);
        }

        // Wait for all using agent-aware combinator
        let results = agent_join_all(ctx, futures).await?;

        let mut output = DynamicAgentOutput::new();
        output.insert("itemCount".to_string(), json!(items.len()));
        output.insert("results".to_string(), Value::Array(results));
        Ok(output)
    }
}

/// Agent that races tasks using select
struct RacingTasksAgent;

#[async_trait]
impl DynamicAgent for RacingTasksAgent {
    fn kind(&self) -> &str { "racing-tasks-agent" }

    async fn execute(&self, ctx: &dyn AgentContext, input: DynamicAgentInput) -> Result<DynamicAgentOutput> {
        let primary_delay = input.get("primaryDelayMs").and_then(|v| v.as_u64()).unwrap_or(2000);
        let fallback_delay = input.get("fallbackDelayMs").and_then(|v| v.as_u64()).unwrap_or(500);

        // Schedule both tasks
        let primary = ctx.schedule_task("fetch-data", json!({
            "source": "primary",
            "delay_ms": primary_delay
        })).await?;

        let fallback = ctx.schedule_task("fetch-data", json!({
            "source": "fallback",
            "delay_ms": fallback_delay
        })).await?;

        // Race - first to complete wins
        let (winner_index, result) = agent_select(ctx, vec![primary, fallback]).await?;

        let mut output = DynamicAgentOutput::new();
        output.insert("winnerIndex".to_string(), json!(winner_index));
        output.insert("winner".to_string(), result);
        Ok(output)
    }
}

/// Agent that does fan-out/fan-in with result aggregation
struct FanOutFanInAgent;

#[async_trait]
impl DynamicAgent for FanOutFanInAgent {
    fn kind(&self) -> &str { "fan-out-fan-in-agent" }

    async fn execute(&self, ctx: &dyn AgentContext, input: DynamicAgentInput) -> Result<DynamicAgentOutput> {
        let items: Vec<String> = input.get("items")
            .and_then(|v| v.as_array())
            .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
            .unwrap_or_else(|| vec!["apple".into(), "banana".into(), "cherry".into()]);

        ctx.append_entry(EntryRole::Assistant, &json!({"text": "Starting fan-out..."})).await?;

        // Fan-out: schedule all processing tasks
        let mut futures = Vec::new();
        for item in &items {
            let future = ctx.schedule_task("process-item", json!({"item": item})).await?;
            futures.push(future);
        }

        // Checkpoint before waiting
        ctx.checkpoint(&json!({"phase": "fan-out-complete", "taskCount": items.len()})).await?;

        // Fan-in: wait for all results
        let results = agent_join_all(ctx, futures).await?;

        // Aggregate results
        let processed: Vec<String> = results.iter()
            .filter_map(|r| r.get("processed").and_then(|v| v.as_str()).map(String::from))
            .collect();

        ctx.append_entry(EntryRole::Assistant, &json!({"text": "Fan-in complete"})).await?;

        let mut output = DynamicAgentOutput::new();
        output.insert("inputCount".to_string(), json!(items.len()));
        output.insert("outputCount".to_string(), json!(processed.len()));
        output.insert("processedItems".to_string(), json!(processed));
        Ok(output)
    }
}

/// Agent with mixed parallel and sequential tasks
struct MixedParallelAgent;

#[async_trait]
impl DynamicAgent for MixedParallelAgent {
    fn kind(&self) -> &str { "mixed-parallel-agent" }

    async fn execute(&self, ctx: &dyn AgentContext, input: DynamicAgentInput) -> Result<DynamicAgentOutput> {
        let mut output = DynamicAgentOutput::new();

        // Phase 1: Two parallel tasks
        let task1 = ctx.schedule_task("process-item", json!({"item": "phase1-a"})).await?;
        let task2 = ctx.schedule_task("process-item", json!({"item": "phase1-b"})).await?;
        let phase1_results = agent_join_all(ctx, vec![task1, task2]).await?;
        output.insert("phase1".to_string(), Value::Array(phase1_results));

        ctx.checkpoint(&json!({"phase": 1})).await?;

        // Phase 2: Sequential task
        let phase2_result = ctx.schedule_task_raw("slow-operation", json!({"op": "sequential"})).await?;
        output.insert("phase2".to_string(), phase2_result);

        ctx.checkpoint(&json!({"phase": 2})).await?;

        // Phase 3: Three parallel tasks
        let task3 = ctx.schedule_task("process-item", json!({"item": "phase3-a"})).await?;
        let task4 = ctx.schedule_task("process-item", json!({"item": "phase3-b"})).await?;
        let task5 = ctx.schedule_task("process-item", json!({"item": "phase3-c"})).await?;
        let phase3_results = agent_join_all(ctx, vec![task3, task4, task5]).await?;
        output.insert("phase3".to_string(), Value::Array(phase3_results));

        output.insert("success".to_string(), json!(true));
        Ok(output)
    }
}
```

### Test Tasks

```rust
/// Task that processes an item (fast)
struct ProcessItemTask;

#[async_trait]
impl DynamicTask for ProcessItemTask {
    fn kind(&self) -> &str { "process-item" }

    async fn execute(&self, input: DynamicTaskInput, _ctx: &dyn TaskContext) -> Result<DynamicTaskOutput> {
        let item = input.get("item").and_then(|v| v.as_str()).unwrap_or("unknown");
        let mut output = DynamicTaskOutput::new();
        output.insert("processed".to_string(), json!(format!("processed:{}", item)));
        Ok(output)
    }
}

/// Task that fetches data with configurable delay (for racing tests)
struct FetchDataTask;

#[async_trait]
impl DynamicTask for FetchDataTask {
    fn kind(&self) -> &str { "fetch-data" }

    async fn execute(&self, input: DynamicTaskInput, _ctx: &dyn TaskContext) -> Result<DynamicTaskOutput> {
        let source = input.get("source").and_then(|v| v.as_str()).unwrap_or("unknown");
        let delay_ms = input.get("delay_ms").and_then(|v| v.as_u64()).unwrap_or(100);

        // Simulate network delay
        tokio::time::sleep(Duration::from_millis(delay_ms)).await;

        let mut output = DynamicTaskOutput::new();
        output.insert("source".to_string(), json!(source));
        output.insert("data".to_string(), json!(format!("data-from-{}", source)));
        Ok(output)
    }
}

/// Task that simulates slow operation
struct SlowOperationTask;

#[async_trait]
impl DynamicTask for SlowOperationTask {
    fn kind(&self) -> &str { "slow-operation" }

    async fn execute(&self, input: DynamicTaskInput, _ctx: &dyn TaskContext) -> Result<DynamicTaskOutput> {
        let op = input.get("op").and_then(|v| v.as_str()).unwrap_or("default");
        let delay_ms = input.get("delay_ms").and_then(|v| v.as_u64()).unwrap_or(1000);

        tokio::time::sleep(Duration::from_millis(delay_ms)).await;

        let mut output = DynamicTaskOutput::new();
        output.insert("op".to_string(), json!(op));
        output.insert("completed".to_string(), json!(true));
        Ok(output)
    }
}
```

---

## Integration Test Details

### test_agent_parallel_tasks_join_all

```rust
#[tokio::test]
async fn test_agent_parallel_tasks_join_all() {
    // Setup: ParallelTasksAgent + ProcessItemTask
    // Input: {"items": ["a", "b", "c"]}
    // Expected:
    //   - Agent schedules 3 tasks in parallel
    //   - Agent suspends with wait_for_tasks (mode=ALL)
    //   - All 3 tasks complete
    //   - Agent resumes and returns all results
    // Verify:
    //   - Output has 3 results
    //   - All items processed correctly
    //   - Agent metadata had wait_for_tasks with 3 task IDs
}
```

### test_agent_racing_tasks_select

```rust
#[tokio::test]
async fn test_agent_racing_tasks_select() {
    // Setup: RacingTasksAgent + FetchDataTask (with different delays)
    // Input: primary has 2s delay, fallback has 500ms delay
    // Expected:
    //   - Agent schedules 2 tasks
    //   - Agent suspends with wait_for_tasks (mode=ANY)
    //   - Fallback completes first
    //   - Agent resumes with fallback result
    // Verify:
    //   - winner_index is 1 (fallback)
    //   - Result is from fallback task
}
```

### test_agent_parallel_with_failure

```rust
#[tokio::test]
async fn test_agent_parallel_with_failure() {
    // Setup: Agent schedules 3 tasks, middle one fails
    // Expected:
    //   - Agent schedules 3 tasks
    //   - Task 2 fails
    //   - Agent resumes with error
    // Verify:
    //   - Agent status is COMPLETED (or FAILED depending on error handling)
    //   - Error message mentions failed task
}
```

### test_agent_parallel_large_batch

```rust
#[tokio::test]
async fn test_agent_parallel_large_batch() {
    // Setup: Agent schedules 10 tasks
    // Expected:
    //   - All 10 tasks scheduled
    //   - Agent suspends with wait_for_tasks
    //   - All tasks complete
    //   - Agent returns 10 results
    // Verify:
    //   - Performance is reasonable (parallel, not sequential)
    //   - All results present and correct
}
```

### test_agent_parallel_idempotency

```rust
#[tokio::test]
async fn test_agent_parallel_idempotency() {
    // Setup: Agent schedules 3 parallel tasks, crashes after scheduling
    // Expected:
    //   - Agent schedules 3 tasks
    //   - Simulated crash/restart
    //   - On resume, idempotency keys return same tasks
    //   - No duplicate tasks created
    // Verify:
    //   - Only 3 task executions exist
    //   - Same task IDs returned on retry
}
```

### test_concurrent_agents_parallel_tasks

```rust
#[tokio::test]
async fn test_concurrent_agents_parallel_tasks() {
    // Setup: 3 agents each scheduling 3 parallel tasks (9 total)
    // Expected:
    //   - All agents start
    //   - Each schedules 3 tasks
    //   - No cross-talk between agents
    //   - Each agent completes with its own results
    // Verify:
    //   - 9 task executions total
    //   - Each agent gets correct results
}
```

---

## Checkpointing and Resume Behavior

### Checkpoint State for Parallel Tasks

When agent suspends with multiple pending tasks, checkpoint includes:
```json
{
  "user_state": { /* agent's custom state */ },
  "pending_tasks": {
    "futures": [
      {"task_id": "uuid-1", "kind": "fetch-data", "index": 0},
      {"task_id": "uuid-2", "kind": "fetch-data", "index": 1},
      {"task_id": "uuid-3", "kind": "process-item", "index": 2}
    ],
    "wait_mode": "ALL",
    "scheduled_task_counter": 5  // For idempotency on resume
  }
}
```

### Resume Flow

1. Agent resumes after task(s) complete
2. Load checkpoint state
3. Reconstruct `AgentTaskFuture` objects from checkpoint
4. Call `get_task_results_batch()` to get all statuses in one call
5. Continue based on wait mode:
   - `ALL`: If all complete, return results; if any still running, re-suspend
   - `ANY`: Return first completed result

### Idempotency Across Suspensions

Critical: Task futures must map to same tasks after resume.

```rust
// First execution
let task1 = ctx.schedule_task("task-a", input).await?;  // counter=5, idempotency_key="agent:5"
let task2 = ctx.schedule_task("task-b", input).await?;  // counter=6, idempotency_key="agent:6"
// Suspends...

// After resume - same code runs again from checkpoint
let task1 = ctx.schedule_task("task-a", input).await?;  // counter=5, same key -> returns existing task
let task2 = ctx.schedule_task("task-b", input).await?;  // counter=6, same key -> returns existing task
// No duplicate tasks created
```

### Cancelled Tasks After Resume

If agent cancelled a task before suspension, on resume:
- Task status is CANCELLED in batch status check
- `AgentTaskFuture` reflects cancelled state
- `agent_join_all` with cancelled future fails appropriately
- Use `agent_join_all_skip_cancelled` to ignore cancelled tasks

### Crash Recovery

If agent crashes after scheduling but before suspending:
1. On restart, agent runs from last checkpoint
2. `schedule_task()` with same idempotency key returns existing task
3. No duplicate tasks created
4. Agent continues normally with existing task futures

---

## Migration Notes

- Existing agents using `schedule_task_raw()` continue to work unchanged
- New parallel APIs are additive
- Proto changes are backwards compatible (new oneof variant)
- No database migrations needed

## Performance Considerations

- `WAIT_MODE_ALL`: Server must check all task statuses on each task completion
- Consider caching task statuses or using batch queries
- For large batches (50+ tasks), may need optimization

## Task Cancellation

### Use Cases

1. **Timeout**: Agent waits too long, wants to cancel all pending tasks
2. **Select winner**: After `select()` returns, cancel remaining tasks
3. **User cancellation**: External signal tells agent to abort
4. **Partial cancellation**: Cancel one slow task while keeping others
5. **Cancel and replace**: Cancel a slow task, schedule a faster alternative
6. **Graceful degradation**: Cancel optional tasks, proceed with required ones

### Schema Changes for Cancellation

```protobuf
// Add to AgentDispatch service
rpc CancelAgentTask(CancelAgentTaskRequest) returns (CancelAgentTaskResponse);

message CancelAgentTaskRequest {
  string agent_execution_id = 1;  // For authorization
  string task_execution_id = 2;
  optional string reason = 3;
}

message CancelAgentTaskResponse {
  bool cancelled = 1;
  string status = 2;  // Final status: CANCELLED, COMPLETED, FAILED (if already done)
}
```

### SDK API for Cancellation

```rust
#[async_trait]
pub trait AgentContext {
    // ... existing methods ...

    // Cancel a specific task by future reference
    async fn cancel_task(&self, future: &AgentTaskFuture) -> Result<CancelResult>;

    // Cancel multiple tasks
    async fn cancel_tasks(&self, futures: &[AgentTaskFuture]) -> Result<Vec<CancelResult>>;
}

/// Result of a cancellation attempt
pub enum CancelResult {
    Cancelled,           // Successfully cancelled
    AlreadyCompleted(Value),  // Task finished before cancel arrived
    AlreadyFailed(String),    // Task failed before cancel arrived
    AlreadyCancelled,    // Was already cancelled
}
```

### Implementation

#### AgentTaskFuture with Cancellation State

```rust
pub struct AgentTaskFuture {
    task_id: Uuid,
    task_kind: String,
    index: usize,
    ctx: Weak<AgentContextImpl>,
    state: AtomicU8,  // 0=pending, 1=completed, 2=failed, 3=cancelled
    result: UnsafeCell<Option<Result<Value>>>,
}

impl AgentTaskFuture {
    pub fn is_cancelled(&self) -> bool {
        self.state.load(Ordering::SeqCst) == 3
    }

    pub fn is_done(&self) -> bool {
        self.state.load(Ordering::SeqCst) != 0
    }
}
```

#### Select with Auto-Cancel Option

```rust
/// Select with auto-cancel of remaining tasks (default behavior)
pub async fn agent_select(
    ctx: &dyn AgentContext,
    futures: Vec<AgentTaskFuture>,
) -> Result<(usize, Value)> {
    agent_select_impl(ctx, futures, true).await
}

/// Select without auto-cancel (caller manages remaining tasks)
pub async fn agent_select_no_cancel(
    ctx: &dyn AgentContext,
    futures: Vec<AgentTaskFuture>,
) -> Result<(usize, Value, Vec<AgentTaskFuture>)> {
    let (index, result) = agent_select_impl(ctx, futures.clone(), false).await?;
    let remaining: Vec<_> = futures.into_iter()
        .enumerate()
        .filter(|(i, _)| *i != index)
        .map(|(_, f)| f)
        .collect();
    Ok((index, result, remaining))
}

// Usage:
let task1 = ctx.schedule_task("fast-task", input1).await?;
let task2 = ctx.schedule_task("slow-task", input2).await?;

// Option 1: Auto-cancel losers
let (winner, result) = agent_select(ctx, vec![task1, task2]).await?;

// Option 2: Keep losers running, cancel manually later
let (winner, result, remaining) = agent_select_no_cancel(ctx, vec![task1, task2]).await?;
for task in remaining {
    ctx.cancel_task(&task).await?;
}
```

#### Timeout with Cancellation

```rust
use flovyn_worker_sdk::agent::combinators::agent_join_all_with_timeout;

// Parallel tasks with timeout
let task1 = ctx.schedule_task("task-a", input1).await?;
let task2 = ctx.schedule_task("task-b", input2).await?;

match agent_join_all_with_timeout(ctx, vec![task1, task2], Duration::from_secs(30)).await {
    Ok(results) => {
        // All completed in time
    }
    Err(FlovynError::Timeout { completed, pending }) => {
        // Timeout occurred
        // - completed: Vec<(usize, Value)> - tasks that finished
        // - pending: Vec<AgentTaskFuture> - tasks still running (auto-cancelled)
    }
}
```

### Server-Side Cancellation Logic

```rust
// In task_execution.rs
async fn cancel_task(
    &self,
    request: CancelAgentTaskRequest,
) -> Result<CancelAgentTaskResponse> {
    let task = self.task_repo.get(task_id).await?;

    // Verify agent owns this task
    if task.agent_execution_id != Some(agent_id) {
        return Err(Status::permission_denied("Task not owned by agent"));
    }

    // Can only cancel PENDING or RUNNING tasks
    match task.status {
        TaskStatus::Pending | TaskStatus::Running => {
            self.task_repo.cancel(task_id, reason).await?;
            Ok(CancelAgentTaskResponse {
                cancelled: true,
                status: "CANCELLED".into(),
            })
        }
        status => {
            // Already completed/failed - can't cancel
            Ok(CancelAgentTaskResponse {
                cancelled: false,
                status: status.to_string(),
            })
        }
    }
}
```

### Additional Integration Tests for Cancellation

**TODO:**
- [ ] `test_agent_cancel_task` - Cancel a single running task (deferred - already covered by select_with_cancel)
- [x] `test_agent_select_cancels_remaining` - Select auto-cancels losers (covered by `test_agent_racing_tasks_with_cancellation`)
- [x] `test_agent_timeout_cancels_all` - Timeout cancels all pending tasks
- [x] `test_agent_timeout_partial_completion` - Timeout with partial completion
- [x] `test_agent_cancel_completed_task` - Cancel already-completed task (no-op)
- [x] `test_agent_cancel_unauthorized` - Can't cancel task from different agent (covered by server integration test `test_agent_cancel_task_wrong_agent`)

### Test: test_agent_select_cancels_remaining

```rust
#[tokio::test]
async fn test_agent_select_cancels_remaining() {
    // Setup: Agent schedules 2 tasks with different delays
    // Task 1: 500ms (fast)
    // Task 2: 5000ms (slow)

    // Agent calls select() - Task 1 wins
    // Task 2 should be cancelled

    // Verify:
    // - Task 1 status: COMPLETED
    // - Task 2 status: CANCELLED
    // - Agent completes with Task 1 result
}
```

### Test: test_agent_timeout_cancels_all

```rust
#[tokio::test]
async fn test_agent_timeout_cancels_all() {
    // Setup: Agent schedules 3 slow tasks (each 10s)
    // Agent calls join_all_with_timeout(handles, 2s)

    // Timeout occurs after 2s
    // All 3 tasks should be cancelled

    // Verify:
    // - All task statuses: CANCELLED
    // - Agent receives timeout error
    // - Agent can handle timeout gracefully
}
```

---

## Advanced Cancellation Scenarios

### Scenario 1: Cancel One Task While Waiting for Others

```rust
use flovyn_worker_sdk::agent::combinators::agent_join_all_with_individual_timeouts;

// Agent needs results from 3 APIs, but one is slow
let api1 = ctx.schedule_task("fetch-api", json!({"source": "fast-1"})).await?;
let api2 = ctx.schedule_task("fetch-api", json!({"source": "slow"})).await?;
let api3 = ctx.schedule_task("fetch-api", json!({"source": "fast-2"})).await?;

// Wait with per-task timeout tracking
let results = agent_join_all_with_individual_timeouts(ctx, vec![
    (api1, Duration::from_secs(5)),
    (api2, Duration::from_secs(2)),  // Short timeout for slow API
    (api3, Duration::from_secs(5)),
]).await;

// Results: Vec<TaskOutcome>
// - api1: Completed(result)
// - api2: Cancelled (timed out)
// - api3: Completed(result)
```

### Scenario 2: Cancel and Replace Strategy

```rust
use flovyn_worker_sdk::agent::combinators::agent_wait_with_timeout;

// Try primary source, if too slow, cancel and try fallback
let primary = ctx.schedule_task("fetch-data", json!({"source": "primary"})).await?;

// Wait up to 2 seconds for single task
match agent_wait_with_timeout(ctx, primary, Duration::from_secs(2)).await {
    Ok(result) => {
        // Primary succeeded in time
        return Ok(result);
    }
    Err(FlovynError::Timeout { task }) => {
        // Primary too slow - it's already cancelled by timeout
        // Try fallback
        let fallback = ctx.schedule_task("fetch-data", json!({"source": "fallback"})).await?;
        return fallback.await;  // Wait for fallback (no timeout)
    }
    Err(e) => return Err(e),
}
```

### Scenario 3: Partial Results with Graceful Degradation

```rust
use flovyn_worker_sdk::agent::combinators::agent_join_all_best_effort;

// Schedule optional enrichment tasks
let weather = ctx.schedule_task("enrich-weather", input.clone()).await?;
let news = ctx.schedule_task("enrich-news", input.clone()).await?;
let social = ctx.schedule_task("enrich-social", input.clone()).await?;

// Wait up to 5 seconds, accept partial results
let results = agent_join_all_best_effort(
    ctx,
    vec![weather, news, social],
    Duration::from_secs(5),
).await;

// PartialResults {
//   completed: Vec<(usize, Value)>,  // (index, result) for completed
//   cancelled: Vec<usize>,           // indices of cancelled tasks
//   failed: Vec<(usize, String)>,    // (index, error) for failed
// }

// Use whatever completed, ignore the rest
let mut output = base_output;
for (_, result) in results.completed {
    if let Some(enrichment) = result.as_object() {
        for (k, v) in enrichment {
            output.insert(k.clone(), v.clone());
        }
    }
}
output.insert("enrichmentStats".to_string(), json!({
    "completed": results.completed.len(),
    "cancelled": results.cancelled.len(),
    "failed": results.failed.len(),
}));
```

### Handling Cancelled Tasks in join_all

Three strategies via different combinator functions:

1. **Fail-fast** (default): If any task is cancelled, `agent_join_all` returns error
   ```rust
   let results = agent_join_all(ctx, futures).await?;
   // Error if any task cancelled externally
   ```

2. **Skip cancelled**: Return results for completed tasks only
   ```rust
   let results = agent_join_all_skip_cancelled(ctx, futures).await?;
   // Returns Vec<(usize, Value)> - index and result of completed tasks
   ```

3. **Collect all outcomes**: Return status for each task
   ```rust
   let outcomes = agent_join_all_outcomes(ctx, futures).await;
   // Returns Vec<TaskOutcome> where TaskOutcome = Completed(Value) | Failed(Error) | Cancelled
   ```

### Edge Cases

#### Race: Cancel vs Complete

Task might complete while cancellation request is in flight:
```rust
let task = ctx.schedule_task("fast-task", input).await?;
// Task completes very quickly...

// Cancel arrives after completion
let result = ctx.cancel_task(&task).await?;
// Returns CancelResult::AlreadyCompleted(value)
// Agent should handle this gracefully - can use the value
```

#### Cancel Idempotency

Multiple cancel calls should be safe:
```rust
let task = ctx.schedule_task("task", input).await?;
ctx.cancel_task(&task).await?;  // Returns Cancelled
ctx.cancel_task(&task).await?;  // Returns AlreadyCancelled (no-op)
```

#### Cancelled Future in Subsequent join_all

If a future was cancelled, using it in join_all fails immediately:
```rust
let task1 = ctx.schedule_task("task-1", input).await?;
let task2 = ctx.schedule_task("task-2", input).await?;

ctx.cancel_task(&task1).await?;

// Later - task1 is already cancelled
let results = agent_join_all(ctx, vec![task1, task2]).await;
// Returns Err(FlovynError::TaskCancelled) immediately
// Use agent_join_all_skip_cancelled if you want to ignore cancelled tasks
```

### TaskOutcome Enum

```rust
/// Outcome of a task execution
pub enum TaskOutcome {
    /// Task completed successfully
    Completed(Value),
    /// Task failed with error
    Failed(String),
    /// Task was cancelled
    Cancelled,
    /// Task is still running (shouldn't happen in final results)
    Running,
}

impl TaskOutcome {
    pub fn is_success(&self) -> bool {
        matches!(self, Self::Completed(_))
    }

    pub fn into_result(self) -> Result<Value> {
        match self {
            Self::Completed(v) => Ok(v),
            Self::Failed(e) => Err(FlovynError::TaskFailed(e)),
            Self::Cancelled => Err(FlovynError::TaskCancelled),
            Self::Running => Err(FlovynError::TaskStillRunning),
        }
    }
}
```

### Additional Cancellation Tests

**TODO:**
- [x] `test_agent_cancel_one_of_many` - Cancel one task, others continue (covered by `test_agent_racing_tasks_with_cancellation`)
- [x] `test_agent_cancel_and_replace` - Cancel slow task, schedule replacement
- [x] `test_agent_partial_results` - Get results from completed tasks, cancel rest (covered by `test_agent_timeout_partial_completion`)
- [x] `test_agent_cancel_race_with_complete` - Cancel task that's completing (covered by `test_agent_cancel_completed_task`)
- [x] `test_agent_cancel_idempotency` - Multiple cancels are safe
- [x] `test_agent_join_all_with_cancelled_handle` - Fails if handle already cancelled
- [x] `test_agent_join_all_outcomes` - Collect all outcomes including cancelled (covered by `test_agent_parallel_with_failure`)

---

## Updated Phase Plan

### Phase 6: Task Cancellation ✅ COMPLETED

**TODO:**
- [x] Add `CancelAgentTask` RPC to proto (completed in Phase 1)
- [x] Implement cancellation in server `task_execution.rs` (completed in Phase 1)
- [x] Add `cancel_task()` to SDK client (`agent_dispatch.rs`)
- [x] Add `cancel_task()` and `cancel_tasks()` to `AgentContext`
- [x] Add `agent_select_with_cancel()` combinator that auto-cancels remaining tasks
- [x] Add `SelectWithCancelResult` and `CancelAttempt` result types
- [x] Add `RacingTasksWithCancelAgent` test fixture
- [x] Add `test_agent_racing_tasks_with_cancellation` E2E test
- [x] Add `agent_join_all_with_timeout()` with cancellation
- [x] Add `JoinAllTimeoutResult` result type
- [x] Add `ConditionalFailTask` task fixture for failure testing
- [x] Add `ParallelWithFailuresAgent` agent fixture
- [x] Add `test_agent_parallel_with_failure` E2E test
- [x] Add `test_agent_cancel_completed_task` E2E test

---

## Future Extensions

- `join_n()` - wait for exactly N tasks (not all)
- Task priority/ordering in cancellation
- Graceful cancellation (allow task to clean up before terminating)
