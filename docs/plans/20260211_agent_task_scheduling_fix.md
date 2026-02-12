# Agent Task Scheduling Fix - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix agent task scheduling to use direct task status queries instead of signals, making it consistent with how workflows handle task completion.

**Architecture:** When an agent schedules a task, it suspends waiting for the task (not a signal). When the task completes, the server resumes the agent. On resume, the SDK queries the task result directly from the task_execution table. Signals remain only for external interaction (userMessage, etc.).

**Tech Stack:** Rust (server + SDK), gRPC, PostgreSQL

---

## Problem Statement

The current implementation uses signals (`task_complete:{task_id}`) to notify agents when tasks complete. This creates several issues:

1. **Idempotency key instability**: The key included `checkpoint_seq`, which changes between suspensions, causing new tasks to be scheduled on resume instead of getting the original task's result.

2. **Signal abuse**: Signals are designed for external interaction (user messages, webhooks), not internal coordination between agent and task worker.

3. **Inconsistency with workflows**: Workflows don't use signals for task completion - they use event sourcing with replay. While agents don't use replay, they should still query task status directly rather than using signals.

## Design

### Current Flow (Broken)

```
schedule_task_raw():
  1. Generate idempotency key (includes checkpoint_seq - UNSTABLE)
  2. ScheduleAgentTask → task_execution_id
  3. Checkpoint (increments checkpoint_seq)
  4. SuspendAgent(wait_for_signal="task_complete:{task_id}")
  5. Task completes → server creates signal
  6. On resume: ConsumeSignals("task_complete:{task_id}")
  7. PROBLEM: On resume, new idempotency key → new task → wrong signal name
```

### New Flow (Correct)

```
schedule_task_raw():
  1. Generate stable idempotency key (agent_id + counter, no checkpoint_seq)
  2. ScheduleAgentTask → task_execution_id (same on retry due to idempotency)
  3. GetAgentTaskResult(task_execution_id) → check if already done
  4. If done: return result immediately
  5. If not done: SuspendAgent(wait_for_task=task_execution_id)
  6. Task completes → server resumes agent (no signal)
  7. On resume: same idempotency key → same task_id → GetAgentTaskResult → done
```

### Key Changes

1. **Server: Add `wait_for_task` suspension mode**
   - `SuspendAgentRequest` gets `wait_for_task` field (alternative to `wait_for_signal`)
   - Store wait condition in `agent_execution.metadata`

2. **Server: Resume agent on task completion**
   - In `TaskExecutionService::complete_task`, check if parent agent is suspended waiting for this task
   - If so, transition agent from WAITING to PENDING

3. **Server: Add `GetAgentTaskResult` RPC**
   - Query task_execution by ID
   - Return status + output/error

4. **SDK: Rewrite `schedule_task_with_options_raw`**
   - Use stable idempotency key (already partially done)
   - Query task result before suspending
   - Suspend with `wait_for_task` instead of `wait_for_signal`

5. **Cleanup: Remove signal-based task completion**
   - Remove `task_complete:` signal creation in server
   - Remove signal consumption in SDK task scheduling

---

## Phase 1: Server - Task Result Query

### Task 1.1: Add GetAgentTaskResult RPC

**Files:**
- Modify: `flovyn-server/server/proto/agent.proto`
- Modify: `flovyn-server/server/src/api/grpc/agent_dispatch.rs`

**Step 1: Add proto messages**

Add to `agent.proto`:

```protobuf
// Query task execution result
rpc GetAgentTaskResult(GetAgentTaskResultRequest) returns (GetAgentTaskResultResponse);

message GetAgentTaskResultRequest {
  // Agent execution ID (for authorization)
  string agent_execution_id = 1;

  // Task execution ID to query
  string task_execution_id = 2;
}

message GetAgentTaskResultResponse {
  // Task status: "PENDING", "RUNNING", "COMPLETED", "FAILED", "CANCELLED"
  string status = 1;

  // Output (if COMPLETED)
  optional bytes output = 2;

  // Error message (if FAILED)
  optional string error = 3;
}
```

**Step 2: Run build to generate code**

```bash
cd flovyn-server && mise run build
```

**Step 3: Implement GetAgentTaskResult**

In `agent_dispatch.rs`:

