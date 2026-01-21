# Eventhook Milestone 0: Unified Event Publisher

**Date:** 2025-12-31
**Status:** Ready for Review
**Related:** [Eventhook Research](../research/eventhook/20251231_research.md), [Eventhook Roadmap](../research/eventhook/20251231_roadmap.md)

## Overview

This document describes the design for Milestone 0 of the Eventhook feature: creating an event publishing infrastructure for structured lifecycle events (workflow/task state changes), separate from generic SSE streaming.

**Key distinction:**
- **Generic streaming** (`StreamEvent`) - LLM tokens, logs, progress updates. Workflow-scoped, ephemeral.
- **Lifecycle events** (`FlovynEvent`) - Workflow/task state changes. Tenant-scoped, structured, SSE-streamable, routable.

## Goals

1. **Separate concerns** - Generic streaming stays unchanged; lifecycle events get new infrastructure
2. **Add event bus capability** - Publish/subscribe to tenant-scoped lifecycle events
3. **Backend-agnostic** - Same API for in-memory and NATS backends
4. **Pattern matching** - Subscribers can filter by event type

## Non-Goals

- Event persistence (Milestone 5)
- Rules engine / routing (Milestone 1)
- Webhook ingestion (Milestone 1)
- Outbound webhook delivery (Milestone 4)
- Changes to generic streaming (StreamEvent, Token/Progress/Data/Error)

## Current State

```
server/src/streaming/
├── mod.rs          # StreamEventPublisher, StreamSubscriber traits, StreamError
├── in_memory.rs    # InMemoryStreaming (HashMap<workflow_id, broadcast::Sender>)
└── nats.rs         # NatsStreaming (async_nats::Client)
```

**Generic streaming (unchanged):**
```rust
#[async_trait]
pub trait StreamEventPublisher: Send + Sync {
    async fn publish(&self, event: StreamEvent) -> Result<(), StreamError>;
}

pub trait StreamSubscriber: Send + Sync {
    fn subscribe(&self, workflow_execution_id: &str)
        -> Pin<Box<dyn Stream<Item = StreamEvent> + Send>>;
}
```

`StreamEvent` with `StreamEventType` (Token, Progress, Data, Error) - for generic SSE streaming. **Stays as-is.**

**Lifecycle events (to be migrated):**

Currently `StateEventPayload` is sent via `StreamEvent` with type `Data`. This should move to `FlovynEvent`:
- `StateEventPayload` with events: TASK_CREATED, TASK_STARTED, TASK_COMPLETED, WORKFLOW_STARTED, WORKFLOW_COMPLETED, etc.
- Snapshots: `TaskSnapshot`, `WorkflowSnapshot`, `TimerSnapshot`, `PromiseSnapshot`, etc.

**Current NATS subject:** `flovyn.streams.workflow.{workflow_execution_id}`

## Proposed Design

### Approach: Separate Event Bus

Add a new event bus infrastructure alongside existing generic streaming:
- **Generic streaming** - `StreamEventPublisher` / `StreamSubscriber` - unchanged
- **Event bus** - `EventPublisher` / `EventSubscriber` - new, for lifecycle events

### New Module Structure

```
server/src/streaming/
├── mod.rs          # All traits + re-exports
├── event.rs        # FlovynEvent, EventPattern (NEW)
├── in_memory.rs    # InMemoryStreaming (implements all traits)
└── nats.rs         # NatsStreaming (implements all traits)
```

### Core Types

#### FlovynEvent

New event type for the event bus (distinct from `TaskStreamEvent` which is for SSE):

