# Task Streaming - Server Implementation

## Overview

This document describes the server-side implementation for real-time task streaming in the Rust server. The design aligns with the existing Kotlin server implementation.

## Related Documents

- **SDK Design**: `sdk-rust/.dev/docs/design/task-streaming.md` - SDK-side design
- **Kotlin Reference**: `leanapp/flovyn/server/app/src/main/kotlin/ai/flovyn/streaming/` - Kotlin implementation

---

## 1. Architecture Overview

The Kotlin server uses an **ephemeral streaming** model:
- Events are **not persisted** to database
- Events are delivered in **real-time only** via pub/sub
- Reconnecting clients **miss events** that occurred while disconnected
- Supports **NATS** (production) and **in-memory** (testing) backends

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              Flovyn Server                               │
│                                                                          │
│  ┌──────────────┐    ┌─────────────────┐    ┌─────────────────────────┐ │
│  │   gRPC API   │    │  StreamTaskData │    │   StreamEventPublisher  │ │
│  │              │───▶│   Handler       │───▶│   (NATS or InMemory)    │ │
│  │  (SDK calls) │    │                 │    │                         │ │
│  └──────────────┘    └─────────────────┘    └───────────┬─────────────┘ │
│                                                         │               │
│                                                         ▼               │
│                                             ┌─────────────────────────┐ │
│                                             │   StreamSubscriber      │ │
│                                             │   (NATS or InMemory)    │ │
│                                             └───────────┬─────────────┘ │
│                                                         │               │
│                                                         ▼               │
│                                             ┌─────────────────────────┐ │
│                                             │   SSE Controller        │ │
│                                             │   (HTTP Endpoint)       │ │
│                                             └───────────┬─────────────┘ │
└─────────────────────────────────────────────────────────┼───────────────┘
                                                          │
                                                          ▼
                                                  ┌─────────────┐
                                                  │   Clients   │
                                                  │  (Browser,  │
                                                  │   Apps)     │
                                                  └─────────────┘
```

**Flow** (aligned with Kotlin):
1. SDK sends `StreamTaskData` gRPC request
2. Server publishes to pub/sub (NATS or in-memory)
3. SSE subscribers receive events in real-time
4. No persistence - events are fire-and-forget

---

## 2. Domain Model

Aligned with Kotlin's `TaskStreamEvent`:

```rust
// src/domain/task_stream.rs

use serde::{Deserialize, Serialize};

/// Stream event emitted by tasks during execution.
/// These events are ephemeral and not persisted.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskStreamEvent {
    pub task_execution_id: String,
    pub workflow_execution_id: String,
    pub sequence: i32,
    #[serde(rename = "type")]
    pub event_type: StreamEventType,
    pub payload: String,
    pub timestamp_ms: i64,
}

/// Type of stream event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum StreamEventType {
    Token,
    Progress,
    Data,
    Error,
}

impl StreamEventType {
    pub fn from_proto(value: i32) -> Option<Self> {
        match value {
            1 => Some(Self::Token),
            2 => Some(Self::Progress),
            3 => Some(Self::Data),
            4 => Some(Self::Error),
            _ => None,
        }
    }
}
```

---

## 3. Pub/Sub Traits

Following Kotlin's `StreamEventPublisher` and `StreamSubscriber` interfaces:

```rust
// src/streaming/mod.rs

use crate::domain::task_stream::TaskStreamEvent;
use async_trait::async_trait;
use tokio_stream::Stream;
use std::pin::Pin;

/// Publishes stream events to connected clients.
///
/// Implementations can use different backends:
/// - NatsStreamEventPublisher: NATS Pub/Sub (production)
/// - InMemoryStreamEventPublisher: In-memory (testing)
#[async_trait]
pub trait StreamEventPublisher: Send + Sync {
    /// Publish a stream event to subscribers.
    async fn publish(&self, event: TaskStreamEvent) -> Result<(), StreamError>;
}

/// Subscribes to stream events for workflows.
///
/// Implementations can use different backends:
/// - NatsStreamSubscriber: NATS Pub/Sub (production)
/// - InMemoryStreamSubscriber: In-memory (testing)
pub trait StreamSubscriber: Send + Sync {
    /// Subscribe to stream events for a specific workflow.
    fn subscribe(&self, workflow_execution_id: &str) -> Pin<Box<dyn Stream<Item = TaskStreamEvent> + Send>>;
}

#[derive(Debug, thiserror::Error)]
pub enum StreamError {
    #[error("Failed to publish event: {0}")]
    PublishError(String),
    #[error("Connection error: {0}")]
    ConnectionError(String),
}
```

---

## 4. In-Memory Implementation (Testing/Development)

For testing and single-instance deployments:

```rust
// src/streaming/in_memory.rs

