# Client-Generated Task Execution IDs

**Status**: Design Proposal
**Purpose**: Enable SDK to generate task execution IDs client-side, eliminating the need for a separate `SubmitTask` gRPC call before scheduling tasks.

---

## Overview

This document describes changes to the Flovyn server to support client-generated task execution IDs. Currently, the SDK must call `SubmitTask()` gRPC to obtain a server-generated task execution ID before sending a `ScheduleTask` command. This creates an awkward two-step flow and prevents synchronous task scheduling in the SDK.

**Current Flow (Server-Generated IDs)**:
```
SDK                                    Server
 |                                       |
 |--submitTask(taskType, input)--------->|
 |                                       | Create TaskExecution
 |                                       | Generate UUID
 |<--taskExecutionId--------------------|
 |                                       |
 |--ScheduleTask{taskExecutionId}------->|
 |                                       | Create TASK_SCHEDULED event
```

**Proposed Flow (Client-Generated IDs)**:
```
SDK                                    Server
 |                                       |
 | Generate UUID (deterministic)         |
 | Queue ScheduleTask command            |
 |                                       |
 | Workflow suspends                     |
 |                                       |
 |--BatchCommands[ScheduleTask,...]----->|
 |                                       | For each ScheduleTask:
 |                                       |   Create TaskExecution with client ID
 |                                       |   Create TASK_SCHEDULED event
```

---

## Goals

1. Accept client-provided `task_execution_id` in `ScheduleTaskCommand`
2. Create `TaskExecution` record when processing the command (not via separate gRPC call)
3. Support idempotency for duplicate task IDs (network retries)
4. Maintain backwards compatibility during migration (keep `SubmitTask` temporarily)
5. Process batch commands atomically (all-or-nothing transaction)

## Non-Goals

- Changing how task workers poll/execute tasks (no changes to `PollTask`, `CompleteTask`, etc.)
- Backwards compatibility with existing event histories (SDK breaking change is allowed)

---

## Current Implementation

### SubmitTask gRPC (task_execution.rs)

```rust
async fn submit_task(&self, request: Request<SubmitTaskRequest>) -> Result<Response<SubmitTaskResponse>, Status> {
    // Parse tenant_id, workflow_execution_id
    // Get queue and traceparent from workflow
    // Create TaskExecution with server-generated UUID
    let mut task = TaskExecution::new(tenant_id, workflow_execution_id, task_type, input, queue, max_retries);
    self.task_repo.create(&task).await?;

    Ok(Response::new(SubmitTaskResponse {
        task_execution_id: task.id.to_string(),
        ...
    }))
}
```

### ScheduleTask Command Processing (workflow_dispatch.rs)

```rust
CommandType::ScheduleTask => {
    // Note: ScheduleTask command does NOT create the TaskExecution record here.
    // The TaskExecution is created by the SDK calling submitTask() gRPC method BEFORE
    // sending the ScheduleTask command.

    // Only creates TASK_SCHEDULED event
    let event_data = json!({
        "taskType": task.task_type,
        "taskExecutionId": task.task_execution_id,
        "input": input_value,
    });
    Some(WorkflowEvent::new(workflow_id, sequence, EventType::TaskScheduled, event_data))
}
```

---

## Proposed Changes

### 1. Extend ScheduleTaskCommand Proto

Add optional fields for task configuration:

```protobuf
message ScheduleTaskCommand {
  string task_type = 1;
  bytes input = 2;
  string task_execution_id = 3;  // Client-generated UUID (required)

  // New optional fields (moved from SubmitTaskRequest)
  optional int32 max_retries = 4;
  optional int64 timeout_ms = 5;
  optional string queue = 6;
  optional int32 priority_seconds = 7;
}
```

### 2. Update Command Processing

Modify `ScheduleTaskCommand` processing to create `TaskExecution`:

**File**: `flovyn-server/src/api/grpc/workflow_dispatch.rs`