```rust
// server/src/streaming/event.rs

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Lifecycle event for the event bus.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FlovynEvent {
    /// Unique event ID
    pub id: Uuid,
    /// Tenant scope (for tenant-level subscriptions)
    pub tenant_id: Uuid,
    /// Workflow execution ID (for workflow-level subscriptions)
    pub workflow_execution_id: Option<Uuid>,
    /// Task execution ID (for task-level subscriptions)
    pub task_execution_id: Option<Uuid>,
    /// Event type (e.g., "workflow.completed", "task.started")
    pub event_type: String,
    /// Source identifier (e.g., "system", "worker:worker-123")
    pub source: String,
    /// Event payload (JSON)
    pub data: serde_json::Value,
    /// Timestamp (milliseconds since epoch)
    pub timestamp_ms: i64,
    /// Optional correlation ID for tracing
    pub correlation_id: Option<String>,
}

impl FlovynEvent {
    pub fn new(tenant_id: Uuid, event_type: impl Into<String>, source: impl Into<String>, data: serde_json::Value) -> Self {
        Self {
            id: Uuid::new_v4(),
            tenant_id,
            workflow_execution_id: None,
            task_execution_id: None,
            event_type: event_type.into(),
            source: source.into(),
            data,
            timestamp_ms: chrono::Utc::now().timestamp_millis(),
            correlation_id: None,
        }
    }

    pub fn with_workflow(mut self, workflow_execution_id: Uuid) -> Self {
        self.workflow_execution_id = Some(workflow_execution_id);
        self
    }

    pub fn with_task(mut self, task_execution_id: Uuid) -> Self {
        self.task_execution_id = Some(task_execution_id);
        self
    }

    pub fn with_correlation_id(mut self, id: impl Into<String>) -> Self {
        self.correlation_id = Some(id.into());
        self
    }
}
```

#### EventPattern

Pattern for filtering event subscriptions:

```rust
// server/src/streaming/event.rs

/// Pattern for filtering event subscriptions.
/// Works identically for both in-memory and NATS backends.
#[derive(Clone, Debug, Default)]
pub struct EventPattern {
    /// Tenant scope (required)
    pub tenant_id: Uuid,
    /// Workflow execution ID filter (for workflow-specific subscriptions)
    pub workflow_execution_id: Option<Uuid>,
    /// Task execution ID filter (for task-specific subscriptions)
    pub task_execution_id: Option<Uuid>,
    /// Event type prefix filter (None = all events)
    pub event_type_prefix: Option<String>,
    /// Source filter (None = all sources)
    pub source: Option<String>,
}

impl EventPattern {
    /// Match all events for a tenant.
    pub fn all(tenant_id: Uuid) -> Self {
        Self {
            tenant_id,
            workflow_execution_id: None,
            task_execution_id: None,
            event_type_prefix: None,
            source: None,
        }
    }

    /// Match events for a specific workflow.
    pub fn for_workflow(tenant_id: Uuid, workflow_execution_id: Uuid) -> Self {
        Self {
            tenant_id,
            workflow_execution_id: Some(workflow_execution_id),
            task_execution_id: None,
            event_type_prefix: None,
            source: None,
        }
    }

    /// Match events for a specific task.
    pub fn for_task(tenant_id: Uuid, task_execution_id: Uuid) -> Self {
        Self {
            tenant_id,
            workflow_execution_id: None,
            task_execution_id: Some(task_execution_id),
            event_type_prefix: None,
            source: None,
        }
    }

    /// Match events with a specific type prefix.
    pub fn by_type(tenant_id: Uuid, prefix: impl Into<String>) -> Self {
        Self {
            tenant_id,
            workflow_execution_id: None,
            task_execution_id: None,
            event_type_prefix: Some(prefix.into()),
            source: None,
        }
    }

    /// Check if an event matches this pattern.
    pub fn matches(&self, event: &FlovynEvent) -> bool {
        if event.tenant_id != self.tenant_id {
            return false;
        }
        if let Some(wf_id) = self.workflow_execution_id {
            if event.workflow_execution_id != Some(wf_id) {
                return false;
            }
        }
        if let Some(task_id) = self.task_execution_id {
            if event.task_execution_id != Some(task_id) {
                return false;
            }
        }
        if let Some(ref prefix) = self.event_type_prefix {
            if !event.event_type.starts_with(prefix) {
                return false;
            }
        }
        if let Some(ref source) = self.source {
            if &event.source != source {
                return false;
            }
        }
        true
    }
}
```

### Traits

#### Existing traits (unchanged)

```rust
// server/src/streaming/mod.rs - NO CHANGES

#[async_trait]
pub trait StreamEventPublisher: Send + Sync {
    async fn publish(&self, event: StreamEvent) -> Result<(), StreamError>;
}

pub trait StreamSubscriber: Send + Sync {
    fn subscribe(&self, workflow_execution_id: &str)
        -> Pin<Box<dyn Stream<Item = StreamEvent> + Send>>;
}
```

#### New traits (event bus)

