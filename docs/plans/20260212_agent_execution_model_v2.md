# Agent Execution Model v2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Unify agent and workflow execution models with lazy task scheduling, command batching, and pluggable storage backends.

**Architecture:** Introduce abstraction traits (`AgentStorage`, `TaskExecutor`, `SignalSource`) that decouple agent execution from the server. Refactor `AgentContextImpl` to batch commands and commit atomically at suspension points. Add lazy `AgentTaskFutureRaw` that mirrors workflow's `TaskFutureRaw`.

**Tech Stack:** Rust, async-trait, sqlx (for SQLite), tokio channels, existing gRPC client.

**Design Doc:** [Agent Execution Model v2](../design/20260212_agent_execution_model_v2.md)

---

## CRITICAL: API Design Decisions

> **NO BACKWARD COMPATIBILITY** - These decisions are final and must be followed exactly.

### 1. Method Naming - Align with Workflow API

The agent API MUST use the same naming as the workflow API:

| Workflow API | Agent API (NEW) | Agent API (OLD - REMOVE) |
|--------------|-----------------|--------------------------|
| `schedule_raw()` | `schedule_raw()` | ~~`schedule_task_raw()`~~ |
| `schedule_with_options_raw()` | `schedule_with_options_raw()` | ~~`schedule_task_handle_with_options()`~~ |
| `TaskFutureRaw` | `AgentTaskFutureRaw` | - |

### 2. Remove ALL Legacy APIs

The following methods MUST be completely removed (not deprecated, REMOVED):

- `schedule_task_raw()` - replaced by `schedule_raw()`
- `schedule_task_handle()` - replaced by `schedule_raw()`
- `schedule_task_handle_with_options()` - replaced by `schedule_with_options_raw()`
- All old combinators that used `AgentTaskHandle`

### 3. No Compatibility Shims

- NO aliases pointing old names to new names
- NO re-exports of old method names
- NO "deprecated" attributes - just delete the old code
- NO `_legacy` or `_compat` variants

If code references old APIs, it must be updated. Period.

---

## Phase 1: Storage Abstraction (Non-Breaking)

Introduce the `AgentStorage` trait without changing existing behavior. Current `AgentContextImpl` will use `RemoteStorage` that wraps existing gRPC calls.

### Task 1.1: Define AgentStorage Trait

**Files:**
- Create: `sdk-rust/worker-sdk/src/agent/storage.rs`
- Modify: `sdk-rust/worker-sdk/src/agent/mod.rs`

**Step 1: Create storage.rs with trait definition**

```rust
// sdk-rust/worker-sdk/src/agent/storage.rs
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use crate::error::WorkerError;

/// Result type for storage operations
pub type StorageResult<T> = Result<T, WorkerError>;

/// A batch of commands to commit atomically
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandBatch {
    pub segment: u64,
    pub sequence: u64,
    pub commands: Vec<AgentCommand>,
    pub checkpoint: Option<CheckpointData>,
}

/// Commands that can be batched
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum AgentCommand {
    AppendEntry {
        entry_id: Uuid,
        parent_id: Option<Uuid>,
        role: String,
        content: Value,
    },
    ScheduleTask {
        task_id: Uuid,
        kind: String,
        input: Value,
        options: TaskOptions,
    },
    WaitForSignal {
        signal_name: String,
    },
}

/// Checkpoint data to persist
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckpointData {
    pub state: Value,
    pub leaf_entry_id: Option<Uuid>,
    pub token_usage: Option<TokenUsage>,
}

/// Task scheduling options
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskOptions {
    pub queue: Option<String>,
    pub max_retries: Option<i32>,
    pub timeout_ms: Option<i64>,
}

/// Token usage for cost tracking
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TokenUsage {
    pub input_tokens: i64,
    pub output_tokens: i64,
}

/// Segment state loaded on recovery
#[derive(Debug, Clone)]
pub struct SegmentState {
    pub segment: u64,
    pub checkpoint: Option<CheckpointData>,
    pub pending_tasks: Vec<PendingTask>,
    pub pending_signals: Vec<String>,
}

/// A task that was scheduled but not yet completed
#[derive(Debug, Clone)]
pub struct PendingTask {
    pub task_id: Uuid,
    pub kind: String,
    pub status: TaskStatus,
    pub result: Option<Value>,
    pub error: Option<String>,
}

/// Task execution status
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskStatus {
    Pending,
    Running,
    Completed,
    Failed,
    Cancelled,
}

/// Storage backend for agent execution
#[async_trait]
pub trait AgentStorage: Send + Sync {
    /// Commit a batch of commands atomically
    async fn commit_batch(&self, agent_id: Uuid, batch: CommandBatch) -> StorageResult<()>;

    /// Load segment state for recovery
    async fn load_segment(&self, agent_id: Uuid, segment: u64) -> StorageResult<SegmentState>;

    /// Get the latest segment number for an agent
    async fn get_latest_segment(&self, agent_id: Uuid) -> StorageResult<u64>;

    /// Get task result (if completed)
    async fn get_task_result(&self, task_id: Uuid) -> StorageResult<Option<TaskResult>>;

    /// Get multiple task results in one call
    async fn get_task_results(&self, task_ids: &[Uuid]) -> StorageResult<Vec<TaskResult>>;

    /// Store a pending signal for an agent
    async fn store_signal(&self, agent_id: Uuid, signal_name: &str, payload: Value) -> StorageResult<()>;

    /// Get and remove pending signal
    async fn pop_signal(&self, agent_id: Uuid, signal_name: &str) -> StorageResult<Option<Value>>;

    /// Check if signal exists without consuming
    async fn has_signal(&self, agent_id: Uuid, signal_name: &str) -> StorageResult<bool>;
}

/// Result of a completed task
#[derive(Debug, Clone)]
pub struct TaskResult {
    pub task_id: Uuid,
    pub status: TaskStatus,
    pub output: Option<Value>,
    pub error: Option<String>,
}
```

**Step 2: Add storage module to agent/mod.rs**

Add to `sdk-rust/worker-sdk/src/agent/mod.rs`:
```rust
pub mod storage;
pub use storage::{AgentStorage, CommandBatch, AgentCommand, CheckpointData, TaskOptions, SegmentState};
```

**Step 3: Run compilation check**

Run: `cd sdk-rust && cargo check -p worker-sdk`
Expected: Compiles with no errors

**Step 4: Commit**

```bash
git add sdk-rust/worker-sdk/src/agent/storage.rs sdk-rust/worker-sdk/src/agent/mod.rs
git commit -m "$(cat <<'EOF'
feat(sdk): add AgentStorage trait for pluggable storage backends

Defines the core abstraction for agent state persistence:
- CommandBatch for atomic commits
- AgentCommand enum for batched operations
- SegmentState for recovery
- Signal persistence methods

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.2: Implement RemoteStorage

**Files:**
- Create: `sdk-rust/worker-sdk/src/agent/storage/remote.rs`
- Modify: `sdk-rust/worker-sdk/src/agent/storage.rs` → rename to `sdk-rust/worker-sdk/src/agent/storage/mod.rs`

**Step 1: Restructure storage as a module directory**

Move `storage.rs` to `storage/mod.rs` and add remote.rs:

```rust
// sdk-rust/worker-sdk/src/agent/storage/mod.rs
// (keep existing trait definitions, add at bottom)

