# Design: Worker Concurrency Support

## Date
2026-02-14

## Status
DRAFT

## Problem Statement

Currently, all three worker types (Workflow, Task, Agent) execute work sequentially by default, causing significant performance issues:

1. **LLM requests block everything** - A 30-60 second LLM call blocks all other tasks
2. **Agent sessions queue up** - Multiple users launching agents wait minutes for their turn
3. **Underutilized resources** - Single-threaded execution wastes available CPU/memory

### Observed Impact

Production agent run `f0a8ac7e-8257-4ced-93d6-f144e6eddaec`:
- Created: 10:46:09
- Started: 10:56:11
- **Dispatch delay: 10 minutes**

A second agent `17b0f8e5-c7da-44da-89da-5751b768a8f0` launched 3 minutes later had a 7-minute delay.

## Current State Analysis

| Worker | Concurrency Infrastructure | Default Config | Behavior |
|--------|---------------------------|----------------|----------|
| WorkflowWorker | ✅ Semaphore + tokio::spawn | `max_concurrent: 1` | Sequential |
| TaskWorker | ❌ None | N/A | Sequential |
| AgentWorker | ❌ None | N/A | Sequential |

### WorkflowWorker (has infrastructure, wrong default)

```rust
// sdk-rust/worker-sdk/src/worker/workflow_worker.rs
pub struct WorkflowWorkerConfig {
    pub max_concurrent: usize,  // Default: 1
}

// Uses semaphore + spawn pattern
async fn poll_and_execute(...) {
    let permit = semaphore.acquire_owned().await?;
    let workflow_info = client.poll_workflow(...).await?;
    tokio::spawn(async move {
        let _permit = permit;
        Self::execute_workflow(...).await;
    });
}
```

### TaskWorker (no infrastructure)

```rust
// sdk-rust/worker-sdk/src/worker/task_worker.rs
async fn poll_and_execute(&mut self) -> Result<()> {
    let task_info = self.client.poll_task(...).await?;
    self.execute_task(task_info).await?;  // Blocks until complete
}
```

### AgentWorker (no infrastructure)

```rust
// sdk-rust/worker-sdk/src/worker/agent_worker.rs
async fn poll_and_execute(&mut self) -> Result<()> {
    let agent_info = self.client.poll_agent(...).await?;
    self.execute_agent(agent_info).await?;  // Blocks until complete
}
```

## Proposed Solution

### 1. Add Concurrency to TaskWorker

Add semaphore-based concurrency matching WorkflowWorker pattern:

```rust
pub struct TaskWorkerConfig {
    // Existing fields...

    /// Maximum concurrent task executions (NEW)
    pub max_concurrent: usize,
}

impl Default for TaskWorkerConfig {
    fn default() -> Self {
        Self {
            // ...
            max_concurrent: 10,  // Default to 10 concurrent tasks
        }
    }
}

pub struct TaskExecutorWorker {
    // Existing fields...

    semaphore: Arc<Semaphore>,  // NEW
}

impl TaskExecutorWorker {
    pub fn new(config: TaskWorkerConfig, ...) -> Self {
        Self {
            semaphore: Arc::new(Semaphore::new(config.max_concurrent)),
            // ...
        }
    }

    async fn poll_and_execute(&mut self) -> Result<()> {
        // Acquire permit (blocks if max_concurrent reached)
        let permit = self.semaphore.clone().acquire_owned().await?;

        let task_info = self.client.poll_task(...).await?;

        match task_info {
            Some(info) => {
                // Clone necessary state for spawned task
                let client = self.client.clone();
                let registry = self.registry.clone();

                tokio::spawn(async move {
                    let _permit = permit;  // Hold permit during execution
                    Self::execute_task_inner(client, registry, info).await;
                });
            }
            None => {
                drop(permit);  // Release immediately if no work
                tokio::time::sleep(self.config.no_work_backoff).await;
            }
        }

        Ok(())
    }
}
```

### 2. Add Concurrency to AgentWorker

Same pattern for agents:

```rust
pub struct AgentWorkerConfig {
    // Existing fields...

    /// Maximum concurrent agent executions (NEW)
    pub max_concurrent: usize,
}

impl Default for AgentWorkerConfig {
    fn default() -> Self {
        Self {
            // ...
            max_concurrent: 5,  // Default to 5 concurrent agents
        }
    }
}

pub struct AgentExecutorWorker {
    // Existing fields...

    semaphore: Arc<Semaphore>,  // NEW
}
```

