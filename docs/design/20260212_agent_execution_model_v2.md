# Design: Agent Execution Model v2

## Status

Draft

## Related

- [Async Agents Research](../research/20260212_async-agents.md) - Formalized definition of async agents
- [External Coding Agent Integration](../research/20260211_external_coding_agent_integration.md) - Patterns for integrating Pi, Claude Code, etc.

## Context

### Two Levels of "Async"

There are two distinct concerns that are often conflated:

**1. External Async (Caller ↔ Agent Platform)**
- Caller submits agent, gets handle immediately (non-blocking)
- Caller can disconnect, reconnect, poll status
- Agent runs autonomously, reports progress, completes eventually
- This is what the [Async Agents Research](../research/20260212_async-agents.md) defines

**2. Internal Async (Within Agent Execution)**
- Agent code schedules tasks, waits for results
- How parallel tasks are expressed (`join_all`, `select`, etc.)
- How state is persisted (checkpoints, event sourcing)
- This is what this document addresses

The current Flovyn architecture handles External Async well (the server manages agent lifecycle, status, signals). But the Internal execution model differs from workflows:

### Current Internal Model Comparison

The current agent execution model differs significantly from workflows:

| Aspect | Workflow | Agent (Current) |
|--------|----------|-----------------|
| Task scheduling | `schedule_raw()` returns lazy `Future` | `schedule_task_handle().await` makes immediate RPC |
| Command handling | Batched, sent atomically at suspension | Individual RPCs per operation |
| Recovery | Deterministic replay from beginning | Restore from checkpoint |
| ID generation | Deterministic sequence counter | Server-generated UUIDs |

This divergence creates:
1. **API inconsistency** - Different patterns for similar operations
2. **Unnecessary coupling** - Agents require server connection for basic operations
3. **No local mode** - Can't run agents without remote persistence

## Goals

1. **Unified execution model** - Agents and workflows use the same patterns
2. **Local mode support** - Agents can run without remote server (for coding agents, CLI tools)
3. **Pluggable storage** - Same model works with remote server, local SQLite, or in-memory
4. **Simpler API** - No `.await` on scheduling, natural parallel patterns

## Non-Goals

- Breaking existing workflow APIs
- Full deterministic replay for agents (checkpoints are still the recovery mechanism)

## Long-Term Vision: Async Agents Everywhere

Per the [Async Agents Research](../research/20260212_async-agents.md), async agents need:

| Property | Description | How This Design Supports It |
|----------|-------------|----------------------------|
| P1: Non-blocking invocation | Caller gets handle immediately | Already supported by server |
| P2: Execution independence | Agent runs even if caller disconnects | Already supported by server |
| P3: Autonomous reasoning loop | plan → act → observe → replan | Agent code; not affected by this design |
| P4: Durable state | Survives crashes | Checkpoint-based recovery; storage abstraction |
| P5: Observable lifecycle | Caller can poll status/progress | Already supported; entries + streaming |
| P6: Bounded execution | TTL, step limits | Server-enforced timeouts; task deadlines |

The key insight: **the internal execution model (this design) is orthogonal to the external async contract**. An agent can be:

- **Remote + Full Persistence**: Traditional Flovyn deployment, server manages everything
- **Remote + Lightweight Persistence**: Server manages lifecycle, but simpler checkpoints
- **Local + File Persistence**: Coding agent with SQLite, no server needed
- **Local + No Persistence**: Ephemeral agent, in-memory only, for quick tasks

All four should use the **same internal execution model** (lazy scheduling, command batching, segment-based recovery). Only the storage and execution backends differ.

## Key Insight

### What Does a Running Agent Actually Need?

Let's decompose the server's role into atomic concerns:

| Operation | During Execution | For Recovery |
|-----------|------------------|--------------|
| Schedule task | Task execution (could be local) | Task result persistence |
| Append entry | Nothing (can buffer) | Entry persistence |
| Checkpoint | Nothing (can buffer) | State persistence |
| Wait for signal | Signal delivery mechanism | Signal persistence |

The server provides several distinct concerns that can be separated:

1. **Task Execution** - Running tasks (could be remote workers OR local in-process)
2. **Signal Delivery** - Delivering signals to waiting agents (could be server OR local channel)
3. **State Persistence** - Storing checkpoints, entries (could be server DB OR local SQLite/file)
4. **Lifecycle Management** - Tracking agent status, timeouts (could be server OR local runtime)

### Checkpoint-Based Recovery vs Deterministic Replay

Workflows use **deterministic replay**: on crash, replay from the beginning, skip already-completed operations by reading from event log. This requires:
- Deterministic code (same inputs → same outputs)
- Complete event log (every operation recorded)
- Replay infrastructure

Agents use **checkpoint-based recovery**: on crash, restore from last checkpoint, continue from there. This is:
- Simpler (no replay infrastructure)
- More flexible (checkpoint state can be arbitrary)
- Less precise (may lose work since last checkpoint)

**Key realization**: Checkpoints are only needed for crash recovery. If you don't care about crash recovery (ephemeral agent), you don't need checkpoints. If your state is already durable elsewhere (git repo), you may not need checkpoints either.

### A Coding Agent Example

A coding agent manipulating a git repository:
- **Task execution**: Local (file I/O, shell commands, git operations)
- **Signal delivery**: Local (stdin, IDE events)
- **State persistence**: Minimal - the *artifact* (source code) is what matters, not the agent's internal state
- **Lifecycle management**: Local runtime (or none - just run to completion)

This agent needs ZERO remote infrastructure. The git repository provides durable *artifacts*. The agent's internal state (conversation, plan, current step) can be ephemeral. Recovery is: inspect `git status` / `git diff`, figure out what was being done, continue.

Key insight: **artifact-centric vs state-centric recovery**. Coding agents are artifact-centric - the value is in what they produce (code), not in their internal state.

But the **internal execution model** should be the same:
```rust
// Same API whether local or remote
let f1 = ctx.schedule_task("read-file", json!({"path": "src/main.rs"}));
let f2 = ctx.schedule_task("read-file", json!({"path": "Cargo.toml"}));
let contents = join_all(vec![f1, f2]).await?;
```

## Design

### Supporting All Async Agent Levels

The [Async Agents Research](../research/20260212_async-agents.md) defines three levels:

| Level | Example | Internal Model Requirements |
|-------|---------|----------------------------|
| L1: Fire-and-Forget | "Summarize this PDF" | Simple: run to completion, return result |
| L2: Supervised Autonomous | "Research competitors, write report" | Progress reporting, input requests, plan approval |
| L3: Persistent Daemon | "Monitor CI, fix failures" | Long-running, event-driven, no single completion |

