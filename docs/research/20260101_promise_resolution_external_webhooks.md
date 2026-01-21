# Promise Resolution and External Webhook Integration

**Date:** 2026-01-01
**Research Question:** How do Temporal and Hatchet resolve promises from external webhooks (e.g., Stripe)?

## Executive Summary

| Aspect | Temporal | Hatchet |
|--------|----------|---------|
| **What workflow gives to Stripe** | Task Token (opaque bytes) OR Workflow+Activity IDs | Nothing - uses event key matching |
| **Correlation Mechanism** | Explicit: token/IDs passed to external system and returned | Implicit: event key + CEL expression matching |
| **Idempotency Keys** | Yes - `request_id` on activities/signals | Yes - claim-based with `claimed_by_external_id` |
| **Who knows about correlation** | External system must store and return the token/IDs | Only Hatchet knows - external system just sends webhook |

---

## Temporal: Explicit Correlation (Token/ID-Based)

### What Gets Passed to Stripe

The workflow/activity **explicitly passes** correlation information to Stripe:

**Option A: Task Token** (opaque bytes, ~100-200 bytes base64 encoded)
```
Activity → Stripe: "Here's my task token: eyJuYW1lc3BhY2VfaWQi..."
Stripe → Webhook: "Completing with token: eyJuYW1lc3BhY2VfaWQi..."
```

**Option B: Workflow + Activity IDs** (human-readable strings)
```
Activity → Stripe: "workflow_id=order-123, activity_id=charge-payment"
Stripe → Webhook: "Completing workflow=order-123, activity=charge-payment"
```

### Task Token Structure

From `temporal/common/tasktoken/token.go`:

```go
type ActivityTaskToken struct {
    NamespaceId       string      // Temporal namespace
    WorkflowId        string      // e.g., "order-123"
    RunId             string      // Specific execution run
    ScheduledEventID  int64       // Position in workflow history
    ActivityId        string      // e.g., "charge-payment"
    ActivityType      string
    Attempt           int32
    Clock             VectorClock
}
```

### Complete Flow with Stripe

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. ACTIVITY STARTS                                                  │
│    Activity gets task_token from Temporal                           │
│    task_token = base64(protobuf{workflow_id, activity_id, ...})     │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 2. ACTIVITY CALLS STRIPE                                            │
│    stripe.Charge.create(                                            │
│        amount=2000,                                                 │
│        metadata={                                                   │
│            "task_token": "eyJuYW1lc3BhY2VfaWQi...",  ← PASSED HERE  │
│            "workflow_id": "order-123",               ← OR THESE     │
│            "activity_id": "charge-payment"                          │
│        }                                                            │
│    )                                                                │
│    activity.raise_complete_async()  # Don't wait for return         │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 3. STRIPE STORES METADATA                                           │
│    Stripe saves the task_token/IDs in the charge record             │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 4. STRIPE SENDS WEBHOOK                                             │
│    POST /temporal-webhook                                           │
│    {                                                                │
│        "type": "charge.succeeded",                                  │
│        "data": {                                                    │
│            "object": {                                              │
│                "id": "ch_abc123",                                   │
│                "metadata": {                                        │
│                    "task_token": "eyJuYW1lc3BhY2VfaWQi...",         │
│                    "workflow_id": "order-123",                      │
│                    "activity_id": "charge-payment"                  │
│                }                                                    │
│            }                                                        │
│        }                                                            │
│    }                                                                │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 5. WEBHOOK HANDLER EXTRACTS TOKEN/IDS AND COMPLETES                 │
│    token = event.data.object.metadata["task_token"]                 │
│    client.complete_activity(token, result)                          │
│    # OR                                                             │
│    client.complete_activity_by_id(workflow_id, activity_id, result) │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 6. WORKFLOW RESUMES                                                 │
│    Activity completes with the result from Stripe                   │
└─────────────────────────────────────────────────────────────────────┘
```

### Code Example

```python
@activity.defn
async def charge_payment(order_id: str, amount: int) -> PaymentResult:
    # Get the token to pass to Stripe
    task_token = activity.info().task_token  # bytes

    # Create Stripe charge with token in metadata
    stripe.Charge.create(
        amount=amount,
        metadata={
            # Option A: Pass opaque token
            "task_token": base64.b64encode(task_token).decode(),
            # Option B: Pass readable IDs
            "workflow_id": activity.info().workflow_id,
            "activity_id": activity.info().activity_id,
        }
    )

    # Tell Temporal: don't wait for me to return
    activity.raise_complete_async()

