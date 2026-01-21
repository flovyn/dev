# Real-Time API Requirements for Frontend

## Overview

This document specifies how the frontend receives real-time updates for workflow execution monitoring.

**Related Documents:**
- `20251221_task-streaming-implementation.md` - Ephemeral data streaming architecture

**Status:** ✅ Implemented

---

## 1. What the Frontend Needs

| Need | Solution |
|------|----------|
| Initial task state on page load | REST: `GET /workflow-executions/{id}/tasks` |
| Real-time status updates | SSE: `/workflow-executions/{id}/stream` |
| Token streaming from LLM tasks | SSE: `/workflow-executions/{id}/stream` |
| State recovery after reconnect | REST: re-fetch `/workflow-executions/{id}/tasks` |

---

## 2. Design Decisions

### 2.1 URL Pattern Alignment ✅

Streaming endpoints follow the REST resource pattern:

| Endpoint | Description |
|----------|-------------|
| `/api/tenants/:slug/workflow-executions/:id/stream` | Stream events for a workflow |
| `/api/tenants/:slug/workflow-executions/:id/stream/consolidated` | Stream events including child workflows |
| `/api/tenants/:slug/task-executions/:id/stream` | Stream events for a standalone task |

### 2.2 Unified Event Payload Format ✅

**Decision:** All state events use the `Data` SSE event type with a unified payload structure:

```json
{
  "type": "Event",
  "event": "TASK_CREATED",
  "data": { ... entity-specific snapshot ... },
  "timestampMs": 1703764800000
}
```

**Why this approach:**
- No changes to `StreamEventType` enum (stays at 4 values: Token, Progress, Data, Error)
- Proto enum unchanged - SDK developers don't see server-only events
- Frontend distinguishes state events by checking `payload.type === "Event"`
- Extensible - new event types just need new `event` values

### 2.3 Supported Event Types ✅

All workflow event types from `EventType` enum are supported:

| Category | Events |
|----------|--------|
| **Workflow** | WORKFLOW_CREATED, WORKFLOW_STARTED, WORKFLOW_COMPLETED, WORKFLOW_FAILED, WORKFLOW_SUSPENDED, WORKFLOW_RESUMED, WORKFLOW_CANCELLED |
| **Task** | TASK_CREATED, TASK_STARTED, TASK_COMPLETED, TASK_FAILED, TASK_CANCELLED |
| **Timer** | TIMER_STARTED, TIMER_FIRED, TIMER_CANCELLED |
| **Promise** | PROMISE_CREATED, PROMISE_RESOLVED, PROMISE_REJECTED |
| **Child Workflow** | CHILD_WORKFLOW_INITIATED, CHILD_WORKFLOW_STARTED, CHILD_WORKFLOW_COMPLETED, CHILD_WORKFLOW_FAILED, CHILD_WORKFLOW_CANCELLATION_REQUESTED, CHILD_WORKFLOW_CANCELLATION_FAILED |
| **Operation** | OPERATION_COMPLETED |
| **Cancellation** | CANCELLATION_REQUESTED |
| **State** | STATE_SET, STATE_CLEARED |
| **Retry** | RETRY_REQUESTED |

---

## 3. Implementation Details

### 3.1 SSE Event Types (Wire Format)

Only 4 SSE event types on the wire:

| SSE Event | Source | Description |
|-----------|--------|-------------|
| `token` | SDK/Worker | LLM token streaming |
| `progress` | SDK/Worker | Progress percentage (0.0-1.0) |
| `data` | SDK/Worker + Server | Structured data (includes state events) |
| `error` | SDK/Worker | Error notifications |

### 3.2 State Event Payload Structure

Server-originated state events are sent as `data` SSE events with this structure:

```typescript
interface StateEventPayload {
  type: "Event";           // Discriminator for state events
  event: string;           // "TASK_CREATED", "WORKFLOW_STARTED", etc.
  data: Snapshot;          // Entity-specific data
  timestampMs: number;     // Event timestamp
}
```

### 3.3 Snapshot Types

Each entity type has its own snapshot structure:

**WorkflowSnapshot:**
```typescript
{
  id: string;
  kind: string;
  status: string;
  workerId?: string;
  error?: string;
  parentWorkflowExecutionId?: string;
}
```

**TaskSnapshot:**
```typescript
{
  id: string;
  kind: string;
  status: string;
  executionCount: number;
  maxRetries: number;
  workerId?: string;
  error?: string;
}
```

**TimerSnapshot:**
```typescript
{
  timerId: string;
  fireAtMs?: number;
}
```

**PromiseSnapshot:**
```typescript
{
  promiseId: string;
  result?: string;
  error?: string;
}
```

**ChildWorkflowSnapshot:**
```typescript
{
  childWorkflowId: string;
  kind: string;
  status?: string;
  error?: string;
}
```

**OperationSnapshot:**
```typescript
{
  operationId: string;
  result?: string;
}
```

---

## 4. SSE Event Examples

All events go through `/workflow-executions/{id}/stream`:

