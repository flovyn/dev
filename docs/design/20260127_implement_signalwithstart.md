# Design: SignalWithStart API

**Date**: 2026-01-27
**Status**: Draft
**GitHub Issue**: https://github.com/flovyn/dev/issues/10

---

## Related Research

This design focuses on the **SignalWithStart API**. For broader architectural questions, see:

- [Execution Patterns for Multi-Message Workflows](../research/20260128_execution_patterns_multi_message.md) - Entity/Handler vs Workflow+Signals vs Actor patterns
- [Durable AI Conversations and Context Management](../research/20260128_ai_conversation_durability.md) - LLM compaction, tool durability, recovery models

---

## Problem Statement

Currently, Flovyn cannot efficiently represent long-running conversations (like chatbot sessions) as workflows. The problem arises from two limitations:

1. **Start vs Signal Dilemma**: To send a message to a conversation, you need to either:
   - Start a new workflow (but this creates duplicates if one already exists)
   - Signal an existing workflow (but this fails if none exists yet)

2. **Race Condition with Idempotency Key**: Using idempotency keys helps with the first message, but creates a race condition for subsequent messages:
   ```
   Thread A: Start workflow with key="conv-123" → Creates workflow
   Thread B: Start workflow with key="conv-123" → Returns existing (good!)
   Thread B: Try to signal with message → Works
   Thread A: Try to signal with message → ??? (no guarantee of ordering)
   ```

3. **Two-Step Race**: Even if you check first, there's a window for failure:
   ```
   Thread A: Check if workflow exists? No → Start workflow
   Thread B: Check if workflow exists? No → Start workflow ← CONFLICT!
   ```

**Use Case: Chatbot Conversations**

A chatbot needs to:
1. Receive a user message for conversation ID "conv-123"
2. If no workflow exists for this conversation, start one
3. If a workflow already exists, send the message to it (signal)
4. The workflow processes messages sequentially

Without an atomic "start-or-signal" operation, this pattern is either racy or requires complex client-side coordination.

---

## Solution Overview

