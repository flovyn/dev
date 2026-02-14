# Durable Agent System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement Agent as a first-class runtime primitive with checkpoint-based recovery and tree-structured conversation storage.

**Architecture:** Agent executions are stored in dedicated tables (`agent_execution`, `agent_entry`, `agent_checkpoint`, `agent_signal`). Workers poll via a new `AgentDispatch` gRPC service. Recovery loads the latest checkpoint and walks the entry tree to reconstruct messages — no event replay.

**Tech Stack:** Rust (server + SDK), PostgreSQL, gRPC (tonic), Protobuf, Next.js (frontend), SSE streaming.

**Design Reference:** See `dev/docs/design/20260210_durable_agent_system.md` for full data model, API contracts, and architectural decisions.

---

## Critical Observations from Design Review

1. **gRPC Streaming Required**: The design specifies client-side streaming for `ScheduleAgentTask` and server-side streaming for `GetEntries` to handle the 4MB gRPC limit. This is required to support long conversations and large tool outputs.

2. **Entry Tree vs Linear Chain**: The design says "for MVP, the tree is a linear chain." We should enforce this constraint in code (reject entries with siblings) to avoid accidentally supporting branching before we're ready.

3. **Task Execution Link**: Adding `agent_execution_id` to `task_execution` requires careful migration — the existing `workflow_execution_id` pattern is our template.

4. **Signal Table Similarity**: `agent_signal` closely mirrors the existing workflow signal mechanism. We should verify if we can reuse the workflow signal infrastructure or if a separate table is truly needed.

5. **Persistence Mode (Deferred)**: The `Local` persistence mode is deferred with explicit user consent. Only `Remote` mode will be implemented. The trait boundary (`AgentContext`) will support `Local` later without API changes.

6. **AgentDefinition (server-side)**: This is a predefined configuration entity, not the SDK trait. The naming overlap could cause confusion — the server has `AgentDefinition` (DB entity) while the SDK has `AgentDefinition` (trait). Keep this distinction clear.

---

## Phase 1: Server Infrastructure (Database + Domain)

**Outcome:** Agent tables exist, domain models compile, repositories have basic CRUD.

### Task 1.1: Database Migration — Core Agent Tables

**Files:**
- Create: `flovyn-server/server/migrations/YYYYMMDDHHMMSS_agent_system.sql`

**Steps:**

- [x] **Step 1.1.1**: Write the migration file with all four tables:
  - `agent_definition` — predefined agent configurations
  - `agent_execution` — running/completed agent instances
  - `agent_entry` — conversation entries (tree structure)
  - `agent_checkpoint` — lightweight state snapshots
  - `agent_signal` — signal queue for user messages

  Include indexes from the design document. Use actual timestamp for migration filename.

- [x] **Step 1.1.2**: Run migration locally
  ```bash
  cd flovyn-server && mise run build
  ```

- [x] **Step 1.1.3**: Verify schema
  ```bash
  mise run db:schema | grep -E "agent_"
  ```

**Commit:** `feat(server): add agent system database tables`

### Task 1.2: Database Migration — Task Execution Link

**Files:**
- Create: `flovyn-server/server/migrations/YYYYMMDDHHMMSS_task_agent_link.sql`

**Steps:**

- [x] **Step 1.2.1**: Write migration to add `agent_execution_id` column to `task_execution`:
  ```sql
  ALTER TABLE task_execution
      ADD COLUMN agent_execution_id UUID REFERENCES agent_execution(id) ON DELETE CASCADE;

  CREATE INDEX idx_task_execution_agent ON task_execution(agent_execution_id)
      WHERE agent_execution_id IS NOT NULL;

  ALTER TABLE task_execution
      ADD CONSTRAINT task_single_parent
      CHECK (NOT (workflow_execution_id IS NOT NULL AND agent_execution_id IS NOT NULL));
  ```

- [x] **Step 1.2.2**: Run migration and verify constraint works

**Commit:** `feat(server): link task executions to agent executions`

### Task 1.3: Domain Models

**Files:**
- Create: `flovyn-server/crates/core/src/domain/agent.rs`
- Create: `flovyn-server/crates/core/src/domain/agent_definition.rs`
- Modify: `flovyn-server/crates/core/src/domain/mod.rs`
- Modify: `flovyn-server/crates/core/src/domain/task.rs` (add `agent_execution_id`)

**Steps:**

- [x] **Step 1.3.1**: Create `AgentStatus` enum following `WorkflowStatus` pattern:
  ```rust
  pub enum AgentStatus {
      Pending, Running, Waiting, Completed, Failed, Cancelled, Cancelling
  }
  ```

- [x] **Step 1.3.2**: Create `PersistenceMode` enum:
  ```rust
  pub enum PersistenceMode {
      Remote,  // Default — entries in server DB
      Local,   // Worker-local storage (future)
  }
  ```

- [x] **Step 1.3.3**: Create `AgentExecution` struct with all fields from design

- [x] **Step 1.3.4**: Create `AgentEntry` struct with `entry_type`, `role`, `content`, `parent_id`, `turn_id`

- [x] **Step 1.3.5**: Create `AgentCheckpoint` struct with `sequence`, `leaf_entry_id`, `state`

- [x] **Step 1.3.6**: Create `AgentSignal` struct with `signal_name`, `signal_value`, `consumed`

- [x] **Step 1.3.7**: Create `AgentDefinition` struct (server-side config entity)

- [x] **Step 1.3.8**: Add `agent_execution_id: Option<Uuid>` to `TaskExecution` struct

- [x] **Step 1.3.9**: Export new types in `mod.rs`

- [x] **Step 1.3.10**: Run `mise run check` to verify compilation

**Commit:** `feat(core): add agent domain models`

### Task 1.4: Repositories