All three levels should use the **same internal execution model**:

```rust
// L1: Fire-and-forget - simple task
async fn execute(&self, ctx: &dyn AgentContext, input: Input) -> Result<Output> {
    let result = ctx.schedule_task("summarize", input.document).await?;
    Ok(Output { summary: result })
}

// L2: Supervised - with progress and input requests
async fn execute(&self, ctx: &dyn AgentContext, input: Input) -> Result<Output> {
    // Show plan to user
    ctx.append_entry(EntryRole::Assistant, &json!({"plan": plan})).await;

    // Wait for approval
    let approval = ctx.wait_for_signal("plan-approval").await?;
    if !approval.approved { return Err(...); }

    // Execute with progress
    for step in plan.steps {
        ctx.append_entry(EntryRole::Assistant, &json!({"progress": step})).await;
        let result = ctx.schedule_task(&step.task, step.input).await?;
    }

    Ok(output)
}

// L3: Daemon - event-driven loop
async fn execute(&self, ctx: &dyn AgentContext, input: Input) -> Result<Output> {
    loop {
        // Wait for external event (CI failure, timer, etc.)
        let event = ctx.wait_for_signal("ci-event").await?;

        // Process event
        let diagnosis = ctx.schedule_task("diagnose", event).await?;
        let fix = ctx.schedule_task("generate-fix", diagnosis).await?;
        ctx.schedule_task("open-pr", fix).await?;

        // Notify
        ctx.schedule_task("slack-notify", notification).await?;

        // Checkpoint after each event
        ctx.checkpoint(&state).await?;
    }
}
```

The execution model doesn't change based on agent level. What changes is:
- **L1**: No signals, no progress, runs once
- **L2**: Uses signals for input, appends entries for progress
- **L3**: Uses signals for events, loops indefinitely

### Core Concept: Execution Segments

An agent execution is a series of **segments**, each bounded by suspension points:

```
Segment 0 (initial)
├── append_entry(user, "Hello")           seq=0
├── schedule_task("llm-call", input)      seq=1 → task_id = {agent}-0-1
├── [SUSPEND: wait for task]
│
Segment 1 (after task completes)
├── append_entry(assistant, response)     seq=2
├── checkpoint(state)                     seq=3
├── wait_for_signal("user-input")         seq=4
├── [SUSPEND: wait for signal]
│
Segment 2 (after signal received)
├── append_entry(user, signal_content)    seq=5
├── ...
```

Within each segment:
- Operations have **deterministic sequence numbers**
- IDs are derived from `{agent_id}-{segment}-{sequence}`
- Commands are **batched** in memory
- At suspension, batch is **committed atomically**

### Recovery Model

On crash and recovery:

1. Load last committed segment state
2. Re-execute from that point
3. Operations generate same sequence numbers
4. For each operation:
   - If result exists in history → return cached result
   - If not → execute and persist

This is **segment-level replay**, not full replay like workflows. The agent code within a segment must be deterministic, but:
- External calls (tasks) are non-deterministic - their results are persisted
- LLM responses, API calls, etc. are captured as task results

### API Changes

#### Task Scheduling (Aligned with Workflows)

```rust
// Current (v1) - immediate RPC
let h1 = ctx.schedule_task_handle("task-a", input1).await?;
let h2 = ctx.schedule_task_handle("task-b", input2).await?;
let results = agent_join_all(ctx, vec![h1, h2]).await?;

// Proposed (v2) - lazy futures, like workflows
let f1 = ctx.schedule_task("task-a", input1);  // No .await, returns Future
let f2 = ctx.schedule_task("task-b", input2);  // No .await, returns Future
let results = join_all(vec![f1, f2]).await?;   // Suspends here, batch committed
```

The `schedule_task` method:
- Returns `AgentTaskFuture` immediately (no RPC)
- Assigns deterministic task ID based on sequence
- Adds "ScheduleTask" command to batch
- When awaited, suspends agent and commits batch

#### Entry Appending

```rust
// Current - immediate RPC
ctx.append_entry(role, content).await?;

// Proposed - buffered
ctx.append_entry(role, content);  // Adds to batch, no await needed
```

Entries are committed:
- When agent suspends (task wait, signal wait)
- When checkpoint is called
- When agent completes

#### Checkpoints

```rust
// Explicit checkpoint (commits batch + saves state)
ctx.checkpoint(&state).await?;

// Or implicit - batch committed at any suspension point
let result = ctx.schedule_task("llm", prompt).await?;  // Commits pending entries
```

### Storage Abstraction

```rust
/// Storage backend for agent execution
#[async_trait]
pub trait AgentStorage: Send + Sync {
    /// Commit a batch of commands atomically
    async fn commit_batch(&self, agent_id: &str, batch: CommandBatch) -> Result<()>;

    /// Load segment state for recovery
    async fn load_segment(&self, agent_id: &str, segment: u64) -> Result<SegmentState>;

    /// Get task result (if completed)
    async fn get_task_result(&self, task_id: &str) -> Result<Option<TaskResult>>;

    /// Get signal (if received)
    async fn get_signal(&self, agent_id: &str, signal_name: &str) -> Result<Option<Signal>>;
}

/// Command batch to commit atomically
pub struct CommandBatch {
    pub segment: u64,
    pub sequence: u64,
    pub commands: Vec<Command>,
    pub checkpoint: Option<CheckpointData>,
}

pub enum Command {
    AppendEntry { role: EntryRole, content: Value },
    ScheduleTask { task_id: String, kind: String, input: Value },
    WaitForSignal { signal_name: String },
    // ...
}
```

### Storage Implementations

#### Remote Server (Current)

```rust
pub struct RemoteStorage {
    client: AgentDispatchClient,
}

impl AgentStorage for RemoteStorage {
    async fn commit_batch(&self, agent_id: &str, batch: CommandBatch) -> Result<()> {
        // gRPC call to server
        self.client.commit_agent_batch(agent_id, batch).await
    }
    // ...
}
```

#### Local SQLite

```rust
pub struct SqliteStorage {
    db: SqlitePool,
}

impl AgentStorage for SqliteStorage {
    async fn commit_batch(&self, agent_id: &str, batch: CommandBatch) -> Result<()> {
        // Write to local SQLite in transaction
        let mut tx = self.db.begin().await?;
        for cmd in batch.commands {
            sqlx::query("INSERT INTO agent_commands ...").execute(&mut tx).await?;
        }
        tx.commit().await
    }
    // ...
}
```

