# Eventhook Milestone 1: Receive & Route

**Date:** 2025-01-01
**Status:** Design
**Related:** [M0 Design](./20251231_eventhook_milestone0_event_publisher.md), [Research](../research/eventhook/20251231_research.md), [Roadmap](../research/eventhook/20251231_roadmap.md)

## Overview

This document describes the design for Milestone 1 of the Eventhook feature: receiving webhooks from external providers and routing them to workflows, tasks, and promises.

**Scope:**
- Eventhook plugin skeleton and registration
- Database schema for sources, routes, events, and event actions
- Ingest endpoint to receive webhooks
- Signature verification (HMAC, API key, basic auth)
- Basic rule matching and routing to targets (workflow, task, promise)

## Goals

1. **Receive webhooks** - Accept HTTP requests from external providers (GitHub, Stripe, etc.)
2. **Verify signatures** - Validate webhook authenticity using HMAC, API key, or basic auth
3. **Route to targets** - Trigger workflows, create tasks, or resolve/reject promises based on rules
4. **Store events** - Persist webhook events for debugging and audit

## Non-Goals

- Management API for sources/routes (Milestone 2)
- Event replay functionality (Milestone 2)
- Advanced pattern matching on event data (Milestone 3)
- JavaScript transformations (Milestone 3)
- Outbound webhook delivery (Milestone 4)
- Event persistence with JetStream (Milestone 5)

## Prerequisites

- M0 complete: `FlovynEvent`, `EventPublisher`, `EventSubscriber` infrastructure

## Architecture

### Plugin Structure

```
plugins/
└── eventhook/
    ├── Cargo.toml
    ├── migrations/
    │   └── 20250101000001_init.sql
    └── src/
        ├── lib.rs              # Plugin trait implementation
        ├── api/
        │   ├── mod.rs
        │   └── ingest.rs       # Webhook reception endpoint
        ├── domain/
        │   ├── mod.rs
        │   ├── source.rs       # WebhookSource entity
        │   ├── route.rs        # WebhookRoute entity
        │   └── event.rs        # WebhookEvent entity
        ├── repository/
        │   ├── mod.rs
        │   ├── source_repository.rs
        │   ├── route_repository.rs
        │   └── event_repository.rs
        ├── service/
        │   ├── mod.rs
        │   ├── ingest_service.rs    # Webhook reception logic
        │   ├── processor.rs         # Event processing logic
        │   └── verifier.rs          # Signature verification
        └── target/
            ├── mod.rs
            ├── workflow.rs     # WorkflowTarget
            ├── task.rs         # TaskTarget
            └── promise.rs      # PromiseTarget
```

### Component Diagram

```
                     External Provider
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│  POST /api/tenants/{slug}/eventhook/in/{source_slug}         │
│                      Ingest Endpoint                          │
└───────────────────────────┬──────────────────────────────────┘
                            │
                            ▼
                   ┌────────────────┐
                   │   Verifier     │  ◀── HMAC / API Key / Basic Auth
                   └───────┬────────┘
                           │
                           ▼
                   ┌────────────────┐
                   │ Store Event    │  ◀── p_eventhook__event
                   │ (durability)   │
                   └───────┬────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │    Event Processor     │
              │  (match routes, exec)  │
              └────────────┬───────────┘
                           │
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
    ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
    │  Workflow   │ │    Task     │ │   Promise   │
    │   Target    │ │   Target    │ │   Target    │
    └─────────────┘ └─────────────┘ └─────────────┘
           │               │               │
           ▼               ▼               ▼
    workflow_execution  task_execution   promise
```

## Database Schema

All tables use plugin naming convention: `p_eventhook__<table>`.

### WebhookSource

Represents an external webhook provider endpoint.

```sql
CREATE TABLE p_eventhook__source (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,

    -- Identification
    name VARCHAR(255) NOT NULL,
    slug VARCHAR(255) NOT NULL,  -- Used in URL path

    -- Status
    is_enabled BOOLEAN NOT NULL DEFAULT true,

    -- Verification
    verifier_type VARCHAR(50),  -- 'hmac', 'basic_auth', 'api_key', 'none'
    verifier_config JSONB,      -- Type-specific config

    -- Deduplication
    idempotency_key_paths TEXT[],  -- e.g., ['header.x-request-id', 'body.id']

    -- Metadata
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE(tenant_id, slug)
);

CREATE INDEX idx_p_eventhook__source_lookup
    ON p_eventhook__source(tenant_id, slug)
    WHERE is_enabled = true;
```

### WebhookRoute

Defines routing rules from source to targets.

```sql
CREATE TABLE p_eventhook__route (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id UUID NOT NULL REFERENCES p_eventhook__source(id) ON DELETE CASCADE,
    tenant_id UUID NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,

    -- Identification
    name VARCHAR(255) NOT NULL,
    priority INT NOT NULL DEFAULT 0,  -- Higher = evaluated first
    is_enabled BOOLEAN NOT NULL DEFAULT true,

    -- Target type
    target_type VARCHAR(50) NOT NULL,  -- 'workflow', 'task', 'promise'
    target_config JSONB NOT NULL,

    -- Basic filtering (event types only in M1)
    filter_event_types TEXT[],  -- Match specific event types

    -- Metadata
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_p_eventhook__route_source
    ON p_eventhook__route(source_id, priority DESC)
    WHERE is_enabled = true;
```

### WebhookEvent

Stores received webhook events.

```sql
CREATE TABLE p_eventhook__event (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    source_id UUID NOT NULL REFERENCES p_eventhook__source(id) ON DELETE CASCADE,

    -- Request details
    content_type VARCHAR(255),           -- Original Content-Type header
    raw_payload BYTEA NOT NULL,          -- Original payload bytes (any format)
    parsed_payload JSONB,                -- NULL if non-JSON or parse failed
    headers JSONB NOT NULL,

    -- Event identification
    event_type VARCHAR(255),             -- Extracted from payload or header

    -- Deduplication
    idempotency_key VARCHAR(512),        -- Extracted key for duplicate detection
    is_duplicate BOOLEAN NOT NULL DEFAULT false,

    -- Processing status
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    -- 'pending'    - Stored, waiting to be processed
    -- 'processing' - Being processed by background worker
    -- 'delivered'  - Successfully delivered to target(s)
    -- 'unrouted'   - No matching routes found
    -- 'failed'     - Processing failed (parse error, target error, etc.)
    -- 'rejected'   - Verification failed (shouldn't happen with verify-before-store)
    -- 'duplicate'  - Duplicate event, skipped

    -- Retry tracking
    retry_count INT NOT NULL DEFAULT 0,
    max_retries INT NOT NULL DEFAULT 3,
    next_retry_at TIMESTAMPTZ,            -- NULL = no retry scheduled
    last_error TEXT,                       -- Last error message for debugging

    -- Verification
    verified BOOLEAN,
    verification_error TEXT,

    -- Metadata
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ,
    source_ip INET
);

CREATE INDEX idx_p_eventhook__event_tenant_time
    ON p_eventhook__event(tenant_id, received_at DESC);
CREATE INDEX idx_p_eventhook__event_source_time
    ON p_eventhook__event(source_id, received_at DESC);
CREATE INDEX idx_p_eventhook__event_status
    ON p_eventhook__event(tenant_id, status, received_at DESC)
    WHERE status IN ('pending', 'failed', 'unrouted');

-- Index for retry polling (batch fetch)
CREATE INDEX idx_p_eventhook__event_retry
    ON p_eventhook__event(next_retry_at)
    WHERE next_retry_at IS NOT NULL AND status = 'failed';

-- Unique constraint for deduplication (only non-duplicate events)
CREATE UNIQUE INDEX idx_p_eventhook__event_idempotency
    ON p_eventhook__event(source_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL AND is_duplicate = false;
```