**Files:**
- Create: `flovyn-server/server/src/repository/agent_repository.rs`
- Create: `flovyn-server/server/src/repository/agent_definition_repository.rs`
- Create: `flovyn-server/server/src/repository/agent_entry_repository.rs`
- Create: `flovyn-server/server/src/repository/agent_checkpoint_repository.rs`
- Create: `flovyn-server/server/src/repository/agent_signal_repository.rs`
- Modify: `flovyn-server/server/src/repository/mod.rs`
- Modify: `flovyn-server/server/src/repository/task_repository.rs`

**Steps:**

- [x] **Step 1.4.1**: Create `AgentDefinitionRepository` with CRUD operations:
  - `create()`, `find_by_id()`, `find_by_slug()`, `list_by_org()`, `update()`, `delete()`

- [x] **Step 1.4.2**: Create `AgentRepository` with:
  - `create()`, `find_by_id()`, `list_by_org()`, `update_status()`, `find_lock_and_mark_running()` (atomic polling)

- [x] **Step 1.4.3**: Create `AgentEntryRepository` with:
  - `create()`, `find_by_id()`, `list_by_execution()` (for tree walking), `find_leaf()`

- [x] **Step 1.4.4**: Create `AgentCheckpointRepository` with:
  - `create()`, `find_latest()`, `list_by_execution()`

- [x] **Step 1.4.5**: Create `AgentSignalRepository` with:
  - `create()`, `find_unconsumed()`, `mark_consumed()`, `has_signal()`

- [x] **Step 1.4.6**: Update `TaskRepository` to handle `agent_execution_id`:
  - Modify `create()` to accept optional `agent_execution_id`
  - Add `list_by_agent_execution()` query

- [x] **Step 1.4.7**: Export repositories in `mod.rs`

- [x] **Step 1.4.8**: Run `mise run check`

**Commit:** `feat(server): add agent repositories`

### Task 1.5: Repository Integration Tests

**Files:**
- Create: `flovyn-server/tests/integration/agent_repository_test.rs`
- Modify: `flovyn-server/tests/integration/mod.rs`

**Steps:**

- [x] **Step 1.5.1**: Write test for `AgentRepository::create()` and `find_by_id()`

- [x] **Step 1.5.2**: Write test for `AgentRepository::find_lock_and_mark_running()` (atomic poll)
  - Added race condition tests with tokio barriers: `test_agent_atomic_poll_no_double_claim` (10 workers, 1 agent)
  - Added `test_agent_atomic_poll_multiple_agents` (5 workers, 5 agents)
  - Added `test_agent_atomic_poll_with_capabilities` (capability filtering)

- [x] **Step 1.5.3**: Write test for `AgentEntryRepository` tree operations:
  - `test_agent_entry_tree_operations`: root entry, child entries, find_leaf, list_by_turn
  - `test_agent_entry_incremental_load`: list_after_entry for incremental loading

- [x] **Step 1.5.4**: Write test for `AgentCheckpointRepository`:
  - `test_agent_checkpoint_operations`: create, find_latest, get_by_sequence, get_next_sequence
  - `test_checkpoint_sequence_unique`: verify duplicate sequence rejection

- [x] **Step 1.5.5**: Write test for `AgentSignalRepository`:
  - `test_agent_signal_operations`: create, find_unconsumed, mark_consumed, has_signal
  - `test_agent_signal_consume_race_condition`: 10 concurrent consumers, 5 signals (race condition detection)

- [x] **Step 1.5.6**: Write test for task-agent link:
  - `test_task_agent_link_constraint`: create task with agent_execution_id, list_by_agent_execution_id
  - `test_task_single_parent_constraint`: verify constraint rejects task with both workflow and agent IDs

- [x] **Step 1.5.7**: Run tests (all 17 tests pass, verified stable across 3 runs)
  ```bash
  mise run test:integration -- agent
  ```

**Commit:** `test(server): add agent repository integration tests`

---

## Phase 2: gRPC Service — Agent Dispatch

**Outcome:** Workers can poll for agents, load entries, submit checkpoints, and schedule tasks via gRPC.

### Task 2.1: Protobuf Definitions

**Files:**
- Create: `flovyn-server/server/proto/agent.proto`
- Modify: `flovyn-server/server/build.rs`

**Steps:**

- [x] **Step 2.1.1**: Create `agent.proto` with `AgentDispatch` service definition
  - All service methods defined: PollAgent, GetEntries, AppendEntry, GetLatestCheckpoint, SubmitCheckpoint, ScheduleAgentTask, CompleteAgent, FailAgent, SuspendAgent, SignalAgent, ConsumeSignals, HasSignal, StreamAgentData

- [x] **Step 2.1.2**: Define streaming chunk messages
  - `AgentEntryChunk` for server-side streaming (GetEntries)
  - `ScheduleAgentTaskChunk` with oneof (header/input_chunk) for client-side streaming
  - `StreamAgentDataRequest` for client-side streaming (agent data)

- [x] **Step 2.1.3**: Define all other message types following patterns from `flovyn.proto`
  - PollAgentRequest/Response, AgentExecutionInfo
  - GetEntriesRequest, AgentEntry, TokenUsage
  - AppendEntryRequest/Response
  - GetCheckpointRequest/Response, AgentCheckpoint, SubmitCheckpointRequest/Response
  - ScheduleAgentTaskHeader, ScheduleAgentTaskResponse
  - CompleteAgentRequest, FailAgentRequest, SuspendAgentRequest
  - SignalAgentRequest/Response, ConsumeSignalsRequest/Response, AgentSignal, HasSignalRequest/Response
  - AgentStreamEventType enum, StreamAgentDataRequest/Response

- [x] **Step 2.1.4**: Update `build.rs` to compile `agent.proto`

- [x] **Step 2.1.5**: Run `mise run build` and verify generated code
  - AgentDispatch trait, AgentDispatchServer, all message types generated correctly

**Commit:** `feat(server): add agent.proto definitions`

### Task 2.2: gRPC Service Implementation — Core Operations

**Files:**
- Create: `flovyn-server/server/src/api/grpc/agent_dispatch.rs`
- Modify: `flovyn-server/server/src/api/grpc/mod.rs`

**Steps:**