mod remote;
pub use remote::RemoteStorage;
```

**Step 2: Create remote.rs implementing AgentStorage via existing gRPC client**

```rust
// sdk-rust/worker-sdk/src/agent/storage/remote.rs
use async_trait::async_trait;
use serde_json::Value;
use uuid::Uuid;

use crate::error::WorkerError;
use worker_core::client::AgentDispatch;

use super::{
    AgentCommand, AgentStorage, CheckpointData, CommandBatch, PendingTask, SegmentState,
    StorageResult, TaskResult, TaskStatus,
};

/// Remote storage implementation using gRPC client
pub struct RemoteStorage {
    client: AgentDispatch,
    org_id: Uuid,
}

impl RemoteStorage {
    pub fn new(client: AgentDispatch, org_id: Uuid) -> Self {
        Self { client, org_id }
    }
}

#[async_trait]
impl AgentStorage for RemoteStorage {
    async fn commit_batch(&self, agent_id: Uuid, batch: CommandBatch) -> StorageResult<()> {
        // For now, execute commands individually (existing behavior)
        // Phase 2 will add true batching on server side
        for cmd in batch.commands {
            match cmd {
                AgentCommand::AppendEntry { entry_id, parent_id, role, content } => {
                    self.client
                        .append_entry(
                            agent_id,
                            parent_id,
                            "message", // entry_type
                            &role,
                            content,
                            Some(entry_id.to_string()),
                        )
                        .await?;
                }
                AgentCommand::ScheduleTask { task_id, kind, input, options } => {
                    self.client
                        .schedule_task(
                            agent_id,
                            &kind,
                            input,
                            options.queue.as_deref(),
                            options.max_retries,
                            options.timeout_ms,
                            Some(task_id.to_string()),
                        )
                        .await?;
                }
                AgentCommand::WaitForSignal { .. } => {
                    // Signals are handled separately via suspend
                }
            }
        }

        // Commit checkpoint if present
        if let Some(checkpoint) = batch.checkpoint {
            self.client
                .submit_checkpoint(
                    agent_id,
                    checkpoint.leaf_entry_id,
                    checkpoint.state,
                    checkpoint.token_usage.map(|t| (t.input_tokens, t.output_tokens)),
                )
                .await?;
        }

        Ok(())
    }

    async fn load_segment(&self, agent_id: Uuid, _segment: u64) -> StorageResult<SegmentState> {
        // Load checkpoint from server
        let checkpoint = self.client.get_latest_checkpoint(agent_id).await?;

        Ok(SegmentState {
            segment: 0, // Remote storage doesn't track segments yet
            checkpoint: checkpoint.map(|(state, leaf_entry_id)| CheckpointData {
                state,
                leaf_entry_id,
                token_usage: None,
            }),
            pending_tasks: vec![],
            pending_signals: vec![],
        })
    }

    async fn get_latest_segment(&self, _agent_id: Uuid) -> StorageResult<u64> {
        // Remote storage doesn't track segments yet
        Ok(0)
    }

    async fn get_task_result(&self, task_id: Uuid) -> StorageResult<Option<TaskResult>> {
        let result = self.client.get_task_result(task_id).await?;

        Ok(result.map(|(status, output, error)| TaskResult {
            task_id,
            status: match status.as_str() {
                "COMPLETED" => TaskStatus::Completed,
                "FAILED" => TaskStatus::Failed,
                "CANCELLED" => TaskStatus::Cancelled,
                "RUNNING" => TaskStatus::Running,
                _ => TaskStatus::Pending,
            },
            output,
            error,
        }))
    }

    async fn get_task_results(&self, task_ids: &[Uuid]) -> StorageResult<Vec<TaskResult>> {
        let mut results = Vec::with_capacity(task_ids.len());
        for &task_id in task_ids {
            if let Some(result) = self.get_task_result(task_id).await? {
                results.push(result);
            }
        }
        Ok(results)
    }

    async fn store_signal(&self, _agent_id: Uuid, _signal_name: &str, _payload: Value) -> StorageResult<()> {
        // Remote signals are handled by server, not stored locally
        Ok(())
    }

    async fn pop_signal(&self, agent_id: Uuid, signal_name: &str) -> StorageResult<Option<Value>> {
        // Check if signal exists on server
        let has_signal = self.client.has_signal(agent_id, signal_name).await?;
        if has_signal {
            let signal = self.client.drain_signals(agent_id, signal_name).await?;
            Ok(signal.into_iter().next())
        } else {
            Ok(None)
        }
    }

    async fn has_signal(&self, agent_id: Uuid, signal_name: &str) -> StorageResult<bool> {
        self.client.has_signal(agent_id, signal_name).await
    }
}
```

**Step 3: Run compilation check**

Run: `cd sdk-rust && cargo check -p worker-sdk`
Expected: May have errors due to missing client methods - note them for next task

**Step 4: Commit**

```bash
git add sdk-rust/worker-sdk/src/agent/storage/
git commit -m "$(cat <<'EOF'
feat(sdk): add RemoteStorage implementation wrapping gRPC client

Implements AgentStorage trait using existing AgentDispatch client.
Commands are executed individually for now (Phase 2 adds true batching).

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.3: Implement InMemoryStorage for Testing

**Files:**
- Create: `sdk-rust/worker-sdk/src/agent/storage/memory.rs`
- Modify: `sdk-rust/worker-sdk/src/agent/storage/mod.rs`

**Step 1: Create memory.rs with in-memory implementation**

