# Design: Remove WorkerNotifier

**Date**: 2026-01-12
**Status**: Draft
**Author**: [TBD]

## Summary

Remove the `WorkerNotifier` push notification system from the server and SDKs. Workers will rely solely on polling with configurable backoff intervals.

## Background

### Current Architecture

The `WorkerNotifier` is a tokio broadcast channel that pushes notifications to all connected workers when work becomes available:

```
┌─────────────────────────────────────┐
│   WorkerNotifier (broadcast sender) │
│   Capacity: 1000 notifications      │
└──────────────┬──────────────────────┘
               │ notify_work_available(org_id, queue)
               │
   ┌───────────┼───────────┬───────────────────┐
   │           │           │                   │
┌──▼──┐     ┌──▼──┐     ┌──▼──┐            ┌──▼──┐
│ W1  │     │ W2  │     │ W3  │   ...      │ WN  │
│filter│    │filter│    │filter│           │filter│
└─────┘     └─────┘     └─────┘            └─────┘
```

**Flow:**
1. Server component calls `notifier.notify_work_available(org_id, queue)`
2. Notification sent to broadcast channel
3. **All N workers** receive the notification
4. Each worker filters by org_id and queue locally
5. Matching workers poll immediately

### Problem: Thundering Herd

When work becomes available, the notification goes to **all connected workers**, not just those that can handle the work. With many workers (e.g., 100 workers, 10 queues), a single notification triggers:
- 100 network events (server → workers)
- Up to 100 immediate poll requests back to server
- Only ~10 workers (1 queue) actually need the notification

This design doesn't scale well and adds complexity without clear benefit at the MVP stage.

### Origin

This was ported from the legacy Kotlin server design. The original implementation assumed a fully-featured orchestration server where instant work discovery was critical. For MVP, the 100ms polling fallback is sufficient.

## Motivation for Removal

1. **Premature optimization**: The 100ms polling interval provides acceptable latency for most use cases. Notifications add complexity for marginal improvement.

2. **Scalability concern**: Broadcast-to-all doesn't scale. Proper solution requires queue-specific channels or pub/sub routing (e.g., NATS subjects per queue).

3. **Code complexity**: 24+ notification call sites across the codebase. Each new feature that creates work must remember to notify.

4. **Testing overhead**: Notification logic adds edge cases (stream disconnection, lag, filtering).

5. **SDK complexity**: Each SDK must implement notification subscription, reconnection logic, and coordination with polling.

### What About Latency?

Without notifications, worst-case latency to discover work is the polling interval (default 100ms). For most workflow use cases, this is acceptable:

| Scenario | With Notifications | Without (100ms poll) |
|----------|-------------------|---------------------|
| Interactive UI | Instant | Up to 100ms |
| Background jobs | Instant | Up to 100ms |
| Scheduled tasks | Instant | Up to 100ms |

If sub-100ms latency becomes critical, we can implement a proper solution (e.g., NATS-based pub/sub) rather than the current broadcast approach.

## Scope of Changes

### In Scope

| Component | Changes |
|-----------|---------|
| **flovyn-server** | Remove WorkerNotifier, remove all notify_work_available calls, remove gRPC SubscribeToNotifications handler |
| **sdk-rust** | Remove notification subscription loop, remove `enable_notifications` config, simplify worker loops |
| **sdk-kotlin** | Remove any notification-related code (if exists) |

### Out of Scope

- NATS integration (existing NATS code is separate from WorkerNotifier)
- Changing polling intervals (keep current 100ms default)
- Adding new notification mechanism

## Detailed Changes

### flovyn-server

#### 1. Remove WorkerNotifier struct

**File:** `flovyn-server/server/src/api/grpc/mod.rs`

Remove:
```rust
pub struct WorkNotification { ... }
pub struct WorkerNotifier { ... }
impl WorkerNotifier { ... }
```

#### 2. Remove notifier from GrpcState and AppState

