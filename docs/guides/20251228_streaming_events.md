# Streaming Events Guide

This guide explains how to consume real-time workflow and task events via Server-Sent Events (SSE).

## Endpoints

### Workflow Stream
```
GET /api/orgs/{org_slug}/workflow-executions/{workflow_execution_id}/stream
```

Subscribe to all events for a specific workflow execution, including:
- Workflow state changes (started, completed, failed, suspended, cancelled)
- Task state changes (created, started, completed, failed, cancelled)
- Timer events (started, fired, cancelled)
- Promise events (created, resolved, rejected)
- Child workflow events (initiated, started, completed, failed)
- Operation events (completed)
- Token streaming from LLM tasks
- Progress updates
- Custom data events from tasks

### Consolidated Workflow Stream
```
GET /api/orgs/{org_slug}/workflow-executions/{workflow_execution_id}/stream/consolidated
```

Same as above but includes events from all child workflows.

### Task Stream
```
GET /api/orgs/{org_slug}/task-executions/{task_execution_id}/stream
```

Subscribe to events for a specific standalone task execution.

## SSE Event Types

Each SSE event has a `type` indicating the event category:

| SSE Event Type | Source | Description |
|----------------|--------|-------------|
| `token` | SDK/Worker | LLM token or text chunk streamed from task |
| `progress` | SDK/Worker | Progress update (0.0-1.0) |
| `data` | SDK/Worker + Server | Structured data - includes both custom task data and state events |
| `error` | SDK/Worker | Error notification from task |

## State Events (Server-Originated)

State change events are sent as `data` SSE events. To distinguish them from SDK-originated data events, check for `type: "Event"` in the payload:

```json
{
  "type": "Event",
  "event": "TASK_CREATED",
  "data": {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "kind": "send-email",
    "status": "PENDING",
    "executionCount": 0,
    "maxRetries": 3
  },
  "timestampMs": 1703764800000
}
```

### All Event Types

#### Workflow Events

| Event | Description |
|-------|-------------|
| `WORKFLOW_CREATED` | Workflow was created |
| `WORKFLOW_STARTED` | Workflow execution started |
| `WORKFLOW_COMPLETED` | Workflow finished successfully |
| `WORKFLOW_FAILED` | Workflow failed |
| `WORKFLOW_SUSPENDED` | Workflow suspended (waiting for timer, promise, etc.) |
| `WORKFLOW_RESUMED` | Workflow resumed from suspension |
| `WORKFLOW_CANCELLED` | Workflow was cancelled |

**Workflow Data Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Workflow execution UUID |
| `kind` | string | Workflow type name |
| `status` | string | PENDING, RUNNING, WAITING, COMPLETED, FAILED, CANCELLED |
| `workerId` | string? | ID of worker executing the workflow |
| `error` | string? | Error message (only on failure) |
| `parentWorkflowExecutionId` | string? | Parent workflow ID (for child workflows) |

#### Task Events

| Event | Description |
|-------|-------------|
| `TASK_CREATED` | Task was scheduled by the workflow |
| `TASK_STARTED` | Worker picked up and started executing the task |
| `TASK_COMPLETED` | Task finished successfully |
| `TASK_FAILED` | Task failed (may retry or failed permanently) |
| `TASK_CANCELLED` | Task was cancelled |

**Task Data Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Task execution UUID |
| `kind` | string | Task type name |
| `status` | string | PENDING, RUNNING, COMPLETED, FAILED, CANCELLED |
| `executionCount` | number | Number of execution attempts |
| `maxRetries` | number | Maximum retry attempts allowed |
| `workerId` | string? | ID of worker executing the task |
| `error` | string? | Error message (only on failure) |

#### Timer Events

| Event | Description |
|-------|-------------|
| `TIMER_STARTED` | Timer was started |
| `TIMER_FIRED` | Timer has fired |
| `TIMER_CANCELLED` | Timer was cancelled |

**Timer Data Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `timerId` | string | Timer identifier |
| `fireAtMs` | number? | Timestamp when timer will fire (only on TIMER_STARTED) |

#### Promise Events

| Event | Description |
|-------|-------------|
| `PROMISE_CREATED` | External promise was created |
| `PROMISE_RESOLVED` | Promise was resolved with a value |
| `PROMISE_REJECTED` | Promise was rejected with an error |

**Promise Data Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `promiseId` | string | Promise identifier |
| `result` | string? | Result value (only on PROMISE_RESOLVED) |
| `error` | string? | Error message (only on PROMISE_REJECTED) |

