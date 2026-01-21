# Bug: SSE Streaming Not Working for Standalone Tasks

**Date:** 2026-01-04
**Severity:** High
**Component:** Streaming / SSE / NATS / SDK

## Summary

Server-Sent Events (SSE) streaming does not deliver events for standalone task executions. The SSE connection establishes successfully (200 OK) but no events are received by the client.

## Investigation Log

### Issue 1: NATS Subject Mismatch (FIXED)

**Status:** Fixed in server

When a standalone task (no workflow_execution_id) was polled and started, the NATS subject was incorrectly built using an empty string.

**Publishing Side (`api/grpc/task_execution.rs:291-305`)**

```rust
workflow_execution_id: t
    .workflow_execution_id
    .map(|id| id.to_string())
    .unwrap_or_default(),  // ← EMPTY for standalone tasks
```

**Result:**
- Published to: `flovyn.streams.workflow.` (empty ID)
- Subscribed to: `flovyn.streams.workflow.{task_id}` (with UUID)
- Mismatch = No events delivered

**Fix Applied:** Changed `unwrap_or_default()` to `unwrap_or_else(|| task_id.to_string())` in 4 locations:
- TASK_STARTED event (line ~294)
- TASK_COMPLETED event (line ~444)
- TASK_FAILED event (line ~668)
- SDK StreamTaskData endpoint (line ~1210)

### Issue 2: SDK Not Sending Progress to Server (ROOT CAUSE)

**Status:** FIXED - SDK changes implemented

**Fix Applied:** Modified `task_worker.rs` to wire up progress callbacks to gRPC:
- Added `create_task_callbacks()` method that creates a channel-based forwarder
- Single background task receives progress/log events via channel and sends to server via gRPC
- Channel closes automatically when task completes (callbacks are dropped)
- Uses `report_progress()` and `log_message()` gRPC endpoints

**Evidence from code tracing (original issue):**

1. **Task worker calls executor.execute()** (`sdk-rust/sdk/src/worker/task_worker.rs:443-451`):
   ```rust
   let result = self.executor.execute(
       task_execution_id,
       task_type,
       task_info.input,
       task_info.execution_count,
   ).await;
   ```

2. **executor.execute() uses default callbacks** (`sdk-rust/sdk/src/task/executor.rs:98-103`):
   ```rust
   pub async fn execute(...) -> TaskExecutionResult {
       self.execute_with_callbacks(
           ...
           TaskExecutorCallbacks::default(),  // ALL CALLBACKS ARE None!
       )
   }
   ```

3. **TaskExecutorCallbacks::default() has all callbacks as None** (`sdk-rust/sdk/src/task/executor.rs:52-63`):
   ```rust
   pub struct TaskExecutorCallbacks {
       pub on_progress: Option<Box<dyn Fn(f64, Option<String>) + Send + Sync>>,
       pub on_log: Option<Box<dyn Fn(String, String) + Send + Sync>>,
       pub on_heartbeat: Option<Box<dyn Fn() + Send + Sync>>,
       pub on_stream: Option<Box<dyn Fn(StreamEvent) + Send + Sync>>,
   }
   ```

4. **When ctx.report_progress() is called, nothing happens** (`sdk-rust/sdk/src/task/context_impl.rs:169-188`):
   ```rust
   async fn report_progress(&self, progress: f64, message: Option<&str>) -> Result<()> {
       ...
       if let Some(ref reporter) = self.progress_reporter {
           // ... call reporter
       } else {
           Ok(())  // <-- NO-OP when callback is None
       }
   }
   ```

**Conclusion:**
The SDK sample DOES call `ctx.report_progress()` (standalone-tasks/src/main.rs:109), but this is a no-op because the task worker doesn't wire up progress callbacks to send to the server via gRPC.

## Root Cause Summary

1. **NATS subject mismatch** (Fixed) - Server was publishing to wrong NATS subject for standalone tasks
2. **SDK doesn't send progress** (Fixed) - Task worker now uses `create_task_callbacks()` to wire up progress/log callbacks to gRPC