```rust
CommandType::ScheduleTask => {
    if let Some(CommandData::ScheduleTask(ref task_cmd)) = command.command_data {
        // Parse task_execution_id from client
        let task_execution_id = Uuid::parse_str(&task_cmd.task_execution_id)
            .map_err(|_| Status::invalid_argument("Invalid task_execution_id format"))?;

        // Idempotency check: does TaskExecution already exist?
        let existing = self.task_repo.get(task_execution_id).await?;

        if let Some(existing_task) = existing {
            // Validate it matches (same task type, workflow)
            if existing_task.task_type != task_cmd.task_type {
                return Err(Status::failed_precondition(format!(
                    "Task execution ID collision: {} already exists with different task type '{}', got '{}'",
                    task_execution_id, existing_task.task_type, task_cmd.task_type
                )));
            }
            if existing_task.workflow_execution_id != Some(workflow_id) {
                return Err(Status::failed_precondition(format!(
                    "Task execution ID collision: {} belongs to different workflow",
                    task_execution_id
                )));
            }
            // Already exists - idempotent, skip creation
            tracing::debug!(
                task_id = %task_execution_id,
                "Task already exists, skipping creation (idempotent)"
            );
        } else {
            // Create new TaskExecution
            let queue = task_cmd.queue.clone()
                .unwrap_or_else(|| workflow.task_queue.clone());
            let max_retries = task_cmd.max_retries.unwrap_or(3);

            let mut task = TaskExecution {
                id: task_execution_id,
                tenant_id: workflow.tenant_id,
                workflow_execution_id: Some(workflow_id),
                task_type: task_cmd.task_type.clone(),
                input: Some(task_cmd.input.clone()),
                queue: queue.clone(),
                max_retries,
                timeout: task_cmd.timeout_ms.map(|ms| chrono::Duration::milliseconds(ms)),
                status: TaskStatus::Pending,
                traceparent: workflow.traceparent.clone(),
                created_at: chrono::Utc::now(),
                ..Default::default()
            };

            self.task_repo.create(&task).await
                .map_err(|e| Status::internal(format!("Failed to create task: {}", e)))?;

            // Record metrics
            crate::metrics::record_task_submitted(
                &workflow.tenant_id.to_string(),
                &task_cmd.task_type,
                &queue
            );
        }

        // Create TASK_SCHEDULED event (always, even if task already existed)
        let input_value: serde_json::Value = serde_json::from_slice(&task_cmd.input)
            .unwrap_or(serde_json::Value::Null);
        let event_data = serde_json::json!({
            "taskType": task_cmd.task_type,
            "taskExecutionId": task_cmd.task_execution_id,
            "input": input_value,
        });
        Some(WorkflowEvent::new(
            workflow_id,
            *next_sequence,
            EventType::TaskScheduled,
            Some(serde_json::to_vec(&event_data).unwrap_or_default()),
        ))
    } else {
        None
    }
}
```

### 3. Transaction Handling

Ensure batch command processing is atomic:

```rust
async fn dispatch_workflow_result(&self, request: Request<DispatchWorkflowResultRequest>)
    -> Result<Response<DispatchWorkflowResultResponse>, Status>
{
    // Begin transaction
    let mut tx = self.pool.begin().await
        .map_err(|e| Status::internal(format!("Failed to begin transaction: {}", e)))?;

    for command in &req.commands {
        match process_command(&mut tx, command, workflow_id, &mut next_sequence).await {
            Ok(event) => events.push(event),
            Err(e) => {
                // Rollback on any error
                tx.rollback().await.ok();
                return Err(e);
            }
        }
    }

    // Commit all changes atomically
    tx.commit().await
        .map_err(|e| Status::internal(format!("Failed to commit transaction: {}", e)))?;

    Ok(Response::new(response))
}
```

### 4. Keep SubmitTask for Backwards Compatibility

During migration, keep the `SubmitTask` gRPC method functional. SDKs can be updated incrementally.

**Deprecation Timeline**:
1. Phase 1: Server accepts client IDs in ScheduleTaskCommand
2. Phase 2: SDK switches to client-generated IDs
3. Phase 3: Mark SubmitTask as deprecated
4. Phase 4: Remove SubmitTask (major version bump)

---

## Idempotency Semantics

### Duplicate Task ID (Same Workflow)

If `ScheduleTaskCommand` is received with a `task_execution_id` that already exists:

| Condition | Behavior |
|-----------|----------|
| Same task_type, same workflow | Skip creation, create event (idempotent) |
| Different task_type | Error: `FAILED_PRECONDITION` |
| Different workflow | Error: `FAILED_PRECONDITION` |

### Why Create Event Even if Task Exists?

The workflow event stream should always reflect what commands were sent. If a `ScheduleTaskCommand` is received (even as a retry), we create the `TASK_SCHEDULED` event. The event is idempotent based on sequence number—duplicate sequence numbers would be rejected by the event table's unique constraint.

