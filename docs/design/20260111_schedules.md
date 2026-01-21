# Schedules Design

**Date:** 2026-01-11
**Status:** Draft
**Related:** [Eventhook M3 Design](./20260103_eventhook_milestone3_advanced_routing.md)

## Overview

Design a schedule system that allows users to trigger workflows or standalone tasks at specific times or on recurring intervals. This unifies the various trigger mechanisms into a single, auditable system.

## Goals

1. **One-time scheduling** - Trigger a workflow/task at a specific future time
2. **Recurring schedules** - Cron-like expressions for periodic execution
3. **Unified targeting** - Same target model as Eventhook (workflow or task)
4. **Audit trail** - Track who created schedules and execution history
5. **Management API** - CRUD operations for schedules with proper validation

## Non-Goals

- Complex calendar-based rules (e.g., "first Monday of each month excluding holidays")
- Backfill of missed executions (if scheduler was down)

## Current State Analysis

### Existing Trigger Mechanisms

| Mechanism | Type | Location |
|-----------|------|----------|
| `POST /workflow-executions` | Immediate workflow | REST API |
| `POST /task-executions` | Immediate task | REST API |
| `POST /task-executions` with `scheduled_at` | One-time delayed task | REST API |
| Eventhook routes | Event-driven workflow/task | Plugin |
| gRPC `StartWorkflow` / `SubmitTask` | Immediate (SDK) | gRPC API |

### Gaps

1. **No workflow delay** - Cannot schedule a workflow for future execution
2. **No recurrence** - No cron-like scheduling for either workflows or tasks
3. **No schedule management** - `scheduled_at` is fire-and-forget with no visibility
4. **No audit** - No tracking of who scheduled what

## Architecture

### Domain Model

```rust
/// A schedule defines when and what to execute
pub struct Schedule {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub name: String,
    pub description: Option<String>,

    // Timing
    pub schedule_type: ScheduleType,

    // What to execute
    pub target: ScheduleTarget,

    // State
    pub enabled: bool,
    pub next_run_at: Option<DateTime<Utc>>,  // NULL = no future runs
    pub last_run_at: Option<DateTime<Utc>>,
    pub run_count: i64,

    // Policies
    pub missed_run_policy: MissedRunPolicy,  // Default: Skip
    pub overlap_policy: OverlapPolicy,        // Default: Skip

    // Audit
    pub created_by: Option<String>,  // User ID or API key identifier
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ScheduleType {
    /// Execute once at a specific time
    Once {
        run_at: DateTime<Utc>
    },

    /// Execute on a recurring schedule
    Recurring {
        cron: String,                   // Cron expression (5 or 6 fields)
        timezone: Option<String>,       // IANA timezone (e.g., "America/New_York"), default UTC
        end_at: Option<DateTime<Utc>>,  // Optional end time
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ScheduleTarget {
    /// Start a workflow
    Workflow {
        workflow_kind: String,
        queue: Option<String>,
        input: Option<serde_json::Value>,
        metadata: Option<HashMap<String, String>>,
    },

    /// Submit a standalone task
    Task {
        task_kind: String,
        queue: Option<String>,
        input: Option<serde_json::Value>,
        max_retries: Option<i32>,
        metadata: Option<HashMap<String, String>>,
    },
}

/// What happens if a scheduled time passes while scheduler is down/overloaded
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum MissedRunPolicy {
    #[default]
    Skip,        // Only execute future runs (default) - prevents load spikes
    ExecuteOnce, // Run once on recovery, then resume normal schedule
}

/// What happens if a schedule triggers while previous run is still active
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum OverlapPolicy {
    #[default]
    Skip,           // Don't start if previous still running (default)
    Allow,          // Run concurrently
    CancelPrevious, // Cancel previous run, start new one
}
```

### Policy Reference

| Policy | Options | Default | Rationale |
|--------|---------|---------|-----------|
| `missedRunPolicy` | `skip`, `execute_once` | `skip` | Prevents load spikes after outage; stale runs rarely useful |
| `overlapPolicy` | `skip`, `allow`, `cancel_previous` | `skip` | Prevents resource exhaustion; most workflows shouldn't overlap |