```rust
// sdk-rust/worker-sdk/src/agent/storage/memory.rs
use async_trait::async_trait;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::RwLock;
use uuid::Uuid;

use super::{
    AgentStorage, CommandBatch, PendingTask, SegmentState, StorageResult, TaskResult, TaskStatus,
};

/// In-memory storage for testing and ephemeral agents
#[derive(Default)]
pub struct InMemoryStorage {
    /// Stored checkpoints by agent_id -> segment -> checkpoint
    checkpoints: RwLock<HashMap<Uuid, HashMap<u64, CommandBatch>>>,
    /// Task results by task_id
    task_results: RwLock<HashMap<Uuid, TaskResult>>,
    /// Signals by agent_id -> signal_name -> payloads (FIFO queue)
    signals: RwLock<HashMap<Uuid, HashMap<String, Vec<Value>>>>,
    /// Latest segment by agent_id
    latest_segments: RwLock<HashMap<Uuid, u64>>,
}

impl InMemoryStorage {
    pub fn new() -> Self {
        Self::default()
    }

    /// Set a task result (for testing)
    pub fn set_task_result(&self, task_id: Uuid, result: TaskResult) {
        self.task_results.write().unwrap().insert(task_id, result);
    }

    /// Send a signal to an agent (for testing)
    pub fn send_signal(&self, agent_id: Uuid, signal_name: &str, payload: Value) {
        let mut signals = self.signals.write().unwrap();
        signals
            .entry(agent_id)
            .or_default()
            .entry(signal_name.to_string())
            .or_default()
            .push(payload);
    }
}

#[async_trait]
impl AgentStorage for InMemoryStorage {
    async fn commit_batch(&self, agent_id: Uuid, batch: CommandBatch) -> StorageResult<()> {
        let segment = batch.segment;

        // Store the batch
        {
            let mut checkpoints = self.checkpoints.write().unwrap();
            checkpoints
                .entry(agent_id)
                .or_default()
                .insert(segment, batch);
        }

        // Update latest segment
        {
            let mut latest = self.latest_segments.write().unwrap();
            let current = latest.entry(agent_id).or_insert(0);
            if segment > *current {
                *current = segment;
            }
        }

        Ok(())
    }

    async fn load_segment(&self, agent_id: Uuid, segment: u64) -> StorageResult<SegmentState> {
        let checkpoints = self.checkpoints.read().unwrap();

        let batch = checkpoints
            .get(&agent_id)
            .and_then(|segments| segments.get(&segment));

        Ok(SegmentState {
            segment,
            checkpoint: batch.and_then(|b| b.checkpoint.clone()),
            pending_tasks: vec![],
            pending_signals: vec![],
        })
    }

    async fn get_latest_segment(&self, agent_id: Uuid) -> StorageResult<u64> {
        let latest = self.latest_segments.read().unwrap();
        Ok(*latest.get(&agent_id).unwrap_or(&0))
    }

    async fn get_task_result(&self, task_id: Uuid) -> StorageResult<Option<TaskResult>> {
        let results = self.task_results.read().unwrap();
        Ok(results.get(&task_id).cloned())
    }

    async fn get_task_results(&self, task_ids: &[Uuid]) -> StorageResult<Vec<TaskResult>> {
        let results = self.task_results.read().unwrap();
        Ok(task_ids
            .iter()
            .filter_map(|id| results.get(id).cloned())
            .collect())
    }

    async fn store_signal(&self, agent_id: Uuid, signal_name: &str, payload: Value) -> StorageResult<()> {
        let mut signals = self.signals.write().unwrap();
        signals
            .entry(agent_id)
            .or_default()
            .entry(signal_name.to_string())
            .or_default()
            .push(payload);
        Ok(())
    }

    async fn pop_signal(&self, agent_id: Uuid, signal_name: &str) -> StorageResult<Option<Value>> {
        let mut signals = self.signals.write().unwrap();
        if let Some(agent_signals) = signals.get_mut(&agent_id) {
            if let Some(queue) = agent_signals.get_mut(signal_name) {
                if !queue.is_empty() {
                    return Ok(Some(queue.remove(0)));
                }
            }
        }
        Ok(None)
    }

    async fn has_signal(&self, agent_id: Uuid, signal_name: &str) -> StorageResult<bool> {
        let signals = self.signals.read().unwrap();
        Ok(signals
            .get(&agent_id)
            .and_then(|s| s.get(signal_name))
            .map(|q| !q.is_empty())
            .unwrap_or(false))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn test_commit_and_load_batch() {
        let storage = InMemoryStorage::new();
        let agent_id = Uuid::new_v4();

        let batch = CommandBatch {
            segment: 1,
            sequence: 5,
            commands: vec![],
            checkpoint: Some(super::super::CheckpointData {
                state: json!({"step": 3}),
                leaf_entry_id: None,
                token_usage: None,
            }),
        };

        storage.commit_batch(agent_id, batch).await.unwrap();

        let loaded = storage.load_segment(agent_id, 1).await.unwrap();
        assert_eq!(loaded.segment, 1);
        assert!(loaded.checkpoint.is_some());
        assert_eq!(loaded.checkpoint.unwrap().state, json!({"step": 3}));
    }

    #[tokio::test]
    async fn test_signal_fifo() {
        let storage = InMemoryStorage::new();
        let agent_id = Uuid::new_v4();

        storage.send_signal(agent_id, "input", json!({"msg": "first"}));
        storage.send_signal(agent_id, "input", json!({"msg": "second"}));

        assert!(storage.has_signal(agent_id, "input").await.unwrap());

        let first = storage.pop_signal(agent_id, "input").await.unwrap();
        assert_eq!(first, Some(json!({"msg": "first"})));

        let second = storage.pop_signal(agent_id, "input").await.unwrap();
        assert_eq!(second, Some(json!({"msg": "second"})));

        let third = storage.pop_signal(agent_id, "input").await.unwrap();
        assert!(third.is_none());

        assert!(!storage.has_signal(agent_id, "input").await.unwrap());
    }

    #[tokio::test]
    async fn test_task_results() {
        let storage = InMemoryStorage::new();
        let task_id = Uuid::new_v4();

        // Initially no result
        assert!(storage.get_task_result(task_id).await.unwrap().is_none());

        // Set result
        storage.set_task_result(
            task_id,
            TaskResult {
                task_id,
                status: TaskStatus::Completed,
                output: Some(json!({"result": 42})),
                error: None,
            },
        );

        // Now has result
        let result = storage.get_task_result(task_id).await.unwrap().unwrap();
        assert_eq!(result.status, TaskStatus::Completed);
        assert_eq!(result.output, Some(json!({"result": 42})));
    }
}
```

**Step 2: Export InMemoryStorage from mod.rs**

Add to `sdk-rust/worker-sdk/src/agent/storage/mod.rs`:
```rust
mod memory;
pub use memory::InMemoryStorage;
```

**Step 3: Run tests**

Run: `cd sdk-rust && cargo test -p worker-sdk storage`
Expected: All tests pass

**Step 4: Commit**

```bash
git add sdk-rust/worker-sdk/src/agent/storage/
git commit -m "$(cat <<'EOF'
feat(sdk): add InMemoryStorage for testing and ephemeral agents

Provides a simple in-memory implementation of AgentStorage:
- Stores checkpoints in HashMap
- FIFO signal queues
- Task result injection for tests

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.4: Add TaskExecutor Trait

**Files:**
- Create: `sdk-rust/worker-sdk/src/agent/executor.rs`
- Modify: `sdk-rust/worker-sdk/src/agent/mod.rs`

**Step 1: Create executor.rs with TaskExecutor trait**

```rust
// sdk-rust/worker-sdk/src/agent/executor.rs
use async_trait::async_trait;
use serde_json::Value;
use uuid::Uuid;

use crate::error::WorkerError;

/// Result type for executor operations
pub type ExecutorResult<T> = Result<T, WorkerError>;

/// Task executor abstraction for running tasks
#[async_trait]
pub trait TaskExecutor: Send + Sync {
    /// Execute a task and return its result
    ///
    /// For remote execution, this schedules the task and waits.
    /// For local execution, this runs the task in-process.
    async fn execute(
        &self,
        task_id: Uuid,
        kind: &str,
        input: Value,
    ) -> ExecutorResult<Value>;

    /// Check if a task kind can be executed locally
    fn supports_local(&self, kind: &str) -> bool;
}

/// Remote task executor (tasks run on remote workers)
///
/// This is a marker - actual execution happens via storage + server coordination
pub struct RemoteTaskExecutor;

impl RemoteTaskExecutor {
    pub fn new() -> Self {
        Self
    }
}

impl Default for RemoteTaskExecutor {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl TaskExecutor for RemoteTaskExecutor {
    async fn execute(
        &self,
        _task_id: Uuid,
        _kind: &str,
        _input: Value,
    ) -> ExecutorResult<Value> {
        // Remote execution is handled by scheduling + suspension
        // This method shouldn't be called directly for remote tasks
        Err(WorkerError::Internal(
            "Remote tasks are executed via storage scheduling, not direct execution".into(),
        ))
    }