#### In-Memory (Testing / Ephemeral)

```rust
pub struct InMemoryStorage {
    state: RwLock<HashMap<String, AgentState>>,
}
```

### Task Execution Abstraction

Tasks also need abstraction for local mode:

```rust
#[async_trait]
pub trait TaskExecutor: Send + Sync {
    async fn execute(&self, task_id: &str, kind: &str, input: Value) -> Result<Value>;
}

/// Remote task execution (current model)
pub struct RemoteTaskExecutor {
    // Tasks executed by remote workers
}

/// Local task execution (in-process)
pub struct LocalTaskExecutor {
    registry: TaskRegistry,
}

impl TaskExecutor for LocalTaskExecutor {
    async fn execute(&self, task_id: &str, kind: &str, input: Value) -> Result<Value> {
        let task = self.registry.get(kind)?;
        task.execute(input).await
    }
}
```

### Agent Builder

```rust
// Remote mode (current behavior)
let agent = AgentBuilder::new()
    .storage(RemoteStorage::new(grpc_client))
    .task_executor(RemoteTaskExecutor::new())
    .build();

// Local mode (new)
let agent = AgentBuilder::new()
    .storage(SqliteStorage::new("./agent.db"))
    .task_executor(LocalTaskExecutor::new(task_registry))
    .build();

// Ephemeral mode (no persistence)
let agent = AgentBuilder::new()
    .storage(InMemoryStorage::new())
    .task_executor(LocalTaskExecutor::new(task_registry))
    .build();
```

### Signal Handling in Local Mode

For local mode, signals need a local delivery mechanism:

```rust
pub trait SignalSource: Send + Sync {
    async fn wait_for_signal(&self, agent_id: &str, signal_name: &str) -> Result<Signal>;
}

/// Remote signals (from server)
pub struct RemoteSignalSource { /* gRPC streaming */ }

/// Local signals (from channel)
pub struct LocalSignalSource {
    receiver: mpsc::Receiver<Signal>,
}

/// Interactive signals (from stdin/user)
pub struct InteractiveSignalSource {
    // Read from terminal
}
```

### Local Mode Architecture

For local mode, we provide alternative implementations of each abstraction:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        AGENT RUNTIME                                │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    AgentContext                              │   │
│  │  • schedule_task() → Future                                  │   │
│  │  • append_entry()                                            │   │
│  │  • checkpoint()                                              │   │
│  │  • wait_for_signal()                                         │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│              ┌───────────────┼───────────────┐                      │
│              ▼               ▼               ▼                      │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐           │
│  │ TaskExecutor  │  │ AgentStorage  │  │ SignalSource  │           │
│  └───────┬───────┘  └───────┬───────┘  └───────┬───────┘           │
│          │                  │                  │                    │
└──────────┼──────────────────┼──────────────────┼────────────────────┘
           │                  │                  │
     ┌─────┴─────┐      ┌─────┴─────┐      ┌─────┴─────┐
     ▼           ▼      ▼           ▼      ▼           ▼
┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐
│ Remote  │ │ Local   │ │ Remote  │ │ SQLite  │ │ Remote  │ │ Stdin   │
│ Workers │ │ Process │ │ Server  │ │ File    │ │ Server  │ │ Channel │
└─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘
    (current)   (new)      (current)   (new)      (current)   (new)
```

**Composition Examples:**

| Mode | TaskExecutor | AgentStorage | SignalSource |
|------|--------------|--------------|--------------|
| Full Remote | RemoteWorkers | RemoteServer | RemoteServer |
| Local + Persist | LocalProcess | SQLite | Stdin/Channel |
| Ephemeral | LocalProcess | InMemory | Stdin/Channel |
| Hybrid | RemoteWorkers | SQLite | Stdin/Channel |

### Example: Local Coding Agent

```rust
// Define tasks that run locally
struct ReadFileTask;
impl TaskDefinition for ReadFileTask {
    async fn execute(&self, ctx: &TaskContext, input: ReadFileInput) -> Result<String> {
        tokio::fs::read_to_string(&input.path).await
    }
}

struct WriteFileTask;
impl TaskDefinition for WriteFileTask {
    async fn execute(&self, ctx: &TaskContext, input: WriteFileInput) -> Result<()> {
        tokio::fs::write(&input.path, &input.content).await
    }
}

struct ShellCommandTask;
impl TaskDefinition for ShellCommandTask {
    async fn execute(&self, ctx: &TaskContext, input: ShellInput) -> Result<ShellOutput> {
        Command::new("sh").arg("-c").arg(&input.command).output().await
    }
}

// Build local agent
let task_registry = TaskRegistry::new()
    .register(ReadFileTask)
    .register(WriteFileTask)
    .register(ShellCommandTask);

let agent = AgentBuilder::new()
    .storage(SqliteStorage::new("./coding-agent.db"))
    .task_executor(LocalTaskExecutor::new(task_registry))
    .signals(InteractiveSignalSource::from_stdin())
    .build();

// Run agent
agent.execute(CodingAgent, input).await?;
```

The coding agent:
- Persists state to local SQLite (optional, could be in-memory)
- Executes file/shell tasks in-process
- Receives signals from stdin (user messages)
- No server connection needed

### Determinism Requirements

For segment-level replay to work, agent code must be deterministic within a segment:

**Allowed:**
```rust
// Deterministic - same sequence number, same task ID
let f1 = ctx.schedule_task("task-a", input);
let result = f1.await?;

// Deterministic - uses ctx.random() which is seeded
let id = ctx.random_uuid();

// Deterministic - uses ctx.current_time() which is segment-start time
let now = ctx.current_time();
```

**Not Allowed:**
```rust
// Non-deterministic - different on replay!
let id = Uuid::new_v4();
let now = SystemTime::now();
let random = rand::random::<u64>();

