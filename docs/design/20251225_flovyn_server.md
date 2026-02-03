# Minimal Flovyn Server

## Background

We previously developed a Flovyn server in Kotlin ([source](/Users/manhha/Developer/manhha/leanapp/flovyn)). However, the project accumulated too many features and the complexity became difficult to manage.

We've since developed a [Rust SDK](/Users/manhha/Developer/manhha/flovyn/sdk-rust) with a comprehensive E2E test suite. These tests target a container image of the server, making them implementation-agnostic.

## Goals

Build a new Flovyn server in Rust with the following principles:

- **Minimal scope**: Implement only what's necessary to pass the Rust SDK's E2E tests
- **Test-driven**: All features are driven by tests first
- **Proven patterns**: Draw inspiration from the Kotlin server's proven implementation

---

## E2E Test Harness Requirements

The E2E tests use Testcontainers to orchestrate the server. The harness expects:

### Infrastructure
- **PostgreSQL**: Port 5435 (existing dev instance)
- **NATS**: Port 4222 (existing dev instance)
- **Server HTTP**: Port 8080 (mapped dynamically)
- **Server gRPC**: Port 9090 (mapped dynamically)

### Environment Variables
```bash
# Database
DATABASE_URL=postgres://flovyn:flovyn@host.docker.internal:5435/flovyn

# NATS
NATS_ENABLED=true
NATS_URL=nats://host.docker.internal:4222

# Server ports
SERVER_PORT=8080
GRPC_SERVER_PORT=9090

# Security (test mode)
FLOVYN_SECURITY_ENABLED=true
FLOVYN_SECURITY_JWT_SKIP_SIGNATURE_VERIFICATION=true

# Migrations
RUN_MIGRATIONS=true
```

### Startup Sequence
1. Server starts and runs database migrations
2. Health check polls `GET /_/health` (max 30s timeout)
3. Test creates tenant via `POST /api/tenants`
4. Test creates worker token via `POST /api/tenants/{slug}/worker-tokens`
5. Tests connect via gRPC using the worker token

### JWT Authentication (Test Mode)
- Tests generate self-signed RS256 JWTs
- Server must accept JWTs with valid structure when `SKIP_SIGNATURE_VERIFICATION=true`
- Required JWT claims: `sub`, `id`, `name`, `email`, `iss`, `aud`, `exp`, `iat`

---

## REST API (Axum + OpenAPI)

The REST API uses Axum with `utoipa` for OpenAPI specification generation.

### Endpoints

#### Health Check
```
GET /_/health
Response: { "status": "UP" }
```

#### Tenant Management
```
POST /api/tenants
Authorization: Bearer {jwt}
Request:
{
  "name": "Test Tenant",
  "slug": "test-abc123",
  "tier": "FREE",
  "region": "us-west-2"
}
Response:
{
  "id": "uuid",
  "slug": "test-abc123"
}
```

#### Worker Token Management
```
POST /api/tenants/{slug}/worker-tokens
Authorization: Bearer {jwt}
Request:
{
  "displayName": "e2e-test-worker"
}
Response:
{
  "token": "fwt_..."
}
```

#### Promise Resolution (External)
```
POST /api/promises/{promise_id}/resolve
Authorization: Bearer {jwt}
Request: { "value": <json> }

POST /api/promises/{promise_id}/reject
Authorization: Bearer {jwt}
Request: { "error": "message" }
```

#### OpenAPI Specification
```
GET /api/docs/openapi.json   # OpenAPI 3.0 spec
GET /api/docs                # Swagger UI (optional)
```

### OpenAPI Integration
```rust
// Use utoipa for OpenAPI generation
use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;

#[derive(OpenApi)]
#[openapi(
    paths(
        health_check,
        create_tenant,
        create_worker_token,
        resolve_promise,
        reject_promise,
    ),
    components(schemas(
        TenantRequest, TenantResponse,
        WorkerTokenRequest, WorkerTokenResponse,
        HealthResponse,
    ))
)]
struct ApiDoc;
```

---

## gRPC API (Tonic + Prost)

Proto file: `/Users/manhha/Developer/manhha/flovyn/sdk-rust/proto/flovyn.proto`

### Services Required

#### WorkflowDispatch (Primary)
| Method | Purpose | E2E Test Coverage |
|--------|---------|-------------------|
| `PollWorkflow` | Long-poll for workflow work | All workflow tests |
| `StartWorkflow` | Start a workflow execution | All workflow tests |
| `StartChildWorkflow` | Start child workflow | `child_workflow_tests.rs` |
| `ResolvePromise` | Resolve durable promise | `promise_tests.rs` |
| `RejectPromise` | Reject durable promise | `promise_tests.rs` |
| `GetEvents` | Get workflow event history | All tests (completion check) |
| `SubmitWorkflowCommands` | Submit execution results | Implicit in all tests |
| `SubscribeToNotifications` | Server-stream notifications | Worker registration |

