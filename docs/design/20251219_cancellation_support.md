# Design: Cancellation Support

## Status
**Implemented** - Required for SDK parallel execution support

## Background

The Rust SDK is implementing parallel execution support ([design doc](../../../dev/docs/design/parallel-execution.md)) which requires the server to handle cancellation commands. Currently:

- **Task cancellation**: RPC defined but returns `Status::unimplemented()` (`src/api/grpc/task_execution.rs:496`)
- **Timer cancellation**: Proto defined (`CommandType::CancelTimer = 13`) but command handler missing in `process_command()`
- **Child workflow cancellation**: Not defined in proto

This document specifies the server-side implementation for all three cancellation types.

### Current Codebase State

Before implementation, note what already exists:

| Feature | Status |
|---------|--------|
| `WorkflowState::Cancelling` | Already exists in `flovyn-server/src/domain/workflow.rs` |
| `WorkflowState::Cancelled` | Already exists in `flovyn-server/src/domain/workflow.rs` |
| `EventType::TimerCancelled` | Already exists in `flovyn-server/src/domain/workflow_event.rs` |
| `CancelTimerCommand` proto message | Already exists in `proto/flovyn.proto` |
| `timer` table | Already exists in `flovyn-server/migrations/001_init.sql` (but not actively used - events are used instead) |

## Goals

1. Implement task cancellation via `CancelTask` RPC
2. Implement timer cancellation via `CancelTimer` command
3. Implement child workflow cancellation via `RequestCancelChildWorkflow` command
4. Maintain event sourcing consistency for deterministic replay
5. Support cancellation propagation where applicable

## Non-Goals

- Cross-namespace cancellation (all operations within single tenant)
- Workflow-level cancellation API changes (already exists)
- Cancellation compensation/rollback logic (SDK responsibility)

---

## Design

### 1. Task Cancellation

#### 1.1 Current State

**Proto** (`proto/flovyn.proto`):
```protobuf
service TaskExecution {
    rpc CancelTask(CancelTaskRequest) returns (google.protobuf.Empty);
}

message CancelTaskRequest {
    string task_execution_id = 1;
}
```

**Implementation** (`src/api/grpc/task_execution.rs:495-504`):
```rust
async fn cancel_task(&self, _request: Request<CancelTaskRequest>) -> Result<Response<()>, Status> {
    Err(Status::unimplemented("Task cancellation not yet implemented"))
}
```

#### 1.2 Proposed Implementation

**Note**: `TaskExecutionService` currently lacks a `WorkerNotifier`. Either add it to the service struct, or notify via the workflow repository pattern.

```rust
async fn cancel_task(
    &self,
    request: Request<CancelTaskRequest>,
) -> Result<Response<()>, Status> {
    let req = request.into_inner();
    let task_execution_id = Uuid::parse_str(&req.task_execution_id)
        .map_err(|_| Status::invalid_argument("Invalid task_execution_id format"))?;

    // 1. Get task from database
    let task = self.task_repo.get(task_execution_id).await
        .map_err(|e| Status::internal(format!("Failed to get task: {}", e)))?
        .ok_or_else(|| Status::not_found("Task not found"))?;

    // 2. Check if task can be cancelled (only PENDING or RUNNING)
    let status = task.status();
    if status != TaskStatus::Pending && status != TaskStatus::Running {
        return Err(Status::failed_precondition(format!(
            "Task cannot be cancelled: status is {:?}", status
        )));
    }

    // 3. Update task status to CANCELLED
    self.task_repo.update_status(
        task_execution_id,
        "CANCELLED",
        Some("Cancelled by request".to_string()),
    ).await.map_err(|e| Status::internal(format!("Failed to cancel task: {}", e)))?;

    // 4. If task belongs to a workflow, record TASK_CANCELLED event
    if let Some(workflow_id) = task.workflow_execution_id {
        let next_seq = self.event_repo.get_latest_sequence(workflow_id).await
            .map_err(|e| Status::internal(format!("Failed to get sequence: {}", e)))?
            .unwrap_or(0) + 1;

        let event_data = serde_json::json!({
            "taskExecutionId": task_execution_id.to_string(),
            "taskType": task.task_type,
            "reason": "Cancelled by request",
        });

        let event = WorkflowEvent::new(
            workflow_id,
            next_seq,
            EventType::TaskCancelled,
            Some(serde_json::to_vec(&event_data).unwrap_or_default()),
        );

        self.event_repo.append(&event).await
            .map_err(|e| Status::internal(format!("Failed to record event: {}", e)))?;

        // 5. Resume workflow if waiting
        self.workflow_repo.resume(workflow_id).await
            .map_err(|e| Status::internal(format!("Failed to resume workflow: {}", e)))?;
    }

    Ok(Response::new(()))
}
```

