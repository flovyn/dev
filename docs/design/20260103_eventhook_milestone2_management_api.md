# Eventhook Milestone 2: Management API

**Date:** 2026-01-03
**Status:** Design
**Related:** [M1 Design](./20250101_eventhook_milestone1_receive_route.md), [Research](../research/eventhook/20251231_research.md), [Roadmap](../research/eventhook/20251231_roadmap.md)

## Overview

This document describes the design for Milestone 2 of the Eventhook feature: providing a complete REST API for managing webhook sources, routes, and events.

**Scope:**
- Sources CRUD API (create, list, get, update, delete)
- Routes CRUD API (nested under sources)
- Events API (list, get details, reprocess)
- Provider templates (pre-configured verifiers for GitHub, Stripe, etc.)

## Goals

1. **Full configuration via API** - No direct database manipulation required
2. **Provider templates** - Easy setup for common webhook providers
3. **Event visibility** - Query and debug webhook events
4. **Event replay** - Reprocess failed or unrouted events

## Non-Goals

- Advanced pattern matching on event data (Milestone 3)
- JavaScript transformations (Milestone 3)
- Outbound webhook delivery (Milestone 4)

## Prerequisites

- M1 complete: Ingest endpoint, signature verification, event processing, target execution

## Authentication

Management endpoints use **standard Flovyn authentication** via the tenant auth middleware:
- JWT tokens (user identity)
- Session tokens (user identity)
- API keys (if configured)

This is different from ingest endpoints (`/in/{source}`) which use signature verification.

## API Design

### Base Path

All management endpoints are under:
```
/api/tenants/{tenant_slug}/eventhook
```

### 1. Sources API

#### List Sources

```
GET /api/tenants/{tenant_slug}/eventhook/sources
```

Query parameters:
| Parameter | Type | Description |
|-----------|------|-------------|
| `enabled` | bool | Filter by enabled status |
| `limit` | int | Max results (default: 50, max: 100) |
| `offset` | int | Pagination offset |

Response:
```json
{
  "sources": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "slug": "github",
      "name": "GitHub Webhooks",
      "description": "GitHub repository events",
      "enabled": true,
      "verifierType": "hmac",
      "rateLimitPerSecond": 100,
      "ingestUrl": "https://api.flovyn.io/api/tenants/acme/eventhook/in/github",
      "routeCount": 3,
      "createdAt": "2026-01-01T00:00:00Z",
      "updatedAt": "2026-01-02T00:00:00Z"
    }
  ],
  "total": 5,
  "limit": 50,
  "offset": 0
}
```

#### Create Source

```
POST /api/tenants/{tenant_slug}/eventhook/sources
```

Request:
```json
{
  "slug": "github",
  "name": "GitHub Webhooks",
  "description": "GitHub repository events",
  "enabled": true,
  "verifierConfig": {
    "type": "hmac",
    "secret": "whsec_...",
    "algorithm": "sha256",
    "headerName": "X-Hub-Signature-256",
    "encoding": "hex",
    "prefix": "sha256="
  },
  "rateLimitPerSecond": 100,
  "idempotencyKeyPaths": ["header.x-github-delivery"]
}
```

Alternative using provider template:
```json
{
  "slug": "github",
  "name": "GitHub Webhooks",
  "provider": "github",
  "secret": "whsec_..."
}
```

Response: `201 Created` with source object (same as list item).

Validation:
- `slug`: required, unique per tenant, lowercase alphanumeric with hyphens
- `name`: required, 1-255 characters
- `verifierConfig` or `provider`: at least one required (unless intentionally no verification)
- `rateLimitPerSecond`: optional, 1-10000

#### Get Source

```
GET /api/tenants/{tenant_slug}/eventhook/sources/{source_slug}
```