```rust
// server/src/streaming/mod.rs - NEW

/// Publish lifecycle events to the tenant-scoped event bus.
#[async_trait]
pub trait EventPublisher: Send + Sync {
    async fn publish(&self, event: FlovynEvent) -> Result<(), StreamError>;
}

/// Subscribe to lifecycle events on the event bus.
pub trait EventSubscriber: Send + Sync {
    fn subscribe(&self, pattern: EventPattern)
        -> Pin<Box<dyn Stream<Item = FlovynEvent> + Send>>;
}
```

### In-Memory Implementation

```rust
// server/src/streaming/in_memory.rs

const STREAM_CHANNEL_CAPACITY: usize = 256;   // Per-workflow generic streaming
const EVENT_CHANNEL_CAPACITY: usize = 1024;   // Per-tenant lifecycle events

/// In-memory streaming backend.
/// Implements both generic streaming and event bus traits.
pub struct InMemoryStreaming {
    /// Generic stream channels keyed by workflow_execution_id (existing)
    channels: RwLock<HashMap<String, broadcast::Sender<StreamEvent>>>,
    /// Event bus channels keyed by tenant_id (new)
    event_channels: RwLock<HashMap<Uuid, broadcast::Sender<FlovynEvent>>>,
}

// Existing StreamEventPublisher impl - UNCHANGED
#[async_trait]
impl StreamEventPublisher for InMemoryStreaming {
    async fn publish(&self, event: StreamEvent) -> Result<(), StreamError> {
        let tx = self.get_or_create_channel(&event.workflow_execution_id);
        let _ = tx.send(event);
        Ok(())
    }
}

// Existing StreamSubscriber impl - UNCHANGED
impl StreamSubscriber for InMemoryStreaming {
    fn subscribe(&self, workflow_execution_id: &str)
        -> Pin<Box<dyn Stream<Item = StreamEvent> + Send>>
    {
        let tx = self.get_or_create_channel(workflow_execution_id);
        Box::pin(BroadcastStream::new(tx.subscribe()).filter_map(|r| r.ok()))
    }
}

// NEW: EventPublisher impl
#[async_trait]
impl EventPublisher for InMemoryStreaming {
    async fn publish(&self, event: FlovynEvent) -> Result<(), StreamError> {
        let tx = self.get_or_create_event_channel(event.tenant_id);
        let _ = tx.send(event);
        Ok(())
    }
}

// NEW: EventSubscriber impl
impl EventSubscriber for InMemoryStreaming {
    fn subscribe(&self, pattern: EventPattern)
        -> Pin<Box<dyn Stream<Item = FlovynEvent> + Send>>
    {
        let tx = self.get_or_create_event_channel(pattern.tenant_id);
        let stream = BroadcastStream::new(tx.subscribe())
            .filter_map(|r| r.ok())
            .filter(move |event| {
                let matches = pattern.matches(event);
                async move { matches }
            });
        Box::pin(stream)
    }
}
```

**Backpressure:** When a channel is full, oldest events are dropped. Consumers handle gaps via `filter_map(|r| r.ok())`.

### NATS Implementation

