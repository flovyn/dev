# Workload Discovery Design

## Problem Statement

The Flovyn server currently accepts worker registration with workflow and task capabilities, but provides no way to discover what workloads are available in the system. Users cannot:
- List registered workers and their status
- See which workflows and tasks are available for execution
- Find which workers can execute a specific workflow or task kind
- Browse capability metadata (descriptions, timeouts, versions)

This makes it difficult to use the CLI effectively since users must know workflow/task kinds ahead of time.

**Relation to Standalone Tasks**: With standalone tasks (see `standalone-tasks.md`), tasks become first-class citizens that can be triggered directly via REST API. Task discovery is essential so users can browse available task types before creating standalone tasks.

## Goals

1. **Worker Discovery**: List and inspect registered workers with their status and capabilities
2. **Capability Discovery**: List all available workflow and task kinds across the system
3. **CLI Integration**: Expose discovery through the flovyn CLI for browsing and operational visibility
4. **Persist Capability Metadata**: Store rich capability metadata (name, description, timeout, tags) that is currently accepted but discarded

## Non-Goals

- Worker health dashboard or real-time monitoring (future work)
- Automatic worker failover or load balancing
- REST API for worker registration (workers register via gRPC only)
- Execution-based discovery (inferring capabilities from execution history)

## Current State

### What Exists

**gRPC Registration** (`WorkerLifecycle` service):
- `RegisterWorker` - Workers register with capabilities
- `SendHeartbeat` - Workers send periodic heartbeats

**Database Tables**:
```sql
worker (id, tenant_id, worker_name, worker_version, worker_type, host_name, process_id, last_heartbeat_at, metadata)
worker_workflow_capability (id, worker_id, kind, version, content_hash)
worker_task_capability (id, worker_id, kind)
```

**Repository Methods**:
- `upsert()`, `find_by_name()`, `get()`, `heartbeat()`
- `clear_capabilities()`, `add_workflow_capabilities()`, `add_task_capabilities()`

### What's Missing

1. **Schema**: Rich capability metadata (name, description, timeout, tags, schemas) is not stored
2. **Repository**: No list/query methods for workers or capabilities
3. **REST API**: No discovery endpoints
4. **gRPC**: No discovery service
5. **CLI**: No discovery commands
6. **REST Client**: No discovery methods

## Design

### Database Schema Changes

The Kotlin implementation uses a **normalized schema** with separate `workflow_definition` and `task_definition` tables to store metadata. Worker capability tables are join tables linking workers to definitions.

#### Kotlin Schema (Normalized)

```
┌─────────────────────────┐     ┌──────────────────────────────┐     ┌─────────────────────────┐
│ workflow_definition     │     │ worker_workflow_capability   │     │ worker                  │
├─────────────────────────┤     ├──────────────────────────────┤     ├─────────────────────────┤
│ id                      │◄────│ workflow_definition_id       │     │ id                      │
│ tenant_id, space_id     │     │ worker_id ─────────────────────────►│ tenant_id, space_id     │
│ kind (unique per space) │     │ version                      │     │ worker_name             │
│ name, description       │     │ registered_at                │     │ status                  │
│ timeout_seconds         │     └──────────────────────────────┘     │ last_heartbeat_at       │
│ retry_policy (JSONB)    │                                          └─────────────────────────┘
│ tags[], cancellable     │
│ availability_status     │
│ first_seen_at           │
│ last_registered_at      │
└─────────────────────────┘

┌─────────────────────────┐     ┌──────────────────────────────┐
│ task_definition         │     │ worker_task_capability       │
├─────────────────────────┤     ├──────────────────────────────┤
│ id                      │◄────│ task_definition_id           │
│ tenant_id, space_id     │     │ worker_id                    │
│ kind (unique per space) │     │ registered_at                │
│ name, description       │     └──────────────────────────────┘
│ timeout_seconds         │
│ retry_policy (JSONB)    │
│ tags[], cancellable     │
│ input_schema (JSONB)    │
│ output_schema (JSONB)   │
│ availability_status     │
│ first_seen_at           │
│ last_registered_at      │
└─────────────────────────┘
```