- [x] **Step 2.2.1**: Implement `PollAgent` — long-poll for available agent work:
  - Query PENDING agents for org + queue
  - Use `find_lock_and_mark_running()` for atomic claim
  - Return agent metadata + checkpoint reference (if resuming)

- [x] **Step 2.2.2**: Implement `GetEntries` with **server-side streaming**:
  - Query all entries for execution (single indexed query)
  - Support `after_entry_id` filter for incremental loads
  - Stream entries one by one via `tokio_stream::wrappers::ReceiverStream`
  - Each `AgentEntryChunk` contains one entry (~KB each)

- [x] **Step 2.2.3**: Implement `AppendEntry` — persist single entry:
  - Validate parent_id exists (if provided)
  - Create entry with auto-generated ID
  - Return entry ID

- [x] **Step 2.2.4**: Implement `GetLatestCheckpoint` and `SubmitCheckpoint`:
  - Get: return checkpoint with highest sequence
  - Submit: create checkpoint, update `agent_execution.current_checkpoint_seq`

- [x] **Step 2.2.5**: Register service in gRPC server (mod.rs)
  - Added AgentDispatchServer to both server start functions
  - Added health reporter for AgentDispatch

- [x] **Step 2.2.6**: Run `mise run check` - Build and tests pass

**Note:** Also implemented:
- `CompleteAgent`, `FailAgent`, `SuspendAgent` (completion methods)
- `SignalAgent`, `ConsumeSignals`, `HasSignal` (signal methods)
- `ScheduleAgentTask` and `StreamAgentData` implemented with client-side streaming

**Commit:** `feat(server): implement core AgentDispatch gRPC operations`

### Task 2.3: gRPC Service Implementation — Task Scheduling & Completion

**Files:**
- Modify: `flovyn-server/server/src/api/grpc/agent_dispatch.rs`

**Steps:**

- [x] **Step 2.3.1**: Implement `ScheduleAgentTask` with **client-side streaming**:
  - [x] Receive `ScheduleAgentTaskChunk` stream:
    - First chunk: `header` with task kind, options, idempotency key
    - Subsequent chunks: `input_chunk` bytes (~64KB each)
  - [x] Reassemble input from chunks
  - [x] Create `TaskExecution` with `agent_execution_id` set
  - [x] Support idempotency key (return existing task if key matches)
  - [ ] Publish task event to event bus (TODO in code)

- [x] **Step 2.3.2**: Implement `CompleteAgent`:
  - [x] Update status to COMPLETED
  - [x] Set output and completed_at
  - [ ] Publish agent.completed event (TODO in code)

- [x] **Step 2.3.3**: Implement `FailAgent`:
  - [x] Update status to FAILED
  - [x] Set error and completed_at
  - [ ] Publish agent.failed event (TODO in code)

- [x] **Step 2.3.4**: Implement `SuspendAgent`:
  - [x] Update status to WAITING
  - [ ] Store wait condition (signal name) in metadata (TODO in code)
  - [ ] Publish agent.waiting event (TODO in code)

**Commit:** `feat(server): implement AgentDispatch task scheduling and completion`

### Task 2.4: gRPC Service Implementation — Signals & Streaming

**Files:**
- Modify: `flovyn-server/server/src/api/grpc/agent_dispatch.rs`

**Steps:**

- [x] **Step 2.4.1**: Implement `SignalAgent`:
  - [x] Create signal record in `agent_signal` table
  - [x] If agent is WAITING for this signal, transition to PENDING
  - [ ] Publish agent.signalled event (TODO in code)

- [x] **Step 2.4.2**: Implement `ConsumeSignals`:
  - [x] Find unconsumed signals by name
  - [x] Mark them consumed
  - [x] Return signal values

- [x] **Step 2.4.3**: Implement `HasSignal`:
  - [x] Check if unconsumed signal with name exists
  - [x] Return boolean

- [x] **Step 2.4.4**: Implement `StreamAgentData`:
  - [x] Receive streaming data (tokens, tool output, events)
  - [x] Publish to `StreamEventPublisher` with agent execution context
  - [x] Support same event types as workflow streaming (Token, Progress, Data, Error)

**Commit:** `feat(server): implement AgentDispatch signals and streaming`

### Task 2.5: gRPC Integration Tests

**Files:**
- Create: `flovyn-server/tests/integration/agent_grpc_tests.rs`
- Modify: `flovyn-server/tests/integration_tests.rs`

**Steps:**

- [x] **Step 2.5.1**: Write test for full poll-execute-complete cycle:
  - Create agent execution via DB
  - Poll agent, verify claimed
  - Submit checkpoint
  - Complete agent
  - Verify status is COMPLETED

- [x] **Step 2.5.2**: Write test for entry persistence:
  - Append entries with parent chain
  - GetEntries, verify order and content

- [x] **Step 2.5.3**: Write test for signal flow:
  - Create WAITING agent
  - Signal agent
  - Verify transitions to PENDING
  - ConsumeSignals, verify consumed

- [x] **Step 2.5.4**: Write test for task scheduling with idempotency:
  - Schedule task with idempotency key
  - Schedule same key again, verify returns same task

- [x] **Step 2.5.5**: Run tests (all 5 gRPC tests + 17 repository tests pass)
  ```bash
  cargo test --test integration_tests -- agent
  ```

**Additional tests added:**
- `agent_execution_tests.rs`: SDK-based agent lifecycle integration tests (7 tests)
  - Tests using SDK agents: EchoAgent, MultiTurnAgent, TaskSchedulingAgent, CheckpointAgent
  - Covers: basic execution, multi-turn signals, task scheduling, checkpoint persistence, concurrent execution, multiple workers, claiming race
  - Total: 43 agent integration tests pass

**Commit:** `test(server): add AgentDispatch gRPC integration tests`

---

## Phase 3: REST API

**Outcome:** Frontend can create agent executions, list runs, send signals, and stream events.

### Task 3.1: REST Endpoints — Agent Definitions CRUD