// Conditional scheduling based on non-deterministic value
if SystemTime::now().elapsed() > Duration::from_secs(10) {
    ctx.schedule_task("timeout-task", input);  // May not exist on replay!
}
```

This is the same requirement as workflows. External non-determinism (LLM responses, API calls) is captured via task results.

## Migration Path

### Phase 1: Internal Refactor (Non-Breaking)

1. Add `AgentStorage` trait
2. Add `TaskExecutor` trait
3. Refactor `AgentContextImpl` to use these traits
4. Current behavior preserved (remote storage, remote execution)

### Phase 2: Add Command Batching

1. Add command batching to `AgentContextImpl`
2. Keep current API, but batch internally
3. Commit at suspension points
4. Add sequence-based ID generation

### Phase 3: New Lazy API

1. Add `schedule_task()` returning `AgentTaskFuture`
2. Deprecate `schedule_task_handle()`
3. Unify with workflow `join_all`, `select`, etc.

### Phase 4: Local Mode

1. Add `SqliteStorage` implementation
2. Add `LocalTaskExecutor` implementation
3. Add `InteractiveSignalSource`
4. Document local mode usage

### Phase 5: Hierarchical Agents

1. Add `spawn_local_agent()` / `spawn_remote_agent()` APIs
2. Add parent-child signal communication
3. Add `SharedContext` options for conversation sharing
4. Implement `LocalWorkerDaemon` for user machines
5. Add escalation chain support (child → parent → human)

## Alternatives Considered

### Alternative 1: Full Deterministic Replay (Like Workflows)

Agents replay from the beginning on recovery, not from checkpoints.

**Pros:**
- Fully unified with workflow model
- Simpler mental model

**Cons:**
- Agents can be very long-running (days/weeks for coding agents)
- Replay from beginning is expensive
- Loses checkpoint flexibility

**Decision:** Keep checkpoint-based recovery, but make segments deterministic.

### Alternative 2: Keep Current Model, Just Add Local Storage

Keep immediate RPCs, just swap storage backend.

**Pros:**
- Minimal changes
- No API changes

**Cons:**
- Still requires server-like component for task execution coordination
- API remains different from workflows
- Harder to reason about parallelism

**Decision:** Unify the model for consistency and simplicity.

### Alternative 3: Make Checkpoints Implicit

Auto-checkpoint after every operation.

**Pros:**
- No explicit checkpoint calls
- Fine-grained recovery

**Cons:**
- High overhead (many checkpoints)
- Less control for agent authors
- Doesn't align with workflow batching model

**Decision:** Keep explicit checkpoints as segment boundaries, batch commands between them.

## When Is Persistence Actually Needed?

The user raised an important point: *"checkpoints/message history is only for crash recovery - less precise than deterministic replay."*

Let's examine when persistence is actually required:

| Scenario | Crash Recovery? | Progress Visibility? | Audit/Compliance? | Persistence Needed? |
|----------|-----------------|---------------------|-------------------|---------------------|
| Quick CLI task (< 1 min) | No (re-run if fails) | No (user watching) | No | **None** |
| Coding agent (git repo) | Git IS recovery | Maybe (IDE shows) | Git history | **Minimal** (entries for UX) |
| Research agent (hours) | Yes (expensive) | Yes (user checks) | Maybe | **Full** |
| CI daemon (always on) | Yes (must resume) | Yes (dashboards) | Yes (audit log) | **Full** |

**Key insight**: For many agent use cases, especially local ones, persistence is optional or handled externally (git, filesystem).

### Minimal Persistence Mode

For agents that don't need full persistence:

```rust
let agent = AgentBuilder::new()
    .storage(MinimalStorage::new())  // Only tracks in-flight tasks
    .task_executor(LocalTaskExecutor::new(tasks))
    .signals(StdinSignalSource::new())
    .build();
```

`MinimalStorage` would:
- Track scheduled tasks (for `join_all` to work)
- NOT persist checkpoints
- NOT persist entries (unless explicitly saved)
- On crash: agent must restart from beginning (acceptable for short tasks)

### Progressive Persistence

An agent could opt into persistence at specific points:

```rust
async fn execute(&self, ctx: &dyn AgentContext, input: Input) -> Result<Output> {
    // Phase 1: Quick local work, no persistence needed
    let files = ctx.schedule_task("scan-files", input).await?;

    // Phase 2: Expensive LLM work, persist for recovery
    ctx.enable_persistence();  // Start persisting from here
    let analysis = ctx.schedule_task("llm-analyze", files).await?;

    // Phase 3: Make changes
    ctx.schedule_task("apply-changes", analysis).await?;

    Ok(output)
}
```

This gives agent authors control over the persistence vs performance tradeoff.

## Hierarchical Agents: Remote + Local Sub-Agents

A powerful pattern emerges: a **remote agent** (full durability, cloud-hosted) that commands **local sub-agents** (ephemeral, running on user's machine).

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    REMOTE AGENT (Flovyn Server)                 │
│  • Full async (L2/L3), durable state, crash recovery            │
│  • Plans, coordinates, makes LLM calls                          │
│  • Accessible from anywhere, persists conversation              │
│                                                                 │
│  async fn execute(&self, ctx, input) {                          │
│      let plan = ctx.schedule_task("llm-plan", goal).await?;     │
│                                                                 │
│      // Unified API: spawn_agent(mode, input, options)          │
│      let handle = ctx.spawn_agent(                              │
│          AgentMode::Local("coder"),  // or External(Pi{...})    │
│          plan,                                                  │
│          SpawnOptions::default(),                               │
│      ).await?;                                                  │
│                                                                 │
│      // Monitor and assist                                      │
│      loop {                                                     │
│          match ctx.wait_for_child_event(handle).await? {        │
│              ChildEvent::Signal { name: "needs-help", .. } => { │
│                  /* assist */                                   │
│              }                                                  │
│              ChildEvent::Signal { name: "progress", .. } => {   │
│                  /* log */                                      │
│              }                                                  │
│              ChildEvent::Completed { output } => break Ok(output),
│          }                                                      │
│      }                                                          │
│  }                                                              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ (signal / task queue)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│               LOCAL SUB-AGENT (User's Machine)                  │
│  • Ephemeral (parent tracks macro-state)                        │
│  • Direct file system, git, terminal access                     │
│  • Fast local execution (no network latency for file ops)       │
│  • Can escalate to parent for help                              │
│                                                                 │
│  async fn execute(&self, ctx, plan) {                           │
│      for step in plan.steps {                                   │
│          let files = ctx.schedule_task("read-files", ..).await?;│
│          let edit = ctx.schedule_task("llm-edit", ..).await?;   │
│          ctx.schedule_task("write-file", edit).await?;          │
│                                                                 │
│          // Run tests locally                                   │
│          let result = ctx.schedule_task("run-tests", ..).await?;│
│          if result.failed {                                     │
│              // Escalate to parent for help                     │
│              ctx.signal_parent("needs-help", question).await?;  │
│              let guidance = ctx.wait_for_signal("guidance").await?;
│          }                                                      │
│                                                                 │
│          ctx.signal_parent("progress", step).await?;            │
│      }                                                          │
│      Ok(result)                                                 │
│  }                                                              │
└─────────────────────────────────────────────────────────────────┘
```