**Files:**
- `flovyn-server/server/src/api/grpc/mod.rs` - Remove from `GrpcState`
- `flovyn-server/server/src/api/rest/mod.rs` - Remove from `AppState`
- `flovyn-server/server/src/main.rs` - Remove notifier creation and injection

#### 3. Remove all notify_work_available calls

**Locations (24+ call sites):**

| File | Lines | Context |
|------|-------|---------|
| `flovyn-server/api/grpc/workflow_dispatch.rs` | 267, 361, 813, 1105, 1268, 1594, 1978 | Workflow start, child completion, promise resolution |
| `flovyn-server/api/grpc/task_execution.rs` | 536, 648, 755 | Task completion/failure |
| `flovyn-server/api/rest/workflows.rs` | 624, 1478 | REST workflow trigger |
| `flovyn-server/api/rest/tasks.rs` | 515 | Standalone task creation |
| `flovyn-server/api/rest/promises.rs` | 311, 478 | Promise resolution |
| `flovyn-server/api/rest/schedules.rs` | 1564 | Schedule firing |
| `scheduler.rs` | 245, 442, 600, 871, 908 | Timer, child workflow, reclaim, schedules |
| `flovyn-server/service/workflow_launcher.rs` | 183 | Workflow launch |
| `flovyn-server/service/task_launcher.rs` | 192 | Task launch |
| `flovyn-server/service/promise_resolver.rs` | 247, 329 | Promise resolution |

#### 4. Remove subscribe_to_notifications RPC handler

**File:** `flovyn-server/server/src/api/grpc/workflow_dispatch.rs`

Remove or stub the `subscribe_to_notifications` method. Options:
- **Option A**: Remove entirely and update proto (breaking change)
- **Option B**: Keep stub that returns empty stream (backward compatible)

**Recommendation**: Option B for SDK compatibility during transition.

#### 5. Update proto (optional)

**File:** `proto/flovyn.proto`

If removing the RPC entirely, remove:
```protobuf
rpc SubscribeToNotifications(SubscriptionRequest) returns (stream WorkAvailableEvent);
message SubscriptionRequest { ... }
message WorkAvailableEvent { ... }
```

### sdk-rust

**Path:** `../sdk-rust/sdk/src/worker/`

#### 1. Remove notification subscription from WorkflowWorker

**File:** `workflow_worker.rs`

**Remove from WorkflowWorkerConfig (lines 27-63):**
```rust
/// Enable notification subscription for instant work notifications
pub enable_notifications: bool,  // line 51, default: true at line 79
```

**Remove from WorkflowExecutorWorker struct (lines 112-134):**
```rust
/// Notify when work is available (from notification subscription)
work_available_notify: Arc<Notify>,  // line 127
```

**Remove notification_subscription_loop method (lines 250-318):**
- Entire `async fn notification_subscription_loop(...)` method
- Handles subscribing to `subscribe_to_notifications` gRPC stream
- Calls `work_available_notify.notify_one()` when notifications received

**Remove from start() method (lines 377-393):**
```rust
// Start notification subscription loop in background (if enabled)
if self.config.enable_notifications {
    // ... spawns notification_subscription_loop
}
```

**Simplify poll_and_execute (lines 612-627):**

Current code waits on notification OR timeout:
```rust
None => {
    drop(permit);
    tokio::select! {
        _ = work_available_notify.notified() => {
            debug!("Work available notification received, polling immediately");
        }
        _ = tokio::time::sleep(config.no_work_backoff) => {
            // Regular poll interval
        }
    }
    Ok(())
}
```

Simplified code (just timeout):
```rust
None => {
    drop(permit);
    tokio::time::sleep(config.no_work_backoff).await;
    Ok(())
}
```

**Remove work_available_notify from constructor (lines 136-170):**
- Remove field initialization: `work_available_notify: Arc::new(Notify::new()),`
- Remove clone in start(): `let work_available_notify = self.work_available_notify.clone();`
- Remove parameter in poll_and_execute call

#### 2. Update WorkflowWorkerConfig

**File:** `workflow_worker.rs`

