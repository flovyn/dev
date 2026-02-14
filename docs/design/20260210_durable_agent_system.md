# Durable Agent System

**Date:** 2026-02-10
**Status:** Draft
**Issue:** [flovyn/dev#17](https://github.com/flovyn/dev/issues/17)

## Context

Flovyn is a distributed durable execution platform. Today it supports two primitives: **workflows** (deterministic, event-sourced orchestration) and **tasks** (stateless units of work executed on remote workers). These primitives power reliable, observable, and recoverable business processes.

We recently built an AI agent on top of Flovyn's workflow primitive ([agent-session-integration design](20260208_agent-session-integration.md)). The agent runs as a workflow of kind `"react-agent"`, where LLM calls and tool executions are modeled as tasks. The conversation loop uses signals for multi-turn interaction and workflow state (`ctx.set_raw("messages", ...)`) for persistence.

This approach has hit fundamental limits, documented in [agent-data-model.md](20260209_agent-data-model.md):

1. **gRPC message size exceeded**: A single agent session produced 222 events, with tool outputs (shell commands, file reads) reaching megabytes. The 4MB gRPC limit was hit during replay.

2. **Unbounded replay cost**: Every time the agent resumes (after each tool call, each user message), the server sends the entire event history for replay. With 222+ events carrying large payloads, this makes resume increasingly slow.

3. **Determinism mismatch**: LLM calls are inherently non-deterministic. The workflow model assumes deterministic replay — replaying the same events should produce the same commands. This assumption breaks for agents. Today it works only because task results are cached in events, but this forces all LLM outputs into the event stream, inflating it further.

4. **History-recovery coupling**: The workflow event history serves double duty as both the recovery mechanism (replay from event 0) and the execution record. For agents, the history grows without bound (every LLM call, every tool invocation), directly degrading recovery performance.

The ideas document ([durable-agent-system.md](~/shared/ideas/durable-agent-system.md)) proposes resolving this by making Agent a first-class primitive with checkpoint-based recovery instead of event-sourced replay.

Additionally, a proven tree-based conversation data model ([~/shared/ideas/tree/](~/shared/ideas/tree/)) from a previous project provides a battle-tested approach to conversation storage, context management, and extensibility. Rather than storing the full messages array as a blob in each checkpoint, conversation entries form a tree (linked via `parent_id`). Checkpoints reference a position (leaf entry ID) in this tree. This model was successfully implemented through 4 phases: tree as source of truth, variants + model switching + cost tracking, branching + compaction, and sub-agents.

This design document combines both ideas: checkpoint-based recovery from the durable execution model, with tree-structured conversation storage from the context management model.

## Problem Statement

### The Three-Way Conflict

The current architecture forces three concerns through the same mechanism (workflow event history):

| Concern | What it needs | What the workflow model provides |
|---------|--------------|----------------------------------|
| **Durability** | Fast recovery from crashes | Replay all events from event 0 — gets slower as history grows |
| **Observability** | Record of every action | Every action becomes an event — inflates the data used for recovery |
| **Scalability** | Handle long sessions with large payloads | All payloads flow through events and gRPC — hits size and performance limits |

For workflows with bounded, predictable steps, this coupling works well. For agents with hundreds of LLM calls and megabytes of tool output, it breaks down.

### Evidence from Production

From a real agent session (single user prompt, coding task):

- **222 workflow events** generated (TASK_SCHEDULED, TASK_COMPLETED, STATE_SET repeated for each tool call)
- **gRPC limit hit**: `message length too large: found 4,309,449 bytes, the limit is: 4,194,304 bytes`
- **Pattern per tool call**: ~8 events (schedule task, suspend, task complete, set messages state, set usage state, set tool call state)
- **State bloat**: Full `messages` array serialized and stored as a STATE_SET event after every tool call

The current architecture cannot support longer sessions, larger tool outputs, or more complex agent interactions without fundamental changes.

## Goals

1. **Agent as a first-class primitive** — alongside workflows and tasks, with its own execution model, data model, and APIs
2. **Checkpoint-based recovery** — agents recover from the latest state snapshot, not by replaying all events
3. **One-shot agent execution** — fully working single-prompt agent sessions (like ManusAI), replacing the current workflow-based implementation
5. **Multi-turn interaction** — user can send follow-up messages, agent maintains conversation continuity
6. **Real-time streaming** — LLM tokens, tool output, and status changes stream to the UI as they happen
7. **Predefined agents** — reusable agent configurations (system prompt, model, tools) that can be instantiated as executions
8. **UI integration** — agent runs list, run detail with chat view, and agent definitions management in flovyn-app

## Non-Goals

- **Agent ↔ Workflow interaction** — agents calling workflows and vice versa (explicitly out of scope per issue #17)
- **Sub-agents / agent teams** — composing multiple agents together
- **Branching / forking** — creating alternative execution paths from checkpoints (data model supports it, implementation deferred)
- **Variants** — multiple views of the same conversation with different included/excluded entries
- **Context compaction / summarization** — compressing conversation history to fit context windows
- **Agent skills / extensions** — pluggable capabilities beyond built-in tools
- **Cloud sandboxed environments** — remote isolated execution (existing Docker sandbox is sufficient)
- **Human-in-the-loop approval flows** — structured approval widgets with escalation
- **Checkpoint retention policies** — automatic cleanup of old checkpoints
- **Agent state schema evolution** — handling checkpoint format changes across code versions

## Solution Overview

Introduce **Agent** as a third runtime primitive alongside Workflow and Task:

| Aspect | Workflow | Agent | Task |
|--------|----------|-------|------|
| Execution model | Deterministic, event-sourced replay | Non-deterministic, checkpoint-based | Stateless, single execution |
| Recovery | Replay all events from event 0 | Load latest checkpoint, resume | Retry from scratch |
| State persistence | Every state change is an event | Periodic state snapshots | No durable state |
| History | Source of truth for recovery | Entry tree (conversation) + `llm_call` entries (observability) | Task attempts log |
| Composition | Spawns tasks, child workflows | Spawns tasks | Standalone |

### Execution Modes: Durable vs Ephemeral

Not all agents need full persistence. A coding agent can generate GBs of conversation data (file contents, diffs, compiler output) — persisting every entry to the database is expensive and often unnecessary. But the user still needs to interact with it (signals) and observe it (streaming).

The design supports two persistence modes via the `AgentContext` trait:

| Capability | Remote | Local |
|-----------|-------------|-------|
| `append_entry()` | Persisted to server DB via gRPC | Worker-local storage (in-memory, file, SQLite, etc.) |
| `load_messages()` | Walk entry tree from server DB | Read from local storage |
| `checkpoint()` | Persisted to server DB | Local or no-op |
| `schedule_task()` | Via server | Via server (or local) |
| `wait_for_signal()` | Via server | Via server |
| `stream_token()` | Via server → SSE | Via server → SSE |
| Crash recovery | Resume from checkpoint on any worker | Only on the same worker |
| Data volume | Bounded by DB storage | Bounded by worker resources |

The agent logic is identical — `AgentDefinition.execute()` takes `&dyn AgentContext` and doesn't know which mode it's running in. The mode is chosen at execution creation time:

```json
POST /agent-executions
{
  "kind": "react-agent",
  "persistenceMode": "local",
  ...
}
```

**Local mode**: The `AgentExecution` record still exists in the server (for status tracking, signals, streaming). But entries and checkpoints are stored locally on the worker — not in the remote server database. The local storage mechanism is an implementation detail (in-memory, local files, SQLite, etc.) chosen by the worker. This handles GBs of coding agent data without remote DB overhead. The trade-off: the execution cannot be recovered from a different worker.

**Remote mode** (default): Entries and checkpoints persisted to the server database. The agent can recover from crashes and resume from any worker. Required for long-running background agents, async agents, and anything that must survive worker failures.

The `AgentContext` trait boundary makes this a configuration choice, not a code change. Same agent, different runtime behavior.

The agent execution lifecycle:

```
Create Agent Execution
    │
    ├── Agent worker polls and picks up execution
    │
    ├── Load state (from input on first run, from checkpoint on recovery)
    │
    ├── Enter run loop:
    │     ├── LLM reasoning (schedule llm-request task, stream tokens)
    │     ├── Tool execution (schedule tool tasks sequentially)
    │     ├── Checkpoint state (messages, usage, turn index)
    │     └── Continue / Complete / Wait for user input
    │
    ├── Wait for user input:
    │     ├── Checkpoint state (mandatory)
    │     ├── Agent suspends (WAITING status, no resources held)
    │     ├── User sends signal → agent resumes from checkpoint
    │     └── Re-enter run loop
    │
    ├── On crash:
    │     ├── Load latest checkpoint
    │     ├── Re-enter run loop from checkpoint state
    │     └── Re-submit pending task (idempotent via idempotency key)
    │
    └── Complete / Fail / Cancel
```

### Key Insight: Tree-Structured Conversation Storage

Instead of storing the full messages array as a blob (which grows unboundedly), each conversation message is stored as an individual **entry** in a tree structure linked via `parent_id`. This approach is proven across 4 implementation phases in a previous project.

**Why a tree instead of a flat array:**

| Concern | Flat array (in checkpoint) | Tree (entries table) |
|---------|---------------------------|----------------------|
| Persistence | Entire array serialized on each checkpoint | Each message persisted individually on creation |
| Crash resilience | Lose all messages since last checkpoint | Lose only the in-flight message |
| Checkpoint size | Grows with conversation length (MB+) | Constant (leaf reference + metadata) |
| Branching | Requires copying the entire array | Natural — new branch is a new child of any entry |
| Context selection | All or nothing | Per-entry inclusion/exclusion |
| Compaction | Replace array in-place | Add compaction entry to tree, mark old entries |
| Sub-agents | Separate array, manual coordination | Child agent's tree linked to parent via entry |

**For MVP**: The tree is a linear chain (each entry has one child). This gives us incremental persistence and lightweight checkpoints. Future phases add branching (multiple children per entry), variants, compaction, and sub-agents without schema changes.

**Context resolution**: To build the LLM messages array, walk from the checkpoint's leaf entry to the root, reverse to get chronological order. This replaces deserializing a blob from the checkpoint.

## Architecture

### System Architecture

```
flovyn-app (browser)                  flovyn-server                    agent-worker
─────────────────────                 ──────────────                   ────────────

POST /agent-executions ──────────►  Create AgentExecution  ──────┐
  { definition_id | inline config }   (PENDING)                  │
                                                                 │
GET /agent-executions/{id}/stream    ◄── SSE ──────────────────  │
  (EventSource)                                                  │
                                                                 │
                                      PollAgent ─────────────────┘
                                      (gRPC long-poll)
                                                                 │
                                      GetCheckpoint ◄────────────┤
                                                                 │
                                                                 ▼
                                                           AgentDefinition.execute()
                                                           ├─ ScheduleTask("llm-request")
                                                           │    └─ StreamAgentData (tokens)
                                                           ├─ ScheduleTask("bash")
                                                           │    └─ StreamAgentData (terminal)
                                                           ├─ SubmitCheckpoint
                                                           └─ ...
                                                                 │
POST /agent-executions/{id}/signal ► SignalAgent ────────────────┘
  { name: "userMessage", ... }        (resumes agent)
```

### Execution Model: Suspend/Resume with Checkpoint

The agent uses a **suspend/resume** model similar to workflows but with checkpoint-based recovery instead of event replay:

1. **Agent dispatched**: Worker polls `PollAgent`, receives agent execution (with input or checkpoint reference)
2. **Load state**: On first run, initialize from input. On resume/recovery, load latest checkpoint
3. **Execute**: Run agent logic — LLM calls and tool executions dispatched as tasks
4. **Task dispatch**: Agent schedules a task → server creates TaskExecution → agent suspends (WAITING)
5. **Task completes**: Server links task result to agent → resumes agent (PENDING for pickup)
6. **Agent resumes**: Worker polls, picks up agent, loads checkpoint + task result, continues
7. **Checkpoint**: After meaningful work (e.g., after all tools in a turn complete), persist state snapshot
8. **Yield for input**: When waiting for user, mandatory checkpoint + suspend with signal wait condition
9. **Crash recovery**: Load latest checkpoint, re-enter run loop. Any in-flight tasks re-submitted with idempotency keys

**Per-tool-call overhead**: Each tool call involves a suspend/resume cycle (similar to the current workflow model). The key improvement: resume loads a fixed-size checkpoint (O(1)) instead of replaying N events (O(N)). With NATS-based worker notifications, the suspend/resume latency is ~10-20ms.

### Checkpoint Strategy

With the tree model, **individual entries are persisted immediately** as each message completes (user message, assistant response, tool result). The checkpoint captures the agent's execution position:

```json
{
  "leafEntryId": "entry-uuid",    // Position in the conversation tree
  "totalUsage": { ... },          // Aggregate across all models
  "usageByModel": {               // Per-model breakdown (keyed by "provider/modelId")
    "anthropic/claude-sonnet-4-20250514": { "input": 12000, "output": 3200, "cost": 0.042, "calls": 8 },
    "anthropic/claude-haiku-3-5-20241022": { "input": 4500, "output": 800, "cost": 0.003, "calls": 3 }
  },
  "turnIndex": 5                  // Current turn in the inner loop
}
```

This tracks which models were used and how much each contributed to cost — essential when an agent selects different models per turn (e.g., cheap model for simple tool orchestration, expensive model for complex reasoning). Checkpoint size remains small (a few KB at most, regardless of conversation length).

**Checkpoint timing** — after each LLM turn (after all tool results are collected and persisted as entries):

```
LLM call → persist assistant entry → tool 1 → persist tool result entry → ... → CHECKPOINT → next LLM call
```

If the agent crashes during tool 2:
- All entries persisted before the crash are safe in the database
- Recovery loads checkpoint → gets leaf entry ID (pointing to last fully completed turn)
- Agent resumes from last checkpoint, re-executes the current LLM turn
- Lost work: at most one LLM turn (typically seconds)

This is acceptable because:
- LLM calls are non-deterministic anyway — replaying them doesn't reproduce results
- Individual entries are persisted immediately (the tree is always consistent)
- Only the checkpoint reference (which turn we're in) may be stale

Additional checkpoint points:
- **Before yielding for user input** (mandatory — ensures execution position is saved before suspension)
- **After receiving user input** (user entry is persisted to tree, checkpoint updated)

## Data Model

### Domain Entities

#### AgentDefinition

A predefined, reusable agent configuration. Optional — agents can be created anonymously with inline config.

```rust
pub struct AgentDefinition {
    pub id: Uuid,
    pub org_id: Uuid,
    pub name: String,
    pub slug: String,
    pub description: Option<String>,
    pub system_prompt: String,
    pub models: Vec<AgentModelConfig>,  // First is primary; agent can select others per turn
    pub tools: Vec<String>,             // ["read-file", "write-file", "bash", ...]
    pub config: AgentConfig,            // { max_turns, max_tokens, temperature, thinking }
    pub metadata: Option<serde_json::Value>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}
```

#### AgentExecution

A running or completed agent instance. Analogous to WorkflowExecution.

```rust
pub struct AgentExecution {
    pub id: Uuid,
    pub org_id: Uuid,
    pub agent_definition_id: Option<Uuid>,  // None for anonymous agents
    pub kind: String,                        // Agent type (e.g., "react-agent")
    pub persistence_mode: PersistenceMode,   // Durable (default) or Ephemeral
    pub status: AgentStatus,                 // Pending, Running, Waiting, Completed, Failed, Cancelled, Cancelling
    pub input: Option<Vec<u8>>,              // Serialized AgentInput
    pub output: Option<Vec<u8>>,             // Serialized agent result
    pub error: Option<String>,
    pub queue: String,
    pub current_checkpoint_seq: i32,         // Latest checkpoint sequence
    pub worker_id: Option<Uuid>,
    pub traceparent: Option<String>,
    pub metadata: Option<serde_json::Value>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub started_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
    pub version: i32,                        // Optimistic concurrency
}

pub enum PersistenceMode {
    Remote, // Entries + checkpoints in server DB, recoverable from any worker (default)
    Local,       // Entries stored on worker (in-memory, file, SQLite, etc.); signals + streaming still via server
}

pub enum AgentStatus {
    Pending,      // Queued, waiting for worker
    Running,      // Agent worker is executing
    Waiting,      // Suspended (waiting for signal, task, or timer)
    Completed,    // Successfully finished
    Failed,       // Execution error
    Cancelled,    // User cancelled
    Cancelling,   // Cancellation in progress
}
```

#### AgentEntry

A single conversation entry in the tree. Each message (user, assistant, tool result) is stored as an individual entry. Entries form a tree via `parent_id`, enabling future branching. For MVP, the tree is a linear chain.

```rust
pub struct AgentEntry {
    pub id: Uuid,
    pub agent_execution_id: Uuid,
    pub parent_id: Option<Uuid>,           // NULL = root entry; FK → agent_entry.id
    pub entry_type: String,                // "message" | "llm_call" | "injection"
    pub role: Option<String>,              // "system" | "user" | "assistant" | "tool_result"
    pub content: Vec<u8>,                  // Serialized message content (JSON)
    pub turn_id: Option<String>,           // Groups assistant + tool_use + tool_result in one LLM turn
    pub metadata: Option<serde_json::Value>, // Varies by type (e.g., LLM call metadata: model, tokens, cost)
    pub created_at: DateTime<Utc>,
}
```

Entry types:
- **`message`**: A conversation message (user prompt, assistant response, tool result). Has `role` and `content`.
- **`llm_call`**: Metadata-only record of an LLM API call. Not shown in conversation but tracked for observability and cost attribution. Persisted on `turn_end`. Metadata schema:
  ```json
  {
    "model": { "provider": "anthropic", "modelId": "claude-sonnet-4-20250514" },
    "usage": { "input": 1200, "output": 450, "cacheRead": 800, "totalTokens": 2450 },
    "cost": { "input": 0.0036, "output": 0.00225, "total": 0.00585 },
    "latencyMs": 2340,
    "stopReason": "tool_use"
  }
  ```
  This per-call record enables aggregation by model (which models were used, how much each cost) and supports multi-model executions where the agent selects different models per turn.
- **`injection`**: Operator-inserted context (future). Editable and deletable, unlike regular messages.

Future entry types (data model supports, implementation deferred):
- **`branch_summary`**: Summary of an abandoned conversation path after branching
- **`compaction`**: Summary replacing older entries to fit context window
- **`agent_spawn`** / **`agent_result`**: Sub-agent delegation markers

#### AgentCheckpoint

A lightweight execution position reference. Only the latest is needed for recovery; older ones retained for debugging/branching (future).

```rust
pub struct AgentCheckpoint {
    pub id: Uuid,
    pub agent_execution_id: Uuid,
    pub sequence: i32,                    // Monotonically increasing
    pub leaf_entry_id: Option<Uuid>,      // Position in the conversation tree (FK → agent_entry.id)
    pub state: Vec<u8>,                   // Minimal execution state (usage, turn index — NOT messages)
    pub metadata: Option<serde_json::Value>, // { checkpoint_reason, entry_count }
    pub created_at: DateTime<Utc>,
}
```

Checkpoint state (lightweight — messages are in the entry tree, not here):
```json
{
  "totalUsage": { "inputTokens": 15000, "outputTokens": 3200, "cost": 0.045 },
  "usageByModel": {
    "anthropic/claude-sonnet-4-20250514": { "input": 12000, "output": 3000, "cost": 0.042, "calls": 5 },
    "anthropic/claude-haiku-3-5-20241022": { "input": 3000, "output": 200, "cost": 0.003, "calls": 2 }
  },
  "turnIndex": 5
}
```

Context resolution on recovery:
1. Load checkpoint → get `leaf_entry_id`
2. Walk `parent_id` chain from leaf to root → collect entries
3. Reverse to chronological order → filter to `message` type entries
4. Build `Vec<Message>` for the agent's conversation context

### Database Schema

```sql
-- Predefined agent configurations
CREATE TABLE agent_definition (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id          UUID NOT NULL REFERENCES organization(id),
    name            TEXT NOT NULL,
    slug            TEXT NOT NULL,
    description     TEXT,
    system_prompt   TEXT NOT NULL,
    models          JSONB NOT NULL,         -- [{ provider, modelId, apiKeyEnv? }, ...] first is primary
    tools           JSONB NOT NULL DEFAULT '[]',
    config          JSONB NOT NULL DEFAULT '{}',
    metadata        JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (org_id, slug)
);

-- Agent execution instances
CREATE TABLE agent_execution (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id                  UUID NOT NULL REFERENCES organization(id),
    agent_definition_id     UUID REFERENCES agent_definition(id),
    kind                    TEXT NOT NULL,
    persistence_mode        TEXT NOT NULL DEFAULT 'REMOTE',  -- 'REMOTE' or 'LOCAL'
    status                  TEXT NOT NULL DEFAULT 'PENDING',
    input                   BYTEA,
    output                  BYTEA,
    error                   TEXT,
    queue                   TEXT NOT NULL DEFAULT 'default',
    current_checkpoint_seq  INTEGER NOT NULL DEFAULT 0,
    worker_id               UUID,
    traceparent             TEXT,
    metadata                JSONB,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at              TIMESTAMPTZ,
    completed_at            TIMESTAMPTZ,
    version                 INTEGER NOT NULL DEFAULT 1
);

-- Indexes for dispatch and querying
CREATE INDEX idx_agent_execution_org ON agent_execution(org_id);
CREATE INDEX idx_agent_execution_dispatch ON agent_execution(org_id, queue, status, created_at)
    WHERE status = 'PENDING';
CREATE INDEX idx_agent_execution_definition ON agent_execution(agent_definition_id)
    WHERE agent_definition_id IS NOT NULL;
CREATE INDEX idx_agent_execution_metadata ON agent_execution USING gin(metadata);

-- Conversation entries (tree structure)
CREATE TABLE agent_entry (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_execution_id      UUID NOT NULL REFERENCES agent_execution(id) ON DELETE CASCADE,
    parent_id               UUID REFERENCES agent_entry(id),   -- NULL = root entry
    entry_type              TEXT NOT NULL,                      -- 'message', 'llm_call', 'injection'
    role                    TEXT,                               -- 'system', 'user', 'assistant', 'tool_result'
    content                 BYTEA NOT NULL,                     -- Serialized message content
    turn_id                 TEXT,                               -- Groups entries in one LLM turn
    metadata                JSONB,                              -- Varies by type
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_agent_entry_execution ON agent_entry(agent_execution_id);
CREATE INDEX idx_agent_entry_parent ON agent_entry(parent_id) WHERE parent_id IS NOT NULL;
CREATE INDEX idx_agent_entry_turn ON agent_entry(agent_execution_id, turn_id) WHERE turn_id IS NOT NULL;

-- State snapshots for recovery (lightweight — references entry tree position)
CREATE TABLE agent_checkpoint (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_execution_id      UUID NOT NULL REFERENCES agent_execution(id) ON DELETE CASCADE,
    sequence                INTEGER NOT NULL,
    leaf_entry_id           UUID REFERENCES agent_entry(id),    -- Position in the conversation tree
    state                   BYTEA NOT NULL,                     -- Minimal execution state (usage, turn index)
    metadata                JSONB,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (agent_execution_id, sequence)
);

-- Signal queue for agent executions (naming aligned with workflow signals)
CREATE TABLE agent_signal (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_execution_id      UUID NOT NULL REFERENCES agent_execution(id) ON DELETE CASCADE,
    signal_name             TEXT NOT NULL,
    signal_value            BYTEA,
    consumed                BOOLEAN NOT NULL DEFAULT false,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_agent_signal_pending ON agent_signal(agent_execution_id, signal_name, consumed)
    WHERE consumed = false;
```

### Task Execution Link

Tasks spawned by an agent are linked via a dedicated `agent_execution_id` column on `task_execution`, following the same pattern as the existing `workflow_execution_id`:

```sql
ALTER TABLE task_execution
    ADD COLUMN agent_execution_id UUID REFERENCES agent_execution(id) ON DELETE CASCADE;

CREATE INDEX idx_task_execution_agent ON task_execution(agent_execution_id)
    WHERE agent_execution_id IS NOT NULL;

-- Constraint: a task belongs to at most one parent (workflow OR agent, not both)
ALTER TABLE task_execution
    ADD CONSTRAINT task_single_parent
    CHECK (NOT (workflow_execution_id IS NOT NULL AND agent_execution_id IS NOT NULL));
```

The Rust domain struct gains the corresponding field:

```rust
pub struct TaskExecution {
    // ... existing fields ...
    pub workflow_execution_id: Option<Uuid>,
    pub agent_execution_id: Option<Uuid>,   // NEW — same pattern as workflow_execution_id
    // ...
}
```

This provides:
- **First-class querying**: `SELECT * FROM task_execution WHERE agent_execution_id = $1` — indexed, no JSON parsing
- **Referential integrity**: FK constraint ensures agent_execution_id points to a valid execution; CASCADE on delete
- **Consistency**: Same pattern as `workflow_execution_id` — no special cases in query logic
- **Idempotency**: Task idempotency key uses `agent_execution_id:checkpoint_seq:tool_call_index`

### Large Task Inputs and the 4MB gRPC Limit

The `llm-request` task input includes the full messages array, which grows with conversation length. In the current workflow model, task inputs flow through the `ScheduleTask` gRPC command, which is part of the `SubmitWorkflowCommands` batch — all subject to the 4MB limit.

For agents, task scheduling uses `ScheduleAgentTask` with **client-side streaming**, so the input is chunked and has no size limit. However, there's a second bottleneck: the task worker receives the input via `PollTask`, which is currently unary.

**Mitigation options** (to be decided during implementation planning):

1. **Stream task input on PollTask**: Add server-side streaming variant of `PollTask` for large inputs. Most task inputs are small; only `llm-request` with long conversations is large.

2. **Store input by reference**: `ScheduleAgentTask` stores the input in a staging table (or blob column); `PollTask` returns a reference; the task worker fetches the input via a streaming `GetTaskInput` RPC. This decouples input storage from task dispatch.

3. **Keep messages in entries, pass references**: The `llm-request` task input could reference entry IDs instead of containing the full messages. The task worker resolves entries from the server. This requires the task worker to have entry-resolution capability — adds coupling but eliminates the large-input problem entirely.

## API Design

### gRPC API: Agent Dispatch Service

New gRPC service alongside `WorkflowDispatch` and `TaskExecution`.

**Design principle: stream chunks to overcome the 4MB gRPC message limit.** The current workflow model hit this limit because `GetEvents` returned all events in a single response. For agents, any RPC that carries conversation data or task inputs/outputs must use gRPC streaming to send data in small chunks rather than single large messages.

```protobuf
service AgentDispatch {
    // Worker polling (unary — response is lightweight: execution metadata + checkpoint reference)
    rpc PollAgent(PollAgentRequest) returns (PollAgentResponse);

    // Entry tree loading (SERVER-SIDE STREAMING — entries sent one by one)
    // The agent worker calls this on resume to reconstruct conversation state.
    // Each entry is a small message (~KB). Even a 500-entry conversation streams
    // safely within individual message limits.
    rpc GetEntries(GetEntriesRequest) returns (stream AgentEntryChunk);

    // Entry persistence (unary — single entry at a time, always small)
    rpc AppendEntry(AppendEntryRequest) returns (AppendEntryResponse);

    // Checkpoint management (unary — checkpoints are lightweight with tree model)
    rpc GetLatestCheckpoint(GetCheckpointRequest) returns (GetCheckpointResponse);
    rpc SubmitCheckpoint(SubmitCheckpointRequest) returns (SubmitCheckpointResponse);

    // Task dispatch (CLIENT-SIDE STREAMING — task input sent in chunks)
    // LLM request inputs contain the full messages array which can be large.
    // The agent worker streams the input in chunks; server reassembles before
    // creating the TaskExecution.
    rpc ScheduleAgentTask(stream ScheduleAgentTaskChunk) returns (ScheduleAgentTaskResponse);

    // Agent completion (unary — output is typically small)
    rpc CompleteAgent(CompleteAgentRequest) returns (CompleteAgentResponse);
    rpc FailAgent(FailAgentRequest) returns (FailAgentResponse);

    // Real-time streaming (CLIENT-SIDE STREAMING — tokens, tool output, structured events)
    rpc StreamAgentData(stream StreamAgentDataRequest) returns (StreamAgentDataResponse);

    // Signals (unary — payloads are small user messages)
    // Field naming: signal_name + signal_value (aligned with workflow SignalWorkflowRequest)
    rpc SignalAgent(SignalAgentRequest) returns (SignalAgentResponse);
    rpc ConsumeSignals(ConsumeSignalsRequest) returns (ConsumeSignalsResponse);
    rpc HasSignal(HasSignalRequest) returns (HasSignalResponse);

    // Suspend/resume (unary — metadata only)
    rpc SuspendAgent(SuspendAgentRequest) returns (SuspendAgentResponse);
}
```

#### Streaming Protocol for Large Payloads

For RPCs that use streaming to handle large data, messages are split into chunks:

```protobuf
// Chunked task input (for ScheduleAgentTask)
message ScheduleAgentTaskChunk {
    oneof chunk {
        ScheduleAgentTaskHeader header;    // First message: task kind, options, idempotency key
        bytes input_chunk;                  // Subsequent messages: input data chunks (~64KB each)
    }
}

// Entry stream (for GetEntries)
message AgentEntryChunk {
    AgentEntry entry;                      // One entry per message (entries are individually small)
}
```

**Chunk size**: 64KB per chunk (well under the 4MB limit, efficient for network transfer). A 4MB tool output becomes ~64 chunks — fully transparent to the SDK consumer.

#### Key RPCs

- **PollAgent** (unary): Long-polls for agent work. Returns lightweight metadata: execution ID, status, checkpoint reference, trigger data (task result reference or signal payload). No large data — the agent worker calls `GetEntries` separately to load conversation state.

- **GetEntries** (server-side streaming): Streams conversation entries one by one from the entry tree. Each entry is a small message (~KB). Called by the agent worker on resume to reconstruct the messages array. Can filter by `after_entry_id` to load only new entries since last checkpoint.

- **AppendEntry** (unary): Persists a single conversation entry. Always small (one message at a time). Returns entry ID. Server advances the conversation tree.

- **ScheduleAgentTask** (client-side streaming): Creates a TaskExecution linked to the agent. The task input (e.g., full messages array for LLM request) is streamed in chunks. Server reassembles the input, creates the task, and returns the task ID. Agent then suspends (WAITING for task).

- **StreamAgentData** (client-side streaming): Sends real-time data (tokens, terminal output, structured events) to the server for SSE forwarding. Each chunk is small (token deltas, structured JSON events).

- **SuspendAgent** (unary): Agent suspends with a wait condition (waiting for signal). Server transitions to WAITING. When the condition is met, server transitions to PENDING.

### REST API

New routes under `/api/orgs/{org_slug}/`:

```
# Agent Definitions (CRUD)
POST   /agent-definitions                    # Create definition
GET    /agent-definitions                    # List definitions
GET    /agent-definitions/{id}               # Get definition
PUT    /agent-definitions/{id}               # Update definition
DELETE /agent-definitions/{id}               # Delete definition

# Agent Executions
POST   /agent-executions                     # Start agent (from definition or inline)
GET    /agent-executions                     # List/query (FQL)
GET    /agent-executions/{id}                # Get execution details
DELETE /agent-executions/{id}                # Cancel execution

# Agent Interaction
POST   /agent-executions/{id}/signal         # Send signal (user message)

# Agent Streaming
GET    /agent-executions/{id}/stream         # SSE stream (agent events only)
GET    /agent-executions/{id}/stream/consolidated  # SSE stream (agent + tasks)

# Agent Internals (debugging/observability)
GET    /agent-executions/{id}/checkpoints    # List checkpoints
GET    /agent-executions/{id}/checkpoints/{seq}  # Get specific checkpoint
GET    /agent-executions/{id}/tasks          # List tasks spawned by agent
```

**Start agent execution**:

```json
// From definition
POST /agent-executions
{
  "agentDefinitionId": "...",
  "userPrompt": "Analyze the top 10 trending GitHub repos...",
  "config": { "maxTurns": 30 }  // Optional overrides
}

// Inline (anonymous agent)
POST /agent-executions
{
  "kind": "react-agent",
  "systemPrompt": "You are a helpful coding assistant...",
  "userPrompt": "Implement a REST API for...",
  "models": [
    { "provider": "anthropic", "modelId": "claude-sonnet-4-20250514" },
    { "provider": "anthropic", "modelId": "claude-haiku-3-5-20241022" }
  ],
  "tools": ["read-file", "write-file", "edit-file", "bash", "grep", "find"],
  "config": { "maxTurns": 25, "maxTokens": 16384, "temperature": 0.7 }
}
```

**Send signal** (same field names as workflow signal endpoint):
```json
POST /agent-executions/{id}/signal
{
  "signalName": "userMessage",
  "signalValue": { "text": "Add a comparison table to the report" }
}
```

### SSE Consolidated Stream

The consolidated stream merges agent-level events with task-level streaming, following the same pattern as the existing workflow consolidated stream:

```
event: agent.started
data: {"agentExecutionId":"...","status":"RUNNING"}

event: token
data: {"agentExecutionId":"...","taskExecutionId":"...","data":"Hello"}

event: data
data: {"agentExecutionId":"...","data":{"type":"tool_call_start","tool_call":{...}}}

event: data
data: {"agentExecutionId":"...","data":{"type":"terminal","stream":"stdout","data":"..."}}

event: task.completed
data: {"taskExecutionId":"...","kind":"bash"}

event: data
data: {"agentExecutionId":"...","data":{"type":"tool_call_end","tool_call":{...},"result":{...}}}

event: agent.checkpoint
data: {"agentExecutionId":"...","sequence":3}

event: agent.waiting
data: {"agentExecutionId":"...","status":"WAITING","reason":"signal"}

event: agent.resumed
data: {"agentExecutionId":"...","status":"RUNNING"}

event: agent.completed
data: {"agentExecutionId":"...","status":"COMPLETED"}
```

The frontend adapter processes these events identically to the current workflow-based approach — the SSE contract is largely the same, just with different source entity types.

## SDK Design

### New Traits in `worker-sdk`

#### AgentDefinition

```rust
/// Defines an agent type. Analogous to WorkflowDefinition.
#[async_trait]
pub trait AgentDefinition: Send + Sync {
    type Input: Serialize + DeserializeOwned + JsonSchema + Send;
    type Output: Serialize + DeserializeOwned + JsonSchema + Send;

    /// Unique type identifier (e.g., "react-agent")
    fn kind(&self) -> &str;

    /// Human-readable name
    fn name(&self) -> &str { self.kind() }

    /// Execute the agent logic
    async fn execute(&self, ctx: &dyn AgentContext, input: Self::Input) -> Result<Self::Output>;

    /// Whether the agent supports cancellation
    fn cancellable(&self) -> bool { true }

    fn description(&self) -> Option<&str> { None }
    fn timeout_seconds(&self) -> Option<u32> { None }
    fn tags(&self) -> Vec<String> { vec![] }
}
```

#### AgentContext

```rust
/// Runtime context for agent execution. Not deterministic — no replay guarantees.
#[async_trait]
pub trait AgentContext: Send + Sync {
    // === Identity ===
    fn agent_execution_id(&self) -> Uuid;
    fn org_id(&self) -> Uuid;

    // === Conversation Entries (tree-based persistence) ===
    /// Append a message entry to the conversation tree. Persisted immediately.
    /// Returns the entry ID. The entry becomes the new leaf.
    async fn append_entry(&self, role: &str, content: &Value) -> Result<Uuid>;

    /// Load messages from the entry tree (walk leaf → root → reverse).
    /// Called on startup/recovery to reconstruct the conversation.
    fn load_messages(&self) -> Vec<Value>;

    // === Checkpointing ===
    /// Persist a lightweight checkpoint (position in tree + execution metadata).
    /// The runtime stores leaf_entry_id automatically.
    async fn checkpoint(&self, state: &Value) -> Result<i32>; // Returns checkpoint sequence

    /// Access the execution state from the latest checkpoint.
    fn state(&self) -> &Value;

    // === Task Scheduling ===
    /// Schedule a task and wait for its result.
    /// The agent suspends while the task executes.
    /// On crash recovery, re-submits with idempotency key.
    async fn schedule_task(&self, kind: &str, input: Value) -> Result<Value>;

    /// Schedule a task with options (timeout, retries, queue).
    async fn schedule_task_with_options(
        &self,
        kind: &str,
        input: Value,
        options: TaskOptions,
    ) -> Result<Value>;

    // === Signals ===
    /// Block until a signal with the given name arrives.
    /// Checkpoints before suspending. Resumes with signal payload.
    async fn wait_for_signal(&self, signal_name: &str) -> Result<Value>;

    /// Check if a signal is already buffered (non-blocking).
    fn has_signal(&self, signal_name: &str) -> bool;

    /// Drain all buffered signals with the given name.
    fn drain_signals(&self, signal_name: &str) -> Vec<Value>;

    // === Streaming (ephemeral, forwarded to SSE) ===
    fn stream_token(&self, text: &str) -> Result<()>;
    fn stream_data(&self, data: Value) -> Result<()>;
    fn stream_error(&self, message: &str) -> Result<()>;

    // === Cancellation ===
    fn is_cancellation_requested(&self) -> bool;
    async fn check_cancellation(&self) -> Result<()>;
}
```

**Key differences from WorkflowContext**:

| Capability | WorkflowContext | AgentContext |
|-----------|----------------|--------------|
| State recovery | Event replay | Checkpoint load |
| Task scheduling | Command → event → replay | Direct dispatch → suspend/resume |
| State persistence | `set_raw()` per key → STATE_SET event | `checkpoint()` → full snapshot |
| Deterministic time/random | Yes (for replay correctness) | No (not needed) |
| Signal handling | Durable via events | Durable via `agent_signal` table |

### FlovynClient Integration

```rust
let client = FlovynClient::builder()
    .server_url("http://localhost:9090")
    .org_id(org_id)
    .worker_token(token)
    .queue("default")
    // Register agent definitions (new)
    .register_agent(ReactAgent)
    // Register task definitions (same as before)
    .register_task(LlmRequestTask)
    .register_task(BashTask)
    .register_task(ReadFileTask)
    // ...
    .build()
    .await?;

client.start().await?;
```

The client builder creates an `AgentExecutorWorker` (new) alongside the existing `WorkflowExecutorWorker` and `TaskExecutorWorker`. All three poll independently.

### Agent Worker: AgentExecutorWorker

New worker type that polls for agent executions:

```
AgentExecutorWorker loop:
  1. PollAgent(queue) → agent_execution
  2. If first run:
       state = initial_state_from(input)
     Else (resume):
       state = GetLatestCheckpoint(agent_id).state
       trigger = resume_trigger (task_result | signal_payload)
  3. Create AgentContextImpl(state, trigger, ...)
  4. Call agent.execute(ctx, input)
  5. Handle result:
       - Ok(output) → CompleteAgent(agent_id, output)
       - Err(suspend) → already suspended via ctx methods
       - Err(cancel) → already handled
       - Err(error) → FailAgent(agent_id, error)
```

## Agent Worker Changes

The existing `agent-worker` crate migrates from `WorkflowDefinition` to `AgentDefinition`:

### Before (current)

```rust
impl WorkflowDefinition for AgentWorkflow {
    async fn execute(&self, ctx: &dyn WorkflowContext, input: AgentWorkflowInput) -> Result<Value> {
        let mut messages = vec![Message::user_text(&input.user_prompt)];
        loop {
            for _ in 0..max_turns {
                // Single model — no per-turn model selection
                let result = ctx.schedule_raw("llm-request", llm_input).await?;  // Event-sourced
                // ...
                ctx.set_raw("messages", to_value(&messages)).await?;  // STATE_SET event per call
            }
            ctx.wait_for_signal_raw("userMessage").await?;  // Replay-based suspend
        }
    }
}
```

### After (new)

```rust
impl AgentDefinition for AgentWorkflow {
    async fn execute(&self, ctx: &dyn AgentContext, input: AgentWorkflowInput) -> Result<Value> {
        // Load messages from entry tree (walk leaf → root → reverse)
        let mut messages: Vec<Message> = ctx.load_messages();
        let mut usage_tracker: UsageTracker = UsageTracker::from_state(ctx.state());

        // Available models from input (first is primary, rest are alternatives)
        let models = &input.models;
        let primary_model = &models[0];

        // If first run, persist initial user message as entry
        if messages.is_empty() {
            let entry_id = ctx.append_entry("user", &input.user_prompt).await?;
            messages.push(Message::user_text(&input.user_prompt));
        }

        loop {
            ctx.check_cancellation().await?;

            // Drain pending steering messages
            for signal in ctx.drain_signals("userMessage") {
                if let Some(text) = signal.get("text").and_then(|v| v.as_str()) {
                    ctx.append_entry("user", text).await?;  // Persist immediately
                    messages.push(Message::user_text(text));
                }
            }

            // Inner loop: LLM + tools
            for _ in 0..max_turns {
                // Select model for this turn — agent can use a cheaper model for
                // simple tool orchestration and a more capable model for reasoning
                let model = self.select_model(&messages, &models);

                // LLM call (task, for streaming) — model is part of the task input
                let llm_input = json!({
                    "messages": &messages,
                    "model": model,
                    "maxTokens": input.config.max_tokens,
                });
                let result = ctx.schedule_task("llm-request", llm_input).await?;

                // Track usage per model
                usage_tracker.record_call(&model, &result.usage);

                // Persist assistant message as entry immediately
                ctx.append_entry("assistant", &result).await?;
                messages.push(Message::assistant(result));
                // Execute tools
                let tool_calls = extract_tool_calls(&result);
                if tool_calls.is_empty() { break; }

                for (id, name, args) in &tool_calls {
                    if ctx.has_signal("userMessage") { break; }

                    ctx.stream_data(json!({ "type": "tool_call_start", ... }))?;
                    let tool_result = ctx.schedule_task(name, args.clone()).await?;
                    ctx.stream_data(json!({ "type": "tool_call_end", ... }))?;

                    // Persist tool result as entry immediately
                    ctx.append_entry("tool_result", &tool_result).await?;
                    messages.push(Message::tool_result(id, name, &tool_result));
                }

                // Lightweight checkpoint — position + per-model usage breakdown
                ctx.checkpoint(&usage_tracker.to_state()).await?;
            }

            // Wait for next user message (yields with checkpoint)
            let signal = ctx.wait_for_signal("userMessage").await?;
            ctx.append_entry("user", &signal["text"]).await?;
            messages.push(Message::user_text(&signal["text"]));
        }
    }
}
```

**Key changes**:
- `ctx.schedule_raw()` → `ctx.schedule_task()` — same semantics, different recovery mechanism
- `ctx.set_raw("messages", ...)` (full array on every call) → `ctx.append_entry()` (single entry, persisted immediately)
- `ctx.checkpoint(...)` saves only position + per-model usage, not the full messages array
- `ctx.wait_for_signal_raw()` → `ctx.wait_for_signal()` — checkpoint-based suspend instead of replay-based
- Messages loaded from entry tree on startup (`ctx.load_messages()`), not deserialized from checkpoint blob
- Each message persisted individually — crash-safe without frequent full checkpoints
- **Observability via entry tree**: `llm_call` entries record model, tokens, cost, latency per call — no separate audit stream needed
- **Multi-model support**: Agent selects model per turn from available models list; `UsageTracker` accumulates usage per model (`"provider/modelId"` key); `llm_call` entries record which model was used; checkpoint state contains `usageByModel` breakdown

## Frontend Changes

### API Migration

| Current (workflow-based) | New (agent-based) |
|-------------------------|-------------------|
| `POST /workflow-executions { kind: "agent" }` | `POST /agent-executions { ... }` |
| `GET /workflow-executions?kind=agent` | `GET /agent-executions` |
| `GET /workflow-executions/{id}` | `GET /agent-executions/{id}` |
| `GET /workflow-executions/{id}/stream/consolidated` | `GET /agent-executions/{id}/stream/consolidated` |
| `POST /workflow-executions/{id}/signal` | `POST /agent-executions/{id}/signal` |
| `DELETE /workflow-executions/{id}` | `DELETE /agent-executions/{id}` |
| `GET /workflow-executions/{id}/state?key=messages` | `GET /agent-executions/{id}/checkpoints/latest` |

### Chat Adapter

The `flovyn-chat-adapter.ts` updates to use agent execution endpoints. The SSE event format is nearly identical — the adapter parses the same `token`, `data`, `lifecycle` events.

Key change for page reload: instead of fetching `state?key=messages`, fetch the latest checkpoint and deserialize messages from its state.

### Pages

| Page | Data Source |
|------|------------|
| `/ai/runs` | `GET /agent-executions` — list all agent runs |
| `/ai/runs/new` | `POST /agent-executions` — create new run |
| `/ai/runs/[runId]` | `GET /agent-executions/{id}` + SSE stream + latest checkpoint for messages |
| `/ai/agents` | `GET /agent-definitions` — list predefined agents |
| `/ai/agents/new` | `POST /agent-definitions` — create agent definition |
| `/ai/agents/[agentId]` | `GET /agent-definitions/{id}` — view/edit agent |

### Status Mapping

The agent status enum maps to UI states identically to workflows:

| `agent.status` | UI rendering | Input enabled |
|----------------|-------------|---------------|
| `PENDING` | Spinner: "Starting..." | No |
| `RUNNING` | Spinner + streaming content | No |
| `WAITING` | Idle, ready for input | Yes |
| `COMPLETED` | Final message shown | No |
| `FAILED` | Error banner | No |
| `CANCELLED` | "Cancelled" banner | No |

## Migration from Current Model

### Phase 1: Server infrastructure

Add the new database tables, domain model, gRPC service, and REST endpoints for agent executions. This is additive — no changes to existing workflow infrastructure.

### Phase 2: SDK support

Add `AgentDefinition` trait, `AgentContext`, and `AgentExecutorWorker` to `worker-sdk`. Register agent capabilities in `FlovynClient::builder()`. Again additive — workflow support unchanged.

### Phase 3: Agent worker migration

Migrate `agent-worker` from `WorkflowDefinition` to `AgentDefinition`. The conversation loop, LLM integration, and tool implementations remain largely unchanged — only the context API changes.

### Phase 4: Frontend migration

Update `flovyn-chat-adapter.ts` and the AI pages to use agent execution endpoints instead of workflow execution endpoints. The SSE streaming contract is nearly identical.

### Rollback

Each phase is independently reversible. The old workflow-based agent continues to work alongside the new agent infrastructure until we're confident in the migration.

## Key Architecture Decisions

### Decision 1: Agent as a separate primitive (not a workflow variant)

**Chosen**: Agent is a distinct entity with its own tables, gRPC service, and SDK traits.

**Alternative considered**: Keep agents as workflows but add checkpoint support to the workflow model.

**Rationale**: The execution semantics are fundamentally different (non-deterministic vs. deterministic, checkpoint vs. replay). Mixing them in one model would compromise both. Separate primitives allow each to evolve independently while sharing infrastructure (tasks, streaming, signals).

### Decision 2: Suspend/resume per task (not keep-alive)

**Chosen**: Agent suspends when scheduling a task, resumes when the task completes.

**Alternative considered**: Agent worker stays alive and blocks on task completion.

**Rationale**: Suspend/resume is more scalable (agent workers don't hold resources during long tasks) and consistent with the existing workflow pattern. The per-task overhead (~10-20ms with NATS notifications) is acceptable. Checkpoint-based resume (O(1)) eliminates the replay cost that made this slow for workflows.

### Decision 3: Dedicated `agent_execution_id` column on `task_execution`

**Chosen**: Add `agent_execution_id UUID` column to `task_execution`, mirroring the existing `workflow_execution_id` column.

**Alternative considered**: Store `agent_execution_id` in the task's existing `metadata` JSONB column to avoid schema changes.

**Rationale**: The `workflow_execution_id` column already establishes the pattern — agent tasks should follow the same pattern rather than taking a shortcut. A proper FK column gives indexed lookups, referential integrity with CASCADE, and consistent query logic across workflow and agent tasks. A CHECK constraint (`task_single_parent`) ensures a task belongs to at most one parent.

### Decision 4: Checkpoint after each LLM turn (not per tool)

**Chosen**: Checkpoint once after all tools in a turn complete.

**Alternative considered**: Checkpoint after every tool call.

**Rationale**: Checkpointing per tool adds overhead (database write + gRPC call per tool). The cost of replaying one LLM turn on crash (non-deterministic anyway) is acceptable. This can be made configurable later.

### Decision 5: Tree-structured entries (not flat messages array in checkpoints)

**Chosen**: Each message is an individual entry in a tree (linked via `parent_id`). Checkpoints reference a leaf position. Messages reconstructed by walking the tree.

**Alternative considered**: Store the full `messages: Vec<Message>` array as a blob in each checkpoint (the simpler approach).

**Rationale**: The tree model is proven across 4 implementation phases in a previous project. It provides: (1) immediate per-message persistence (crash-safe without frequent checkpoints), (2) constant-size checkpoints (just a leaf reference), (3) natural support for branching, variants, compaction, and sub-agents without schema changes. The flat array approach would require re-designing the data model when adding these features later. The tree model costs slightly more complexity upfront but pays off in every future phase.

### Decision 6: gRPC streaming for large payloads (not raising the message limit)

**Chosen**: Use gRPC streaming (server-side and client-side) to send large data in small chunks (~64KB each).

**Alternative considered**: Raise the gRPC max message size from 4MB to a larger value (e.g., 64MB).

**Rationale**: Raising the limit is a band-aid — any fixed limit will eventually be hit by sufficiently long agent sessions. Streaming has no upper bound and is how gRPC is designed to handle large data. It also enables incremental processing on the receiver side (e.g., the agent worker can start building the messages array as entries stream in, rather than waiting for a single large response). The chunking is transparent to SDK consumers — the `AgentContext` methods handle reassembly internally.

### Decision 7: Naming — "Agent Execution" (not "Run" or "Session")

**Chosen**: `AgentExecution` as the domain entity name, displayed as "Run" in the UI.

**Rationale**: Aligns with `WorkflowExecution` naming, establishing a consistent pattern for execution entities across primitives. "Run" is used in the UI for user-friendliness. "Session" implies interactivity that doesn't apply to all agent types (e.g., one-shot tasks).

## Future Phases (Enabled by Tree Data Model)

The tree-based entry model is designed to support these future capabilities without schema changes. Each phase builds on the previous one, following the proven implementation path from the [tree ideas](~/shared/ideas/tree/).

### Phase 2: Variants + Cost Controls

Per-turn model selection and per-model cost tracking are part of MVP (see `usageByModel` in checkpoint state and `llm_call` entry metadata). This phase extends that foundation:

- **Variants table**: Multiple named views of the same conversation tree, each pointing to a different leaf
- **Per-entry exclusions**: Toggle individual entries in/out of LLM context per variant
- **Model override per variant**: Force a specific model for all turns in a variant (overriding the agent's per-turn selection)
- **Budget enforcement**: Per-variant and per-execution cost caps, with automatic model downgrade when budget threshold is reached
- **Auto-fork**: Modifying past context (excluding an entry before the last LLM call) auto-creates a new variant

### Phase 3: Branching + Compaction

- **Branching**: Move a variant's leaf backward to any entry, creating an alternative path. New messages become siblings of the old path. Optional AI summary of the abandoned path (`branch_summary` entry type)
- **Context compaction**: When conversation exceeds model context window, automatically summarize older entries into a `compaction` entry. Iterative — subsequent compactions update the existing summary rather than creating summaries-of-summaries
- **Tree view**: Full conversation tree visualization showing all branches, active path, variant positions

### Phase 4: Sub-Agents

- **Agent spawning**: Create child agent executions from a parent, with selected context entries copied
- **Independent trees**: Each child gets its own entry tree (Mode A — simplest, proven)
- **Result injection**: When child completes, its result is auto-injected into parent's tree as an `agent_result` entry
- **Hierarchy tracking**: Parent-child relationships enable cost rollup and navigation across agent trees

## Resolved Questions

### Entry content size limits

**Resolved**: Entries always contain exactly what the LLM sees — no size cap needed. The agent logic controls what goes into entries (e.g., truncating large tool outputs before calling `append_entry()`). Entries are self-contained conversation context.

### Agent-task resume mechanism

**Resolved**: Reuse the existing polling + NATS notification pattern from workflows. No new mechanism needed.

### Proto file organization

**Resolved**: Separate `agent.proto` file. The current `flovyn.proto` is already ~700 lines. Agent is a distinct primitive with its own gRPC service — keeping it in a separate file is cleaner. Same build step, just a second input file.

### FQL support for agent executions

**Resolved**: Not for MVP. FQL is a query convenience, not a blocker. Add when there's demand.

### Unified execution view

**Resolved**: Not for MVP. Design the agent API clean first. Unification across workflows/agents/tasks is a future concern.

### Agent definition versioning

**Resolved**: Configuration is frozen at execution creation time (input contains full config). This is the right default — running executions are unaffected by definition changes. Versioning is a future concern.

### Entry tree resolution performance

**Resolved**: Load all entries for the execution in one query (`SELECT * FROM agent_entry WHERE agent_execution_id = $1 ORDER BY created_at`), walk in-memory using `parent_id` chain. Same approach that worked in the previous project. With an index on `agent_execution_id`, this is a single indexed scan. No denormalization needed.

## Open Questions

### ~~1. Shared streaming infrastructure~~ (Resolved)

**Resolved**: Generalize the existing `StreamSubscriber` and SSE infrastructure to support `agent_execution_id` alongside `workflow_execution_id` and `task_execution_id`. No parallel streaming path — reuse the same infrastructure.

### ~~2. Idempotency for in-flight tasks on recovery~~ (Resolved)

**Resolved**: No special "attach" mechanism needed. `ScheduleAgentTask` with an idempotency key is idempotent — it returns the existing task regardless of state. The suspend/resume flow handles the rest:

| Task state | Server behavior |
|-----------|----------------|
| **Not found** | Create new task, agent suspends — normal flow |
| **Completed** | Return existing task ID + result immediately — no suspend needed |
| **Still running** | Return existing task ID — agent suspends waiting for it, same as normal flow |

The agent doesn't know or care whether the task was freshly created or already in-flight.

### ~~3. Entry content format~~ (Resolved)

**Resolved**: Entries store a **Flovyn-native format** — provider-agnostic message types that get converted to provider-specific formats just before sending to the LLM API. This follows the same pattern as [pi-mono](~/workspaces/flovyn/competitors/pi-mono/packages/ai/src/types.ts):

**Flovyn message content types** (stored in `agent_entry.content`):

| Content type | Fields | Notes |
|-------------|--------|-------|
| `text` | `text`, `textSignature?` | Plain text content |
| `thinking` | `thinking`, `thinkingSignature?` | Model reasoning (opaque signature preserves provider context) |
| `image` | `data` (base64), `mimeType` | Inline images |
| `toolCall` | `id`, `name`, `arguments` | Tool invocation |

**Assistant entries** additionally store: `provider`, `model`, `usage`, `stopReason` — so the converter knows which provider generated the content (important for signature handling and thinking block fidelity).

**Conversion happens in the agent worker**, just before building the `llm-request` task input:
1. Load entries from tree → Flovyn `Message[]`
2. Transform messages (normalize tool IDs, handle thinking blocks across providers)
3. Convert to provider-specific format (Anthropic `MessageParam[]`, OpenAI `ChatCompletionMessageParam[]`, etc.)
4. Send as task input

This decouples storage from any single provider and makes multi-model executions clean — an agent can switch from Anthropic to OpenAI mid-conversation, and the converter handles the format differences (tool ID formats, thinking block representation, tool result grouping).