```rust
// server/src/streaming/nats.rs

/// NATS streaming backend.
/// Implements both generic streaming and event bus traits.
pub struct NatsStreaming {
    client: async_nats::Client,
}

impl NatsStreaming {
    // Existing subject for generic streaming
    fn build_stream_subject(workflow_execution_id: &str) -> String {
        format!("flovyn.streams.workflow.{}", workflow_execution_id)
    }

    // NEW: Subject for event bus
    fn build_event_subject(tenant_id: Uuid, event_type: &str) -> String {
        format!("flovyn.events.{}.{}", tenant_id, event_type)
    }

    // NEW: Subscription pattern for event bus
    fn build_event_subscription_subject(pattern: &EventPattern) -> String {
        match &pattern.event_type_prefix {
            None => format!("flovyn.events.{}.>", pattern.tenant_id),
            Some(prefix) => {
                if prefix.contains('.') {
                    format!("flovyn.events.{}.{}", pattern.tenant_id, prefix)
                } else {
                    format!("flovyn.events.{}.{}.>", pattern.tenant_id, prefix)
                }
            }
        }
    }
}

// Existing StreamEventPublisher impl - UNCHANGED
#[async_trait]
impl StreamEventPublisher for NatsStreaming {
    async fn publish(&self, event: StreamEvent) -> Result<(), StreamError> {
        // ... existing implementation
    }
}

// Existing StreamSubscriber impl - UNCHANGED
impl StreamSubscriber for NatsStreaming {
    fn subscribe(&self, workflow_execution_id: &str)
        -> Pin<Box<dyn Stream<Item = StreamEvent> + Send>>
    {
        // ... existing implementation
    }
}

// NEW: EventPublisher impl
#[async_trait]
impl EventPublisher for NatsStreaming {
    async fn publish(&self, event: FlovynEvent) -> Result<(), StreamError> {
        let subject = Self::build_event_subject(event.tenant_id, &event.event_type);
        let payload = serde_json::to_vec(&event)
            .map_err(|e| StreamError::Serialization(e.to_string()))?;
        self.client.publish(subject, payload.into()).await
            .map_err(|e| StreamError::Publish(e.to_string()))?;
        self.client.flush().await
            .map_err(|e| StreamError::Publish(e.to_string()))?;
        Ok(())
    }
}

// NEW: EventSubscriber impl
impl EventSubscriber for NatsStreaming {
    fn subscribe(&self, pattern: EventPattern)
        -> Pin<Box<dyn Stream<Item = FlovynEvent> + Send>>
    {
        let subject = Self::build_event_subscription_subject(&pattern);
        let client = self.client.clone();

        let stream = async_stream::stream! {
            if let Ok(mut sub) = client.subscribe(subject).await {
                while let Some(msg) = sub.next().await {
                    if let Ok(event) = serde_json::from_slice::<FlovynEvent>(&msg.payload) {
                        if pattern.matches(&event) {
                            yield event;
                        }
                    }
                }
            }
        };
        Box::pin(stream)
    }
}
```

**NATS Subject Hierarchy:**
```
flovyn.
├── streams.workflow.{workflow_id}     # Generic streaming (existing)
└── events.{tenant_id}.{event_type}    # Lifecycle events (new)
    ├── workflow.started
    ├── workflow.completed
    ├── task.started
    ├── task.completed
    └── webhook.{source}.{type}        # Future: webhook events
```

**NATS Wildcard Patterns:**
- `flovyn.events.{tenant}.>` - All events for tenant
- `flovyn.events.{tenant}.workflow.>` - All workflow events
- `flovyn.events.{tenant}.workflow.completed` - Specific event type

### SSE Endpoints

**Existing endpoints (updated with `types` param in M0):**
```
GET /workflow-executions/{id}/stream?types=events,tokens,progress,data
GET /task-executions/{id}/stream?types=events,tokens,progress,data
```

| Type | Source | Description |
|------|--------|-------------|
| `events` | `FlovynEvent` via `EventSubscriber` | Lifecycle events (TASK_STARTED, WORKFLOW_COMPLETED, etc.) |
| `tokens` | `StreamEvent::Token` via `StreamSubscriber` | LLM token streaming |
| `progress` | `StreamEvent::Progress` via `StreamSubscriber` | Progress updates |
| `data` | `StreamEvent::Data` via `StreamSubscriber` | Logs, custom data |
| `errors` | `StreamEvent::Error` via `StreamSubscriber` | Error messages |

**Default:** `types=events,tokens,progress,data,errors` (all types)

**Implementation:** Endpoint merges `StreamSubscriber::subscribe(workflow_id)` and `EventSubscriber::subscribe(EventPattern::for_workflow(tenant_id, workflow_id))` based on requested types.

**New tenant-scoped endpoint (Deferred to M1):**
```
GET /events/stream?types=workflow.*,task.*
```

Subscribe to all lifecycle events for the tenant, filtered by event type pattern.

### Migration: Existing Lifecycle Event Publishers

Places that currently publish lifecycle events via `StreamEvent` with `StateEventPayload` should migrate to use `EventPublisher`:

| Location | Current | After M0 |
|----------|---------|----------|
| `workflow_dispatch.rs` | `stream_publisher.publish(StreamEvent::Data(StateEventPayload))` | `event_publisher.publish(FlovynEvent)` |
| `task_execution.rs` | `stream_publisher.publish(StreamEvent::Data(StateEventPayload))` | `event_publisher.publish(FlovynEvent)` |
| `scheduler.rs` | `stream_publisher.publish(StreamEvent::Data(StateEventPayload))` | `event_publisher.publish(FlovynEvent)` |