#### Current Rust vs Target (aligned with Kotlin)

| Aspect | Rust (Current) | Target |
|--------|----------------|--------|
| Schema design | Denormalized | Normalized (definition tables) |
| Definition tables | None | `workflow_definition`, `task_definition` |
| Capability tables | Store `kind`, `version` | Join tables with FK to definition |
| Worker table | No `space_id`, no `status` | Has `space_id`, `status`, `registered_at` |
| Availability tracking | None | `availability_status` on definitions |

#### Migration Script

New migration file (e.g., `20251225_workload_discovery.sql`). No data migration needed - just drop and recreate.

```sql
-- Drop existing capability tables (no data to preserve in MVP)
DROP TABLE IF EXISTS worker_task_capability;
DROP TABLE IF EXISTS worker_workflow_capability;
DROP TABLE IF EXISTS worker;


-- ============================================================================
-- Worker (extended)
-- ============================================================================
CREATE TABLE worker (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    space_id UUID REFERENCES space(id) ON DELETE SET NULL,
    worker_name VARCHAR(255) NOT NULL,
    worker_version VARCHAR(50),
    worker_type VARCHAR(50) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'ONLINE',
    host_name VARCHAR(255),
    process_id VARCHAR(100),
    registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB,

    CONSTRAINT worker_type_check CHECK (worker_type IN ('WORKFLOW', 'TASK', 'UNIFIED')),
    CONSTRAINT worker_status_check CHECK (status IN ('ONLINE', 'OFFLINE', 'DEGRADED'))
);

CREATE INDEX idx_worker_tenant ON worker(tenant_id);
CREATE INDEX idx_worker_space ON worker(space_id);
CREATE INDEX idx_worker_status ON worker(status);
CREATE INDEX idx_worker_heartbeat ON worker(last_heartbeat_at);

-- ============================================================================
-- Workflow Definition
-- ============================================================================
CREATE TABLE workflow_definition (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    space_id UUID REFERENCES space(id) ON DELETE SET NULL,
    kind VARCHAR(255) NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    timeout_seconds INT,
    retry_policy JSONB,
    tags TEXT[],
    cancellable BOOLEAN NOT NULL DEFAULT false,
    latest_version VARCHAR(50),
    availability_status VARCHAR(50) NOT NULL DEFAULT 'AVAILABLE',
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_registered_at TIMESTAMPTZ,
    metadata JSONB,

    CONSTRAINT workflow_definition_tenant_space_kind_unique UNIQUE (tenant_id, space_id, kind),
    CONSTRAINT workflow_definition_availability_check CHECK (availability_status IN ('AVAILABLE', 'UNAVAILABLE', 'DEGRADED'))
);

CREATE INDEX idx_workflow_definition_tenant ON workflow_definition(tenant_id);
CREATE INDEX idx_workflow_definition_kind ON workflow_definition(kind);
CREATE INDEX idx_workflow_definition_availability ON workflow_definition(availability_status);

-- ============================================================================
-- Task Definition
-- ============================================================================
CREATE TABLE task_definition (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    space_id UUID REFERENCES space(id) ON DELETE SET NULL,
    kind VARCHAR(255) NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    timeout_seconds INT,
    retry_policy JSONB,
    tags TEXT[],
    cancellable BOOLEAN NOT NULL DEFAULT false,
    input_schema JSONB,
    output_schema JSONB,
    availability_status VARCHAR(50) NOT NULL DEFAULT 'AVAILABLE',
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_registered_at TIMESTAMPTZ,
    metadata JSONB,

    CONSTRAINT task_definition_tenant_space_kind_unique UNIQUE (tenant_id, space_id, kind),
    CONSTRAINT task_definition_availability_check CHECK (availability_status IN ('AVAILABLE', 'UNAVAILABLE', 'DEGRADED'))
);

CREATE INDEX idx_task_definition_tenant ON task_definition(tenant_id);
CREATE INDEX idx_task_definition_kind ON task_definition(kind);
CREATE INDEX idx_task_definition_availability ON task_definition(availability_status);

-- ============================================================================
-- Worker Capabilities (join tables)
-- ============================================================================
CREATE TABLE worker_workflow_capability (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    worker_id UUID NOT NULL REFERENCES worker(id) ON DELETE CASCADE,
    workflow_definition_id UUID NOT NULL REFERENCES workflow_definition(id) ON DELETE CASCADE,
    version VARCHAR(50),
    registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT worker_workflow_cap_unique UNIQUE(worker_id, workflow_definition_id)
);

CREATE INDEX idx_worker_workflow_cap_worker ON worker_workflow_capability(worker_id);
CREATE INDEX idx_worker_workflow_cap_definition ON worker_workflow_capability(workflow_definition_id);

CREATE TABLE worker_task_capability (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    worker_id UUID NOT NULL REFERENCES worker(id) ON DELETE CASCADE,
    task_definition_id UUID NOT NULL REFERENCES task_definition(id) ON DELETE CASCADE,
    registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT worker_task_cap_unique UNIQUE(worker_id, task_definition_id)
);

CREATE INDEX idx_worker_task_cap_worker ON worker_task_capability(worker_id);
CREATE INDEX idx_worker_task_cap_definition ON worker_task_capability(task_definition_id);
```

