# Bug: Promise Not Found When Resolving Externally

## Summary

When a workflow creates a durable promise using `ctx.promise()` and suspends, attempting to resolve the promise externally via `client.resolvePromise()` fails with "Promise not found" error.

## Status

**Fixed** - Root cause identified and fix applied

## Environment

- Kotlin SDK (sdk-kotlin)
- Flovyn Server (Docker)
- E2E Test Environment

## Steps to Reproduce

1. Create a workflow that creates a promise and awaits it:
   ```kotlin
   class AwaitPromiseWorkflow : WorkflowDefinition<AwaitPromiseInput, AwaitPromiseOutput>() {
       override val kind = "await-promise-workflow"

       override suspend fun execute(ctx: WorkflowContext, input: AwaitPromiseInput): AwaitPromiseOutput {
           val promise = ctx.promise<String>(input.promiseName, Duration.ofSeconds(60))
           val resolvedValue = promise.await()
           return AwaitPromiseOutput(promiseName = input.promiseName, resolvedValue = resolvedValue)
       }
   }
   ```

2. Start the workflow:
   ```kotlin
   val executionId = client.startWorkflow("await-promise-workflow", AwaitPromiseInput(promiseName = "test-promise"))
   ```

3. Wait for workflow to be processed and create the promise

4. Try to resolve the promise externally:
   ```kotlin
   client.resolvePromise(executionId, "test-promise", "Hello!")
   ```

## Expected Behavior

The promise should be resolved and the workflow should continue execution with the resolved value.

## Actual Behavior

Error: `FfiException$Grpc: msg=Promise not found, code=5`

## Analysis

### Promise ID Format

The promise ID format used:
- **Workflow creates promise with ID**: `{promiseName}` (e.g., `test-promise`)
- **Client resolves with ID**: `{workflowExecutionId}:{promiseName}` (e.g., `uuid:test-promise`)

This matches the Rust SDK's format in `flovyn_client.rs:401`:
```rust
let promise_id = format!("{}:{}", workflow_execution_id, promise_name);
```

### Potential Issues

1. **Promise Command Not Reaching Server**: The `CreatePromise` command may not be properly submitted to the server when the workflow suspends.

2. **WorkflowWorker Completion Issue**: When `WorkflowSuspendedException` is caught, the commands (including `CreatePromise`) are sent via `completeWorkflowActivation`, but there may be errors (observed "Workflow not found" errors in logs).

3. **Server-Side Promise Registration**: The server may require additional information or a different flow to register promises.

4. **Timing Issue**: Even with 5 second delay, the promise might not be registered yet.

### Relevant Code Paths

**Kotlin SDK:**
- `WorkflowContextImpl.promise()` - Creates `FfiWorkflowCommand.CreatePromise`
- `WorkflowWorker.processActivation()` - Catches `WorkflowSuspendedException` and calls `completeWorkflowActivation`
- `FlovynClient.resolvePromise()` - Formats promise ID and calls FFI

**Rust FFI:**
- `ffi/src/client.rs:resolve_promise()` - Calls `WorkflowDispatch.resolve_promise()`

**Rust Core:**
- `core/src/client/workflow_dispatch.rs:resolve_promise()` - Sends gRPC request

## Files Involved

- `sdk-kotlin/core/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContextImpl.kt`
- `sdk-kotlin/core/src/main/kotlin/ai/flovyn/sdk/worker/WorkflowWorker.kt`
- `sdk-kotlin/core/src/main/kotlin/ai/flovyn/sdk/client/FlovynClient.kt`
- `sdk-rust/ffi/src/client.rs`
- `sdk-rust/core/src/client/workflow_dispatch.rs`

## Test Case

Located in: `sdk-kotlin/sdk-jackson/src/test/kotlin/ai/flovyn/sdk/e2e/WorkflowE2ETest.kt`

Test: `test resolve promise externally` (currently `@Disabled`)

## Next Steps

1. Add logging to trace the promise creation command flow
2. Verify the `CreatePromise` command is included in the activation completion
3. Check server logs for promise registration
4. Compare with Rust SDK's promise creation flow
5. Verify the promise ID format matches what the server expects

## Resolution

### Root Cause

The issue had two components in the FFI layer:

1. **FFI `run_id` was incorrect** (`sdk-kotlin/ffi/src/worker.rs`): The activation was setting `run_id` to a random UUID instead of the `workflow_execution_id`, causing "Workflow not found" when completing activations.

2. **FFI was not submitting commands** (`sdk-kotlin/ffi/src/worker.rs`): The `complete_workflow_activation` function was calling `suspend_workflow` with an empty vector `vec![]` instead of the actual commands, so the `CreatePromise` command was never sent to the server.

### Fixes Applied

**1. Fixed run_id in FFI activation** (`ffi/src/worker.rs:204`):
```rust
// Before: run_id: Uuid::new_v4().to_string(),
// After:
run_id: workflow_info.id.to_string(),
```

**2. Added proto command conversion** (`sdk-kotlin/ffi/src/command.rs`):
Added `to_proto_command()` method to `FfiWorkflowCommand` to convert FFI commands to protobuf format for gRPC submission.

**3. Fixed command submission** (`ffi/src/worker.rs:251-264`):
```rust
// Convert FFI commands to proto commands for gRPC submission
let proto_commands: Vec<flovyn_core::generated::flovyn_v1::WorkflowCommand> = completion
    .commands
    .iter()
    .enumerate()
    .map(|(i, cmd)| cmd.to_proto_command(i as i32 + 1))
    .collect();

// Submit commands to server
dispatch_client
    .suspend_workflow(workflow_execution_id, proto_commands)
    .await
```

### Verification

**Rust SDK E2E Tests**: All 58 tests pass
- `test_promise_resolve` - PASSED
- `test_promise_reject` - PASSED

**Kotlin SDK E2E Tests**: All 5 tests pass
- `test resolve promise externally` - PASSED (now enabled)
- `test promise workflow creates promise` - PASSED
- `test simple echo workflow execution` - PASSED
- `test sleep workflow with timer` - PASSED

### Files Modified

- `sdk-rust/ffi/src/worker.rs` - Fixed run_id and command submission
- `sdk-rust/ffi/src/command.rs` - Added `to_proto_command()` method
- `sdk-kotlin/sdk-jackson/src/test/kotlin/ai/flovyn/sdk/e2e/WorkflowE2ETest.kt` - Removed @Disabled from promise test

## Related

- Step 11 of Phase 3 Kotlin SDK implementation
- `resolvePromise()` and `rejectPromise()` APIs now work correctly
- E2E tests verify promise functionality in both SDKs
