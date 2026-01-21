# Real-Time API Implementation Plan

## Overview

Implementation plan for real-time state events as designed in [20251228_realtime-api-requirements.md](../design/20251228_realtime_api_requirements.md).

**Status:** All Phases Complete (Task, Workflow, Timer, Promise, Child Workflow Events)

---

## Design Decision Change

**Original plan**: Extend `StreamEventType` enum with new variants (TaskCreated, TaskStarted, etc.)

**Actual implementation**: Use existing `Data` SSE event type with unified payload structure:
```json
{
  "type": "Event",
  "event": "TASK_CREATED",
  "data": { ... snapshot ... },
  "timestampMs": 1234567890
}
```

**Why changed**:
- No changes to `StreamEventType` enum (stays at 4 values)
- Proto unchanged - SDK developers don't see server-only events
- More extensible - adding new events just adds `event` string values
- Supports multiple entity types (workflow, task, timer, promise, child workflow, operation)

---

## TODO List

### Phase 1: Rename Streaming Endpoints ✅

- [x] 1.1 Update route: `/stream/workflows/:id` -> `/workflow-executions/:id/stream`
- [x] 1.2 Update route: `/stream/workflows/:id/consolidated` -> `/workflow-executions/:id/stream/consolidated`
- [x] 1.3 Update route: `/stream/tasks/:id` -> `/task-executions/:id/stream`
- [x] 1.4 Update doc comments in `streaming.rs` to match new paths
- [x] 1.5 Verify routes work with existing tests

### Phase 2: Define Snapshot Types ✅

- [x] 2.1 Create `WorkflowSnapshot` struct
- [x] 2.2 Create `TaskSnapshot` struct (renamed from TaskStatePayload)
- [x] 2.3 Create `TimerSnapshot` struct
- [x] 2.4 Create `PromiseSnapshot` struct
- [x] 2.5 Create `ChildWorkflowSnapshot` struct
- [x] 2.6 Create `OperationSnapshot` struct
- [x] 2.7 Create `StateEventData` enum with all snapshot types
- [x] 2.8 Create `StateEventPayload` struct with unified format
- [x] 2.9 Add unit tests for all serialization

### Phase 3: Add Event Helper Methods ✅

- [x] 3.1 Task events: `task_created`, `task_started`, `task_completed`, `task_failed`, `task_cancelled`
- [x] 3.2 Workflow events: `workflow_created`, `workflow_started`, `workflow_completed`, `workflow_failed`, `workflow_cancelled`, `workflow_suspended`, `workflow_resumed`
- [x] 3.3 Timer events: `timer_started`, `timer_fired`, `timer_cancelled`
- [x] 3.4 Promise events: `promise_created`, `promise_resolved`, `promise_rejected`
- [x] 3.5 Child workflow events: `child_workflow_initiated`, `child_workflow_started`, `child_workflow_completed`, `child_workflow_failed`
- [x] 3.6 Operation events: `operation_completed`
- [x] 3.7 Add unit tests for helper methods

### Phase 4: Update Documentation ✅

- [x] 4.1 Update design document with actual implementation
- [x] 4.2 Update implementation plan (this document)
- [x] 4.3 Create/update `flovyn-server/docs/guides/streaming-events.md` frontend guide

### Phase 5: Publish Events from gRPC Handlers

- [x] 5.1 In `workflow_dispatch.rs` `submit_workflow_commands`: publish TASK_CREATED
- [x] 5.2 In `task_execution.rs` `poll_task`: publish TASK_STARTED
- [x] 5.3 In `task_execution.rs` `complete_task`: publish TASK_COMPLETED
- [x] 5.4 In `task_execution.rs` `fail_task`: publish TASK_FAILED
- [x] 5.5 In `workflow_dispatch.rs` `poll_workflow`: publish WORKFLOW_STARTED
- [x] 5.6 In `workflow_dispatch.rs` `submit_workflow_commands`: publish WORKFLOW_COMPLETED, WORKFLOW_FAILED
- [x] 5.7 Timer events: TIMER_STARTED, TIMER_CANCELLED in workflow_dispatch.rs, TIMER_FIRED in scheduler.rs
- [x] 5.8 Promise events: PROMISE_CREATED, PROMISE_RESOLVED, PROMISE_REJECTED in workflow_dispatch.rs
- [x] 5.9 Child workflow events: CHILD_WORKFLOW_INITIATED in workflow_dispatch.rs, CHILD_WORKFLOW_COMPLETED/FAILED in scheduler.rs

### Phase 6: Integration Tests

- [x] 6.1 Test: TASK_CREATED, TASK_STARTED, TASK_COMPLETED (`test_task_state_events_published`)
- [x] 6.2 Test: TASK_FAILED (`test_task_failed_event_published`)
- [x] 6.3 Test: Multiple event types - TASK_CREATED, TASK_STARTED, TASK_COMPLETED, WORKFLOW_COMPLETED (`test_workflow_and_task_events_published`)
- [x] 6.4 Test: TASK_FAILED + WORKFLOW_COMPLETED (`test_workflow_failed_event_published`)
- [x] 6.5 Test: Timer events (`test_timer_events_published`)
- [x] 6.6 Test: Child workflow events (`test_child_workflow_events_published`)

### Phase 7: E2E Testing (Deferred)

- [ ] 7.1 Manual test with curl (deferred)
- [ ] 7.2 E2E test script with Docker image (deferred)

---

## Files Modified