    fn supports_local(&self, _kind: &str) -> bool {
        false
    }
}
```

**Step 2: Export from mod.rs**

Add to `sdk-rust/worker-sdk/src/agent/mod.rs`:
```rust
pub mod executor;
pub use executor::{TaskExecutor, RemoteTaskExecutor};
```

**Step 3: Run compilation check**

Run: `cd sdk-rust && cargo check -p worker-sdk`
Expected: Compiles with no errors

**Step 4: Commit**

```bash
git add sdk-rust/worker-sdk/src/agent/executor.rs sdk-rust/worker-sdk/src/agent/mod.rs
git commit -m "$(cat <<'EOF'
feat(sdk): add TaskExecutor trait for pluggable task execution

Defines abstraction for running tasks:
- Remote execution via storage scheduling (default)
- Local execution for in-process tasks (Phase 4)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.5: Add SignalSource Trait

**Files:**
- Create: `sdk-rust/worker-sdk/src/agent/signals.rs`
- Modify: `sdk-rust/worker-sdk/src/agent/mod.rs`

**Step 1: Create signals.rs with SignalSource trait**

```rust
// sdk-rust/worker-sdk/src/agent/signals.rs
use async_trait::async_trait;
use serde_json::Value;
use uuid::Uuid;

use crate::error::WorkerError;

/// Result type for signal operations
pub type SignalResult<T> = Result<T, WorkerError>;

/// Signal source abstraction for receiving signals
#[async_trait]
pub trait SignalSource: Send + Sync {
    /// Wait for a signal with the given name
    ///
    /// This may block until a signal arrives or return immediately if one is pending.
    async fn wait_for_signal(&self, agent_id: Uuid, signal_name: &str) -> SignalResult<Value>;

    /// Check if a signal is pending without consuming it
    async fn has_signal(&self, agent_id: Uuid, signal_name: &str) -> SignalResult<bool>;

    /// Drain all pending signals with the given name
    async fn drain_signals(&self, agent_id: Uuid, signal_name: &str) -> SignalResult<Vec<Value>>;
}

/// Remote signal source (signals delivered via server)
pub struct RemoteSignalSource {
    // Will be connected to gRPC client
}

impl RemoteSignalSource {
    pub fn new() -> Self {
        Self {}
    }
}

impl Default for RemoteSignalSource {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl SignalSource for RemoteSignalSource {
    async fn wait_for_signal(&self, _agent_id: Uuid, _signal_name: &str) -> SignalResult<Value> {
        // Remote signals cause agent suspension
        // This will be wired up when we refactor AgentContextImpl
        Err(WorkerError::Internal(
            "Remote signals are handled via agent suspension".into(),
        ))
    }

    async fn has_signal(&self, _agent_id: Uuid, _signal_name: &str) -> SignalResult<bool> {
        // Will be wired to gRPC client
        Ok(false)
    }

    async fn drain_signals(&self, _agent_id: Uuid, _signal_name: &str) -> SignalResult<Vec<Value>> {
        // Will be wired to gRPC client
        Ok(vec![])
    }
}

/// Channel-based signal source for local agents
pub struct ChannelSignalSource {
    receiver: tokio::sync::mpsc::Receiver<(String, Value)>,
}

impl ChannelSignalSource {
    pub fn new(receiver: tokio::sync::mpsc::Receiver<(String, Value)>) -> Self {
        Self { receiver }
    }

    /// Create a channel pair for sending/receiving signals
    pub fn channel(buffer: usize) -> (tokio::sync::mpsc::Sender<(String, Value)>, Self) {
        let (tx, rx) = tokio::sync::mpsc::channel(buffer);
        (tx, Self::new(rx))
    }
}

// Note: ChannelSignalSource implementation is more complex and will be
// completed in Phase 4 (Local Mode). For now, it's a placeholder.
```

**Step 2: Export from mod.rs**

Add to `sdk-rust/worker-sdk/src/agent/mod.rs`:
```rust
pub mod signals;
pub use signals::{SignalSource, RemoteSignalSource, ChannelSignalSource};
```

**Step 3: Run compilation check**

Run: `cd sdk-rust && cargo check -p worker-sdk`
Expected: Compiles with no errors

**Step 4: Commit**

```bash
git add sdk-rust/worker-sdk/src/agent/signals.rs sdk-rust/worker-sdk/src/agent/mod.rs
git commit -m "$(cat <<'EOF'
feat(sdk): add SignalSource trait for pluggable signal delivery

Defines abstraction for receiving signals:
- Remote signals via server (default)
- Channel-based signals for local agents (Phase 4)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.6: Add AgentTracer Trait (Observability)

**Files:**
- Create: `sdk-rust/worker-sdk/src/agent/tracer.rs`
- Modify: `sdk-rust/worker-sdk/src/agent/mod.rs`

**Step 1: Create tracer.rs with AgentTracer trait**

```rust
// sdk-rust/worker-sdk/src/agent/tracer.rs
use serde_json::Value;
use std::time::Duration;
use uuid::Uuid;

/// Agent tracer for observability
pub trait AgentTracer: Send + Sync {
    /// Called when a turn starts
    fn trace_turn_start(&self, agent_id: Uuid, turn: u64, input: &Value);

    /// Called when a tool/task is invoked
    fn trace_tool_call(&self, agent_id: Uuid, tool: &str, input: &Value, latency: Duration);

    /// Called to record token usage
    fn trace_tokens(&self, agent_id: Uuid, input_tokens: u64, output_tokens: u64, model: &str);

    /// Called when a turn ends
    fn trace_turn_end(&self, agent_id: Uuid, turn: u64, output: &Value);

    /// Called when an error occurs
    fn trace_error(&self, agent_id: Uuid, error: &str, context: Option<&Value>);

    /// Called when agent checkpoints
    fn trace_checkpoint(&self, agent_id: Uuid, segment: u64, state_size_bytes: usize);
}

/// No-op tracer that discards all traces
#[derive(Default, Clone)]
pub struct NoopTracer;

impl AgentTracer for NoopTracer {
    fn trace_turn_start(&self, _agent_id: Uuid, _turn: u64, _input: &Value) {}
    fn trace_tool_call(&self, _agent_id: Uuid, _tool: &str, _input: &Value, _latency: Duration) {}
    fn trace_tokens(&self, _agent_id: Uuid, _input_tokens: u64, _output_tokens: u64, _model: &str) {}
    fn trace_turn_end(&self, _agent_id: Uuid, _turn: u64, _output: &Value) {}
    fn trace_error(&self, _agent_id: Uuid, _error: &str, _context: Option<&Value>) {}
    fn trace_checkpoint(&self, _agent_id: Uuid, _segment: u64, _state_size_bytes: usize) {}
}

/// Tracer that prints to stdout (for debugging)
#[derive(Default, Clone)]
pub struct StdoutTracer {
    /// Whether to include input/output values (can be verbose)
    pub verbose: bool,
}

impl StdoutTracer {
    pub fn new() -> Self {
        Self { verbose: false }
    }

    pub fn verbose() -> Self {
        Self { verbose: true }
    }
}

impl AgentTracer for StdoutTracer {
    fn trace_turn_start(&self, agent_id: Uuid, turn: u64, input: &Value) {
        if self.verbose {
            println!("[TRACE] agent={} turn={} START input={}", agent_id, turn, input);
        } else {
            println!("[TRACE] agent={} turn={} START", agent_id, turn);
        }
    }

    fn trace_tool_call(&self, agent_id: Uuid, tool: &str, input: &Value, latency: Duration) {
        if self.verbose {
            println!(
                "[TRACE] agent={} tool={} latency={:?} input={}",
                agent_id, tool, latency, input
            );
        } else {
            println!("[TRACE] agent={} tool={} latency={:?}", agent_id, tool, latency);
        }
    }