**Simplified from Kotlin**: Removed `discovery_source` and `archived_at` fields - can add later if needed.

#### Schema Design Notes

**Normalized vs Denormalized**: Kotlin uses normalized schema because:
- Workflow/task metadata is shared across workers (stored once)
- Availability tracking at definition level (not per-worker)
- Supports archival and discovery source tracking
- Enables listing "all workflows" without scanning worker capabilities

**Discovery Source**: Tracks how a definition was discovered:
- `REGISTRATION` - Worker registered this capability
- `EXECUTION` - Discovered from workflow execution history (fallback when registration disabled)

**Availability Status**: Tracks if workload can be executed:
- `AVAILABLE` - At least one online worker supports it
- `UNAVAILABLE` - No workers online
- `DEGRADED` - Some workers online but reduced capacity

**Space Isolation**: `UNIQUE(tenant_id, space_id, kind)` allows same workflow kind in different spaces.

**Version Tracking**: `latest_version` on definition + `version` on capability link enables version locking.

### Repository Layer

With the normalized schema, we need repositories for definitions and workers:

#### WorkflowDefinitionRepository

```rust
pub trait WorkflowDefinitionRepository: Send + Sync {
    // Find or create definition during worker registration
    async fn upsert(&self, definition: &WorkflowDefinition) -> Result<Uuid, PersistenceError>;

    // Get by ID
    async fn get(&self, id: Uuid) -> Result<Option<WorkflowDefinition>, PersistenceError>;

    // Find by kind within tenant/space
    async fn find_by_kind(&self, tenant_id: Uuid, space_id: Option<Uuid>, kind: &str)
        -> Result<Option<WorkflowDefinition>, PersistenceError>;

    // List all definitions for a tenant (for discovery)
    async fn list(&self, tenant_id: Uuid, params: ListDefinitionsParams)
        -> Result<Vec<WorkflowDefinition>, PersistenceError>;

    // Update availability status
    async fn update_availability(&self, id: Uuid, status: AvailabilityStatus)
        -> Result<(), PersistenceError>;

    // Update last_registered_at
    async fn touch_registration(&self, id: Uuid) -> Result<(), PersistenceError>;

    // Get with worker count
    async fn get_with_workers(&self, id: Uuid)
        -> Result<Option<WorkflowDefinitionWithWorkers>, PersistenceError>;
}
```