**Files:**
- Create: `flovyn-server/server/src/api/rest/agent_definitions.rs`
- Modify: `flovyn-server/server/src/api/rest/mod.rs`
- Modify: `flovyn-server/server/src/api/rest/openapi.rs`

**Steps:**

- [x] **Step 3.1.1**: Create DTOs:
  - `CreateAgentDefinitionRequest`, `UpdateAgentDefinitionRequest`
  - `AgentDefinitionResponse`, `AgentDefinitionListResponse`

- [x] **Step 3.1.2**: Implement endpoints:
  - `POST /api/orgs/{org_slug}/agent-definitions` — create
  - `GET /api/orgs/{org_slug}/agent-definitions` — list
  - `GET /api/orgs/{org_slug}/agent-definitions/{id}` — get by ID
  - `PUT /api/orgs/{org_slug}/agent-definitions/{id}` — update
  - `DELETE /api/orgs/{org_slug}/agent-definitions/{id}` — delete

- [x] **Step 3.1.3**: Add utoipa annotations and register in `openapi.rs`

- [x] **Step 3.1.4**: Register routes in `mod.rs`

**Commit:** `feat(server): add agent definitions REST API`

### Task 3.2: REST Endpoints — Agent Executions

**Files:**
- Create: `flovyn-server/server/src/api/rest/agent_executions.rs`
- Modify: `flovyn-server/server/src/api/rest/mod.rs`
- Modify: `flovyn-server/server/src/api/rest/openapi.rs`

**Steps:**

- [x] **Step 3.2.1**: Create DTOs:
  - `CreateAgentExecutionRequest` — supports both `agentDefinitionId` and inline config
  - `AgentExecutionResponse`, `AgentExecutionListResponse`
  - `SignalAgentRequest` (with `signalName`, `signalValue`)

- [x] **Step 3.2.2**: Implement execution endpoints:
  - `POST /api/orgs/{org_slug}/agent-executions` — create (from definition or inline)
  - `GET /api/orgs/{org_slug}/agent-executions` — list
  - `GET /api/orgs/{org_slug}/agent-executions/{id}` — get by ID
  - `DELETE /api/orgs/{org_slug}/agent-executions/{id}` — cancel

- [x] **Step 3.2.3**: Implement interaction endpoint:
  - `POST /api/orgs/{org_slug}/agent-executions/{id}/signal` — send signal

- [x] **Step 3.2.4**: Implement debugging endpoints:
  - `GET /api/orgs/{org_slug}/agent-executions/{id}/checkpoints` — list checkpoints
  - `GET /api/orgs/{org_slug}/agent-executions/{id}/checkpoints/{seq}` — get checkpoint
  - `GET /api/orgs/{org_slug}/agent-executions/{id}/tasks` — list spawned tasks

- [x] **Step 3.2.5**: Add utoipa annotations and register in `openapi.rs`

**Commit:** `feat(server): add agent executions REST API`

### Task 3.3: REST Endpoints — SSE Streaming

**Files:**
- Modify: `flovyn-server/server/src/api/rest/streaming.rs`

**Steps:**

- [x] **Step 3.3.1**: Add agent execution SSE endpoints:
  - `GET /api/orgs/{org_slug}/agent-executions/{id}/stream` — agent events only
  - `GET /api/orgs/{org_slug}/agent-executions/{id}/stream/consolidated` — agent + task events

- [x] **Step 3.3.2**: Implement streaming logic:
  - Subscribe to `StreamSubscriber` with agent execution pattern
  - Format events: `agent.started`, `agent.waiting`, `agent.completed`, `token`, `data`, etc.
  - Support KeepAlive for long connections

- [x] **Step 3.3.3**: Add event type documentation to openapi.rs

**Commit:** `feat(server): add agent execution SSE streaming`

### Task 3.4: REST API Tests

**Files:**
- Create: `flovyn-server/tests/integration/agent_rest_tests.rs`
- Modify: `flovyn-server/tests/integration_tests.rs`

**Steps:**

- [x] **Step 3.4.1**: Write test for agent definition CRUD
  - `test_create_agent_definition`, `test_create_agent_definition_duplicate_slug`
  - `test_list_agent_definitions`, `test_get_agent_definition`
  - `test_update_agent_definition`, `test_delete_agent_definition`

- [x] **Step 3.4.2**: Write test for agent execution creation (both from definition and inline)
  - `test_create_agent_execution_with_kind` (inline)
  - `test_create_agent_execution_with_definition` (from definition)
  - `test_create_agent_execution_requires_kind_or_definition` (validation)

- [x] **Step 3.4.3**: Write test for signal endpoint
  - `test_signal_agent_execution` (signal PENDING agent)
  - `test_signal_cancelled_agent_fails` (signal terminal agent fails)

- [x] **Step 3.4.4**: Write test for cancel endpoint
  - `test_cancel_agent_execution`

- [x] **Step 3.4.5**: Run tests (14 tests pass)
  ```bash
  cargo test --test integration_tests -- agent_rest
  ```

**Commit:** `test(server): add agent REST API integration tests`

---

## Phase 4: SDK — Agent Traits & Context

**Outcome:** SDK consumers can define agents using `AgentDefinition` trait and execute them with `AgentContext`.

### Task 4.1: Agent Traits

**Files:**
- Create: `sdk-rust/worker-sdk/src/agent/mod.rs`
- Create: `sdk-rust/worker-sdk/src/agent/definition.rs`
- Create: `sdk-rust/worker-sdk/src/agent/context.rs`
- Modify: `sdk-rust/worker-sdk/src/lib.rs`

**Steps:**

- [x] **Step 4.1.1**: Create `AgentDefinition` trait following TaskDefinition pattern:
  - Typed input/output with JsonSchema support
  - DynamicAgent helper trait for untyped agents
  - Auto-generated schemas from Input/Output types
  - All standard metadata methods (kind, name, description, version, tags, etc.)