## Migration Plan

### Step 1: Add new types (non-breaking)

1. Create `flovyn-server/server/src/streaming/event.rs`:
   - `FlovynEvent` struct
   - `EventPattern` struct with `matches()` method
2. Add to `mod.rs`:
   - `EventPublisher` trait
   - `EventSubscriber` trait
3. Re-export from `mod.rs`

**Verification:** `cargo check` passes.

### Step 2: Extend existing implementations (non-breaking)

1. `InMemoryStreaming`:
   - Add `event_channels: RwLock<HashMap<Uuid, broadcast::Sender<FlovynEvent>>>`
   - Implement `EventPublisher` and `EventSubscriber` traits
   - Update `cleanup_inactive_channels()` to clean both channel types

2. `NatsStreaming`:
   - Add `build_event_subject()` and `build_event_subscription_subject()` methods
   - Implement `EventPublisher` and `EventSubscriber` traits

**Verification:** All existing tests still pass.

### Step 3: Add unit tests

1. In `in_memory.rs`:
   - `test_publish_and_subscribe_event`
   - `test_event_pattern_filtering`
   - `test_tenant_isolation`
   - `test_cleanup_event_channels`

2. In `nats.rs`:
   - `test_build_event_subject`
   - `test_build_event_subscription_subject`

**Verification:** `cargo test streaming` passes.

### Step 4: Migrate existing lifecycle event publishers

1. Update `workflow_dispatch.rs` to use `EventPublisher::publish(FlovynEvent)` for lifecycle events
2. Update `task_execution.rs` to use `EventPublisher::publish(FlovynEvent)` for lifecycle events
3. Update `scheduler.rs` to use `EventPublisher::publish(FlovynEvent)` for lifecycle events
4. Keep `StreamEventPublisher` for Token/Progress/Data/Error events

**Verification:** Existing integration tests still pass.

### Step 5: Integration tests

1. Create `flovyn-server/server/tests/integration/event_bus_tests.rs`
2. Ensure existing streaming tests still pass
3. Add event bus tests

**Verification:** `cargo test --test integration_tests` passes.

## Testing Strategy

### Unit Tests (in-memory only)

These go in `flovyn-server/server/src/streaming/in_memory.rs`:

```rust
#[cfg(test)]
mod tests {
    // ... existing tests remain unchanged ...

    #[tokio::test]
    async fn test_publish_and_subscribe_event() {
        let streaming = InMemoryStreaming::new();
        let tenant_id = Uuid::new_v4();

        let mut stream = EventSubscriber::subscribe(&*streaming, EventPattern::all(tenant_id));

        let event = FlovynEvent::new(
            tenant_id,
            "workflow.completed",
            "system",
            json!({"workflow_id": "wf-123"}),
        );
        EventPublisher::publish(&*streaming, event).await.unwrap();

        let received = timeout(Duration::from_secs(1), stream.next())
            .await
            .expect("timeout")
            .expect("no event");
        assert_eq!(received.event_type, "workflow.completed");
    }

    #[tokio::test]
    async fn test_event_pattern_filtering_by_type() {
        let streaming = InMemoryStreaming::new();
        let tenant_id = Uuid::new_v4();

        let mut stream = EventSubscriber::subscribe(
            &*streaming,
            EventPattern::by_type(tenant_id, "workflow")
        );

        // Should receive
        EventPublisher::publish(&*streaming, FlovynEvent::new(
            tenant_id, "workflow.completed", "system", json!({})
        )).await.unwrap();

        // Should NOT receive (different prefix)
        EventPublisher::publish(&*streaming, FlovynEvent::new(
            tenant_id, "task.started", "system", json!({})
        )).await.unwrap();

        let received = timeout(Duration::from_millis(100), stream.next())
            .await.unwrap().unwrap();
        assert!(received.event_type.starts_with("workflow"));

        // Verify no more events
        let result = timeout(Duration::from_millis(50), stream.next()).await;
        assert!(result.is_err(), "should timeout - no more events");
    }

    #[tokio::test]
    async fn test_event_tenant_isolation() {
        let streaming = InMemoryStreaming::new();
        let tenant_a = Uuid::new_v4();
        let tenant_b = Uuid::new_v4();

        let mut stream_a = EventSubscriber::subscribe(&*streaming, EventPattern::all(tenant_a));

        // Publish to tenant B
        EventPublisher::publish(&*streaming, FlovynEvent::new(
            tenant_b, "test.event", "system", json!({})
        )).await.unwrap();

        // Tenant A should not receive it
        let result = timeout(Duration::from_millis(50), stream_a.next()).await;
        assert!(result.is_err(), "tenant A should not receive tenant B events");
    }

    #[tokio::test]
    async fn test_cleanup_includes_event_channels() {
        let streaming = InMemoryStreaming::new();
        let tenant_id = Uuid::new_v4();

        {
            let _stream = EventSubscriber::subscribe(&*streaming, EventPattern::all(tenant_id));
        }

        streaming.cleanup_inactive_channels();
        // Event channel should be cleaned up
    }
}
```