Response:
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "slug": "github",
  "name": "GitHub Webhooks",
  "description": "GitHub repository events",
  "enabled": true,
  "verifierConfig": {
    "type": "hmac",
    "algorithm": "sha256",
    "headerName": "X-Hub-Signature-256",
    "encoding": "hex",
    "prefix": "sha256="
  },
  "rateLimitPerSecond": 100,
  "idempotencyKeyPaths": ["header.x-github-delivery"],
  "ingestUrl": "https://api.flovyn.io/api/tenants/acme/eventhook/in/github",
  "routeCount": 3,
  "stats": {
    "eventsLast24h": 142,
    "eventsLastHour": 12,
    "failedLast24h": 2
  },
  "createdAt": "2026-01-01T00:00:00Z",
  "updatedAt": "2026-01-02T00:00:00Z"
}
```

Note: `verifierConfig.secret` is never returned in responses.

#### Update Source

```
PUT /api/tenants/{tenant_slug}/eventhook/sources/{source_slug}
```

Request (partial updates supported):
```json
{
  "name": "GitHub Webhooks (Production)",
  "enabled": false,
  "rateLimitPerSecond": 50
}
```

To update the secret:
```json
{
  "verifierConfig": {
    "type": "hmac",
    "secret": "new_secret_value",
    "algorithm": "sha256",
    "headerName": "X-Hub-Signature-256",
    "encoding": "hex",
    "prefix": "sha256="
  }
}
```

Response: `200 OK` with updated source object.

#### Delete Source

```
DELETE /api/tenants/{tenant_slug}/eventhook/sources/{source_slug}
```

Response: `204 No Content`

Note: Deleting a source also deletes all associated routes and events (cascade).

#### Test Source Verification

```
POST /api/tenants/{tenant_slug}/eventhook/sources/{source_slug}/test
```

Request:
```json
{
  "headers": {
    "X-Hub-Signature-256": "sha256=abc123...",
    "Content-Type": "application/json"
  },
  "payload": "{\"action\": \"push\"}"
}
```

Response:
```json
{
  "verified": true,
  "verifierType": "hmac",
  "details": {
    "algorithm": "sha256",
    "signatureFound": true,
    "signatureValid": true
  }
}
```

Or on failure:
```json
{
  "verified": false,
  "verifierType": "hmac",
  "error": "Signature mismatch",
  "details": {
    "algorithm": "sha256",
    "signatureFound": true,
    "signatureValid": false
  }
}
```

### 2. Routes API

Routes are nested under sources.

#### List Routes

```
GET /api/tenants/{tenant_slug}/eventhook/sources/{source_slug}/routes
```

Query parameters:
| Parameter | Type | Description |
|-----------|------|-------------|
| `enabled` | bool | Filter by enabled status |

Response:
```json
{
  "routes": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440001",
      "name": "Handle Push Events",
      "description": "Trigger CI workflow on push",
      "eventTypeFilter": "push",
      "priority": 10,
      "target": {
        "type": "workflow",
        "workflowKind": "ci-pipeline",
        "queue": "default"
      },
      "enabled": true,
      "stats": {
        "matchedLast24h": 45,
        "executedLast24h": 45,
        "failedLast24h": 0
      },
      "createdAt": "2026-01-01T00:00:00Z",
      "updatedAt": "2026-01-02T00:00:00Z"
    }
  ]
}
```

#### Create Route

```
POST /api/tenants/{tenant_slug}/eventhook/sources/{source_slug}/routes
```

Request:
```json
{
  "name": "Handle Push Events",
  "description": "Trigger CI workflow on push",
  "eventTypeFilter": "push",
  "priority": 10,
  "target": {
    "type": "workflow",
    "workflowKind": "ci-pipeline",
    "queue": "default",
    "idempotencyKeyPath": "body.after"
  },
  "enabled": true
}
```

Target types:

**Workflow target:**
```json
{
  "type": "workflow",
  "workflowKind": "process-payment",
  "queue": "payments",
  "idempotencyKeyPath": "body.data.object.id",
  "idempotencyKeyTtlSeconds": 86400
}
```

**Task target:**
```json
{
  "type": "task",
  "taskKind": "send-notification",
  "queue": "notifications",
  "idempotencyKeyPath": "body.id",
  "maxRetries": 3
}
```

**Promise target:**
```json
{
  "type": "promise",
  "idempotencyKeyPath": "body.data.object.id",
  "idempotencyKeyPrefix": "stripe:",
  "mode": "resolve"
}
```

Response: `201 Created` with route object.

#### Get Route

```
GET /api/tenants/{tenant_slug}/eventhook/sources/{source_slug}/routes/{route_id}
```

Response: Route object with full details.

#### Update Route

```
PUT /api/tenants/{tenant_slug}/eventhook/sources/{source_slug}/routes/{route_id}
```

Request (partial updates supported):
```json
{
  "priority": 5,
  "enabled": false
}
```

Response: `200 OK` with updated route object.

#### Delete Route

```
DELETE /api/tenants/{tenant_slug}/eventhook/sources/{source_slug}/routes/{route_id}
```

Response: `204 No Content`

#### Reorder Routes

```
PUT /api/tenants/{tenant_slug}/eventhook/sources/{source_slug}/routes/reorder
```

Request:
```json
{
  "order": [
    {"id": "route-id-1", "priority": 10},
    {"id": "route-id-2", "priority": 20},
    {"id": "route-id-3", "priority": 30}
  ]
}
```

Response: `200 OK` with updated routes list.

### 3. Events API

#### List Events

```
GET /api/tenants/{tenant_slug}/eventhook/events
```

Query parameters:
| Parameter | Type | Description |
|-----------|------|-------------|
| `sourceId` | uuid | Filter by source |
| `sourceSlug` | string | Filter by source slug |
| `status` | string | Filter by status (pending, completed, failed, etc.) |
| `eventType` | string | Filter by event type |
| `since` | datetime | Events received after this time |
| `until` | datetime | Events received before this time |
| `limit` | int | Max results (default: 50, max: 100) |
| `offset` | int | Pagination offset |

Response:
```json
{
  "events": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440002",
      "sourceId": "550e8400-e29b-41d4-a716-446655440000",
      "sourceSlug": "github",
      "externalId": "abc123",
      "eventType": "push",
      "status": "completed",
      "attemptCount": 1,
      "contentType": "application/json",
      "payloadSize": 1234,
      "createdAt": "2026-01-02T10:30:00Z",
      "processedAt": "2026-01-02T10:30:01Z"
    }
  ],
  "total": 142,
  "limit": 50,
  "offset": 0
}
```

#### Get Event Details

```
GET /api/tenants/{tenant_slug}/eventhook/events/{event_id}
```

Response:
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440002",
  "sourceId": "550e8400-e29b-41d4-a716-446655440000",
  "sourceSlug": "github",
  "externalId": "abc123",
  "eventType": "push",
  "status": "completed",
  "attemptCount": 1,
  "headers": {
    "x-github-event": "push",
    "x-github-delivery": "abc123",
    "content-type": "application/json"
  },
  "payload": {
    "ref": "refs/heads/main",
    "after": "abc123def456",
    "repository": {
      "name": "my-repo"
    }
  },
  "contentType": "application/json",
  "error": null,
  "createdAt": "2026-01-02T10:30:00Z",
  "processedAt": "2026-01-02T10:30:01Z",
  "actions": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440003",
      "routeId": "550e8400-e29b-41d4-a716-446655440001",
      "routeName": "Handle Push Events",
      "targetType": "workflow",
      "targetId": "550e8400-e29b-41d4-a716-446655440004",
      "status": "completed",
      "createdAt": "2026-01-02T10:30:00Z",
      "completedAt": "2026-01-02T10:30:01Z"
    }
  ]
}
```