## Steps to Reproduce

1. Start flovyn-server with NATS enabled
2. Start a standalone task worker (e.g., `standalone-tasks-sample`)
3. Create a standalone task execution via UI or API
4. Open the task detail panel in the UI
5. Observe: SSE connection established (200 OK) but no progress events received

## How to Launch Test Environment

### Terminal 1: Start Server
```bash
cd ~/Developer/manhha/flovyn/dev
just server saas
```

### Terminal 2: Start Web App
```bash
cd ~/Developer/manhha/flovyn/dev
just app
```

### Terminal 3: Build and Start SDK Worker (with debug logging)
```bash
cd /Users/manhha/Developer/manhha/flovyn/sdk-rust
cargo build --release -p standalone-tasks-sample
cd examples
RUST_LOG=debug /Users/manhha/Developer/manhha/flovyn/sdk-rust/target/release/standalone-tasks-sample
```

### Browser
- Navigate to: http://localhost:3000/org/htoh/tasks/data-export-task
- Click "Run" to create a new task execution
- Input JSON: `{"format": "csv", "dataset_name": "test", "record_count": 100}`
- Open browser console to monitor SSE events (filter: "TaskStream")

## Expected Behavior

- Progress events should stream to the UI in real-time
- Status change events (TASK_STARTED, TASK_COMPLETED) should be delivered
- The progress bar should update without manual refresh

## Actual Behavior (After Fixes)

- SSE connection opens successfully
- TASK_STARTED/TASK_COMPLETED events are delivered (server fix)
- **Initial** progress event is delivered with progress message (SDK fix)
- Progress bar shows initial progress (e.g., "Processing batch 2/10 (10 records)")
- **BUG:** Subsequent progress updates are NOT delivered - progress bar stays stuck at initial value

## Evidence

### Server logs after NATS fix
```
INFO sse.task_executions.stream: Starting SSE stream for task task_execution_id=02d2ac16-6cc1-4982-96aa-fa7b5a8aa303
DEBUG flovyn_server::streaming::nats: Subscribed to NATS stream subject=flovyn.streams.workflow.02d2ac16-6cc1-4982-96aa-fa7b5a8aa303
```
Subject now correctly uses task_execution_id.

### Browser console
```
[TaskStream] Connected to SSE stream
```
No "Received data event" logs = no events being delivered.

### Worker logs
```
Processing export batch batch=3 records=10
Export progress checkpoint batch=3 total_exported=30 progress_pct="30.0%"
```
Worker IS calling report_progress, but it's not being sent to server.

## Proposed Fix

### For SDK (Required for progress streaming)

The `TaskExecutorWorker` needs to wire up callbacks to send progress via gRPC:

```rust
// In task_worker.rs poll_and_execute()
let callbacks = TaskExecutorCallbacks {
    on_progress: Some(Box::new({
        let client = self.client.clone();
        let task_id = task_execution_id;
        move |progress, message| {
            // Fire-and-forget gRPC call to StreamTaskData
            // or batch and send periodically
        }
    })),
    on_log: Some(...),
    on_stream: Some(...),
    on_heartbeat: None,
};

let result = self.executor.execute_with_callbacks(
    task_execution_id,
    task_type,
    task_info.input,
    task_info.execution_count,
    callbacks,  // Pass callbacks instead of default
).await;
```

## Related Files

### Server (NATS fix applied)
- `flovyn-server/server/src/api/grpc/task_execution.rs` - Publishing stream events
- `flovyn-server/server/src/api/rest/streaming.rs` - SSE endpoint and subscription
- `flovyn-server/server/src/streaming/nats.rs` - NATS publish/subscribe implementation

### SDK (Needs progress callback wiring)
- `sdk-rust/sdk/src/worker/task_worker.rs` - Task polling and execution
- `sdk-rust/sdk/src/task/executor.rs` - TaskExecutor and callbacks
- `sdk-rust/sdk/src/task/context_impl.rs` - TaskContext implementation

