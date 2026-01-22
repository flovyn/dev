# Fix Webhook Issues: Implementation Plan

**Date:** 2026-01-21
**Design Reference:** [Design Document](../design/20260121_fix_webhook_issues.md)
**Status:** Completed

## Overview

This plan implements three fixes for the webhook ingest endpoint:
1. **Configurable event type extraction** - Allow per-source configuration for extracting event type from headers or JSON body
2. **Fix fallback domain** - Change `api.flovyn.io` to `api.flovyn.ai`
3. **Document `FLOVYN_BASE_URL`** - Add to dev environment for localhost development

Additionally, we'll add generic validation endpoints for JMESPath and JavaScript expressions.

---

## Implementation Phases

### Phase 1: Quick Fixes (Domain + URL)

Simple changes that can be verified immediately.

#### 1.1 Fix Fallback Domain

**File:** `flovyn-server/plugins/eventhook/src/api/mod.rs:48-49`

- [x] Change fallback from `https://api.flovyn.io/api/orgs` to `https://api.flovyn.ai/api/orgs`

**Verification:**
```bash
grep -n "flovyn.io" flovyn-server/plugins/eventhook/src
```
Should return no results after the fix.

#### 1.2 Add FLOVYN_BASE_URL to Dev Environment

**File:** `dev/.env`