### Integration Tests

**Regression tests** (ensure SSE streaming still works):

These tests already exist or should be verified in `server/tests/integration/`:
- Existing streaming tests continue to pass without modification

**New event bus tests** (in `event_bus_tests.rs`):

| Test | Description |
|------|-------------|
| `test_event_bus_publish_subscribe_in_memory` | Basic pub/sub works |
| `test_event_bus_pattern_filtering_in_memory` | Pattern filtering works |
| `test_event_bus_tenant_isolation_in_memory` | Tenants are isolated |
| `test_event_bus_publish_subscribe_nats` | Same with NATS backend |
| `test_event_bus_pattern_filtering_nats` | Same with NATS backend |
| `test_event_bus_tenant_isolation_nats` | Same with NATS backend |

**Note:** End-to-end tests (workflow completion → event published) are deferred to Milestone 1 when we actually wire up event publishing to workflow lifecycle.

## Decisions

1. **Separate concerns**: Generic streaming (`StreamEvent`) and lifecycle events (`FlovynEvent`) are distinct systems
   - Generic streaming: LLM tokens, logs, progress - workflow-scoped, ephemeral
   - Event bus: Lifecycle events - tenant-scoped, structured, routable

2. **Additive change**: Add new `EventPublisher`/`EventSubscriber` traits alongside existing `StreamEventPublisher`/`StreamSubscriber`
   - No breaking changes to existing streaming
   - Same struct (`InMemoryStreaming`, `NatsStreaming`) implements all traits

3. **Channel capacity**
   - Stream channels: 256 (per-workflow)
   - Event bus channels: 1024 (per-tenant, higher volume)

4. **Event persistence**: Deferred to Milestone 5
   - M0 is fire-and-forget only

5. **Metrics**: Deferred to after M0 functionality works

## Open Questions

1. **Event type naming convention**: Use dots (`workflow.completed`) consistent with NATS subject hierarchy

2. **Migrate `StateEventPayload` to `FlovynEvent`**: In M1, lifecycle events currently sent via `StreamEvent` with type `Data` should move to `FlovynEvent`. This includes:
   - TASK_CREATED, TASK_STARTED, TASK_COMPLETED, TASK_FAILED
   - WORKFLOW_STARTED, WORKFLOW_COMPLETED, WORKFLOW_FAILED
   - Timer and promise events

## Exit Criteria

M0 is complete when:

1. ✅ `FlovynEvent` and `EventPattern` types exist in `flovyn-server/streaming/event.rs`
2. ✅ `EventPublisher` and `EventSubscriber` traits exist
3. ✅ `InMemoryStreaming` implements both new traits
4. ✅ `NatsStreaming` implements both new traits
5. ✅ Existing lifecycle event publishers migrated to `EventPublisher`
6. ✅ Existing SSE endpoints updated with `types` param
7. ✅ All existing streaming tests still pass (no regression)
8. ✅ New unit tests for event bus functionality pass
9. ✅ Integration tests verify event bus works with both backends

**What M0 does NOT include:**
- No persistence or replay (deferred to M5)
- No metrics
- No tenant-scoped SSE endpoint `GET /events/stream` (deferred to M1)

## References

- [Eventhook Research](../research/eventhook/20251231_research.md) - Full research document
- [Eventhook Roadmap](../research/eventhook/20251231_roadmap.md) - Milestone overview
- Current streaming: `server/src/streaming/`
- Current event types: `flovyn-server/server/src/domain/task_stream.rs`
