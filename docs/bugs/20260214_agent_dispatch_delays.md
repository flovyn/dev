# Bug: Agent Dispatch Delays (10+ minutes)

## Date
2026-02-14

## Status
**FIXED** - Concurrency support implemented in all workers

## Summary

Agent executions experience significant dispatch delays (up to 10+ minutes) when multiple agents are launched concurrently. This is caused by sequential worker execution in all three worker types.

## Observed Behavior

Production agent run `f0a8ac7e-8257-4ced-93d6-f144e6eddaec`:
- Created: 10:46:09
- Started: 10:56:11
- **Dispatch delay: 10 minutes**

A second agent `17b0f8e5-c7da-44da-89da-5751b768a8f0` launched 3 minutes later had a 7-minute delay.

## Root Cause

### Sequential Worker Execution

All three worker types execute work sequentially by default:

| Worker | Concurrency Infrastructure | Default Config | Behavior |
|--------|---------------------------|----------------|----------|
| WorkflowWorker | ✅ Semaphore + tokio::spawn | `max_concurrent: 1` | Sequential |
| TaskWorker | ❌ None | N/A | Sequential |
| AgentWorker | ❌ None | N/A | Sequential |

### Impact on Agent Execution

1. AgentWorker polls and picks up Agent A
2. Agent A calls LLM (30-60 seconds)
3. Agent A schedules tasks, suspends
4. AgentWorker is now free to poll Agent B
5. BUT if TaskWorker is already executing a task, Agent A's task waits
6. Agent B starts, calls LLM...
7. Sequential execution causes cascading delays

### Investigation Notes

**Initial hypothesis was incorrect:** I initially suspected the task polling query was excluding agent tasks via `agent_execution_id IS NULL`. However:

- `find_lock_and_mark_running()` has two modes: `standalone_only=true|false`
- The gRPC handler uses `standalone_only: false` (line 493 in task_execution.rs)
- With `standalone_only=false`, there's NO `agent_execution_id` filter
- Agent tasks ARE correctly polled by TaskWorker

The actual issue is purely **sequential execution**, not query filtering.

## Evidence

### Worker Code Analysis

**AgentWorker** (sdk-rust/worker-sdk/src/worker/agent_worker.rs):
```rust
async fn poll_and_execute(&mut self) -> Result<()> {
    let agent_info = self.client.poll_agent(...).await?;
    self.execute_agent(agent_info).await?;  // Blocks until complete
}
```

**TaskWorker** (sdk-rust/worker-sdk/src/worker/task_worker.rs):
```rust
async fn poll_and_execute(&mut self) -> Result<()> {
    let task_info = self.client.poll_task(...).await?;
    self.execute_task(task_info).await?;  // Blocks until complete
}
```

Neither has concurrency infrastructure like WorkflowWorker's semaphore pattern.

## Solution

See design document: `dev/docs/design/20260214_worker_concurrency.md`

### Implemented Changes

1. **TaskWorker** (`sdk-rust/worker-sdk/src/worker/task_worker.rs`):
   - Added `max_concurrent: usize` config field (default: 10)
   - Added `semaphore: Arc<Semaphore>` for concurrency control
   - Refactored `poll_and_execute` to static method with semaphore + tokio::spawn pattern
   - Tasks now execute concurrently up to `max_concurrent` limit

2. **AgentWorker** (`sdk-rust/worker-sdk/src/worker/agent_worker.rs`):
   - Added `max_concurrent: usize` config field (default: 5)
   - Added `semaphore: Arc<Semaphore>` for concurrency control
   - Refactored `poll_and_execute` to static method with semaphore + tokio::spawn pattern
   - Agents now execute concurrently up to `max_concurrent` limit

3. **WorkflowWorker** (`sdk-rust/worker-sdk/src/worker/workflow_worker.rs`):
   - Changed default `max_concurrent` from 1 to 10
   - Already had semaphore infrastructure, just needed default change

4. **Config** (`sdk-rust/worker-sdk/src/config/mod.rs`):
   - Added `AgentExecutorConfig` with `max_concurrent`, `heartbeat_interval`, `poll_timeout`
   - Added `agent_config` field to `FlovynClientConfig`
   - Added presets: `DEFAULT` (5), `HIGH_THROUGHPUT` (20), `LOW_RESOURCE` (2)
   - Exported `ClientAgentExecutorConfig` in public API

### Default Concurrency Limits

| Worker | Default | High Throughput | Low Resource |
|--------|---------|-----------------|--------------|
| WorkflowWorker | 10 | 50 | 2 |
| TaskWorker | 20 | 100 | 5 |
| AgentWorker | 5 | 20 | 2 |

### Configuration Example

```rust
let client = FlovynClient::builder()
    .server_url("http://localhost:9090")
    .config(FlovynClientConfig::high_throughput()) // 20 concurrent agents
    // Or custom:
    .config(FlovynClientConfig::default()
        .with_agent_config(AgentExecutorConfig {
            max_concurrent: 15,
            ..AgentExecutorConfig::DEFAULT
        }))
    .build()
    .await?;
```

## Timeline

- 2026-02-14: Issue identified during production agent monitoring
- 2026-02-14: Initial investigation (incorrect hypothesis about query filtering)
- 2026-02-14: Root cause confirmed as sequential worker execution
- 2026-02-14: Design document created for concurrency support
- 2026-02-14: Fix implemented - semaphore-based concurrency for all workers
- 2026-02-14: Added `AgentExecutorConfig` for proper config support

## Affected Components

- `sdk-rust/worker-sdk/src/worker/task_worker.rs`
- `sdk-rust/worker-sdk/src/worker/agent_worker.rs`
- `sdk-rust/worker-sdk/src/worker/workflow_worker.rs` (default value change)
- `sdk-rust/worker-sdk/src/config/mod.rs` (new `AgentExecutorConfig`)
- `sdk-rust/worker-sdk/src/client/flovyn_client.rs` (uses agent config)
- `sdk-rust/worker-sdk/src/lib.rs` (exports `ClientAgentExecutorConfig`)

## Notes

- This affects all LLM-heavy workloads, not just agents
- The fix is backward-compatible (default behavior can remain sequential)
- Configuration allows tuning without code changes
