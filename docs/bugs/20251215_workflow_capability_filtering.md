# Bug Report: Server Does Not Filter Workflows by Worker Capabilities

**Status:** OPEN
**Severity:** Medium
**Component:** Server gRPC API / WorkflowDispatch / poll_workflow

## Summary

When a worker polls for workflows, the server returns any PENDING workflow in the requested task queue, regardless of whether the worker has the capability to execute that workflow type. This can cause workers to pick up workflows they cannot execute, leading to execution failures or deadlocks.

## Problem Description

### Current Behavior

1. Worker A registers with capabilities: `["doubler-workflow", "echo-workflow"]`
2. Worker B registers with capabilities: `["comprehensive-workflow"]`
3. Both workers poll the same task queue ("default")
4. Server returns workflows based only on `org_id`, `task_queue`, and `state=PENDING`
5. Worker A might pick up "comprehensive-workflow" which it cannot execute
6. Worker A either fails to execute or ignores the workflow, leaving it stuck

### Expected Behavior (Kotlin Reference)

The Kotlin server filters workflows by worker capabilities during polling:

```sql
SELECT * FROM workflow_execution
WHERE org_id = ?
  AND task_queue = ?
  AND state = 'PENDING'
  AND kind IN (?, ?, ?)  -- Worker's registered workflow capabilities
ORDER BY created_at - priority_ms
FOR UPDATE SKIP LOCKED
LIMIT 1
```

The `PollRequest` in the proto includes `workflow_capabilities` for this purpose:

```protobuf
message PollRequest {
  string worker_id = 1;
  string org_id = 2;
  string task_queue = 3;
  repeated string workflow_capabilities = 4;  // <-- Should be used for filtering
  // ...
}
```

### Current Rust Server Query

```rust
// From workflow_repository.rs
pub async fn find_lock_and_mark_running(...) -> Result<Option<WorkflowExecution>, sqlx::Error> {
    sqlx::query_as!(
        WorkflowExecution,
        r#"
        UPDATE workflow_execution
        SET state = 'RUNNING', worker_id = $1, updated_at = NOW()
        WHERE id = (
            SELECT id FROM workflow_execution
            WHERE org_id = $2
              AND task_queue = $3
              AND state = 'PENDING'
            ORDER BY created_at - (priority_ms * interval '1 millisecond')
            FOR UPDATE SKIP LOCKED
            LIMIT 1
        )
        RETURNING *
        "#,
        worker_id, org_id, task_queue  // Missing: workflow_kind filter
    )
    .fetch_optional(&self.pool)
    .await
}
```

## Root Cause

The `poll_workflow` implementation in `workflow_dispatch.rs` ignores the `workflow_capabilities` field from the request and passes only `worker_id`, `org_id`, and `task_queue` to the repository query.

## Impact

1. **Stuck Workflows:** If Worker A picks up a workflow it can't execute, the workflow may remain in RUNNING state indefinitely
2. **Test Interference:** When running tests in parallel with different worker configurations, tests interfere with each other
3. **Production Issues:** In multi-workflow deployments, workers might claim work they can't handle

## Reproduction Steps

1. Create two workers with different workflow capabilities
2. Have both poll the same task queue
3. Start workflows of different types
4. Observe that either worker may claim either workflow type

### Test Output Showing Issue

```
[Worker A] poll_workflow: task_queue=default  -> picks up "comprehensive-workflow"
[Worker A] Cannot execute comprehensive-workflow (not registered)
[Worker B] poll_workflow: task_queue=default  -> no workflows found (A claimed it)
```

## Proposed Fix

### Option 1: Filter by workflow_capabilities (Recommended)

Update `workflow_dispatch.rs`:

```rust
async fn poll_workflow(&self, request: Request<PollRequest>) -> ... {
    let req = request.into_inner();

    // Extract capabilities
    let capabilities: Vec<String> = req.workflow_capabilities;

    // Pass to repository
    let workflow = self.workflow_repo
        .find_lock_and_mark_running(
            &req.worker_id,
            org_id,
            &req.task_queue,
            &capabilities,  // New parameter
        )
        .await?;
}
```

Update `workflow_repository.rs`:

```rust
pub async fn find_lock_and_mark_running(
    &self,
    worker_id: &str,
    org_id: Uuid,
    task_queue: &str,
    workflow_capabilities: &[String],  // New parameter
) -> Result<Option<WorkflowExecution>, sqlx::Error> {
    // Build dynamic query with IN clause for workflow_capabilities
    sqlx::query_as!(
        WorkflowExecution,
        r#"
        UPDATE workflow_execution
        SET state = 'RUNNING', worker_id = $1, updated_at = NOW()
        WHERE id = (
            SELECT id FROM workflow_execution
            WHERE org_id = $2
              AND task_queue = $3
              AND state = 'PENDING'
              AND kind = ANY($4)  -- Filter by capabilities
            ORDER BY created_at - (priority_ms * interval '1 millisecond')
            FOR UPDATE SKIP LOCKED
            LIMIT 1
        )
        RETURNING *
        "#,
        worker_id, org_id, task_queue, workflow_capabilities
    )
    .fetch_optional(&self.pool)
    .await
}
```

### Option 2: Return workflow without claiming if not capable (SDK-side)

The SDK could check if the returned workflow matches its capabilities before executing. However, this is less efficient as it requires releasing the workflow back to the queue.

## Workaround (Current)

Use different task queues for different workflow types to ensure workers only see workflows they can execute:

```rust
// Worker A
client_builder("worker-a")
    .task_queue("doubler-queue")
    .register_workflow(DoublerWorkflow)

// Worker B
client_builder("worker-b")
    .task_queue("comprehensive-queue")
    .register_workflow(ComprehensiveWorkflow)
```

This works but defeats the purpose of having multiple workflow types per worker and increases operational complexity.

## Related Files

- `flovyn-server/src/api/grpc/workflow_dispatch.rs` - poll_workflow implementation
- `flovyn-server/src/repository/workflow_repository.rs` - find_lock_and_mark_running query
- `sdk-rust/proto/flovyn.proto` - PollRequest with workflow_capabilities field

## References

- Kotlin implementation: `flovyn-server//Users/manhha/Developer/manhha/leanapp/flovyn/server/app/src/main/kotlin/ai/flovyn/queue/DbWorkflowQueue.kt`
- Proto definition: `/Users/manhha/Developer/manhha/flovyn/sdk-rust/proto/flovyn.proto`