use crate::domain::task_stream::TaskStreamEvent;
use crate::streaming::{StreamEventPublisher, StreamSubscriber, StreamError};
use async_trait::async_trait;
use parking_lot::RwLock;
use std::collections::HashMap;
use std::pin::Pin;
use std::sync::Arc;
use tokio::sync::broadcast;
use tokio_stream::{Stream, StreamExt, wrappers::BroadcastStream};

const CHANNEL_CAPACITY: usize = 256;

/// In-memory streaming backend for testing and development.
pub struct InMemoryStreaming {
    /// Channels keyed by workflow execution ID
    channels: RwLock<HashMap<String, broadcast::Sender<TaskStreamEvent>>>,
}

impl InMemoryStreaming {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            channels: RwLock::new(HashMap::new()),
        })
    }

    fn get_or_create_channel(&self, workflow_execution_id: &str) -> broadcast::Sender<TaskStreamEvent> {
        let mut channels = self.channels.write();
        channels
            .entry(workflow_execution_id.to_string())
            .or_insert_with(|| broadcast::channel(CHANNEL_CAPACITY).0)
            .clone()
    }

    /// Cleanup inactive channels (call periodically)
    pub fn cleanup_inactive_channels(&self) {
        self.channels.write().retain(|_, tx| tx.receiver_count() > 0);
    }
}

#[async_trait]
impl StreamEventPublisher for InMemoryStreaming {
    async fn publish(&self, event: TaskStreamEvent) -> Result<(), StreamError> {
        let tx = self.get_or_create_channel(&event.workflow_execution_id);
        // Ignore send errors - means no active subscribers
        let _ = tx.send(event);
        Ok(())
    }
}

impl StreamSubscriber for InMemoryStreaming {
    fn subscribe(&self, workflow_execution_id: &str) -> Pin<Box<dyn Stream<Item = TaskStreamEvent> + Send>> {
        let tx = self.get_or_create_channel(workflow_execution_id);
        let rx = tx.subscribe();

        let stream = BroadcastStream::new(rx)
            .filter_map(|result| result.ok());

        Box::pin(stream)
    }
}
```

---

## 5. NATS Implementation (Production)

For production with multiple server instances:

```rust
// src/streaming/nats.rs

use crate::domain::task_stream::TaskStreamEvent;
use crate::streaming::{StreamEventPublisher, StreamSubscriber, StreamError};
use async_nats::Client;
use async_trait::async_trait;
use std::pin::Pin;
use std::sync::Arc;
use tokio_stream::{Stream, StreamExt};

/// NATS-based streaming for production use.
///
/// Uses plain NATS pub/sub (not JetStream) for real-time streaming.
/// - No persistence: Events are lost if no subscriber is active
/// - No replay: Reconnecting clients miss events
/// - Fire-and-forget: No delivery guarantees
pub struct NatsStreaming {
    client: Client,
}

impl NatsStreaming {
    pub async fn new(nats_url: &str) -> Result<Arc<Self>, StreamError> {
        let client = async_nats::connect(nats_url)
            .await
            .map_err(|e| StreamError::ConnectionError(e.to_string()))?;

        Ok(Arc::new(Self { client }))
    }

    fn build_subject(workflow_execution_id: &str) -> String {
        format!("flovyn.streams.workflow.{}", workflow_execution_id)
    }
}

#[async_trait]
impl StreamEventPublisher for NatsStreaming {
    async fn publish(&self, event: TaskStreamEvent) -> Result<(), StreamError> {
        let subject = Self::build_subject(&event.workflow_execution_id);
        let payload = serde_json::to_vec(&event)
            .map_err(|e| StreamError::PublishError(e.to_string()))?;

        self.client
            .publish(subject, payload.into())
            .await
            .map_err(|e| StreamError::PublishError(e.to_string()))?;

        self.client
            .flush()
            .await
            .map_err(|e| StreamError::PublishError(e.to_string()))?;

        Ok(())
    }
}

impl StreamSubscriber for NatsStreaming {
    fn subscribe(&self, workflow_execution_id: &str) -> Pin<Box<dyn Stream<Item = TaskStreamEvent> + Send>> {
        let subject = Self::build_subject(workflow_execution_id);
        let client = self.client.clone();

        let stream = async_stream::stream! {
            match client.subscribe(subject.clone()).await {
                Ok(mut subscription) => {
                    while let Some(message) = subscription.next().await {
                        match serde_json::from_slice::<TaskStreamEvent>(&message.payload) {
                            Ok(event) => yield event,
                            Err(e) => {
                                tracing::error!(error = %e, "Failed to deserialize stream event");
                            }
                        }
                    }
                }
                Err(e) => {
                    tracing::error!(error = %e, subject = %subject, "Failed to subscribe to NATS subject");
                }
            }
        };

        Box::pin(stream)
    }
}
```

---

## 6. gRPC Handler

Update `stream_task_data` implementation:

```rust
// src/api/grpc/task_execution.rs