#### TaskExecution
| Method | Purpose | E2E Test Coverage |
|--------|---------|-------------------|
| `PollTask` | Long-poll for task work | `task_tests.rs` |
| `CompleteTask` | Mark task completed | `task_tests.rs` |
| `FailTask` | Mark task failed | `error_tests.rs` |
| `SetState` | Set workflow state | `state_tests.rs` |
| `GetState` | Get workflow state | `state_tests.rs` |
| `Heartbeat` | Worker heartbeat | Worker lifecycle |

#### WorkerLifecycle
| Method | Purpose | E2E Test Coverage |
|--------|---------|-------------------|
| `RegisterWorker` | Register worker capabilities | All tests (implicit) |
| `SendHeartbeat` | Periodic heartbeat | Worker lifecycle |

### gRPC Authentication
- Worker token passed via `authorization` metadata header
- Format: `Bearer fwt_...`
- Server validates token against `worker_token` table

---

## Workflow Event Types

The server must record and replay these event types:

| Event Type | Description | Triggered By |
|------------|-------------|--------------|
| `WORKFLOW_STARTED` | Workflow execution created | `StartWorkflow` |
| `WORKFLOW_COMPLETED` | Workflow finished successfully | `CompleteWorkflowCommand` |
| `WORKFLOW_EXECUTION_FAILED` | Workflow failed with error | `FailWorkflowCommand` |
| `OPERATION_COMPLETED` | Inline operation cached | `RecordOperationCommand` |
| `TASK_SCHEDULED` | Task queued for execution | `ScheduleTaskCommand` |
| `TASK_COMPLETED` | Task finished successfully | `CompleteTask` |
| `TASK_FAILED` | Task failed | `FailTask` |
| `CHILD_WORKFLOW_SCHEDULED` | Child workflow started | `ScheduleChildWorkflowCommand` |
| `CHILD_WORKFLOW_COMPLETED` | Child workflow finished | Child workflow completion |
| `PROMISE_CREATED` | Durable promise created | `CreatePromiseCommand` |
| `PROMISE_RESOLVED` | Promise resolved with value | `ResolvePromise` |
| `PROMISE_REJECTED` | Promise rejected with error | `RejectPromise` |
| `TIMER_SCHEDULED` | Durable timer started | `StartTimerCommand` |
| `TIMER_FIRED` | Timer expired | Timer scheduler |
| `STATE_SET` | Workflow state updated | `SetStateCommand` |
| `STATE_CLEARED` | Workflow state removed | `ClearStateCommand` |

---

## Database Schema

### Core Tables

