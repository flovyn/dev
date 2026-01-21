# Task Streaming Implementation Plan

## Overview

Implementation plan for task streaming as designed in [task-streaming-implementation.md](../design/task-streaming-implementation.md).

**Approach**: Test-first development. Each phase starts with tests that define expected behavior, then implements to make tests pass.

**Scope**: Server-side implementation only. SDK changes are out of scope.

---

## Critical Considerations (Not Covered in Design)

1. **Authentication for SSE endpoints**: SSE endpoints need auth. Use the existing `AuthStack` with HTTP middleware.
2. **Tenant validation**: Must verify workflow belongs to requesting tenant before streaming.
3. **Connection lifecycle**: Handle SSE client disconnects gracefully, clean up resources.
4. **Timeout enforcement**: Use `tokio::time::timeout` wrapper around the stream.
5. **GrpcState integration**: The gRPC service uses `GrpcState`, not `AppState`. Need to add `stream_publisher` to `GrpcState`.
6. **Backend selection**: Use existing `NatsConfig.enabled` flag to choose between in-memory and NATS.
7. **Dependencies**: Need to add `async-stream` crate.

---

## TODO List

### Phase 1: Domain Model

- [x] 1.1 Create `flovyn-server/src/domain/task_stream.rs` with `TaskStreamEvent` struct
- [x] 1.2 Add `StreamEventType` enum with proto conversion
- [x] 1.3 Add unit tests for `StreamEventType::from_proto`
- [x] 1.4 Export module from `flovyn-server/src/domain/mod.rs`

### Phase 2: Streaming Traits

- [x] 2.1 Create `flovyn-server/src/streaming/mod.rs` with module structure
- [x] 2.2 Define `StreamEventPublisher` trait
- [x] 2.3 Define `StreamSubscriber` trait
- [x] 2.4 Define `StreamError` type with `thiserror`

### Phase 3: In-Memory Backend

- [x] 3.1 Create `flovyn-server/src/streaming/in_memory.rs`
- [x] 3.2 Implement `InMemoryStreaming` struct with broadcast channels
- [x] 3.3 Implement `StreamEventPublisher` for `InMemoryStreaming`
- [x] 3.4 Implement `StreamSubscriber` for `InMemoryStreaming`
- [x] 3.5 Add `cleanup_inactive_channels` method
- [x] 3.6 Write unit tests for publish/subscribe flow
- [x] 3.7 Write unit tests for multiple subscribers
- [x] 3.8 Write unit tests for subscriber disconnect handling

### Phase 4: gRPC Handler Update

- [x] 4.1 Add `stream_publisher: Arc<dyn StreamEventPublisher>` to `GrpcState`
- [x] 4.2 Update `GrpcState::new()` to accept stream publisher
- [x] 4.3 Implement `stream_task_data` RPC in `TaskExecutionServiceImpl`
- [x] 4.4 Validate event type from proto
- [x] 4.5 Create `TaskStreamEvent` from request
- [x] 4.6 Publish event (fire-and-forget with warning on error)
- [ ] 4.7 Write unit test for successful stream_task_data (deferred - requires SDK changes)
- [ ] 4.8 Write unit test for invalid event type rejection (deferred - requires SDK changes)

### Phase 5: SSE HTTP Endpoints

- [x] 5.1 Create `flovyn-server/src/api/rest/streaming.rs` module
- [x] 5.2 Add `stream_subscriber: Arc<dyn StreamSubscriber>` to `AppState`
- [x] 5.3 Implement `stream_workflow` SSE handler
- [x] 5.4 Add UUID validation for workflow_execution_id
- [x] 5.5 Implement tenant ownership validation (query workflow, check tenant)
- [x] 5.6 Map `TaskStreamEvent` to SSE `Event` with event type, data, id
- [x] 5.7 Configure keep-alive (15 second interval)
- [x] 5.8 Add timeout wrapper (5 minutes)
- [x] 5.9 Add route to HTTP router with auth middleware
- [x] 5.10 Write integration test: SSE endpoint returns events from publisher

### Phase 6: Consolidated Stream

- [x] 6.1 Implement `stream_workflow_consolidated` SSE handler
- [x] 6.2 Query child workflows from database
- [x] 6.3 Merge multiple workflow streams using `tokio_stream::StreamExt::merge`
- [x] 6.4 Include source workflow ID in event payload
- [x] 6.5 Add route to HTTP router
- [ ] 6.6 Write integration test: consolidated stream includes child workflow events (deferred)

### Phase 7: NATS Backend