---

## Error Handling

### Invalid UUID Format

```rust
if let Err(_) = Uuid::parse_str(&task_cmd.task_execution_id) {
    return Err(Status::invalid_argument(
        "Invalid task_execution_id: must be valid UUID"
    ));
}
```

### Task ID Collision

```rust
if existing_task.task_type != task_cmd.task_type {
    return Err(Status::failed_precondition(format!(
        "Task execution ID collision: {} already exists with task type '{}', cannot schedule as '{}'",
        task_execution_id, existing_task.task_type, task_cmd.task_type
    )));
}
```

### Transaction Failure

If any command in the batch fails, the entire batch is rolled back:

```rust
Err(Status::aborted(
    "Batch command processing failed, transaction rolled back"
))
```

---

## Database Considerations

### TaskExecution Table

No schema changes required. The `id` column already accepts UUIDs:

```sql
CREATE TABLE task_executions (
    id UUID PRIMARY KEY,
    tenant_id UUID NOT NULL,
    workflow_execution_id UUID,  -- nullable for standalone tasks
    task_type VARCHAR(255) NOT NULL,
    input BYTEA,
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING',
    queue VARCHAR(255) NOT NULL DEFAULT 'default',
    max_retries INT NOT NULL DEFAULT 3,
    ...
);
```

### Unique Constraint

The `id` column is already the primary key, ensuring uniqueness. No additional constraints needed.

---

## Testing Strategy

### Unit Tests

1. **Happy path**: ScheduleTaskCommand creates TaskExecution and event
2. **Idempotency**: Duplicate task_execution_id with same task_type → success (skip creation)
3. **Collision detection**: Duplicate ID with different task_type → error
4. **Invalid UUID**: Malformed task_execution_id → error
5. **Batch atomicity**: One command fails → entire batch rolled back

### Integration Tests

1. **Full workflow with client IDs**: SDK schedules task, worker executes, workflow completes
2. **Parallel tasks**: Multiple ScheduleTaskCommands in single batch
3. **Network retry**: Same batch sent twice → idempotent behavior
4. **Mixed commands**: Batch with ScheduleTask, StartTimer, CreatePromise

### E2E Tests

1. **SDK→Server→Worker→Server**: Complete task lifecycle
2. **Workflow resume**: Task completes, workflow resumes with result
3. **Server restart**: Tasks survive restart, can be polled

---

## Migration Path

### Phase 1: Server Changes (This Document)

- [x] Design document
- [ ] Extend ScheduleTaskCommand proto with optional fields
- [ ] Update command processor to create TaskExecution
- [ ] Add idempotency checks
- [ ] Add transaction handling
- [ ] Write tests

### Phase 2: SDK Changes

- [ ] Change schedule methods to synchronous (return Future immediately)
- [ ] Generate task_execution_id using deterministic `random_uuid()`
- [ ] Remove `TaskSubmitter` and `GrpcTaskSubmitter`
- [ ] Update tests and examples

### Phase 3: Deprecation

- [ ] Mark `SubmitTask` gRPC as deprecated
- [ ] Add deprecation warning in logs
- [ ] Update documentation

### Phase 4: Removal (Future Major Version)

- [ ] Remove `SubmitTask` gRPC method
- [ ] Remove `SubmitTaskRequest`/`SubmitTaskResponse` from proto

---

## Appendix: Proto Changes

### Before

```protobuf
message ScheduleTaskCommand {
  string task_type = 1;
  bytes input = 2;
  string task_execution_id = 3;
}
```

### After

```protobuf
message ScheduleTaskCommand {
  string task_type = 1;
  bytes input = 2;
  string task_execution_id = 3;  // Client-generated UUID (required)

  // Optional task configuration (defaults from workflow if not specified)
  optional int32 max_retries = 4;      // Default: 3
  optional int64 timeout_ms = 5;       // Default: none
  optional string queue = 6;           // Default: workflow's task_queue
  optional int32 priority_seconds = 7; // Default: 0
}
```

---

## References

- [SDK Synchronous Scheduling Design](/Users/manhha/Developer/manhha/flovyn/dev/docs/design/synchronous-scheduling.md)
- [SDK Implementation Plan](/Users/manhha/Developer/manhha/flovyn/dev/docs/plans/synchronous-scheduling-implementation.md)