These defaults match Temporal and Kubernetes CronJob behavior.

### Execution History

```rust
/// Record of each schedule execution
pub struct ScheduleRun {
    pub id: Uuid,
    pub schedule_id: Uuid,
    pub tenant_id: Uuid,

    pub scheduled_at: DateTime<Utc>,   // When it was supposed to run
    pub started_at: DateTime<Utc>,      // When execution started
    pub completed_at: Option<DateTime<Utc>>,

    pub status: ScheduleRunStatus,
    pub target_type: String,  // "workflow" or "task"
    pub target_id: Option<Uuid>,  // workflow_execution_id or task_execution_id
    pub error: Option<String>,
}

pub enum ScheduleRunStatus {
    Running,    // Execution in progress
    Completed,  // Target successfully created
    Failed,     // Failed to create target
    Skipped,    // Schedule was disabled or deleted before execution
}
```

## Database Schema

```sql
-- Migration: 20260111XXXXXX_schedules.sql

CREATE TABLE schedule (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenant(id),
    name VARCHAR(255) NOT NULL,
    description TEXT,

    -- Timing (stored as JSONB for flexibility)
    schedule_type JSONB NOT NULL,

    -- Target configuration
    target JSONB NOT NULL,

    -- State
    enabled BOOLEAN NOT NULL DEFAULT true,
    next_run_at TIMESTAMPTZ,
    last_run_at TIMESTAMPTZ,
    run_count BIGINT NOT NULL DEFAULT 0,

    -- Policies
    missed_run_policy VARCHAR(20) NOT NULL DEFAULT 'skip',
    overlap_policy VARCHAR(20) NOT NULL DEFAULT 'skip',

    -- Audit
    created_by VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT schedule_name_unique UNIQUE (tenant_id, name)
);

-- Index for scheduler polling
CREATE INDEX idx_schedule_next_run
    ON schedule(next_run_at)
    WHERE enabled = true AND next_run_at IS NOT NULL;

CREATE INDEX idx_schedule_tenant ON schedule(tenant_id);

CREATE TABLE schedule_run (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    schedule_id UUID NOT NULL REFERENCES schedule(id) ON DELETE CASCADE,
    tenant_id UUID NOT NULL REFERENCES tenant(id),

    scheduled_at TIMESTAMPTZ NOT NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,

    status VARCHAR(20) NOT NULL DEFAULT 'running',
    target_type VARCHAR(20) NOT NULL,
    target_id UUID,
    error TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_schedule_run_schedule ON schedule_run(schedule_id);
CREATE INDEX idx_schedule_run_tenant ON schedule_run(tenant_id);
CREATE INDEX idx_schedule_run_status ON schedule_run(schedule_id, status)
    WHERE status = 'running';
```

## Scheduler Integration

The existing `scheduler.rs` handles timer management. We extend it to also process schedules.

### Execution Loop

```rust
// In scheduler.rs - new function

async fn fire_due_schedules(&self) -> Result<(), SchedulerError> {
    let now = Utc::now();

    // Atomically find and lock due schedules (SELECT FOR UPDATE SKIP LOCKED)
    // This prevents duplicate execution across multiple server instances
    let due_schedules = self.schedule_repo
        .find_and_lock_due_schedules(now, BATCH_SIZE)
        .await?;

    for schedule in due_schedules {
        // Create run record
        let run = self.schedule_repo
            .create_run(&schedule, now)
            .await?;

        // Execute target
        let result = self.execute_schedule_target(&schedule).await;

        // Update run record
        match result {
            Ok(target_id) => {
                self.schedule_repo.complete_run(
                    &run.id,
                    ScheduleRunStatus::Completed,
                    Some(target_id),
                    None
                ).await?;
            }
            Err(e) => {
                self.schedule_repo.complete_run(
                    &run.id,
                    ScheduleRunStatus::Failed,
                    None,
                    Some(e.to_string())
                ).await?;
            }
        }

        // Calculate and update next_run_at
        let next = calculate_next_run(&schedule.schedule_type, now);
        self.schedule_repo.update_next_run(&schedule.id, next).await?;
    }

    Ok(())
}

async fn execute_schedule_target(&self, schedule: &Schedule) -> Result<Uuid, Error> {
    match &schedule.target {
        ScheduleTarget::Workflow { workflow_kind, queue, input, metadata } => {
            let execution = self.workflow_service.create_execution(
                schedule.tenant_id,
                workflow_kind,
                input.clone().unwrap_or(json!({})),
                queue.clone().unwrap_or("default".to_string()),
                metadata.clone(),
            ).await?;
            Ok(execution.id)
        }
        ScheduleTarget::Task { task_kind, queue, input, max_retries, metadata } => {
            let execution = self.task_service.create_execution(
                schedule.tenant_id,
                task_kind,
                input.clone().unwrap_or(json!({})),
                queue.clone().unwrap_or("default".to_string()),
                *max_retries,
                None, // No scheduled_at - execute immediately
                metadata.clone(),
            ).await?;
            Ok(execution.id)
        }
    }
}
```