- [x] 7.1 Add `async-stream` to Cargo.toml
- [x] 7.2 Create `flovyn-server/src/streaming/nats.rs`
- [x] 7.3 Implement `NatsStreaming::new()` with connection
- [x] 7.4 Implement subject naming: `flovyn.streams.workflow.{id}`
- [x] 7.5 Implement `StreamEventPublisher` for `NatsStreaming`
- [x] 7.6 Implement `StreamSubscriber` for `NatsStreaming`
- [x] 7.7 Add flush after publish for guaranteed delivery
- [ ] 7.8 Write integration test with NATS testcontainer (deferred)

### Phase 8: Backend Selection & Configuration

- [x] 8.1 Reuse existing `NatsConfig.enabled` for backend selection
- [x] 8.2 Update `main.rs` to initialize streaming backend based on config
- [x] 8.3 Pass streaming to both `AppState` and `GrpcState`
- [ ] 8.4 Write test for in-memory selection when NATS disabled (deferred)
- [ ] 8.5 Write test for NATS selection when NATS enabled (deferred)

### Phase 9: Observability (Deferred)

- [ ] 9.1 Add `flovyn_stream_events_published_total` counter metric
- [ ] 9.2 Add `flovyn_stream_subscribers_active` gauge metric
- [ ] 9.3 Add `flovyn_stream_events_delivered_total` counter metric
- [ ] 9.4 Increment metrics in streaming implementations
- [x] 9.5 Add tracing spans for SSE handlers (basic tracing added)
- [x] 9.6 Add tracing for publish/subscribe operations (basic tracing added)
- [ ] 9.7 Write test verifying metrics are recorded

### Phase 10: Integration Tests

- [x] 10.1 Integration test: SSE endpoint exists and returns correct content-type
- [x] 10.2 Integration test: SSE endpoint returns 404 for non-existent workflow
- [x] 10.3 Integration test: SSE endpoint returns 400 for invalid workflow ID
- [ ] 10.4 Integration test: Authentication required for SSE endpoints
- [ ] 10.5 Integration test: Tenant isolation (can't stream other tenant's workflow)

### Phase 11: E2E Tests

- [ ] 11.1 E2E test: Full flow with Docker image and curl SSE client
- [ ] 11.2 E2E test: Token streaming from task to SSE
- [ ] 11.3 E2E test: NATS backend with multiple server instances

---

## Phase Details

### Phase 1: Domain Model

**Goal**: Create the core data types for stream events.

**Files to create**:
- `flovyn-server/src/domain/task_stream.rs`

**Test first** (`flovyn-server/src/domain/task_stream.rs`):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_stream_event_type_from_proto_token() {
        assert_eq!(StreamEventType::from_proto(1), Some(StreamEventType::Token));
    }

    #[test]
    fn test_stream_event_type_from_proto_progress() {
        assert_eq!(StreamEventType::from_proto(2), Some(StreamEventType::Progress));
    }

    #[test]
    fn test_stream_event_type_from_proto_invalid() {
        assert_eq!(StreamEventType::from_proto(0), None);
        assert_eq!(StreamEventType::from_proto(99), None);
    }

    #[test]
    fn test_task_stream_event_serialization() {
        let event = TaskStreamEvent {
            task_execution_id: "task-1".to_string(),
            workflow_execution_id: "wf-1".to_string(),
            sequence: 1,
            event_type: StreamEventType::Token,
            payload: "hello".to_string(),
            timestamp_ms: 1234567890,
        };

        let json = serde_json::to_string(&event).unwrap();
        assert!(json.contains("\"type\":\"TOKEN\""));
        assert!(json.contains("\"taskExecutionId\":\"task-1\""));
    }
}
```

---

### Phase 2: Streaming Traits

**Goal**: Define the abstraction layer for streaming backends.

**Files to create**:
- `flovyn-server/src/streaming/mod.rs`

**Key design**:
- Both `StreamEventPublisher` and `StreamSubscriber` are object-safe traits
- Use `async_trait` for async methods
- Subscriber returns `Pin<Box<dyn Stream>>` for flexibility

---

### Phase 3: In-Memory Backend

**Goal**: Implement the testing/single-instance backend.

**Files to create**:
- `flovyn-server/src/streaming/in_memory.rs`

**Test first**:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tokio_stream::StreamExt;

    #[tokio::test]
    async fn test_publish_and_subscribe() {
        let streaming = InMemoryStreaming::new();
        let workflow_id = "wf-123";

        // Subscribe first
        let mut stream = streaming.subscribe(workflow_id);

        // Publish event
        let event = TaskStreamEvent {
            task_execution_id: "t1".into(),
            workflow_execution_id: workflow_id.into(),
            sequence: 1,
            event_type: StreamEventType::Token,
            payload: "hello".into(),
            timestamp_ms: 1234567890,
        };
        streaming.publish(event.clone()).await.unwrap();

        // Receive event
        let received = stream.next().await.unwrap();
        assert_eq!(received.payload, "hello");
    }

    #[tokio::test]
    async fn test_no_subscriber_doesnt_error() {
        let streaming = InMemoryStreaming::new();

        let event = TaskStreamEvent { /* ... */ };

        // Should not error even with no subscribers
        let result = streaming.publish(event).await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_multiple_subscribers_receive_same_event() {
        let streaming = InMemoryStreaming::new();
        let workflow_id = "wf-123";

        let mut stream1 = streaming.subscribe(workflow_id);
        let mut stream2 = streaming.subscribe(workflow_id);

        let event = TaskStreamEvent { /* ... */ };
        streaming.publish(event).await.unwrap();

        let recv1 = stream1.next().await.unwrap();
        let recv2 = stream2.next().await.unwrap();

        assert_eq!(recv1.sequence, recv2.sequence);
    }
}
```