Implement a **SignalWithStart** API (similar to [Temporal's SignalWithStart](https://docs.temporal.io/sending-messages#sending-signals)) that atomically:

1. **Checks** if a workflow execution exists for a given workflow ID
2. **Creates** the workflow if it doesn't exist
3. **Signals** the workflow (whether newly created or already running)

All three steps happen in a single atomic transaction.

### Key Terminology

Flovyn currently uses "promises" for external input to workflows. After analyzing Temporal's signal model vs Restate's promise model, we've decided to adopt Temporal's terminology and semantics:

| Temporal Term | Flovyn (New) | Flovyn (Legacy) | Description |
|---------------|--------------|-----------------|-------------|
| Signal | Signal | Promise | External input to a workflow |
| SignalWithStart | SignalWithStart | — | Atomic start-or-signal operation |

**Key difference**: Signals support **queue semantics** (multiple signals with same name = multiple events), while promises are **one-shot** (only resolved once). Signals are required for the chatbot use case where multiple messages arrive over time.

**Naming Decision**: Adopt Temporal's `signal` terminology. Existing `promise` API will be deprecated in favor of signals.

---

## Competitor Analysis: SignalWithStart Implementations

### Temporal: SignalWithStart (Direct Inspiration)

Temporal provides a first-class `SignalWithStartWorkflow` API that atomically starts a workflow if needed and sends a signal.

**API Design:**
```python
# Python SDK - signal is an optional parameter on start_workflow
handle = await client.start_workflow(
    MyWorkflow.run,
    args=[input],
    id="conversation-123",
    task_queue="default",
    start_signal="new_message",        # Signal name
    start_signal_args=[message_data],  # Signal payload
)
```

**Key Characteristics:**
- Signal is passed as optional parameters (`start_signal`, `start_signal_args`) to `start_workflow`
- Uses a dedicated gRPC method: `SignalWithStartWorkflowExecution`
- Workflows receive signals via `@workflow.signal` decorated handlers
- Signals are fire-and-forget (no return value)

**Workflow-Side Signal Handler:**
```python
@workflow.defn
class ConversationWorkflow:
    def __init__(self):
        self.messages = []

    @workflow.signal
    async def new_message(self, message: Message):
        self.messages.append(message)

    @workflow.run
    async def run(self, input: Input):
        while True:
            await workflow.wait_condition(lambda: len(self.messages) > 0)
            msg = self.messages.pop(0)
            await self.process(msg)
```

### Restate: Durable Promises (Different Model)

Restate uses **durable promises** which are one-shot (can only be resolved once):

```python
@workflow.main()
async def pay(ctx: WorkflowContext, amount: int):
    # Wait for external approval - can only be resolved ONCE
    result = await ctx.promise("verify.payment").value()
    if result == "approved":
        return {"success": True}

@workflow.handler()
async def payment_verified(ctx: WorkflowSharedContext, result: str):
    await ctx.promise("verify.payment").resolve(result)
```

**Why this doesn't work for chatbots**: Promises are one-shot. For multiple messages, you'd need indexed names (`message-0`, `message-1`), which is complex and racy.

### Comparison: Signals vs Promises

| Aspect | Signals (Temporal) | Promises (Restate) |
|--------|-------------------|-------------------|
| **Same name, multiple values** | ✅ Each creates an event | ❌ Only first resolve counts |
| **Queue semantics** | ✅ Built-in via handler | ❌ Must build manually |
| **Caller complexity** | Low (just send signal) | High (track indices) |
| **Event storage** | One event per signal | One event per promise name |

---

## Deep Dive: Signal Event Model

### Temporal's Event Structure

Each signal creates a separate `WORKFLOW_EXECUTION_SIGNALED` event:

```json
{
  "eventId": "3",
  "eventType": "EVENT_TYPE_WORKFLOW_EXECUTION_SIGNALED",
  "workflowExecutionSignaledEventAttributes": {
    "signalName": "dosig",
    "input": { "payloads": [{"data": "\"message-1\""}] }
  }
},
{
  "eventId": "4",
  "eventType": "EVENT_TYPE_WORKFLOW_EXECUTION_SIGNALED",
  "workflowExecutionSignaledEventAttributes": {
    "signalName": "dosig",  // Same signal name!
    "input": { "payloads": [{"data": "\"message-2\""}] }
  }
}
```

Multiple signals with the same name = multiple events. This enables queue semantics.

### Flovyn's Signal Implementation

Introduce a new event type `SIGNAL_RECEIVED`:

```rust
pub enum WorkflowEventType {
    // ... existing types ...
    SignalReceived {
        signal_name: String,
        signal_value: Vec<u8>,
    },
}
```

**Workflow SDK API:**
```rust
impl WorkflowContext {
    /// Wait for the next signal with the given name.
    /// Multiple calls receive different signals (FIFO order).
    pub async fn wait_for_signal<T: DeserializeOwned>(&self, signal_name: &str) -> Result<T>;

    /// Check if there are buffered signals without blocking.
    pub fn has_signal(&self, signal_name: &str) -> bool;

    /// Drain all buffered signals with the given name.
    pub async fn drain_signals<T: DeserializeOwned>(&self, signal_name: &str) -> Result<Vec<T>>;
}
```

**Example Workflow:**
```rust
async fn conversation_workflow(ctx: &WorkflowContext) -> Result<()> {
    loop {
        // Wait for next message - multiple signals with same name work!
        let msg: Message = ctx.wait_for_signal("message").await?;

        let response = process_message(&msg).await?;

        if msg.is_end_conversation() {
            break;
        }
    }
    Ok(())
}
```

### SDK Replay Design

Signals are buffered into queues. The same code path handles both normal execution and replay.

**Event History Example:**
```
[1] WORKFLOW_STARTED
[2] WORKFLOW_TASK_SCHEDULED
[3] WORKFLOW_TASK_STARTED
[4] WORKFLOW_TASK_COMPLETED
[5] SIGNAL_RECEIVED {name: "message", value: "hello"}   ← Signal arrived
[6] WORKFLOW_TASK_SCHEDULED
[7] WORKFLOW_TASK_STARTED
[8] WORKFLOW_TASK_COMPLETED {commands: [...]}           ← Workflow processed signal
```

**Replay Engine State:**
```rust
struct ReplayState {
    /// Signal queues built from SIGNAL_RECEIVED events in history
    /// Key: signal name, Value: queue of buffered signals (FIFO)
    signal_queues: HashMap<String, VecDeque<SignalEvent>>,
    // ... other replay state
}

impl ReplayState {
    /// Called when processing SIGNAL_RECEIVED event from history
    fn on_signal_received(&mut self, event: SignalReceivedEvent) {
        self.signal_queues
            .entry(event.signal_name.clone())
            .or_default()
            .push_back(event);
    }
}
```

**Context Implementation:**
```rust
impl WorkflowContext {
    pub async fn wait_for_signal<T: DeserializeOwned>(&self, name: &str) -> Result<T> {
        // Check if signal already buffered (from history or arrived earlier)
        if let Some(signal) = self.state.signal_queues.get_mut(name)?.pop_front() {
            return deserialize(&signal.value);
        }

        // No buffered signal - suspend workflow
        // Will resume when server delivers new SIGNAL_RECEIVED event
        self.suspend().await
    }

    pub fn has_signal(&self, name: &str) -> bool {
        self.state.signal_queues
            .get(name)
            .map(|q| !q.is_empty())
            .unwrap_or(false)
    }

    pub fn drain_signals<T: DeserializeOwned>(&self, name: &str) -> Result<Vec<T>> {
        self.state.signal_queues
            .remove(name)
            .unwrap_or_default()
            .into_iter()
            .map(|s| deserialize(&s.value))
            .collect()
    }
}
```

**Replay vs New Execution Flow:**

| Step | Replay | New Execution |
|------|--------|---------------|
| 1 | Load event history | Workflow starts |
| 2 | Build signal queues from `SIGNAL_RECEIVED` events | `wait_for_signal("msg")` called |
| 3 | Run workflow code | No signal → suspend |
| 4 | `wait_for_signal("msg")` called | Signal arrives externally |
| 5 | Signal in queue → return immediately | Server appends `SIGNAL_RECEIVED` event |
| 6 | Continue execution | Resume workflow → return signal |

**Key Properties:**
- No command generated by `wait_for_signal()` - it just reads from buffer or suspends
- Signals can arrive before workflow asks for them (buffered)
- Same code path for replay and normal execution (deterministic)
- FIFO ordering per signal name

---

## Architecture

### API Design

#### gRPC API

Add new RPCs to the `WorkflowDispatch` service:

```proto
service WorkflowDispatch {
  // Atomically start a workflow (if not exists) and send a signal
  rpc SignalWithStartWorkflow(SignalWithStartWorkflowRequest)
      returns (SignalWithStartWorkflowResponse);

  // Send a signal to an existing workflow
  rpc SignalWorkflow(SignalWorkflowRequest)
      returns (SignalWorkflowResponse);
}

message SignalWithStartWorkflowRequest {
  string org_id = 1;

  // === Workflow Identity ===
  string workflow_id = 2;  // Used as idempotency key for workflow creation

  // === Workflow Start Parameters (used if workflow needs to be created) ===
  string workflow_kind = 3;
  bytes workflow_input = 4;
  string queue = 5;
  int32 priority_seconds = 6;
  optional string workflow_version = 7;
  map<string, string> metadata = 8;

  // === Signal Parameters (always applied) ===
  string signal_name = 9;
  bytes signal_value = 10;

  // === Options ===
  optional int64 idempotency_key_ttl_seconds = 11;
  // No signal_idempotency_key - each call creates a new signal event
  // Deduplication (if needed) is handled at application layer via payload
}

message SignalWithStartWorkflowResponse {
  string workflow_execution_id = 1;
  bool workflow_created = 2;
  int64 signal_event_sequence = 3;
}

message SignalWorkflowRequest {
  string org_id = 1;
  string workflow_execution_id = 2;
  string signal_name = 3;
  bytes signal_value = 4;
}

message SignalWorkflowResponse {
  int64 signal_event_sequence = 1;
}
```

#### REST API

**SignalWithStart:**
```
POST /api/orgs/{org_slug}/workflow-executions/signal-with-start
```

Request body:
```json
{
  "workflow_id": "conversation:conv-123",
  "workflow_kind": "chatbot-conversation",
  "workflow_input": { "conversation_id": "conv-123", "user_id": "user-456" },
  "queue": "default",
  "signal_name": "message",
  "signal_value": { "text": "Hello!", "timestamp": 1706380800000 },
  "metadata": { "channel": "web" }
}
```

Response:
```json
{
  "workflow_execution_id": "550e8400-e29b-41d4-a716-446655440000",
  "workflow_created": true,
  "signal_event_sequence": 3,
  "signal_delivered": true
}
```

**Signal existing workflow:**
```
POST /api/orgs/{org_slug}/workflow-executions/{workflow_execution_id}/signal
```

### Database Implementation

Following Temporal's approach, signals are stored **purely as events** - no separate table.

```sql
-- Use existing workflow_event table with new event type
INSERT INTO workflow_event (workflow_execution_id, event_type, event_data, sequence_number)
VALUES ($1, 'SIGNAL_RECEIVED', '{"signal_name": "message", "signal_value": "..."}', nextval(...));
```

**Atomic SignalWithStart Transaction:**
```sql
BEGIN TRANSACTION;

-- Step 1: Get or create workflow using idempotency key
SELECT * FROM workflow_execution we
JOIN idempotency_key ik ON we.id = ik.workflow_execution_id
WHERE ik.org_id = $org_id
  AND ik.key = $workflow_id
  AND ik.expires_at > NOW()
  AND we.status NOT IN ('COMPLETED', 'FAILED', 'CANCELLED')
FOR UPDATE;

IF NOT FOUND THEN
  INSERT INTO workflow_execution (...) VALUES (...);
  INSERT INTO idempotency_key (...) VALUES (...);
  INSERT INTO workflow_event (...) VALUES (...);  -- WORKFLOW_STARTED
  workflow_created = true;
END IF;

-- Step 2: Append SIGNAL_RECEIVED event (always - no deduplication)
INSERT INTO workflow_event (...) VALUES ('SIGNAL_RECEIVED', ...);

-- Step 3: Resume workflow if waiting
UPDATE workflow_execution SET status = 'PENDING' WHERE status = 'WAITING';
PERFORM pg_notify('workflow_work_available', ...);

COMMIT;
```

### SDK Changes

#### Python SDK

```python
class FlovynClient:
    async def signal_with_start_workflow(
        self,
        workflow_id: str,
        workflow: str | type[Any] | Callable[..., Any],
        workflow_input: Any,
        *,
        signal_name: str,
        signal_value: Any,
        queue: str | None = None,
    ) -> SignalWithStartResponse:
        """Start a workflow if it doesn't exist and send a signal."""

    async def signal_workflow(
        self,
        workflow_execution_id: str,
        signal_name: str,
        signal_value: Any,
    ) -> SignalResponse:
        """Send a signal to an existing workflow."""


class WorkflowContext:
    async def wait_for_signal(self, signal_name: str, type_hint: type[T] = Any) -> T:
        """Wait for the next signal with the given name."""

    def has_signal(self, signal_name: str) -> bool:
        """Check if there are buffered signals without blocking."""

    async def drain_signals(self, signal_name: str, type_hint: type[T] = Any) -> list[T]:
        """Drain all buffered signals with the given name."""
```

#### Rust SDK

```rust
impl FlovynClient {
    pub async fn signal_with_start_workflow(
        &self,
        options: SignalWithStartOptions,
    ) -> Result<SignalWithStartResponse>;

    pub async fn signal_workflow(
        &self,
        workflow_execution_id: &str,
        signal_name: &str,
        signal_value: impl Serialize,
    ) -> Result<SignalResponse>;
}

impl WorkflowContext {
    pub async fn wait_for_signal<T: DeserializeOwned>(&self, signal_name: &str) -> Result<T>;
    pub fn has_signal(&self, signal_name: &str) -> bool;
    pub async fn drain_signals<T: DeserializeOwned>(&self, signal_name: &str) -> Result<Vec<T>>;
}
```

### Eventhook Integration

Support routing webhooks using SignalWithStart:

```rust
pub struct SignalWithStartConfig {
    pub workflow_id_path: String,  // JMESPath to extract workflow ID
    pub signal_name: String,
    pub signal_value_path: Option<String>,
}
```

Example route configuration:
```json
{
  "target": {
    "type": "workflow",
    "workflow_kind": "chatbot-conversation",
    "signal_with_start": {
      "workflow_id_path": "conversation.id",
      "signal_name": "message"
    }
  }
}
```

---

## Implementation Strategy

**Incremental approach** - Add signals first, verify they work, then remove promises:

1. **Phase 1: Add Signals** - Introduce signal support alongside existing promises
2. **Phase 2: Verify** - Write tests, confirm signals work across server and all SDKs
3. **Phase 3: Remove Promises** - Delete promise code and migrations

This prevents breaking everything at once.

---

## Phase 1: Add Signals (Per Project)

### flovyn-server (Rust)

**Database Migrations:**
```
server/migrations/YYYYMMDD_add_signal_received_event.sql
```
- Add `SIGNAL_RECEIVED` event type (keep promise events for now)

**Files to Add:**
- `server/src/api/grpc/signal.rs` - gRPC handlers for `SignalWorkflow`, `SignalWithStartWorkflow`
- `server/src/api/rest/signal.rs` - REST handlers for signal endpoints
- `server/src/service/signal_service.rs` - Business logic for atomic SignalWithStart

**Files to Modify:**
- `server/proto/flovyn.proto`:
  - Add `SignalWithStartWorkflow`, `SignalWorkflow` RPCs and messages
  - Add `SIGNAL_RECEIVED` event type (no command needed - signals are external input, not workflow commands)
  - Keep promise RPCs for now
- `server/src/api/grpc/workflow_dispatch.rs` - Add signal command handling (keep promise handling)
- `server/src/api/grpc/mod.rs` - Register new signal handlers
- `server/src/api/rest/mod.rs` - Register new signal routes
- `server/src/api/rest/openapi.rs` - Add signal endpoints to OpenAPI spec
- `server/src/repository/workflow_repository.rs` - Add atomic get-or-create-and-signal
- `server/src/repository/event_repository.rs` - Add method to append signal events

**Eventhook Changes:**
- `plugins/eventhook/src/route.rs` - Add `signal_with_start` config option
- `plugins/eventhook/src/dispatch.rs` - Implement SignalWithStart dispatch logic

### sdk-rust

**Files to Add:**
- `worker-sdk/src/workflow/signal.rs` - Signal types and futures
- `worker-sdk/tests/e2e/signal_tests.rs` - E2E tests for signals
- `examples/patterns/src/signal_workflow.rs` - Example signal workflow

**Files to Modify:**
- `worker-sdk/src/workflow/context.rs`:
  - Add `wait_for_signal()`, `has_signal()`, `drain_signals()` methods (keep promise methods)
- `worker-sdk/src/workflow/future.rs`:
  - Add `SignalFuture`, `SignalFutureRaw` (keep promise futures)
- `worker-sdk/src/workflow/context_impl.rs` - Add signal implementation
- `worker-sdk/src/worker/workflow_worker.rs` - Handle signal events
- `worker-core/src/workflow/command.rs` - Add signal commands (keep promise commands)
- `worker-core/src/workflow/event.rs` - Add signal event types
- `worker-core/src/workflow/execution.rs` - Add signal queue handling
- `worker-core/src/workflow/replay_engine.rs` - Handle signal events during replay
- `worker-core/proto/flovyn.proto` - Sync with server proto
- `worker-sdk/src/client/flovyn_client.rs` - Add `signal_with_start_workflow()`, `signal_workflow()` methods
- `worker-sdk/src/testing/mock_workflow_context.rs` - Add signal mocks
- `worker-sdk/src/testing/builders.rs` - Add signal test builders

**FFI Layer (used by Python/Kotlin/TypeScript SDKs):**
- `worker-ffi/src/context.rs` - Add FFI bindings for signals
- `worker-ffi/src/command.rs` - Add signal command bindings
- `worker-ffi/src/client.rs` - Add signal client methods
- `worker-napi/src/context.rs` - Add NAPI bindings for signals
- `worker-napi/src/command.rs` - Add signal command bindings
- `worker-napi/src/client.rs` - Add signal client methods

### sdk-python

**Files to Add:**
- `tests/e2e/test_signal.py` - E2E tests for signals

**Files to Modify:**
- `flovyn/context.py` - Add signal methods (`wait_for_signal()`, `has_signal()`, `drain_signals()`) alongside promises
- `flovyn/client.py` - Add `signal_with_start_workflow()`, `signal_workflow()` async methods
- `flovyn/testing/mocks.py` - Add signal mocks
- `flovyn/_native/flovyn_worker_ffi.py` - Regenerate FFI bindings from sdk-rust
- `flovyn/__init__.py` - Export signal methods
- `tests/e2e/fixtures/workflows.py` - Add signal workflow fixtures

### sdk-kotlin

**Files to Add:**
- `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/DurableSignal.kt` - Signal types

**Files to Modify:**
- `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContext.kt` - Add signal methods alongside promises
- `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContextImpl.kt` - Add signal implementation
- `worker-sdk/src/main/kotlin/ai/flovyn/sdk/client/FlovynClient.kt` - Add `signalWithStartWorkflow()`, `signalWorkflow()` methods
- `worker-sdk/src/main/kotlin/ai/flovyn/core/CoreClientBridge.kt` - Add signal bridge methods
- `worker-native/src/main/kotlin/uniffi/flovyn_worker_ffi/flovyn_worker_ffi.kt` - Regenerate FFI bindings
- `worker-sdk-jackson/src/test/kotlin/ai/flovyn/sdk/e2e/fixtures/Workflows.kt` - Add signal workflow fixtures

### sdk-typescript

**Files to Add:**
- `tests/e2e/signal.test.ts` - E2E tests for signals

**Files to Modify:**
- `packages/sdk/src/context/workflow-context.ts` - Add signal methods (`waitForSignal()`, `hasSignal()`, `drainSignals()`) alongside promises
- `packages/sdk/src/client.ts` - Add `signalWithStartWorkflow()`, `signalWorkflow()` methods
- `packages/sdk/src/handles.ts` - Add signal handles
- `packages/sdk/src/types.ts` - Add signal type definitions
- `packages/sdk/src/worker/workflow-worker.ts` - Handle signal events
- `packages/sdk/src/testing/mock-workflow-context.ts` - Add signal mocks
- `packages/native/src/index.ts` - Regenerate native bindings from sdk-rust
- `packages/native/generated.d.ts` - Regenerate type definitions
- `tests/e2e/fixtures/workflows.ts` - Add signal workflow fixtures

### flovyn-app (Next.js)

**Files to Add:**
- `apps/web/components/events/SignalDetailsPanel.tsx` - UI for signal events

**Files to Modify:**
- `apps/web/lib/types/event-spans.ts`:
  - Add `SpanType.SIGNAL` (keep `SpanType.PROMISE`)
  - Add signal span properties
- `apps/web/lib/event-processing/buildEventSpans.ts`:
  - Handle `SIGNAL_RECEIVED` events (keep promise event handling)
- `apps/web/lib/test-utils/mocks/eventSpanFactory.ts` - Add signal fixtures
- `packages/api/` - Regenerate from updated server OpenAPI spec (adds signal endpoints)

**API package:**
- Add `useSignalWorkflow` hook for sending signals

---

## Phase 3: Remove Promises (After Signals Verified)

Only proceed after signals are fully tested and working across all projects.

### flovyn-server

**New Database Migration:**
```
server/migrations/YYYYMMDD_drop_promise_table.sql
```
```sql
-- Drop promise table (no longer used after signal migration)
DROP TABLE IF EXISTS promise;

-- Note: Promise events in workflow_event are kept for historical record
-- They won't be created anymore but existing ones remain readable
```

**Files to Remove:**
- `server/src/api/rest/promises.rs`
- `server/src/repository/promise_repository.rs`
- `server/src/service/promise_resolver.rs`

**Files to Modify:**
- `server/proto/flovyn.proto` - Remove `ResolvePromise`, `RejectPromise` RPCs, `CREATE_PROMISE`, `RESOLVE_PROMISE` commands
- `server/src/api/rest/mod.rs` - Remove promise route registration
- `server/src/api/rest/openapi.rs` - Remove promise endpoints
- `server/src/repository/mod.rs` - Remove promise module
- `server/src/service/mod.rs` - Remove promise module
- `server/src/scheduler.rs` - Remove promise timeout handling
- `server/src/api/grpc/workflow_dispatch.rs` - Remove promise command handling

### sdk-rust

**Files to Remove:**
- `examples/patterns/src/promise_workflow.rs`
- `worker-sdk/tests/e2e/promise_tests.rs`
- `worker-sdk/tests/shared/replay-corpus/promise.json`

**Files to Modify:**
- `worker-sdk/src/workflow/context.rs` - Remove `promise_*` methods, `PromiseOptions`
- `worker-sdk/src/workflow/future.rs` - Remove `PromiseFuture`, `PromiseFutureRaw`
- `worker-core/src/workflow/command.rs` - Remove promise commands
- `worker-core/proto/flovyn.proto` - Sync with server
- `worker-ffi/src/*` - Remove promise FFI bindings
- `worker-napi/src/*` - Remove promise NAPI bindings

### sdk-python

**Files to Remove:**
- `tests/e2e/test_promise.py`

**Files to Modify:**
- `flovyn/context.py` - Remove promise methods
- `flovyn/testing/mocks.py` - Remove promise mocks
- `tests/e2e/fixtures/workflows.py` - Remove promise fixtures

### sdk-kotlin

**Files to Remove:**
- `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/DurablePromise.kt`

**Files to Modify:**
- `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContext.kt` - Remove promise methods
- `worker-sdk-jackson/src/test/kotlin/ai/flovyn/sdk/e2e/fixtures/Workflows.kt` - Remove promise fixtures

### sdk-typescript

**Files to Remove:**
- `tests/e2e/promise.test.ts`

**Files to Modify:**
- `packages/sdk/src/context/workflow-context.ts` - Remove promise methods
- `packages/sdk/src/testing/mock-workflow-context.ts` - Remove promise mocks
- `tests/e2e/fixtures/workflows.ts` - Remove promise fixtures

### flovyn-app

**Files to Remove:**
- `apps/web/components/events/PromiseDetailsPanel.tsx`

**Files to Modify:**
- `apps/web/lib/types/event-spans.ts` - Remove `SpanType.PROMISE`
- `apps/web/lib/event-processing/buildEventSpans.ts` - Remove promise event handling
- `packages/api/` - Regenerate (removes promise hooks)

---

## Alternatives Considered

### Alternative 1: Client-Side Coordination

```python
try:
    await client.start_workflow(workflow_id, ...)
except WorkflowAlreadyExists:
    pass
await client.signal_workflow(workflow_id, "message", value)
```

**Rejected**: Race conditions, requires all clients to implement same logic.

### Alternative 2: Separate "Get or Create" + Signal

```python
workflow = await client.get_or_start_workflow(workflow_id, ...)
await client.signal_workflow(workflow.id, "message", value)
```

**Rejected**: Race window between calls, two round trips.

### Alternative 3: Restate-Style Indexed Promises

```rust
let msg = ctx.promise::<Message>(format!("message-{}", idx)).await?;
```

**Rejected**: Unbounded indices, caller must track, no queue semantics.

---

## Open Questions

### Q1: Signal Name Convention

~~Should we enforce a naming convention for signal names?~~

**Decision**: Any string is valid. No reserved prefixes for MVP.

### Q2: Signal Deduplication

~~How should we handle duplicate signals?~~

**Decision**: No built-in deduplication. Each `signal_workflow()` call creates a new event. If deduplication is needed, handle at application layer (include unique ID in payload, workflow logic deduplicates). This matches Temporal's fire-and-forget signal model.

### Q3: Workflow Not Running

~~What if workflow exists but is in terminal state (COMPLETED, FAILED)?~~

**Decision**: Return error. Temporal: "You can only send Signals to Workflow Executions that haven't closed."

### Q4: Signal Buffer Size Limit

~~Limit unprocessed signals per workflow?~~

**Temporal's approach**:
- 10,000 signals per workflow execution
- ≤5/sec sustained rate recommended
- If limit reached, new signals rejected

**Decision**: 10,000 signals per workflow (matching Temporal). Return error when limit exceeded.

### Q5: Eventhook Migration

~~How to handle existing Eventhook routes?~~

**Decision**: No migration needed - no existing routes use promises. Just implement signal_with_start config.

### Q6: Workflow-to-Workflow Signaling (External Workflow Signaling)

Support one workflow signaling another?

**Why a special mechanism is needed:**

Workflows must be deterministic. A workflow can't use the regular client:

```rust
// ❌ Breaks determinism
async fn my_workflow(ctx: &WorkflowContext) {
    let client = FlovynClient::new();  // Non-deterministic!
    client.signal_workflow("other-id", "msg", data).await;  // Network call!
}
```

On replay, this would make duplicate network calls and potentially get different results.

**Temporal's approach**: Commands + Events (like activities/timers):

```rust
// ✅ Deterministic - recorded in event history
async fn my_workflow(ctx: &WorkflowContext) {
    ctx.signal_external_workflow("other-id", "msg", data).await;
}
```

1. Workflow issues command: `SignalExternalWorkflowExecutionInitiated`
2. Server executes the signal delivery
3. Server records result: `SignalExternalWorkflowExecutionCompleted` or `Failed`
4. On replay, SDK sees command in history → skips execution

**Event flow:**
```
Sender workflow history:
  [5] SignalExternalWorkflowExecutionInitiated {target: "other-id", signal: "msg"}
  [6] SignalExternalWorkflowExecutionCompleted  ← Server confirmed delivery

Receiver workflow history:
  [3] SignalReceived {signal: "msg", value: ...}
```

**Decision**: Deferred to post-MVP. For MVP, signals are external-only (from client/API, not from other workflows).

---

## Success Criteria

1. **Atomicity**: SignalWithStart is atomic - no race conditions
2. **Compatibility**: Works with existing workflow code
3. **Performance**: Single round trip for the entire operation
4. **SDK Support**: Available in all SDKs (Rust, Python, Kotlin, TypeScript)
5. **Eventhook Support**: Can route webhooks using SignalWithStart

---

## References

### Competitor Documentation
- [Temporal SignalWithStart](https://docs.temporal.io/sending-messages#sending-signals)
- [Temporal Python SDK - start_signal parameter](https://python.temporal.io/temporalio.client.Client.html#start_workflow)
- [Restate Workflows - Durable Promises](https://docs.restate.dev/tour/workflows)

### Internal References
- [Execution Patterns for Multi-Message Workflows](../research/20260128_execution_patterns_multi_message.md)
- [Durable AI Conversations and Context Management](../research/20260128_ai_conversation_durability.md)
- [Current Idempotency Key Implementation](flovyn-server/server/src/repository/idempotency_key_repository.rs)
- [Current Promise Implementation (to be replaced)](flovyn-server/server/src/repository/promise_repository.rs)