#### Get Event Raw Payload

```
GET /api/tenants/{tenant_slug}/eventhook/events/{event_id}/payload
```

Response: Raw payload bytes with original content-type header.

#### Reprocess Events

```
POST /api/tenants/{tenant_slug}/eventhook/events/reprocess
```

Request (supports two modes):
```json
{
  "eventIds": ["uuid1", "uuid2"],
  "filter": {
    "status": ["failed", "unrouted"],
    "sourceId": "uuid",
    "since": "2026-01-01T00:00:00Z",
    "until": "2026-01-02T00:00:00Z"
  },
  "limit": 100
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `eventIds` | No | Specific event UUIDs to reprocess |
| `filter` | No | Query filter for batch selection |
| `filter.status` | No | Event statuses to include (default: `["failed", "unrouted"]`) |
| `filter.sourceId` | No | Filter by webhook source |
| `filter.since` | No | Events received after this time |
| `filter.until` | No | Events received before this time |
| `limit` | Yes* | Max events to reprocess (*required when using filter) |

Validation:
- At least one of `eventIds` or `filter` must be provided
- If both provided, `eventIds` takes precedence
- `limit` is required when using `filter` (prevents accidental mass reprocess)
- Only events in `failed` or `unrouted` status can be reprocessed

Response:
```json
{
  "reprocessedCount": 42,
  "eventIds": ["uuid1", "uuid2", "..."]
}
```

### 4. Provider Templates

Provider templates provide pre-configured verifier settings for common webhook providers.

#### List Available Providers

```
GET /api/tenants/{tenant_slug}/eventhook/providers
```

Response:
```json
{
  "providers": [
    {
      "id": "github",
      "name": "GitHub",
      "description": "GitHub repository webhooks",
      "verifierType": "hmac",
      "documentationUrl": "https://docs.github.com/webhooks",
      "requiredFields": ["secret"],
      "optionalFields": [],
      "defaultIdempotencyKeyPaths": ["header.x-github-delivery"]
    },
    {
      "id": "stripe",
      "name": "Stripe",
      "description": "Stripe payment webhooks",
      "verifierType": "hmac",
      "documentationUrl": "https://stripe.com/docs/webhooks",
      "requiredFields": ["secret"],
      "optionalFields": [],
      "defaultIdempotencyKeyPaths": ["body.id"]
    }
  ]
}
```

#### Provider Template Definitions

| Provider | Verifier | Header | Algorithm | Encoding | Prefix | Idempotency Key |
|----------|----------|--------|-----------|----------|--------|-----------------|
| `github` | HMAC | X-Hub-Signature-256 | SHA256 | hex | `sha256=` | `header.x-github-delivery` |
| `stripe` | HMAC | Stripe-Signature | SHA256 | hex | - | `body.id` |
| `shopify` | HMAC | X-Shopify-Hmac-Sha256 | SHA256 | base64 | - | `header.x-shopify-webhook-id` |
| `slack` | HMAC | X-Slack-Signature | SHA256 | hex | `v0=` | `body.event_id` |
| `linear` | HMAC | Linear-Signature | SHA256 | hex | - | `body.webhookId` |
| `twilio` | HMAC | X-Twilio-Signature | SHA1 | base64 | - | `header.i-twilio-idempotency-token` |

#### Using Provider Templates

When creating a source with a provider template:

```json
{
  "slug": "github-prod",
  "name": "GitHub Production",
  "provider": "github",
  "secret": "whsec_..."
}
```

This expands to:
```json
{
  "slug": "github-prod",
  "name": "GitHub Production",
  "verifierConfig": {
    "type": "hmac",
    "secret": "whsec_...",
    "algorithm": "sha256",
    "headerName": "X-Hub-Signature-256",
    "encoding": "hex",
    "prefix": "sha256="
  },
  "idempotencyKeyPaths": ["header.x-github-delivery"]
}
```

## Implementation

### DTOs

```rust
// plugins/eventhook/src/api/dto.rs

