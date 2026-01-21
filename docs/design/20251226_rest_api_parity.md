# REST API Parity with Kotlin Server

This document tracks REST API endpoint parity between the Kotlin and Rust servers.

## Reference

Kotlin server: `/Users/manhha/Developer/manhha/leanapp/flovyn/server/app/src/main/kotlin/ai/flovyn/controller/`

---

## Implementation Status

### Fully Implemented

| Category | Endpoint | Notes |
|----------|----------|-------|
| **Health** | `GET /_/health` | Version and plugins info |
| **Health** | `GET /_/metrics` | Prometheus metrics |
| **Tenants** | `POST /api/tenants` | Create tenant |
| **Tenants** | `GET /api/tenants/{slug}` | Get tenant by slug |
| **Workflows** | `POST .../workflows/{kind}/trigger` | Start workflow (idempotency supported) |
| **Workflows** | `GET .../workflow-executions` | List with filters (status, kind, limit, offset) |
| **Workflows** | `GET .../workflow-executions/{id}` | Get workflow details |
| **Workflows** | `GET .../workflow-executions/{id}/events` | Get event log (since_sequence supported) |
| **Workflows** | `POST .../workflow-executions/{id}/cancel` | Cancel workflow |
| **Workflows** | `GET .../workflow-executions/{id}/tasks` | Get all tasks for workflow |
| **Standalone Tasks** | `POST .../tasks` | Create standalone task |
| **Standalone Tasks** | `GET .../tasks` | List with filters (status, queue, task_type) |
| **Standalone Tasks** | `GET .../tasks/{id}` | Get task details |
| **Standalone Tasks** | `DELETE .../tasks/{id}` | Cancel pending task |
| **Standalone Tasks** | `GET .../tasks/{id}/attempts` | Get retry attempt history |
| **Discovery** | `GET .../workers` | List workers with capabilities |
| **Discovery** | `GET .../workers/{id}` | Get worker details |
| **Discovery** | `GET .../workflow-definitions` | List available workflow types |
| **Discovery** | `GET .../workflow-definitions/{kind}` | Get workflow definition details |
| **Discovery** | `GET .../task-definitions` | List available task types |
| **Discovery** | `GET .../task-definitions/{kind}` | Get task definition details |
| **Streaming** | `GET .../stream/workflows/{id}` | SSE for workflow events |
| **Streaming** | `GET .../stream/workflows/{id}/consolidated` | SSE including child workflows |
| **OpenAPI** | `GET /api/docs` | Swagger UI |
| **OpenAPI** | `flovyn-server/GET /api/docs/openapi.json` | OpenAPI 3.0 spec |

---

## Not Yet Implemented

> **Implementation Order**: For each endpoint below:
> 1. Implement REST endpoint in server
> 2. Update `crates/rest-client` with client method
> 3. Write integration tests using rest-client
> 4. Add CLI command

### 1. Workflow Retry

**Kotlin**: `WorkflowExecutionController.retryWorkflow()`

```
POST /api/tenants/{tenantSlug}/workflow-executions/{workflowExecutionId}/retry
```

**Purpose**: Reset a failed workflow to PENDING state for re-execution by workers.

**Request**:
```json
{
  "note": "Retrying after bug fix deployment"
}
```

**Response**:
```json
{
  "workflowExecutionId": "uuid",
  "status": "PENDING",
  "retryAttempt": 2,
  "message": "Workflow reset for retry. Workers will pick it up automatically.",
  "success": true
}
```

**Use Case**: Operations teams retry failed workflows after fixing bugs or resolving infrastructure issues. Manual retry bypasses automatic max retry limits.

**Phase**: 1 - Core Operations

**CLI Command**:
```bash
flovyn workflow retry <workflow-id> [--note "reason"]
```

**Implementation Notes**:
- Only allow retry for workflows in FAILED state
- Increment `retry_attempts` counter
- Reset state to PENDING
- Clear error field
- Record RETRY_REQUESTED event in event log

---

### 2. Workflow Children

**Kotlin**: `WorkflowExecutionController.getChildWorkflows()`

```
GET /api/tenants/{tenantSlug}/workflow-executions/{workflowExecutionId}/children
```

**Purpose**: List child workflow executions spawned by a parent workflow.

**Response**:
```json
{
  "children": [
    {
      "childWorkflowExecutionId": "uuid",
      "childExecutionName": "process-order",
      "status": "COMPLETED",
      "createdAt": "2024-01-15T10:30:00.000Z"
    }
  ]
}
```

**Use Case**: Debug parent-child workflow relationships, visualize workflow hierarchy in UI.

**Phase**: 2 - Debugging

**CLI Command**:
```bash
flovyn workflow children <workflow-id>
```

**Implementation Notes**:
- Query `child_workflow_execution` table by parent_workflow_execution_id
- Join with `workflow_execution` for current state

---

### 3. Workflow Task Attempts

**Kotlin**: `TaskExecutionController.getTaskAttempts()`

```
GET /api/tenants/{tenantSlug}/workflow-executions/{workflowExecutionId}/tasks/{taskExecutionId}/attempts
```

