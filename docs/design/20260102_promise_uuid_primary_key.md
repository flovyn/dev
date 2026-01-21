# Promise UUID Primary Key

**Date:** 2026-01-02
**Status:** Accepted

## Problem

The promise table uses a composite string as the primary key:

```sql
CREATE TABLE promise (
    id VARCHAR(255) PRIMARY KEY,  -- format: "{workflow_execution_id}:{promise_name}"
    workflow_execution_id UUID NOT NULL,
    name VARCHAR(255) NOT NULL,
    ...
);
```

This approach has issues:

1. **Redundancy**: The `id` is just `{workflow_execution_id}:{name}` - redundant with the columns that already exist
2. **Non-standard**: Temporal and Hatchet use UUIDs for signal/promise identifiers
3. **API confusion**: REST API accepts `id:{promise_id}` but the "id" is a composite string, not a proper identifier
4. **Inconsistency**: Other tables (`workflow_execution`, `task_execution`, `worker`) use UUID primary keys

## Research: Industry Standards

### Temporal
```go
// Uses uuid.New() for signal request IDs
signalRequestID := uuid.New()
```

### Hatchet
```go
// Uses UUID for signal external IDs
SignalExternalId string `validate:"required,uuid"`
```

## Decision: Use UUID Primary Key

Change the promise table to use UUID as the primary key:

```sql
CREATE TABLE promise (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workflow_execution_id UUID NOT NULL REFERENCES workflow_execution(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    resolved BOOLEAN NOT NULL DEFAULT FALSE,
    value BYTEA,
    error TEXT,
    timeout_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ,
    created_by_sequence INT NOT NULL,
    resolved_by_sequence INT,

    UNIQUE(workflow_execution_id, name)
);

CREATE INDEX idx_promise_workflow ON promise(workflow_execution_id);
CREATE INDEX idx_promise_pending ON promise(workflow_execution_id, resolved) WHERE resolved = FALSE;
```

## Implementation Changes

### 1. Database Migration

Update `flovyn-server/server/migrations/20251214220815_init.sql`:

```sql
CREATE TABLE promise (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workflow_execution_id UUID NOT NULL REFERENCES workflow_execution(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    ...
    UNIQUE(workflow_execution_id, name)
);
```

### 2. Promise Domain Model

Update `flovyn-server/server/src/repository/promise_repository.rs`:

```rust
pub struct Promise {
    pub id: Uuid,  // Changed from String
    pub workflow_execution_id: Uuid,
    pub name: String,
    // ... rest unchanged
}
```

### 3. Promise Repository

Update all methods to use `Uuid`:

```rust
impl PromiseRepository {
    pub async fn get(&self, id: Uuid) -> Result<Option<Promise>, sqlx::Error> { ... }

    pub async fn get_by_workflow_and_name(
        &self,
        workflow_id: Uuid,
        name: &str,
    ) -> Result<Option<Promise>, sqlx::Error> { ... }

    pub async fn resolve(&self, id: Uuid, value: Vec<u8>, sequence: i32) -> Result<(), sqlx::Error> { ... }

    pub async fn reject(&self, id: Uuid, error: &str, sequence: i32) -> Result<(), sqlx::Error> { ... }

    pub async fn create(&self, promise: &Promise) -> Result<Uuid, sqlx::Error> {
        // Let database generate UUID, return it
    }
}
```

### 4. Workflow Dispatch (gRPC)

Update `flovyn-server/server/src/api/grpc/workflow_dispatch.rs`:

```rust
// Before:
let composite_promise_id = format!("{}:{}", workflow_id, promise_cmd.promise_id);
let promise = Promise {
    id: composite_promise_id.clone(),
    ...
};

// After:
let promise = Promise {
    id: Uuid::new_v4(),  // Generate UUID
    workflow_execution_id: workflow_id,
    name: promise_cmd.promise_id.clone(),
    ...
};
```

### 5. Idempotency Key Table

Update `idempotency_key` table to store UUID instead of composite string:

```sql
-- Change promise_id from VARCHAR to UUID
ALTER TABLE idempotency_key
    ALTER COLUMN promise_id TYPE UUID USING promise_id::uuid;
```

Update `IdempotencyKeyRepository`:

```rust
pub async fn create_for_promise(
    &self,
    tenant_id: Uuid,
    key: &str,
    promise_id: Uuid,  // Changed from &str
    expires_at: DateTime<Utc>,
) -> Result<(), IdempotencyError> { ... }

pub async fn find_promise_by_key(
    &self,
    tenant_id: Uuid,
    key: &str,
) -> Result<Option<Uuid>, sqlx::Error> {  // Changed from Option<String>
    ...
}
```

### 6. REST API

Update `flovyn-server/server/src/api/rest/promises.rs`:

```rust
// Before: parse_identifier returns IdentifierType with String
// After:
enum IdentifierType {
    PromiseId(Uuid),
    IdempotencyKey(String),
}

fn parse_identifier(identifier: &str) -> Result<IdentifierType, String> {
    if let Some(id) = identifier.strip_prefix("id:") {
        let uuid = Uuid::parse_str(id)
            .map_err(|_| "Invalid UUID format for promise ID")?;
        Ok(IdentifierType::PromiseId(uuid))
    } else if let Some(key) = identifier.strip_prefix("key:") {
        Ok(IdentifierType::IdempotencyKey(key.to_string()))
    } else {
        Err("Identifier must start with 'id:' or 'key:' prefix".to_string())
    }
}

// Response DTO
pub struct PromiseResponse {
    pub resolved: bool,
    pub already_resolved: bool,
    pub promise_id: Uuid,  // Changed from String
}
```

REST API endpoints remain the same, but now accept proper UUIDs:
- `POST /api/tenants/{slug}/promises/id:{uuid}/resolve`
- `POST /api/tenants/{slug}/promises/key:{idempotency_key}/resolve`

### 7. SDK Changes

The Rust SDK's `await_promise(name)` method uses the promise name, not the ID. The server handles the mapping internally. However, if the SDK stores or returns promise IDs, those need to change from String to UUID.

## Alternatives Considered

### Composite Primary Key (workflow_execution_id, name)

Remove the `id` column entirely:

```sql
CREATE TABLE promise (
    workflow_execution_id UUID NOT NULL,
    name VARCHAR(255) NOT NULL,
    PRIMARY KEY (workflow_execution_id, name),
    ...
);
```

**Pros:**
- Simpler schema, no redundancy
- Natural key for promises (a promise is uniquely identified by its workflow + name)

**Cons:**
- REST API would need two identifiers: `/promises/{workflow_id}/{name}/resolve`
- External systems would need to track both workflow_id and promise name
- Idempotency key table would need two columns for the reference

**Verdict:** UUID is cleaner for external API consumption, aligns with industry standards.

## Summary

| Component | Before | After |
|-----------|--------|-------|
| `promise.id` | `VARCHAR(255)` composite | `UUID` |
| `Promise.id` (Rust) | `String` | `Uuid` |
| `idempotency_key.promise_id` | `VARCHAR(255)` | `UUID` |
| REST API identifier | `id:{workflow_id}:{name}` | `id:{uuid}` |
| Promise uniqueness | PK on composite string | UNIQUE(workflow_execution_id, name) |