```
event: data
data: {"type":"Event","event":"WORKFLOW_STARTED","data":{"id":"wf-123","kind":"order-process","status":"RUNNING"},"timestampMs":1703764800000}

event: data
data: {"type":"Event","event":"TASK_CREATED","data":{"id":"task-123","kind":"send-email","status":"PENDING","executionCount":0,"maxRetries":3},"timestampMs":1703764800001}

event: data
data: {"type":"Event","event":"TASK_STARTED","data":{"id":"task-123","kind":"send-email","status":"RUNNING","executionCount":1,"maxRetries":3,"workerId":"worker-1"},"timestampMs":1703764800002}

event: token
data: Hello

event: token
data: , world!

event: progress
data: 0.5

event: data
data: {"type":"Event","event":"TASK_COMPLETED","data":{"id":"task-123","kind":"send-email","status":"COMPLETED","executionCount":1,"maxRetries":3},"timestampMs":1703764800100}

event: data
data: {"type":"Event","event":"WORKFLOW_COMPLETED","data":{"id":"wf-123","kind":"order-process","status":"COMPLETED"},"timestampMs":1703764800200}
```

---

## 5. Frontend Integration

### Connection pattern

```typescript
function useWorkflowExecution(workflowExecutionId: string) {
  const [workflow, setWorkflow] = useState<WorkflowState | null>(null);
  const [tasks, setTasks] = useState<Map<string, TaskState>>(new Map());
  const [tokens, setTokens] = useState<string>('');

  useEffect(() => {
    const eventSource = new EventSource(
      `/api/tenants/${slug}/workflow-executions/${workflowExecutionId}/stream`
    );

    // Handle all data events
    eventSource.addEventListener('data', (e) => {
      const payload = JSON.parse(e.data);

      // Check if this is a server state event
      if (payload.type === 'Event') {
        const { event, data } = payload;

        if (event.startsWith('WORKFLOW_')) {
          setWorkflow(data);
        } else if (event.startsWith('TASK_')) {
          setTasks(prev => new Map(prev).set(data.id, data));
        }
        // Handle timer, promise, child workflow, operation events as needed
      } else {
        // Custom data from SDK/worker
        console.log('Custom data:', payload);
      }
    });

    // Token streaming
    eventSource.addEventListener('token', (e) => {
      setTokens(prev => prev + e.data);
    });

    return () => eventSource.close();
  }, [workflowExecutionId]);

  return { workflow, tasks, tokens };
}
```

---

## 6. Files Modified

| File | Changes |
|------|---------|
| `flovyn-server/server/src/domain/task_stream.rs` | Added snapshot types (WorkflowSnapshot, TimerSnapshot, etc.), StateEventData enum, StateEventPayload with event methods |
| `flovyn-server/server/src/api/rest/mod.rs` | Routes use new URL pattern |
| `flovyn-server/server/src/api/rest/streaming.rs` | Updated doc comments, added OpenAPI annotations |
| `flovyn-server/server/src/api/rest/openapi.rs` | Registered streaming endpoints, added "Streaming" tag |
| `flovyn-server/server/src/api/grpc/workflow_dispatch.rs` | Publishes TASK_CREATED, WORKFLOW_STARTED, WORKFLOW_COMPLETED, WORKFLOW_FAILED, TIMER_STARTED, TIMER_CANCELLED, PROMISE_CREATED, PROMISE_RESOLVED, PROMISE_REJECTED, CHILD_WORKFLOW_INITIATED events |
| `flovyn-server/server/src/api/grpc/task_execution.rs` | Publishes TASK_STARTED, TASK_COMPLETED, TASK_FAILED events |
| `flovyn-server/server/src/scheduler.rs` | Publishes TIMER_FIRED, CHILD_WORKFLOW_COMPLETED, CHILD_WORKFLOW_FAILED events |
| `flovyn-server/server/src/main.rs` | Pass stream_publisher to Scheduler |
| `flovyn-server/docs/guides/streaming-events.md` | Complete guide with all event types |

---

## 7. Trade-offs

| Aspect | This Design |
|--------|-------------|
| **Complexity** | Low - uses existing `Data` event type |
| **Proto changes** | None - SDK unchanged |
| **Extensibility** | High - new events just add `event` string values |
| **Frontend detection** | Check `payload.type === "Event"` |

---

## 8. Testing

Unit tests in `flovyn-server/server/src/domain/task_stream.rs`:
- `test_state_event_payload_serialization`
- `test_workflow_event_payload_serialization`
- `test_timer_event_serialization`
- `test_promise_event_serialization`
- `test_child_workflow_event_serialization`
- `test_operation_event_serialization`

All 18 tests pass.

---

## 9. Implementation Complete

All event publishing has been implemented:

- **Task Events**: TASK_CREATED, TASK_STARTED, TASK_COMPLETED, TASK_FAILED published from gRPC handlers
- **Workflow Events**: WORKFLOW_STARTED, WORKFLOW_COMPLETED, WORKFLOW_FAILED published from gRPC handlers
- **Timer Events**: TIMER_STARTED, TIMER_CANCELLED from workflow_dispatch.rs; TIMER_FIRED from scheduler.rs
- **Promise Events**: PROMISE_CREATED, PROMISE_RESOLVED, PROMISE_REJECTED from workflow_dispatch.rs
- **Child Workflow Events**: CHILD_WORKFLOW_INITIATED from workflow_dispatch.rs; CHILD_WORKFLOW_COMPLETED, CHILD_WORKFLOW_FAILED from scheduler.rs

Integration tests verify the event flow in `flovyn-server/server/tests/integration/streaming_tests.rs`.