# Webhook handler (Flask/FastAPI endpoint)
async def stripe_webhook(request):
    event = stripe.Event.construct_from(request.json, stripe.api_key)
    if event.type == "charge.succeeded":
        charge = event.data.object

        # Option A: Use token
        token = base64.b64decode(charge.metadata["task_token"])
        await client.complete_activity(token, PaymentResult(charge_id=charge.id))

        # Option B: Use IDs
        await client.complete_activity_by_id(
            workflow_id=charge.metadata["workflow_id"],
            activity_id=charge.metadata["activity_id"],
            result=PaymentResult(charge_id=charge.id)
        )
```

### Key Point

**Stripe MUST store and return the token/IDs**. Without them, the webhook handler cannot know which workflow to complete.

---

## Hatchet: Implicit Correlation (Event Key Matching)

### What Gets Passed to Stripe

**Nothing workflow-specific!** The workflow does NOT pass any token or ID to Stripe.

Instead:
1. Workflow declares what **event key** it's waiting for (e.g., `payment:completed`)
2. Workflow optionally provides a **CEL filter expression** (e.g., `input.order_id == 'order-123'`)
3. Hatchet has a generic webhook endpoint registered with Stripe
4. When webhook arrives, Hatchet extracts an event key from the payload
5. Hatchet queries for all workflows waiting for that event key + matching the filter

### Complete Flow with Stripe

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. WORKFLOW REGISTERS WAIT CONDITION                                │
│    ctx.waitFor(                                                     │
│        event_key="payment:completed",                               │
│        expression="input.order_id == 'order-123'"  ← FILTER         │
│    )                                                                │
│    # Hatchet stores: task_id + event_key + expression in database   │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 2. WORKFLOW CALLS STRIPE (NO SPECIAL METADATA)                      │
│    stripe.Charge.create(                                            │
│        amount=2000,                                                 │
│        metadata={                                                   │
│            "order_id": "order-123"   ← JUST BUSINESS DATA           │
│        }                                                            │
│    )                                                                │
│    # No task_token, no workflow_id passed to Stripe!                │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 3. STRIPE SENDS WEBHOOK TO HATCHET'S GENERIC ENDPOINT               │
│    POST /api/orgs/{org}/webhooks/stripe-payments           │
│    {                                                                │
│        "type": "charge.succeeded",                                  │
│        "data": {                                                    │
│            "object": {                                              │
│                "id": "ch_abc123",                                   │
│                "metadata": { "order_id": "order-123" }              │
│            }                                                        │
│        }                                                            │
│    }                                                                │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 4. HATCHET EXTRACTS EVENT KEY VIA CEL                               │
│    Webhook config has: event_key_expression="'payment:completed'"   │
│    Evaluates to: "payment:completed"                                │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 5. HATCHET QUERIES DATABASE FOR MATCHING WORKFLOWS                  │
│    SELECT * FROM signal_matches                                     │
│    WHERE event_key = 'payment:completed'                            │
│    AND evaluate_cel(expression, webhook_payload) = true             │
│                                                                     │
│    Finds: Workflow waiting with expression="input.order_id == 'order-123'" │
│    Payload has: order_id = "order-123" → MATCH!                     │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ 6. WORKFLOW RESUMES                                                 │
│    Matched workflow receives webhook payload as input               │
└─────────────────────────────────────────────────────────────────────┘
```

### Code Example

```python
@hatchet.durable_task(name="ProcessOrder")
async def process_order(input: OrderInput, ctx: DurableContext):
    order_id = input.order_id

    # Create Stripe charge - NO workflow metadata needed!
    stripe.Charge.create(
        amount=input.amount,
        metadata={"order_id": order_id}  # Just business data
    )

    # Wait for payment completion
    # Hatchet will match incoming webhooks by order_id
    result = await ctx.aio_wait_for(
        "payment",
        UserEventCondition(
            event_key="payment:completed",
            expression=f"input.metadata.order_id == '{order_id}'"
        ),
    )

    # result contains the webhook payload
    return {"charge_id": result["data"]["object"]["id"]}
```