#### 1.3 Database & Domain Changes

**Add `TaskStatus::Cancelled` variant** (`flovyn-server/src/domain/task.rs`):
```rust
pub enum TaskStatus {
    Pending,
    Running,
    Completed,
    Failed,
    Cancelled,  // NEW
}

impl TaskStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            // ... existing cases ...
            TaskStatus::Cancelled => "CANCELLED",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_uppercase().as_str() {
            // ... existing cases ...
            "CANCELLED" => Some(TaskStatus::Cancelled),
            _ => None,
        }
    }
}
```

**Note**: The current codebase uses string-based status (`status_str: String`) in the database, not PostgreSQL enums. No migration required - just add the new variant to the Rust enum.

#### 1.4 Event Type

**Add `TaskCancelled` event type** (`flovyn-server/src/domain/workflow_event.rs`):
```rust
pub enum EventType {
    // ... existing types ...
    TaskCancelled,  // NEW
}
```

---

### 2. Timer Cancellation

#### 2.1 Current State

**Proto** (`proto/flovyn.proto`):
```protobuf
enum CommandType {
    CANCEL_TIMER = 13;
}

message CancelTimerCommand {
    string timer_id = 1;
}
```

**Implementation**: Command falls through to `_ => None` catch-all in `process_command()` (`src/api/grpc/workflow_dispatch.rs:1419`).

**Event type**: `EventType::TimerCancelled` already exists in `flovyn-server/src/domain/workflow_event.rs`.

**Timer tracking**: Currently uses event-based tracking via `TIMER_STARTED`/`TIMER_FIRED` events in `workflow_event` table (see `find_expired_timers()` in `src/repository/event_repository.rs:161`). The `timer` table exists but is not actively used.

#### 2.2 Proposed Implementation

**Add handler in `process_command()`** (`flovyn-server/src/api/grpc/workflow_dispatch.rs`):

```rust
CommandType::CancelTimer => {
    if let Some(CommandData::CancelTimer(ref cancel)) = command.command_data {
        let event_data = serde_json::json!({
            "timerId": cancel.timer_id,
        });
        Some(WorkflowEvent::new(
            workflow_id,
            *next_sequence,
            EventType::TimerCancelled,
            Some(serde_json::to_vec(&event_data).unwrap_or_default()),
        ))
    } else {
        None
    }
}
```

**Update `find_expired_timers()`** (`flovyn-server/src/repository/event_repository.rs`):

Add check for `TIMER_CANCELLED` events to prevent firing cancelled timers:

```sql
-- Add to the NOT EXISTS clause in find_expired_timers()
AND NOT EXISTS (
    SELECT 1 FROM workflow_event wec
    WHERE wec.workflow_execution_id = wes.workflow_execution_id
      AND wec.event_type = 'TIMER_CANCELLED'
      AND (convert_from(wec.event_data, 'UTF8')::jsonb->>'timerId')::text = wes.timer_id
)
```

#### 2.3 No Database Changes Required

Timer cancellation uses the existing event-based approach. Recording a `TIMER_CANCELLED` event is sufficient - the scheduler's `find_expired_timers()` query will exclude cancelled timers after the query update above.

---

### 3. Child Workflow Cancellation

#### 3.1 Proto Changes

**Add command type** (`proto/flovyn.proto`):

```protobuf
enum CommandType {
    // ... existing types ...
    REQUEST_CANCEL_CHILD_WORKFLOW = 14;  // NEW
}

message RequestCancelChildWorkflowCommand {
    string child_execution_name = 1;      // Logical name for matching
    string child_workflow_execution_id = 2; // UUID of child workflow
    string reason = 3;                    // Optional cancellation reason
}

// Add to workflow_command.command_data oneof:
oneof command_data {
    // ... existing ...
    RequestCancelChildWorkflowCommand request_cancel_child_workflow = 15;
}
```

#### 3.2 Event Types

**Add new event types** (`flovyn-server/src/domain/workflow_event.rs`):

```rust
pub enum EventType {
    // ... existing types ...

    // Child workflow cancellation events
    ChildWorkflowCancellationRequested,  // Parent requested child cancellation
    ChildWorkflowCancellationFailed,     // Child cancellation failed (e.g., already completed)
    CancellationRequested,               // Workflow received cancellation request (from parent/external)
}
```