```rust
async fn get_agent_task_result(
    &self,
    request: Request<GetAgentTaskResultRequest>,
) -> Result<Response<GetAgentTaskResultResponse>, Status> {
    let req = request.into_inner();
    let agent_execution_id = Uuid::parse_str(&req.agent_execution_id)
        .map_err(|_| Status::invalid_argument("Invalid agent_execution_id"))?;
    let task_execution_id = Uuid::parse_str(&req.task_execution_id)
        .map_err(|_| Status::invalid_argument("Invalid task_execution_id"))?;

    // Verify task belongs to this agent
    let task = self.task_repo.find_by_id(task_execution_id).await
        .map_err(|e| Status::internal(e.to_string()))?
        .ok_or_else(|| Status::not_found("Task not found"))?;

    if task.agent_execution_id != Some(agent_execution_id) {
        return Err(Status::permission_denied("Task does not belong to this agent"));
    }

    Ok(Response::new(GetAgentTaskResultResponse {
        status: task.status.to_string(),
        output: if task.status == TaskStatus::Completed { task.output.map(|v| v.to_string().into_bytes()) } else { None },
        error: if task.status == TaskStatus::Failed { task.error.clone() } else { None },
    }))
}
```

**Step 4: Run tests**

```bash
cd flovyn-server && mise run test
```

**Commit:** `feat(server): add GetAgentTaskResult gRPC method`

---

## Phase 2: Server - Task-Based Suspension

### Task 2.1: Extend SuspendAgent for Task Waiting

**Files:**
- Modify: `flovyn-server/server/proto/agent.proto`
- Modify: `flovyn-server/server/src/api/grpc/agent_dispatch.rs`
- Modify: `flovyn-server/server/src/repository/agent_repository.rs`

**Step 1: Update proto**

Modify `SuspendAgentRequest`:

```protobuf
message SuspendAgentRequest {
  string agent_execution_id = 1;

  // Wait condition - exactly one must be set
  oneof wait_condition {
    // Wait for external signal (e.g., "userMessage")
    string wait_for_signal = 2;

    // Wait for task completion
    string wait_for_task = 4;
  }

  optional string reason = 3;
}
```

**Step 2: Regenerate and update implementation**

Update `suspend_agent` in `agent_dispatch.rs` to handle both wait conditions:
- Store wait condition type in `agent_execution.metadata`
- Store the signal_name or task_execution_id

**Step 3: Run build**

```bash
cd flovyn-server && mise run build
```

**Commit:** `feat(server): support task-based suspension in SuspendAgent`

### Task 2.2: Resume Agent on Task Completion

**Files:**
- Modify: `flovyn-server/server/src/api/grpc/task_execution.rs`

**Step 1: Update CompleteTask to resume waiting agents**

In `TaskExecutionService::complete_task`, after updating task status:

```rust
// If task has an agent parent, check if agent is waiting for this task
if let Some(agent_id) = task.agent_execution_id {
    let agent = self.agent_repo.find_by_id(agent_id).await?;
    if let Some(agent) = agent {
        if agent.status == AgentStatus::Waiting {
            // Check if waiting for this specific task
            if let Some(metadata) = &agent.metadata {
                if let Some(wait_for_task) = metadata.get("wait_for_task") {
                    if wait_for_task.as_str() == Some(&task.id.to_string()) {
                        // Resume agent
                        self.agent_repo.update_status(agent_id, AgentStatus::Pending).await?;
                    }
                }
            }
        }
    }
}
```

**Step 2: Same for FailTask**

Add similar logic to `fail_task`.

**Step 3: Write integration test**

Create test that:
1. Creates agent execution
2. Schedules task from agent
3. Suspends agent waiting for task
4. Completes task
5. Verifies agent transitioned to PENDING

**Step 4: Run tests**

```bash
cd flovyn-server && mise run test:integration -- agent
```

**Commit:** `feat(server): resume agent when waited-for task completes`

---

## Phase 3: SDK - Direct Task Status Query

### Task 3.1: Add get_task_result to AgentDispatch Client

**Files:**
- Modify: `sdk-rust/worker-core/src/client/agent_dispatch.rs`

**Step 1: Add method to AgentDispatch**