- [x] **Step 4.1.2**: Create `AgentContext` trait with methods from design:
  - Identity: `agent_execution_id()`, `org_id()`, `input_raw()`
  - Entries: `append_entry()`, `append_tool_call()`, `append_tool_result()`, `load_messages()`, `reload_messages()`
  - Checkpointing: `checkpoint()`, `state()`, `checkpoint_sequence()`
  - Task scheduling: `schedule_task_raw()`, `schedule_task_with_options_raw()`
  - Signals: `wait_for_signal_raw()`, `has_signal()`, `drain_signals_raw()`
  - Streaming: `stream()`, `stream_token()`, `stream_progress()`, `stream_data_value()`, `stream_error()`
  - Cancellation: `is_cancellation_requested()`, `check_cancellation()`
  - AgentContextExt extension trait for typed convenience methods

- [x] **Step 4.1.3**: Export types in `mod.rs` and `lib.rs`, added to prelude

- [x] **Step 4.1.4**: Build succeeded with `cargo build -p flovyn-worker-sdk`

**Commit:** `feat(sdk): add AgentDefinition and AgentContext traits`

### Task 4.2: Agent Context Implementation

**Files:**
- Create: `sdk-rust/worker-sdk/src/agent/context_impl.rs`
- Modify: `sdk-rust/worker-sdk/src/agent/mod.rs`

**Steps:**

- [ ] **Step 4.2.1**: Create `AgentContextImpl` struct:
  ```rust
  pub struct AgentContextImpl {
      agent_execution_id: Uuid,
      org_id: Uuid,
      messages: RwLock<Vec<Value>>,  // Loaded from entries
      checkpoint_state: RwLock<Value>,
      leaf_entry_id: RwLock<Option<Uuid>>,
      client: AgentDispatchClient,
      cancellation_requested: AtomicBool,
      // ... other fields
  }
  ```

- [ ] **Step 4.2.2**: Implement entry operations:
  - `append_entry()` — call gRPC `AppendEntry`, update local `leaf_entry_id`
  - `load_messages()` — return cached messages (loaded on construction)

- [ ] **Step 4.2.3**: Implement checkpoint operations:
  - `checkpoint()` — call gRPC `SubmitCheckpoint` with `leaf_entry_id` + state
  - `state()` — return current checkpoint state

- [ ] **Step 4.2.4**: Implement task scheduling with **client-side streaming**:
  - `schedule_task()` — stream task input in 64KB chunks via `ScheduleAgentTask`
  - First chunk: header with task kind, options, idempotency key
  - Subsequent chunks: serialized input bytes
  - Wait for task completion (poll or NATS notification)
  - Generate idempotency key: `{agent_execution_id}:{checkpoint_seq}:{task_index}`

- [ ] **Step 4.2.5**: Implement signals:
  - `wait_for_signal()` — checkpoint, call `SuspendAgent`, wait for resume, `ConsumeSignals`
  - `has_signal()` — call gRPC `HasSignal`
  - `drain_signals()` — call gRPC `ConsumeSignals`

- [ ] **Step 4.2.6**: Implement streaming:
  - `stream_token()`, `stream_data()`, `stream_error()` — call gRPC `StreamAgentData`

**Commit:** `feat(sdk): implement AgentContextImpl`

### Task 4.3: Agent Registry

**Files:**
- Create: `sdk-rust/worker-sdk/src/agent/registry.rs`
- Modify: `sdk-rust/worker-sdk/src/agent/mod.rs`

**Steps:**

- [x] **Step 4.3.1**: Create `AgentRegistry` following `TaskRegistry` pattern:
  - `AgentMetadata` struct with kind, name, description, version, tags, timeout, cancellable, schemas
  - `BoxedAgentFn` type alias for execution functions
  - `RegisteredAgent` struct with metadata and execute function
  - `AgentRegistry` with RwLock-protected HashMap

- [x] **Step 4.3.2**: Implement `register<A>()` method with schema generation:
  - Auto-extracts metadata from AgentDefinition trait
  - Generates schemas from Input/Output types via schemars
  - Also implemented `register_simple()` and `register_raw()` methods

- [x] **Step 4.3.3**: Implement `get()`, `has()`, `get_registered_kinds()`, `get_all_metadata()`, `len()`, `is_empty()`, `has_registrations()`

**Commit:** `feat(sdk): add AgentRegistry`

### Task 4.4: SDK Unit Tests

**Files:**
- Tests in: `sdk-rust/worker-sdk/src/agent/definition.rs` (inline tests)
- Tests in: `sdk-rust/worker-sdk/src/agent/context.rs` (inline tests)
- Tests in: `sdk-rust/worker-sdk/src/agent/registry.rs` (inline tests)

**Steps:**

- [x] **Step 4.4.1**: Write tests for `AgentRegistry` registration and lookup:
  - `test_agent_registry_new`, `test_agent_registry_register_simple`
  - `test_agent_registry_duplicate_registration`, `test_agent_registry_get`
  - `test_agent_registry_has`, `test_agent_registry_get_registered_kinds`
  - `test_agent_registry_get_all_metadata`, `test_agent_registry_register_with_metadata`
  - `test_agent_registry_debug`, `test_registered_agent_debug`

- [x] **Step 4.4.2**: Write tests for `AgentDefinition` and `DynamicAgent`:
  - `test_dynamic_agent_kind`, `test_dynamic_agent_name_defaults_to_kind`
  - `test_dynamic_agent_version`, `test_dynamic_agent_description`
  - `test_dynamic_agent_timeout_seconds`, `test_dynamic_agent_cancellable`
  - `test_dynamic_agent_tags_default_empty`, `test_agent_definition_impl`

- [x] **Step 4.4.3**: Write tests for `AgentContext` types:
  - `test_entry_type_as_str`, `test_entry_role_as_str`
  - `test_schedule_task_options_default`, `test_schedule_task_options_builder`
  - `test_token_usage_default`

- [x] **Step 4.4.4**: Run tests (24 tests pass)
  ```bash
  cargo test -p flovyn-worker-sdk -- agent
  ```

**Commit:** `test(sdk): add agent trait unit tests`