use crate::streaming::StreamEventPublisher;

impl TaskExecutionServiceImpl {
    // Add to struct:
    // pub stream_publisher: Arc<dyn StreamEventPublisher>,
}

#[tonic::async_trait]
impl TaskExecution for TaskExecutionServiceImpl {
    async fn stream_task_data(
        &self,
        request: Request<StreamTaskDataRequest>,
    ) -> Result<Response<StreamTaskDataResponse>, Status> {
        let req = request.into_inner();

        // Validate event type
        let event_type = StreamEventType::from_proto(req.r#type)
            .ok_or_else(|| Status::invalid_argument("Invalid event type"))?;

        // Create event (aligned with Kotlin's TaskStreamEvent)
        let event = TaskStreamEvent {
            task_execution_id: req.task_execution_id,
            workflow_execution_id: req.workflow_execution_id,
            sequence: req.sequence,
            event_type,
            payload: req.payload,
            timestamp_ms: req.timestamp_ms,
        };

        // Publish to subscribers (fire-and-forget)
        if let Err(e) = self.stream_publisher.publish(event).await {
            tracing::warn!(error = %e, "Failed to publish stream event");
            // Don't fail the request - streaming is best-effort
        }

        Ok(Response::new(StreamTaskDataResponse { acknowledged: true }))
    }
}
```

---

## 7. SSE HTTP Endpoints

Aligned with Kotlin's `StreamingController`:

```rust
// src/api/http/streaming.rs

use axum::{
    extract::{Path, State},
    response::sse::{Event, KeepAlive, Sse},
    http::StatusCode,
};
use futures::stream::Stream;
use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;
use uuid::Uuid;
use tokio_stream::StreamExt;

use crate::app_state::AppState;
use crate::streaming::StreamSubscriber;

/// SSE stream for workflow execution events
/// GET /api/tenants/{tenant_slug}/stream/workflows/{workflow_execution_id}
///
/// Event types: token, progress, data, error
/// Timeout: 5 minutes of inactivity
pub async fn stream_workflow(
    Path((tenant_slug, workflow_execution_id)): Path<(String, String)>,
    State(state): State<Arc<AppState>>,
) -> Result<Sse<impl Stream<Item = Result<Event, Infallible>>>, StatusCode> {
    // Validate UUID format
    let _ = Uuid::parse_str(&workflow_execution_id)
        .map_err(|_| StatusCode::BAD_REQUEST)?;

    // TODO: Validate workflow belongs to tenant (like Kotlin's validateWorkflowBelongsToTenant)

    tracing::info!(
        workflow_execution_id = %workflow_execution_id,
        tenant = %tenant_slug,
        "Starting SSE stream for workflow"
    );

    // Subscribe to stream events
    let event_stream = state.stream_subscriber.subscribe(&workflow_execution_id);

    let sse_stream = event_stream.map(|event| {
        let event_type = match event.event_type {
            StreamEventType::Token => "token",
            StreamEventType::Progress => "progress",
            StreamEventType::Data => "data",
            StreamEventType::Error => "error",
        };

        Ok(Event::default()
            .event(event_type)
            .data(event.payload)
            .id(event.sequence.to_string()))
    });

    Ok(Sse::new(sse_stream).keep_alive(
        KeepAlive::new()
            .interval(Duration::from_secs(15))
            .text("keep-alive"),
    ))
}

/// Consolidated SSE stream for workflow and all child workflows
/// GET /api/tenants/{tenant_slug}/stream/workflows/{workflow_execution_id}/consolidated
pub async fn stream_workflow_consolidated(
    Path((tenant_slug, workflow_execution_id)): Path<(String, String)>,
    State(state): State<Arc<AppState>>,
) -> Result<Sse<impl Stream<Item = Result<Event, Infallible>>>, StatusCode> {
    // Validate UUID format
    let _ = Uuid::parse_str(&workflow_execution_id)
        .map_err(|_| StatusCode::BAD_REQUEST)?;

    tracing::info!(
        workflow_execution_id = %workflow_execution_id,
        tenant = %tenant_slug,
        "Starting consolidated SSE stream for workflow"
    );

    // Subscribe to stream events
    // TODO: Add child workflow discovery and streaming
    let event_stream = state.stream_subscriber.subscribe(&workflow_execution_id);

    let sse_stream = event_stream.map(|event| {
        let event_type = match event.event_type {
            StreamEventType::Token => "token",
            StreamEventType::Progress => "progress",
            StreamEventType::Data => "data",
            StreamEventType::Error => "error",
        };

        // Include source workflow ID in consolidated stream
        let consolidated_payload = serde_json::json!({
            "workflowExecutionId": event.workflow_execution_id,
            "data": event.payload,
        });

        Ok(Event::default()
            .event(event_type)
            .data(consolidated_payload.to_string())
            .id(format!("{}:{}", event.workflow_execution_id, event.sequence)))
    });

    Ok(Sse::new(sse_stream).keep_alive(
        KeepAlive::new()
            .interval(Duration::from_secs(15))
            .text("keep-alive"),
    ))
}
```

### Router Configuration

```rust
// src/api/http/mod.rs

use axum::{routing::get, Router};

pub fn streaming_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route(
            "/api/tenants/:tenant_slug/stream/workflows/:workflow_execution_id",
            get(streaming::stream_workflow)
        )
        .route(
            "/api/tenants/:tenant_slug/stream/workflows/:workflow_execution_id/consolidated",
            get(streaming::stream_workflow_consolidated)
        )
}
```

---

## 8. AppState Integration

```rust
// src/app_state.rs