    fn trace_tokens(&self, agent_id: Uuid, input_tokens: u64, output_tokens: u64, model: &str) {
        println!(
            "[TRACE] agent={} tokens in={} out={} model={}",
            agent_id, input_tokens, output_tokens, model
        );
    }

    fn trace_turn_end(&self, agent_id: Uuid, turn: u64, output: &Value) {
        if self.verbose {
            println!("[TRACE] agent={} turn={} END output={}", agent_id, turn, output);
        } else {
            println!("[TRACE] agent={} turn={} END", agent_id, turn);
        }
    }

    fn trace_error(&self, agent_id: Uuid, error: &str, context: Option<&Value>) {
        if let Some(ctx) = context {
            println!("[TRACE] agent={} ERROR: {} context={}", agent_id, error, ctx);
        } else {
            println!("[TRACE] agent={} ERROR: {}", agent_id, error);
        }
    }

    fn trace_checkpoint(&self, agent_id: Uuid, segment: u64, state_size_bytes: usize) {
        println!(
            "[TRACE] agent={} CHECKPOINT segment={} size={}B",
            agent_id, segment, state_size_bytes
        );
    }
}

/// Composite tracer that forwards to multiple tracers
pub struct CompositeTracer {
    tracers: Vec<Box<dyn AgentTracer>>,
}

impl CompositeTracer {
    pub fn new(tracers: Vec<Box<dyn AgentTracer>>) -> Self {
        Self { tracers }
    }
}

impl AgentTracer for CompositeTracer {
    fn trace_turn_start(&self, agent_id: Uuid, turn: u64, input: &Value) {
        for tracer in &self.tracers {
            tracer.trace_turn_start(agent_id, turn, input);
        }
    }

    fn trace_tool_call(&self, agent_id: Uuid, tool: &str, input: &Value, latency: Duration) {
        for tracer in &self.tracers {
            tracer.trace_tool_call(agent_id, tool, input, latency);
        }
    }

    fn trace_tokens(&self, agent_id: Uuid, input_tokens: u64, output_tokens: u64, model: &str) {
        for tracer in &self.tracers {
            tracer.trace_tokens(agent_id, input_tokens, output_tokens, model);
        }
    }

    fn trace_turn_end(&self, agent_id: Uuid, turn: u64, output: &Value) {
        for tracer in &self.tracers {
            tracer.trace_turn_end(agent_id, turn, output);
        }
    }

    fn trace_error(&self, agent_id: Uuid, error: &str, context: Option<&Value>) {
        for tracer in &self.tracers {
            tracer.trace_error(agent_id, error, context);
        }
    }