#### TaskDefinitionRepository

```rust
pub trait TaskDefinitionRepository: Send + Sync {
    // Same pattern as WorkflowDefinitionRepository
    async fn upsert(&self, definition: &TaskDefinition) -> Result<Uuid, PersistenceError>;
    async fn get(&self, id: Uuid) -> Result<Option<TaskDefinition>, PersistenceError>;
    async fn find_by_kind(&self, tenant_id: Uuid, space_id: Option<Uuid>, kind: &str)
        -> Result<Option<TaskDefinition>, PersistenceError>;
    async fn list(&self, tenant_id: Uuid, params: ListDefinitionsParams)
        -> Result<Vec<TaskDefinition>, PersistenceError>;
    async fn update_availability(&self, id: Uuid, status: AvailabilityStatus)
        -> Result<(), PersistenceError>;
    async fn touch_registration(&self, id: Uuid) -> Result<(), PersistenceError>;
    async fn get_with_workers(&self, id: Uuid)
        -> Result<Option<TaskDefinitionWithWorkers>, PersistenceError>;
}
```

#### WorkerRepository (extended)

```rust
pub trait WorkerRepository: Send + Sync {
    // Existing methods...
    async fn upsert(&self, worker: &Worker) -> Result<Uuid, PersistenceError>;
    async fn get(&self, id: Uuid) -> Result<Option<Worker>, PersistenceError>;
    async fn heartbeat(&self, id: Uuid) -> Result<(), PersistenceError>;

    // New discovery methods
    async fn list(&self, tenant_id: Uuid, params: ListWorkersParams)
        -> Result<Vec<Worker>, PersistenceError>;

    async fn get_with_capabilities(&self, id: Uuid)
        -> Result<Option<WorkerWithCapabilities>, PersistenceError>;

    // Find workers for a definition
    async fn find_for_workflow_definition(&self, workflow_definition_id: Uuid)
        -> Result<Vec<Worker>, PersistenceError>;

    async fn find_for_task_definition(&self, task_definition_id: Uuid)
        -> Result<Vec<Worker>, PersistenceError>;

    // Link worker to definition
    async fn add_workflow_capability(&self, worker_id: Uuid, definition_id: Uuid, version: Option<String>)
        -> Result<(), PersistenceError>;

    async fn add_task_capability(&self, worker_id: Uuid, definition_id: Uuid)
        -> Result<(), PersistenceError>;

    // Stale worker detection
    async fn find_stale_workers(&self, timeout: Duration)
        -> Result<Vec<Worker>, PersistenceError>;

    async fn mark_offline(&self, id: Uuid) -> Result<(), PersistenceError>;
}
```

#### Domain Types