### WebhookEventAction

Tracks actions taken for each event.

```sql
CREATE TABLE p_eventhook__event_action (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id UUID NOT NULL REFERENCES p_eventhook__event(id) ON DELETE CASCADE,
    route_id UUID NOT NULL REFERENCES p_eventhook__route(id) ON DELETE CASCADE,

    -- Target details
    target_type VARCHAR(50) NOT NULL,

    -- Result
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    -- 'pending', 'success', 'failed', 'skipped'

    -- Links to created resources
    workflow_execution_id UUID REFERENCES workflow_execution(id),
    task_execution_id UUID REFERENCES task_execution(id),
    promise_id UUID REFERENCES promise(id),

    -- Error tracking
    error_message TEXT,

    -- Timing
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ
);

CREATE INDEX idx_p_eventhook__event_action_event
    ON p_eventhook__event_action(event_id);
```

## Ingest Endpoint

### Route

```
POST /api/tenants/{tenant_slug}/eventhook/in/{source_slug}
```

Mounted without standard auth middleware (plugin handles its own auth via signature verification).

### Handler Flow

**Design principles:**
1. Verify signature BEFORE storing (DDoS protection)
2. Store event and return 200 immediately
3. Processing happens OUTSIDE the HTTP request cycle

```rust
pub async fn receive_webhook(
    State(state): State<EventhookState>,
    Path((tenant_slug, source_slug)): Path<(String, String)>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<StatusCode, EventhookError> {
    // 1. Look up tenant
    let tenant = state.tenant_repo.find_by_slug(&tenant_slug).await?
        .ok_or(EventhookError::TenantNotFound)?;

    // 2. Look up webhook source
    let source = state.source_repo.find_by_slug(tenant.id, &source_slug).await?
        .ok_or(EventhookError::SourceNotFound)?;

    if !source.is_enabled {
        return Err(EventhookError::SourceDisabled);
    }

    // 3. Rate limit check (DDoS protection)
    if !state.rate_limiter.check(&source.id).await {
        return Err(EventhookError::RateLimitExceeded);
    }

    // 4. Verify signature BEFORE storing (DDoS protection)
    if let Some(ref verifier_config) = source.verifier_config {
        if let Err(e) = verify_signature(verifier_config, &headers, &body) {
            tracing::warn!(
                tenant = %tenant_slug,
                source = %source_slug,
                error = %e,
                "Webhook signature verification failed"
            );
            return Err(EventhookError::VerificationFailed);
        }
    }

    // 5. Check for duplicate using header-based idempotency key
    let idempotency_key = extract_idempotency_key(
        source.idempotency_key_paths.as_deref(),
        &headers,
        None, // Body-based keys checked during async processing
    );

    if let Some(ref key) = idempotency_key {
        if state.event_repo.exists_by_idempotency_key(source.id, key).await? {
            return Ok(StatusCode::OK); // Already received
        }
    }

    // 6. Store event (durability)
    let _event_id = state.event_repo.create(&NewEvent {
        tenant_id: tenant.id,
        source_id: source.id,
        raw_payload: body.to_vec(),
        headers: headers_to_json(&headers),
        idempotency_key,
        status: EventStatus::Pending,
    }).await?;

    // 7. Return immediately - processing happens async
    Ok(StatusCode::OK)
}
```

### Async Event Processing

Events are processed outside the HTTP cycle via a background processor:

```rust
/// Background task that processes pending webhook events
pub struct EventProcessor {
    event_repo: Arc<EventRepository>,
    route_repo: Arc<RouteRepository>,
    workflow_launcher: Arc<WorkflowLauncher>,
    task_launcher: Arc<TaskLauncher>,
    promise_resolver: Arc<PromiseResolver>,
}

impl EventProcessor {
    /// Start the background processor
    pub async fn run(&self, mut shutdown: broadcast::Receiver<()>) {
        let mut interval = tokio::time::interval(Duration::from_millis(100));

        loop {
            tokio::select! {
                _ = interval.tick() => {
                    self.process_pending_events().await;
                }
                _ = shutdown.recv() => {
                    tracing::info!("Event processor shutting down");
                    break;
                }
            }
        }
    }

    async fn process_pending_events(&self) {
        // Fetch batch of pending events
        let events = match self.event_repo.find_pending(100).await {
            Ok(events) => events,
            Err(e) => {
                tracing::error!(error = %e, "Failed to fetch pending events");
                return;
            }
        };

        for event in events {
            // Mark as processing (prevents duplicate processing)
            if let Err(_) = self.event_repo.try_claim_for_processing(event.id).await {
                continue; // Another processor claimed it
            }

            if let Err(e) = self.process_single_event(&event).await {
                tracing::error!(event_id = %event.id, error = %e, "Event processing failed");
                self.event_repo.update_status(event.id, EventStatus::Failed, Some(e.to_string())).await.ok();
            }
        }
    }

    async fn process_single_event(&self, event: &WebhookEvent) -> Result<(), ProcessError> {
        // 1. Parse payload
        let parsed = parse_payload(&event.raw_payload, &event.headers)?;
        self.event_repo.update_parsed(event.id, &parsed).await?;

        // 2. Extract body-based idempotency key if needed
        if event.idempotency_key.is_none() {
            let source = self.source_repo.find_by_id(event.source_id).await?;
            if let Some(key) = extract_idempotency_key(
                source.idempotency_key_paths.as_deref(),
                &event.headers,
                parsed.parsed.as_ref(),
            ) {
                // Check for duplicate
                if self.event_repo.exists_by_idempotency_key(event.source_id, &key).await? {
                    self.event_repo.mark_duplicate(event.id).await?;
                    return Ok(());
                }
                self.event_repo.set_idempotency_key(event.id, &key).await?;
            }
        }

        // 3. Match routes and execute targets
        let routes = self.route_repo.find_matching(event.source_id, &parsed).await?;
        for route in routes {
            self.execute_target(&route, event, &parsed).await?;
        }

        self.event_repo.update_status(event.id, EventStatus::Delivered, None).await?;
        Ok(())
    }
}
```

### Processing Options

| Option | M1 | Pros | Cons |
|--------|-----|------|------|
| **Polling loop** | ✅ | Simple, no extra infra | Latency (polling interval) |
| **NATS queue** | Future | Low latency, scalable | Requires NATS |
| **pg_notify** | Future | Low latency, no extra infra | PostgreSQL specific |