**Note**: When a child workflow is cancelled, the parent receives `ChildWorkflowFailed` with a cancellation error (reuses existing event type).

#### 3.3 Implementation

**Add handler in `process_command()`**:

```rust
CommandType::RequestCancelChildWorkflow => {
    if let Some(CommandData::RequestCancelChildWorkflow(ref cancel)) = command.command_data {
        let event_data = serde_json::json!({
            "childExecutionName": cancel.child_execution_name,
            "childWorkflowExecutionId": cancel.child_workflow_execution_id,
            "reason": cancel.reason,
        });
        Some(WorkflowEvent::new(
            workflow_id,
            *next_sequence,
            EventType::ChildWorkflowCancellationRequested,
            Some(serde_json::to_vec(&event_data).unwrap_or_default()),
        ))
    } else {
        None
    }
}
```

**Process cancellation after event recording**:

```rust
// In submit_workflow_commands, after saving events:
for event in &new_events {
    if event.event_type == EventType::ChildWorkflowCancellationRequested.as_str() {
        if let Some(ref data) = event.event_data {
            if let Ok(v) = serde_json::from_slice::<serde_json::Value>(data) {
                let child_id = v.get("childWorkflowExecutionId")
                    .and_then(|id| id.as_str())
                    .and_then(|id| Uuid::parse_str(id).ok());

                if let Some(child_workflow_id) = child_id {
                    self.cancel_child_workflow(
                        workflow_id,
                        child_workflow_id,
                        v.get("childExecutionName").and_then(|n| n.as_str()).unwrap_or(""),
                        v.get("reason").and_then(|r| r.as_str()).unwrap_or("Parent requested cancellation"),
                    ).await;
                }
            }
        }
    }
}
```

**Cancellation propagation method**:

```rust
impl WorkflowDispatchService {
    async fn cancel_child_workflow(
        &self,
        parent_id: Uuid,
        child_id: Uuid,
        child_name: &str,
        reason: &str,
    ) {
        // 1. Get child workflow
        let child = match self.workflow_repo.get(child_id).await {
            Ok(Some(w)) => w,
            Ok(None) => {
                self.record_cancellation_failed(parent_id, child_name, child_id, "Child workflow not found").await;
                return;
            }
            Err(e) => {
                self.record_cancellation_failed(parent_id, child_name, child_id, &e.to_string()).await;
                return;
            }
        };

        // 2. Check if child can be cancelled (Running or Waiting)
        let child_state = child.state();
        if child_state != WorkflowState::Running && child_state != WorkflowState::Waiting {
            self.record_cancellation_failed(
                parent_id,
                child_name,
                child_id,
                &format!("Child workflow not cancellable: state is {:?}", child_state)
            ).await;
            return;
        }

        // 3. Record CANCELLATION_REQUESTED event in child workflow
        let child_next_seq = self.event_repo.get_latest_sequence(child_id).await
            .unwrap_or(Ok(Some(0))).unwrap_or(Some(0)).unwrap_or(0) + 1;
        let cancel_event = WorkflowEvent::new(
            child_id,
            child_next_seq,
            EventType::CancellationRequested,
            Some(serde_json::to_vec(&serde_json::json!({
                "reason": reason,
                "requestedBy": parent_id.to_string(),
            })).unwrap_or_default()),
        );
        if let Err(e) = self.event_repo.append(&cancel_event).await {
            tracing::warn!(error = %e, "Failed to append cancellation event to child");
        }

        // 4. Update child workflow state to CANCELLING
        if let Err(e) = self.workflow_repo.update_state(child_id, "CANCELLING").await {
            tracing::warn!(error = %e, "Failed to update child workflow state");
        }

        // 5. Notify child workflow worker to pick up cancellation
        self.notifier.notify_work_available(child.tenant_id, child.task_queue);

        tracing::info!(
            parent_id = %parent_id,
            child_id = %child_id,
            child_name = %child_name,
            "Child workflow cancellation requested"
        );

        // Note: Parent will be notified when child completes/fails via the
        // existing handle_completed_child_workflows() scheduler logic
    }

    async fn record_cancellation_failed(&self, parent_id: Uuid, child_name: &str, child_id: Uuid, error: &str) {
        let next_seq = self.event_repo.get_latest_sequence(parent_id).await
            .unwrap_or(Ok(Some(0))).unwrap_or(Some(0)).unwrap_or(0) + 1;
        let event = WorkflowEvent::new(
            parent_id,
            next_seq,
            EventType::ChildWorkflowCancellationFailed,
            Some(serde_json::to_vec(&serde_json::json!({
                "childExecutionName": child_name,
                "childWorkflowExecutionId": child_id.to_string(),
                "error": error,
            })).unwrap_or_default()),
        );
        if let Err(e) = self.event_repo.append(&event).await {
            tracing::warn!(error = %e, "Failed to record cancellation failed event");
        }
    }
}
```

