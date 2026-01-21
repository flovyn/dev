# REST API: Trigger Workflow

**Status**: Design Proposal
**Purpose**: Enable external systems to trigger workflow executions via REST API with idempotency key support.

---

## Overview

This document describes the design for a REST API endpoint that allows external systems to trigger workflow executions. The endpoint provides an alternative to the gRPC `StartWorkflow` method for systems that prefer HTTP/REST communication.

**Key Features**:
1. Trigger workflows by kind with JSON input
2. Full idempotency key support (see [idempotency-keys.md](/Users/manhha/Developer/manhha/leanapp/flovyn/docs/design/idempotency-keys.md))
3. JWT authentication for external API access
4. OpenAPI documentation via utoipa

---

## API Design

### Endpoint

```
POST /api/tenants/{tenantSlug}/workflows/{kind}/trigger
```

### Authentication

- **Method**: JWT Bearer token
- **Header**: `Authorization: Bearer <jwt>`
- **Required Claims**: `sub`, `iss`, `aud`, `exp`, `iat`

### Path Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `tenantSlug` | string | Tenant identifier (e.g., `my-org-abc123`) |
| `kind` | string | Workflow type identifier (e.g., `order-processing`) |

### Request Body

```json
{
  "input": {
    "orderId": "ORDER-12345",
    "customerId": "CUST-789"
  },
  "taskQueue": "high-priority",
  "prioritySeconds": 0,
  "version": "1.0.0",
  "idempotencyKey": "order-ORDER-12345-process",
  "idempotencyKeyTTL": "1h",
  "labels": {
    "environment": "production",
    "source": "webhook"
  }
}
```

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `input` | object | No | `{}` | JSON input data for the workflow |
| `taskQueue` | string | No | `"default"` | Task queue for worker routing |
| `prioritySeconds` | int | No | `0` | Time-offset priority (negative = higher priority) |
| `version` | string | No | `null` | Workflow version to execute |
| `idempotencyKey` | string | No | `null` | Unique key for deduplication |
| `idempotencyKeyTTL` | string | No | `"24h"` | TTL for idempotency key (e.g., `30s`, `5m`, `2h`, `7d`) |
| `labels` | object | No | `{}` | Key-value labels for filtering/querying |

### Response (201 Created - New Execution)

```json
{
  "workflowExecutionId": "550e8400-e29b-41d4-a716-446655440000",
  "status": "PENDING",
  "kind": "order-processing",
  "createdAt": "2025-01-15T10:30:00Z",
  "links": {
    "self": "/api/tenants/my-org/workflow-executions/550e8400-e29b-41d4-a716-446655440000",
    "events": "/api/tenants/my-org/workflow-executions/550e8400-e29b-41d4-a716-446655440000/events"
  },
  "idempotencyKeyUsed": true,
  "idempotencyKeyNew": true
}
```

### Response (200 OK - Existing Execution via Idempotency Key)

```json
{
  "workflowExecutionId": "550e8400-e29b-41d4-a716-446655440000",
  "status": "RUNNING",
  "kind": "order-processing",
  "createdAt": "2025-01-15T10:25:00Z",
  "links": {
    "self": "/api/tenants/my-org/workflow-executions/550e8400-e29b-41d4-a716-446655440000",
    "events": "/api/tenants/my-org/workflow-executions/550e8400-e29b-41d4-a716-446655440000/events"
  },
  "idempotencyKeyUsed": true,
  "idempotencyKeyNew": false
}
```

| Field | Type | Description |
|-------|------|-------------|
| `workflowExecutionId` | UUID | Unique identifier for the workflow execution |
| `status` | string | Current status: `PENDING`, `RUNNING`, `WAITING`, `COMPLETED`, `FAILED`, `CANCELLED` |
| `kind` | string | Workflow type identifier (echoed from request path) |
| `createdAt` | ISO 8601 | Timestamp when the execution was created |
| `links` | object | HATEOAS links to related resources (`self`, `events`) |
| `idempotencyKeyUsed` | boolean | Whether an idempotency key was provided |
| `idempotencyKeyNew` | boolean | `true` = new execution created, `false` = existing returned |

### Error Responses

#### 400 Bad Request
```json
{
  "error": "Invalid idempotencyKeyTTL format: '2x'. Expected: 30s, 5m, 2h, 7d"
}
```

#### 401 Unauthorized
```json
{
  "error": "Missing or invalid authorization token"
}
```