### Cron Parsing

Use the `cron` crate with `chrono-tz` for timezone-aware scheduling:

```rust
use cron::Schedule as CronSchedule;
use chrono_tz::Tz;

fn calculate_next_run(
    schedule_type: &ScheduleType,
    after: DateTime<Utc>
) -> Option<DateTime<Utc>> {
    match schedule_type {
        ScheduleType::Once { run_at } => {
            if *run_at > after {
                Some(*run_at)
            } else {
                None  // Already executed
            }
        }
        ScheduleType::Recurring { cron, timezone, end_at } => {
            let schedule: CronSchedule = cron.parse().ok()?;

            // Parse timezone, default to UTC
            let tz: Tz = timezone
                .as_ref()
                .and_then(|s| s.parse().ok())
                .unwrap_or(chrono_tz::UTC);

            // Convert to target timezone, find next occurrence, convert back to UTC
            let after_local = after.with_timezone(&tz);
            let next_local = schedule.after(&after_local).next()?;
            let next_utc = next_local.with_timezone(&Utc);

            // Check end_at constraint
            if let Some(end) = end_at {
                if next_utc > *end {
                    return None;
                }
            }

            Some(next_utc)
        }
    }
}
```

### Timezone and DST Handling

The `chrono-tz` crate handles DST transitions automatically:

| DST Scenario | Behavior |
|--------------|----------|
| Spring forward (e.g., 2 AM → 3 AM) | Non-existent times are skipped to next valid time |
| Fall back (e.g., 2 AM → 1 AM) | Ambiguous times run once (first occurrence) |

**Example:** A job scheduled for "0 2 * * *" (2:00 AM) in `America/New_York`:
- On March 9, 2026 (spring forward): Runs at 3:00 AM local (skips non-existent 2 AM)
- On November 1, 2026 (fall back): Runs once at the first 2:00 AM

### Distributed Execution (Multiple Server Instances)

When running multiple server instances, we use PostgreSQL's `SELECT FOR UPDATE SKIP LOCKED` to ensure exactly-once execution. This pattern is already used in the codebase for task polling.

```sql
-- find_and_lock_due_schedules
WITH due AS (
    SELECT id
    FROM schedule
    WHERE enabled = true
      AND next_run_at IS NOT NULL
      AND next_run_at <= $1  -- now
    ORDER BY next_run_at
    LIMIT $2  -- batch size
    FOR UPDATE SKIP LOCKED
)
UPDATE schedule
SET next_run_at = NULL  -- temporarily clear to prevent re-selection
WHERE id IN (SELECT id FROM due)
RETURNING *;
```

**How it works:**

| Instance A | Instance B | Result |
|------------|------------|--------|
| Locks schedule X | Tries to lock X | B skips X (SKIP LOCKED) |
| Executes X | Locks schedule Y | Both execute different schedules |
| Updates next_run_at | Executes Y | No duplicates |

**Why this approach:**
- **No external dependencies** - Uses PostgreSQL only (no Redis/Zookeeper)
- **Battle-tested** - Same pattern used for task polling in this codebase
- **Scales horizontally** - More instances = faster schedule processing
- **Automatic failover** - If instance crashes, lock is released on connection close