```sql
-- Multi-tenant isolation
CREATE TABLE tenant (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    slug VARCHAR(100) NOT NULL UNIQUE,
    tier VARCHAR(50) NOT NULL DEFAULT 'FREE',
    region VARCHAR(50),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Worker authentication tokens
CREATE TABLE worker_token (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenant(id),
    display_name VARCHAR(255) NOT NULL,
    token_prefix VARCHAR(16) NOT NULL,  -- First 16 chars for lookup
    token_hash BYTEA NOT NULL,           -- HMAC-SHA256 hash
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    UNIQUE(token_prefix)
);

-- Workflow executions (main entity)
CREATE TABLE workflow_execution (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenant(id),
    kind VARCHAR(255) NOT NULL,
    state VARCHAR(50) NOT NULL DEFAULT 'PENDING',
    input BYTEA,
    output BYTEA,
    error TEXT,
    task_queue VARCHAR(100) NOT NULL DEFAULT 'default',
    priority_ms BIGINT NOT NULL DEFAULT 0,
    current_sequence INT NOT NULL DEFAULT 0,
    workflow_version VARCHAR(50),
    parent_workflow_execution_id UUID REFERENCES workflow_execution(id),
    idempotency_key VARCHAR(255),
    idempotency_key_expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    version INT NOT NULL DEFAULT 0,  -- Optimistic locking
    workflow_task_time_millis BIGINT,
    UNIQUE(tenant_id, idempotency_key)
);

-- Workflow states: PENDING, RUNNING, WAITING, COMPLETED, FAILED, CANCELLED

CREATE INDEX idx_workflow_dispatch ON workflow_execution(tenant_id, task_queue, state, created_at)
    WHERE state = 'PENDING';

-- Event sourcing log (append-only)
CREATE TABLE workflow_event (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workflow_execution_id UUID NOT NULL REFERENCES workflow_execution(id),
    sequence_number INT NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    event_data BYTEA,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(workflow_execution_id, sequence_number)
);

CREATE INDEX idx_workflow_events ON workflow_event(workflow_execution_id, sequence_number);

-- Task executions
CREATE TABLE task_execution (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenant(id),
    workflow_execution_id UUID REFERENCES workflow_execution(id),
    task_type VARCHAR(255) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING',
    input BYTEA,
    output BYTEA,
    error TEXT,
    queue VARCHAR(100) NOT NULL DEFAULT 'default',
    execution_count INT NOT NULL DEFAULT 0,
    max_retries INT NOT NULL DEFAULT 3,
    progress DOUBLE PRECISION,
    progress_details TEXT,
    state JSONB,  -- Task-local state
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

-- Task states: PENDING, RUNNING, COMPLETED, FAILED

CREATE INDEX idx_task_dispatch ON task_execution(tenant_id, queue, status, created_at)
    WHERE status = 'PENDING';

-- Durable promises
CREATE TABLE promise (
    id VARCHAR(255) PRIMARY KEY,  -- Format: {workflow_execution_id}:{promise_name}
    workflow_execution_id UUID NOT NULL REFERENCES workflow_execution(id),
    name VARCHAR(255) NOT NULL,
    resolved BOOLEAN NOT NULL DEFAULT FALSE,
    value BYTEA,
    error TEXT,
    timeout_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ,
    created_by_sequence INT NOT NULL,
    resolved_by_sequence INT
);

-- Durable timers
CREATE TABLE timer (
    id VARCHAR(255) PRIMARY KEY,  -- Format: {workflow_execution_id}:{timer_id}
    workflow_execution_id UUID NOT NULL REFERENCES workflow_execution(id),
    duration_ms BIGINT NOT NULL,
    fire_at TIMESTAMPTZ NOT NULL,
    fired BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    fired_at TIMESTAMPTZ,
    created_by_sequence INT NOT NULL
);

CREATE INDEX idx_timer_pending ON timer(fire_at) WHERE fired = FALSE;

-- Worker registry
CREATE TABLE worker (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenant(id),
    worker_name VARCHAR(255) NOT NULL,
    worker_version VARCHAR(50),
    worker_type VARCHAR(50) NOT NULL,  -- WORKFLOW, TASK, UNIFIED
    host_name VARCHAR(255),
    process_id VARCHAR(100),
    last_heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB
);

-- Worker capabilities
CREATE TABLE worker_workflow_capability (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    worker_id UUID NOT NULL REFERENCES worker(id) ON DELETE CASCADE,
    kind VARCHAR(255) NOT NULL,
    version VARCHAR(50),
    content_hash VARCHAR(64)
);

CREATE TABLE worker_task_capability (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    worker_id UUID NOT NULL REFERENCES worker(id) ON DELETE CASCADE,
    kind VARCHAR(255) NOT NULL
);

-- Idempotency keys
CREATE TABLE idempotency_key (
    key VARCHAR(255) PRIMARY KEY,
    tenant_id UUID NOT NULL REFERENCES tenant(id),
    entity_type VARCHAR(50) NOT NULL,  -- WORKFLOW, TASK
    entity_id UUID NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_idempotency_expiry ON idempotency_key(expires_at);

-- Workflow state storage
CREATE TABLE workflow_state (
    workflow_execution_id UUID NOT NULL REFERENCES workflow_execution(id),
    key VARCHAR(255) NOT NULL,
    value BYTEA,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY(workflow_execution_id, key)
);
```

### Schema Flexibility
Design schemas to be flexible (not fixed to the `public` schema) to support multi-tenant deployments where each tenant uses a separate Postgres schema.

```rust
// Schema-aware repository pattern
pub struct SchemaContext {
    schema: String,
}

impl SchemaContext {
    pub fn table(&self, name: &str) -> String {
        format!("{}.{}", self.schema, name)
    }
}
```

---

## Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Flovyn Server                            │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │   Axum      │  │   Tonic     │  │      Background         │  │
│  │  REST API   │  │  gRPC API   │  │       Workers           │  │
│  │  (8080)     │  │  (9090)     │  │  (Timer, Cleanup)       │  │
│  └──────┬──────┘  └──────┬──────┘  └───────────┬─────────────┘  │
│         │                │                      │                │
│  ┌──────┴────────────────┴──────────────────────┴─────────────┐  │
│  │                    Service Layer                           │  │
│  │  ┌──────────────┐ ┌──────────────┐ ┌────────────────────┐  │  │
│  │  │ Workflow     │ │ Task         │ │ Authorization      │  │  │
│  │  │ Service      │ │ Service      │ │ Service (Cedar)    │  │  │
│  │  └──────────────┘ └──────────────┘ └────────────────────┘  │  │
│  └───────────────────────────┬────────────────────────────────┘  │
│                              │                                   │
│  ┌───────────────────────────┴────────────────────────────────┐  │
│  │                   Repository Layer                         │  │
│  │  ┌──────────────┐ ┌──────────────┐ ┌────────────────────┐  │  │
│  │  │ Workflow     │ │ Task         │ │ Event              │  │  │
│  │  │ Repository   │ │ Repository   │ │ Repository         │  │  │
│  │  └──────────────┘ └──────────────┘ └────────────────────┘  │  │
│  └───────────────────────────┬────────────────────────────────┘  │
│                              │                                   │
├──────────────────────────────┼───────────────────────────────────┤
│  ┌───────────────┐   ┌───────┴───────┐   ┌───────────────────┐  │
│  │  PostgreSQL   │   │     SQLx      │   │   async-nats      │  │
│  │  (5435)       │   │  Connection   │   │   (4222)          │  │
│  └───────────────┘   └───────────────┘   └───────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Event Sourcing Flow

```
┌────────────┐     ┌────────────┐     ┌────────────┐     ┌────────────┐
│   Client   │────▶│   Server   │────▶│   Events   │────▶│   State    │
│  (Worker)  │     │  (Command) │     │   (Log)    │     │  (Update)  │
└────────────┘     └────────────┘     └────────────┘     └────────────┘
                         │
                         │ Replay
                         ▼
                   ┌────────────┐
                   │   Events   │────▶ Reconstruct State
                   │  (Fetch)   │
                   └────────────┘
```

### Workflow State Machine

```
                    ┌─────────┐
                    │ PENDING │
                    └────┬────┘
                         │ PollWorkflow
                         ▼
                    ┌─────────┐
              ┌─────│ RUNNING │─────┐
              │     └────┬────┘     │
              │          │          │
    SuspendCmd│    CompleteCmd  FailCmd
              │          │          │
              ▼          ▼          ▼
         ┌─────────┐ ┌─────────┐ ┌────────┐
         │ WAITING │ │COMPLETED│ │ FAILED │
         └────┬────┘ └─────────┘ └────────┘
              │
              │ Event (task/timer/promise)
              ▼
         ┌─────────┐
         │ PENDING │ (re-enqueued)
         └─────────┘
```

---

## Technology Stack

| Component | Library | Purpose |
|-----------|---------|---------|
| Runtime | Tokio | Async runtime |
| gRPC | Tonic + Prost | Protocol buffer services |
| HTTP | Axum | REST endpoints |
| OpenAPI | utoipa + utoipa-swagger-ui | API documentation |
| Database | SQLx | PostgreSQL async driver |
| Messaging | async-nats | NATS JetStream client |
| Authorization | Cedar | Policy-based access control |
| Observability | Tracing | Structured logging |
| Config | config-rs | Configuration management |
| Testing | tokio-test, testcontainers | Async tests, integration tests |

---

## Implementation Phases

### Phase 1: Foundation
- [ ] Project setup (Cargo workspace, dependencies)
- [ ] Configuration management (config-rs)
- [ ] Database connection pool (SQLx)
- [ ] Migration framework
- [ ] Health check endpoint (`GET /_/health`)
- [ ] OpenAPI setup (utoipa)

### Phase 2: Tenant & Authentication
- [ ] Tenant table and repository
- [ ] Worker token generation and validation
- [ ] REST endpoints: `POST /api/tenants`, `POST /api/tenants/{slug}/worker-tokens`
- [ ] JWT validation (with skip-signature mode for tests)

### Phase 3: Core Workflow Execution
- [ ] Workflow execution table and repository
- [ ] Event table and repository (event sourcing)
- [ ] gRPC `WorkflowDispatch` service:
  - [ ] `StartWorkflow`
  - [ ] `PollWorkflow`
  - [ ] `GetEvents`
  - [ ] `SubmitWorkflowCommands`
- [ ] Basic workflow lifecycle (PENDING → RUNNING → COMPLETED/FAILED)

### Phase 4: Task Execution
- [ ] Task execution table and repository
- [ ] gRPC `TaskExecution` service:
  - [ ] `PollTask`
  - [ ] `CompleteTask`
  - [ ] `FailTask`
- [ ] Task scheduling from workflows (`ScheduleTaskCommand`)
- [ ] Task completion events back to workflows