    fn trace_checkpoint(&self, agent_id: Uuid, segment: u64, state_size_bytes: usize) {
        for tracer in &self.tracers {
            tracer.trace_checkpoint(agent_id, segment, state_size_bytes);
        }
    }
}
```

**Step 2: Export from mod.rs**

Add to `sdk-rust/worker-sdk/src/agent/mod.rs`:
```rust
pub mod tracer;
pub use tracer::{AgentTracer, NoopTracer, StdoutTracer, CompositeTracer};
```

**Step 3: Run compilation check**

Run: `cd sdk-rust && cargo check -p worker-sdk`
Expected: Compiles with no errors

**Step 4: Commit**

```bash
git add sdk-rust/worker-sdk/src/agent/tracer.rs sdk-rust/worker-sdk/src/agent/mod.rs
git commit -m "$(cat <<'EOF'
feat(sdk): add AgentTracer trait for observability

Provides structured tracing for agent execution:
- Turn start/end events
- Tool call latency tracking
- Token usage recording
- Error tracking with context
- Checkpoint events

Includes NoopTracer, StdoutTracer, and CompositeTracer implementations.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2: Command Batching

Add command batching to `AgentContextImpl` while maintaining backward compatibility. Commands are collected in memory and committed atomically at suspension points.

### Task 2.1: Add CommandBatch to AgentContextImpl

**Files:**
- Modify: `sdk-rust/worker-sdk/src/agent/context_impl.rs`

**Step 1: Add batch field to AgentContextImpl struct**

Add to the struct fields:
```rust
/// Pending commands to be committed at next suspension point
pending_commands: RwLock<Vec<AgentCommand>>,
/// Current segment number
current_segment: AtomicU64,
/// Current sequence within segment
current_sequence: AtomicU64,
```

**Step 2: Initialize batch in constructor**

In the `new()` method, add:
```rust
pending_commands: RwLock::new(Vec::new()),
current_segment: AtomicU64::new(0),
current_sequence: AtomicU64::new(0),
```

**Step 3: Add method to generate deterministic task ID**

```rust
fn next_task_id(&self) -> Uuid {
    let segment = self.current_segment.load(Ordering::SeqCst);
    let seq = self.current_sequence.fetch_add(1, Ordering::SeqCst);
    // Generate deterministic UUID from agent_id + segment + sequence
    let input = format!("{}-{}-{}", self.agent_execution_id, segment, seq);
    Uuid::new_v5(&Uuid::NAMESPACE_OID, input.as_bytes())
}
```

**Step 4: Add method to commit pending batch**

```rust
async fn commit_pending_batch(&self, checkpoint: Option<CheckpointData>) -> Result<(), WorkerError> {
    let commands = {
        let mut pending = self.pending_commands.write().unwrap();
        std::mem::take(&mut *pending)
    };

    if commands.is_empty() && checkpoint.is_none() {
        return Ok(());
    }

    let batch = CommandBatch {
        segment: self.current_segment.load(Ordering::SeqCst),
        sequence: self.current_sequence.load(Ordering::SeqCst),
        commands,
        checkpoint,
    };

    // For now, execute via existing gRPC methods (RemoteStorage pattern)
    // This will be replaced with storage.commit_batch() in Task 2.3
    self.execute_batch_legacy(&batch).await
}

async fn execute_batch_legacy(&self, batch: &CommandBatch) -> Result<(), WorkerError> {
    let mut client = self.client.lock().await;

    for cmd in &batch.commands {
        match cmd {
            AgentCommand::AppendEntry { entry_id, parent_id, role, content } => {
                client
                    .append_entry(
                        self.agent_execution_id,
                        *parent_id,
                        "message",
                        role,
                        content.clone(),
                        Some(entry_id.to_string()),
                    )
                    .await?;
            }
            AgentCommand::ScheduleTask { task_id, kind, input, options } => {
                client
                    .schedule_task(
                        self.agent_execution_id,
                        kind,
                        input.clone(),
                        options.queue.as_deref(),
                        options.max_retries,
                        options.timeout_ms,
                        Some(task_id.to_string()),
                    )
                    .await?;
            }
            AgentCommand::WaitForSignal { .. } => {
                // Handled via suspension
            }
        }
    }

    if let Some(checkpoint) = &batch.checkpoint {
        client
            .submit_checkpoint(
                self.agent_execution_id,
                checkpoint.leaf_entry_id,
                checkpoint.state.clone(),
                checkpoint.token_usage.as_ref().map(|t| (t.input_tokens, t.output_tokens)),
            )
            .await?;
    }

    Ok(())
}
```

**Step 5: Run compilation check**

Run: `cd sdk-rust && cargo check -p worker-sdk`
Expected: Compiles (may have warnings about unused fields)

**Step 6: Commit**

```bash
git add sdk-rust/worker-sdk/src/agent/context_impl.rs
git commit -m "$(cat <<'EOF'
feat(sdk): add command batching infrastructure to AgentContextImpl

Adds pending_commands buffer and commit_pending_batch() method.
Commands are collected and committed atomically at suspension points.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.2: Refactor append_entry to Use Batching

**Files:**
- Modify: `sdk-rust/worker-sdk/src/agent/context_impl.rs`

**Step 1: Modify append_entry_raw to buffer commands**

Change the `append_entry_raw` implementation to buffer instead of immediate RPC:

```rust
async fn append_entry_raw(
    &self,
    role: EntryRole,
    content: Value,
) -> Result<Uuid, WorkerError> {
    let entry_id = self.next_entry_id();
    let parent_id = self.leaf_entry_id.read().unwrap().clone();

    // Add to pending batch instead of immediate RPC
    {
        let mut pending = self.pending_commands.write().unwrap();
        pending.push(AgentCommand::AppendEntry {
            entry_id,
            parent_id,
            role: role.as_str().to_string(),
            content: content.clone(),
        });
    }

    // Update leaf_entry_id
    *self.leaf_entry_id.write().unwrap() = Some(entry_id);

    // Update local message cache
    {
        let mut messages = self.messages.write().unwrap();
        messages.push(LoadedMessage {
            id: entry_id,
            role,
            content,
        });
    }

    Ok(entry_id)
}
```

**Step 2: Ensure checkpoint commits pending entries**

Modify `checkpoint` to commit batch:

```rust
async fn checkpoint(&self, state: &Value) -> Result<(), WorkerError> {
    let checkpoint_data = CheckpointData {
        state: state.clone(),
        leaf_entry_id: self.leaf_entry_id.read().unwrap().clone(),
        token_usage: None, // Will be set by caller if needed
    };

    self.commit_pending_batch(Some(checkpoint_data)).await?;

    // Update local state
    *self.checkpoint_state.write().unwrap() = Some(state.clone());
    self.checkpoint_sequence.fetch_add(1, Ordering::SeqCst);

    Ok(())
}
```

**Step 3: Run tests**

Run: `cd sdk-rust && cargo test -p worker-sdk`
Expected: Existing tests pass (behavior unchanged externally)

**Step 4: Commit**

```bash
git add sdk-rust/worker-sdk/src/agent/context_impl.rs
git commit -m "$(cat <<'EOF'
refactor(sdk): use command batching for append_entry

Entries are now buffered and committed atomically with checkpoints.
This reduces RPC calls and ensures atomic state transitions.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.3: Refactor schedule_task to Use Batching

**Files:**
- Modify: `sdk-rust/worker-sdk/src/agent/context_impl.rs`

**Step 1: Modify schedule_task_handle to buffer**

```rust
async fn schedule_task_handle(
    &self,
    kind: &str,
    input: Value,
) -> Result<AgentTaskHandle, WorkerError> {
    self.schedule_task_handle_with_options(kind, input, ScheduleAgentTaskOptions::default())
        .await
}

async fn schedule_task_handle_with_options(
    &self,
    kind: &str,
    input: Value,
    options: ScheduleAgentTaskOptions,
) -> Result<AgentTaskHandle, WorkerError> {
    let task_id = self.next_task_id();

    // Add to pending batch
    {
        let mut pending = self.pending_commands.write().unwrap();
        pending.push(AgentCommand::ScheduleTask {
            task_id,
            kind: kind.to_string(),
            input: input.clone(),
            options: TaskOptions {
                queue: options.queue.clone(),
                max_retries: options.max_retries,
                timeout_ms: options.timeout_ms,
            },
        });
    }

    Ok(AgentTaskHandle {
        task_execution_id: task_id,
        task_kind: kind.to_string(),
    })
}
```

**Step 2: Modify suspend_for_tasks to commit batch first**

```rust
async fn suspend_for_tasks(
    &self,
    task_ids: &[Uuid],
    mode: SuspensionMode,
) -> Result<Vec<TaskResultInfo>, WorkerError> {
    // Commit any pending commands before suspending
    self.commit_pending_batch(None).await?;

    // Now check task results and suspend if needed
    // ... (existing logic)
}
```

**Step 3: Run tests**

Run: `cd sdk-rust && cargo test -p worker-sdk`
Expected: Tests pass

**Step 4: Commit**

```bash
git add sdk-rust/worker-sdk/src/agent/context_impl.rs
git commit -m "$(cat <<'EOF'
refactor(sdk): use command batching for schedule_task

Tasks are buffered with deterministic IDs and committed at suspension.
Ensures atomic scheduling of parallel tasks.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3: Lazy Task API

Add the new `schedule_raw()` returning `AgentTaskFutureRaw` that mirrors workflow patterns.

### Task 3.1: Create AgentTaskFuture

**Files:**
- Create: `sdk-rust/worker-sdk/src/agent/future.rs`
- Modify: `sdk-rust/worker-sdk/src/agent/mod.rs`

**Step 1: Create future.rs with AgentTaskFuture**

```rust
// sdk-rust/worker-sdk/src/agent/future.rs
use serde_json::Value;
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};
use uuid::Uuid;

use crate::error::WorkerError;

/// A future representing a scheduled agent task
///
/// Unlike `schedule_task_handle().await`, this future:
/// - Does not make an RPC when created
/// - Assigns a deterministic task ID
/// - Only suspends when awaited
///
/// This enables natural parallel patterns:
/// ```rust
/// let f1 = ctx.schedule_task("task-a", input_a);
/// let f2 = ctx.schedule_task("task-b", input_b);
/// let results = futures::future::join_all(vec![f1, f2]).await?;
/// ```
pub struct AgentTaskFuture {
    /// The deterministic task ID
    pub(crate) task_id: Uuid,
    /// The task kind
    pub(crate) kind: String,
    /// The task input
    pub(crate) input: Value,
    /// Whether the task has been scheduled (command added to batch)
    pub(crate) scheduled: bool,
    /// The result if already available
    pub(crate) result: Option<Result<Value, WorkerError>>,
}

impl AgentTaskFuture {
    pub(crate) fn new(task_id: Uuid, kind: String, input: Value) -> Self {
        Self {
            task_id,
            kind,
            input,
            scheduled: false,
            result: None,
        }
    }

    /// Get the task ID
    pub fn task_id(&self) -> Uuid {
        self.task_id
    }

    /// Get the task kind
    pub fn kind(&self) -> &str {
        &self.kind
    }
}

// Note: The actual Future implementation requires access to AgentContext
// which we'll implement in Task 3.2 using a different pattern (poll-based
// execution via the combinators).

/// Raw future that can be collected and awaited together
pub struct AgentTaskFutureRaw {
    pub task_id: Uuid,
    pub kind: String,
    pub input: Value,
}

impl AgentTaskFutureRaw {
    pub fn new(task_id: Uuid, kind: String, input: Value) -> Self {
        Self { task_id, kind, input }
    }
}
```

**Step 2: Export from mod.rs**

Add to `sdk-rust/worker-sdk/src/agent/mod.rs`:
```rust
pub mod future;
pub use future::{AgentTaskFuture, AgentTaskFutureRaw};
```

**Step 3: Run compilation check**

Run: `cd sdk-rust && cargo check -p worker-sdk`
Expected: Compiles

**Step 4: Commit**

```bash
git add sdk-rust/worker-sdk/src/agent/future.rs sdk-rust/worker-sdk/src/agent/mod.rs
git commit -m "$(cat <<'EOF'
feat(sdk): add AgentTaskFuture for lazy task scheduling

