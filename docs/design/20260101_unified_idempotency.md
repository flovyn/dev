# Unified Idempotency Key Design

**Date:** 2026-01-01
**Status:** Draft
**Related:** [Promise Resolution Research](../research/20260101_promise_resolution_external_webhooks.md)

## Problem Statement

When a workflow waits for an external event (e.g., Stripe payment confirmation), we need a way to:

1. **Correlate** incoming webhooks to the correct promise
2. **Deduplicate** webhook retries (Stripe may send the same event multiple times)

Currently, the only way to resolve a promise is by its `promise_id`. This requires:
- Passing `promise_id` to the external system (e.g., in Stripe metadata)
- External system storing and returning the `promise_id`
- Webhook handler extracting `promise_id` and calling resolve API

This is cumbersome and not all external systems support metadata passthrough.

## Proposed Solution

Create a promise **with an idempotency key** that serves dual purpose:

1. **Correlation**: Look up which promise to resolve by key
2. **Deduplication**: Same key cannot resolve multiple times

### Flow

```
1. Workflow calls Stripe to create charge
   → Stripe returns charge_id "ch_abc123"

2. Workflow creates promise with idempotency key:
   create_promise("payment", key: "stripe:ch_abc123")

3. Workflow awaits promise normally

--- later ---

4. Stripe webhook arrives with charge_id "ch_abc123"

5. Resolver looks up promise by key "stripe:ch_abc123"
   → Finds promise

6. Resolver resolves the promise with webhook payload
```

**Key insight**: The webhook handler doesn't need to know the promise_id. It only provides the external event ID, and the system finds the correct promise.

## Goals

1. Allow workflows to create a promise with an idempotency key
2. Enable future resolution-by-key lookup (out of scope for this design)
3. Reuse existing `idempotency_key` table

## Non-Goals

- REST/gRPC endpoint to resolve promise by idempotency key (future work)
- Webhook ingestion endpoint (separate feature)
- Event-key matching with CEL expressions (Hatchet-style, future work)

## Design

### Schema Changes

Extend the existing `idempotency_key` table to support promise correlation:

```sql
-- Migration: YYYYMMDDHHMMSS_add_promise_idempotency.sql

-- Add promise_id column
ALTER TABLE idempotency_key
ADD COLUMN promise_id VARCHAR(255) REFERENCES promise(id) ON DELETE CASCADE;

-- Drop old constraint and add new one supporting promise_id
ALTER TABLE idempotency_key DROP CONSTRAINT IF EXISTS idempotency_key_execution_check;
ALTER TABLE idempotency_key ADD CONSTRAINT idempotency_key_execution_check CHECK (
    -- All NULL = placeholder during claim phase
    (workflow_execution_id IS NULL AND task_execution_id IS NULL AND promise_id IS NULL) OR
    -- Exactly one set = registered idempotency key
    (workflow_execution_id IS NOT NULL AND task_execution_id IS NULL AND promise_id IS NULL) OR
    (workflow_execution_id IS NULL AND task_execution_id IS NOT NULL AND promise_id IS NULL) OR
    (workflow_execution_id IS NULL AND task_execution_id IS NULL AND promise_id IS NOT NULL)
);

-- Index for looking up promise by idempotency key
CREATE INDEX idx_idempotency_key_promise
ON idempotency_key (tenant_id, key)
WHERE promise_id IS NOT NULL;

-- Index for finding idempotency key by promise
CREATE INDEX idx_idempotency_key_by_promise
ON idempotency_key (promise_id)
WHERE promise_id IS NOT NULL;
```

### API Changes

#### gRPC (flovyn.proto)

Extend `SchedulePromise` command to accept an optional idempotency key:

```protobuf
message SchedulePromise {
    string name = 1;
    optional int64 timeout_ms = 2;
    optional string idempotency_key = 3;            // NEW: e.g., "stripe:ch_abc123"
    optional int64 idempotency_key_ttl_seconds = 4; // NEW: default 86400 (24h)
}
```

#### Workflow SDK Usage

```rust
// Call Stripe in a run() block (non-deterministic operation)
let charge_id = ctx.run("create-charge", || async {
    let charge = stripe::Charge::create(ChargeParams {
        amount: 2000,
        metadata: hashmap! {
            "order_id" => order_id.clone(),
        },
        ..Default::default()
    }).await?;
    Ok(charge.id)
}).await?;

// Create promise with the charge ID as idempotency key
let result = ctx.create_promise::<PaymentResult>("payment")
    .with_idempotency_key(format!("stripe:{}", charge_id))
    .await?;

// Workflow waits here until webhook resolves by key
```