### Phase 5: Advanced Features
- [ ] Durable timers (`StartTimerCommand`, timer scheduler)
- [ ] Durable promises (`CreatePromiseCommand`, `ResolvePromise`, `RejectPromise`)
- [ ] Child workflows (`ScheduleChildWorkflowCommand`)
- [ ] Workflow state (`SetState`, `GetState`)

### Phase 6: Worker Management
- [ ] Worker registry table
- [ ] gRPC `WorkerLifecycle` service:
  - [ ] `RegisterWorker`
  - [ ] `SendHeartbeat`
- [ ] NATS notifications (`SubscribeToNotifications`)

### Phase 7: Authorization
- [ ] Cedar policy engine integration
- [ ] Policy-based access control for gRPC methods
- [ ] Worker token scope validation

### Phase 8: Production Readiness
- [ ] Structured logging (tracing)
- [ ] Metrics (prometheus)
- [ ] Graceful shutdown
- [ ] Connection pooling tuning
- [ ] Docker image build

---

## E2E Test Coverage Matrix

### SDK E2E Tests (Primary)

| Test File | Required Features |
|-----------|-------------------|
| `workflow_tests.rs` | StartWorkflow, PollWorkflow, GetEvents, SubmitWorkflowCommands |
| `task_tests.rs` | ScheduleTaskCommand, PollTask, CompleteTask |
| `timer_tests.rs` | StartTimerCommand, timer scheduler |
| `promise_tests.rs` | CreatePromiseCommand, ResolvePromise, RejectPromise |
| `error_tests.rs` | FailWorkflowCommand, error preservation |
| `child_workflow_tests.rs` | ScheduleChildWorkflowCommand, child completion events |
| `concurrency_tests.rs` | Concurrent polling, multiple workers |
| `state_tests.rs` | SetStateCommand, GetState |

### Server E2E Tests (Using SDK)

The server can have its own E2E tests in `tests/e2e/` that use the Rust SDK as a client library. This enables:

- **Server-specific edge case testing**: Test scenarios unique to this implementation
- **Integration testing**: Test NATS notifications, Cedar authorization, database behavior
- **Performance testing**: Benchmark workflow throughput and latency
- **Regression testing**: Catch issues specific to the Rust implementation

```rust
// tests/e2e/mod.rs - Example server test using SDK
use flovyn_sdk::{FlovynClient, WorkflowContext};

#[tokio::test]
async fn test_nats_notification_delivery() {
    let client = FlovynClient::connect("http://localhost:9090").await?;
    // Test NATS-specific behavior
}

#[tokio::test]
async fn test_cedar_authorization_policy() {
    // Test Cedar policy enforcement
}
```

Add SDK as dev dependency:
```toml
[dev-dependencies]
flovyn-sdk = { path = "../sdk-rust/sdk" }
```

---

## File Structure

```
flovyn-server/
├── Cargo.toml
├── Cargo.lock
├── .env.example
├── Dockerfile
├── migrations/
│   ├── 001_init.sql
│   ├── 002_workers.sql
│   └── ...
├── src/
│   ├── main.rs
│   ├── config.rs
│   ├── api/
│   │   ├── mod.rs
│   │   ├── rest/
│   │   │   ├── mod.rs
│   │   │   ├── health.rs
│   │   │   ├── tenants.rs
│   │   │   ├── promises.rs
│   │   │   └── openapi.rs
│   │   └── grpc/
│   │       ├── mod.rs
│   │       ├── workflow_dispatch.rs
│   │       ├── task_execution.rs
│   │       └── worker_lifecycle.rs
│   ├── domain/
│   │   ├── mod.rs
│   │   ├── workflow.rs
│   │   ├── task.rs
│   │   ├── event.rs
│   │   ├── promise.rs
│   │   ├── timer.rs
│   │   └── worker.rs
│   ├── service/
│   │   ├── mod.rs
│   │   ├── workflow_service.rs
│   │   ├── task_service.rs
│   │   ├── event_service.rs
│   │   └── auth_service.rs
│   ├── repository/
│   │   ├── mod.rs
│   │   ├── workflow_repository.rs
│   │   ├── task_repository.rs
│   │   ├── event_repository.rs
│   │   └── tenant_repository.rs
│   ├── scheduler/
│   │   ├── mod.rs
│   │   └── timer_scheduler.rs
│   └── auth/
│       ├── mod.rs
│       ├── jwt.rs
│       ├── worker_token.rs
│       └── cedar.rs
├── proto/
│   └── flovyn.proto (symlink to sdk-rust)
└── tests/
    └── integration/
        └── ...
```

---