For M1, use simple polling loop. Can optimize with NATS/pg_notify in future milestones.

### Retry Mechanism

Events can fail for transient reasons (DB timeout, target service unavailable) or configuration reasons (no matching routes). M1 includes automatic retry with exponential backoff.

#### Automatic Retry (Failed Events)

```rust
impl EventProcessor {
    /// Process retryable events in batches
    async fn process_retries(&self) {
        // Fetch batch of events due for retry
        let events = self.event_repo
            .find_due_for_retry(100)  // Batch size
            .await
            .unwrap_or_default();

        for event in events {
            // Claim for processing (prevents duplicate processing)
            if self.event_repo.try_claim_for_processing(event.id).await.is_err() {
                continue;
            }

            match self.process_single_event(&event).await {
                Ok(_) => {
                    self.event_repo.update_status(event.id, EventStatus::Delivered, None).await.ok();
                }
                Err(e) => {
                    self.schedule_retry_or_fail(&event, &e).await;
                }
            }
        }
    }

    async fn schedule_retry_or_fail(&self, event: &WebhookEvent, error: &ProcessError) {
        let new_retry_count = event.retry_count + 1;

        if new_retry_count >= event.max_retries {
            // Max retries exceeded - mark as permanently failed
            self.event_repo.update_status(
                event.id,
                EventStatus::Failed,
                Some(format!("Max retries exceeded. Last error: {}", error))
            ).await.ok();
        } else {
            // Schedule next retry with exponential backoff
            let delay = self.calculate_backoff(new_retry_count);
            let next_retry = Utc::now() + delay;

            self.event_repo.schedule_retry(
                event.id,
                new_retry_count,
                next_retry,
                &error.to_string()
            ).await.ok();
        }
    }

    fn calculate_backoff(&self, retry_count: i32) -> Duration {
        // Exponential backoff: 10s, 30s, 90s, 270s (4.5min), ...
        let base_seconds = 10;
        let multiplier = 3_i64.pow(retry_count as u32);
        let max_seconds = 3600; // Cap at 1 hour

        Duration::seconds(std::cmp::min(base_seconds * multiplier, max_seconds))
    }
}
```

#### Repository Methods

```rust
impl EventRepository {
    /// Find events due for retry (batch)
    pub async fn find_due_for_retry(&self, limit: i64) -> Result<Vec<WebhookEvent>, Error> {
        sqlx::query_as!(
            WebhookEvent,
            r#"
            SELECT * FROM p_eventhook__event
            WHERE status = 'failed'
              AND next_retry_at IS NOT NULL
              AND next_retry_at <= NOW()
            ORDER BY next_retry_at ASC
            LIMIT $1
            "#,
            limit
        )
        .fetch_all(&self.pool)
        .await
    }

    /// Schedule a retry
    pub async fn schedule_retry(
        &self,
        id: Uuid,
        retry_count: i32,
        next_retry_at: DateTime<Utc>,
        last_error: &str,
    ) -> Result<(), Error> {
        sqlx::query!(
            r#"
            UPDATE p_eventhook__event
            SET retry_count = $2,
                next_retry_at = $3,
                last_error = $4,
                status = 'failed'
            WHERE id = $1
            "#,
            id,
            retry_count,
            next_retry_at,
            last_error
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}
```

#### Manual Re-process (Unrouted/Failed Events)

For events that failed due to configuration issues (wrong routes, missing routes), operators can manually trigger re-processing via admin API (M2):

```
POST /api/tenants/{slug}/eventhook/events/reprocess
```

Request body supports two modes - specific event IDs or filter-based selection:

```json
{
  "event_ids": ["uuid1", "uuid2"],           // Mode A: specific events
  "filter": {                                 // Mode B: query filter
    "status": ["unrouted", "failed"],
    "source_id": "uuid",
    "received_after": "2025-01-01T00:00:00Z",
    "received_before": "2025-01-02T00:00:00Z"
  },
  "limit": 100                                // Safety cap (required for filter mode)
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `event_ids` | No | Specific event UUIDs to reprocess |
| `filter` | No | Query filter for batch selection |
| `filter.status` | No | Event statuses to include (default: `["failed", "unrouted"]`) |
| `filter.source_id` | No | Filter by webhook source |
| `filter.received_after` | No | Events received after this time |
| `filter.received_before` | No | Events received before this time |
| `limit` | Yes* | Max events to reprocess (*required when using filter) |

**Validation:**
- At least one of `event_ids` or `filter` must be provided
- If both provided, `event_ids` takes precedence
- `limit` is required when using `filter` (prevents accidental mass reprocess)

Response:
```json
{
  "reprocessed_count": 42,
  "event_ids": ["uuid1", "uuid2", "..."]
}
```

**Implementation:**

```rust
#[derive(Deserialize)]
pub struct ReprocessRequest {
    pub event_ids: Option<Vec<Uuid>>,
    pub filter: Option<ReprocessFilter>,
    pub limit: Option<i64>,
}

#[derive(Deserialize)]
pub struct ReprocessFilter {
    pub status: Option<Vec<String>>,
    pub source_id: Option<Uuid>,
    pub received_after: Option<DateTime<Utc>>,
    pub received_before: Option<DateTime<Utc>>,
}