---

### 4. Workflow State Machine (Already Implemented)

The workflow state machine already includes cancellation states in `flovyn-server/src/domain/workflow.rs`:

```rust
pub enum WorkflowState {
    Pending,
    Running,
    Waiting,      // Note: Uses "Waiting" not "Suspended"
    Completed,
    Failed,
    Cancelled,    // Already exists
    Cancelling,   // Already exists
}
```

**State transitions** (for reference):
```
Running/Waiting → Cancelling (on CANCELLATION_REQUESTED)
Cancelling → Cancelled (when workflow acknowledges cancellation)
Cancelling → Failed (if cancellation handling fails)
```

No changes required to workflow state machine.

---

### 5. SDK Integration

The SDK will use these server features as follows:

| SDK Operation | Server Command/RPC | Server Event |
|---------------|-------------------|--------------|
| `task_future.cancel()` | `CancelTask` RPC | `TaskCancelled` |
| `timer_future.cancel()` | `CancelTimer` command | `TimerCancelled` (exists) |
| `child_workflow_future.cancel()` | `RequestCancelChildWorkflow` command | `ChildWorkflowFailed` (on success) or `ChildWorkflowCancellationFailed` |

**Child workflow cancellation flow**:
1. Parent sends `RequestCancelChildWorkflow` command
2. Server records `ChildWorkflowCancellationRequested` in parent
3. Server records `CancellationRequested` in child and sets child to `CANCELLING`
4. Child SDK handles cancellation and completes with `CANCELLED` state
5. Scheduler's `handle_completed_child_workflows()` notifies parent with `ChildWorkflowFailed`

---

## Event Summary

| Event Type | Trigger | Data Fields |
|------------|---------|-------------|
| `TaskCancelled` | `CancelTask` RPC | `taskExecutionId`, `taskType`, `reason` |
| `TimerCancelled` (exists) | `CancelTimer` command | `timerId` |
| `ChildWorkflowCancellationRequested` | `RequestCancelChildWorkflow` command | `childExecutionName`, `childWorkflowExecutionId`, `reason` |
| `ChildWorkflowCancellationFailed` | Cancellation failed | `childExecutionName`, `childWorkflowExecutionId`, `error` |
| `ChildWorkflowFailed` (exists) | Child cancelled/failed | `childExecutionName`, `childWorkflowExecutionId`, `error` |
| `CancellationRequested` | Parent/external cancellation | `reason`, `requestedBy` |

---

## Implementation Plan

### Phase 1: Domain Changes (`src/domain/`)
1. Add `TaskStatus::Cancelled` variant to `task.rs`
2. Add new event types to `workflow_event.rs`:
   - `TaskCancelled`
   - `ChildWorkflowCancellationRequested`
   - `ChildWorkflowCancellationFailed`
   - `CancellationRequested`

**Note**: `TimerCancelled`, `WorkflowState::Cancelling`, and `WorkflowState::Cancelled` already exist.

### Phase 2: Proto Updates
1. Add `REQUEST_CANCEL_CHILD_WORKFLOW = 14` command type
2. Add `RequestCancelChildWorkflowCommand` message
3. Regenerate Rust code with `cargo build`

### Phase 3: Implementation
1. Implement `cancel_task()` RPC handler (`flovyn-server/src/api/grpc/task_execution.rs`)
2. Add `CancelTimer` command handler in `process_command()` (`flovyn-server/src/api/grpc/workflow_dispatch.rs`)
3. Update `find_expired_timers()` to exclude cancelled timers (`flovyn-server/src/repository/event_repository.rs`)
4. Add `RequestCancelChildWorkflow` command handler in `process_command()`
5. Add cancellation propagation logic for child workflows

### Phase 4: Testing
1. Unit tests for each cancellation handler
2. Integration tests with SDK
3. E2E tests for parallel execution with cancellation

---

## References

- [SDK Parallel Execution Design](../../../dev/docs/design/parallel-execution.md)
- [Temporal Server Cancellation](https://github.com/temporalio/temporal) - Reference implementation
- [Kotlin Flovyn Server](../../../leanapp/flovyn) - Original implementation patterns
