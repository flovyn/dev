# Design: Fix Webhook Issues

**Date:** 2026-01-21
**Status:** Draft
**GitHub Issue:** https://github.com/flovyn/flovyn-server/issues/2
**Bug Investigation:** `dev/docs/bugs/20260120_webhook_ingest_issues.md`

## Problem Statement

The webhook ingest endpoint has three issues:

1. **Event type extraction is not configurable** - Users cannot specify where event type comes from (custom headers or JSON paths). Different providers use different conventions:
   - GitHub: `X-GitHub-Event` header
   - Shopify: `X-Shopify-Topic` header
   - Stripe: `type` field in JSON body
   - Custom systems: Any header or JSON path

2. **Wrong domain in fallback URL** - Hardcoded fallback is `api.flovyn.io` instead of `api.flovyn.ai`

3. **Ingest URL not environment-aware** - The ingest URL shown to users doesn't work for localhost or self-hosted deployments

## Current State Analysis

### Event Type Extraction (`flovyn-server/plugins/eventhook/src/api/ingest.rs:269-290`)

Currently hardcoded to check:
1. `X-GitHub-Event` header
2. JSON body fields: `type`, `event_type`, `eventType`

**Problems:**
- Not source-dependent - same logic for all sources
- Cannot configure custom header names (e.g., `X-Shopify-Topic`, `X-Webhook-Event`)
- Cannot configure custom JSON paths (e.g., `event.name`, `metadata.type`)
- Users with non-standard providers see "unknown" event type

### WebhookSource Domain (`flovyn-server/plugins/eventhook/src/domain/source.rs`)

```rust
pub struct WebhookSource {
    pub id: Uuid,
    pub org_id: Uuid,
    pub slug: String,
    pub name: String,
    pub description: Option<String>,
    pub verifier_config: Option<VerifierConfig>,
    pub rate_limit_per_second: Option<i32>,
    pub enabled: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}
```

**Gap:** No field for event type extraction configuration.

### Ingest URL Construction (`flovyn-server/plugins/eventhook/src/api/mod.rs:46-56`)

```rust
let base_url = std::env::var("FLOVYN_BASE_URL")
    .unwrap_or_else(|_| "https://api.flovyn.io/api/orgs".to_string());
```

**Issues:**
- Fallback domain is wrong (`flovyn.io` → should be `flovyn.ai`)
- Environment variable exists but is undocumented

## Proposed Solution

### Fix 1: Configurable Event Type Extraction

Add per-source configuration for event type extraction.

#### Domain Model Changes

```rust
// flovyn-server/plugins/eventhook/src/domain/source.rs

pub struct WebhookSource {
    // ... existing fields ...

    /// Optional configuration for extracting event type
    pub event_type_config: Option<EventTypeConfig>,
}

/// Configuration for extracting event type from incoming webhooks.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventTypeConfig {
    /// Header name to extract event type from (e.g., "X-Shopify-Topic")
    pub header_name: Option<String>,

    /// JMESPath expression to extract event type from the body.
    /// Examples: "type", "data.event.type", "items[0].event_type"
    /// Uses the same JMESPath library already used for input transforms.
    pub jmespath: Option<String>,
}
```

#### Extraction Logic

Update `extract_event_type` to accept source config:

```rust
fn extract_event_type(
    headers: &HeaderMap,
    body: &[u8],
    config: Option<&EventTypeConfig>,
) -> Option<String> {
    // 1. If source has custom config, use it first
    if let Some(cfg) = config {
        // Try custom header
        if let Some(header_name) = &cfg.header_name {
            if let Some(v) = headers.get(header_name.as_str()).and_then(|v| v.to_str().ok()) {
                return Some(v.to_string());
            }
        }

        // Try JMESPath expression (reuses existing JmespathTransformer)
        if let Some(expr) = &cfg.jmespath {
            if let Some(v) = extract_event_type_jmespath(body, expr) {
                return Some(v);
            }
        }
    }

    // 2. Fall back to default extraction (existing logic)
    // GitHub: X-GitHub-Event
    if let Some(v) = headers.get("x-github-event").and_then(|v| v.to_str().ok()) {
        return Some(v.to_string());
    }

    // Body fields: type, event_type, eventType
    if let Ok(json) = serde_json::from_slice::<serde_json::Value>(body) {
        if let Some(t) = json.get("type").and_then(|v| v.as_str()) {
            return Some(t.to_string());
        }
        if let Some(t) = json.get("event_type").and_then(|v| v.as_str()) {
            return Some(t.to_string());
        }
        if let Some(t) = json.get("eventType").and_then(|v| v.as_str()) {
            return Some(t.to_string());
        }
    }

    None
}

/// Extract event type from body using JMESPath expression.
/// Reuses the existing JmespathTransformer from the transform module.
fn extract_event_type_jmespath(body: &[u8], expression: &str) -> Option<String> {
    let json: serde_json::Value = serde_json::from_slice(body).ok()?;
    let transformer = JmespathTransformer::new(expression).ok()?;
    let result = transformer.transform(&json).ok()?;
    result.as_str().map(|s| s.to_string())
}
```

#### Database Schema Change

```sql
-- Add event_type_config column to webhook sources
ALTER TABLE p_eventhook__sources
ADD COLUMN event_type_config JSONB;
```

#### API Changes

Update create/update source endpoints to accept `eventTypeConfig`:

```typescript
// Request body - using custom header
{
  "slug": "shopify",
  "name": "Shopify Webhooks",
  "provider": "custom",
  "verifierConfig": { ... },
  "eventTypeConfig": {
    "headerName": "X-Shopify-Topic"
  }
}

// Using JMESPath expression for body extraction
{
  "eventTypeConfig": {
    "jmespath": "event.type"  // Extract from body.event.type
  }
}

// Or with nested paths and array access
{
  "eventTypeConfig": {
    "jmespath": "data.attributes.event_type"
  }
}

// Or both (header takes precedence)
{
  "eventTypeConfig": {
    "headerName": "X-Event-Type",
    "jmespath": "data.event_type"
  }
}
```

#### Generic Validation Endpoints

Add reusable validation endpoints for JMESPath and JavaScript expressions. These can be used by event type extraction, input transforms, filters, and any future features.

**JMESPath Validation:**
```
POST /api/orgs/{org_slug}/eventhook/validate/jmespath
```

Request:
```typescript
{
  "expression": "data.event.type",
  "input": {"data": {"event": {"type": "order.created"}}}  // Optional test input
}
```

Response:
```typescript
{
  "valid": true,
  "result": "order.created",  // Result if input was provided
  "error": null
}
```

**JavaScript Validation:**
```
POST /api/orgs/{org_slug}/eventhook/validate/javascript
```

Request:
```typescript
{
  "script": "function transform(event) { return { type: event.data.type }; }",
  "functionName": "transform",  // "transform" | "filter"
  "input": {"data": {"type": "order.created"}}  // Optional test input
}
```

Response:
```typescript
{
  "valid": true,
  "result": {"type": "order.created"},  // Result if input was provided
  "error": null
}
```

These generic endpoints can be reused by:
- Event type extraction configuration
- Route input transforms
- Route filters
- Schedules
- Any future JMESPath/JavaScript features

### Fix 2: Correct the Fallback Domain

Change the fallback from `api.flovyn.io` to `api.flovyn.ai`:

```rust
let base_url = std::env::var("FLOVYN_BASE_URL")
    .unwrap_or_else(|_| "https://api.flovyn.ai/api/orgs".to_string());
```

### Fix 3: Document Environment Variable

Add `FLOVYN_BASE_URL` to dev environment:

```env
# dev/.env
FLOVYN_BASE_URL=http://localhost:8000/api/orgs
```

Document in deployment guides for self-hosted setups.

## Architecture Decisions

**Note:** We are at MVP stage - backward compatibility is not a concern.

### AD1: Optional Configuration with Sensible Defaults

**Decision:** `event_type_config` is optional. When not set, use existing default extraction logic.

**Rationale:**
- GitHub/Stripe sources don't need configuration (detected automatically)
- Only custom providers need explicit configuration

### AD2: Reuse JMESPath for Body Extraction

**Decision:** Use JMESPath expressions for body extraction, reusing the existing `JmespathTransformer`.

**Rationale:**
- JMESPath is already used in eventhook plugin for input transforms
- No new dependencies needed (`jmespath` crate already in Cargo.toml)
- Consistent with existing patterns in the codebase
- Powerful expression syntax (arrays, filters, functions) already available

### AD3: Header Precedence Over JSON Path

**Decision:** When both `headerName` and `jsonPath` are configured, check header first.

**Rationale:** Headers are cheaper to check (no JSON parsing needed), and most providers use headers for event type.

### AD4: Source-Specific Config Takes Precedence Over Defaults

**Decision:** If source has `event_type_config`, use it exclusively before falling back to defaults.

**Rationale:** User explicitly configured extraction rules - respect their configuration. Fall back to defaults only if custom extraction fails.

## Scope

### In Scope (Phase 1: Server)
- Add `EventTypeConfig` to `WebhookSource` domain model
- Add database migration for `event_type_config` column
- Update `extract_event_type` to use per-source config with JMESPath
- Update create/update source API to accept `eventTypeConfig`
- Add generic validation endpoints for JMESPath and JavaScript
- Fix fallback domain typo (`flovyn.io` → `flovyn.ai`)
- Document `FLOVYN_BASE_URL` in dev environment
- Add unit tests for configurable extraction

### In Scope (Phase 2: Frontend)
Per the GitHub issue: "Once the fix is done, we should improve the frontend after that."

- Add `eventTypeConfig` fields to source create/edit forms
- Use generic validation endpoints to test JMESPath/JS before saving
- Show configured extraction method in source details
- Verify event type displays correctly in events data grid

## Testing Strategy

1. **Unit tests** for `extract_event_type`:
   - No config: uses defaults (GitHub header, body fields)
   - Header config only: extracts from custom header
   - JMESPath config only: extracts from nested JSON
   - Both configured: header takes precedence
   - Invalid JMESPath: falls back gracefully

2. **Unit tests** for `extract_event_type_jmespath`:
   - Simple path: `type` → extracts `body.type`
   - Nested path: `data.event.type` → extracts nested field
   - Array access: `items[0].type` → extracts from array
   - Missing field: returns None
   - Non-string result: returns None

3. **Integration tests**:
   - Create source with eventTypeConfig
   - Send webhook with custom header
   - Verify event has correct event_type
   - Test JMESPath validation endpoint with valid/invalid expressions
   - Test JavaScript validation endpoint with valid/invalid scripts

4. **E2E tests**:
   - Frontend can configure event type extraction
   - Events display correct event type

## Open Questions

None - solution is well-defined based on the bug investigation.

## References

- Bug investigation: `dev/docs/bugs/20260120_webhook_ingest_issues.md`
- Current implementation: `flovyn-server/plugins/eventhook/src/api/ingest.rs`
- Source domain: `flovyn-server/plugins/eventhook/src/domain/source.rs`
- URL construction: `flovyn-server/plugins/eventhook/src/api/mod.rs`
- JMESPath transformer: `flovyn-server/plugins/eventhook/src/service/transform_jmespath.rs`