pub async fn reprocess_events(
    &self,
    tenant_id: Uuid,
    req: ReprocessRequest,
) -> Result<ReprocessResult, Error> {
    let event_ids = if let Some(ids) = req.event_ids {
        // Mode A: specific events
        ids
    } else if let Some(filter) = req.filter {
        // Mode B: filter-based selection
        let limit = req.limit.ok_or(Error::LimitRequired)?;
        self.find_events_by_filter(tenant_id, &filter, limit).await?
    } else {
        return Err(Error::InvalidRequest("event_ids or filter required"));
    };

    // Reset events to pending
    let count = sqlx::query!(
        r#"
        UPDATE p_eventhook__event
        SET status = 'pending',
            retry_count = 0,
            next_retry_at = NULL,
            last_error = NULL,
            processed_at = NULL
        WHERE id = ANY($1)
          AND tenant_id = $2
          AND status IN ('failed', 'unrouted')
        "#,
        &event_ids,
        tenant_id
    )
    .execute(&self.pool)
    .await?
    .rows_affected();

    Ok(ReprocessResult {
        reprocessed_count: count as i64,
        event_ids,
    })
}
```

#### Retry Summary

| Scenario | Trigger | Behavior |
|----------|---------|----------|
| **Transient failure** | Automatic | Exponential backoff (10s, 30s, 90s...), max 3 retries |
| **Max retries exceeded** | Automatic | Mark as `failed`, requires manual intervention |
| **No matching routes** | Manual | Operator fixes routes, calls reprocess API |
| **Parse error** | Manual | Usually unfixable, investigate payload |

### Error Handling Strategy

| Step | Failure | Event Stored? | HTTP Response | Resolution |
|------|---------|---------------|---------------|------------|
| 1-2 | Tenant/Source not found | No | 404 | Provider may retry |
| 3 | Rate limit exceeded | No | 429 | Provider backs off |
| 4 | Verification fails | **No** | 401 | Attacker blocked |
| 5 | Duplicate detected | No (existing) | 200 | Idempotent |
| 6 | Store fails | No | 500 | Provider retries |
| 7 | Parse fails | Yes | 200 | Manual investigation |
| 8-9 | Processing fails | Yes | 200 | Retry via admin API |
| - | Success | Yes | 200 | Done |

**Key insight:** Verification happens BEFORE storing. This protects against:
- DDoS attacks filling database with garbage
- Invalid signatures never touch storage
- Only legitimate requests consume resources

**After storage:** Always return 200. Failed events can be replayed via admin API (M2).

### Response Codes

| Code | Condition |
|------|-----------|
| 200 | Event received (includes parse/processing failures - check event status) |
| 401 | Signature verification failed (event NOT stored) |
| 404 | Tenant or source not found, or source disabled |
| 429 | Rate limit exceeded |
| 500 | Failed to store event (database error) |

**Note:** Verification failures return 401 and do NOT store the event (DDoS protection). Parse/processing failures return 200 with event stored.

### DDoS Protection

Multiple layers of protection to prevent abuse:

#### 1. Rate Limiting (M1)

```rust
// Per-source rate limiting
pub struct RateLimitConfig {
    /// Max requests per second per source
    pub requests_per_second: u32,  // Default: 100
    /// Max requests per minute per source
    pub requests_per_minute: u32,  // Default: 1000
    /// Burst allowance
    pub burst_size: u32,           // Default: 50
}
```

Rate limits checked BEFORE any database operations:

```rust
// In receive_webhook, before storing
if !state.rate_limiter.check(&source.id).await {
    return Err(EventhookError::RateLimitExceeded);
}
```

#### 2. Verify Before Store

**Critical change:** For sources WITH verification configured, verify signature BEFORE storing:

```rust
// Updated flow:
// 1. Lookup tenant/source
// 2. Rate limit check
// 3. Verify signature (if configured) - REJECT if invalid, don't store
// 4. Store event
// 5. Parse and process
```

This prevents attackers from filling the database with invalid events.

| Source Config | Invalid Signature | Result |
|---------------|-------------------|--------|
| Verification enabled | Fails | 401, NOT stored |
| Verification disabled | N/A | Stored (user accepts risk) |

#### 3. Request Size Limits

```rust
// Axum layer configuration
.layer(RequestBodyLimitLayer::new(1024 * 1024)) // 1MB max payload
```

#### 4. IP Allowlisting (Optional, Future)

For enterprise sources, optionally restrict to known IP ranges:

```sql
-- Add to p_eventhook__source
allowed_ip_ranges INET[],  -- e.g., GitHub webhook IPs
```

#### 5. Tenant Quotas (Future - M2)

```sql
-- Per-tenant limits
max_events_per_day INT,
max_storage_bytes BIGINT,
```

## Signature Verification

### Verifier Types

```rust
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum VerifierConfig {
    Hmac(HmacConfig),
    BasicAuth(BasicAuthConfig),
    ApiKey(ApiKeyConfig),
    None,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HmacConfig {
    /// Header containing the signature (e.g., "X-Hub-Signature-256")
    pub header: String,
    /// Secret key for HMAC computation (stored encrypted)
    pub secret: SecretString,
    /// Hash algorithm: sha256, sha512, sha1
    pub algorithm: HmacAlgorithm,
    /// Signature encoding: hex, base64
    pub encoding: SignatureEncoding,
    /// Optional prefix to strip (e.g., "sha256=" for GitHub)
    pub prefix: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BasicAuthConfig {
    pub username: String,
    pub password: SecretString,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ApiKeyConfig {
    /// Header containing the API key
    pub header: String,
    /// Expected API key value
    pub value: SecretString,
}
```

### HMAC Verification Implementation

```rust
impl HmacConfig {
    pub fn verify(&self, headers: &HeaderMap, body: &[u8]) -> Result<(), VerifyError> {
        // 1. Get signature from header
        let header_value = headers.get(&self.header)
            .ok_or(VerifyError::MissingHeader)?
            .to_str()
            .map_err(|_| VerifyError::InvalidHeader)?;

        // 2. Strip prefix if configured
        let signature = match &self.prefix {
            Some(prefix) => header_value.strip_prefix(prefix)
                .ok_or(VerifyError::InvalidPrefix)?,
            None => header_value,
        };

        // 3. Decode signature
        let expected = match self.encoding {
            SignatureEncoding::Hex => hex::decode(signature)?,
            SignatureEncoding::Base64 => base64::decode(signature)?,
        };

        // 4. Compute HMAC
        let computed = match self.algorithm {
            HmacAlgorithm::Sha256 => compute_hmac::<Sha256>(&self.secret, body),
            HmacAlgorithm::Sha512 => compute_hmac::<Sha512>(&self.secret, body),
            HmacAlgorithm::Sha1 => compute_hmac::<Sha1>(&self.secret, body),
        };

        // 5. Constant-time comparison
        if !constant_time_eq(&computed, &expected) {
            return Err(VerifyError::InvalidSignature);
        }

        Ok(())
    }
}
```

## Deduplication

Webhook providers often retry deliveries, which can cause duplicate processing. M1 includes built-in deduplication using configurable idempotency keys.

### Configuration

Sources define `idempotency_key_paths` - an ordered list of paths to try:

```json
{
  "name": "GitHub",
  "slug": "github",
  "idempotency_key_paths": ["header.x-github-delivery"]
}
```

```json
{
  "name": "Stripe",
  "slug": "stripe",
  "idempotency_key_paths": ["body.id"]
}
```

```json
{
  "name": "Generic",
  "slug": "generic",
  "idempotency_key_paths": ["header.x-request-id", "body.id", "body.event_id"]
}
```

### Path Syntax

Format: `{source}.{path}` where source is `header` or `body`:

| Path | Extracts From |
|------|---------------|
| `header.x-github-delivery` | `headers["x-github-delivery"]` |
| `header.x-request-id` | `headers["x-request-id"]` |
| `body.id` | `payload["id"]` |
| `body.data.object.id` | `payload["data"]["object"]["id"]` |

### Implementation

```rust
fn extract_idempotency_key(
    paths: &[String],
    headers: &HeaderMap,
    payload: Option<&serde_json::Value>,
) -> Option<String> {
    for path in paths {
        if let Some(value) = extract_by_path(path, headers, payload) {
            return Some(value);
        }
    }
    None
}

fn extract_by_path(
    path: &str,
    headers: &HeaderMap,
    payload: Option<&serde_json::Value>,
) -> Option<String> {
    let (source, field_path) = path.split_once('.')?;

    match source {
        "header" => {
            headers.get(field_path)
                .and_then(|v| v.to_str().ok())
                .map(|s| s.to_string())
        }
        "body" => {
            let payload = payload?;
            // Convert dot path to JSON pointer: "data.object.id" → "/data/object/id"
            let pointer = format!("/{}", field_path.replace('.', "/"));
            payload.pointer(&pointer)
                .and_then(|v| match v {
                    serde_json::Value::String(s) => Some(s.clone()),
                    serde_json::Value::Number(n) => Some(n.to_string()),
                    _ => None,
                })
        }
        _ => None,
    }
}
```

### Processing Flow

```rust
// After storing raw event, before processing
if let Some(ref paths) = source.idempotency_key_paths {
    if let Some(key) = extract_idempotency_key(paths, &headers, parsed.as_ref()) {
        // Try to set the key - unique index will reject if duplicate
        match event_repo.set_idempotency_key(event_id, &key).await {
            Ok(_) => {
                // First time seeing this key, continue processing
            }
            Err(e) if is_unique_violation(&e) => {
                // Duplicate detected
                event_repo.mark_duplicate(event_id).await?;
                return Ok(StatusCode::OK);  // Return success, skip processing
            }
            Err(e) => return Err(e.into()),
        }
    }
}
```

### Behavior

| Scenario | Result |
|----------|--------|
| No `idempotency_key_paths` configured | No deduplication, all events processed |
| Key extracted, first occurrence | Event processed normally |
| Key extracted, duplicate detected | Event stored with `is_duplicate=true`, returns 200, skips processing |
| Key extraction fails (path not found) | Event processed normally (no deduplication possible) |

**Note:** Duplicates are still stored for audit purposes, but marked as `is_duplicate=true` and not processed.

### Two-Layer Deduplication

Eventhook supports deduplication at two levels:

| Layer | Configured On | Storage | Purpose |
|-------|---------------|---------|---------|
| **Event-level** | Source (`idempotency_key_paths`) | `p_eventhook__event` table | Prevents processing the same webhook twice |
| **Target-level** | Route (`target_config.idempotency_key_path`) | Core `idempotency_key` table | Prevents creating duplicate workflows/tasks |

**Target-level uses existing infrastructure:** The `IdempotencyKeyRepository` with claim-then-register pattern (same as gRPC `StartWorkflow`). See `flovyn-server/server/src/repository/idempotency_key_repository.rs`.

**Example: Belt and suspenders approach**

```json
{
  "source": {
    "slug": "stripe",
    "idempotency_key_paths": ["body.id"]
  },
  "route": {
    "target_type": "workflow",
    "target_config": {
      "workflow_kind": "process-payment",
      "idempotency_key_path": "body.data.object.id"
    }
  }
}
```

- Event-level: Deduplicates on Stripe event ID (`evt_xxx`) → stored in `p_eventhook__event`
- Target-level: Deduplicates on PaymentIntent ID (`pi_xxx`) → stored in core `idempotency_key` table

This provides defense in depth - even if event deduplication is not configured or fails, the workflow won't be created twice for the same payment.

## Event Processing

### Route Matching

```rust
impl EventProcessor {
    pub async fn process(
        &self,
        event_id: Uuid,
        source: &WebhookSource,
        payload: &serde_json::Value,
    ) -> Result<(), ProcessError> {
        // Update event status
        self.event_repo.update_status(event_id, EventStatus::Processing).await?;

        // Load enabled routes for source, ordered by priority DESC
        let routes = self.route_repo.find_by_source(source.id).await?;

        let mut any_success = false;
        let mut all_failed = true;

        for route in routes {
            // Check if route matches this event
            if !self.matches_route(&route, payload) {
                continue;
            }

            // Create action record
            let action_id = self.action_repo.create(&NewEventAction {
                event_id,
                route_id: route.id,
                target_type: route.target_type.clone(),
                status: ActionStatus::Pending,
            }).await?;

            // Execute target
            let result = self.execute_target(&route, payload).await;

            // Update action record
            match result {
                Ok(target_result) => {
                    self.action_repo.update_success(action_id, &target_result).await?;
                    any_success = true;
                    all_failed = false;
                }
                Err(e) => {
                    self.action_repo.update_failed(action_id, &e.to_string()).await?;
                }
            }
        }

        // Update event status
        let final_status = if any_success {
            EventStatus::Delivered
        } else if all_failed && routes.len() > 0 {
            EventStatus::Failed
        } else {
            EventStatus::Unrouted // No matching routes - queryable for debugging
        };

        self.event_repo.update_status(event_id, final_status).await?;

        Ok(())
    }

    fn matches_route(&self, route: &WebhookRoute, payload: &serde_json::Value) -> bool {
        // M1: Only event type filtering
        if let Some(ref types) = route.filter_event_types {
            let event_type = self.extract_event_type(payload);
            if !types.iter().any(|t| event_type.as_ref().map(|e| e == t).unwrap_or(false)) {
                return false;
            }
        }
        true
    }
}
```

### Payload Parsing

Webhooks can arrive in different formats. M1 handles them as follows:

| Content-Type | Handling | `parsed_payload` | Route Matching |
|--------------|----------|------------------|----------------|
| `application/json` | Parse as JSON | JSON value | Full support |
| `application/x-www-form-urlencoded` | Parse form fields to JSON | `{"field": "value", ...}` | Full support |
| `text/xml`, `application/xml` | Store raw only | NULL | Header-based only |
| `multipart/form-data` | Extract fields to JSON | `{"field": "value", ...}` | Full support |
| Other | Store raw only | NULL | Header-based only |

```rust
fn parse_payload(body: &[u8], headers: &HeaderMap) -> Result<ParsedPayload, ParseError> {
    let content_type = headers.get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/octet-stream");

    let parsed = if content_type.contains("application/json") {
        Some(serde_json::from_slice(body)?)
    } else if content_type.contains("application/x-www-form-urlencoded") {
        Some(form_to_json(body)?)
    } else if content_type.contains("multipart/form-data") {
        Some(multipart_to_json(body, content_type)?)
    } else {
        // XML, binary, etc. - store raw only
        None
    };

    Ok(ParsedPayload {
        content_type: content_type.to_string(),
        parsed,
    })
}
```

**Note:** XML-to-JSON conversion is deferred to M3. For XML webhooks in M1, use header-based event type extraction.

### Event Type Extraction

Event type is extracted from headers first, then from payload (if JSON):

```rust
fn extract_event_type(headers: &HeaderMap, payload: Option<&serde_json::Value>) -> Option<String> {
    // 1. Try headers first (works for all content types)
    let header_names = [
        "x-event-type",
        "x-github-event",      // GitHub
        "x-stripe-event",      // Stripe (not standard but some use it)
        "x-webhook-event",
    ];

    for name in header_names {
        if let Some(value) = headers.get(name).and_then(|v| v.to_str().ok()) {
            return Some(value.to_string());
        }
    }

    // 2. Try payload paths (JSON only)
    if let Some(payload) = payload {
        let paths = [
            "/type",              // Stripe, many others
            "/event",             // Some providers
            "/action",            // GitHub
            "/event_type",        // Some providers
        ];

        for path in paths {
            if let Some(value) = payload.pointer(path) {
                if let Some(s) = value.as_str() {
                    return Some(s.to_string());
                }
            }
        }
    }

    None
}
```

## Tracking Event Delivery

### Event vs Target Status

**Important distinction:**
- **Event status (`Delivered`)**: Indicates the event was successfully delivered to targets (workflows started, tasks created, promises resolved)
- **Target status**: Indicates whether the target has completed processing

An event with status `Delivered` does NOT mean the triggered workflow has completed - only that Eventhook successfully handed off the work.

### Checking Delivery Details

The `p_eventhook__event_action` table links events to their targets:

```sql
SELECT
    e.id as event_id,
    e.status as event_status,
    e.received_at,
    ea.target_type,
    ea.status as action_status,
    ea.workflow_execution_id,
    ea.task_execution_id,
    ea.promise_id,
    ea.error_message
FROM p_eventhook__event e
JOIN p_eventhook__event_action ea ON ea.event_id = e.id
WHERE e.source_id = $1
ORDER BY e.received_at DESC;
```

### Checking Target Processing Status

To check if the triggered target has completed, join with the core tables:

**For workflow targets:**
```sql
SELECT
    e.id as event_id,
    ea.workflow_execution_id,
    w.status as workflow_status,
    w.completed_at
FROM p_eventhook__event e
JOIN p_eventhook__event_action ea ON ea.event_id = e.id
LEFT JOIN workflow_execution w ON w.id = ea.workflow_execution_id
WHERE e.source_id = $1
  AND ea.target_type = 'workflow';
```

**For task targets:**
```sql
SELECT
    e.id as event_id,
    ea.task_execution_id,
    t.status as task_status,
    t.completed_at
FROM p_eventhook__event e
JOIN p_eventhook__event_action ea ON ea.event_id = e.id
LEFT JOIN task_execution t ON t.id = ea.task_execution_id
WHERE e.source_id = $1
  AND ea.target_type = 'task';
```

**For promise targets:**
```sql
SELECT
    e.id as event_id,
    ea.promise_id,
    p.status as promise_status,
    p.resolved_at
FROM p_eventhook__event e
JOIN p_eventhook__event_action ea ON ea.event_id = e.id
LEFT JOIN promise p ON p.id = ea.promise_id
WHERE e.source_id = $1
  AND ea.target_type = 'promise';
```

### Event Action Status Values

| Status | Meaning |
|--------|---------|
| `pending` | Action queued, not yet executed |
| `success` | Target successfully created/resolved |
| `failed` | Target execution failed (see `error_message`) |
| `skipped` | Action skipped (e.g., idempotent duplicate) |

### Event Status Values

| Status | Meaning |
|--------|---------|
| `pending` | Stored, waiting to be processed |
| `processing` | Being processed by background worker |
| `delivered` | Successfully delivered to target(s) |
| `unrouted` | No matching routes found (check route config) |
| `failed` | Processing failed (parse error, target error) |
| `duplicate` | Duplicate event, skipped |

### Summary

| What you want to know | Where to look |
|----------------------|---------------|
| Was webhook received? | `p_eventhook__event.status` |
| Were targets triggered? | `p_eventhook__event_action.status` |
| Why wasn't it routed? | `p_eventhook__event.status = 'unrouted'` + check route filters |
| Which workflow was started? | `p_eventhook__event_action.workflow_execution_id` |
| Did the workflow complete? | `workflow_execution.status` |

## Targets

### Target Configuration

```rust
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TargetConfig {
    Workflow(WorkflowTargetConfig),
    Task(TaskTargetConfig),
    Promise(PromiseTargetConfig),
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkflowTargetConfig {
    /// Workflow definition kind to trigger
    pub workflow_kind: String,
    /// Queue name (optional)
    pub queue: Option<String>,
    /// Path to extract idempotency key for workflow creation (optional)
    /// Uses same syntax as event idempotency: "header.x-id" or "body.data.id"
    pub idempotency_key_path: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TaskTargetConfig {
    /// Task definition kind to create
    pub task_kind: String,
    /// Queue name (optional)
    pub queue: Option<String>,
    /// Path to extract idempotency key for task creation (optional)
    pub idempotency_key_path: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PromiseTargetConfig {
    /// Path to extract idempotency key from payload (e.g., "body.data.object.id")
    pub idempotency_key_path: String,
    /// Optional prefix to prepend to extracted key (e.g., "stripe:")
    /// Final key = prefix + extracted_value (e.g., "stripe:pi_abc123")
    pub idempotency_key_prefix: Option<String>,
    /// Whether to resolve (true) or reject (false)
    pub resolve: bool,
    /// Path to extract value for resolution (optional, defaults to entire payload)
    pub value_path: Option<String>,
    /// Path to extract error message for rejection (optional)
    pub error_path: Option<String>,
}
```

### Prerequisite: Extract Execution Services

Currently, workflow/task launching logic (idempotency handling, creation, notification) lives in the gRPC handlers (`workflow_dispatch.rs`, `task_execution.rs`). To avoid duplication, **extract shared services** that both gRPC and Eventhook can use:

```
server/src/service/
├── mod.rs
├── workflow_launcher.rs   # WorkflowLauncher service
└── task_launcher.rs       # TaskLauncher service
```

```rust
// server/src/service/workflow_launcher.rs

pub struct StartWorkflowRequest {
    pub tenant_id: Uuid,
    pub workflow_kind: String,
    pub input: Option<Vec<u8>>,
    pub queue: Option<String>,
    pub priority_ms: Option<i64>,
    pub idempotency_key: Option<String>,
    pub idempotency_key_ttl_seconds: Option<i64>,
}

pub enum StartWorkflowResult {
    Created(WorkflowExecution),
    Existing(WorkflowExecution),  // Idempotent return
}

pub struct WorkflowLauncher {
    workflow_repo: Arc<WorkflowRepository>,
    idempotency_repo: Arc<IdempotencyKeyRepository>,
    notifier: WorkerNotifier,
    event_publisher: Arc<dyn EventPublisher>,
}

impl WorkflowLauncher {
    /// Start a workflow with full idempotency handling and worker notification.
    /// Used by both gRPC StartWorkflow and Eventhook WorkflowTarget.
    pub async fn start(&self, req: StartWorkflowRequest) -> Result<StartWorkflowResult, LaunchError> {
        let queue = req.queue.unwrap_or_else(|| "default".to_string());
        let expires_at = Utc::now() + Duration::seconds(req.idempotency_key_ttl_seconds.unwrap_or(86400));

        // Idempotency check
        if let Some(ref key) = req.idempotency_key {
            match self.idempotency_repo.claim_or_get(req.tenant_id, key, expires_at).await? {
                ClaimResult::Existing { execution_id } => {
                    let workflow = self.workflow_repo.find_by_id(execution_id).await?
                        .ok_or(LaunchError::NotFound)?;
                    return Ok(StartWorkflowResult::Existing(workflow));
                }
                ClaimResult::Available => { /* proceed */ }
            }
        }

        // Create workflow
        let workflow = WorkflowExecution::new(
            req.tenant_id,
            req.workflow_kind,
            req.input,
            queue.clone(),
            req.priority_ms.unwrap_or(0),
        );
        self.workflow_repo.create(&workflow).await?;

        // Register idempotency key
        if let Some(ref key) = req.idempotency_key {
            self.idempotency_repo
                .register(req.tenant_id, key, Some(workflow.id), None, expires_at)
                .await?;
        }

        // Notify workers
        self.notifier.notify_workflow_available(req.tenant_id, &queue).await;

        // Publish event
        self.event_publisher.publish(FlovynEvent::workflow_started(&workflow)).await?;

        Ok(StartWorkflowResult::Created(workflow))
    }
}
```

Similar `TaskLauncher` for tasks.

### WorkflowTarget

Uses `WorkflowLauncher` service:

```rust
impl WorkflowTarget {
    pub async fn execute(
        &self,
        config: &WorkflowTargetConfig,
        headers: &HeaderMap,
        payload: &serde_json::Value,
        tenant_id: Uuid,
    ) -> Result<TargetResult, TargetError> {
        // Extract idempotency key if configured
        let idempotency_key = config.idempotency_key_path.as_ref()
            .and_then(|path| extract_by_path(path, headers, Some(payload)));

        let result = self.workflow_launcher.start(StartWorkflowRequest {
            tenant_id,
            workflow_kind: config.workflow_kind.clone(),
            input: Some(serde_json::to_vec(payload)?),
            queue: config.queue.clone(),
            priority_ms: None,
            idempotency_key,
            idempotency_key_ttl_seconds: None,
        }).await?;

        match result {
            StartWorkflowResult::Created(wf) => Ok(TargetResult::Workflow { id: wf.id, is_new: true }),
            StartWorkflowResult::Existing(wf) => Ok(TargetResult::Workflow { id: wf.id, is_new: false }),
        }
    }
}
```

### TaskTarget

Uses `TaskLauncher` service:

```rust
impl TaskTarget {
    pub async fn execute(
        &self,
        config: &TaskTargetConfig,
        headers: &HeaderMap,
        payload: &serde_json::Value,
        tenant_id: Uuid,
    ) -> Result<TargetResult, TargetError> {
        let idempotency_key = config.idempotency_key_path.as_ref()
            .and_then(|path| extract_by_path(path, headers, Some(payload)));

        let result = self.task_launcher.start(StartTaskRequest {
            tenant_id,
            task_kind: config.task_kind.clone(),
            input: Some(serde_json::to_vec(payload)?),
            queue: config.queue.clone(),
            idempotency_key,
            idempotency_key_ttl_seconds: None,
        }).await?;

        match result {
            StartTaskResult::Created(task) => Ok(TargetResult::Task { id: task.id, is_new: true }),
            StartTaskResult::Existing(task) => Ok(TargetResult::Task { id: task.id, is_new: false }),
        }
    }
}
```

### PromiseTarget

Promises use a different pattern than workflows/tasks. When a workflow creates a promise, it registers an **idempotency key** (e.g., `stripe:pi_abc123`). Webhooks extract this key from the payload, look up the promise, and resolve/reject it.

See: [Unified Idempotency Plan](../plans/20260101_unified_idempotency.md)

**Prerequisite:** Extract `PromiseResolver` service from `flovyn-server/server/src/api/rest/promises.rs` (same pattern as WorkflowLauncher).

```rust
// server/src/service/promise_resolver.rs

pub enum ResolveResult {
    Resolved { promise_id: Uuid },
    AlreadyResolved { promise_id: Uuid },
}

pub struct PromiseResolver {
    promise_repo: Arc<PromiseRepository>,
    idempotency_repo: Arc<IdempotencyKeyRepository>,
    workflow_repo: Arc<WorkflowRepository>,
    event_publisher: Arc<dyn EventPublisher>,
    notifier: WorkerNotifier,
}

impl PromiseResolver {
    /// Resolve a promise by idempotency key.
    pub async fn resolve_by_key(
        &self,
        tenant_id: Uuid,
        idempotency_key: &str,
        value: serde_json::Value,
    ) -> Result<ResolveResult, ResolveError> {
        // Look up promise by idempotency key
        let promise_id = self.idempotency_repo
            .find_promise_by_key(tenant_id, idempotency_key)
            .await?
            .ok_or(ResolveError::NotFound)?;

        // Resolve atomically (extracted from promises.rs)
        // ... includes notification, event publishing, etc.
    }

    /// Reject a promise by idempotency key.
    pub async fn reject_by_key(
        &self,
        tenant_id: Uuid,
        idempotency_key: &str,
        error: &str,
    ) -> Result<ResolveResult, ResolveError> {
        // ...
    }
}
```

### PromiseTarget Implementation

Uses `PromiseResolver` service:

```rust
impl PromiseTarget {
    pub async fn execute(
        &self,
        config: &PromiseTargetConfig,
        headers: &HeaderMap,
        payload: &serde_json::Value,
        tenant_id: Uuid,
    ) -> Result<TargetResult, TargetError> {
        // 1. Extract idempotency key from payload
        let key_value = extract_by_path(&config.idempotency_key_path, headers, Some(payload))
            .ok_or(TargetError::IdempotencyKeyNotFound)?;

        // 2. Build full key with optional prefix
        let idempotency_key = match &config.idempotency_key_prefix {
            Some(prefix) => format!("{}{}", prefix, key_value),
            None => key_value,
        };

        // 3. Extract value/error from payload
        let value = config.value_path.as_ref()
            .and_then(|path| {
                let pointer = format!("/{}", path.replace('.', "/"));
                payload.pointer(&pointer).cloned()
            })
            .unwrap_or_else(|| payload.clone());

        // 4. Resolve or reject via service
        let result = if config.resolve {
            self.promise_resolver.resolve_by_key(tenant_id, &idempotency_key, value).await?
        } else {
            let error_msg = config.error_path.as_ref()
                .and_then(|path| extract_by_path(path, headers, Some(payload)))
                .unwrap_or_else(|| "Rejected via webhook".to_string());
            self.promise_resolver.reject_by_key(tenant_id, &idempotency_key, &error_msg).await?
        };

        match result {
            ResolveResult::Resolved { promise_id } => Ok(TargetResult::Promise {
                id: promise_id,
                already_resolved: false,
            }),
            ResolveResult::AlreadyResolved { promise_id } => Ok(TargetResult::Promise {
                id: promise_id,
                already_resolved: true,
            }),
        }
    }
}
```

**Example: Stripe PaymentIntent webhook resolving a promise**

1. **Workflow creates PaymentIntent** and gets back `pi_abc123`
2. **Workflow creates promise** with idempotency key based on that ID:
```rust
// Workflow knows the PaymentIntent ID from Stripe API response
let payment_intent_id = "pi_abc123";

// Create promise with key that matches what webhook will contain
ctx.promise_raw_with_options("payment", PromiseOptions {
    idempotency_key: Some(format!("stripe:{}", payment_intent_id)),
    ..Default::default()
}).await?;
```

3. **Stripe sends webhook** when payment succeeds:
```json
{
  "type": "payment_intent.succeeded",
  "data": {
    "object": {
      "id": "pi_abc123",
      "amount": 2000,
      "status": "succeeded"
    }
  }
}
```

4. **Eventhook route config** extracts ID and adds prefix:
```json
{
  "target_type": "promise",
  "target_config": {
    "idempotency_key_path": "body.data.object.id",
    "idempotency_key_prefix": "stripe:",
    "resolve": true,
    "value_path": "body.data.object"
  },
  "filter_event_types": ["payment_intent.succeeded"]
}
```

5. **PromiseTarget** extracts `pi_abc123`, builds key `stripe:pi_abc123`, looks up promise, resolves with PaymentIntent data.

**Flexibility:** The system works without metadata injection - workflow and webhook naturally share the external ID. However, metadata injection is still supported if useful (e.g., storing the promise name in Stripe metadata for debugging). The `idempotency_key_path` can point to either:
- Natural IDs: `body.data.object.id` (recommended, no injection)
- Injected metadata: `body.data.object.metadata.my_key` (if preferred)

## Plugin Registration

### Plugin Implementation

```rust
// plugins/eventhook/src/lib.rs

pub struct EventhookPlugin;

impl EventhookPlugin {
    pub const NAME: &'static str = "eventhook";
    pub const VERSION: &'static str = "0.1.0";

    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl Plugin for EventhookPlugin {
    fn name(&self) -> &'static str {
        Self::NAME
    }

    fn version(&self) -> &'static str {
        Self::VERSION
    }

    fn trusted(&self) -> bool {
        true // First-party plugin
    }

    fn migrations(&self) -> Vec<PluginMigration> {
        flovyn_plugin::plugin_migrations!()
    }

    fn rest_routes(&self, services: Arc<PluginServices>) -> Router {
        api::create_router(services)
    }

    fn openapi(&self) -> Option<utoipa::openapi::OpenApi> {
        Some(EventhookApiDoc::openapi())
    }
}
```

### Feature Flag

```toml
# server/Cargo.toml
[features]
default = ["plugin-worker-token"]
plugin-eventhook = ["dep:flovyn-plugin-eventhook"]
all-plugins = ["plugin-worker-token", "plugin-eventhook"]

[dependencies]
flovyn-plugin-eventhook = { workspace = true, optional = true }
```

## Testing Strategy

### Unit Tests

**Verifier tests:**
- `test_hmac_verify_github_signature`
- `test_hmac_verify_stripe_signature`
- `test_hmac_verify_invalid_signature`
- `test_api_key_verify_success`
- `test_api_key_verify_missing_header`
- `test_basic_auth_verify_success`

**Route matching tests:**
- `test_route_matches_event_type`
- `test_route_matches_all_events`
- `test_route_no_match_wrong_type`

**Deduplication tests:**
- `test_extract_idempotency_key_from_header`
- `test_extract_idempotency_key_from_body`
- `test_extract_idempotency_key_nested_path`
- `test_extract_idempotency_key_fallback_chain`
- `test_duplicate_event_not_processed`
- `test_duplicate_event_returns_200`

**Target tests:**
- `test_workflow_target_creates_execution`
- `test_task_target_creates_standalone`
- `test_promise_target_resolves`
- `test_promise_target_rejects`

### Integration Tests

**End-to-end flow:**
```rust
#[tokio::test]
async fn test_webhook_triggers_workflow() {
    let harness = TestHarness::start().await;

    // Create source and route via direct DB insert (no management API in M1)
    let source = harness.create_webhook_source("github", HmacConfig {
        header: "X-Hub-Signature-256".to_string(),
        secret: "test-secret".into(),
        algorithm: HmacAlgorithm::Sha256,
        encoding: SignatureEncoding::Hex,
        prefix: Some("sha256=".to_string()),
    }).await;

    harness.create_route(source.id, RouteConfig {
        name: "trigger-on-push".to_string(),
        target_type: TargetType::Workflow,
        target_config: json!({
            "workflow_kind": "process-github-event"
        }),
        filter_event_types: Some(vec!["push".to_string()]),
    }).await;

    // Send webhook with valid signature
    let payload = json!({
        "action": "push",
        "repository": { "name": "test-repo" }
    });
    let signature = compute_github_signature("test-secret", &payload);

    let response = harness.client
        .post(&format!("/api/tenants/{}/eventhook/in/github", harness.tenant_slug))
        .header("X-Hub-Signature-256", signature)
        .json(&payload)
        .send()
        .await;

    assert_eq!(response.status(), 200);

    // Verify workflow was created
    let workflows = harness.list_workflow_executions().await;
    assert_eq!(workflows.len(), 1);
    assert_eq!(workflows[0].kind, "process-github-event");
}
```

**Signature verification tests:**
```rust
#[tokio::test]
async fn test_webhook_rejects_invalid_signature() {
    // ... setup source ...

    let response = harness.client
        .post(&format!("/api/tenants/{}/eventhook/in/github", harness.tenant_slug))
        .header("X-Hub-Signature-256", "sha256=invalid")
        .json(&json!({}))
        .send()
        .await;

    assert_eq!(response.status(), 401);
}
```

## Exit Criteria

M1 is complete when:

**Core Prerequisites:**
1. [ ] Extract `WorkflowLauncher` service from `workflow_dispatch.rs`
2. [ ] Extract `TaskLauncher` service from `task_execution.rs`
3. [ ] Refactor gRPC handlers to use the new services

**Plugin Implementation:**
4. [ ] Plugin skeleton created with proper registration
5. [ ] Database schema created with all 4 tables
6. [ ] Ingest endpoint receives webhooks at `/api/tenants/{slug}/eventhook/in/{source}`
7. [ ] HMAC signature verification works for GitHub-style webhooks
8. [ ] API key and basic auth verification work
9. [ ] Event-level deduplication works with configurable idempotency key paths
10. [ ] WorkflowTarget triggers workflows via `WorkflowLauncher` (with target-level dedup)
11. [ ] TaskTarget creates tasks via `TaskLauncher` (with target-level dedup)
12. [ ] PromiseTarget resolves/rejects promises
13. [ ] Events stored in database with status tracking

**Testing:**
14. [ ] All unit tests pass
15. [ ] Integration test demonstrates end-to-end flow

**Verification command:**
```bash
# This works:
curl -X POST /api/tenants/acme/eventhook/in/github \
  -H "X-Hub-Signature-256: sha256=..." \
  -d '{"action": "push", ...}'
# -> Triggers workflow based on configured route
```

## Security Considerations

1. **Secret storage**: Verifier secrets stored encrypted in database
2. **Constant-time comparison**: HMAC verification uses constant-time comparison
3. **Rate limiting**: Consider adding per-source rate limiting
4. **IP allowlisting**: Future consideration for enterprise sources
5. **Event storage**: Raw payload stored for debugging; consider retention policy

## References

- [M0 Design](./20251231_eventhook_milestone0_event_publisher.md) - Event bus infrastructure
- [Research Document](../research/eventhook/20251231_research.md) - Full research with Svix/Convoy analysis
- [Roadmap](../research/eventhook/20251231_roadmap.md) - Milestone overview
- Worker Token Plugin: `plugins/worker-token/` - Reference for plugin structure