## Development Approach

### Guiding Principles

1. **E2E Tests Are the Spec**: The Rust SDK's E2E tests define what the server must do. Never implement features not covered by tests.
2. **Test First, Always**: Before writing any server code, ensure the corresponding E2E test exists and fails.
3. **Minimal Implementation**: Implement the simplest solution that passes the test. No premature optimization.
4. **Extract, Don't Invent**: Database schemas and patterns come from the Kotlin server—do not design from scratch.
5. **Refer to Kotlin Server Often**: The Kotlin server is the reference implementation. When implementing any feature, always check how Kotlin handles it first.

---

### Step-by-Step Development Workflow

#### Step 1: Set Up Development Environment

```bash
# Start dev infrastructure (PostgreSQL + NATS)
cd /Users/manhha/Developer/manhha/leanapp/flovyn/dev
docker-compose up -d postgres nats

# Verify services
psql -h localhost -p 5435 -U flovyn -d flovyn -c "SELECT 1"
nats-cli server check --server=localhost:4222
```

#### Step 2: Run E2E Tests Against Current Server (Baseline)

```bash
# Build and run the Kotlin server to see tests pass
cd /Users/manhha/Developer/manhha/leanapp/flovyn
./gradlew :server:app:bootRun

# In another terminal, run E2E tests
cd /Users/manhha/Developer/manhha/flovyn/sdk-rust
cargo test --test e2e -- --nocapture
```

Document which tests pass. This is your baseline.

#### Step 3: Extract Database Schema

**DO NOT design tables from scratch.** Extract only what you need from the Kotlin server:

```bash
# Connect to dev database
psql -h localhost -p 5435 -U flovyn -d flovyn

# List all tables
\dt

# Get schema for specific tables
\d+ workflow_execution
\d+ workflow_event
\d+ task_execution
\d+ tenant
\d+ worker_token
```

**Extraction Rules:**
1. Start with tables needed for Phase 1-3 only (tenant, worker_token, workflow_execution, workflow_event)
2. Copy column definitions exactly—do not rename or restructure
3. Copy indexes exactly—they are optimized for the query patterns
4. Add tables incrementally as tests require them

**Example: Extracting workflow_execution**
```bash
# In psql, export DDL
\d+ workflow_execution > /tmp/workflow_execution.sql

# Clean up and adapt for SQLx migrations
# Keep: column names, types, constraints, indexes
# Remove: Kotlin-specific defaults, unused columns
```

#### Step 4: Test-First Development Cycle

For each feature, follow this exact sequence:

```
┌─────────────────────────────────────────────────────────────┐
│  1. IDENTIFY TEST                                           │
│     Find the E2E test that covers the feature               │
│     Example: sdk-rust/sdk/tests/e2e/workflow_tests.rs       │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  2. RUN TEST (expect FAIL)                                  │
│     cargo test --test workflow_tests -- test_name           │
│     Verify it fails for the right reason (missing impl)     │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  3. EXTRACT SCHEMA                                          │
│     Get required tables from Kotlin server                  │
│     Create migration file in migrations/                    │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  4. IMPLEMENT MINIMAL CODE                                  │
│     Write just enough to pass the test                      │
│     Reference Kotlin impl for patterns, not verbatim copy   │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  5. RUN TEST (expect PASS)                                  │
│     cargo test --test workflow_tests -- test_name           │
│     If fails, debug and iterate                             │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  6. RUN ALL TESTS                                           │
│     cargo test --test e2e                                   │
│     Ensure no regressions                                   │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  7. COMMIT                                                  │
│     git commit with test name in message                    │
│     Example: "feat: pass test_simple_workflow_execution"    │
└─────────────────────────────────────────────────────────────┘
```

#### Step 5: Feature Implementation Order

Follow this strict order to build incrementally:

```
Phase 1: Bootstrap (no E2E tests yet, use curl)
├── Health check: GET /_/health
├── Database pool + migrations
└── Basic Axum + Tonic servers running

Phase 2: Tenant Setup (harness.rs requirements)
├── TEST: harness startup → tenant creation
├── POST /api/tenants
├── POST /api/tenants/{slug}/worker-tokens
└── JWT validation (skip-signature mode)

Phase 3: Basic Workflow (workflow_tests.rs)
├── TEST: test_simple_workflow_execution
├── gRPC: StartWorkflow, PollWorkflow, GetEvents, SubmitWorkflowCommands
├── DB: workflow_execution, workflow_event tables
└── State machine: PENDING → RUNNING → COMPLETED

Phase 4: Failing Workflow (error_tests.rs)
├── TEST: test_workflow_failure
├── FailWorkflowCommand handling
└── Error message preservation

Phase 5: Tasks (task_tests.rs)
├── TEST: test_basic_task_scheduling
├── gRPC: PollTask, CompleteTask
├── DB: task_execution table
├── ScheduleTaskCommand → TASK_SCHEDULED event
└── CompleteTask → TASK_COMPLETED event → workflow resumes

Phase 6: Timers (timer_tests.rs)
├── TEST: test_durable_timer_sleep
├── DB: timer table
├── StartTimerCommand → TIMER_SCHEDULED event
├── Timer scheduler background task
└── Timer fires → TIMER_FIRED event → workflow resumes

Phase 7: Promises (promise_tests.rs)
├── TEST: test_promise_resolve
├── DB: promise table
├── CreatePromiseCommand → PROMISE_CREATED event
├── ResolvePromise/RejectPromise gRPC
└── Promise resolution → workflow resumes

Phase 8: Child Workflows (child_workflow_tests.rs)
├── TEST: test_child_workflow_success
├── ScheduleChildWorkflowCommand handling
├── Child workflow execution tracking
└── Child completion → parent resumes

Phase 9: State (state_tests.rs)
├── TEST: test_state_set_get
├── DB: workflow_state table
├── SetState/GetState gRPC
└── STATE_SET event

Phase 10: Concurrency (concurrency_tests.rs)
├── TEST: test_concurrent_workflow_execution
├── SELECT FOR UPDATE SKIP LOCKED
└── Multiple worker support
```

---

### Database Extraction Checklist

For each table, verify:

- [ ] Column names match Kotlin server exactly
- [ ] Data types are equivalent (VARCHAR → TEXT is OK, but UUID must stay UUID)
- [ ] NOT NULL constraints preserved
- [ ] DEFAULT values preserved where meaningful
- [ ] Indexes match (especially partial indexes for polling)
- [ ] Foreign keys preserved

**Table Mapping (Kotlin → Rust/SQLx)**

| Kotlin Type | Postgres Type | SQLx Type |
|-------------|---------------|-----------|
| UUID | UUID | `Uuid` |
| String | VARCHAR/TEXT | `String` |
| Long | BIGINT | `i64` |
| Int | INT | `i32` |
| Boolean | BOOLEAN | `bool` |
| Instant | TIMESTAMPTZ | `DateTime<Utc>` |
| ByteArray | BYTEA | `Vec<u8>` |
| Map<String, Any> | JSONB | `serde_json::Value` |

---

### Testing Commands Reference

```bash
# Run specific test
cargo test --test e2e workflow_tests::test_simple_workflow_execution -- --nocapture

# Run test file
cargo test --test e2e workflow_tests -- --nocapture

# Run all E2E tests
cargo test --test e2e -- --nocapture

# Run with debug logging
RUST_LOG=debug cargo test --test e2e -- --nocapture
```

---

### Code Organization Rules

1. **One gRPC method = One service function = One repository method**
   ```
   grpc/workflow_dispatch.rs::poll_workflow()
       → service/workflow_service.rs::poll_workflow()
           → repository/workflow_repository.rs::claim_next_workflow()
   ```

2. **Events are append-only**: Never update workflow_event table, only INSERT

3. **State changes go through events**:
   ```
   Command → Event (persisted) → State change (derived)
   ```

4. **Repository methods are single-responsibility**:
   - `find_by_id()` - fetch single entity
   - `find_pending()` - fetch next work item
   - `insert()` - create new entity
   - `update_state()` - change state only

5. **Transactions wrap command processing**:
   ```rust
   async fn submit_commands(commands: Vec<Command>) -> Result<()> {
       let mut tx = pool.begin().await?;
       for cmd in commands {
           let event = process_command(&mut tx, cmd).await?;
           insert_event(&mut tx, event).await?;
       }
       tx.commit().await?;
       Ok(())
   }
   ```

---

### Debugging Failed Tests

When a test fails:

1. **Check server logs**:
   ```bash
   docker logs <container_id>
   ```

2. **Check database state**:
   ```bash
   psql -h localhost -p 5435 -U flovyn -d flovyn
   SELECT * FROM workflow_execution ORDER BY created_at DESC LIMIT 5;
   SELECT * FROM workflow_event WHERE workflow_execution_id = '<id>' ORDER BY sequence_number;
   ```

3. **Compare with Kotlin server**:
   - Run same test against Kotlin server
   - Compare database state after test
   - Compare gRPC responses

4. **Add tracing**:
   ```rust
   #[tracing::instrument]
   async fn poll_workflow(...) {
       tracing::debug!(?request, "received poll request");
       // ...
   }
   ```