#### Child Workflow Events

| Event | Description |
|-------|-------------|
| `CHILD_WORKFLOW_INITIATED` | Child workflow was initiated |
| `CHILD_WORKFLOW_STARTED` | Child workflow started executing |
| `CHILD_WORKFLOW_COMPLETED` | Child workflow completed successfully |
| `CHILD_WORKFLOW_FAILED` | Child workflow failed |
| `CHILD_WORKFLOW_CANCELLATION_REQUESTED` | Cancellation was requested for child workflow |
| `CHILD_WORKFLOW_CANCELLATION_FAILED` | Failed to cancel child workflow |

**Child Workflow Data Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `childWorkflowId` | string | Child workflow execution UUID |
| `kind` | string | Child workflow type name |
| `status` | string? | Current status |
| `error` | string? | Error message (only on failure events) |

#### Operation Events

| Event | Description |
|-------|-------------|
| `OPERATION_COMPLETED` | Side-effect operation was recorded |

**Operation Data Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `operationId` | string | Operation identifier |
| `result` | string? | Operation result |

#### Cancellation Events

| Event | Description |
|-------|-------------|
| `CANCELLATION_REQUESTED` | Cancellation was requested for the workflow |

**Cancellation Data Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `workflowExecutionId` | string | Workflow execution UUID being cancelled |
| `reason` | string? | Reason for cancellation |

#### State Events

| Event | Description |
|-------|-------------|
| `STATE_SET` | Workflow state was set |
| `STATE_CLEARED` | Workflow state was cleared |

**State Data Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `key` | string | State key |
| `value` | string? | State value (only on STATE_SET) |

#### Retry Events

| Event | Description |
|-------|-------------|
| `RETRY_REQUESTED` | Retry was requested for a task or workflow |

**Retry Data Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `targetId` | string | ID of task or workflow being retried |
| `targetType` | string | Type of target (task or workflow) |
| `attempt` | number? | Retry attempt number |

## SDK-Originated Events

Workers can stream data to clients during task execution:

### Token Events
Streamed text chunks, typically from LLM responses:
```
event: token
data: Hello
```

### Progress Events
Progress percentage (0.0 to 1.0):
```
event: progress
data: 0.75
```

### Data Events (from SDK)
Custom structured data from tasks. These do NOT have `type: "Event"`:
```
event: data
data: {"status": "processing", "itemsProcessed": 42}
```

### Error Events
Error messages from task execution:
```
event: error
data: Connection timeout
```

## JavaScript Example

```javascript
const orgSlug = "my-org";
const workflowId = "550e8400-e29b-41d4-a716-446655440000";

const eventSource = new EventSource(
  `/api/orgs/${orgSlug}/workflow-executions/${workflowId}/stream`
);

// Handle data events (both state events and custom data)
eventSource.addEventListener("data", (event) => {
  const payload = JSON.parse(event.data);

  // Check if this is a server state event
  if (payload.type === "Event") {
    handleStateEvent(payload);
  } else {
    // Custom data from SDK/worker
    console.log("Custom data:", payload);
  }
});

function handleStateEvent(payload) {
  const { event, data, timestampMs } = payload;

  // Workflow events
  if (event.startsWith("WORKFLOW_")) {
    console.log(`Workflow ${data.id}: ${event}`);
    if (data.error) console.error(`Error: ${data.error}`);
    return;
  }

  // Task events
  if (event.startsWith("TASK_")) {
    console.log(`Task ${data.kind} (${data.id}): ${event}`);
    if (data.workerId) console.log(`  Worker: ${data.workerId}`);
    if (data.error) console.error(`  Error: ${data.error}`);
    return;
  }

  // Timer events
  if (event.startsWith("TIMER_")) {
    console.log(`Timer ${data.timerId}: ${event}`);
    if (data.fireAtMs) console.log(`  Fire at: ${new Date(data.fireAtMs)}`);
    return;
  }

  // Promise events
  if (event.startsWith("PROMISE_")) {
    console.log(`Promise ${data.promiseId}: ${event}`);
    if (data.result) console.log(`  Result: ${data.result}`);
    if (data.error) console.error(`  Error: ${data.error}`);
    return;
  }

  // Child workflow events
  if (event.startsWith("CHILD_WORKFLOW_")) {
    console.log(`Child Workflow ${data.childWorkflowId} (${data.kind}): ${event}`);
    if (data.error) console.error(`  Error: ${data.error}`);
    return;
  }

  // Operation events
  if (event === "OPERATION_COMPLETED") {
    console.log(`Operation ${data.operationId} completed`);
    if (data.result) console.log(`  Result: ${data.result}`);
    return;
  }
}

// Handle token streaming (e.g., LLM output)
eventSource.addEventListener("token", (event) => {
  document.getElementById("output").textContent += event.data;
});

// Handle progress updates
eventSource.addEventListener("progress", (event) => {
  const percent = parseFloat(event.data) * 100;
  document.getElementById("progress").style.width = `${percent}%`;
});

// Handle errors from tasks
eventSource.addEventListener("error", (event) => {
  if (event.data) {
    console.error("Task error:", event.data);
  }
});

// Handle connection errors
eventSource.onerror = (event) => {
  if (eventSource.readyState === EventSource.CLOSED) {
    console.log("Stream closed");
  }
};
```