**Implementation in repository:**

```rust
impl ScheduleRepository {
    /// Atomically find and lock due schedules for execution
    pub async fn find_and_lock_due_schedules(
        &self,
        now: DateTime<Utc>,
        batch_size: i32,
    ) -> Result<Vec<Schedule>, Error> {
        sqlx::query_as!(
            Schedule,
            r#"
            WITH due AS (
                SELECT id FROM schedule
                WHERE enabled = true
                  AND next_run_at IS NOT NULL
                  AND next_run_at <= $1
                ORDER BY next_run_at
                LIMIT $2
                FOR UPDATE SKIP LOCKED
            )
            UPDATE schedule
            SET next_run_at = NULL
            WHERE id IN (SELECT id FROM due)
            RETURNING *
            "#,
            now,
            batch_size
        )
        .fetch_all(&self.pool)
        .await
    }
}
```

### Cron Expression Format

Support standard 5-field cron format plus optional seconds:

```
┌───────────── second (0-59) [optional]
│ ┌───────────── minute (0-59)
│ │ ┌───────────── hour (0-23)
│ │ │ ┌───────────── day of month (1-31)
│ │ │ │ ┌───────────── month (1-12)
│ │ │ │ │ ┌───────────── day of week (0-6, Sun=0)
│ │ │ │ │ │
* * * * * *
```

**Examples:**
| Expression | Meaning |
|------------|---------|
| `0 * * * *` | Every hour at minute 0 |
| `*/15 * * * *` | Every 15 minutes |
| `0 9 * * 1-5` | 9 AM on weekdays |
| `0 0 1 * *` | Midnight on first of each month |
| `30 4 * * *` | 4:30 AM daily |

## REST API

### Endpoints

```
POST   /api/tenants/{tenant_slug}/schedules           Create schedule
GET    /api/tenants/{tenant_slug}/schedules           List schedules
GET    /api/tenants/{tenant_slug}/schedules/{id}      Get schedule
PUT    /api/tenants/{tenant_slug}/schedules/{id}      Update schedule
DELETE /api/tenants/{tenant_slug}/schedules/{id}      Delete schedule

POST   /api/tenants/{tenant_slug}/schedules/{id}/pause    Pause (disable)
POST   /api/tenants/{tenant_slug}/schedules/{id}/resume   Resume (enable)
POST   /api/tenants/{tenant_slug}/schedules/{id}/trigger  Trigger immediately

GET    /api/tenants/{tenant_slug}/schedules/{id}/runs     List execution history
```

### Request/Response Examples

**Create One-Time Schedule:**
```json
POST /api/tenants/acme/schedules

{
  "name": "year-end-report",
  "description": "Generate year-end financial report",
  "scheduleType": {
    "type": "once",
    "runAt": "2026-12-31T23:59:00Z"
  },
  "target": {
    "type": "workflow",
    "workflowKind": "generate-report",
    "input": { "reportType": "annual", "year": 2026 }
  }
}
```

**Create Recurring Schedule:**
```json
POST /api/tenants/acme/schedules

{
  "name": "daily-report",
  "description": "Generate daily sales report at 9 AM Eastern",
  "scheduleType": {
    "type": "recurring",
    "cron": "0 9 * * *",
    "timezone": "America/New_York"
  },
  "target": {
    "type": "workflow",
    "workflowKind": "generate-sales-report",
    "input": { "reportType": "daily" }
  }
}
```

**Response:**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "name": "daily-report",
  "description": "Generate daily sales report at 9 AM Eastern",
  "scheduleType": {
    "type": "recurring",
    "cron": "0 9 * * *",
    "timezone": "America/New_York"
  },
  "target": {
    "type": "workflow",
    "workflowKind": "generate-sales-report",
    "input": { "reportType": "daily" }
  },
  "enabled": true,
  "nextRunAt": "2026-01-12T14:00:00Z",
  "nextRunAtLocal": "2026-01-12T09:00:00",
  "lastRunAt": null,
  "runCount": 0,
  "createdBy": "user:john@example.com",
  "createdAt": "2026-01-11T14:30:00Z",
  "updatedAt": "2026-01-11T14:30:00Z"
}
```

**Trigger Immediately:**
```json
POST /api/tenants/acme/schedules/{id}/trigger

