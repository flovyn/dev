# Implementation Plan: Unified Idempotency Key for Promises

**Date:** 2026-01-01
**Design Document:** [Unified Idempotency Key Design](../design/20260101_unified_idempotency.md)

## Overview

This plan implements promise idempotency keys to enable external webhook correlation. When a workflow creates a promise with an idempotency key (e.g., `stripe:ch_abc123`), external systems can later resolve the promise by looking it up via that key.

## Prerequisites

- Familiarity with the existing `IdempotencyKeyRepository` (`flovyn-server/server/src/repository/idempotency_key_repository.rs`)
- Understanding of the claim-then-register pattern used for workflow idempotency

## Implementation Phases

### Phase 1: Database Schema Migration

**Goal:** Extend `idempotency_key` table to support promise correlation.

**Files to modify:**
- New migration: `flovyn-server/server/migrations/YYYYMMDDHHMMSS_add_promise_idempotency.sql`

**Changes:**
1. Add `promise_id VARCHAR(255) REFERENCES promise(id) ON DELETE CASCADE` column
2. Update the `idempotency_key_execution_check` constraint to allow promise_id as third option
3. Add index for looking up promise by idempotency key
4. Add index for finding idempotency key by promise

### Phase 2: Repository Layer

**Goal:** Extend `IdempotencyKeyRepository` to handle promise idempotency keys.

**Files to modify:**
- `flovyn-server/server/src/repository/idempotency_key_repository.rs`
- `flovyn-server/server/src/repository/mod.rs`

**Changes:**
1. Add `Promise` variant to `ExecutionType` enum
2. Add `IdempotencyError` enum for promise-specific errors
3. Implement `create_for_promise()` method
4. Implement `find_promise_by_key()` method
5. Update `clear_for_execution()` to handle promise type

### Phase 3: Protobuf API Changes

**Goal:** Extend `CreatePromiseCommand` to accept optional idempotency key.

**Files to modify:**
- `server/proto/flovyn.proto`
- Run `cargo build` to regenerate `flovyn-server/server/src/generated/flovyn.v1.rs`

**Changes:**
1. Add `optional string idempotency_key = 3` to `CreatePromiseCommand`
2. Add `optional int64 idempotency_key_ttl_seconds = 4` to `CreatePromiseCommand`

### Phase 4: Command Handler Integration

**Goal:** Process idempotency key when creating promises via workflow commands.

**Files to modify:**
- `flovyn-server/server/src/api/grpc/workflow_dispatch.rs` (command processing)
- `flovyn-server/server/src/repository/event_repository.rs` (event handling)

**Changes:**
1. Extract idempotency key from `CreatePromiseCommand`
2. Call `IdempotencyKeyRepository::create_for_promise()` when creating promise
3. Handle key conflict errors appropriately
4. Ensure proper transaction handling

### Phase 5: REST API for Promise Resolution

**Goal:** Add REST API to resolve promises by ID or idempotency key.

**Files to modify:**
- `flovyn-server/server/src/api/rest/mod.rs` (add routes)
- `flovyn-server/server/src/api/rest/workflows.rs` (add handler)
- `flovyn-server/server/src/api/rest/openapi.rs` (register endpoint and DTOs)

**API Design (from design document):**
```
POST /api/tenants/{slug}/promises/id:{promise_id}/resolve
POST /api/tenants/{slug}/promises/key:{idempotency_key}/resolve

POST /api/tenants/{slug}/promises/id:{promise_id}/reject
POST /api/tenants/{slug}/promises/key:{idempotency_key}/reject
```

Resolve request body:
```json
{
  "value": { ... }
}
```

Reject request body:
```json
{
  "error": "Payment declined"
}
```

Response:
- `200 OK` with `{"resolved": true}` - Promise resolved/rejected
- `200 OK` with `{"resolved": false, "alreadyResolved": true}` - Already resolved (idempotent)
- `404 Not Found` - Promise not found