### Repository Interface

```rust
impl IdempotencyKeyRepository {
    /// Create an idempotency key entry for a promise.
    /// Called when promise is created with an idempotency key.
    ///
    /// Returns Err if key is already registered to a different promise.
    pub async fn create_for_promise(
        &self,
        tenant_id: Uuid,
        key: &str,
        promise_id: &str,
        expires_at: DateTime<Utc>,
    ) -> Result<(), IdempotencyError>;

    /// Look up promise by idempotency key.
    /// Used by resolver to find which promise to resolve.
    pub async fn find_promise_by_key(
        &self,
        tenant_id: Uuid,
        key: &str,
    ) -> Result<Option<String>, sqlx::Error>;
}

#[derive(Debug, thiserror::Error)]
pub enum IdempotencyError {
    #[error("Key already registered to different promise: {existing_promise_id}")]
    KeyConflict { existing_promise_id: String },

    #[error("Database error: {0}")]
    Database(#[from] sqlx::Error),
}
```

### Error Handling

| Scenario | Behavior |
|----------|----------|
| Key not used | Create promise normally |
| Key is new | Create promise and idempotency key entry |
| Key already used for different promise | Return error with existing promise_id |
| Key expired | Treat as unused (allow creation) |

### Cleanup

Expired idempotency keys are cleaned up by the existing `delete_expired()` method in `IdempotencyKeyRepository`. No changes needed.

## Future Work (Out of Scope)

### Resolution by Key

Use consistent identifier prefixes for promise resolution:

```
POST /api/tenants/{slug}/promises/id:{promise_id}/resolve
POST /api/tenants/{slug}/promises/key:{idempotency_key}/resolve
```

Examples:
```
POST /api/tenants/{slug}/promises/id:550e8400-e29b-41d4-a716-446655440000:payment/resolve
POST /api/tenants/{slug}/promises/key:stripe:ch_abc123/resolve
```

The prefix tells the server how to look up the promise:
- `id:` - by promise_id (existing behavior)
- `key:` - by idempotency key (new)

## Usage Example: Stripe Integration

```rust
// Workflow
async fn process_order(ctx: &WorkflowContext, order: Order) -> Result<()> {
    // 1. Call Stripe in run() block (non-deterministic)
    let charge_id = ctx.run("create-stripe-charge", || async {
        let charge = stripe::Charge::create(ChargeParams {
            amount: order.amount,
            metadata: hashmap! {
                "order_id" => order.id.clone(),
            },
            ..Default::default()
        }).await?;
        Ok(charge.id)
    }).await?;

    // 2. Create promise with Stripe charge ID as idempotency key
    let payment: PaymentResult = ctx.create_promise("payment")
        .with_idempotency_key(format!("stripe:{}", charge_id))
        .await?;

    // 3. Continue with order fulfillment...
    Ok(())
}
```

```rust
// Future: Webhook handler (out of scope for this design)
async fn stripe_webhook(payload: StripeEvent) -> Result<()> {
    if payload.event_type == "charge.succeeded" {
        let charge = payload.data.object;

        // Resolve by key - no promise_id needed!
        // POST /api/tenants/{slug}/promises/key:stripe:{charge_id}/resolve
        client.resolve_promise(ResolvePromiseRequest {
            identifier: format!("key:stripe:{}", charge.id),
            value: serde_json::to_vec(&PaymentResult {
                charge_id: charge.id,
                amount: charge.amount,
            })?,
        }).await?;
    }
    Ok(())
}
```

## Alternatives Considered

### 1. Pass promise_id through external system metadata

**Approach**: Workflow passes `promise_id` to Stripe, Stripe returns it in webhook.

**Cons**:
- Requires external system to support metadata passthrough
- Exposes internal IDs to external systems
- More complex webhook handling

**Decision**: Rejected in favor of key-based correlation.

### 2. Separate correlation table

**Approach**: Create a new `promise_correlation` table instead of extending `idempotency_key`.

**Cons**:
- Another table to maintain
- Duplicates TTL/expiration logic
- Inconsistent with workflow idempotency pattern

**Decision**: Rejected - reuse existing `idempotency_key` table.

## Testing Strategy

1. **Unit tests**:
   - `create_for_promise` inserts idempotency key entry
   - `find_promise_by_key` returns correct promise
   - Key conflict detection works

2. **Integration tests**:
   - Create promise with key, look up by key
   - Concurrent promise creation with same key (one wins, one fails)
   - Key expiration allows reuse
   - Backward compatibility (promise without key still works)