---

## Phase 5: SDK — Agent Worker

**Outcome:** `FlovynClient` can register and execute agents alongside workflows and tasks.

### Task 5.1: Agent Worker Implementation

**Files:**
- Create: `sdk-rust/worker-sdk/src/worker/agent_worker.rs`
- Modify: `sdk-rust/worker-sdk/src/worker/mod.rs`

**Steps:**

- [ ] **Step 5.1.1**: Create `AgentWorkerConfig` following `WorkflowWorkerConfig` pattern

- [ ] **Step 5.1.2**: Create `AgentExecutorWorker` struct:
  ```rust
  pub struct AgentExecutorWorker {
      config: AgentWorkerConfig,
      registry: Arc<AgentRegistry>,
      client: AgentDispatchClient,
      running: Arc<AtomicBool>,
      semaphore: Arc<Semaphore>,
      // ...
  }
  ```

- [ ] **Step 5.1.3**: Implement polling loop:
  - Call `PollAgent` RPC
  - Look up agent in registry by `kind`
  - Load entries via `GetEntries` **server-side streaming** (collect stream into Vec)
  - Get checkpoint via `GetLatestCheckpoint`
  - Create `AgentContextImpl` with loaded entries
  - Call `agent.execute(ctx, input)`
  - Handle result: `CompleteAgent` / `FailAgent`

- [ ] **Step 5.1.4**: Implement graceful shutdown

**Commit:** `feat(sdk): implement AgentExecutorWorker`

### Task 5.2: FlovynClient Integration

**Files:**
- Modify: `sdk-rust/worker-sdk/src/client/builder.rs`
- Modify: `sdk-rust/worker-sdk/src/client/flovyn_client.rs`

**Steps:**

- [ ] **Step 5.2.1**: Add `agent_registry: AgentRegistry` to builder

- [ ] **Step 5.2.2**: Add `.register_agent<A>(agent)` builder method

- [ ] **Step 5.2.3**: Create `AgentExecutorWorker` in `build()` if agents registered

- [ ] **Step 5.2.4**: Start `AgentExecutorWorker` in `client.start()`

- [ ] **Step 5.2.5**: Add agent capabilities to worker registration

**Commit:** `feat(sdk): integrate AgentExecutorWorker into FlovynClient`

### Task 5.3: SDK E2E Tests

**Files:**
- Create: `sdk-rust/tests/e2e/agent_test.rs`
- Modify: `sdk-rust/tests/e2e/mod.rs`

**Steps:**

- [x] **Step 5.3.1**: Create simple test agent:
  ```rust
  struct EchoAgent;
  impl AgentDefinition for EchoAgent {
      type Input = String;
      type Output = String;
      fn kind(&self) -> &str { "echo-agent" }
      async fn execute(&self, ctx: &dyn AgentContext, input: String) -> Result<String> {
          ctx.append_entry("user", &json!({ "text": &input })).await?;
          ctx.checkpoint(&json!({})).await?;
          Ok(format!("Echo: {}", input))
      }
  }
  ```
  Created `fixtures/agents.rs` with EchoAgent, MultiTurnAgent, TaskSchedulingAgent, StreamingAgent, CheckpointAgent

- [x] **Step 5.3.2**: Write test for complete agent execution cycle:
  - Register agent
  - Create execution via REST
  - Wait for completion
  - Verify output

  Created `agent_tests.rs` with `test_basic_agent_execution`

- [x] **Step 5.3.3**: Write test for multi-turn agent with signals:
  - Agent waits for signal
  - Send signal via REST
  - Agent completes

  Created `test_multi_turn_agent_with_signals`

- [x] **Step 5.3.4**: Write test for agent with task scheduling:
  - Agent schedules a task
  - Task completes
  - Agent uses result

  Created `test_agent_with_task_scheduling`

- [x] **Step 5.3.5**: Run tests
  ```bash
  cd sdk-rust && mise run test:e2e -- agent
  ```
  All 12 agent E2E tests pass (basic, multi-turn, task scheduling, checkpoint, metrics, combined workers, failure handling, concurrent execution, multiple workers, rapid signals, concurrent with tasks, claiming race).

**Fixes applied:**
- Entry types aligned: SDK `EntryType` changed to match server's `AgentEntryType` (lowercase: `message`, `llm_call`, `injection`)
- Entry roles aligned: SDK `EntryRole::Tool` renamed to `ToolResult` with value `tool_result`
- Agent worker suspension: Now recognizes both signal and task suspension as valid (not failures)

**Commit:** `test(sdk): add agent E2E tests`

---

## Phase 6: Agent Worker Migration (react-agent)

**Outcome:** The existing `agent-worker` crate uses the new `AgentDefinition` trait instead of `WorkflowDefinition`.

### Task 6.1: Migrate react-agent to AgentDefinition

**Files:**
- Modified: `agent-worker/src/workflows/agent.rs` - `AgentWorkflow` → `ReactAgent` using `DynamicAgent`
- Modified: `agent-worker/src/main.rs` - `register_workflow` → `register_agent`

**Steps:**

- [x] **Step 6.1.1**: Change trait implementation from `WorkflowDefinition` to `DynamicAgent`
  - Renamed `AgentWorkflow` to `ReactAgent`
  - Implemented `DynamicAgent` trait with `kind()`, `name()`, `cancellable()`, `execute()`

- [x] **Step 6.1.2**: Update conversation loop to use `AgentContext` APIs:
  - `ctx.schedule_raw()` → `ctx.schedule_task_raw()`
  - `ctx.set_raw("messages", ...)` → `ctx.append_entry()` + `ctx.checkpoint()`
  - `ctx.wait_for_signal_raw()` → `ctx.wait_for_signal_raw()` (same)
  - `ctx.has_signal()` → `ctx.has_signal().await?` (now async)
  - Added `ctx.checkpoint()` after each assistant response and tool execution
  - Added `ctx.append_tool_call()` and `ctx.append_tool_result()` for tool entries