Introduces future type that enables workflow-like parallel patterns:
- No RPC on creation
- Deterministic task IDs
- Natural join_all usage

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.2: Add schedule_raw Returning Future to AgentContext

**Files:**
- Modify: `sdk-rust/worker-sdk/src/agent/context.rs`
- Modify: `sdk-rust/worker-sdk/src/agent/context_impl.rs`

**Step 1: Add schedule_raw method to AgentContext trait**

Add to `context.rs`:
```rust
/// Schedule a task and return a future (lazy, no immediate RPC)
///
/// This is the preferred API for parallel task execution:
/// ```rust
/// let f1 = ctx.schedule_raw("task-a", json!({"x": 1}));
/// let f2 = ctx.schedule_raw("task-b", json!({"y": 2}));
/// let results = ctx.join_all(vec![f1, f2]).await?;
/// ```
fn schedule_raw(&self, task_kind: &str, input: Value) -> AgentTaskFutureRaw;

/// Schedule a task with options and return a future
fn schedule_with_options_raw(
    &self,
    task_kind: &str,
    input: Value,
    options: ScheduleAgentTaskOptions,
) -> AgentTaskFutureRaw;

/// Wait for all task futures to complete
async fn join_all(&self, futures: Vec<AgentTaskFutureRaw>) -> Result<Vec<Value>, WorkerError>;

/// Wait for the first task to complete successfully
async fn select_ok(&self, futures: Vec<AgentTaskFutureRaw>) -> Result<(Value, Vec<AgentTaskFutureRaw>), WorkerError>;
```

**Step 2: Implement in context_impl.rs**

```rust
fn schedule_raw(&self, task_kind: &str, input: Value) -> AgentTaskFutureRaw {
    self.schedule_with_options_raw(task_kind, input, ScheduleAgentTaskOptions::default())
}

fn schedule_with_options_raw(
    &self,
    task_kind: &str,
    input: Value,
    options: ScheduleAgentTaskOptions,
) -> AgentTaskFutureRaw {
    let task_id = self.next_task_id();

    // Add to pending batch
    {
        let mut pending = self.pending_commands.write().unwrap();
        pending.push(AgentCommand::ScheduleTask {
            task_id,
            kind: task_kind.to_string(),
            input: input.clone(),
            options: TaskOptions {
                queue: options.queue.clone(),
                max_retries: options.max_retries,
                timeout_ms: options.timeout_ms,
            },
        });
    }

    AgentTaskFutureRaw::new(task_id, task_kind.to_string(), input)
}

async fn join_all(&self, futures: Vec<AgentTaskFutureRaw>) -> Result<Vec<Value>, WorkerError> {
    if futures.is_empty() {
        return Ok(vec![]);
    }

    // Commit batch to schedule all tasks
    self.commit_pending_batch(None).await?;

    // Collect task IDs
    let task_ids: Vec<Uuid> = futures.iter().map(|f| f.task_id).collect();

    // Use existing suspension mechanism
    let results = self
        .suspend_for_tasks(&task_ids, SuspensionMode::All)
        .await?;

    // Extract results in order
    let mut output = Vec::with_capacity(futures.len());
    for future in &futures {
        let result = results
            .iter()
            .find(|r| r.task_id == future.task_id)
            .ok_or_else(|| WorkerError::Internal(format!("Missing result for task {}", future.task_id)))?;

        match &result.status {
            TaskStatus::Completed => {
                output.push(result.output.clone().unwrap_or(Value::Null));
            }
            TaskStatus::Failed => {
                return Err(WorkerError::TaskFailed {
                    task_id: result.task_id,
                    error: result.error.clone().unwrap_or_default(),
                });
            }
            _ => {
                return Err(WorkerError::Internal(format!(
                    "Unexpected task status: {:?}",
                    result.status
                )));
            }
        }
    }

    Ok(output)
}

async fn select_ok(&self, futures: Vec<AgentTaskFutureRaw>) -> Result<(Value, Vec<AgentTaskFutureRaw>), WorkerError> {
    if futures.is_empty() {
        return Err(WorkerError::Internal("select_ok called with empty futures".into()));
    }

    // Commit batch to schedule all tasks
    self.commit_pending_batch(None).await?;

    // Collect task IDs
    let task_ids: Vec<Uuid> = futures.iter().map(|f| f.task_id).collect();

    // Use existing suspension mechanism with Select mode
    let results = self
        .suspend_for_tasks(&task_ids, SuspensionMode::Select)
        .await?;

    // Find first completed task
    for result in &results {
        if result.status == TaskStatus::Completed {
            let value = result.output.clone().unwrap_or(Value::Null);
            let remaining: Vec<_> = futures
                .into_iter()
                .filter(|f| f.task_id != result.task_id)
                .collect();
            return Ok((value, remaining));
        }
    }

    // All failed
    Err(WorkerError::AllTasksFailed {
        errors: results
            .iter()
            .filter_map(|r| r.error.clone())
            .collect(),
    })
}
```

**Step 3: Run tests**

Run: `cd sdk-rust && cargo test -p worker-sdk`
Expected: Tests pass

**Step 4: Commit**

```bash
git add sdk-rust/worker-sdk/src/agent/context.rs sdk-rust/worker-sdk/src/agent/context_impl.rs
git commit -m "$(cat <<'EOF'
feat(sdk): add lazy schedule_raw API with join_all/select_ok

New workflow-aligned API:
- schedule_raw() returns AgentTaskFutureRaw immediately (no await)
- schedule_with_options_raw() for options
- join_all() waits for all tasks
- select_ok() returns first success

API aligns exactly with workflow's schedule_raw() -> TaskFutureRaw pattern.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.3: Remove ALL Legacy APIs (Breaking Change - NO BACKWARD COMPAT)

> **CRITICAL:** Remove all old APIs completely. NO aliases, NO deprecations, NO compatibility shims.

**Files:**
- Modify: `sdk-rust/worker-sdk/src/agent/context.rs`
- Modify: `sdk-rust/worker-sdk/src/agent/context_impl.rs`
- Modify: `sdk-rust/worker-sdk/src/agent/combinators.rs` (remove old combinators)
- Modify: `sdk-rust/worker-sdk/src/testing/mock_agent_context.rs`
- Modify: `sdk-rust/worker-sdk/tests/e2e/fixtures/agents.rs`
- Modify: `sdk-rust/agent-worker/src/workflows/agent.rs`
- Update: Any tests using old API

**Step 1: Remove from AgentContext trait**

Remove ALL these methods from `context.rs` (DELETE, not deprecate):
- `schedule_task_raw` - REMOVE (replaced by `schedule_raw`)
- `schedule_task_with_options_raw` - REMOVE (replaced by `schedule_with_options_raw`)
- `schedule_task_handle` - REMOVE
- `schedule_task_handle_with_options` - REMOVE

**Step 2: Remove from AgentContextImpl**

Remove the corresponding implementations from `context_impl.rs`. Delete the code entirely.

**Step 3: Remove from MockAgentContext**

Update `mock_agent_context.rs` to use only the new API. Remove any methods for old APIs.

**Step 4: Update combinators.rs**

Remove old combinators that used `AgentTaskHandle`:
- `agent_join_all`
- `agent_select`
- `agent_join_all_settled`
- `agent_select_ok`

The new `ctx.join_all()` and `ctx.select_ok()` methods replace these.

**Step 5: Update all code using old APIs**