**Changes:**
1. Add `ResolvePromiseRequest`, `RejectPromiseRequest`, and `PromiseResponse` DTOs
2. Implement `resolve_promise` and `reject_promise` handlers with identifier parsing
3. Parse identifier prefix: `id:` → lookup by promise_id, `key:` → lookup by idempotency key
4. Add routes:
   - `/api/tenants/:tenant_slug/promises/:identifier/resolve`
   - `/api/tenants/:tenant_slug/promises/:identifier/reject`
5. For `key:` prefix, use `find_promise_by_key()` to get promise_id
6. Reuse `resolve_promise_atomically()` logic from gRPC handler

## TODO List

### Phase 1: Database Migration
- [x] Create migration file with actual timestamp (`20260101204520_add_promise_idempotency.sql`)
- [x] Add `promise_id` column to `idempotency_key` table
- [x] Drop existing `idempotency_key_execution_check` constraint
- [x] Add new constraint supporting three execution types
- [x] Add `idx_idempotency_key_promise` index for key->promise lookups
- [x] Add `idx_idempotency_key_by_promise` index for promise->key lookups
- [x] Verify migration runs successfully

### Phase 2: Repository Layer
- [x] Add `Promise` variant to `ExecutionType` enum
- [x] Add `IdempotencyError` enum with `KeyConflict` and `Database` variants
- [x] Implement `create_for_promise()` method with claim-then-register pattern
- [x] Implement `find_promise_by_key()` method
- [x] Add `clear_for_promise()` method for cleanup

### Phase 3: Protobuf API Changes
- [x] Add `idempotency_key` field to `CreatePromiseCommand`
- [x] Add `idempotency_key_ttl_seconds` field to `CreatePromiseCommand`
- [x] Run `cargo build` to regenerate protobuf code
- [x] Verify generated code compiles