```rust
// Definition tables (simplified for MVP)
pub struct WorkflowDefinition {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub space_id: Option<Uuid>,
    pub kind: String,
    pub name: String,
    pub description: Option<String>,
    pub timeout_seconds: Option<i32>,
    pub retry_policy: Option<serde_json::Value>,
    pub tags: Vec<String>,
    pub cancellable: bool,
    pub latest_version: Option<String>,
    pub availability_status: AvailabilityStatus,
    pub first_seen_at: DateTime<Utc>,
    pub last_registered_at: Option<DateTime<Utc>>,
    pub metadata: Option<serde_json::Value>,
}

pub struct TaskDefinition {
    pub id: Uuid,
    pub tenant_id: Uuid,
    pub space_id: Option<Uuid>,
    pub kind: String,
    pub name: String,
    pub description: Option<String>,
    pub timeout_seconds: Option<i32>,
    pub retry_policy: Option<serde_json::Value>,
    pub tags: Vec<String>,
    pub cancellable: bool,
    pub input_schema: Option<serde_json::Value>,
    pub output_schema: Option<serde_json::Value>,
    pub availability_status: AvailabilityStatus,
    pub first_seen_at: DateTime<Utc>,
    pub last_registered_at: Option<DateTime<Utc>>,
    pub metadata: Option<serde_json::Value>,
}

// Enums
pub enum AvailabilityStatus {
    Available,
    Unavailable,
    Degraded,
}

// Aggregate types for queries
pub struct WorkflowDefinitionWithWorkers {
    pub definition: WorkflowDefinition,
    pub workers: Vec<WorkerSummary>,
    pub versions: Vec<String>,
}

pub struct TaskDefinitionWithWorkers {
    pub definition: TaskDefinition,
    pub workers: Vec<WorkerSummary>,
}

pub struct WorkerWithCapabilities {
    pub worker: Worker,
    pub workflow_definitions: Vec<WorkflowDefinition>,
    pub task_definitions: Vec<TaskDefinition>,
}

pub struct WorkerSummary {
    pub id: Uuid,
    pub name: String,
    pub status: WorkerStatus,
    pub version: Option<String>,
}

// Query params
pub struct ListDefinitionsParams {
    pub space_id: Option<Uuid>,
    pub availability_status: Option<AvailabilityStatus>,
    pub include_archived: bool,
    pub limit: i64,
    pub offset: i64,
}

pub struct ListWorkersParams {
    pub space_id: Option<Uuid>,
    pub worker_type: Option<String>,  // WORKFLOW, TASK, UNIFIED
    pub status: Option<WorkerStatus>,
    pub limit: i64,
    pub offset: i64,
}
```

### REST API

Uses hyphenated paths to match execution endpoints style (`/workflow-executions`, `/task-executions`).

#### Worker Discovery

```
GET /api/tenants/{tenant_slug}/workers
    Query params: limit, offset, type
    Response: [Worker, ...]

GET /api/tenants/{tenant_slug}/workers/{worker_id}
    Response: { worker, workflowCapabilities, taskCapabilities }
```

#### Workflow Definition Discovery

```
GET /api/tenants/{tenant_slug}/workflow-definitions
    Response: [WorkflowDefinition, ...]

GET /api/tenants/{tenant_slug}/workflow-definitions/{kind}
    Response: WorkflowDefinition

PATCH /api/tenants/{tenant_slug}/workflow-definitions/{kind}/configuration
    Body: { timeout_seconds?, retry_policy?, tags? }
    Response: WorkflowDefinition
```

#### Task Definition Discovery

```
GET /api/tenants/{tenant_slug}/task-definitions
    Response: [TaskDefinition, ...]

GET /api/tenants/{tenant_slug}/task-definitions/{kind}
    Response: TaskDefinition

PATCH /api/tenants/{tenant_slug}/task-definitions/{kind}/configuration
    Body: { timeout_seconds?, retry_policy?, tags? }
    Response: TaskDefinition
```

#### Standalone Task Executions (from standalone-tasks.md)

```
POST /api/tenants/{tenant_slug}/task-executions
    Body: { task_type, input, queue?, max_retries?, scheduled_at? }
    Response: TaskExecution (201 Created)

GET /api/tenants/{tenant_slug}/task-executions
    Query params: status, queue, task_type, limit, offset
    Response: { tasks: [...], total: N }

GET /api/tenants/{tenant_slug}/task-executions/{task_id}
    Response: TaskExecution

DELETE /api/tenants/{tenant_slug}/task-executions/{task_id}
    Response: 204 No Content (cancellation)

GET /api/tenants/{tenant_slug}/task-executions/{task_id}/attempts
    Response: { attempts: [...] }
```

### CLI Commands

#### Worker Commands

```bash
# List all workers
flovyn workers list [--type WORKFLOW|TASK|UNIFIED] [--limit N] [--offset N]

# Show worker details with capabilities
flovyn workers get <worker-id>
```

Example output for `flovyn workers list`:

```
WORKER ID                             NAME              TYPE     STATUS   LAST HEARTBEAT
550e8400-e29b-41d4-a716-446655440001  order-worker      UNIFIED  ONLINE   2s ago
550e8400-e29b-41d4-a716-446655440002  notification-svc  TASK     ONLINE   15s ago
550e8400-e29b-41d4-a716-446655440003  batch-processor   WORKFLOW OFFLINE  5m ago
```

#### Workflow Commands (existing + discovery)

```bash
# Execution commands (existing)
flovyn workflows trigger <kind> [--input JSON]
flovyn workflows list [--status STATUS] [--kind KIND] [--limit N]
flovyn workflows get <id>
flovyn workflows events <id>
flovyn workflows cancel <id>
flovyn workflows tasks <id>
flovyn workflows logs <id> [--follow]

# Definition discovery commands (new)
flovyn workflows definitions                  # List workflow definitions
flovyn workflows definitions <kind>           # Get workflow definition details
```

Example output for `flovyn workflows definitions`:

```
KIND                  NAME                  STATUS     WORKERS  VERSIONS
order-processing      Order Processing      AVAILABLE  2        1.0.0, 1.1.0
user-onboarding       User Onboarding       AVAILABLE  1        2.0.0
payment-reconcile     Payment Reconcile     AVAILABLE  1        1.0.0
```

#### Task Commands (new - mirrors workflows)

Task commands are symmetrical with workflow commands, supporting both standalone task executions and task definition discovery.

```bash
# Execution commands (requires standalone-tasks.md implementation)
flovyn tasks trigger <kind> [--input JSON] [--queue QUEUE] [--scheduled-at TIME]
flovyn tasks list [--status STATUS] [--kind KIND] [--queue QUEUE] [--limit N]
flovyn tasks get <id>
flovyn tasks cancel <id>
flovyn tasks attempts <id>

# Definition discovery commands (new)
flovyn tasks definitions                      # List task definitions
flovyn tasks definitions <kind>               # Get task definition details
```

Example output for `flovyn tasks definitions`:

```
KIND                  NAME                  STATUS     WORKERS
send-email            Send Email            AVAILABLE  2
process-image         Process Image         AVAILABLE  1
generate-report       Generate Report       AVAILABLE  3
```

Example output for `flovyn tasks list`:

```
TASK ID                               KIND           STATUS     QUEUE     CREATED
550e8400-e29b-41d4-a716-446655440010  send-email     COMPLETED  default   2m ago
550e8400-e29b-41d4-a716-446655440011  process-image  RUNNING    media     30s ago
550e8400-e29b-41d4-a716-446655440012  send-email     PENDING    priority  5s ago
```

### Command Symmetry

The CLI follows a consistent pattern for both workflows and tasks:

| Operation | Workflows | Tasks |
|-----------|-----------|-------|
| Trigger | `workflows trigger <kind>` | `tasks trigger <kind>` |
| List executions | `workflows list` | `tasks list` |
| Get execution | `workflows get <id>` | `tasks get <id>` |
| Cancel | `workflows cancel <id>` | `tasks cancel <id>` |
| History | `workflows events <id>` | `tasks attempts <id>` |
| List definitions | `workflows definitions` | `tasks definitions` |
| Get definition | `workflows definitions <kind>` | `tasks definitions <kind>` |

### REST Client Updates

Add methods to the REST client crate:

```rust
impl FlovynRestClient {
    // Worker discovery
    pub async fn list_workers(&self, params: ListWorkersParams)
        -> Result<Vec<Worker>, ClientError>;

    pub async fn get_worker(&self, worker_id: Uuid)
        -> Result<WorkerWithCapabilities, ClientError>;

    // Workflow definition discovery
    pub async fn list_workflow_definitions(&self)
        -> Result<Vec<WorkflowDefinition>, ClientError>;

    pub async fn get_workflow_definition(&self, kind: &str)
        -> Result<WorkflowDefinition, ClientError>;

    // Task definition discovery
    pub async fn list_task_definitions(&self)
        -> Result<Vec<TaskDefinition>, ClientError>;

    pub async fn get_task_definition(&self, kind: &str)
        -> Result<TaskDefinition, ClientError>;

    // Standalone task executions (from standalone-tasks.md)
    pub async fn create_task_execution(&self, params: CreateTaskParams)
        -> Result<TaskExecution, ClientError>;

    pub async fn list_task_executions(&self, params: ListTasksParams)
        -> Result<ListTasksResponse, ClientError>;

    pub async fn get_task_execution(&self, task_id: Uuid)
        -> Result<TaskExecution, ClientError>;

    pub async fn cancel_task_execution(&self, task_id: Uuid)
        -> Result<(), ClientError>;

    pub async fn get_task_attempts(&self, task_id: Uuid)
        -> Result<Vec<TaskAttempt>, ClientError>;
}
```

### Worker Status

Derive worker status from `last_heartbeat_at`:

```rust
pub enum WorkerStatus {
    Online,   // Heartbeat within last 60 seconds
    Offline,  // No heartbeat for > 60 seconds
}

impl Worker {
    pub fn status(&self) -> WorkerStatus {
        let threshold = Utc::now() - Duration::seconds(60);
        if self.last_heartbeat_at >= threshold {
            WorkerStatus::Online
        } else {
            WorkerStatus::Offline
        }
    }
}
```

## Implementation Order

### Phase 1: Schema & Domain Layer

1. **New migration**: Add migration to create normalized schema (drop/recreate worker tables)
2. **Domain types**: Add `WorkflowDefinition`, `TaskDefinition`, enums
3. **Definition repositories**: Implement `WorkflowDefinitionRepository`, `TaskDefinitionRepository`
4. **Extend worker repository**: Add discovery methods, update capability methods

### Phase 2: Registration Flow Update

5. **Update WorkerLifecycleService**: On registration:
   - Upsert `workflow_definition` for each workflow capability
   - Upsert `task_definition` for each task capability
   - Link worker to definitions via capability tables
   - Update `last_registered_at` on definitions
6. **Update heartbeat**: Update worker status based on heartbeat

### Phase 3: Discovery API & CLI

7. **REST discovery endpoints**: Add `/workers`, `/workflow-definitions`, `/task-definitions` endpoints
8. **REST client methods**: Add discovery client methods
9. **CLI discovery commands**: `workers list/get`, `workflows definitions`, `tasks definitions`
10. **Discovery tests**: Integration tests for discovery flows

### Phase 4: Task CLI (depends on standalone-tasks.md)

11. **REST client task methods**: Add `create_task`, `list_tasks`, `get_task`, `cancel_task`, `get_task_attempts`
12. **CLI task commands**: Add `tasks trigger/list/get/cancel/attempts`
13. **Task CLI tests**: Integration tests for task CLI commands

### Phase 5: Availability Monitoring (optional)

14. **Background job**: Periodically check worker heartbeats
15. **Update definition availability**: Mark definitions as UNAVAILABLE when no workers online

### Dependencies

```
Phase 1 (Schema) → Phase 2 (Registration) → Phase 3 (Discovery API)
                                                    ↓
                                          CLI discovery works

standalone-tasks.md (REST API) → Phase 4 (Task CLI)
```

## Open Questions

1. **Stale worker cleanup**: Should we automatically remove workers that haven't sent heartbeats for extended periods (e.g., 24 hours)?

2. **Capability aggregation**: When multiple workers register the same workflow kind with different metadata (e.g., different descriptions), which one wins? Options:
   - First registered wins
   - Most recent wins
   - Return all versions in discovery response

3. **gRPC discovery service**: Should we add gRPC discovery endpoints for SDK clients, or is REST sufficient for discovery use cases?