## React Hook Example

```tsx
import { useEffect, useState } from "react";

interface TaskState {
  id: string;
  kind: string;
  status: string;
  executionCount: number;
  maxRetries: number;
  workerId: string | null;
  error: string | null;
}

interface WorkflowState {
  id: string;
  kind: string;
  status: string;
  workerId: string | null;
  error: string | null;
  parentWorkflowExecutionId: string | null;
}

interface StreamState {
  workflow: WorkflowState | null;
  tasks: Map<string, TaskState>;
  tokens: string;
  progress: number;
  error: string | null;
}

function useWorkflowStream(orgSlug: string, workflowId: string): StreamState {
  const [state, setState] = useState<StreamState>({
    workflow: null,
    tasks: new Map(),
    tokens: "",
    progress: 0,
    error: null,
  });

  useEffect(() => {
    const url = `/api/orgs/${orgSlug}/workflow-executions/${workflowId}/stream`;
    const eventSource = new EventSource(url);

    eventSource.addEventListener("data", (event) => {
      const payload = JSON.parse(event.data);

      if (payload.type === "Event") {
        const { event: eventType, data } = payload;

        // Handle workflow events
        if (eventType.startsWith("WORKFLOW_")) {
          setState((prev) => ({
            ...prev,
            workflow: data as WorkflowState,
          }));
          return;
        }

        // Handle task events
        if (eventType.startsWith("TASK_")) {
          const task = data as TaskState;
          setState((prev) => ({
            ...prev,
            tasks: new Map(prev.tasks).set(task.id, task),
          }));
          return;
        }
      }
    });

    eventSource.addEventListener("token", (event) => {
      setState((prev) => ({ ...prev, tokens: prev.tokens + event.data }));
    });

    eventSource.addEventListener("progress", (event) => {
      setState((prev) => ({ ...prev, progress: parseFloat(event.data) }));
    });

    eventSource.addEventListener("error", (event) => {
      if (event.data) {
        setState((prev) => ({ ...prev, error: event.data }));
      }
    });

    return () => eventSource.close();
  }, [orgSlug, workflowId]);

  return state;
}
```

## TypeScript Types