### Phase 4: Command Handler Integration
- [x] Modify command handler to extract idempotency key from `CreatePromiseCommand`
- [x] Call repository to create idempotency key entry after promise creation
- [x] Handle `IdempotencyError::KeyConflict` error (log warning but don't fail)

### Phase 5: REST API for Promise Resolution
- [x] Add `ResolvePromiseRequest` DTO (value field)
- [x] Add `RejectPromiseRequest` DTO (error field)
- [x] Add `PromiseResponse` DTO (resolved, alreadyResolved, promiseId fields)
- [x] Implement `resolve_promise` handler with identifier parsing
- [x] Implement `reject_promise` handler with identifier parsing
- [x] Add routes in `mod.rs`:
  - [x] `/api/tenants/:tenant_slug/promises/:identifier/resolve`
  - [x] `/api/tenants/:tenant_slug/promises/:identifier/reject`
- [x] Register endpoints and DTOs in `openapi.rs`
- [x] Add Promises tag to OpenAPI spec

### Phase 6: Integration Tests
- [x] `test_promise_resolve_via_rest_api` - resolve by `id:{promise_id}` prefix
- [x] `test_promise_resolve_by_idempotency_key` - resolve by `key:{idempotency_key}` prefix
- [x] `test_promise_resolve_not_found` - returns 404 for non-existent key
- [x] Existing `test_promise_workflow` confirms backward compatibility

### Phase 7: Validation & Cleanup
- [x] Run full test suite: 110 tests pass
- [x] Clean up unused code warnings
- [x] All compilation warnings resolved

## Test Strategy

### Unit Tests (Repository Layer)

Location: `flovyn-server/server/src/repository/idempotency_key_repository.rs`

```rust
#[cfg(test)]
mod tests {
    // Test create_for_promise success and lookup
    #[sqlx::test(fixtures("tenant", "workflow", "promise"))]
    async fn test_create_for_promise_and_lookup(pool: PgPool) { ... }

    // Test key conflict detection
    #[sqlx::test(fixtures("tenant", "workflow", "promise"))]
    async fn test_create_for_promise_key_conflict(pool: PgPool) { ... }

    // Test find_promise_by_key returns None for non-existent
    #[sqlx::test(fixtures("tenant"))]
    async fn test_find_promise_by_key_not_found(pool: PgPool) { ... }

    // Test expired key allows reuse
    #[sqlx::test(fixtures("tenant", "workflow", "promise"))]
    async fn test_expired_key_allows_reuse(pool: PgPool) { ... }
}
```

### Integration Tests (REST API)

Location: `flovyn-server/server/tests/integration/workflow_tests.rs`

Uses `harness.http_client()` to call REST API endpoints.

```rust
/// Workflow that creates a promise with an idempotency key
pub struct PromiseWithKeyWorkflow;

#[async_trait]
impl DynamicWorkflow for PromiseWithKeyWorkflow {
    fn kind(&self) -> &str { "promise-with-key-workflow" }

    async fn execute(&self, ctx: &dyn WorkflowContext, input: DynamicInput) -> Result<DynamicOutput> {
        let key = input.get("idempotencyKey").and_then(|v| v.as_str()).unwrap();

        // Create promise with idempotency key
        let value: Value = ctx.promise_raw_with_options("payment", PromiseOptions {
            idempotency_key: Some(key.to_string()),
            ..Default::default()
        }).await?;

        let mut output = DynamicOutput::new();
        output.insert("promiseValue".to_string(), value);
        Ok(output)
    }
}

#[tokio::test]
async fn test_resolve_promise_by_idempotency_key() {
    tokio::time::timeout(Duration::from_secs(30), async {
        let harness = get_harness().await;
        let http_client = harness.http_client();
        let idempotency_key = format!("stripe:ch_{}", Uuid::new_v4());

        // 1. Start workflow that creates promise with idempotency key
        let start_result = client.start_workflow_with_options(
            "promise-with-key-workflow",
            json!({"idempotencyKey": &idempotency_key}),
            options,
        ).await.unwrap();

        // 2. Wait for promise to be created
        tokio::time::sleep(Duration::from_secs(2)).await;

        // 3. Resolve promise via REST API using idempotency key
        let url = format!(
            "http://localhost:{}/api/tenants/{}/promises/key:{}/resolve",
            harness.http_port, harness.tenant_slug, idempotency_key
        );
        let resp = http_client
            .post(&url)
            .json(&json!({"value": {"approved": true, "amount": 2000}}))
            .send()
            .await.unwrap();

        assert_eq!(resp.status(), 200);
        let body: serde_json::Value = resp.json().await.unwrap();
        assert_eq!(body["resolved"], true);

        // 4. Verify workflow completes with resolved value
        // ... poll for WORKFLOW_COMPLETED event ...
    }).await.expect("Test timed out");
}

#[tokio::test]
async fn test_resolve_promise_by_id() {
    // Test resolving by id:{promise_id} prefix
}

#[tokio::test]
async fn test_reject_promise_by_key() {
    // Test rejecting via key:{key} prefix
    // Workflow should receive error
}

#[tokio::test]
async fn test_resolve_promise_idempotent() {
    // Call resolve twice, second should return alreadyResolved: true
}

#[tokio::test]
async fn test_resolve_promise_not_found() {
    // Non-existent key returns 404
}

#[tokio::test]
async fn test_promise_without_key_backward_compatible() {
    // Existing test_promise_workflow still works
}
```

Test cases:
1. **Resolve by key** - Workflow creates promise with key, resolve via `key:{key}` REST endpoint
2. **Resolve by id** - Resolve via `id:{promise_id}` REST endpoint
3. **Reject by key** - Reject promise via `key:{key}` REST endpoint, workflow receives error
4. **Idempotent resolution** - Second resolve call returns `alreadyResolved: true`
5. **Not found** - Non-existent key returns 404
6. **Backward compatibility** - Promise without key works with existing gRPC `resolve_promise`

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Migration breaks existing data | Constraint uses OR logic, existing rows unaffected |
| Concurrent key claims cause issues | Reuse proven claim-then-register pattern |
| Foreign key constraint with promise table | Use ON DELETE CASCADE for cleanup |

## Out of Scope

- Webhook ingestion endpoint (separate feature)
- Event-key matching with CEL expressions (Hatchet-style, future work)

## Notes

- The proto field is named `CreatePromiseCommand` (not `SchedulePromise` as mentioned in design doc)
- Default TTL should be 24 hours (86400 seconds) if not specified
- Key format convention: use prefixes like `stripe:`, `webhook:` for namespacing