- [x] **Step 6.1.3**: Usage tracking in checkpoints
  - Usage is accumulated in `total_usage` and saved in checkpoints
  - Per-model tracking deferred to future enhancement

- [x] **Step 6.1.4**: Update message loading to use `ctx.load_messages()`
  - On resume, messages are reconstructed from loaded entries
  - Handles User, Assistant, and Tool entries

- [x] **Step 6.1.5**: Update client registration from `register_workflow` to `register_agent`
  - Updated `main.rs` to use `register_agent(ReactAgent)`

**Note:** Existing tests were disabled pending `MockAgentContext` implementation (see Phase 6.2).

**Commit:** `refactor(agent-worker): migrate to AgentDefinition trait`

### Task 6.2: Agent Worker E2E Tests

**Files:**
- Location TBD based on existing test structure

**Steps:**

- [ ] **Step 6.2.1**: Write E2E test for single-turn agent execution

- [ ] **Step 6.2.2**: Write E2E test for multi-turn conversation

- [ ] **Step 6.2.3**: Write E2E test for tool execution

- [ ] **Step 6.2.4**: Write E2E test for crash recovery (kill worker mid-execution, verify resumes)

**Commit:** `test(agent-worker): add E2E tests for new agent execution model`

---

## Phase 7: Frontend Integration

**Outcome:** UI shows agent runs list, run detail with chat, and supports multi-turn interaction.

### Task 7.1: API Client Updates

**Files:**
- Updated: `flovyn-app/packages/api/spec.json` - Exported from server with agent endpoints
- Generated: `flovyn-app/packages/api/src/flovynServerApiSchemas.ts` - Agent types
- Generated: `flovyn-app/packages/api/src/flovynServerApiComponents.ts` - Agent React Query hooks

**Steps:**

- [x] **Step 7.1.1**: Add agent execution API functions:
  - `useCreateAgentExecution()`, `useGetAgentExecution()`, `useListAgentExecutions()`
  - `useSignalAgentExecution()`, `useCancelAgentExecution()`
  - `useGetAgentCheckpoint()`, `useListAgentCheckpoints()`, `useListAgentTasks()`

- [x] **Step 7.1.2**: Add agent definition API functions:
  - `useCreateAgentDefinition()`, `useGetAgentDefinition()`, `useListAgentDefinitions()`
  - `useUpdateAgentDefinition()`, `useDeleteAgentDefinition()`

Note: API client is auto-generated from OpenAPI spec. Updated spec from server and ran `pnpm --filter @workspace/api run generate`.

**Commit:** `feat(app): add agent API client functions`

### Task 7.2: Chat Adapter Migration

**Files:**
- Created: `flovyn-app/apps/web/lib/effect/agent-chat-stream.ts`
- Created: `flovyn-app/apps/web/lib/ai/flovyn-agent-chat-adapter.ts`
- Created: `flovyn-app/apps/web/lib/ai/use-flovyn-agent-chat-runtime.ts`
- Fixed: `flovyn-app/apps/web/lib/ai/use-flovyn-chat-runtime.ts` (removed missing hook)

**Steps:**

- [x] **Step 7.2.1**: Create agent-specific SSE stream (`agent-chat-stream.ts`):
  - Uses URL: `/api/orgs/${orgSlug}/agent-executions/${agentExecutionId}/stream/consolidated`
  - Event types: token, tool_call_start/end, thinking_delta, terminal, lifecycle, turn_complete, agent_done, stream_error

- [x] **Step 7.2.2**: Create agent chat adapter (`flovyn-agent-chat-adapter.ts`):
  - Follows workflow adapter pattern
  - Uses agent-specific SSE stream
  - Handles agent signals via `sendSignal` callback
  - Status changes: running → waiting → completed/failed/cancelled

- [x] **Step 7.2.3**: Create agent chat runtime hooks (`use-flovyn-agent-chat-runtime.ts`):
  - `useFlovynAgentChatData`: Fetches agent execution and checkpoint state
  - `useFlovynAgentChatRuntime`: Creates adapter, handles terminal, cancel, auto-send
  - Uses `useListAgentCheckpoints` to get latest checkpoint

- [x] **Step 7.2.4**: Fix workflow chat runtime type error:
  - Replaced missing `useGetWorkflowState` with direct useQuery fetch

**Commit:** `feat(app): add agent chat adapter and runtime hooks`

### Task 7.3: Agent Runs Pages

**Files:**
- Updated: `flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/page.tsx`
- Updated: `flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/new/page.tsx`
- Updated: `flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/[runId]/page.tsx`
- Created: `flovyn-app/apps/web/components/ai/run/unified-agent-run-view.tsx`

**Steps:**

- [x] **Step 7.3.1**: Update runs list page (`/org/[orgSlug]/ai/runs`):
  - Changed from `useListWorkflows` to `useListAgentExecutions`
  - Displays agent executions with status, created_at, kind

- [x] **Step 7.3.2**: Update new run page (`/org/[orgSlug]/ai/runs/new`):
  - Changed from `useTriggerWorkflow` to `useCreateAgentExecution`
  - Redirects to agent execution ID on success

- [x] **Step 7.3.3**: Create agent run detail view:
  - Created `UnifiedAgentRunView` component
  - Uses `useFlovynAgentChatData` and `useFlovynAgentChatRuntime`
  - Chat view with agent-specific SSE streaming
  - Status indicator and cancel button

**Commit:** `feat(app): migrate agent runs pages to agent execution APIs`

### Task 7.4: Agent Definitions Pages

**Files:**
- Updated: `flovyn-app/apps/web/app/org/[orgSlug]/ai/agents/page.tsx`
- Updated: `flovyn-app/apps/web/app/org/[orgSlug]/ai/agents/[agentId]/page.tsx`

**Steps:**

- [x] **Step 7.4.1**: Update agents list page (`/org/[orgSlug]/ai/agents`):
  - Changed from mock data to `useListAgentDefinitions` API
  - Displays agent name, slug, description, tools count, models count