```rust
pub async fn get_task_result(
    &mut self,
    agent_execution_id: Uuid,
    task_execution_id: Uuid,
) -> Result<TaskResult> {
    let request = GetAgentTaskResultRequest {
        agent_execution_id: agent_execution_id.to_string(),
        task_execution_id: task_execution_id.to_string(),
    };

    let response = self.client.get_agent_task_result(request).await?;
    let inner = response.into_inner();

    Ok(TaskResult {
        status: inner.status,
        output: inner.output.map(|b| serde_json::from_slice(&b).unwrap_or(Value::Null)),
        error: inner.error,
    })
}
```

**Step 2: Add TaskResult struct**

```rust
pub struct TaskResult {
    pub status: String,
    pub output: Option<Value>,
    pub error: Option<String>,
}
```

**Step 3: Run build**

```bash
cd sdk-rust && cargo build -p flovyn-worker-core
```

**Commit:** `feat(sdk): add get_task_result to AgentDispatch client`

### Task 3.2: Rewrite schedule_task_with_options_raw

**Files:**
- Modify: `sdk-rust/worker-sdk/src/agent/context_impl.rs`

**Step 1: Rewrite the method**

```rust
async fn schedule_task_with_options_raw(
    &self,
    task_kind: &str,
    input: Value,
    options: ScheduleAgentTaskOptions,
) -> Result<Value> {
    // Generate stable idempotency key (doesn't include checkpoint_seq)
    let idempotency_key = options
        .idempotency_key
        .unwrap_or_else(|| self.generate_task_idempotency_key());

    // Schedule the task (idempotent - returns same task if key exists)
    let result = {
        let mut client = self.client.lock().await;
        client
            .schedule_task(
                self.agent_execution_id,
                task_kind,
                &input,
                options.queue.as_deref(),
                options.max_retries.map(|r| r as i32),
                options.timeout.map(|t| t.as_millis() as i64),
                Some(&idempotency_key),
            )
            .await?
    };

    let task_execution_id = result.task_execution_id;

    // Check if task already completed (handles resume case)
    let task_result = {
        let mut client = self.client.lock().await;
        client.get_task_result(self.agent_execution_id, task_execution_id).await?
    };

    match task_result.status.as_str() {
        "COMPLETED" => {
            // Task done - return result
            Ok(task_result.output.unwrap_or(Value::Null))
        }
        "FAILED" => {
            // Task failed - return error
            Err(FlovynError::TaskFailed(format!(
                "Task '{}' failed: {}",
                task_kind,
                task_result.error.unwrap_or_else(|| "Unknown error".to_string())
            )))
        }
        "CANCELLED" => {
            Err(FlovynError::TaskFailed(format!("Task '{}' was cancelled", task_kind)))
        }
        _ => {
            // Task still running - suspend waiting for it
            {
                let mut client = self.client.lock().await;
                client
                    .suspend_agent_for_task(
                        self.agent_execution_id,
                        task_execution_id,
                        Some(&format!("Waiting for task {} to complete", task_kind)),
                    )
                    .await?;
            }

            // Agent will be resumed when task completes
            Err(FlovynError::Other(format!(
                "Agent suspended waiting for task '{}' completion",
                task_kind
            )))
        }
    }
}
```

**Step 2: Add suspend_agent_for_task to client**

```rust
pub async fn suspend_agent_for_task(
    &mut self,
    agent_execution_id: Uuid,
    task_execution_id: Uuid,
    reason: Option<&str>,
) -> Result<()> {
    let request = SuspendAgentRequest {
        agent_execution_id: agent_execution_id.to_string(),
        wait_condition: Some(WaitCondition::WaitForTask(task_execution_id.to_string())),
        reason: reason.map(|s| s.to_string()),
    };

    self.client.suspend_agent(request).await?;
    Ok(())
}
```

**Step 3: Run build**

```bash
cd sdk-rust && cargo build -p flovyn-worker-sdk
```

**Commit:** `feat(sdk): rewrite schedule_task_raw to use direct task status`

---

## Phase 4: Cleanup

### Task 4.1: Remove Signal-Based Task Completion

**Files:**
- Modify: `flovyn-server/server/src/api/grpc/task_execution.rs`

**Step 1: Remove signal creation in CompleteTask**