#### 404 Not Found
```json
{
  "error": "Tenant 'unknown-tenant' not found"
}
```

#### 429 Too Many Requests (Quota Exceeded)
```json
{
  "error": "MONTHLY_QUOTA_EXCEEDED",
  "message": "Monthly workflow run quota exceeded",
  "quotaType": "monthly_workflow_runs",
  "limit": 1000,
  "current": 1000
}
```

```json
{
  "error": "CONCURRENT_QUOTA_EXCEEDED",
  "message": "Concurrent workflow quota exceeded",
  "quotaType": "concurrent_workflows",
  "limit": 10,
  "current": 10
}
```

---

## Idempotency Key Behavior

The REST endpoint follows the idempotency design from [idempotency-keys.md](/Users/manhha/Developer/manhha/leanapp/flovyn/docs/design/idempotency-keys.md).

### Database Schema

The Kotlin server uses a **dedicated `idempotency_key` table** (not columns on `workflow_execution`). This design:
- Supports both workflow AND task idempotency
- Enables efficient cleanup via `expires_at` index
- Allows status-based clearing when executions fail

**Migration Note**: The current Rust server has `idempotency_key` and `idempotency_key_expires_at` columns on `workflow_execution`. These should be **removed** when migrating to the dedicated table approach:
1. Create new `idempotency_key` table
2. Drop columns from `workflow_execution` (no data migration needed)
3. Remove `WorkflowRepository::find_by_idempotency_key()`
4. Remove fields from `WorkflowExecution` domain model

```sql
CREATE TABLE idempotency_key (
    tenant_id UUID NOT NULL,
    key TEXT NOT NULL,
    workflow_execution_id UUID,
    task_execution_id UUID,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (tenant_id, expires_at, key),
    FOREIGN KEY (workflow_execution_id) REFERENCES workflow_execution(id) ON DELETE CASCADE,
    FOREIGN KEY (task_execution_id) REFERENCES task_execution(id) ON DELETE CASCADE,

    CHECK (
        (workflow_execution_id IS NOT NULL AND task_execution_id IS NULL) OR
        (workflow_execution_id IS NULL AND task_execution_id IS NOT NULL)
    )
);

CREATE UNIQUE INDEX idx_idempotency_key_unique ON idempotency_key (tenant_id, key);
CREATE INDEX idx_idempotency_key_expires ON idempotency_key (expires_at);
```

### Status-Based Key Clearing

When a workflow execution reaches a **terminal failure state**, the idempotency key is cleared to allow retries:

| Execution Status | Idempotency Key Behavior |
|-----------------|-------------------------|
| PENDING | Key active - return existing |
| RUNNING | Key active - return existing |
| WAITING | Key active - return existing |
| COMPLETED | Key active - return existing |
| **FAILED** | **Key cleared - allow new execution** |
| **CANCELLED** | **Key cleared - allow new execution** |

This enables the retry pattern: if a workflow fails, the client can retry with the same idempotency key.

### Two-Phase Idempotency Handling (Claim-Then-Register)

The Kotlin implementation uses a **claim-then-register** pattern:

1. **Phase 1 - Claim or Get**: Before creating the workflow, check if the idempotency key already exists
2. **Phase 2 - Register**: After successful workflow creation, register the idempotency key with TTL

This ensures failed workflow creations don't leave orphan idempotency keys.

```
┌─────────────────────────────────────────────────────────────────┐
│  Request arrives with idempotencyKey                            │
└─────────────────────────────────────┬───────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────┐
│  Phase 1: claimOrGet(tenantId, key)                             │
│  SELECT workflow_execution_id FROM idempotency_key              │
│  WHERE tenant_id = ? AND key = ? AND expires_at > NOW()         │
│  FOR UPDATE SKIP LOCKED                                         │
└─────────────────────────────────────┬───────────────────────────┘
                                      │
                    ┌─────────────────┴─────────────────┐
                    │                                   │
         ClaimResult::Existing                ClaimResult::Available
                    │                                   │
                    ▼                                   ▼
    ┌───────────────────────────┐       ┌───────────────────────────┐
    │  Get workflow execution   │       │  Create workflow_execution │
    │  Return 200 OK with       │       └─────────────┬─────────────┘
    │  idempotencyKeyNew: false │                     │
    └───────────────────────────┘                     ▼
                                        ┌───────────────────────────┐
                                        │  Phase 2: register()      │
                                        │  INSERT idempotency_key   │
                                        │  with TTL expiration      │
                                        └─────────────┬─────────────┘
                                                      │
                                                      ▼
                                        ┌───────────────────────────┐
                                        │  Return 201 Created       │
                                        │  idempotencyKeyNew: true  │
                                        └───────────────────────────┘
```