**The child can be any of:**
- `AgentMode::Local("coder")` - Native Flovyn agent on user's machine
- `AgentMode::Remote("researcher")` - Native Flovyn agent on server
- `AgentMode::External(ExternalAgent::Pi{...})` - External Pi agent
- `AgentMode::External(ExternalAgent::ClaudeCode{...})` - External Claude Code

### Why This Pattern?

| Concern | Remote Agent | Local Sub-Agent |
|---------|--------------|-----------------|
| LLM API calls | ✓ (has keys, billing) | Via parent or own |
| File system access | ✗ | ✓ (direct) |
| Git operations | ✗ | ✓ |
| Run tests/build | ✗ | ✓ |
| Persistence | ✓ (full durability) | Minimal (parent tracks) |
| Crash recovery | ✓ (checkpoints) | Parent re-spawns |
| User disconnect | Keeps running | Dies, parent re-spawns |
| Network latency | High (cloud) | None (local) |

This mirrors production systems:
- **Devin**: Cloud planning + local sandbox
- **Cursor Background Agents**: Cloud coordination + local IDE
- **Copilot Workspace**: Cloud planning + local execution

### Local Agent Doesn't Need Full Durability

The local sub-agent can be **ephemeral** because:

1. **Parent tracks macro-state**: "Step 3 of 5 complete, files modified: [a.rs, b.rs]"
2. **Git tracks micro-state**: Actual code changes are committed
3. **Parent re-spawns on failure**: With context of what was already done

```rust
// Parent's checkpoint includes child progress
ctx.checkpoint(&json!({
    "phase": "local-execution",
    "child_progress": {
        "steps_completed": 3,
        "files_modified": ["src/main.rs", "src/lib.rs"],
        "last_test_result": "2 failures"
    }
})).await?;

// If local agent dies, parent can re-spawn with context
let handle = ctx.spawn_local_agent("coder", RecoveryPlan {
    original_plan: plan,
    already_done: checkpoint.child_progress,
    resume_from: "step 4",
}).await?;
```

### API Extensions

#### Spawning Child Agents

```rust
// Unified API: spawn_agent(mode, input, options)

// Spawn a local Flovyn agent (runs on connected local worker)
let handle = ctx.spawn_agent(
    AgentMode::Local("coder"),
    input,
    SpawnOptions::default(),
).await?;

// Spawn a remote Flovyn agent (runs on server, full durability)
let handle = ctx.spawn_agent(
    AgentMode::Remote("researcher"),
    input,
    SpawnOptions::default(),
).await?;

// Spawn an external agent (Pi, Claude Code, etc.)
let handle = ctx.spawn_agent(
    AgentMode::External(ExternalAgent::Pi {
        working_dir: project_path,
        model: None,
    }),
    input,
    SpawnOptions::default(),
).await?;

// With options
let handle = ctx.spawn_agent(
    AgentMode::Local("coder"),
    input,
    SpawnOptions {
        persistence: Persistence::Ephemeral,
        shared_context: SharedContext::Conversation,
        machine: Some("dev-laptop".into()),  // for multi-machine
    },
).await?;
```

```rust
pub enum AgentMode {
    /// Run on Flovyn server (full durability)
    Remote(String),

    /// Run on user's local machine (ephemeral, fast local access)
    Local(String),

    /// Run external agent (Pi, Claude Code, etc.)
    External(ExternalAgent),
}

pub struct SpawnOptions {
    pub persistence: Persistence,        // Full, Minimal, Ephemeral
    pub shared_context: SharedContext,   // None, Conversation, Custom
    pub machine: Option<String>,         // Target machine for Local mode
}
```

#### Parent-Child Communication

```rust
// Child signals parent
ctx.signal_parent("needs-help", json!({"question": "..."})).await?;
ctx.signal_parent("progress", json!({"step": 3, "status": "..."})).await?;

// Parent signals child
ctx.signal_child(handle, "guidance", json!({"answer": "..."})).await?;
ctx.signal_child(handle, "cancel", json!({"reason": "..."})).await?;

// Parent waits for child events
let event = ctx.wait_for_child_event(handle).await?;
match event {
    ChildEvent::Signal { name, payload } => { /* handle */ }
    ChildEvent::Completed { output } => { /* done */ }
    ChildEvent::Failed { error } => { /* handle failure */ }
}
```

#### Shared Context Options

```rust
pub enum SharedContext {
    /// No shared context - child is independent
    None,

    /// Child appends to parent's conversation tree
    /// Parent sees child's entries in real-time
    Conversation,

    /// Child has read-only view of parent's conversation
    ConversationReadOnly,

    /// Custom shared state
    Custom(Value),
}
```

### Local Worker Daemon

A lightweight daemon runs on the user's machine:

```
┌─────────────────────────────────────────────────────────────────┐
│                    LOCAL WORKER DAEMON                          │
│  • Connects to Flovyn server (authenticated)                    │
│  • Polls for "local agent" tasks assigned to this user/machine  │
│  • Executes local agents with LocalTaskExecutor                 │
│  • Reports results/signals back to server                       │
│                                                                 │
│  Components:                                                    │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │ AgentRunner │  │   Sandbox   │  │   Signal    │             │
│  │ (ephemeral) │  │  (project   │  │   Bridge    │             │
│  │             │  │   scoped)   │  │  (to server)│             │
│  └─────────────┘  └─────────────┘  └─────────────┘             │
└─────────────────────────────────────────────────────────────────┘
```

```rust
// Starting local worker daemon
let daemon = LocalWorkerDaemon::builder()
    .server_url("https://flovyn.example.com")
    .auth_token(user_token)
    .workspace("/path/to/project")
    .register_agent(CoderAgent)
    .register_task(ReadFileTask)
    .register_task(WriteFileTask)
    .register_task(ShellCommandTask)
    .build();

daemon.run().await;  // Long-running, waits for work
```

### Advanced Patterns

#### Multi-Machine Coordination

A remote agent coordinating work across multiple local environments:

```rust
async fn execute(&self, ctx, input) {
    // Spawn agents on different machines using unified API
    let frontend = ctx.spawn_agent(
        AgentMode::Local("coder"),
        frontend_plan,
        SpawnOptions { machine: Some("dev-laptop".into()), ..Default::default() },
    ).await?;

    let backend = ctx.spawn_agent(
        AgentMode::Local("coder"),
        backend_plan,
        SpawnOptions { machine: Some("server-1".into()), ..Default::default() },
    ).await?;

    // Coordinate
    let fe_result = ctx.wait_for_child(frontend).await?;
    ctx.signal_child(backend, "frontend-ready", fe_result).await?;
    let be_result = ctx.wait_for_child(backend).await?;

    Ok(json!({"frontend": fe_result, "backend": be_result}))
}
```

#### Escalation Chain

Local agent → Parent agent → Human:

```rust
// Local agent encounters issue
if tests_failing && attempts > 3 {
    ctx.signal_parent("escalate", json!({
        "issue": "Can't fix test failure",
        "context": diagnostic_info,
        "options": ["ask human", "skip test", "revert changes"]
    })).await?;

    let decision = ctx.wait_for_signal("escalation-response").await?;
    // Parent either handles it or escalates to human (INPUT_REQUIRED)
}
```

#### Hybrid LLM Routing

Local agent can use parent for LLM calls (centralized billing, API keys):

```rust
// Local agent delegates LLM call to parent
let response = ctx.request_from_parent("llm-call", json!({
    "model": "claude-3-opus",
    "prompt": analysis_prompt,
})).await?;

// Or use local LLM if available
let response = ctx.schedule_task("local-llm", json!({
    "model": "llama-3",
    "prompt": quick_prompt,
})).await?;
```

### Integration with External Coding Agents

The [External Coding Agent Integration](../research/20260211_external_coding_agent_integration.md) research explores integrating tools like **Pi** and **Claude Code**. The hierarchical agent model provides a natural framework for this:

```
┌─────────────────────────────────────────────────────────────────┐
│                    REMOTE ORCHESTRATOR AGENT                    │
│                    (Flovyn Server - Durable)                    │
│                                                                 │
│  • Plans overall approach                                       │
│  • Coordinates multiple coding agents                           │
│  • Persists state, handles user interaction                     │
│  • Routes work to appropriate local agent                       │
└─────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ LOCAL FLOVYN    │ │ EXTERNAL PI     │ │ EXTERNAL CLAUDE │
│ AGENT           │ │ AGENT           │ │ CODE            │
│ (Native tasks)  │ │ (via Adapter)   │ │ (via Adapter)   │
│                 │ │                 │ │                 │
│ • File I/O      │ │ • RPC protocol  │ │ • SDK/subprocess│
│ • Shell cmds    │ │ • Own session   │ │ • Own session   │
│ • Git ops       │ │ • Sophisticated │ │ • MCP tools     │
│                 │ │   tree history  │ │                 │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

**"Local agent" can be:**

1. **Native Flovyn Agent** - Uses `LocalTaskExecutor`, same execution model
2. **External Agent via Adapter** - Pi, Claude Code wrapped in `ExternalAgentProtocol`
3. **Hybrid** - Flovyn agent that delegates to external agents for specific tasks

#### Unified spawn_agent API

A single `spawn_agent(mode, ...)` API handles all cases:

```rust
// Spawn native Flovyn agent running locally
let handle = ctx.spawn_agent(AgentMode::Local("flovyn-coder"), plan).await?;

// Spawn native Flovyn agent running remotely (on server)
let handle = ctx.spawn_agent(AgentMode::Remote("researcher"), plan).await?;

// Spawn external Pi agent (via adapter)
let handle = ctx.spawn_agent(AgentMode::External(ExternalAgent::Pi {
    working_dir: "/path/to/project".into(),
    model: Some("claude-3-5-sonnet".into()),
}), plan).await?;

// Spawn external Claude Code agent
let handle = ctx.spawn_agent(AgentMode::External(ExternalAgent::ClaudeCode {
    working_dir: "/path/to/project".into(),
    mcp_servers: vec!["github", "filesystem"],
}), plan).await?;
```

```rust
pub enum AgentMode {
    /// Run on Flovyn server (full durability)
    Remote(String),  // agent kind

    /// Run on user's local machine (ephemeral, fast local access)
    Local(String),   // agent kind

    /// Run external agent (Pi, Claude Code, etc.)
    External(ExternalAgent),
}