### 3. Update WorkflowWorker Default

Change default from 1 to 10:

```rust
impl Default for WorkflowWorkerConfig {
    fn default() -> Self {
        Self {
            // ...
            max_concurrent: 10,  // Changed from 1
        }
    }
}
```

### 4. Unified Configuration

Update `FlovynClientConfig` to expose concurrency settings:

```rust
pub struct FlovynClientConfig {
    pub workflow_config: WorkflowExecutorConfig,
    pub task_config: TaskExecutorConfig,
    pub agent_config: AgentExecutorConfig,  // NEW
    // ...
}

// Builder pattern
FlovynClient::builder()
    .max_concurrent_workflows(10)
    .max_concurrent_tasks(20)
    .max_concurrent_agents(5)
    .build()
```

## Default Values

| Worker | Recommended Default | Rationale |
|--------|-------------------|-----------|
| Workflows | 10 | Workflows are lightweight, mostly waiting |
| Tasks | 20 | Mix of CPU-bound and I/O-bound |
| Agents | 5 | Agents are heavier, manage state |

For LLM-heavy workloads (like agent-worker), consider:
- Tasks: 50+ (LLM calls are I/O-bound, not CPU-bound)
- Agents: 10+ (each agent waits on LLM most of the time)

## Implementation Considerations

### Shared State

When spawning concurrent executions, ensure state is properly cloned/shared:

```rust
// These need to be Arc or Clone
let client = self.client.clone();       // gRPC client (Clone)
let registry = self.registry.clone();   // Arc<Registry>
let config = self.config.clone();       // Clone
```

### Graceful Shutdown

Track spawned tasks for clean shutdown:

```rust
struct TaskExecutorWorker {
    active_tasks: Arc<AtomicUsize>,
    // or
    task_handles: Arc<Mutex<Vec<JoinHandle<()>>>>,
}

async fn shutdown(&self) {
    // Wait for active tasks to complete
    while self.active_tasks.load(Ordering::SeqCst) > 0 {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}
```

### Backpressure

When all permits are taken, `semaphore.acquire()` blocks, providing natural backpressure. The worker won't poll for new work until a slot opens.

### Metrics

Add observability for concurrency:

```rust
// Track concurrent executions
gauge!("worker.concurrent_tasks").set(active_count);
gauge!("worker.concurrent_agents").set(active_count);

// Track permit wait time
histogram!("worker.permit_wait_ms").record(wait_time);
```

## Migration Path

1. **Phase 1**: Add infrastructure to TaskWorker and AgentWorker with conservative defaults
2. **Phase 2**: Update WorkflowWorker default from 1 to 10
3. **Phase 3**: Add configuration via environment variables for easy tuning
4. **Phase 4**: Add metrics and auto-tuning based on system resources

## Environment Variable Configuration

For operational flexibility without code changes:

```bash
FLOVYN_MAX_CONCURRENT_WORKFLOWS=10
FLOVYN_MAX_CONCURRENT_TASKS=20
FLOVYN_MAX_CONCURRENT_AGENTS=5
```

## Testing Plan

1. **Unit tests**: Verify semaphore limits concurrent executions
2. **Integration tests**: Multiple tasks/agents execute in parallel
3. **Load tests**: Verify performance improvement under concurrent load
4. **Stress tests**: Ensure graceful degradation when overloaded

## Files to Modify

**sdk-rust/worker-sdk/src/worker/task_worker.rs**
- Add `max_concurrent` to config
- Add `Semaphore` to worker struct
- Refactor `poll_and_execute` to spawn tasks

**sdk-rust/worker-sdk/src/worker/agent_worker.rs**
- Add `max_concurrent` to config
- Add `Semaphore` to worker struct
- Refactor `poll_and_execute` to spawn agents

**sdk-rust/worker-sdk/src/worker/workflow_worker.rs**
- Change default `max_concurrent` from 1 to 10

**sdk-rust/worker-sdk/src/config/mod.rs**
- Add `AgentExecutorConfig`
- Update defaults

**sdk-rust/worker-sdk/src/client/builder.rs**
- Add builder methods for concurrency config

## Success Criteria

1. Multiple agent sessions start within seconds, not minutes
2. LLM requests don't block other task types
3. Resource utilization improves (CPU, memory actually used)
4. No increase in error rates under concurrent load
5. Graceful shutdown waits for in-flight work