**Note**: Unlike the original idempotency design that returns 409 for terminal failures, the Kotlin implementation simply returns the existing execution. This is simpler and allows clients to check the `status` field to determine if they should retry with a new key.

### TTL Format Parsing

| Input | Duration |
|-------|----------|
| `30s` | 30 seconds |
| `5m` | 5 minutes |
| `2h` | 2 hours |
| `7d` | 7 days |
| Default | 24 hours |
| Maximum | 30 days |

### Background Cleanup Task

A scheduled task runs every 5 minutes to delete expired idempotency keys:

```rust
// src/scheduler/idempotency_cleanup.rs

pub async fn cleanup_expired_keys(pool: &PgPool) -> Result<i64, sqlx::Error> {
    let result = sqlx::query!(
        "DELETE FROM idempotency_key WHERE expires_at < NOW()"
    )
    .execute(pool)
    .await?;

    Ok(result.rows_affected() as i64)
}
```

Integrated into the existing scheduler loop in `flovyn-server/src/scheduler.rs`.

---

## Implementation

### IdempotencyKeyRepository Interface

```rust
// src/repository/idempotency_key_repository.rs

pub enum ExecutionType {
    Workflow,
    Task,
}

pub enum ClaimResult {
    /// Key exists and is active - return existing execution
    Existing { execution_id: Uuid, execution_type: ExecutionType },
    /// Key available - proceed with new execution
    Available,
}

pub struct IdempotencyKeyRepository {
    pool: PgPool,
}

impl IdempotencyKeyRepository {
    /// Attempts to claim an idempotency key.
    /// Returns Existing if key already claimed (and execution not failed).
    /// Returns Available if key is free or execution failed (allows retry).
    pub async fn claim_or_get(
        &self,
        tenant_id: Uuid,
        key: &str,
    ) -> Result<ClaimResult, sqlx::Error>;

    /// Registers a new idempotency key after execution is created.
    pub async fn register(
        &self,
        tenant_id: Uuid,
        key: &str,
        workflow_execution_id: Option<Uuid>,
        task_execution_id: Option<Uuid>,
        expires_at: DateTime<Utc>,
    ) -> Result<(), sqlx::Error>;

    /// Clears idempotency key for a failed execution (allows retry).
    pub async fn clear_for_execution(
        &self,
        execution_id: Uuid,
        execution_type: ExecutionType,
    ) -> Result<(), sqlx::Error>;

    /// Deletes all expired keys.
    pub async fn delete_expired(&self) -> Result<i64, sqlx::Error>;
}
```

### Request/Response DTOs

```rust
// src/api/rest/workflows.rs

#[derive(Debug, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct TriggerWorkflowRequest {
    #[serde(default)]
    pub input: serde_json::Value,

    #[serde(default = "default_task_queue")]
    pub task_queue: String,

    #[serde(default)]
    pub priority_seconds: i32,

    pub version: Option<String>,

    pub idempotency_key: Option<String>,

    #[serde(default = "default_ttl")]
    pub idempotency_key_ttl: String,

    #[serde(default)]
    pub labels: HashMap<String, String>,
}

fn default_task_queue() -> String {
    "default".to_string()
}

fn default_ttl() -> String {
    "24h".to_string()
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct TriggerWorkflowResponse {
    pub workflow_execution_id: Uuid,
    pub status: String,
    pub kind: String,
    pub created_at: DateTime<Utc>,
    pub links: HashMap<String, String>,
    pub idempotency_key_used: bool,
    pub idempotency_key_new: bool,
}
```

### Handler Implementation