pub enum ExternalAgent {
    Pi { working_dir: PathBuf, model: Option<String> },
    ClaudeCode { working_dir: PathBuf, mcp_servers: Vec<String> },
    Custom { protocol: String, config: Value },
}
```

#### Event Bridge

External agent events map to Flovyn's model (from the research doc):

| External Agent Event | Flovyn Action |
|---------------------|---------------|
| `text_delta` | `ctx.stream_token()` |
| `tool_call_start` | `ctx.append_tool_call()` |
| `tool_call_end` | `ctx.append_tool_result()` |
| `turn_end` | `ctx.checkpoint()` + signal parent |
| `agent_end` | Child completion event |

#### State Ownership

Per the research recommendations:
- **External agent owns content** - Pi/Claude Code manage their own session files
- **Flovyn tracks metadata** - Session file path, turn count, timestamps in checkpoints
- **Recovery**: Flovyn restarts → reattaches to external agent via session file

```rust
// Parent's checkpoint includes external agent session reference
ctx.checkpoint(&json!({
    "child_type": "pi",
    "session_file": "/home/user/.pi/sessions/abc123.jsonl",
    "turn_count": 5,
    "last_tool": "write_file",
})).await?;
```

#### Protocol Abstraction

From the research, the `ExternalAgentProtocol` trait provides a clean interface:

```rust
#[async_trait]
pub trait ExternalAgentProtocol: Send + Sync {
    async fn start(&self, config: SessionConfig) -> Result<SessionHandle>;
    async fn send_message(&self, handle: &SessionHandle, msg: Message) -> Result<()>;
    async fn steer(&self, handle: &SessionHandle, msg: Message) -> Result<()>;
    fn subscribe(&self, handle: &SessionHandle) -> impl Stream<Item = AgentEvent>;
    async fn suspend(&self, handle: &SessionHandle) -> Result<SessionSnapshot>;
    async fn resume(&self, snapshot: SessionSnapshot) -> Result<SessionHandle>;
    async fn abort(&self, handle: &SessionHandle) -> Result<()>;
}
```

Implementations: `PiAgentProtocol`, `ClaudeCodeProtocol`, `McpAgentProtocol`

## Open Questions

1. **Checkpoint frequency**: Should we auto-checkpoint at certain intervals, or leave it entirely to agent code?

2. **Backward compatibility**: How to handle existing agents using `schedule_task_handle`? Deprecation period?

3. **Entry persistence**: Should entries be committed separately from checkpoints, or always together?

4. **Signal persistence in local mode**: How to persist signals for recovery when running locally?

5. **Task timeout in local mode**: How should server-side timeouts work when tasks execute locally?

6. **Minimal vs full persistence**: Should persistence be opt-in (minimal by default) or opt-out (full by default)?

7. **Hybrid mode**: Can an agent start local and "upgrade" to remote persistence mid-execution?

8. **Local worker security**: How to authenticate local workers? Scope access to specific projects?

9. **Multi-machine routing**: How does parent specify which local machine should run a child agent?

10. **Conversation sharing**: If child appends to parent's conversation, how to handle concurrent writes?

## Summary: Why This Design Matters

1. **Unified API**: Agents and workflows use the same patterns for parallel execution
   ```rust
   // Same in both workflows and agents
   let results = join_all(vec![task1, task2, task3]).await?;
   ```

2. **Local Mode**: Agents can run without any server, enabling:
   - Coding agents that only need local file system
   - CLI tools that run ephemerally
   - Offline operation with later sync

3. **Async Agent Vision**: The design supports all three levels from the research:
   - L1 (Fire-and-forget): Simple task execution
   - L2 (Supervised): Progress, input requests, plan approval
   - L3 (Daemon): Long-running, event-driven

4. **Flexibility**: Same execution model, different backends:
   - Full remote (current production)
   - Local with persistence (coding agent)
   - Ephemeral (quick CLI task)

5. **Simpler Mental Model**:
   - No immediate RPCs during scheduling
   - Commands batched, committed atomically
   - Determinism within segments enables replay for debugging

## References

- [Async Agents Research](../research/20260212_async-agents.md) - Formalized definition
- Current workflow implementation: `sdk-rust/worker-sdk/src/workflow/`
- Current agent implementation: `sdk-rust/worker-sdk/src/agent/`
- Temporal's deterministic execution model

---

## Appendix: Gaps Identified from Research

*Based on web research of LangGraph, local-first patterns, multi-agent orchestration (CrewAI, AutoGen), and observability tooling (LangSmith). Note: We intentionally reject Temporal/Restate's "workflows for everything" narrative - their deterministic replay model doesn't work for LLM-based agents.*

### Gap 1: Observability / Tracing

**Problem:** The design mentions entries and progress reporting but lacks structured tracing.

Research shows 89% of organizations with AI agents have some observability. LangSmith provides token-level traces, tool call attribution, cost tracking, and latency breakdowns.

**Gap in current design:**
- No structured tracing format
- No cost attribution model
- No debugging/replay tooling for failed turns
- Tracing works differently in remote vs local modes

**Recommendation:** Add `AgentTracer` abstraction that works in all modes:

```rust
pub trait AgentTracer: Send + Sync {
    fn trace_turn_start(&self, turn: u64, input: &Value);
    fn trace_tool_call(&self, tool: &str, input: &Value, latency_ms: u64);
    fn trace_tokens(&self, input_tokens: u64, output_tokens: u64, model: &str);
    fn trace_turn_end(&self, turn: u64, output: &Value);
    fn trace_error(&self, error: &AgentError);
}

// Implementations
pub struct RemoteTracer { /* sends to server */ }
pub struct LocalTracer { /* writes to file/sqlite */ }
pub struct StdoutTracer { /* prints for debugging */ }
pub struct CompositeTracer { /* multiple tracers */ }
```

Even ephemeral local agents need debugging capability.

Decision: To adopt AgentTracer

---

### Gap 2: Cancellation Semantics

**Problem:** When a parent cancels a child agent, what happens?

The design mentions `ctx.signal_child(handle, "cancel", ...)` but doesn't specify:
- Graceful vs hard cancellation
- What happens to in-flight tool calls
- What state is persisted on cancellation
- How external agents (Pi, Claude Code) handle abort

**Recommendation:** Define explicit cancellation semantics:

```rust
pub enum CancellationMode {
    /// Wait for current tool to complete, then stop
    Graceful { timeout: Duration },

    /// Stop immediately, abandon in-flight work
    Hard,
}

// Parent cancels child
ctx.cancel_child(handle, CancellationMode::Graceful {
    timeout: Duration::from_secs(30)
}).await?;

// Child receives cancellation
if ctx.is_cancellation_requested() {
    // Clean up and return partial result
    return Ok(PartialOutput { completed_steps, reason: "cancelled" });
}
```

For external agents, `ExternalAgentProtocol::abort()` needs clearer semantics about what state is preserved.

Decision: Adopt

---

### Gap 3: Cost / Budget Controls

**Problem:** Long-running agents can rack up significant LLM costs. No mechanism to control this.

**Gap in current design:**
- No token budgets per agent/turn
- No cost callbacks
- No budget-exceeded signals
- No way for parent to set limits on child agents

**Recommendation:** Add budget controls to spawn options:

```rust
pub struct Budget {
    /// Maximum tokens (input + output) for this agent's lifetime
    pub max_tokens: Option<u64>,

    /// Maximum cost in USD (requires model pricing info)
    pub max_cost_usd: Option<f64>,

    /// Maximum tokens per single LLM call
    pub max_tokens_per_call: Option<u64>,
}

let handle = ctx.spawn_agent(
    AgentMode::Local("coder"),
    input,
    SpawnOptions {
        budget: Some(Budget {
            max_tokens: Some(100_000),
            max_cost_usd: Some(5.00),
            ..Default::default()
        }),
        ..Default::default()
    },
).await?;

// Agent receives budget info
let remaining = ctx.remaining_budget();
if remaining.tokens < 1000 {
    ctx.signal_parent("budget-low", json!({"remaining": remaining})).await?;
}

// Budget exceeded = automatic graceful cancellation
// Parent receives: ChildEvent::BudgetExceeded { used, limit }
```

Decision: Adopt

---

### Gap 4: Typed State Schemas

**Problem:** We have `checkpoint(&state)` but no formal state schema.

LangGraph uses explicit state schemas with reducers:
```python
class AgentState(TypedDict):
    messages: Annotated[list, add_messages]  # reducer defines merge behavior
```

**Gap in current design:**
- Inconsistent checkpoint structures across agents
- No type-safe state updates
- Harder to reason about state evolution over time
- No schema versioning for long-running agents

**Recommendation:** Optional typed state schemas:

```rust
// Agent defines its state schema
#[derive(AgentState, Serialize, Deserialize)]
struct CoderState {
    #[reducer(append)]  // New messages append to list
    messages: Vec<Message>,