### Key Point

**Stripe does NOT need to store any workflow identifiers**. The correlation happens entirely within Hatchet via event key + expression matching.

---

## Side-by-Side Comparison

| Aspect | Temporal | Hatchet |
|--------|----------|---------|
| **What workflow passes to Stripe** | `task_token` (bytes) or `workflow_id + activity_id` | Nothing workflow-specific |
| **What Stripe must store** | The token/IDs in charge metadata | Just business data (order_id, etc.) |
| **How webhook finds workflow** | Extract token/IDs from metadata, call complete API | Hatchet matches event key + expression filter |
| **Correlation location** | In external system (Stripe metadata) | In Hatchet database (signal_matches table) |
| **Webhook endpoint** | Your app's endpoint, calls Temporal API | Hatchet's generic webhook endpoint |
| **Multiple workflows same event** | Each has unique token/IDs | Matched by expression filter |

### Which Approach Does Flovyn Use?

Flovyn currently uses **Temporal-style explicit correlation**:
- Promise has a unique `promise_id` (e.g., `{workflow_id}:{promise_name}`)
- Workflow passes `promise_id` to Stripe in metadata
- Webhook handler extracts `promise_id` and calls `resolve_promise(promise_id, result)`

The **idempotency key** (e.g., `stripe:evt_abc123`) is separate from correlation:
- **Correlation**: Which promise to resolve? → `promise_id`
- **Idempotency**: Is this a duplicate request? → `idempotency_key`

---

## Temporal Idempotency Mechanisms

1. **Workflow Creation**: `create_request_id` prevents duplicate workflows
2. **Signal Deduplication**: `signal_requested_ids` set prevents duplicate signal processing
3. **Update Deduplication**: Updates are keyed by `update_id` - same ID returns previous outcome
4. **Activity Deduplication**: Activities have `request_id` for deduplication

---

## Hatchet Idempotency Mechanisms

From `hatchet/pkg/repository/v1/idempotency.go`:

```go
type IdempotencyRepository interface {
    CreateIdempotencyKey(ctx context.Context, orgId, key string, expiresAt pgtype.Timestamptz) error
    EvictExpiredIdempotencyKeys(ctx context.Context, orgId pgtype.UUID) error
}
```

- **Claim-based system**: `claimed_by_external_id` tracks which external entity claimed the key
- **FIFO ordering**: `ROW_NUMBER()` ensures deterministic claiming
- **Expiration**: Keys expire after configured duration
- **Lock-free**: `FOR UPDATE SKIP LOCKED` enables parallel processing

---

## Implications for Flovyn

### Current Promise Design

Flovyn has promises with `name` field. Need to decide:

1. **Resolution by ID vs Name**
   - Temporal: Resolves by ID (task token or activity ID)
   - Hatchet: Resolves by event key (derived from payload)
   - **Recommendation**: Support both ID and name for flexibility

2. **External Completion Pattern**

   Option A: Token-based (Temporal-style)
   ```rust
   // Activity/task gets completion token
   let token = ctx.get_completion_token();
   // External system later calls
   POST /api/promises/complete
   { "token": "...", "result": {...} }
   ```

   Option B: ID-based
   ```rust
   // Promise has unique ID
   POST /api/workflows/{workflow_id}/promises/{promise_id}/complete
   { "result": {...} }
   ```

   Option C: Event-driven (Hatchet-style)
   ```rust
   // Promise waits for event key
   ctx.wait_for_event("stripe:charge:ch_123").await
   // Webhook creates event with matching key
   POST /api/events
   { "key": "stripe:charge:ch_123", "data": {...} }
   ```

3. **Idempotency for External Completions**
   - Every completion request should have a `request_id` for deduplication
   - Track completed request IDs to prevent double-completion

### Recommended API for Flovyn