---

### Phase 4: gRPC Handler Update

**Goal**: Implement the `stream_task_data` RPC.

**Files to modify**:
- `flovyn-server/src/api/grpc/mod.rs` - Add to `GrpcState`
- `flovyn-server/src/api/grpc/task_execution.rs` - Implement RPC

**Implementation notes**:
- Fire-and-forget semantics: always return success to SDK
- Log warning on publish failure, don't fail the RPC
- Validate event type, return `INVALID_ARGUMENT` for unknown types

---

### Phase 5: SSE HTTP Endpoints

**Goal**: Create the SSE endpoints for browser/client consumption.

**Files to create**:
- `flovyn-server/src/api/rest/streaming.rs`

**Files to modify**:
- `flovyn-server/src/api/rest/mod.rs` - Add routes and update `AppState`

**Key implementation details**:

```rust
// Tenant validation - must verify workflow belongs to tenant
async fn validate_workflow_ownership(
    pool: &PgPool,
    tenant_slug: &str,
    workflow_execution_id: Uuid,
) -> Result<(), StatusCode> {
    // Query workflow and check tenant matches
    let workflow = sqlx::query!(
        r#"
        SELECT we.id, t.slug as tenant_slug
        FROM workflow_execution we
        JOIN tenant t ON we.tenant_id = t.id
        WHERE we.id = $1
        "#,
        workflow_execution_id
    )
    .fetch_optional(pool)
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    match workflow {
        Some(w) if w.tenant_slug == tenant_slug => Ok(()),
        Some(_) => Err(StatusCode::FORBIDDEN),
        None => Err(StatusCode::NOT_FOUND),
    }
}
```

**Timeout implementation**:

```rust
use tokio::time::{timeout, Duration};
use tokio_stream::StreamExt;

let timeout_duration = Duration::from_millis(300_000); // 5 minutes

let event_stream = state.stream_subscriber.subscribe(&workflow_execution_id);

// Wrap with timeout that resets on each event
let timed_stream = event_stream.timeout(timeout_duration);

let sse_stream = timed_stream.map(|result| {
    match result {
        Ok(event) => Ok(Event::default().event(...).data(...)),
        Err(_timeout) => {
            // Connection timed out, end stream
            Err(std::convert::Infallible) // This won't actually error
        }
    }
});
```

---

### Phase 6: Consolidated Stream

**Goal**: Stream events from parent and all child workflows.

**Implementation approach**:

```rust
use tokio_stream::StreamExt;

async fn stream_workflow_consolidated(...) {
    // 1. Get parent workflow
    // 2. Query all child workflows
    let child_ids = sqlx::query_scalar!(
        "SELECT id FROM workflow_execution WHERE parent_workflow_execution_id = $1",
        workflow_execution_id
    )
    .fetch_all(&state.pool)
    .await?;

    // 3. Subscribe to parent
    let parent_stream = state.stream_subscriber.subscribe(&workflow_execution_id);

    // 4. Subscribe to all children and merge
    let child_streams: Vec<_> = child_ids
        .iter()
        .map(|id| state.stream_subscriber.subscribe(&id.to_string()))
        .collect();

    let merged = child_streams
        .into_iter()
        .fold(parent_stream, |acc, s| Box::pin(acc.merge(s)));

    // 5. Map to SSE with source workflow ID
    // ...
}
```

**Note**: Child workflows started after SSE connection is established won't be included. This is acceptable per the ephemeral streaming model.

---

### Phase 7: NATS Backend

**Goal**: Production backend for multi-instance deployments.

**Files to create**:
- `flovyn-server/src/streaming/nats.rs`

**Dependencies to add**:

```toml
# Cargo.toml
async-stream = "0.3"
```

**Key implementation notes**:
- Use plain NATS pub/sub (not JetStream)
- Flush after each publish for immediate delivery
- Handle subscription errors gracefully in the stream

---

### Phase 8: Backend Selection

**Goal**: Wire streaming into the server startup.

**Files to modify**:
- `flovyn-server/src/main.rs`

**Implementation**:

```rust
// In main.rs

let (stream_publisher, stream_subscriber): (
    Arc<dyn StreamEventPublisher>,
    Arc<dyn StreamSubscriber>,
) = if config.nats.enabled {
    let nats = NatsStreaming::new(&config.nats.url).await?;
    (nats.clone(), nats)
} else {
    let mem = InMemoryStreaming::new();
    (mem.clone(), mem)
};

// Pass to both states
let app_state = AppState {
    // ...existing fields...
    stream_subscriber: stream_subscriber.clone(),
};

let grpc_state = GrpcState {
    // ...existing fields...
    stream_publisher,
};
```

---

### Phase 9: Observability

**Goal**: Add metrics and tracing for streaming.

**Files to modify**:
- `flovyn-server/src/infrastructure/metrics.rs` (or wherever metrics are defined)
- `flovyn-server/src/streaming/in_memory.rs`
- `flovyn-server/src/streaming/nats.rs`

**Metrics to add**:

```rust
// Use existing metrics infrastructure
use metrics::{counter, gauge};

// In StreamEventPublisher::publish
counter!("flovyn_stream_events_published_total").increment(1);

// In StreamSubscriber::subscribe (track active)
gauge!("flovyn_stream_subscribers_active").increment(1.0);

// On subscriber drop (need to track with wrapper)
gauge!("flovyn_stream_subscribers_active").decrement(1.0);
```

---

### Phase 10: Integration Tests

**Goal**: Test the full server-side flow.

**Test file**: `flovyn-server/tests/integration/streaming_tests.rs`

**Test approach**:
- Start server with testcontainers (PostgreSQL)
- Use gRPC client to call `stream_task_data`
- Use HTTP client to connect to SSE endpoint
- Verify events flow through

```rust
#[tokio::test]
async fn test_stream_data_to_sse() {
    let harness = TestHarness::start().await;

    // Create workflow
    let workflow_id = harness.create_workflow("test-wf").await;

    // Start SSE listener in background
    let (tx, mut rx) = tokio::sync::mpsc::channel(10);
    let sse_handle = tokio::spawn({
        let url = format!(
            "{}/api/tenants/{}/stream/workflows/{}",
            harness.http_url(), harness.tenant_slug(), workflow_id
        );
        async move {
            let client = reqwest::Client::new();
            let mut response = client.get(&url).send().await.unwrap();
            while let Some(chunk) = response.chunk().await.unwrap() {
                tx.send(chunk).await.unwrap();
            }
        }
    });

    // Give SSE time to connect
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Stream data via gRPC
    harness.grpc_client()
        .stream_task_data(StreamTaskDataRequest {
            task_execution_id: "task-1".into(),
            workflow_execution_id: workflow_id.to_string(),
            sequence: 1,
            r#type: 1, // TOKEN
            payload: "hello world".into(),
            timestamp_ms: 12345,
        })
        .await
        .unwrap();

    // Verify SSE received event
    let event_data = tokio::time::timeout(Duration::from_secs(5), rx.recv())
        .await
        .expect("timeout")
        .expect("no event");

    assert!(String::from_utf8_lossy(&event_data).contains("hello world"));

    sse_handle.abort();
}
```

---

## File Structure After Implementation

```
src/
├── domain/
│   ├── mod.rs           # Add task_stream export
│   └── task_stream.rs   # NEW: TaskStreamEvent, StreamEventType
│
├── streaming/
│   ├── mod.rs           # NEW: Traits, re-exports
│   ├── in_memory.rs     # NEW: InMemoryStreaming
│   └── nats.rs          # NEW: NatsStreaming
│
├── api/
│   ├── rest/
│   │   ├── mod.rs       # MODIFIED: Add stream_subscriber to AppState, routes
│   │   └── streaming.rs # NEW: SSE handlers
│   │
│   └── grpc/
│       ├── mod.rs              # MODIFIED: Add stream_publisher to GrpcState
│       └── task_execution.rs   # MODIFIED: Implement stream_task_data
│
├── infrastructure/
│   └── metrics.rs       # MODIFIED: Add streaming metrics
│
└── main.rs              # MODIFIED: Initialize streaming backend

tests/
└── integration/
    └── streaming_tests.rs  # NEW: Integration tests
```

---

## Definition of Done

Each phase is complete when:

1. All tests in the phase pass
2. Code compiles with `cargo check`
3. No new clippy warnings (`cargo clippy`)
4. Code is formatted (`cargo fmt`)
5. Existing tests still pass (`./bin/dev/test.sh`)

Final completion criteria:

1. All TODO items checked off
2. `stream_task_data` gRPC RPC is fully implemented
3. SSE endpoints work with authentication
4. In-memory backend works for single instance
5. NATS backend works for multi-instance (tested with testcontainers)
6. Metrics are recorded for streaming operations
7. Integration tests pass
8. E2E tests pass with Docker image