use serde::{Deserialize, Serialize};
use uuid::Uuid;
use chrono::{DateTime, Utc};

// === Source DTOs ===

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceResponse {
    pub id: Uuid,
    pub slug: String,
    pub name: String,
    pub description: Option<String>,
    pub enabled: bool,
    pub verifier_type: Option<String>,
    pub rate_limit_per_second: Option<i32>,
    pub ingest_url: String,
    pub route_count: i64,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceDetailResponse {
    #[serde(flatten)]
    pub source: SourceResponse,
    pub verifier_config: Option<VerifierConfigResponse>,
    pub idempotency_key_paths: Option<Vec<String>>,
    pub stats: SourceStats,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceStats {
    pub events_last_24h: i64,
    pub events_last_hour: i64,
    pub failed_last_24h: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateSourceRequest {
    pub slug: String,
    pub name: String,
    pub description: Option<String>,
    pub enabled: Option<bool>,
    pub provider: Option<String>,
    pub secret: Option<String>,
    pub verifier_config: Option<VerifierConfigRequest>,
    pub rate_limit_per_second: Option<i32>,
    pub idempotency_key_paths: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateSourceRequest {
    pub name: Option<String>,
    pub description: Option<String>,
    pub enabled: Option<bool>,
    pub verifier_config: Option<VerifierConfigRequest>,
    pub rate_limit_per_second: Option<i32>,
    pub idempotency_key_paths: Option<Vec<String>>,
}

// === Route DTOs ===

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RouteResponse {
    pub id: Uuid,
    pub name: String,
    pub description: Option<String>,
    pub event_type_filter: Option<String>,
    pub priority: i32,
    pub target: TargetConfigResponse,
    pub enabled: bool,
    pub stats: RouteStats,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RouteStats {
    pub matched_last_24h: i64,
    pub executed_last_24h: i64,
    pub failed_last_24h: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateRouteRequest {
    pub name: String,
    pub description: Option<String>,
    pub event_type_filter: Option<String>,
    pub priority: Option<i32>,
    pub target: TargetConfigRequest,
    pub enabled: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateRouteRequest {
    pub name: Option<String>,
    pub description: Option<String>,
    pub event_type_filter: Option<String>,
    pub priority: Option<i32>,
    pub target: Option<TargetConfigRequest>,
    pub enabled: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReorderRoutesRequest {
    pub order: Vec<RouteOrderItem>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RouteOrderItem {
    pub id: Uuid,
    pub priority: i32,
}

// === Event DTOs ===

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EventResponse {
    pub id: Uuid,
    pub source_id: Uuid,
    pub source_slug: String,
    pub external_id: Option<String>,
    pub event_type: Option<String>,
    pub status: String,
    pub attempt_count: i32,
    pub content_type: Option<String>,
    pub payload_size: i64,
    pub created_at: DateTime<Utc>,
    pub processed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EventDetailResponse {
    #[serde(flatten)]
    pub event: EventResponse,
    pub headers: serde_json::Value,
    pub payload: serde_json::Value,
    pub error: Option<String>,
    pub actions: Vec<EventActionResponse>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EventActionResponse {
    pub id: Uuid,
    pub route_id: Uuid,
    pub route_name: String,
    pub target_type: String,
    pub target_id: Option<Uuid>,
    pub status: String,
    pub error: Option<String>,
    pub created_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReprocessEventsRequest {
    pub event_ids: Option<Vec<Uuid>>,
    pub filter: Option<ReprocessFilter>,
    pub limit: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReprocessFilter {
    pub status: Option<Vec<String>>,
    pub source_id: Option<Uuid>,
    pub since: Option<DateTime<Utc>>,
    pub until: Option<DateTime<Utc>>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReprocessEventsResponse {
    pub reprocessed_count: i64,
    pub event_ids: Vec<Uuid>,
}

// === Provider DTOs ===

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderResponse {
    pub id: String,
    pub name: String,
    pub description: String,
    pub verifier_type: String,
    pub documentation_url: String,
    pub required_fields: Vec<String>,
    pub optional_fields: Vec<String>,
    pub default_idempotency_key_paths: Vec<String>,
}
```

### Handler Structure

```rust
// plugins/eventhook/src/api/mod.rs

pub fn management_routes(services: Arc<PluginServices>) -> Router {
    Router::new()
        // Sources
        .route("/sources", get(list_sources).post(create_source))
        .route("/sources/:source_slug",
            get(get_source).put(update_source).delete(delete_source))
        .route("/sources/:source_slug/test", post(test_source))
        // Routes (nested under sources)
        .route("/sources/:source_slug/routes",
            get(list_routes).post(create_route))
        .route("/sources/:source_slug/routes/reorder", put(reorder_routes))
        .route("/sources/:source_slug/routes/:route_id",
            get(get_route).put(update_route).delete(delete_route))
        // Events
        .route("/events", get(list_events))
        .route("/events/reprocess", post(reprocess_events))
        .route("/events/:event_id", get(get_event))
        .route("/events/:event_id/payload", get(get_event_payload))
        // Providers
        .route("/providers", get(list_providers))
        .with_state(services)
}
```

### Repository Extensions

Add these methods to existing repositories:

```rust
// plugins/eventhook/src/repository/source_repository.rs

impl SourceRepository {
    // Existing methods...

    pub async fn create(&self, source: &WebhookSource) -> Result<(), Error>;
    pub async fn update(&self, source: &WebhookSource) -> Result<(), Error>;
    pub async fn delete(&self, tenant_id: Uuid, slug: &str) -> Result<bool, Error>;
    pub async fn list(&self, tenant_id: Uuid, filter: &SourceFilter) -> Result<Vec<WebhookSource>, Error>;
    pub async fn count_routes(&self, source_id: Uuid) -> Result<i64, Error>;
    pub async fn get_stats(&self, source_id: Uuid) -> Result<SourceStats, Error>;
}

// plugins/eventhook/src/repository/route_repository.rs

impl RouteRepository {
    // Existing methods...

    pub async fn create(&self, route: &WebhookRoute) -> Result<(), Error>;
    pub async fn update(&self, route: &WebhookRoute) -> Result<(), Error>;
    pub async fn delete(&self, id: Uuid) -> Result<bool, Error>;
    pub async fn list_by_source(&self, source_id: Uuid) -> Result<Vec<WebhookRoute>, Error>;
    pub async fn update_priorities(&self, updates: &[(Uuid, i32)]) -> Result<(), Error>;
    pub async fn get_stats(&self, route_id: Uuid) -> Result<RouteStats, Error>;
}

// plugins/eventhook/src/repository/event_repository.rs

impl EventRepository {
    // Existing methods...

    pub async fn list(&self, tenant_id: Uuid, filter: &EventFilter) -> Result<Vec<WebhookEvent>, Error>;
    pub async fn count(&self, tenant_id: Uuid, filter: &EventFilter) -> Result<i64, Error>;
    pub async fn get_with_actions(&self, id: Uuid) -> Result<Option<(WebhookEvent, Vec<EventAction>)>, Error>;
    pub async fn find_for_reprocess(&self, tenant_id: Uuid, filter: &ReprocessFilter, limit: i64) -> Result<Vec<Uuid>, Error>;
    pub async fn reset_for_reprocess(&self, ids: &[Uuid]) -> Result<i64, Error>;
}
```

### Provider Template Registry

```rust
// plugins/eventhook/src/service/provider_templates.rs

use crate::domain::source::{VerifierConfig, HmacConfig, HmacAlgorithm, SignatureEncoding};

pub struct ProviderTemplate {
    pub id: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    pub documentation_url: &'static str,
    pub verifier_config: fn(secret: &str) -> VerifierConfig,
    pub default_idempotency_key_paths: Vec<&'static str>,
}

pub fn get_provider_templates() -> Vec<ProviderTemplate> {
    vec![
        ProviderTemplate {
            id: "github",
            name: "GitHub",
            description: "GitHub repository webhooks",
            documentation_url: "https://docs.github.com/webhooks",
            verifier_config: |secret| VerifierConfig::Hmac(HmacConfig {
                secret: secret.to_string(),
                algorithm: HmacAlgorithm::Sha256,
                header_name: "X-Hub-Signature-256".to_string(),
                encoding: SignatureEncoding::Hex,
                prefix: Some("sha256=".to_string()),
            }),
            default_idempotency_key_paths: vec!["header.x-github-delivery"],
        },
        ProviderTemplate {
            id: "stripe",
            name: "Stripe",
            description: "Stripe payment webhooks",
            documentation_url: "https://stripe.com/docs/webhooks",
            verifier_config: |secret| VerifierConfig::Hmac(HmacConfig {
                secret: secret.to_string(),
                algorithm: HmacAlgorithm::Sha256,
                header_name: "Stripe-Signature".to_string(),
                encoding: SignatureEncoding::Hex,
                prefix: None,
            }),
            default_idempotency_key_paths: vec!["body.id"],
        },
        ProviderTemplate {
            id: "shopify",
            name: "Shopify",
            description: "Shopify store webhooks",
            documentation_url: "https://shopify.dev/docs/apps/webhooks",
            verifier_config: |secret| VerifierConfig::Hmac(HmacConfig {
                secret: secret.to_string(),
                algorithm: HmacAlgorithm::Sha256,
                header_name: "X-Shopify-Hmac-Sha256".to_string(),
                encoding: SignatureEncoding::Base64,
                prefix: None,
            }),
            default_idempotency_key_paths: vec!["header.x-shopify-webhook-id"],
        },
        ProviderTemplate {
            id: "slack",
            name: "Slack",
            description: "Slack app webhooks",
            documentation_url: "https://api.slack.com/authentication/verifying-requests-from-slack",
            verifier_config: |secret| VerifierConfig::Hmac(HmacConfig {
                secret: secret.to_string(),
                algorithm: HmacAlgorithm::Sha256,
                header_name: "X-Slack-Signature".to_string(),
                encoding: SignatureEncoding::Hex,
                prefix: Some("v0=".to_string()),
            }),
            default_idempotency_key_paths: vec!["body.event_id"],
        },
        ProviderTemplate {
            id: "linear",
            name: "Linear",
            description: "Linear issue tracker webhooks",
            documentation_url: "https://developers.linear.app/docs/graphql/webhooks",
            verifier_config: |secret| VerifierConfig::Hmac(HmacConfig {
                secret: secret.to_string(),
                algorithm: HmacAlgorithm::Sha256,
                header_name: "Linear-Signature".to_string(),
                encoding: SignatureEncoding::Hex,
                prefix: None,
            }),
            default_idempotency_key_paths: vec!["body.webhookId"],
        },
    ]
}

pub fn get_provider(id: &str) -> Option<&'static ProviderTemplate> {
    get_provider_templates().iter().find(|p| p.id == id)
}
```

## OpenAPI Registration

Register all endpoints and DTOs in the plugin's OpenAPI spec:

```rust
// plugins/eventhook/src/api/openapi.rs

use utoipa::OpenApi;

#[derive(OpenApi)]
#[openapi(
    paths(
        // Sources
        list_sources,
        create_source,
        get_source,
        update_source,
        delete_source,
        test_source,
        // Routes
        list_routes,
        create_route,
        get_route,
        update_route,
        delete_route,
        reorder_routes,
        // Events
        list_events,
        get_event,
        get_event_payload,
        reprocess_events,
        // Providers
        list_providers,
    ),
    components(schemas(
        SourceResponse,
        SourceDetailResponse,
        CreateSourceRequest,
        UpdateSourceRequest,
        RouteResponse,
        CreateRouteRequest,
        UpdateRouteRequest,
        ReorderRoutesRequest,
        EventResponse,
        EventDetailResponse,
        ReprocessEventsRequest,
        ReprocessEventsResponse,
        ProviderResponse,
    )),
    tags(
        (name = "Eventhook Sources", description = "Webhook source management"),
        (name = "Eventhook Routes", description = "Webhook route management"),
        (name = "Eventhook Events", description = "Webhook event viewing and replay"),
        (name = "Eventhook Providers", description = "Pre-configured webhook provider templates"),
    )
)]
pub struct EventhookApiDoc;
```

## Testing Strategy

### Unit Tests

- Source CRUD validation
- Route CRUD validation
- Provider template expansion
- Reprocess filter validation

### Integration Tests

```rust
#[tokio::test]
async fn test_source_crud() {
    let harness = get_harness().await;

    // Create source
    let resp = harness.client
        .post("/api/tenants/test/eventhook/sources")
        .json(&json!({
            "slug": "github",
            "name": "GitHub",
            "provider": "github",
            "secret": "test-secret"
        }))
        .send().await;
    assert_eq!(resp.status(), 201);

    // List sources
    let resp = harness.client
        .get("/api/tenants/test/eventhook/sources")
        .send().await;
    assert_eq!(resp.status(), 200);
    let body: Value = resp.json().await;
    assert_eq!(body["sources"].as_array().unwrap().len(), 1);

    // Update source
    let resp = harness.client
        .put("/api/tenants/test/eventhook/sources/github")
        .json(&json!({"name": "GitHub Production"}))
        .send().await;
    assert_eq!(resp.status(), 200);

    // Delete source
    let resp = harness.client
        .delete("/api/tenants/test/eventhook/sources/github")
        .send().await;
    assert_eq!(resp.status(), 204);
}

#[tokio::test]
async fn test_route_crud();

#[tokio::test]
async fn test_event_list_and_filter();

#[tokio::test]
async fn test_event_reprocess();

#[tokio::test]
async fn test_provider_templates();
```

## Exit Criteria

M2 is complete when:

**Sources API:**
- [ ] List sources with pagination and filtering
- [ ] Create source with verifier config or provider template
- [ ] Get source with stats
- [ ] Update source (partial updates)
- [ ] Delete source (cascade to routes and events)
- [ ] Test source verification

**Routes API:**
- [ ] List routes for a source
- [ ] Create route with target config
- [ ] Get route with stats
- [ ] Update route (partial updates)
- [ ] Delete route
- [ ] Reorder routes

**Events API:**
- [ ] List events with filtering (source, status, time range)
- [ ] Get event details with actions
- [ ] Get raw event payload
- [ ] Reprocess events (by ID or filter)

**Provider Templates:**
- [ ] List available providers
- [ ] Create source using provider template

**Testing:**
- [ ] All integration tests pass
- [ ] OpenAPI spec includes all endpoints

**Verification:**
```bash
# Create source using provider template
curl -X POST /api/tenants/acme/eventhook/sources \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"slug": "github", "name": "GitHub", "provider": "github", "secret": "..."}'

# Create route
curl -X POST /api/tenants/acme/eventhook/sources/github/routes \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"name": "CI Pipeline", "eventTypeFilter": "push", "target": {...}}'

# List events
curl /api/tenants/acme/eventhook/events?status=failed

# Reprocess failed events
curl -X POST /api/tenants/acme/eventhook/events/reprocess \
  -d '{"filter": {"status": ["failed"]}, "limit": 100}'
```

## Security Considerations

1. **Secret handling**: Verifier secrets are never returned in API responses
2. **Authorization**: All management endpoints require tenant authentication
3. **Rate limiting**: Consider rate limiting management API to prevent abuse
4. **Cascade deletes**: Warn users before deleting sources with events

## References

- [M1 Design](./20250101_eventhook_milestone1_receive_route.md) - Receive & Route
- [Research Document](../research/eventhook/20251231_research.md) - Full research
- [Roadmap](../research/eventhook/20251231_roadmap.md) - Milestone overview