**Purpose**: Get detailed retry attempt history for a specific workflow task.

**Response**:
```json
{
  "attempts": [
    {
      "attempt": 1,
      "startedAt": "2024-01-15T10:30:00.000Z",
      "finishedAt": "2024-01-15T10:30:02.000Z",
      "durationMs": 2150,
      "status": "FAILED",
      "error": "Connection timeout",
      "workerId": "worker-pod-abc123"
    },
    {
      "attempt": 2,
      "startedAt": "2024-01-15T10:30:32.000Z",
      "finishedAt": "2024-01-15T10:30:33.000Z",
      "durationMs": 500,
      "status": "COMPLETED",
      "output": {"result": "success"},
      "workerId": "worker-pod-xyz789"
    }
  ]
}
```

**Use Case**: Debug task retry behavior, understand why tasks failed, analyze per-attempt timing.

**Phase**: 2 - Debugging

**CLI Command**:
```bash
flovyn workflow task-attempts <workflow-id> <task-id>
```

**Note**: Standalone tasks already have this endpoint (`GET .../tasks/{id}/attempts`). This adds parity for workflow-bound tasks.

---

### 4. Task Logs

**Kotlin**: `TaskExecutionController.getTaskLogs()`

```
GET /api/tenants/{tenantSlug}/workflow-executions/{workflowExecutionId}/tasks/{taskExecutionId}/logs
```

**Query Parameters**:
- `level`: Filter by log level (INFO, WARN, ERROR)
- `limit`: Max results (default 100, max 1000)
- `offset`: Pagination offset

**Purpose**: Get structured logs emitted by a task during execution.

**Response**:
```json
{
  "taskExecutionId": "uuid",
  "logs": [
    {
      "id": "uuid",
      "level": "INFO",
      "message": "Processing order",
      "timestamp": "2024-01-15T10:30:01.000Z"
    }
  ],
  "total": 50,
  "limit": 100,
  "offset": 0
}
```

**Use Case**: Debug task execution, understand what happened during processing.

**Phase**: 3 - Observability

**CLI Command**:
```bash
flovyn workflow task-logs <workflow-id> <task-id> [--level INFO|WARN|ERROR] [--limit 100]
```

**Dependencies**:
- Add `task_execution_log` table
- Worker SDK changes to emit logs via gRPC
- Log ingestion endpoint

---

### 5. Task Stream (SSE)

**Kotlin**: `WorkflowTaskHistoryController.streamWorkflowTaskHistory()`

```
GET /api/tenants/{tenantSlug}/workflow-executions/{workflowExecutionId}/tasks/stream
```

**Purpose**: Real-time SSE stream of task state changes for a workflow.

**Event Types**:
- `task_created`: New task scheduled
- `task_started`: Task began execution
- `task_progress`: Task progress update
- `task_completed`: Task finished successfully
- `task_failed`: Task attempt failed
- `task_retry`: Task scheduled for retry

**Use Case**: Live monitoring of workflow tasks in TUI or web dashboard.

**Phase**: 3 - Observability

**CLI Command**:
```bash
flovyn workflow watch-tasks <workflow-id>
```

---

## Deferred

### Schedules

**Kotlin**: `ScheduleController`

Time-based workflow triggering (CRON, intervals, one-time). 7 endpoints for schedule CRUD and enable/disable.

**Use Case**: Scheduled workflows - daily reports, periodic cleanup, batch processing.

---

### Webhooks

**Kotlin**: `WebhookManagementController`

Receive external events from GitHub, Stripe, generic webhooks. 5 endpoints for webhook CRUD.

**Use Case**: Event-driven workflows triggered by external systems.

---

### Promises (Signals)

**Kotlin**: `PromiseController`

External systems signal workflow executions via durable promises. 2 endpoints for resolve/reject.

**Use Case**: Human approval workflows, external event completion.

---

## Out of Scope

### Visual Workflows

**Kotlin**: `VisualWorkflowController`, `VisualWorkflowBuilderController`

CRUD for visual workflow definitions (no-code workflow builder).

**Reason**: Rust server is code-first only. Visual workflow support is not planned.

---

## Implementation Priorities

### Phase 1: Core Operations

1. **Workflow Retry** - Essential for production operations

### Phase 2: Debugging

2. **Workflow Children** - Parent-child workflow visibility
3. **Workflow Task Attempts** - Detailed retry history for workflow tasks

### Phase 3: Observability

4. **Task Logs** - Requires SDK changes
5. **Task Stream (SSE)** - Real-time task state changes

---

## Changelog

- **2024-12-26**: Major update
  - Moved Standalone Tasks to "Implemented" (commit 4f60300)
  - Moved Workload Discovery to "Implemented" (commit bbd796b)
  - Identified missing endpoints from Kotlin: Schedules, Webhooks, Promises
  - Deferred Schedules, Webhooks, Promises
  - Removed compatibility notes (strict Kotlin compatibility not required)
  - Reorganized priorities based on production requirements
