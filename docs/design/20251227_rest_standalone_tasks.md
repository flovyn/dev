# REST API: Standalone Tasks

**Status**: Implemented
**Related**: [standalone-tasks.md](./20251225_standalone_tasks.md)

---

## Overview

This document describes the REST API design for standalone task management. Standalone tasks allow executing tasks outside of workflow context - useful for one-off operations, scheduled jobs, or simple task execution without workflow overhead.

**Key Features**:
1. Create and manage tasks via REST API
2. Queue-based task routing
3. Scheduled/delayed task execution
4. Full task lifecycle visibility with retry attempt history
5. Task logs for debugging

**Difference from Workflow Tasks**: Standalone tasks have `workflow_execution_id = NULL`. They are created via REST API, polled by workers via gRPC, and provide direct REST visibility without workflow event log overhead.

---

## API Design

### Base Path

```
/api/tenants/{tenant_slug}/task-executions
```

All endpoints require JWT authentication via `Authorization: Bearer <token>` header.

---

### Create Standalone Task

```
POST /api/tenants/{tenant_slug}/task-executions
```

Creates a new standalone task for worker execution.

#### Request Body

```json
{
  "taskType": "send-email",
  "input": {
    "to": "user@example.com",
    "subject": "Hello",
    "body": "Welcome!"
  },
  "queue": "default",
  "maxRetries": 3,
  "scheduledAt": "2025-01-15T10:00:00Z"
}
```

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `taskType` | string | **Yes** | - | Task type identifier (e.g., `send-email`, `process-file`) |
| `input` | object | No | `{}` | JSON input data for the task |
| `queue` | string | No | `"default"` | Task queue for worker routing |
| `maxRetries` | integer | No | `3` | Maximum retry attempts (0-10) |
| `scheduledAt` | ISO 8601 | No | `null` | Scheduled execution time. Task won't be polled until this time. |

#### Response (201 Created)

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "tenantId": "acme-tenant-uuid",
  "taskType": "send-email",
  "status": "PENDING",
  "queue": "default",
  "executionCount": 0,
  "maxRetries": 3,
  "progress": null,
  "progressDetails": null,
  "input": {
    "to": "user@example.com",
    "subject": "Hello",
    "body": "Welcome!"
  },
  "output": null,
  "error": null,
  "workerId": null,
  "scheduledAt": "2025-01-15T10:00:00Z",
  "createdAt": "2025-01-15T09:00:00Z",
  "startedAt": null,
  "completedAt": null
}
```

#### Error Responses

| Status | Condition | Response |
|--------|-----------|----------|
| 400 | Queue name > 100 chars | `{"error": "Queue name too long (max 100 characters)"}` |
| 400 | Invalid JSON input | `{"error": "Invalid input JSON: ..."}` |
| 403 | Not authorized | `{"error": "Forbidden"}` |
| 404 | Tenant not found | `{"error": "Tenant 'unknown' not found"}` |

#### Validation Rules

- `taskType`: Required, non-empty
- `queue`: Max 100 characters
- `maxRetries`: Clamped to 0-10 range
- `input`: Valid JSON, max size 1MB

#### Worker Notification

After task creation, `WorkerNotifier::notify_work_available()` is called to wake workers polling the queue.

---

### List Standalone Tasks

```
GET /api/tenants/{tenant_slug}/task-executions
```

Returns paginated list of standalone tasks.

#### Query Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `status` | string | - | Filter by status: `PENDING`, `RUNNING`, `COMPLETED`, `FAILED`, `CANCELLED` |
| `queue` | string | - | Filter by queue name |
| `taskType` | string | - | Filter by task type |
| `limit` | integer | `50` | Max results per page (1-100) |
| `offset` | integer | `0` | Results to skip for pagination |

#### Response (200 OK)

```json
{
  "tasks": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "tenantId": "acme-tenant-uuid",
      "taskType": "send-email",
      "status": "COMPLETED",
      "queue": "default",
      "executionCount": 1,
      "maxRetries": 3,
      "progress": 1.0,
      "progressDetails": null,
      "input": {"to": "user@example.com"},
      "output": {"messageId": "abc123"},
      "error": null,
      "workerId": "worker-1",
      "scheduledAt": null,
      "createdAt": "2025-01-15T09:00:00Z",
      "startedAt": "2025-01-15T09:00:05Z",
      "completedAt": "2025-01-15T09:00:30Z"
    }
  ],
  "total": 150,
  "limit": 50,
  "offset": 0
}
```

#### SQL Query (Standalone Filter)

The list endpoint filters by `workflow_execution_id IS NULL` to return only standalone tasks:

```sql
SELECT * FROM task_execution
WHERE tenant_id = $1
  AND workflow_execution_id IS NULL
  AND ($2::text IS NULL OR status = $2)
  AND ($3::text IS NULL OR queue = $3)
  AND ($4::text IS NULL OR task_type = $4)