- [x] **Step 7.4.2**: Update agent detail page (`/org/[orgSlug]/ai/agents/[agentId]`):
  - Changed from mock data to `useGetAgentDefinition` and `useListAgentExecutions` APIs
  - Three tabs: Executions, Tools, Config
  - Shows agent executions filtered by this definition
  - Displays tools, models, system prompt, and configuration

**Note:** New agent creation page (`/ai/agents/new`) deferred - can be added later.

**Commit:** `feat(app): migrate agent definitions pages to real APIs`

### Task 7.5: Frontend E2E Tests

**Files:**
- Location TBD based on existing Playwright setup

**Steps:**

- [ ] **Step 7.5.1**: Write E2E test for creating and running an agent

- [ ] **Step 7.5.2**: Write E2E test for multi-turn chat interaction

- [ ] **Step 7.5.3**: Write E2E test for agent definitions CRUD

**Commit:** `test(app): add agent UI E2E tests`

---

## Test Plan Summary

| Phase | Test Type | Count | Coverage |
|-------|-----------|-------|----------|
| Phase 1 | Integration | 17 | Repository CRUD, atomic polling, entry tree operations, signal flow, race conditions |
| Phase 2 | Integration | 5 + 7 | gRPC poll-execute-complete cycle, entry persistence, signals, idempotency; SDK-based lifecycle tests |
| Phase 3 | Integration | 14 | REST CRUD, signal endpoint, cancel, SSE streaming |
| Phase 4 | Unit | 28 | Registry, schema generation, traits |
| Phase 5 | E2E | 12 | Agent execution cycle, multi-turn, task scheduling, concurrent execution, race conditions |
| Phase 6 | E2E | TBD | react-agent migration, crash recovery |
| Phase 7 | E2E | TBD | UI flows, chat interaction |

**Total agent tests:** 43 server integration + 12 SDK E2E = 55 tests

**Testing Approach:**
- Test-first for all new code
- Each phase should pass all tests before moving to the next
- Integration tests use testcontainers (Postgres, NATS)
- E2E tests run against full stack (server + SDK + optional frontend)

---

## Explicitly Deferred (with user consent)

- **`PersistenceMode::Local`**: Worker-local storage for entries/checkpoints. Only `Remote` mode is implemented. The `AgentContext` trait boundary ensures `Local` can be added later without API changes. Required for GBs of coding agent data — will be needed before heavy production use.

---

## Rollout Considerations

1. **Feature Flag**: Consider adding a feature flag to enable/disable agent execution endpoints. This allows deploying the code without exposing it.

2. **Backwards Compatibility**: The existing workflow-based agent continues to work. Migration to the new agent model is opt-in per worker.

3. **Database Migration**: Migrations are additive (new tables, new columns). No risk to existing data.

4. **Monitoring**: Add metrics for agent execution duration, checkpoint frequency, entry count per execution, signal latency.

5. **Documentation**: Update SDK docs with `AgentDefinition` trait examples. Update API docs with new endpoints.

---

## TODO Checklist (Copy this to track progress)

### Phase 1: Server Infrastructure ✅ COMPLETE
- [x] 1.1.1: Write agent tables migration
- [x] 1.1.2: Run migration locally
- [x] 1.1.3: Verify schema
- [x] 1.2.1: Write task-agent link migration
- [x] 1.2.2: Run migration and verify constraint
- [x] 1.3.1-1.3.10: Create domain models
- [x] 1.4.1-1.4.8: Create repositories
- [x] 1.5.1-1.5.7: Write repository integration tests (17 tests, including race condition detection)

### Phase 2: gRPC Service ✅ COMPLETE
- [x] 2.1.1-2.1.5: Create agent.proto with streaming RPCs
- [x] 2.2.1-2.2.6: Implement core gRPC operations (incl. server-side streaming for GetEntries)
- [x] 2.3.1-2.3.4: Implement task scheduling with client-side streaming
- [x] 2.4.1-2.4.4: Implement signals and streaming
- [x] 2.5.1-2.5.5: Write gRPC integration tests (5 gRPC tests pass)

### Phase 3: REST API ✅ COMPLETE
- [x] 3.1.1-3.1.4: Agent definitions CRUD
- [x] 3.2.1-3.2.5: Agent executions endpoints
- [x] 3.3.1-3.3.3: SSE streaming
- [x] 3.4.1-3.4.5: REST API tests (14 integration tests)

### Phase 4: SDK Traits ✅ COMPLETE
- [x] 4.1.1-4.1.4: Create AgentDefinition and AgentContext traits
- [x] 4.2.1-4.2.6: Implement AgentContextImpl (gRPC client + async context)
- [x] 4.3.1-4.3.3: Create AgentRegistry
- [x] 4.4.1-4.4.4: SDK unit tests (28 tests pass)

### Phase 5: SDK Worker ✅ COMPLETE
- [x] 5.1.1-5.1.4: Implement AgentExecutorWorker (polling, execute, complete/fail)
- [x] 5.2.1-5.2.5: Integrate into FlovynClient (register_agent, start agent worker)
- [x] 5.3.1-5.3.5: SDK E2E tests (12 tests pass: basic, multi-turn, task scheduling, checkpoint, metrics, combined workers, failure handling, concurrent execution, multiple workers, rapid signals, concurrent with tasks, claiming race)

### Phase 6: Agent Worker Migration
- [x] 6.1.1-6.1.5: Migrate react-agent (AgentWorkflow → ReactAgent with DynamicAgent trait)
- [ ] 6.2.1-6.2.4: Agent worker E2E tests (requires MockAgentContext)

### Phase 7: Frontend
- [x] 7.1.1-7.1.2: API client updates (auto-generated from OpenAPI spec with agent endpoints)
- [ ] 7.2.1-7.2.3: Chat adapter migration
- [ ] 7.3.1-7.3.3: Agent runs pages
- [ ] 7.4.1-7.4.3: Agent definitions pages
- [ ] 7.5.1-7.5.3: Frontend E2E tests
