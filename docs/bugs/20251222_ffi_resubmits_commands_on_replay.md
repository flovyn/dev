# Bug: Kotlin SDK Resubmits Commands During Replay

## Summary

When a workflow resumes after an external event (e.g., promise resolution, timer fire), the Kotlin SDK (via FFI) resubmits all commands including those that were already processed. This causes duplicate key errors in the database for commands like `CreatePromise`.

**Note**: The Rust SDK does NOT have this issue - it correctly checks for existing replay events before generating commands.

## Status

**Fixed** - Implemented FFI-level replay handling

## Environment

- Kotlin SDK (via FFI) - **affected**
- Rust SDK - **not affected**
- Flovyn Server
- Observed during E2E tests

## Symptoms

Server logs show warnings like:
```
WARN workflow.commands.submit: Failed to create promise record (may already exist)
promise_id=8adb052a-2d15-4045-9edf-06025755ac27:external-resolve-1766417223462
error=error returned from database: duplicate key value violates unique constraint "promise_pkey"
```

## Root Cause

The FFI `complete_workflow_activation` function submits all commands from the completion without distinguishing between:
1. **New commands** - generated during fresh execution
2. **Replayed commands** - regenerated during replay of already-processed events

When a workflow resumes:
1. Workflow re-executes from the beginning (replay mode)
2. `ctx.promise("name")` is called again during replay
3. FFI generates a `CreatePromise` command
4. FFI submits this command to the server
5. Server tries to insert the promise record, but it already exists

## Expected Behavior

During replay, the SDK should either:
1. Not generate commands for already-executed operations
2. Mark commands as "replay" so the server can skip them
3. Or the server should handle duplicates gracefully without warnings

## Current Behavior

- FFI always submits all commands
- Server attempts to insert duplicate records
- Server logs a warning but continues (graceful degradation)
- Functionality works correctly, but with unnecessary DB operations and log noise

## Potential Solutions

### Option 1: FFI Tracks Replay State
The FFI could receive replay information and skip command generation for replayed operations.

```rust
// In WorkflowActivation
pub struct WorkflowActivation {
    pub is_replaying: bool,
    pub last_replayed_sequence: i32,
    // ...
}
```

### Option 2: Server Uses Upsert
The server could use `INSERT ... ON CONFLICT DO NOTHING` for idempotent command processing.

```sql
INSERT INTO promise (id, workflow_execution_id, ...)
VALUES ($1, $2, ...)
ON CONFLICT (id) DO NOTHING
```

### Option 3: Command Deduplication in FFI
Track which commands have been submitted and filter duplicates.

## Impact

- **Functionality**: None - tests pass, workflows complete correctly
- **Performance**: Minor - unnecessary DB operations during replay
- **Observability**: Log noise from warnings

## Why Rust SDK Doesn't Have This Issue

The Rust SDK's `WorkflowContextImpl` checks for existing replay events before generating commands:

```rust
fn promise_raw(&self, name: &str) -> PromiseFutureRaw {
    // Look for event at this per-type index (replay case)
    if let Some(created_event) = self.promise_events.get(promise_seq as usize) {
        // Event exists → replay case, return future WITHOUT generating command
        return PromiseFuture::new(...);
    }

    // No event → new execution, generate command
    self.record_command(WorkflowCommand::CreatePromise { ... });
}
```

The Kotlin SDK's `WorkflowContextImpl` doesn't have access to replay events:

```kotlin
override suspend fun <T> promise(name: String, timeout: Duration?): DurablePromise<T> {
    // Always generates command - no replay check
    commands.add(FfiWorkflowCommand.CreatePromise(...))
    return PendingDurablePromise(name)
}
```

## Related

- Discovered while fixing: `promise-not-found-on-resolve.md`
- Affects: Promise creation, potentially timer creation, child workflow scheduling

## Files Involved

- `sdk-kotlin/core/.../WorkflowContextImpl.kt` - Command generation without replay check
- `sdk-rust/ffi/src/worker.rs` - `complete_workflow_activation()`
- `flovyn-server/src/api/grpc/workflow_dispatch.rs` - Command processing
- `sdk-rust/sdk/src/workflow/context_impl.rs` - Reference implementation with replay handling

## Resolution

### Solution Implemented

Implemented **Option A: FFI-Level Replay Handling** as designed in `sdk-rust/.dev/docs/design/ffi-replay-handling.md`.

The solution moves replay logic from language SDKs to the Rust FFI layer, providing consistent replay behavior across all language SDKs.

### Key Changes

1. **New `FfiWorkflowContext` object** (`sdk-rust/ffi/src/context.rs`):
   - Pre-filters replay events by type for O(1) lookup
   - Builds terminal event lookup maps (completed_tasks, resolved_promises, fired_timers)
   - Context methods check for existing events before generating commands
   - Only generates commands for NEW operations

2. **Updated `WorkflowActivation`** (`sdk-rust/ffi/src/activation.rs`):
   - Now includes `FfiWorkflowContext` reference
   - Context is created during `poll_workflow_activation()`

3. **Updated `CoreWorker`** (`sdk-rust/ffi/src/worker.rs`):
   - `poll_workflow_activation()` creates `FfiWorkflowContext` with parsed events
   - `complete_workflow_activation()` extracts commands from context via `take_commands()`

4. **Simplified Kotlin `WorkflowContextImpl`** (`sdk-kotlin/core/.../WorkflowContextImpl.kt`):
   - Now a thin wrapper that delegates all operations to `FfiWorkflowContext`
   - No longer manages commands directly
   - No longer maintains local replay state

### How Replay Works Now

```
┌─────────────────────────────────────────────────────────────┐
│ Kotlin SDK                                                  │
│   ctx.promise("name")                                       │
│   → calls ffiContext.createPromise("name")                  │
│   → receives FfiPromiseResult.Resolved or .Pending          │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│ Rust FFI (FfiWorkflowContext)                               │
│   1. Check if promise_seq < promise_events.len()            │
│   2. If YES (replay):                                       │
│      - Validate promise name matches                        │
│      - Return cached result (Resolved/Rejected/TimedOut)    │
│      - NO command generated                                 │
│   3. If NO (new):                                           │
│      - Generate CreatePromise command                       │
│      - Return Pending                                       │
└─────────────────────────────────────────────────────────────┘
```

### Verification

- **E2E Tests**: All 9 Kotlin SDK E2E tests pass
- **Server Logs**: No duplicate key warnings during replay
- **Test `test resolve promise externally()`**: Specifically tests workflow suspend/resume with external promise resolution - no duplicate CreatePromise commands

### Benefits

1. **Single replay implementation** - Only Rust code handles replay
2. **Determinism validation** - FFI validates operation names match during replay
3. **Simpler language SDKs** - Just call FFI methods, no replay logic
4. **Future SDKs benefit** - Python, Go, etc. get replay handling automatically
5. **No duplicate commands** - FFI only generates commands for new operations
