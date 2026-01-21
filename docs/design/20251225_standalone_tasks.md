# Standalone Tasks

Standalone tasks allow executing tasks outside of workflow context - useful for one-off operations, scheduled jobs, or simple task execution without workflow overhead.

## Background

The Kotlin server (`/Users/manhha/Developer/manhha/leanapp/flovyn`) has a mature standalone tasks implementation. This document adapts that design for the Rust server while simplifying where possible.

**Key difference from Kotlin**: The Rust server already has `workflow_execution_id: Option<Uuid>` in the task model, so the schema is partially ready.

## Goals

- Execute tasks without workflow overhead
- Queue-based task routing
- Full task lifecycle visibility via REST API
- Scheduled/delayed task execution
- Retry support with attempt history

## Non-Goals

- Task scheduling (CRON/INTERVAL) - separate feature
- Worker pools - use queue-based routing instead
- Label-based matching - simplify to queue routing only
- Visual workflow integration

## Design

### Domain Model Changes

The existing `TaskExecution` struct needs minimal changes:

```rust
pub struct TaskExecution {
    // Existing fields...
    pub workflow_execution_id: Option<Uuid>,  // Already optional

    // New fields for standalone tasks
    pub scheduled_at: Option<DateTime<Utc>>,  // For delayed execution
}
```

A task is standalone when `workflow_execution_id.is_none()`.

### REST API

Base path: `/api/tenants/{tenant_id}/tasks`

#### Create Standalone Task

```
POST /api/tenants/{tenant_id}/tasks
```

Request:
```json
{
  "task_type": "send-email",
  "input": {"to": "user@example.com", "subject": "Hello"},
  "queue": "default",
  "max_retries": 3,
  "scheduled_at": "2025-01-15T10:00:00Z"
}
```

Response (201 Created):
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "tenant_id": "acme-tenant-id",
  "task_type": "send-email",
  "status": "PENDING",
  "input": {"to": "user@example.com", "subject": "Hello"},
  "queue": "default",
  "execution_count": 0,
  "max_retries": 3,
  "progress": 0.0,
  "created_at": "2025-01-15T09:00:00Z",
  "scheduled_at": "2025-01-15T10:00:00Z"
}
```

#### List Standalone Tasks

```
GET /api/tenants/{tenant_id}/tasks
```

Query Parameters:
- `status` - Filter by status (PENDING, RUNNING, COMPLETED, FAILED)
- `queue` - Filter by queue name
- `task_type` - Filter by task type
- `limit` - Max results (default 50, max 100)
- `offset` - Pagination offset

Response:
```json
{
  "tasks": [...],
  "total": 150,
  "limit": 50,
  "offset": 0
}
```

#### Get Task

```
GET /api/tenants/{tenant_id}/tasks/{task_id}
```

Response:
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "tenant_id": "acme-tenant-id",
  "task_type": "send-email",
  "status": "COMPLETED",
  "input": {"to": "user@example.com", "subject": "Hello"},
  "output": {"message_id": "abc123"},
  "queue": "default",
  "execution_count": 1,
  "max_retries": 3,
  "progress": 1.0,
  "worker_id": "worker-1",
  "created_at": "2025-01-15T09:00:00Z",
  "started_at": "2025-01-15T10:00:05Z",
  "completed_at": "2025-01-15T10:00:30Z"
}
```

#### Cancel Task

```
DELETE /api/tenants/{tenant_id}/tasks/{task_id}
```

Only PENDING tasks can be cancelled. Returns 204 on success.

#### Get Task Attempts

```
GET /api/tenants/{tenant_id}/tasks/{task_id}/attempts
```

Response:
```json
{
  "attempts": [
    {
      "attempt": 1,
      "started_at": "2025-01-15T10:00:05Z",
      "finished_at": "2025-01-15T10:00:10Z",
      "duration_ms": 5000,
      "status": "FAILED",
      "error": "Connection timeout",
      "worker_id": "worker-1"
    },
    {
      "attempt": 2,
      "started_at": "2025-01-15T10:00:40Z",
      "finished_at": "2025-01-15T10:00:45Z",
      "duration_ms": 5000,
      "status": "COMPLETED",
      "output": {"message_id": "abc123"},
      "worker_id": "worker-2"
    }
  ]
}
```

### Worker Polling

Workers poll for standalone tasks via gRPC `PollTask` RPC:

```protobuf
message PollTaskRequest {
  string worker_id = 1;
  repeated string task_types = 2;
  string queue = 3;  // New: queue to poll from
}
```

SQL for polling standalone tasks:

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

### Database Changes

#### Migration: Add `scheduled_at` Column

```sql
ALTER TABLE task_execution ADD COLUMN scheduled_at TIMESTAMPTZ;

-- Index for standalone task polling
CREATE INDEX idx_task_standalone_poll
    ON task_execution (tenant_id, queue, status, scheduled_at)
    WHERE workflow_execution_id IS NULL AND status = 'PENDING';
```

#### New Table: `task_attempt`

```sql
CREATE TABLE task_attempt (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_execution_id UUID NOT NULL REFERENCES task_execution(id) ON DELETE CASCADE,
    attempt INT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL,
    finished_at TIMESTAMPTZ NOT NULL,
    status VARCHAR(20) NOT NULL,  -- COMPLETED, FAILED, TIMEOUT, CANCELLED
    output BYTEA,
    error TEXT,
    worker_id VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE(task_execution_id, attempt)
);

CREATE INDEX idx_task_attempt_task ON task_attempt(task_execution_id);
```

### Retry Flow

```
Task FAILS
    │
    ▼
Create task_attempt record (status=FAILED)
    │
    ▼
Check: execution_count < max_retries?
    │
    ├── YES: Set status=PENDING, increment execution_count
    │        (Will be picked up by next poll)
    │
    └── NO: Set status=FAILED, set completed_at
            (Task is terminal)
```

### Implementation Notes

1. **Reuse existing task infrastructure** - The existing `TaskExecution` and `TaskRepository` can be extended rather than creating new types.

2. **Queue-based routing over labels** - Simpler than Kotlin's label matching. Workers poll specific queues.

3. **No worker pools initially** - Use queue isolation instead of worker pool isolation.

4. **Attempt tracking** - New `task_attempt` table provides full retry history.

5. **Scheduled execution** - `scheduled_at` field allows delayed task execution without a separate scheduler.

## Comparison with Kotlin

| Feature | Kotlin | Rust (Proposed) |
|---------|--------|-----------------|
| Standalone tasks | Yes | Yes |
| Queue routing | Yes | Yes |
| Worker pools | Yes | No (use queues) |
| Label matching | Yes | No (simplify) |
| CRON scheduling | Yes | No (separate feature) |
| Interval scheduling | Yes | No (separate feature) |
| One-time scheduling | Yes | Yes (`scheduled_at`) |
| Attempt history | Yes | Yes |
| Task logs | Yes | Deferred |
| Manual resolution | Yes | Deferred |

## API Differences from Workflow Tasks

| Aspect | Workflow Tasks | Standalone Tasks |
|--------|----------------|------------------|
| Creation | gRPC `ScheduleTask` command | REST POST |
| Parent | Has `workflow_execution_id` | No parent |
| Visibility | Via workflow events | Direct REST |
| Polling | `PollTask` with workflow context | `PollTask` without workflow |

## Testing

1. **Unit tests**: Task creation, status transitions, retry logic
2. **Integration tests**: Full lifecycle via REST and gRPC
3. **E2E tests**: Worker polling and completing standalone tasks
