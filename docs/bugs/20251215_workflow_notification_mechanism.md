# Bug Report: Missing Worker Notification Mechanism

**Status:** RESOLVED
**Date:** 2025-12-15
**Component:** Server gRPC API / WorkflowDispatch

## Summary

The Rust server's `subscribe_to_notifications` gRPC stream was not sending notifications to workers when new workflows were started. This caused inefficient polling where workers had to rely solely on timed intervals (100ms) to discover new work, rather than being immediately notified.

## Root Cause Analysis

### Expected Behavior (Kotlin Reference)

From the Kotlin server (`DbWorkflowQueue.kt`):

```kotlin
override suspend fun enqueue(workflow: WorkflowExecution) {
    // ... workflow creation ...

    // Notify workers
    notifier.notifyWorkAvailable(workflowWithPool.orgId, workflowWithPool.taskQueue)
}
```

The Kotlin server:
1. Creates workflows via `WorkflowStore.create()`
2. Immediately notifies subscribed workers via `WorkerNotifier`
3. Workers receive notification through `SubscribeToNotifications` gRPC stream
4. Workers poll immediately upon notification

### Actual Behavior (Rust Server - Before Fix)

```rust
// subscribe_to_notifications was just a stub
async fn subscribe_to_notifications(...) -> Result<Response<Self::SubscribeToNotificationsStream>, Status> {
    let (tx, rx) = mpsc::channel(100);

    // Just kept the stream alive without sending notifications
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(tokio::time::Duration::from_secs(30)).await;
            if tx.is_closed() {
                break;
            }
        }
    });

    Ok(Response::new(tokio_stream::wrappers::ReceiverStream::new(rx)))
}
```

The Rust server:
1. Created workflows successfully
2. **Did NOT notify workers** - `subscribe_to_notifications` was a stub
3. Workers relied on 100ms polling interval to discover work

### Impact

- Workers discovered new work with up to 100ms latency instead of immediately
- Less efficient resource usage due to unnecessary polling
- Tests still passed but were slower than optimal

## Investigation Notes

During investigation, we observed:

1. **Polling was working correctly:**
   ```
   poll_workflow: Query result workflow_found=true workflow_id=Some(80aa2f15-...)
   ```

2. **Workers were polling every ~100ms:**
   ```
   10:49:09.339 poll_workflow: Received poll request
   10:49:09.444 poll_workflow: Received poll request  (105ms later)
   10:49:09.553 poll_workflow: Received poll request  (109ms later)
   ```

3. **Workflows were being executed successfully** - the core polling mechanism was functional

4. **Initial hypothesis (disproven):** SDK was not polling during workflow execution
   - **Actual finding:** SDK was polling correctly, but without notifications it relied on timed intervals

## Resolution

### Changes Made

1. **Added `WorkerNotifier` struct** (`flovyn-server/src/api/grpc/mod.rs`):
   ```rust
   pub struct WorkerNotifier {
       sender: broadcast::Sender<WorkNotification>,
   }

   impl WorkerNotifier {
       pub fn notify_work_available(&self, org_id: Uuid, task_queue: String) {
           let notification = WorkNotification { org_id, task_queue };
           let _ = self.sender.send(notification);
       }

       pub fn subscribe(&self) -> broadcast::Receiver<WorkNotification> {
           self.sender.subscribe()
       }
   }
   ```

2. **Updated `subscribe_to_notifications`** to forward notifications:
   ```rust
   async fn subscribe_to_notifications(...) {
       let mut broadcast_rx = self.notifier.subscribe();

       tokio::spawn(async move {
           loop {
               match broadcast_rx.recv().await {
                   Ok(notification) => {
                       if notification.org_id == org_id && notification.task_queue == task_queue {
                           tx.send(Ok(WorkAvailableEvent { ... })).await;
                       }
                   }
                   // ... error handling
               }
           }
       });
   }
   ```

3. **Updated `start_workflow`** to notify workers:
   ```rust
   async fn start_workflow(...) {
       // ... create workflow ...

       if is_new {
           self.notifier.notify_work_available(org_id, task_queue.clone());
       }
   }
   ```

### Verification

Test output shows notifications being forwarded:
```
start_workflow: Notified workers of new workflow workflow_id=80aa2f15-...
subscribe_to_notifications: Forwarding notification to worker org_id=58260e83-...
poll_workflow: Received poll request  (immediate response to notification)
poll_workflow: Query result workflow_found=true
```

All tests pass:
```
✓ DoublerWorkflow passed
✓ EchoWorkflow passed
✓ StatefulWorkflow passed

=== All 3 basic workflow tests passed! ===
test result: ok. 1 passed; 0 failed; 0 ignored
```

## Future Work

1. **Resume notifications:** When workflows are resumed (after task completion, timer fired, promise resolved), notifications should also be sent
2. **NATS integration:** For distributed deployments, notifications should go through NATS instead of in-memory broadcast

## Files Changed

- `flovyn-server/src/api/grpc/mod.rs` - Added `WorkerNotifier` struct
- `flovyn-server/src/api/grpc/workflow_dispatch.rs` - Implemented notification forwarding
- `flovyn-server/src/main.rs` - Create notifier instance in `GrpcState`