```rust
/// Trigger a workflow execution
#[utoipa::path(
    post,
    path = "/api/tenants/{tenant_slug}/workflows/{kind}/trigger",
    request_body = TriggerWorkflowRequest,
    params(
        ("tenant_slug" = String, Path, description = "Tenant slug"),
        ("kind" = String, Path, description = "Workflow kind/type")
    ),
    responses(
        (status = 201, description = "Workflow created", body = TriggerWorkflowResponse),
        (status = 200, description = "Existing workflow returned (idempotency)", body = TriggerWorkflowResponse),
        (status = 400, description = "Bad request", body = ErrorResponse),
        (status = 401, description = "Unauthorized", body = ErrorResponse),
        (status = 404, description = "Tenant or workflow not found", body = ErrorResponse),
        (status = 429, description = "Quota exceeded", body = QuotaErrorResponse),
    ),
    security(("bearer_auth" = [])),
    tag = "Workflows"
)]
pub async fn trigger_workflow(
    State(state): State<AppState>,
    Path((tenant_slug, kind)): Path<(String, String)>,
    Json(request): Json<TriggerWorkflowRequest>,
) -> Result<(StatusCode, Json<TriggerWorkflowResponse>), (StatusCode, Json<ErrorResponse>)> {
    // Implementation follows the pattern from gRPC start_workflow
    // 1. Validate tenant exists
    // 2. Parse TTL duration
    // 3. Check idempotency key (if provided)
    // 4. Create workflow execution
    // 5. Notify workers via WorkerNotifier
    // 6. Return response with appropriate status code
}
```

### Router Integration

```rust
// src/api/rest/mod.rs

pub fn create_router(state: AppState) -> Router {
    Router::new()
        .merge(health::routes())
        .route("/_/metrics", get(metrics_handler))
        // Existing tenant routes
        .route("/api/tenants", post(tenants::create_tenant))
        .route("/api/tenants/:slug", get(tenants::get_tenant))
        .route(
            "/api/tenants/:slug/worker-tokens",
            post(tenants::create_worker_token),
        )
        // NEW: Workflow trigger route
        .route(
            "/api/tenants/:tenant_slug/workflows/:kind/trigger",
            post(workflows::trigger_workflow),
        )
        .merge(
            SwaggerUi::new("/api/docs")
                .url("/api/docs/openapi.json", openapi::ApiDoc::openapi()),
        )
        .with_state(state)
}
```

---

## Shared Logic with gRPC

The REST handler should reuse the existing workflow creation logic from the gRPC implementation:

```rust
// src/service/workflow_service.rs

pub struct WorkflowService {
    workflow_repo: Arc<WorkflowRepository>,
    notifier: WorkerNotifier,
    trace_cache: WorkflowTraceCache,
}

impl WorkflowService {
    /// Start a workflow execution (shared by REST and gRPC)
    pub async fn start_workflow(
        &self,
        tenant_id: Uuid,
        kind: String,
        input: Option<Vec<u8>>,
        task_queue: String,
        priority_ms: i64,
        version: Option<String>,
        idempotency_key: Option<String>,
        idempotency_ttl_seconds: Option<i64>,
    ) -> Result<StartWorkflowResult, WorkflowError> {
        // Implementation extracted from WorkflowDispatchService::start_workflow
    }
}

pub struct StartWorkflowResult {
    pub workflow_id: Uuid,
    pub is_new: bool,
    pub status: WorkflowState,
    pub created_at: DateTime<Utc>,
}
```

---

## OpenAPI Schema

```rust
// src/api/rest/openapi.rs

#[derive(OpenApi)]
#[openapi(
    paths(
        health::health_check,
        tenants::create_tenant,
        tenants::get_tenant,
        tenants::create_worker_token,
        workflows::trigger_workflow,  // NEW
    ),
    components(schemas(
        TenantRequest, TenantResponse,
        WorkerTokenRequest, WorkerTokenResponse,
        TriggerWorkflowRequest, TriggerWorkflowResponse,  // NEW
        ValidationErrorResponse, QuotaErrorResponse,      // NEW
        ErrorResponse, HealthResponse,
    )),
    tags(
        (name = "Health", description = "Health check endpoints"),
        (name = "Tenants", description = "Tenant management"),
        (name = "Workers", description = "Worker token management"),
        (name = "Workflows", description = "Workflow execution"),  // NEW
    ),
    modifiers(&SecurityAddon)
)]
struct ApiDoc;

struct SecurityAddon;
impl Modify for SecurityAddon {
    fn modify(&self, openapi: &mut utoipa::openapi::OpenApi) {
        let components = openapi.components.get_or_insert_with(Default::default);
        components.add_security_scheme(
            "bearer_auth",
            SecurityScheme::Http(
                HttpBuilder::new()
                    .scheme(HttpAuthScheme::Bearer)
                    .bearer_format("JWT")
                    .build()
            )
        );
    }
}
```

---

## Security Considerations