- [x] Add `FLOVYN_BASE_URL=http://localhost:8002/api/orgs` (use the worktree's SERVER_HTTP_PORT)

**Note:** This should be documented as environment-specific. For production, it's `https://api.flovyn.ai/api/orgs`.

---

### Phase 2: Domain Model Changes

#### 2.1 Add EventTypeConfig to Domain

**File:** `flovyn-server/plugins/eventhook/src/domain/source.rs`

- [x] Add `EventTypeConfig` struct with `header_name` and `jmespath` fields
- [x] Add `event_type_config: Option<EventTypeConfig>` field to `WebhookSource`

```rust
/// Configuration for extracting event type from incoming webhooks.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventTypeConfig {
    /// Header name to extract event type from (e.g., "X-Shopify-Topic")
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header_name: Option<String>,

    /// JMESPath expression to extract event type from the body.
    /// Examples: "type", "data.event.type", "items[0].event_type"
    #[serde(skip_serializing_if = "Option::is_none")]
    pub jmespath: Option<String>,
}
```

---

### Phase 3: Database Migration

**File:** `flovyn-server/plugins/eventhook/migrations/20260121HHMMSS_event_type_config.up.sql`

**Note:** Use actual timestamp when creating the file.

- [x] Create migration to add `event_type_config` JSONB column to `p_eventhook__source`

```sql
-- Add event_type_config column to webhook sources
ALTER TABLE p_eventhook__source
ADD COLUMN event_type_config JSONB;
```

- [x] Create corresponding `.down.sql` migration

```sql
ALTER TABLE p_eventhook__source
DROP COLUMN IF EXISTS event_type_config;
```

- [x] Run migration: `cd flovyn-server && ./bin/dev/migrate.sh`
- [x] Verify schema: `mise run db-server` then `\d p_eventhook__source`

---

### Phase 4: Repository Updates

**File:** `flovyn-server/plugins/eventhook/src/repository/source_repository.rs`

#### 4.1 Update Create Method

- [x] Add `event_type_config: Option<&EventTypeConfig>` parameter to `create()`
- [x] Serialize and insert the new column

#### 4.2 Update Row Mapping

- [x] Update `row_to_source()` to read `event_type_config` column
- [x] Add field to SELECT queries in `find_by_slug()`, `find_by_id()`, `list()`

#### 4.3 Update Update Method

- [x] Update `update()` to persist `event_type_config` field

---

### Phase 5: Event Type Extraction Logic (Test-First)

#### 5.1 Write Tests First

**File:** `flovyn-server/plugins/eventhook/src/api/ingest.rs` (add test module)

- [x] `test_extract_event_type_no_config_github_header` - Uses X-GitHub-Event when no config
- [x] `test_extract_event_type_no_config_body_type` - Uses body.type when no config, no GitHub header
- [x] `test_extract_event_type_no_config_body_event_type` - Uses body.event_type
- [x] `test_extract_event_type_no_config_body_eventType` - Uses body.eventType (camelCase)
- [x] `test_extract_event_type_custom_header` - Uses configured header name
- [x] `test_extract_event_type_custom_jmespath` - Uses configured JMESPath expression
- [x] `test_extract_event_type_custom_header_takes_precedence` - Header checked before JMESPath
- [x] `test_extract_event_type_fallback_on_missing` - Falls back to defaults if custom config fails
- [x] `test_extract_event_type_jmespath_nested` - Nested path like `data.event.type`
- [x] `test_extract_event_type_jmespath_invalid` - Invalid expression returns None gracefully

**Run tests:** `cargo test -p flovyn-plugin-eventhook extract_event_type`

#### 5.2 Update extract_event_type Function

**File:** `flovyn-server/plugins/eventhook/src/api/ingest.rs:269-290`

- [x] Update signature: `fn extract_event_type(headers: &HeaderMap, body: &[u8], config: Option<&EventTypeConfig>) -> Option<String>`
- [x] Add custom header extraction when `config.header_name` is set
- [x] Add JMESPath extraction when `config.jmespath` is set (reuse `JmespathTransformer`)
- [x] Keep existing default extraction as fallback

#### 5.3 Add JMESPath Extraction Helper

**File:** `flovyn-server/plugins/eventhook/src/api/ingest.rs`

- [x] Add `extract_event_type_jmespath()` function using existing `JmespathTransformer`
- [x] Handle non-string results (return None)
- [x] Handle invalid expressions gracefully (return None)

---

### Phase 6: Update Ingest Handler

**File:** `flovyn-server/plugins/eventhook/src/api/ingest.rs:159`

- [x] Pass `source.event_type_config.as_ref()` to `extract_event_type()`

**Current:**
```rust
let event_type = extract_event_type(&headers, &body);
```

**Updated:**
```rust
let event_type = extract_event_type(&headers, &body, source.event_type_config.as_ref());
```

---

### Phase 7: API DTOs

**File:** `flovyn-server/plugins/eventhook/src/api/dto.rs`

#### 7.1 Add EventTypeConfig DTOs

- [x] Add `EventTypeConfigRequest` struct for create/update requests
- [x] Add `EventTypeConfigResponse` struct for responses (same structure)

```rust
/// Event type extraction configuration for requests.
#[derive(Debug, Clone, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct EventTypeConfigRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub jmespath: Option<String>,
}

/// Event type extraction configuration for responses.
#[derive(Debug, Clone, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct EventTypeConfigResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub jmespath: Option<String>,
}
```

#### 7.2 Update Source DTOs

- [x] Add `event_type_config: Option<EventTypeConfigRequest>` to `CreateSourceRequest`
- [x] Add `event_type_config: Option<EventTypeConfigRequest>` to `UpdateSourceRequest`
- [x] Add `event_type_config: Option<EventTypeConfigResponse>` to `SourceDetailResponse`

---

### Phase 8: API Handlers

**File:** `flovyn-server/plugins/eventhook/src/api/handlers/sources.rs`

#### 8.1 Update create_source

- [x] Extract `event_type_config` from request
- [x] Validate JMESPath expression if provided (compile test)
- [x] Pass to repository `create()` method

#### 8.2 Update update_source

- [x] Handle `event_type_config` field in update request
- [x] Validate JMESPath expression if provided
- [x] Update `source.event_type_config` before saving

#### 8.3 Update Response Mapping

- [x] Update `source_to_detail_response()` to include `event_type_config`
- [x] Add conversion from domain `EventTypeConfig` to `EventTypeConfigResponse`

---

### Phase 9: Generic Validation Endpoints

Add reusable validation endpoints for JMESPath and JavaScript expressions.

#### 9.1 JMESPath Validation Endpoint

**File:** `flovyn-server/plugins/eventhook/src/api/handlers/validate.rs` (new file)

- [x] Create `ValidateJmespathRequest` DTO with `expression` and optional `input`
- [x] Create `ValidateJmespathResponse` DTO with `valid`, `result`, and `error`
- [x] Implement `validate_jmespath` handler
- [x] Compile expression to check syntax
- [x] Execute against input if provided

```rust
/// POST /api/orgs/{org_slug}/eventhook/validate/jmespath
pub async fn validate_jmespath(
    Path(org_slug): Path<String>,
    Json(request): Json<ValidateJmespathRequest>,
) -> Result<Json<ValidateJmespathResponse>, HandlerError>
```

#### 9.2 JavaScript Validation Endpoint

- [x] Create `ValidateJavascriptRequest` DTO with `script`, `function_name`, and optional `input`
- [x] Create `ValidateJavascriptResponse` DTO with `valid`, `result`, and `error`
- [x] Implement `validate_javascript` handler
- [x] Validate function exists and syntax is correct
- [x] Execute against input if provided (with timeout protection)

```rust
/// POST /api/orgs/{org_slug}/eventhook/validate/javascript
pub async fn validate_javascript(
    Path(org_slug): Path<String>,
    Json(request): Json<ValidateJavascriptRequest>,
) -> Result<Json<ValidateJavascriptResponse>, HandlerError>
```

#### 9.3 Register Validation Routes

**File:** `flovyn-server/plugins/eventhook/src/api/mod.rs`

- [x] Create validation routes router
- [x] Add `POST /validate/jmespath` route
- [x] Add `POST /validate/javascript` route
- [x] Merge into main router

---

### Phase 10: OpenAPI Updates

**File:** `flovyn-server/plugins/eventhook/src/api/openapi.rs`

- [x] Register `EventTypeConfigRequest` schema
- [x] Register `EventTypeConfigResponse` schema
- [x] Register `ValidateJmespathRequest` schema
- [x] Register `ValidateJmespathResponse` schema
- [x] Register `ValidateJavascriptRequest` schema
- [x] Register `ValidateJavascriptResponse` schema
- [x] Add validation endpoints to paths

**Verify:**
```bash
cargo build -p flovyn-server --features plugin-eventhook
./target/debug/export-openapi | jq '.paths | keys | map(select(contains("validate")))'
```

---

### Phase 11: Integration Tests

**File:** `flovyn-server/tests/integration/eventhook_event_type_tests.rs` (new file)

#### 11.1 Event Type Config Tests

- [x] `test_create_source_with_event_type_config` - Source created with config, config persisted
- [x] `test_update_source_event_type_config` - Config can be updated
- [x] `test_ingest_with_custom_header` - Event type extracted from custom header
- [x] `test_ingest_with_jmespath` - Event type extracted via JMESPath
- [x] `test_ingest_fallback_to_defaults` - Falls back when custom config doesn't match

#### 11.2 Validation Endpoint Tests

- [x] `test_validate_jmespath_valid` - Valid expression returns success
- [x] `test_validate_jmespath_invalid` - Invalid expression returns error
- [x] `test_validate_jmespath_with_input` - Returns transformed result
- [x] `test_validate_javascript_valid` - Valid script returns success
- [x] `test_validate_javascript_invalid` - Syntax error returns error
- [x] `test_validate_javascript_with_input` - Returns execution result

**Run:** `cargo test --test integration eventhook_event_type`

---

### Phase 12: Final Verification

#### 12.1 Run All Tests

```bash
# Unit tests
cargo test -p flovyn-plugin-eventhook

# Integration tests (requires Docker)
cargo test --features plugin-eventhook --test integration

# Build with plugin
cargo build --features plugin-eventhook
```

- [x] All unit tests pass
- [x] All integration tests pass
- [x] No clippy warnings: `cargo clippy -p flovyn-plugin-eventhook`
- [x] Code formatted: `cargo fmt --check`

#### 12.2 Manual Verification

Start dev environment and test:

```bash
# Start services
cd dev && mise run start
mise run server

# Create source with event type config
curl -X POST http://localhost:8002/api/orgs/dev/eventhook/sources \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer flovyn_sk_dev_admin" \
  -d '{
    "slug": "shopify-test",
    "name": "Shopify Test",
    "provider": "custom",
    "verifierConfig": {"type": "none"},
    "eventTypeConfig": {
      "headerName": "X-Shopify-Topic"
    }
  }'

# Send webhook with custom header
curl -X POST http://localhost:8002/api/orgs/dev/eventhook/in/shopify-test \
  -H "Content-Type: application/json" \
  -H "X-Shopify-Topic: orders/create" \
  -d '{"order_id": "12345"}'

# Verify event has correct event_type
curl http://localhost:8002/api/orgs/dev/eventhook/events \
  -H "Authorization: Bearer flovyn_sk_dev_admin" | jq '.events[0].eventType'
# Should return "orders/create"
```

- [x] Ingest URL in responses shows correct domain
- [x] Event type extracted from custom header
- [x] Validation endpoints work

#### 12.3 Update Documentation

- [x] Update design document status to "Implemented"
- [x] Update this plan status to "Completed"

---

## File Changes Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `plugins/eventhook/src/api/mod.rs` | MODIFY | Fix fallback URL, add validation routes |
| `plugins/eventhook/src/domain/source.rs` | MODIFY | Add `EventTypeConfig`, add field to `WebhookSource` |
| `plugins/eventhook/src/repository/source_repository.rs` | MODIFY | Handle new `event_type_config` column |
| `plugins/eventhook/src/api/ingest.rs` | MODIFY | Update `extract_event_type()` to use config |
| `plugins/eventhook/src/api/dto.rs` | MODIFY | Add EventTypeConfig DTOs, update source DTOs |
| `plugins/eventhook/src/api/handlers/sources.rs` | MODIFY | Handle eventTypeConfig in create/update |
| `plugins/eventhook/src/api/handlers/validate.rs` | NEW | Validation endpoints |
| `plugins/eventhook/src/api/handlers/mod.rs` | MODIFY | Export validate module |
| `plugins/eventhook/src/api/openapi.rs` | MODIFY | Register new schemas and paths |
| `plugins/eventhook/migrations/20260121*_event_type_config.up.sql` | NEW | Add column |
| `plugins/eventhook/migrations/20260121*_event_type_config.down.sql` | NEW | Drop column |
| `dev/.env` | MODIFY | Add `FLOVYN_BASE_URL` |

---

## Test Plan

### Unit Tests (Phase 5)

| Test | Description | Expected Result |
|------|-------------|-----------------|
| `test_extract_event_type_no_config_github_header` | No config, X-GitHub-Event header present | Returns header value |
| `test_extract_event_type_no_config_body_type` | No config, body has `type` field | Returns body.type |
| `test_extract_event_type_custom_header` | Config with headerName, header present | Returns header value |
| `test_extract_event_type_custom_jmespath` | Config with jmespath, matching path | Returns extracted value |
| `test_extract_event_type_custom_header_takes_precedence` | Both configured, header present | Returns header (not jmespath) |
| `test_extract_event_type_fallback_on_missing` | Custom config, but no match | Falls back to defaults |

### Integration Tests (Phase 11)

| Test | Description | Expected Result |
|------|-------------|-----------------|
| `test_create_source_with_event_type_config` | Create source with eventTypeConfig | Config persisted and returned |
| `test_ingest_with_custom_header` | Send webhook with custom header | Event has correct event_type |
| `test_validate_jmespath_valid` | Validate valid expression | `valid: true` |
| `test_validate_jmespath_invalid` | Validate invalid expression | `valid: false, error: "..."` |

---

## Exit Criteria Checklist

### Fix 1: Configurable Event Type Extraction
- [x] `EventTypeConfig` domain model added
- [x] Database migration created and applied
- [x] Repository handles new field
- [x] `extract_event_type()` uses per-source config
- [x] Custom header extraction works
- [x] JMESPath extraction works
- [x] Fallback to defaults when config doesn't match
- [x] API accepts `eventTypeConfig` on create/update
- [x] API returns `eventTypeConfig` in source details

### Fix 2: Correct Fallback Domain
- [x] Fallback URL changed to `api.flovyn.ai`
- [x] No occurrences of `flovyn.io` in eventhook plugin

### Fix 3: Document Environment Variable
- [x] `FLOVYN_BASE_URL` added to `dev/.env`

### Validation Endpoints
- [x] JMESPath validation endpoint works
- [x] JavaScript validation endpoint works
- [x] Both return validation errors for invalid input
- [x] Both execute with sample input when provided

### Tests
- [x] All unit tests pass
- [x] All integration tests pass
- [x] No clippy warnings

---

## Frontend Integration Guide

### 1. Configurable Event Type Extraction

When creating or updating a webhook source, the frontend can now specify how to extract the event type from incoming webhooks.

#### Create Source with Event Type Config

```http
POST /api/orgs/{org_slug}/eventhook/sources
```

```json
{
  "slug": "shopify-webhooks",
  "name": "Shopify Webhooks",
  "provider": "custom",
  "verifierConfig": { "type": "none" },
  "eventTypeConfig": {
    "headerName": "X-Shopify-Topic"
  }
}
```

Or using JMESPath for body extraction:

```json
{
  "slug": "custom-webhooks",
  "name": "Custom Webhooks",
  "eventTypeConfig": {
    "jmespath": "data.event.type"
  }
}
```

#### Update Existing Source

```http
PUT /api/orgs/{org_slug}/eventhook/sources/{source_slug}
```

```json
{
  "eventTypeConfig": {
    "headerName": "X-Event-Type",
    "jmespath": "metadata.eventName"
  }
}
```

#### Get Source Details (Response)

```http
GET /api/orgs/{org_slug}/eventhook/sources/{source_slug}
```

```json
{
  "id": "...",
  "slug": "shopify-webhooks",
  "name": "Shopify Webhooks",
  "eventTypeConfig": {
    "headerName": "X-Shopify-Topic",
    "jmespath": null
  },
  "ingestUrl": "http://localhost:8002/api/orgs/dev/eventhook/in/shopify-webhooks",
  ...
}
```

---

### 2. Validation Endpoints

Two new endpoints for validating expressions before saving:

#### Validate JMESPath Expression

```http
POST /api/orgs/{org_slug}/eventhook/validate/jmespath
```

**Request:**
```json
{
  "expression": "data.event.type",
  "input": {
    "data": {
      "event": {
        "type": "order.created"
      }
    }
  }
}
```

**Response (valid):**
```json
{
  "valid": true,
  "result": "order.created",
  "error": null
}
```

**Response (invalid):**
```json
{
  "valid": false,
  "result": null,
  "error": "Invalid JMESPath expression: ..."
}
```

#### Validate JavaScript Transform

```http
POST /api/orgs/{org_slug}/eventhook/validate/javascript
```

**Request:**
```json
{
  "script": "function transform(event) { return { orderId: event.body.id }; }",
  "functionName": "transform",
  "input": {
    "headers": {},
    "body": { "id": "ord_123", "total": 100 },
    "eventType": "order.created"
  }
}
```

**Response (valid):**
```json
{
  "valid": true,
  "result": { "orderId": "ord_123" },
  "error": null
}
```

---

### 3. Frontend UI Suggestions

1. **Source Creation Form** - Add optional "Event Type Config" section with:
   - Text input for "Header Name" (e.g., `X-Shopify-Topic`)
   - Text input for "JMESPath Expression" (e.g., `data.event.type`)
   - "Test" button that calls the validation endpoint

2. **Live Validation** - Call `/validate/jmespath` on blur/change to show real-time feedback

3. **Preview with Sample Data** - Let users paste sample webhook JSON and see extracted event type

4. **Ingest URL Display** - Now shows correct domain (`api.flovyn.ai` in production, configurable via `FLOVYN_BASE_URL` in dev)