{}
```

Response returns the created workflow/task execution.

### Validation Rules

1. **Name**: Required, unique per tenant, 1-255 characters
2. **Cron expression**: Validated at creation, must be parseable
3. **Timezone**: Must be valid IANA timezone (e.g., "America/New_York", "Europe/London")
4. **One-time `runAt`**: Must be in the future (with small grace period)
5. **Target kind**: Must reference an existing workflow/task definition (optional strict mode)
6. **Metadata**: Same limits as workflows (max depth 3, max 100 keys)

## Unifying with Existing APIs

### Option A: Separate Schedule Entity (Recommended)

Keep schedules as a distinct entity. The existing "immediate" APIs remain unchanged.

**Pros:**
- Clear separation of concerns
- Full audit trail for scheduled executions
- Easy to manage (pause/resume/delete) before execution
- Consistent with Eventhook's approach

**Cons:**
- Users must learn new API for scheduling

### Option B: Extend Existing APIs

Add `scheduledAt` and `cron` parameters to existing workflow/task creation APIs.

```json
POST /api/tenants/acme/workflow-executions
{
  "kind": "my-workflow",
  "input": {},
  "scheduledAt": "2026-01-15T10:00:00Z"  // New field
}
```

**Pros:**
- Familiar API surface

**Cons:**
- Muddles immediate vs scheduled execution
- Harder to manage scheduled executions
- No recurring support without significant API changes
- Loss of audit capabilities

### Recommendation

**Use Option A (separate Schedule entity)** for the following reasons:
1. Schedules are long-lived resources that need management
2. Recurring schedules don't fit the "execution" model
3. Audit and observability requirements are better served
4. Consistent with industry patterns (Temporal, Airflow, etc.)

## Migration: Remove Existing `scheduled_at`

The current `scheduled_at` field on tasks will be **removed** to avoid user confusion. All scheduling should go through the Schedules API.

### Migration Steps

1. **Deprecation notice** - Document that `scheduled_at` is deprecated
2. **API change** - Remove `scheduled_at` from `POST /task-executions` request
3. **Database migration** - Drop `scheduled_at` column from `task_execution` table
4. **Update polling query** - Remove `scheduled_at` filter from task polling

### User Migration

Users currently using `scheduled_at` should migrate to:

```json
// Before: Fire-and-forget delayed task
POST /api/tenants/acme/task-executions
{
  "kind": "send-reminder",
  "input": { "userId": "123" },
  "scheduledAt": "2026-01-15T10:00:00Z"
}