```rust
// Promise creation with optional external completion
let promise = ctx.create_promise(PromiseOptions {
    name: "payment-charge",
    timeout: Duration::from_secs(3600),
    // For external completion
    completion_mode: CompletionMode::External {
        // Generated token for external system
        token: Some(CompletionToken::generate()),
        // OR wait for event key
        event_key: Some("stripe:charge:{order_id}"),
    },
});

// External completion endpoint
POST /api/v1/promises/complete
{
    "token": "ct_abc123...",           // Token-based
    "request_id": "req_xyz",           // Idempotency key
    "result": { "charge_id": "ch_123" }
}

// OR ID-based
POST /api/v1/workflows/{workflow_id}/promises/{promise_name}/complete
{
    "request_id": "req_xyz",           // Idempotency key
    "result": { "charge_id": "ch_123" }
}

// OR event-based
POST /api/v1/events
{
    "key": "stripe:charge:ch_123",
    "data": { "amount": 2000 },
    "idempotency_key": "evt_stripe_ch_123"
}
```

---

## Flovyn: Unified Idempotency Design (Hatchet-style)

### Current State

Flovyn has two different idempotency mechanisms:

| Use Case | Current Mechanism |
|----------|-------------------|
| Workflow creation | `idempotency_key` table with claim-then-register pattern |
| Promise resolution | PostgreSQL advisory lock + "already resolved" check |

### Proposed Unified Design

Extend the existing `idempotency_key` table to handle promise resolution using the same claim-based pattern.

#### Schema Change

```sql
-- Add promise_id column to existing table
ALTER TABLE idempotency_key
ADD COLUMN promise_id VARCHAR(255) REFERENCES promise(id) ON DELETE CASCADE;

-- Update constraint to allow exactly one execution type
ALTER TABLE idempotency_key DROP CONSTRAINT idempotency_key_execution_check;
ALTER TABLE idempotency_key ADD CONSTRAINT idempotency_key_execution_check CHECK (
    -- Exactly one of the three must be set (or all NULL during claim phase)
    (workflow_execution_id IS NULL AND task_execution_id IS NULL AND promise_id IS NULL) OR
    (workflow_execution_id IS NOT NULL AND task_execution_id IS NULL AND promise_id IS NULL) OR
    (workflow_execution_id IS NULL AND task_execution_id IS NOT NULL AND promise_id IS NULL) OR
    (workflow_execution_id IS NULL AND task_execution_id IS NULL AND promise_id IS NOT NULL)
);

-- Index for promise lookups
CREATE INDEX idx_idempotency_key_promise ON idempotency_key (promise_id) WHERE promise_id IS NOT NULL;
```

#### Updated ExecutionType Enum

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExecutionType {
    Workflow,
    Task,
    Promise,  // NEW
}
```

#### API Changes

```protobuf
message ResolvePromiseRequest {
    string promise_id = 1;
    bytes value = 2;
    optional string idempotency_key = 3;           // NEW: e.g., "stripe:evt_abc123"
    optional int64 idempotency_key_ttl_seconds = 4; // NEW: default 24h
}

message ResolvePromiseResponse {
    bool already_resolved = 1;
    bool idempotency_key_used = 2;   // NEW
    bool idempotency_key_new = 3;    // NEW: false if same key returned existing result
}
```

#### Resolution Flow (Hatchet-style)

```
Stripe Webhook → POST /api/v1/promises/resolve
{
    "promise_id": "wf_123:payment-confirmation",
    "value": {"charge_id": "ch_abc", "amount": 2000},
    "idempotency_key": "stripe:evt_xyz789"
}

1. CLAIM: Try INSERT into idempotency_key with NULL promise_id
   - If INSERT succeeds → we claimed the key, proceed to resolve
   - If conflict → check existing row

2. CHECK EXISTING:
   - If promise_id is set → return existing result (idempotent)
   - If promise_id is NULL → another request claiming, wait and retry
   - If promise already resolved (different key) → return success

3. RESOLVE: Actually resolve the promise
   - Append PROMISE_RESOLVED event
   - Update promise table
   - Resume workflow

4. REGISTER: Update idempotency_key with promise_id
```

#### Benefits of Unified Approach

1. **Single mechanism**: Same claim-then-register pattern for workflows, tasks, and promises
2. **Request-level dedup**: External systems can retry with same idempotency key
3. **Auditable**: Can track which external event resolved which promise
4. **TTL support**: Keys expire, allowing re-resolution after expiration if needed
5. **Consistent API**: Same `idempotency_key` + `idempotency_key_ttl` fields across all APIs

#### Example: Stripe Integration

```rust
// Workflow creates promise
let promise = ctx.create_promise("payment-confirmation").await?;