Find and remove code that creates `task_complete:{task_id}` signals.

**Step 2: Run tests to verify nothing breaks**

```bash
cd flovyn-server && mise run test:integration
```

**Commit:** `refactor(server): remove signal-based task completion for agents`

### Task 4.2: Clean Up SDK

**Files:**
- Modify: `sdk-rust/worker-sdk/src/agent/context_impl.rs`

**Step 1: Remove unused signal consumption code**

Remove any code that consumes `task_complete:` signals.

**Step 2: Remove unused `generate_idempotency_key` method**

The old method that included checkpoint_seq is no longer needed.

**Step 3: Run all tests**

```bash
cd sdk-rust && mise run test
cd sdk-rust && mise run test:e2e
```

**Commit:** `refactor(sdk): clean up signal-based task completion code`

---

## Phase 5: Testing

### Task 5.1: Update Existing Tests

**Files:**
- Modify: `sdk-rust/worker-sdk/tests/e2e/agent_tests.rs`
- Modify: `flovyn-server/tests/integration/agent_execution_tests.rs`

**Step 1: Verify all existing agent tests pass**

```bash
cd flovyn-server && mise run test:integration -- agent
cd sdk-rust && mise run test:e2e -- agent
```

**Step 2: Add test for suspend-resume-with-task**

Test that specifically verifies:
1. Agent schedules task
2. Agent suspends (not yet complete)
3. Task completes
4. Agent resumes
5. Same schedule_task_raw call returns the result

**Commit:** `test: verify agent task scheduling with direct status query`

### Task 5.2: Add Resume Path Test

**Files:**
- Create: `sdk-rust/worker-sdk/tests/e2e/agent_task_resume_test.rs`

**Step 1: Write test that simulates resume**

```rust
#[tokio::test]
async fn test_agent_task_resume_returns_correct_result() {
    // 1. Start agent that schedules a slow task
    // 2. Agent suspends waiting for task
    // 3. Task completes
    // 4. Agent resumes (new context, counter starts at 0)
    // 5. schedule_task_raw returns cached result (not scheduling new task)
}
```

**Commit:** `test: add agent task resume path test`

---

## TODO Checklist

### Phase 1: Server - Task Result Query
- [ ] 1.1.1: Add GetAgentTaskResult proto messages
- [ ] 1.1.2: Regenerate proto code
- [ ] 1.1.3: Implement GetAgentTaskResult
- [ ] 1.1.4: Run tests

### Phase 2: Server - Task-Based Suspension
- [ ] 2.1.1: Update SuspendAgentRequest proto with wait_for_task
- [ ] 2.1.2: Update suspend_agent implementation
- [ ] 2.1.3: Run build
- [ ] 2.2.1: Update CompleteTask to resume waiting agents
- [ ] 2.2.2: Update FailTask similarly
- [ ] 2.2.3: Write integration test
- [ ] 2.2.4: Run tests

### Phase 3: SDK - Direct Task Status Query
- [ ] 3.1.1: Add get_task_result to AgentDispatch client
- [ ] 3.1.2: Add TaskResult struct
- [ ] 3.1.3: Run build
- [ ] 3.2.1: Rewrite schedule_task_with_options_raw
- [ ] 3.2.2: Add suspend_agent_for_task to client
- [ ] 3.2.3: Run build

### Phase 4: Cleanup
- [ ] 4.1.1: Remove signal creation in CompleteTask
- [ ] 4.1.2: Run tests
- [ ] 4.2.1: Remove signal consumption code in SDK
- [ ] 4.2.2: Remove unused generate_idempotency_key
- [ ] 4.2.3: Run all tests

### Phase 5: Testing
- [ ] 5.1.1: Verify all existing tests pass
- [ ] 5.1.2: Add suspend-resume-with-task test
- [ ] 5.2.1: Add resume path test

---

## Rollback Plan

If issues are discovered:
1. The old signal-based code can be restored by reverting the commits
2. The proto changes are additive (new field, new RPC), so they're backwards compatible
3. The SDK changes are in a single method, easy to revert

## Dependencies

- This plan depends on the stable idempotency key fix already applied to `generate_task_idempotency_key`
- Server must be deployed before SDK changes are used in production