    #[reducer(replace)]  // Latest value wins
    current_file: Option<String>,

    #[reducer(merge)]  // Deep merge
    file_changes: HashMap<String, FileChange>,
}

// Type-safe checkpoint
ctx.checkpoint(&state).await?;  // Compiler ensures correct type

// Recovery returns typed state
let state: CoderState = ctx.load_checkpoint().await?;
```

Make this optional - simple agents can still use `Value` for flexibility.

Decision: Adopt

---

### Gap 5: Coding Agent Recovery Model

**Clarification:** The design says "git IS the state" but this was imprecise.

For coding agents:
- **What the agent manipulates:** source code → versioned in git
- **The agent's own state:** conversation, plan, current step → ephemeral/in-memory

The key insight: **the artifact (source code) matters more than the agent's internal state**.

If a coding agent crashes:
1. Source code changes are in the working directory (`git diff` shows them)
2. Agent can restart fresh, inspect `git status`, and figure out where to continue
3. No need for sophisticated agent checkpointing - the code IS the checkpoint

**Gap in current design:**
- No explicit "artifact-centric" recovery model
- The design assumes agent state is always important to persist
- No tooling for "resume from working directory state"

**Recommendation:** Support artifact-centric agents explicitly:

```rust
pub enum RecoveryModel {
    /// Traditional: persist agent state, restore on crash
    StateCentric {
        storage: Box<dyn AgentStorage>,
    },

    /// Artifact-centric: agent state is ephemeral, artifact is durable
    /// On restart, agent inspects artifact to determine next steps
    ArtifactCentric {
        /// Function to derive "where am I?" from artifact state
        inspect: Box<dyn Fn() -> ArtifactState>,
    },
}

// Coding agent uses artifact-centric recovery
let agent = AgentBuilder::new()
    .recovery(RecoveryModel::ArtifactCentric {
        inspect: Box::new(|| {
            // Look at git status, uncommitted changes, test results
            let diff = git_diff();
            let status = git_status();
            ArtifactState { diff, status, ... }
        }),
    })
    .task_executor(LocalTaskExecutor::new(tasks))
    .build();

// On restart, agent receives artifact state and decides what to do
async fn execute(&self, ctx: &dyn AgentContext, input: Input) -> Result<Output> {
    let artifact = ctx.get_artifact_state()?;  // From inspect function

    if artifact.has_uncommitted_changes() {
        // Resume: figure out what was being done
        let analysis = ctx.schedule_task("analyze-diff", artifact.diff).await?;
        // Continue from there...
    } else {
        // Fresh start
    }
}
```

This is simpler than trying to persist agent state - let the agent be smart about recovering from the artifact.

Decision: not adopt. Let agent persist session state locally, and can recover from that, like Claude Code --resume

---

### Gap 6: Agent Handoff vs Spawn

**Problem:** Current design only has `spawn_agent()` where parent remains in control.

Multi-agent research shows another pattern: **handoff** where control transfers completely.

**Gap in current design:**
- No way to transfer ownership to another agent
- No way to pass conversation context without parent staying involved
- Parent must stay alive to receive child completion

**Recommendation:** Add handoff semantics:

```rust
// Spawn: Parent stays in control, child is subordinate
let handle = ctx.spawn_agent(mode, input, opts).await?;
// Parent continues running, monitors child

// Handoff: Transfer control completely
ctx.handoff_to_agent(
    AgentMode::External(ExternalAgent::Pi { ... }),
    input,
    HandoffOptions {
        // Pass conversation to new agent
        conversation: ctx.get_conversation(),
        // Parent completes after handoff
        completion: HandoffCompletion::WaitForChild,
    }
).await?;
// Parent suspends until child completes, then parent completes with child's result

// Or immediate completion
ctx.handoff_to_agent(
    mode, input,
    HandoffOptions {
        completion: HandoffCompletion::Immediate,  // Parent done, child continues independently
    }
).await?;
```

Use case: Orchestrator decides a task needs Pi's capabilities, hands off completely rather than supervising.

Question: how agent know the name/ID of each peers to communicate?
Comment: the handoff API looks OK

**Answer to question:** For parent-child communication, the parent receives a handle from `spawn_agent()` which contains the child's ID. The child doesn't need to know parent ID - it uses `signal_parent()` which routes via the runtime. For peer-to-peer (if we add it later), options:
1. **Registry-based:** Agents register with names, peers lookup by name
2. **Introduction-based:** Parent spawns both, passes each other's handles
3. **Broadcast:** Signal all agents of a certain type

For MVP, parent-child is sufficient. Peer-to-peer can be deferred.

---

### Gap 7: Signal Persistence in Local Mode (from Open Questions)

**Problem:** Open Question #4 asks about signal persistence in local mode.

**Recommendation:** Define signal storage as part of `AgentStorage`:

```rust
pub trait AgentStorage: Send + Sync {
    // ... existing methods ...

    /// Store a pending signal for an agent
    async fn store_signal(&self, agent_id: &str, signal: Signal) -> Result<()>;

    /// Get and remove pending signal
    async fn pop_signal(&self, agent_id: &str, signal_name: &str) -> Result<Option<Signal>>;
}
```

For `SqliteStorage`, signals are stored in a table. For `InMemoryStorage`, signals are just in a HashMap.

Decision: OK.

---

### Summary: Priority Matrix (with Decisions)

| Gap | Priority | Decision | Notes |
|-----|----------|----------|-------|
| Observability/Tracing | **High** | ✅ Adopt | AgentTracer abstraction |
| Cancellation Semantics | **High** | ✅ Adopt | Graceful/Hard modes |
| Cost/Budget Controls | Medium | ✅ Adopt | Token/cost limits |
| Typed State Schemas | Medium | ✅ Adopt | Optional, for DX |
| Artifact-centric Recovery | Medium | ❌ Reject | Use session persistence like Claude Code --resume |
| Signal Persistence | Medium | ✅ Adopt | Part of AgentStorage trait |
| Agent Handoff | Low | ✅ Adopt | API looks OK, peer discovery deferred |

### What We Correctly Reject

**Temporal/Restate's "Durable Execution" for Agents:**
- Their model assumes deterministic replay works
- LLM calls are not deterministic - you can't replay them
- Forcing determinism on agent code is unnatural
- Our checkpoint-based recovery is the right approach

**Over-engineering state management:**
- We don't need CRDT-level sync for most agents
- Git provides sufficient versioning for coding agents
- Simple checkpoints work for most use cases