// After: Managed one-time schedule
POST /api/tenants/acme/schedules
{
  "name": "reminder-user-123",
  "scheduleType": {
    "type": "once",
    "runAt": "2026-01-15T10:00:00Z"
  },
  "target": {
    "type": "task",
    "taskKind": "send-reminder",
    "input": { "userId": "123" }
  }
}
```

**Benefits of migration:**
- Visibility: Can see pending scheduled work
- Management: Can cancel/modify before execution
- Audit: Track who scheduled what and execution history

## UI Considerations for Business Users

Business users need to understand schedules without thinking in UTC. The API supports this by:

### Response Fields

| Field | Description |
|-------|-------------|
| `nextRunAt` | Next execution time in UTC (ISO 8601) |
| `nextRunAtLocal` | Next execution time in schedule's timezone (no TZ suffix) |
| `lastRunAt` | Last execution time in UTC |

### Cron Description

Consider adding a human-readable description of the cron schedule:

```json
{
  "scheduleType": {
    "type": "recurring",
    "cron": "0 9 * * 1-5",
    "timezone": "America/New_York",
    "description": "Every weekday at 9:00 AM"  // Generated by server
  }
}
```

Libraries like `cron-descriptor` (or Rust equivalent) can generate these descriptions.

### Timezone Picker

The UI should provide:
- Searchable timezone dropdown with common timezones at top
- Current time in selected timezone as preview
- Clear indication when DST applies

## Security Considerations

1. **Authorization**: Schedules follow tenant isolation (same as workflows/tasks)
2. **Rate limiting**: Limit number of schedules per tenant
3. **Cron frequency limits**: Prevent sub-minute schedules (or make configurable)
4. **Input size limits**: Same as workflow/task input limits

## Observability

### Metrics

- `flovyn_schedules_total{tenant, state}` - Total schedules by state
- `flovyn_schedule_runs_total{tenant, status, target_type}` - Execution counts
- `flovyn_schedule_run_latency_seconds{tenant}` - Time from scheduled_at to started_at

### Logging

```rust
tracing::info!(
    schedule_id = %schedule.id,
    schedule_name = %schedule.name,
    tenant_id = %schedule.tenant_id,
    target_type = %target_type,
    "Executing scheduled run"
);
```

## Dependencies

Add to `Cargo.toml`:

```toml
[dependencies]
cron = "0.12"       # Cron expression parsing
chrono-tz = "0.8"   # Timezone support (IANA database)
```

## Testing Strategy

### Unit Tests

- `test_cron_parsing_valid_expressions`
- `test_cron_parsing_invalid_expressions`
- `test_next_run_calculation_once`
- `test_next_run_calculation_recurring`
- `test_next_run_with_end_at`
- `test_next_run_with_timezone`
- `test_next_run_dst_spring_forward`
- `test_next_run_dst_fall_back`
- `test_timezone_validation`
- `test_schedule_target_serialization`

### Integration Tests

- `test_create_one_time_schedule`
- `test_create_recurring_schedule`
- `test_schedule_fires_at_correct_time`
- `test_schedule_creates_workflow`
- `test_schedule_creates_task`
- `test_pause_resume_schedule`
- `test_trigger_immediately`
- `test_schedule_run_history`
- `test_recurring_schedule_calculates_next_run`
- `test_one_time_schedule_clears_after_execution`
- `test_overlap_policy_skip`
- `test_overlap_policy_allow`
- `test_overlap_policy_cancel_previous`
- `test_missed_run_policy_skip`
- `test_missed_run_policy_execute_once`
- `test_concurrent_schedulers_no_duplicate_execution`

## Out of Scope

- **gRPC API**: Schedule management is REST-only (UI/admin use case, not SDK)

## Exit Criteria

Schedule system is complete when:

**Core:**
- [ ] Schedule entity with one-time and recurring types
- [ ] Database schema and migrations
- [ ] Scheduler integration for firing due schedules
- [ ] Distributed locking (SELECT FOR UPDATE SKIP LOCKED)
- [ ] Cron expression parsing and validation
- [ ] Timezone-aware scheduling with DST handling
- [ ] Missed run policy (skip, execute_once)
- [ ] Overlap policy (skip, allow, cancel_previous)

**API:**
- [ ] CRUD endpoints for schedules
- [ ] Pause/resume/trigger actions
- [ ] Execution history endpoint
- [ ] Response includes `nextRunAtLocal` for business user display
- [ ] Human-readable cron description in response
- [ ] OpenAPI documentation

**Targets:**
- [ ] Workflow target creates workflow execution
- [ ] Task target creates task execution
- [ ] Input and metadata pass-through

**Observability:**
- [ ] Execution history records (schedule_run table)
- [ ] Metrics for schedule counts and execution status
- [ ] Structured logging for schedule operations

**Migration:**
- [ ] Remove `scheduled_at` from task creation API
- [ ] Drop `scheduled_at` column from `task_execution` table
- [ ] Update task polling query

**Testing:**
- [ ] Unit tests for cron parsing and next-run calculation
- [ ] Integration tests for schedule lifecycle
- [ ] Integration tests for target execution

## References

- [Eventhook M3 Design](./20260103_eventhook_milestone3_advanced_routing.md) - Target model reference
- [Temporal Schedules](https://docs.temporal.io/workflows#schedule) - Industry reference
- [cron crate](https://crates.io/crates/cron) - Rust cron parsing