### Issue 4: Task List Not Updating When Detail Panel Receives SSE Events (FIXED)

**Status:** FIXED in frontend

**Root Cause:**
The `handleTaskUpdate` callback in `TaskExecutionDetailPanel.tsx` only updated the single-task query cache but NOT the list query cache. When SSE events arrived (e.g., TASK_COMPLETED), the detail panel showed the correct status but the list still showed "Running".

**Fix Applied:**
Modified `handleTaskUpdate` in `flovyn-server/apps/web/components/tasks/TaskExecutionDetailPanel.tsx` to also update the list cache:
```typescript
// Also update the task in any list queries that contain it
const listQueryKeyPrefix = ['api', 'orgs', orgSlug, 'task-executions'];
queryClient.setQueriesData<{ tasks: TaskResponse[] }>(
  { queryKey: listQueryKeyPrefix },
  (oldData) => {
    if (!oldData?.tasks) return oldData;
    const taskIndex = oldData.tasks.findIndex((t) => t.id === taskId);
    if (taskIndex === -1) return oldData;
    const updatedTasks = [...oldData.tasks];
    updatedTasks[taskIndex] = { ...updatedTasks[taskIndex], ...updates } as TaskResponse;
    return { ...oldData, tasks: updatedTasks };
  }
);
```

## Testing

After all fixes, verify:
1. [x] NATS subject uses task_execution_id for standalone tasks (server fix - Issue 1)
2. [x] Progress events are sent to server via gRPC (SDK fix - Issue 2)
3. [x] Server publishes progress events to NATS (server fix - Issue 3)
4. [x] Status change events (TASK_STARTED, TASK_COMPLETED) are delivered
5. [x] Real-time progress bar updates work (verified 2026-01-05)
6. [x] Real-time progress message updates work (verified 2026-01-05)
7. [ ] Workflow task streaming still works correctly
8. [ ] No regression in workflow SSE streaming
9. [x] Task list updates in real-time when detail panel receives SSE events (frontend fix - Issue 4)

## Final Test Results (2026-01-05 06:53)

Task `633793f0-cc88-4620-90ef-2f7e2b056660` completed successfully:
- SSE connection established ✓
- Progress events received via SSE in real-time ✓
- Progress bar updated from 10% → 100% ✓
- Progress message updated in real-time ("batch 6/10" → "batch 8/10" → completed) ✓
- TASK_COMPLETED event received ✓
- Duration: 262s ✓

## Test Results (2026-01-04 22:16)

Created new task execution `cb617599-19e4-44bc-a6d6-36ef13b28100`:
- SSE connection established ✓
- Progress message displayed: "Processing batch 2/10 (10 records)" ✓
- Progress bar shows ~20% progress ✓
- TASK_COMPLETED event received in browser console ✓

### Issue 3: Server Not Publishing Progress to NATS (FIXED)

**Status:** FIXED in server

**Root Cause:**
The server's `report_progress` gRPC handler (`task_execution.rs:754-790`) only updated the database, NOT publishing to NATS.

**Fix Applied:**
Added NATS publishing to `report_progress` handler (`task_execution.rs:789-807`):
```rust
// Publish progress event to NATS for SSE streaming
let workflow_execution_id = task
    .workflow_execution_id
    .map(|id| id.to_string())
    .unwrap_or_else(|| task_id.to_string());

// Progress payload is just the number (frontend expects parseFloat-compatible value)
let stream_event = StreamEvent {
    task_execution_id: task_id.to_string(),
    workflow_execution_id,
    sequence: 0,
    event_type: StreamEventType::Progress,
    payload: req.progress.to_string(),
    timestamp_ms: Utc::now().timestamp_millis(),
};

if let Err(e) = self.state.stream_publisher.publish(stream_event).await {
    tracing::warn!(error = %e, "Failed to publish progress stream event");
}
```