| File | Status | Changes |
|------|--------|---------|
| `flovyn-server/server/src/api/rest/mod.rs` | ✅ | Routes already use new URL pattern |
| `flovyn-server/server/src/api/rest/streaming.rs` | ✅ | Updated doc comments |
| `flovyn-server/server/src/domain/task_stream.rs` | ✅ | Added all snapshot types (Task, Workflow, Timer, Promise, ChildWorkflow, Operation, Cancellation, State, Retry), StateEventData enum, StateEventPayload with all event helper methods |
| `flovyn-server/docs/guides/streaming-events.md` | ✅ | Complete frontend guide with all event types including cancellation, state, and retry events |
| `.dev/docs/design/20251228_realtime-api-requirements.md` | ✅ | Updated to reflect implementation with all event types |
| `flovyn-server/server/src/api/grpc/workflow_dispatch.rs` | ✅ | TASK_CREATED, WORKFLOW_STARTED, WORKFLOW_COMPLETED, WORKFLOW_FAILED, PROMISE_CREATED, PROMISE_RESOLVED, PROMISE_REJECTED, TIMER_STARTED, TIMER_CANCELLED, CHILD_WORKFLOW_INITIATED event publishing |
| `flovyn-server/server/src/api/grpc/task_execution.rs` | ✅ | TASK_STARTED, TASK_COMPLETED, TASK_FAILED event publishing |
| `flovyn-server/server/src/scheduler.rs` | ✅ | Added stream_publisher, TIMER_FIRED, CHILD_WORKFLOW_COMPLETED/FAILED event publishing |
| `flovyn-server/server/src/main.rs` | ✅ | Pass stream_publisher to Scheduler |
| `flovyn-server/server/tests/integration/streaming_tests.rs` | ✅ | Refactored with helper functions (`extract_event_type_from_data`, `collect_events_until`, `assert_events_contain`, `assert_event_order`), added timer and child workflow tests |

---

## Implementation Pattern for Phase 5

```rust
// Helper to publish state event
async fn publish_state_event(
    stream_publisher: &dyn StreamEventPublisher,
    workflow_execution_id: &str,
    payload: StateEventPayload,
) {
    let event = TaskStreamEvent {
        task_execution_id: String::new(), // or task ID if applicable
        workflow_execution_id: workflow_execution_id.to_string(),
        sequence: 0,
        event_type: StreamEventType::Data,
        payload: payload.to_json(),
        timestamp_ms: chrono::Utc::now().timestamp_millis(),
    };

    if let Err(e) = stream_publisher.publish(event).await {
        tracing::warn!(error = %e, "Failed to publish state event");
    }
}

// Usage example for TASK_CREATED
let payload = StateEventPayload::task_created(task.id, &task.kind, task.max_retries);
publish_state_event(&*self.state.stream_publisher, &workflow_id, payload).await;

// Usage example for WORKFLOW_STARTED
let payload = StateEventPayload::workflow_started(&workflow);
publish_state_event(&*self.state.stream_publisher, &workflow.id.to_string(), payload).await;
```

---

## Test Results

All 220 unit tests in flovyn-server pass, including 18 tests in `task_stream.rs`:
- Stream event type tests (6)
- Task event serialization tests (4)
- Workflow event tests (3)
- Timer event test (1)
- Promise event test (1)
- Child workflow event test (1)
- Operation event test (1)
- Deserialization test (1)

**Integration tests status:**
- State event tests in `streaming_tests.rs`:
  - `test_task_state_events_published`: TASK_CREATED, TASK_STARTED, TASK_COMPLETED
  - `test_task_failed_event_published`: TASK_CREATED, TASK_STARTED, TASK_FAILED
  - `test_workflow_and_task_events_published`: Full event ordering verification
  - `test_workflow_failed_event_published`: TASK_FAILED, WORKFLOW_COMPLETED
  - `test_timer_events_published`: TIMER_STARTED, TIMER_FIRED, WORKFLOW_COMPLETED
  - `test_child_workflow_events_published`: CHILD_WORKFLOW_INITIATED, CHILD_WORKFLOW_COMPLETED
- Refactored with shared test helpers: `extract_event_type_from_data`, `collect_events_until`, `assert_events_contain`, `assert_event_order`
- Tests require Docker/testcontainers infrastructure to run (PostgreSQL, NATS)

---

## Definition of Done

Phase 1-4 (Complete):
- [x] Routes use new URL pattern
- [x] All snapshot types defined
- [x] All event helper methods implemented
- [x] Unit tests pass
- [x] Documentation updated

Phase 5-6 (Complete):
- [x] Task events published from gRPC handlers (TASK_CREATED, TASK_STARTED, TASK_COMPLETED, TASK_FAILED)
- [x] Workflow events published from gRPC handlers (WORKFLOW_STARTED, WORKFLOW_COMPLETED, WORKFLOW_FAILED)
- [x] Integration tests verify task event flow
- [x] Integration tests verify workflow event flow
- [x] Renamed TaskStreamEvent to StreamEvent for clarity

Phase 7 (Complete):
- [x] Timer events published (TIMER_STARTED, TIMER_CANCELLED in workflow_dispatch.rs, TIMER_FIRED in scheduler.rs)
- [x] Promise events published (PROMISE_CREATED, PROMISE_RESOLVED, PROMISE_REJECTED in workflow_dispatch.rs)
- [x] Child workflow events published (CHILD_WORKFLOW_INITIATED in workflow_dispatch.rs, CHILD_WORKFLOW_COMPLETED/FAILED in scheduler.rs)
- [x] Timer integration test (`test_timer_events_published`)
- [x] Child workflow integration test (`test_child_workflow_events_published`)
- [ ] E2E test with curl (optional)