```typescript
// SSE event types
type SSEEventType = "token" | "progress" | "data" | "error";

// All event types
type StateEvent =
  // Workflow events
  | "WORKFLOW_CREATED"
  | "WORKFLOW_STARTED"
  | "WORKFLOW_COMPLETED"
  | "WORKFLOW_FAILED"
  | "WORKFLOW_SUSPENDED"
  | "WORKFLOW_RESUMED"
  | "WORKFLOW_CANCELLED"
  // Task events
  | "TASK_CREATED"
  | "TASK_STARTED"
  | "TASK_COMPLETED"
  | "TASK_FAILED"
  | "TASK_CANCELLED"
  // Timer events
  | "TIMER_STARTED"
  | "TIMER_FIRED"
  | "TIMER_CANCELLED"
  // Promise events
  | "PROMISE_CREATED"
  | "PROMISE_RESOLVED"
  | "PROMISE_REJECTED"
  // Child workflow events
  | "CHILD_WORKFLOW_INITIATED"
  | "CHILD_WORKFLOW_STARTED"
  | "CHILD_WORKFLOW_COMPLETED"
  | "CHILD_WORKFLOW_FAILED"
  | "CHILD_WORKFLOW_CANCELLATION_REQUESTED"
  | "CHILD_WORKFLOW_CANCELLATION_FAILED"
  // Operation events
  | "OPERATION_COMPLETED"
  // Cancellation events
  | "CANCELLATION_REQUESTED"
  // State events
  | "STATE_SET"
  | "STATE_CLEARED"
  // Retry events
  | "RETRY_REQUESTED";

// State event payload (received on "data" SSE events with type="Event")
interface StateEventPayload {
  type: "Event";
  event: StateEvent;
  data: TaskSnapshot | WorkflowSnapshot | TimerSnapshot | PromiseSnapshot | ChildWorkflowSnapshot | OperationSnapshot | CancellationSnapshot | StateSnapshot | RetrySnapshot;
  timestampMs: number;
}

interface WorkflowSnapshot {
  id: string;
  kind: string;
  status: "PENDING" | "RUNNING" | "WAITING" | "COMPLETED" | "FAILED" | "CANCELLED";
  workerId: string | null;
  error: string | null;
  parentWorkflowExecutionId: string | null;
}

interface TaskSnapshot {
  id: string;
  kind: string;
  status: "PENDING" | "RUNNING" | "COMPLETED" | "FAILED" | "CANCELLED";
  executionCount: number;
  maxRetries: number;
  workerId: string | null;
  error: string | null;
}

interface TimerSnapshot {
  timerId: string;
  fireAtMs: number | null;
}

interface PromiseSnapshot {
  promiseId: string;
  result: string | null;
  error: string | null;
}

interface ChildWorkflowSnapshot {
  childWorkflowId: string;
  kind: string;
  status: string | null;
  error: string | null;
}

interface OperationSnapshot {
  operationId: string;
  result: string | null;
}

interface CancellationSnapshot {
  workflowExecutionId: string;
  reason: string | null;
}

interface StateSnapshot {
  key: string;
  value: string | null;
}

interface RetrySnapshot {
  targetId: string;
  targetType: string;
  attempt: number | null;
}

// Type guard for state events
function isStateEvent(payload: unknown): payload is StateEventPayload {
  return (
    typeof payload === "object" &&
    payload !== null &&
    "type" in payload &&
    payload.type === "Event" &&
    "event" in payload &&
    "data" in payload
  );
}

// Type guards for specific event data
function isTaskEvent(event: StateEvent): boolean {
  return event.startsWith("TASK_");
}

function isWorkflowEvent(event: StateEvent): boolean {
  return event.startsWith("WORKFLOW_");
}

function isTimerEvent(event: StateEvent): boolean {
  return event.startsWith("TIMER_");
}

function isPromiseEvent(event: StateEvent): boolean {
  return event.startsWith("PROMISE_");
}

function isChildWorkflowEvent(event: StateEvent): boolean {
  return event.startsWith("CHILD_WORKFLOW_");
}

function isOperationEvent(event: StateEvent): boolean {
  return event === "OPERATION_COMPLETED";
}

function isCancellationEvent(event: StateEvent): boolean {
  return event === "CANCELLATION_REQUESTED";
}

function isStateStorageEvent(event: StateEvent): boolean {
  return event.startsWith("STATE_");
}

function isRetryEvent(event: StateEvent): boolean {
  return event === "RETRY_REQUESTED";
}
```

## Reconnection

The stream may close due to network issues or server timeout (5 minutes of inactivity). Implement reconnection:

```javascript
function createReconnectingStream(url, handlers) {
  let eventSource;
  let reconnectAttempts = 0;
  const maxAttempts = 5;

  function connect() {
    eventSource = new EventSource(url);

    eventSource.onopen = () => {
      reconnectAttempts = 0;
    };

    eventSource.onerror = () => {
      eventSource.close();

      if (reconnectAttempts < maxAttempts) {
        const delay = Math.min(1000 * Math.pow(2, reconnectAttempts), 30000);
        reconnectAttempts++;
        console.log(`Reconnecting in ${delay}ms...`);
        setTimeout(connect, delay);
      } else {
        handlers.onMaxRetriesReached?.();
      }
    };

    for (const [event, handler] of Object.entries(handlers)) {
      if (event !== "onMaxRetriesReached") {
        eventSource.addEventListener(event, handler);
      }
    }
  }

  connect();
  return () => eventSource?.close();
}

// Usage
const cleanup = createReconnectingStream(
  `/api/orgs/my-org/workflow-executions/${workflowId}/stream`,
  {
    data: (e) => console.log("Data:", JSON.parse(e.data)),
    token: (e) => console.log("Token:", e.data),
    progress: (e) => console.log("Progress:", e.data),
    error: (e) => console.error("Error:", e.data),
    onMaxRetriesReached: () => console.error("Connection lost"),
  }
);
```