// Start Stripe charge with promise info in metadata
let charge = stripe::Charge::create(ChargeParams {
    amount: 2000,
    metadata: hashmap! {
        "promise_id" => promise.id.clone(),
        "workflow_id" => ctx.workflow_id().to_string(),
    },
    ..Default::default()
}).await?;

// Wait for external resolution
let result = ctx.await_promise::<PaymentResult>("payment-confirmation").await?;
```

```rust
// Webhook handler
async fn stripe_webhook(payload: StripeEvent) -> Result<()> {
    if payload.event_type == "charge.succeeded" {
        let charge = payload.data.object;
        let promise_id = charge.metadata.get("promise_id")?;

        client.resolve_promise(ResolvePromiseRequest {
            promise_id: promise_id.clone(),
            value: serde_json::to_vec(&PaymentResult {
                charge_id: charge.id,
                amount: charge.amount,
            })?,
            // Use Stripe event ID as idempotency key
            // Stripe may retry webhook, this ensures we only process once
            idempotency_key: Some(format!("stripe:{}", payload.id)),
            idempotency_key_ttl_seconds: Some(86400 * 7), // 7 days
        }).await?;
    }
    Ok(())
}
```

#### Comparison with Current Approach

| Aspect | Current (Advisory Lock) | Proposed (Claim-based) |
|--------|-------------------------|------------------------|
| Dedup scope | Promise-level only | Request-level (external event ID) |
| Locking | `pg_advisory_xact_lock` | `INSERT ON CONFLICT` + `FOR UPDATE` |
| Retry handling | Returns success if already resolved | Returns success + tracks original resolver |
| External ID tracking | None | Via `idempotency_key` |
| TTL | None | Configurable expiration |
| Consistency | Same mechanism as workflows | Yes |

---

## Files Referenced

### Temporal
- `temporal/common/tasktoken/token.go` - Task token structure
- `temporal-sdk-java/temporal-sdk/src/main/java/io/temporal/client/ActivityCompletionClient.java`
- `flovyn-server/temporal-sdk-python/temporalio/client.py` - AsyncActivityHandle
- `temporal/service/history/api/respondactivitytaskfailed/api.go` - Completion handling
- `temporal/proto/internal/temporal/server/api/persistence/v1/executions.proto` - SignalInfo, RequestIDInfo

### Hatchet
- `hatchet/api/v1/server/handlers/v1/webhooks/receive.go` - Webhook reception
- `hatchet/internal/services/ingestor/ingestor_v1.go` - Event ingestion
- `hatchet/internal/services/controllers/v1/task/controller.go` - Event trigger matching
- `hatchet/pkg/repository/v1/idempotency.go` - Idempotency repository
- `flovyn-server/hatchet/pkg/repository/v1/sqlcv1/idempotency-keys.sql` - Idempotency SQL

### Flovyn (Current Implementation)
- `flovyn-server/server/migrations/20251217161811_idempotency_keys.sql` - Idempotency key table schema
- `flovyn-server/server/src/repository/idempotency_key_repository.rs` - Claim-then-register pattern
- `flovyn-server/server/src/repository/promise_repository.rs` - Promise domain model
- `server/src/repository/event_repository.rs:552-618` - Current advisory lock-based resolution
- `server/src/api/grpc/workflow_dispatch.rs:938-1050` - Promise resolution handler

### Online Sources
- [Temporal: How to wait for an incoming hook](https://community.temporal.io/t/how-to-wait-for-an-incoming-hook/4799)
- [Temporal Activity Execution docs](https://docs.temporal.io/activity-execution)
- [Temporal Go SDK samples (Async Activity)](https://github.com/temporalio/samples-go)
- [Hatchet Durable Events](https://docs.hatchet.run/home/durable-events)
- [Hatchet Run on Event](https://docs.hatchet.run/home/run-on-event)
- [Stripe Webhooks](https://docs.stripe.com/webhooks)