Remove config field and its default:
- Line 51: `pub enable_notifications: bool,`
- Line 79: `enable_notifications: true,`

Keep:
```rust
pub no_work_backoff: Duration,  // Line 37, default: 100ms at line 72
```

#### 3. TaskWorker - No changes needed

**File:** `task_worker.rs`

TaskWorkerConfig does NOT have `enable_notifications` - it was never implemented.
TaskWorker already uses simple polling with `no_work_backoff` (lines 413-417):
```rust
None => {
    // No task available - wait before next poll to avoid tight loop
    tokio::time::sleep(self.config.no_work_backoff).await;
    return Ok(());
}
```

No changes required for TaskWorker.

### sdk-kotlin

**Path:** `../sdk-kotlin/`

Review and remove any notification-related code. Based on exploration, Kotlin SDK may not have notification subscription implemented yet.

## Testing Strategy

### Automated Tests

1. **Integration tests**: All existing tests should pass since they already work with 100ms polling fallback
2. **Run multiple times**: Use `./bin/dev/run-tests-loop.sh 10` to verify no flakiness introduced

### Manual Verification

1. Start server without WorkerNotifier
2. Connect sdk-rust worker
3. Trigger workflow via REST API
4. Verify workflow executes within ~100ms (polling interval)

### Performance Baseline

Document before/after metrics:
- Server idle CPU with N workers connected
- Workflow discovery latency
- Memory usage

## Migration / Backward Compatibility

**Backward compatibility is NOT a concern** for this change:

1. SDKs are internal and versioned together with server
2. No external consumers of the notification gRPC stream
3. Workers gracefully fall back to polling when notifications unavailable

If keeping the proto RPC for compatibility, the stub implementation should:
- Accept connections
- Never send events
- Close stream after reasonable timeout (e.g., 30s)

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Increased latency | Low | Low | 100ms polling is acceptable for MVP |
| Higher server load from polling | Low | Low | Polling already happens; notifications just reduce some polls |
| Future need for instant notification | Medium | Medium | Can implement proper solution (NATS pub/sub) when needed |

## Future Considerations

If instant work notification becomes necessary post-MVP, consider:

1. **NATS subjects per queue**: `work.{org_id}.{queue}` - workers subscribe to their queues only
2. **Server-Sent Events (SSE)**: Lighter than gRPC streaming
3. **WebSocket per queue**: Targeted notification

These approaches avoid the broadcast-to-all problem of the current design.

## Decision

**Recommendation**: Proceed with removal.

The WorkerNotifier adds complexity without proportional benefit at the MVP stage. The 100ms polling fallback provides acceptable latency, and the code simplification improves maintainability.

---

## Appendix: Files to Modify

### flovyn-server
- `flovyn-server/server/src/api/grpc/mod.rs`
- `flovyn-server/server/src/api/grpc/workflow_dispatch.rs`
- `flovyn-server/server/src/api/grpc/task_execution.rs`
- `flovyn-server/server/src/api/rest/mod.rs`
- `flovyn-server/server/src/api/rest/workflows.rs`
- `flovyn-server/server/src/api/rest/tasks.rs`
- `flovyn-server/server/src/api/rest/promises.rs`
- `flovyn-server/server/src/api/rest/schedules.rs`
- `flovyn-server/server/src/scheduler.rs`
- `flovyn-server/server/src/service/workflow_launcher.rs`
- `flovyn-server/server/src/service/task_launcher.rs`
- `flovyn-server/server/src/service/promise_resolver.rs`
- `flovyn-server/server/src/main.rs`
- `proto/flovyn.proto` (optional)

### sdk-rust
- `flovyn-server/sdk/src/worker/workflow_worker.rs` - Remove notification subscription, simplify polling
- `flovyn-server/sdk/src/client/mod.rs` - Check for `subscribe_to_notifications` client method (may need removal or keep as dead code initially)

### sdk-kotlin
- `sdk/src/main/kotlin/` - Check for notification-related code (likely none based on exploration)