---

### Definition of Done

A feature is complete when:

- [ ] E2E test passes
- [ ] All other E2E tests still pass (no regressions)
- [ ] Code follows established patterns
- [ ] Database schema extracted (not invented)
- [ ] No TODO comments in committed code
- [ ] Tracing instrumentation added

---

### Kotlin Server Reference Guide

**ALWAYS check the Kotlin implementation before writing Rust code.** The Kotlin server is battle-tested and contains important edge case handling.

#### Key Kotlin Files by Feature

| Feature | Kotlin Files to Reference |
|---------|---------------------------|
| **gRPC Services** | `server/app/src/main/kotlin/ai/flovyn/server/grpc/` |
| WorkflowDispatch | `WorkflowDispatchService.kt` |
| TaskExecution | `TaskExecutionService.kt` |
| WorkerLifecycle | `WorkerLifecycleService.kt` |
| **Repositories** | `server/app/src/main/kotlin/ai/flovyn/server/repository/` |
| Workflow Repository | `WorkflowExecutionRepository.kt`, `WorkflowEventRepository.kt` |
| Task Repository | `TaskExecutionRepository.kt` |
| Tenant Repository | `TenantRepository.kt` |
| **Domain Models** | `server/app/src/main/kotlin/ai/flovyn/server/domain/` |
| Workflow State Machine | `WorkflowExecutionState.kt` |
| Event Types | `WorkflowEventType.kt` |
| Command Processing | `WorkflowCommandProcessor.kt` |
| **Database** | `server/app/src/main/resources/db/migration/` |
| All Migrations | `V1__init.sql` through `V41__*.sql` |
| **Queue/Dispatch** | `server/app/src/main/kotlin/ai/flovyn/server/queue/` |
| Workflow Polling | `DbWorkflowQueue.kt` |
| Task Polling | `DbTaskQueue.kt` |
| **Authentication** | `server/app/src/main/kotlin/ai/flovyn/server/auth/` |
| Worker Token | `WorkerTokenValidator.kt`, `WorkerTokenGenerator.kt` |
| JWT Handling | `JwtAuthenticationFilter.kt` |
| **Cedar Authorization** | `server/app/src/main/kotlin/ai/flovyn/server/authz/` |
| Cedar Service | `CedarAuthorizationService.kt` |

#### How to Reference Kotlin Code

1. **Before implementing a gRPC method**:
   ```bash
   # Find the Kotlin implementation
   cd /Users/manhha/Developer/manhha/leanapp/flovyn
   grep -r "fun pollWorkflow" server/app/src/main/kotlin/

   # Read the implementation
   cat server/app/src/main/kotlin/ai/flovyn/server/grpc/WorkflowDispatchService.kt
   ```

2. **Before implementing a repository method**:
   ```bash
   # Find the SQL query
   grep -r "SELECT.*workflow_execution" server/app/src/main/kotlin/ --include="*.kt"
   ```

3. **Before designing a state transition**:
   ```bash
   # Find the state machine
   cat server/app/src/main/kotlin/ai/flovyn/server/domain/WorkflowExecutionState.kt
   ```

4. **Before handling a command**:
   ```bash
   # Find command processing logic
   cat server/app/src/main/kotlin/ai/flovyn/server/domain/WorkflowCommandProcessor.kt
   ```

#### Key Patterns to Copy from Kotlin

1. **Optimistic Locking**: Check how `version` field is used in UPDATE queries
2. **Event Sourcing**: Copy the exact event data JSON structure
3. **Queue Polling**: Use the same `SELECT FOR UPDATE SKIP LOCKED` pattern
4. **Worker Token Validation**: Copy the HMAC-SHA256 verification logic
5. **Timer Scheduling**: Copy the background scheduler pattern
6. **Promise Resolution**: Copy the listener notification logic

---

## References

- Proto definition: `/Users/manhha/Developer/manhha/flovyn/sdk-rust/proto/flovyn.proto`
- SDK E2E tests: `/Users/manhha/Developer/manhha/flovyn/sdk-rust/sdk/tests/e2e/`
- Test harness: `flovyn-server//Users/manhha/Developer/manhha/flovyn/sdk-rust/sdk/tests/e2e/harness.rs`
- Kotlin server: `/Users/manhha/Developer/manhha/leanapp/flovyn/server/app/`
- Kotlin migrations: `/Users/manhha/Developer/manhha/leanapp/flovyn/server/app/src/main/resources/db/migration/`
- Dev environment: `flovyn-server//Users/manhha/Developer/manhha/leanapp/flovyn/dev/docker-compose.yml`