use crate::streaming::{StreamEventPublisher, StreamSubscriber, InMemoryStreaming};
use std::sync::Arc;

pub struct AppState {
    // ... existing fields ...

    /// Stream event publisher (publishes to subscribers)
    pub stream_publisher: Arc<dyn StreamEventPublisher>,

    /// Stream subscriber (for SSE endpoints)
    pub stream_subscriber: Arc<dyn StreamSubscriber>,
}

impl AppState {
    pub fn new(/* ... */) -> Self {
        // Use in-memory streaming by default
        // For production, use NatsStreaming
        let streaming = InMemoryStreaming::new();

        Self {
            // ... existing ...
            stream_publisher: streaming.clone(),
            stream_subscriber: streaming,
        }
    }

    pub async fn new_with_nats(nats_url: &str /* ... */) -> Result<Self, Error> {
        let streaming = NatsStreaming::new(nats_url).await?;

        Ok(Self {
            // ... existing ...
            stream_publisher: streaming.clone(),
            stream_subscriber: streaming,
        })
    }
}
```

---

## 9. Configuration

```toml
# config/default.toml

[streaming]
# Backend: "memory" or "nats"
backend = "memory"

# NATS URL (only used when backend = "nats")
nats_url = "nats://localhost:4222"

# Channel capacity for in-memory backend
channel_capacity = 256

# SSE keep-alive interval in seconds
keep_alive_interval_seconds = 15

# SSE timeout in milliseconds (5 minutes)
timeout_ms = 300000
```

---

## 10. Metrics

```rust
// src/infrastructure/metrics.rs

lazy_static! {
    pub static ref STREAM_EVENTS_PUBLISHED: IntCounter = register_int_counter!(
        "flovyn_stream_events_published_total",
        "Total stream events published"
    ).unwrap();

    pub static ref STREAM_SUBSCRIBERS_ACTIVE: IntGauge = register_int_gauge!(
        "flovyn_stream_subscribers_active",
        "Current number of active SSE subscribers"
    ).unwrap();

    pub static ref STREAM_EVENTS_DELIVERED: IntCounter = register_int_counter!(
        "flovyn_stream_events_delivered_total",
        "Total stream events delivered to subscribers"
    ).unwrap();
}
```

---

## 11. Key Design Decisions (Aligned with Kotlin)

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| **Persistence** | None (ephemeral) | Events are for real-time UI updates, not audit logs |
| **Replay** | Not supported | Clients must stay connected; reduces complexity |
| **Backend** | NATS or In-memory | NATS for multi-instance, in-memory for testing |
| **Delivery** | Fire-and-forget | Simplicity over guaranteed delivery |
| **Subject routing** | Per workflow | `flovyn.streams.workflow.{id}` |

---

## 12. Implementation Plan

### Phase 1: Domain Model
- [ ] Add `TaskStreamEvent` struct
- [ ] Add `StreamEventType` enum

### Phase 2: Pub/Sub Traits
- [ ] Define `StreamEventPublisher` trait
- [ ] Define `StreamSubscriber` trait
- [ ] Define `StreamError` type

### Phase 3: In-Memory Backend
- [ ] Implement `InMemoryStreaming`
- [ ] Write unit tests

### Phase 4: gRPC Handler
- [ ] Update `stream_task_data` to publish events
- [ ] Add `stream_publisher` to service impl
- [ ] Write integration tests

### Phase 5: SSE Endpoints
- [ ] Implement `stream_workflow` handler
- [ ] Implement `stream_workflow_consolidated` handler
- [ ] Add routes to HTTP router
- [ ] Write integration tests

### Phase 6: NATS Backend (Optional for Phase 1)
- [ ] Add `async-nats` dependency
- [ ] Implement `NatsStreaming`
- [ ] Write integration tests with NATS

### Phase 7: Observability
- [ ] Add metrics
- [ ] Add tracing spans

### Phase 8: E2E Testing
- [ ] Test with Rust SDK streaming
- [ ] Test SSE from browser/curl