1. **Input Validation**
   - Maximum input size: 1MB
   - Maximum idempotency key length: 255 characters
   - Maximum label count: 20
   - Maximum label key/value length: 128 characters each

2. **Rate Limiting**
   - Per-tenant rate limits (configurable)
   - Idempotent requests count toward rate limits

3. **TTL Limits**
   - Minimum TTL: 1 second
   - Maximum TTL: 30 days
   - Enforced server-side regardless of client request

4. **Authorization**
   - JWT must have tenant access (future: Cedar policy check)
   - Worker tokens are NOT valid for REST API (gRPC only)

---

## Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `flovyn_rest_workflow_triggered_total` | Counter | `tenant_id`, `workflow_kind`, `status` | Total workflows triggered via REST |
| `flovyn_idempotency_hits_total` | Counter | `tenant_id` | Duplicate requests (existing key found) |
| `flovyn_idempotency_misses_total` | Counter | `tenant_id` | New keys created |
| `flovyn_idempotency_expired_total` | Counter | - | Keys cleaned up by expiration |
| `flovyn_idempotency_cleared_total` | Counter | `tenant_id` | Keys cleared due to failed execution status |
| `flovyn_rest_request_duration_seconds` | Histogram | `endpoint`, `status_code` | Request latency |

---

## Testing

### Unit Tests

```rust
#[tokio::test]
async fn test_trigger_workflow_success() {
    // Test basic workflow triggering
}

#[tokio::test]
async fn test_trigger_workflow_with_idempotency_key() {
    // Test that duplicate requests return same execution
}

#[tokio::test]
async fn test_trigger_workflow_idempotency_key_expired() {
    // Test that expired keys allow new executions
}

#[tokio::test]
async fn test_trigger_workflow_invalid_ttl() {
    // Test TTL validation
}

#[tokio::test]
async fn test_trigger_workflow_tenant_not_found() {
    // Test 404 for unknown tenant
}

#[tokio::test]
async fn test_trigger_workflow_failed_execution_allows_retry() {
    // Test that same idempotency key can create new execution after failure
}

#[tokio::test]
async fn test_concurrent_requests_same_idempotency_key() {
    // Test that concurrent requests with same key create single execution
}
```

### E2E Tests

```rust
// tests/e2e/rest_workflow_tests.rs

#[tokio::test]
async fn test_rest_trigger_workflow_e2e() {
    let harness = TestHarness::start().await;

    let response = harness
        .rest_client()
        .post("/api/tenants/test-tenant/workflows/greeting/trigger")
        .json(&json!({
            "input": { "name": "World" },
            "idempotencyKey": "greeting-world-1"
        }))
        .send()
        .await;

    assert_eq!(response.status(), 201);

    let body: TriggerWorkflowResponse = response.json().await;
    assert!(body.idempotency_key_new);

    // Second request should return existing
    let response2 = harness
        .rest_client()
        .post("/api/tenants/test-tenant/workflows/greeting/trigger")
        .json(&json!({
            "input": { "name": "World" },
            "idempotencyKey": "greeting-world-1"
        }))
        .send()
        .await;

    assert_eq!(response2.status(), 200);

    let body2: TriggerWorkflowResponse = response2.json().await;
    assert!(!body2.idempotency_key_new);
    assert_eq!(body.workflow_execution_id, body2.workflow_execution_id);
}
```

---

## Future Enhancements

1. **Batch Triggering**: `POST /api/tenants/{slug}/workflows/batch` to trigger multiple workflows atomically
2. **Workflow Status Query**: `GET /api/tenants/{slug}/workflows/{id}/status`
3. **Workflow Cancellation**: `POST /api/tenants/{slug}/workflows/{id}/cancel`
4. **Webhook Integration**: Configurable webhooks for workflow completion events

---

## References

- [Idempotency Keys Design](/Users/manhha/Developer/manhha/leanapp/flovyn/docs/design/idempotency-keys.md)
- [Flovyn Server Design](./flovyn-server.md)
- [gRPC StartWorkflow Implementation](../../src/api/grpc/workflow_dispatch.rs:385)
- [REST API Patterns](flovyn-server/src/api/rest/tenants.rs)
- [Kotlin WorkflowTriggerController](flovyn-server//Users/manhha/Developer/manhha/leanapp/flovyn/server/app/src/main/kotlin/ai/flovyn/controller/WorkflowTriggerController.kt) - Reference implementation
