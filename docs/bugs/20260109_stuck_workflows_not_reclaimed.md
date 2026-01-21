# Bug Report: Workflows Stuck in RUNNING Status When Worker Dies

**Date:** 2026-01-09
**Severity:** High
**Status:** Fixed
**Component:** Scheduler / Worker Lifecycle

## Summary

When a worker dies or disconnects without gracefully completing its workflows, the workflows remain stuck in `RUNNING` status indefinitely. They are never reclaimed and re-dispatched to other workers.

## Reproduction Steps

1. Start a workflow that takes some time (e.g., `retry-workflow` with multiple attempts)
2. Kill the worker process while the workflow is running
3. Start a new worker with the same capabilities
4. Observe that the workflow remains stuck in `RUNNING` status and is never picked up by the new worker

## Expected Behavior

- The server should detect that the worker's heartbeat has expired (after 60 seconds based on `HEARTBEAT_TIMEOUT_SECONDS`)
- Workflows assigned to dead workers should be reclaimed and transitioned back to `PENDING` status
- The `worker_id` field should be cleared so other workers can claim the workflow

## Actual Behavior

- The workflow remains in `RUNNING` status with the old `worker_id` forever
- The `updated_at` timestamp is never updated
- New workers cannot claim the workflow because it's not in `PENDING` status

## Evidence

Example stuck workflow:
```sql
SELECT id, status, worker_id, updated_at FROM workflow_execution
WHERE id = '53b54b57-1a7f-4cb3-89fd-e67ef1262bcc';

                  id                  | status  |                  worker_id                  |          updated_at
--------------------------------------+---------+---------------------------------------------+-------------------------------
 53b54b57-1a7f-4cb3-89fd-e67ef1262bcc | RUNNING | worker-63767e2b-8bc3-4c2f-b7ae-a25753752f2b | 2026-01-07 15:51:15.220001+00
```

The workflow has been stuck for 2+ days. The worker `worker-63767e2b-8bc3-4c2f-b7ae-a25753752f2b` is no longer running.

## Root Cause Analysis

The infrastructure for reclaiming stuck workflows **exists but is not being used**:

### Existing (but unused) methods in `worker_repository.rs`:

```rust
/// Find workers with stale heartbeats (lines 277-293)
pub async fn find_stale_workers(&self) -> Result<Vec<Worker>, sqlx::Error> {
    let threshold = Utc::now() - Duration::seconds(HEARTBEAT_TIMEOUT_SECONDS);
    sqlx::query_as::<_, Worker>(
        r#"
        SELECT ... FROM worker
        WHERE status = 'ONLINE' AND last_heartbeat_at < $1
        "#,
    )
    .bind(threshold)
    .fetch_all(&self.pool)
    .await
}

/// Mark worker as offline (lines 295-307)
pub async fn mark_offline(&self, id: Uuid) -> Result<(), sqlx::Error> { ... }
```

### Missing: Workflow reclaim logic

There is no code that:
1. Periodically scans for stale workers
2. Finds workflows assigned to dead workers
3. Transitions those workflows back to `PENDING` status
4. Clears the `worker_id` field

## Proposed Fix

Add a new scheduled task in `scheduler.rs` to reclaim stuck workflows:

```rust
// In scheduler.rs - add to the scheduler loop

async fn reclaim_stuck_workflows(&self) -> Result<(), Error> {
    // 1. Find stale workers
    let stale_workers = self.worker_repo.find_stale_workers().await?;

    for worker in stale_workers {
        // 2. Mark worker as offline
        self.worker_repo.mark_offline(worker.id).await?;

        // 3. Find workflows assigned to this worker that are still RUNNING
        // 4. Transition them back to PENDING with worker_id = NULL
    }

    Ok(())
}
```

### New method needed in `workflow_repository.rs`:

```rust
/// Reclaim workflows from a dead worker
pub async fn reclaim_from_worker(&self, worker_id: &str) -> Result<u64, sqlx::Error> {
    let result = sqlx::query(
        r#"
        UPDATE workflow_execution
        SET status = 'PENDING',
            worker_id = NULL,
            updated_at = $1
        WHERE worker_id = $2 AND status = 'RUNNING'
        "#,
    )
    .bind(Utc::now())
    .bind(worker_id)
    .execute(&self.pool)
    .await?;

    Ok(result.rows_affected())
}
```

### Similar method needed for tasks in `task_repository.rs`

## Configuration Considerations

Consider adding configuration options:
- `workflow_reclaim_interval_secs`: How often to scan for stuck workflows (default: 30s)
- `workflow_stuck_timeout_secs`: How long a workflow can be RUNNING before being considered stuck (default: 2x heartbeat timeout = 120s)

## Related Files

- `flovyn-server//server/src/scheduler.rs` - Add reclaim task to scheduler loop
- `flovyn-server//server/src/repository/worker_repository.rs` - `find_stale_workers()`, `mark_offline()` (exist but unused)
- `flovyn-server//server/src/repository/workflow_repository.rs` - Add `reclaim_from_worker()`
- `flovyn-server//server/src/repository/task_repository.rs` - Add similar reclaim method for tasks
- `flovyn-server//crates/core/src/domain/worker.rs` - `HEARTBEAT_TIMEOUT_SECONDS = 60`

## Fix Applied

The following changes were made to fix this issue:

### 1. `flovyn-server/server/src/scheduler.rs`
- Added `stale_worker_check_interval` config (default: 30s)
- Added `reclaim_stuck_workflows()` function that:
  - Finds workers with stale heartbeats using existing `find_stale_workers()`
  - Marks them offline using existing `mark_offline()`
  - Reclaims their workflows using new `reclaim_from_worker(worker.worker_name)`
- Added `reclaim_orphaned_workflows()` call on scheduler startup to handle workflows stuck with offline workers

### 2. `flovyn-server/server/src/repository/workflow_repository.rs`
- Added `reclaim_from_worker(worker_id: &str)` - reclaims workflows from a specific worker
- Added `reclaim_orphaned_workflows()` - reclaims all workflows where the assigned worker is not ONLINE

### Key insight
The `workflow_execution.worker_id` column stores the worker NAME (e.g., `worker-63767e2b-...`), not the worker UUID. The reclaim function must use `worker.worker_name`, not `worker.id.to_string()`.