ORDER BY created_at DESC
LIMIT $5 OFFSET $6
```

---

### Get Task

```
GET /api/tenants/{tenant_slug}/task-executions/{task_id}
```

Returns detailed information for a single standalone task.

#### Response (200 OK)

Same schema as task object in list response.

#### Error Responses

| Status | Condition | Response |
|--------|-----------|----------|
| 403 | Not authorized | `{"error": "Forbidden"}` |
| 404 | Task not found | `{"error": "Task '...' not found"}` |
| 404 | Task has workflow | `{"error": "Task '...' is not a standalone task"}` |

**Note**: Returns 404 if task belongs to a workflow. Workflow tasks should be accessed via workflow endpoints.

---

### Cancel Task

```
DELETE /api/tenants/{tenant_slug}/task-executions/{task_id}
```

Cancels a pending standalone task.

#### Response (204 No Content)

Empty response on success.

#### Error Responses

| Status | Condition | Response |
|--------|-----------|----------|
| 400 | Task not PENDING | `{"error": "Task cannot be cancelled (not in PENDING state)"}` |
| 400 | Task has workflow | `{"error": "Cannot cancel workflow tasks via this endpoint"}` |
| 403 | Not authorized | `{"error": "Forbidden"}` |
| 404 | Task not found | `{"error": "Task '...' not found"}` |

#### Cancellation Rules

- Only `PENDING` tasks can be cancelled
- `RUNNING` tasks cannot be cancelled (worker owns execution)
- Terminal states (`COMPLETED`, `FAILED`, `CANCELLED`) are immutable

---

### Get Task Attempts

```
GET /api/tenants/{tenant_slug}/task-executions/{task_id}/attempts
```

Returns retry attempt history for a task.

#### Response (200 OK)

```json
{
  "attempts": [
    {
      "attempt": 1,
      "startedAt": "2025-01-15T10:00:05Z",
      "finishedAt": "2025-01-15T10:00:10Z",
      "durationMs": 5000,
      "status": "FAILED",
      "output": null,
      "error": "Connection timeout",
      "workerId": "worker-1"
    },
    {
      "attempt": 2,
      "startedAt": "2025-01-15T10:00:40Z",
      "finishedAt": "2025-01-15T10:00:45Z",
      "durationMs": 5000,
      "status": "COMPLETED",
      "output": {"messageId": "abc123"},
      "error": null,
      "workerId": "worker-2"
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `attempt` | integer | Attempt number (1-based) |
| `startedAt` | ISO 8601 | When worker started processing |
| `finishedAt` | ISO 8601 | When attempt ended |
| `durationMs` | integer | Execution duration in milliseconds |
| `status` | string | `COMPLETED`, `FAILED`, `TIMEOUT`, `CANCELLED` |
| `output` | object | Task output (if completed) |
| `error` | string | Error message (if failed) |
| `workerId` | string | Worker that executed this attempt |

---

### Get Task Logs

```
GET /api/tenants/{tenant_slug}/task-executions/{task_id}/logs
```

Returns structured logs emitted by the task during execution.

#### Query Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `level` | string | - | Filter by level: `DEBUG`, `INFO`, `WARN`, `ERROR` |
| `limit` | integer | `50` | Max results per page (1-100) |
| `offset` | integer | `0` | Results to skip for pagination |

#### Response (200 OK)

```json
{
  "logs": [
    {
      "level": "INFO",
      "message": "Processing email request",
      "timestamp": "2025-01-15T10:00:06Z",
      "metadata": {"recipient": "user@example.com"}
    },
    {
      "level": "ERROR",
      "message": "SMTP connection failed",
      "timestamp": "2025-01-15T10:00:08Z",
      "metadata": {"smtp_host": "mail.example.com", "error_code": "ETIMEDOUT"}
    }
  ],
  "total": 25,
  "limit": 50,
  "offset": 0
}
```

#### Error Responses

| Status | Condition | Response |
|--------|-----------|----------|
| 400 | Invalid log level | `{"error": "Invalid log level: X. Must be DEBUG, INFO, WARN, or ERROR"}` |

---

## Data Models

### TaskResponse

Complete task representation returned by all endpoints:

| Field | Type | Description |
|-------|------|-------------|
| `id` | UUID | Task execution identifier |
| `tenantId` | UUID | Tenant identifier |
| `taskType` | string | Task type (e.g., `send-email`) |
| `status` | string | Current status |
| `queue` | string | Task queue name |
| `executionCount` | integer | Number of execution attempts |
| `maxRetries` | integer | Maximum retry attempts |
| `progress` | float | Progress value (0.0 to 1.0) |
| `progressDetails` | string | Optional progress description |
| `input` | object | Task input data |
| `output` | object | Task output (if completed) |
| `error` | string | Error message (if failed) |
| `workerId` | string | Executing worker ID |
| `scheduledAt` | ISO 8601 | Scheduled execution time |
| `createdAt` | ISO 8601 | Creation timestamp |
| `startedAt` | ISO 8601 | Execution start timestamp |
| `completedAt` | ISO 8601 | Completion timestamp |

### Task Status State Machine

```
          ┌─────────────┐
          │   PENDING   │
          └──────┬──────┘
                 │ worker polls
                 ▼
          ┌─────────────┐
          │   RUNNING   │
          └──┬───────┬──┘
             │       │
    success  │       │ failure
             ▼       ▼
     ┌───────────┐  ┌─────────────────┐
     │ COMPLETED │  │ Check retries   │
     └───────────┘  └────┬───────┬────┘
                         │       │
            retries left │       │ max retries exceeded
                         ▼       ▼
                  ┌──────────┐  ┌────────┐
                  │ PENDING  │  │ FAILED │
                  │ (retry)  │  └────────┘
                  └──────────┘

      ┌─────────────┐
      │  CANCELLED  │ ← Only from PENDING via REST cancel
      └─────────────┘
```

---

## Authorization

Each endpoint performs authorization checks using the pluggable auth system:

| Endpoint | Action | Resource | Notes |
|----------|--------|----------|-------|
| `POST /task-executions` | `create` | `TaskExecution` | Checks tenant access |
| `GET /task-executions` | `list` | `TaskExecution` | Checks tenant access |
| `GET /task-executions/{id}` | `view` | `TaskExecution` | Checks specific task |
| `DELETE /task-executions/{id}` | `delete` | `TaskExecution` | Checks specific task |
| `GET /task-executions/{id}/attempts` | `view` | `TaskExecution` | Same as get task |
| `GET /task-executions/{id}/logs` | `view` | `TaskExecution` | Same as get task |

---

## Worker Integration

### Polling Standalone Tasks

Workers poll for standalone tasks via gRPC `PollTask`. The SQL query filters standalone tasks:

```sql
UPDATE task_execution
SET status = 'RUNNING',
    worker_id = $1,
    started_at = NOW(),
    last_heartbeat_at = NOW(),
    execution_count = execution_count + 1
WHERE id = (
    SELECT id FROM task_execution
    WHERE tenant_id = $2
      AND queue = $3
      AND task_type = ANY($4)
      AND status = 'PENDING'
      AND workflow_execution_id IS NULL  -- Standalone only
      AND (scheduled_at IS NULL OR scheduled_at <= NOW())
    ORDER BY scheduled_at ASC NULLS FIRST, created_at ASC
    LIMIT 1
    FOR UPDATE SKIP LOCKED
)
RETURNING *
```

Key behaviors:
- `workflow_execution_id IS NULL`: Only standalone tasks
- `scheduled_at` filter: Respects delayed execution
- `ORDER BY scheduled_at ASC NULLS FIRST`: Immediate tasks first, then by schedule
- `FOR UPDATE SKIP LOCKED`: Concurrent worker support

### Task Completion

Workers complete tasks via gRPC `CompleteTask` or `FailTask`. On completion:
1. Task status updated to `COMPLETED` or `FAILED`
2. `TaskAttempt` record created for audit trail
3. If failed and retries remaining, status reset to `PENDING`

---

## OpenAPI Integration

All endpoints are documented via utoipa macros:

```rust
#[utoipa::path(
    post,
    path = "/api/tenants/{tenant_slug}/task-executions",
    request_body = CreateTaskRequest,
    params(
        ("tenant_slug" = String, Path, description = "Tenant slug")
    ),
    responses(
        (status = 201, description = "Task created", body = TaskResponse),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 403, description = "Forbidden", body = ErrorResponse),
        (status = 404, description = "Tenant not found", body = ErrorResponse),
    ),
    tag = "Tasks"
)]
pub async fn create_task(...) { ... }
```

Access OpenAPI spec at:
- Swagger UI: `GET /api/docs`
- OpenAPI JSON: `flovyn-server/GET /api/docs/openapi.json`

---

## Security Considerations

1. **Input Validation**
   - Maximum input size: 1MB
   - Queue name: Max 100 characters
   - Task type: Required, non-empty

2. **Tenant Isolation**
   - All tasks scoped to tenant
   - Cross-tenant access prevented by auth layer
   - Task ownership verified before operations

3. **Authorization**
   - JWT required for all endpoints
   - Per-tenant, per-resource authorization
   - Worker tokens NOT valid (gRPC only)

---

## Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `flovyn_rest_task_created_total` | Counter | `tenant_id`, `task_type`, `queue` | Tasks created via REST |
| `flovyn_rest_task_cancelled_total` | Counter | `tenant_id` | Tasks cancelled via REST |
| `flovyn_rest_request_duration_seconds` | Histogram | `endpoint`, `status_code` | Request latency |

---

## Testing

### Integration Tests

```rust
#[tokio::test]
async fn test_standalone_task_lifecycle() {
    // Create task
    let response = client
        .post("/api/tenants/test/tasks")
        .json(&json!({
            "taskType": "send-email",
            "input": {"to": "test@example.com"}
        }))
        .send().await;
    assert_eq!(response.status(), 201);
    let task: TaskResponse = response.json().await;
    assert_eq!(task.status, "PENDING");

    // Worker polls and completes via gRPC
    // ...

    // Verify completion via REST
    let response = client
        .get(&format!("/api/tenants/test/tasks/{}", task.id))
        .send().await;
    let completed: TaskResponse = response.json().await;
    assert_eq!(completed.status, "COMPLETED");
}

#[tokio::test]
async fn test_task_cancellation() {
    // Create task
    let task = create_task(&client, "test-task").await;

    // Cancel
    let response = client
        .delete(&format!("/api/tenants/test/tasks/{}", task.id))
        .send().await;
    assert_eq!(response.status(), 204);

    // Verify cancelled
    let response = client
        .get(&format!("/api/tenants/test/tasks/{}", task.id))
        .send().await;
    let cancelled: TaskResponse = response.json().await;
    assert_eq!(cancelled.status, "CANCELLED");
}

#[tokio::test]
async fn test_scheduled_task_not_polled_early() {
    // Create task scheduled for future
    let task = client
        .post("/api/tenants/test/tasks")
        .json(&json!({
            "taskType": "delayed",
            "scheduledAt": "2099-01-01T00:00:00Z"
        }))
        .send().await.json().await;

    // Worker polls - should not receive task
    let polled = worker.poll_task("delayed", "default").await;
    assert!(polled.is_none());
}

#[tokio::test]
async fn test_retry_attempt_tracking() {
    // Create task, fail it multiple times, verify attempts
    let task = create_task(&client, "flaky-task").await;

    // Fail twice
    worker.fail_task(task.id, "Error 1").await;
    worker.fail_task(task.id, "Error 2").await;

    // Check attempts
    let response = client
        .get(&format!("/api/tenants/test/tasks/{}/attempts", task.id))
        .send().await;
    let attempts: ListTaskAttemptsResponse = response.json().await;
    assert_eq!(attempts.attempts.len(), 2);
    assert_eq!(attempts.attempts[0].status, "FAILED");
    assert_eq!(attempts.attempts[1].status, "FAILED");
}
```

---

## CLI Usage

```bash
# Create a standalone task
flovyn tasks create send-email --input '{"to": "user@example.com"}'

# Create with delayed execution
flovyn tasks create send-email --input-file email.json --scheduled-at "2025-01-15T10:00:00Z"

# Create with custom queue and retries
flovyn tasks create process-file --queue high-priority --max-retries 5 --input '{}'

# List all standalone tasks
flovyn tasks list

# List with filters
flovyn tasks list --status PENDING --queue default --limit 100

# Get task details
flovyn tasks get 550e8400-e29b-41d4-a716-446655440000

# Cancel a pending task
flovyn tasks cancel 550e8400-e29b-41d4-a716-446655440000

# View task attempts (retry history)
flovyn tasks attempts 550e8400-e29b-41d4-a716-446655440000

# View task logs
flovyn tasks logs 550e8400-e29b-41d4-a716-446655440000 --level ERROR

# JSON output for scripting
flovyn tasks list --output json | jq '.tasks[] | select(.status == "FAILED")'
```

---

## References

- [Standalone Tasks Design](./20251225_standalone_tasks.md)
- [REST Workflow Trigger](./20251217_rest_workflow_trigger.md)
- [Implementation Plan](../plans/20251225_standalone_tasks_implementation.md)
- [REST API Implementation](flovyn-server/server/src/api/rest/tasks.rs)