Find and update ALL code using the old API to use the new pattern:
```rust
// Old (DELETE THIS):
let h1 = ctx.schedule_task_raw("task-a", input1).await?;
let results = agent_join_all(ctx, vec![h1]).await?;

// New (USE THIS):
let f1 = ctx.schedule_raw("task-a", input1);
let results = ctx.join_all(vec![f1]).await?;
```

Files to check:
- `flovyn-server/server/tests/integration/agent_execution_tests.rs`
- `worker-sdk/tests/e2e/fixtures/agents.rs`
- `agent-worker/src/workflows/agent.rs`

**Step 6: Run tests**

Run: `cd sdk-rust && cargo test -p flovyn-worker-sdk`
Expected: All tests pass with new API

**Step 7: Commit**

```bash
git add sdk-rust/
git commit -m "$(cat <<'EOF'
refactor(sdk)!: remove ALL legacy task APIs, use schedule_raw

BREAKING CHANGE: Removed all legacy APIs with NO backward compatibility.

Removed APIs (DELETE, not deprecated):
- schedule_task_raw() -> use schedule_raw()
- schedule_task_with_options_raw() -> use schedule_with_options_raw()
- schedule_task_handle() -> use schedule_raw()
- agent_join_all() -> use ctx.join_all()
- agent_select() -> use ctx.select_ok()

New API aligns exactly with workflow API (schedule_raw returns AgentTaskFutureRaw).

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3.5: Integration Tests for New Features

Add E2E tests to verify the new lazy task API, command batching, and deterministic task IDs work correctly in full execution flows.

**Test locations:**
- `flovyn-server/server/tests/integration/agent_execution_tests.rs` - Full flow tests targeting specific server behaviors (parallel handling, lazy scheduling, batching)
- `sdk-rust/worker-sdk/tests/e2e/agent_tests.rs` - Full flow tests from developer perspective (API usability)

Both are E2E tests running full agent flows. The difference is intent: server tests verify specific internal behaviors, SDK tests verify developer experience.

### Task 3.5.1: Test Deterministic Task IDs

**Files:**
- Modify: `sdk-rust/worker-sdk/src/agent/context_impl.rs` (unit tests for ID generation algorithm)

**Test:** Verify that `next_task_id()` generates deterministic UUIDs based on agent_id + segment + sequence. Same inputs must produce same task IDs across replays.

**Status:** DONE

---

### Task 3.5.2: Test Lazy Schedule - No Premature RPC

**Files:**
- Modify: `flovyn-server/server/tests/integration/agent_execution_tests.rs`
- Add agent: `LazyScheduleVerificationAgent`

**Test:** `test_lazy_schedule_no_premature_tasks`

**Agent behavior:**
```rust
struct LazyScheduleVerificationAgent;

async fn execute(&self, ctx, input) {
    // Phase 1: Schedule tasks lazily
    let f1 = ctx.schedule_raw("echo-task", json!({"id": 1}));
    let f2 = ctx.schedule_raw("echo-task", json!({"id": 2}));
    let f3 = ctx.schedule_raw("echo-task", json!({"id": 3}));

    // Phase 2: Create checkpoint BEFORE join_all
    // This commits the pending schedule commands to server
    ctx.checkpoint(&json!({"phase": "pre-join"})).await?;

    // Phase 3: Now call join_all
    let results = ctx.join_all(vec![f1, f2, f3]).await?;

    ctx.checkpoint(&json!({"phase": "post-join", "count": results.len()})).await?;

    Ok(output)
}
```

**Test verification:**
1. Create agent execution
2. Wait for COMPLETED status
3. Query tasks for this agent - should have exactly 3 tasks
4. Verify all tasks completed

**Why this works:** The checkpoint before join_all commits the schedule commands. If lazy scheduling wasn't working (immediate RPC), there would be duplicate task creation attempts or errors.

**Status:** DONE - `test_lazy_schedule_verification` added

---

### Task 3.5.3: Test Command Batching - Atomic Commit

**Files:**
- Modify: `flovyn-server/server/tests/integration/agent_execution_tests.rs`
- Add agent: `BatchingCrashAgent`

**Test:** `test_command_batching_crash_before_checkpoint`

**Agent behavior:**
```rust
struct BatchingCrashAgent;

async fn execute(&self, ctx, input) {
    let should_crash = input.get("should_crash").and_then(|v| v.as_bool()).unwrap_or(false);

    // Append entries (buffered, not committed)
    ctx.append_entry(EntryRole::User, &json!({"text": "Entry 1"})).await?;
    ctx.append_entry(EntryRole::Assistant, &json!({"text": "Entry 2"})).await?;

    // Schedule tasks (buffered, not committed)
    let f1 = ctx.schedule_raw("echo-task", json!({"id": 1}));
    let f2 = ctx.schedule_raw("echo-task", json!({"id": 2}));

    if should_crash {
        // Crash BEFORE checkpoint - nothing should be committed
        return Err(FlovynError::Internal("Simulated crash".into()));
    }

    // Checkpoint commits everything atomically
    ctx.checkpoint(&json!({"committed": true})).await?;

    let results = ctx.join_all(vec![f1, f2]).await?;

    Ok(output)
}
```

**Test verification:**
1. Run agent with `should_crash: true`
2. Wait for FAILED status
3. Query entries - should have 0 entries (nothing committed)
4. Query tasks - should have 0 tasks (nothing committed)
5. Run agent with `should_crash: false`
6. Wait for COMPLETED status
7. Query entries - should have 2 entries
8. Verify output shows 2 task results

**Status:** DONE - `test_command_batching_crash_before_checkpoint` added

---

### Task 3.5.4: Test join_all Order Preservation

**Status:** DONE - `test_agent_join_all_order_preservation` exists

---

### Task 3.5.5: Test select_ok Returns First Success

**Status:** DONE - `test_agent_select_ok_skips_failures` and `test_agent_select_ok_first_to_complete_wins` exist

---

## Phase 4: Local Mode (Deferred)

> **Note:** Phase 4 (SqliteStorage, LocalTaskExecutor, InteractiveSignalSource) is deferred to a future implementation plan. The abstractions from Phases 1-3 enable this work, but implementation details require further design for:
> - SQLite schema for local storage
> - Local task registry and execution
> - Interactive signal handling (stdin, IDE integration)
> - Session persistence like Claude Code --resume

---

## Phase 5: Hierarchical Agents (Deferred)

> **Note:** Phase 5 (spawn_agent API, parent-child signals, LocalWorkerDaemon) is deferred to a future implementation plan. This requires:
> - Server-side support for child agent tracking
> - gRPC streaming for parent-child events
> - LocalWorkerDaemon design and security model

---

## Verification

After completing Phases 1-3:

```bash
# Unit tests
cd sdk-rust && cargo test -p worker-sdk

# Integration tests (requires running server)
cd sdk-rust && cargo test --test integration

# Check for compilation errors across all crates
cd sdk-rust && cargo check --all
```

---

## Summary

This plan implements the core Agent Execution Model v2 changes:

| Phase | Tasks | Outcome |
|-------|-------|---------|
| 1 | 1.1-1.6 | Storage/Executor/Signal/Tracer abstractions |
| 2 | 2.1-2.3 | Command batching in AgentContextImpl |
| 3 | 3.1-3.3 | Lazy schedule_task API with join_all/select_ok |
| 3.5 | 3.5.1-3.5.5 | Integration tests for new features |

Phases 4-5 (Local Mode, Hierarchical Agents) are deferred for separate implementation plans.
