# Eventhook Milestone 2: Management API Implementation Plan

**Date:** 2026-01-03
**Design Reference:** [M2 Design Document](../design/20260103_eventhook_milestone2_management_api.md)
**Status:** ✅ Completed

## Overview

This plan implements the M2 Management API for the Eventhook plugin. The existing M1 implementation provides ingest endpoints, signature verification, and event processing. M2 adds full CRUD APIs for sources, routes, and events plus provider templates.

## Current State Summary

**Already implemented (M1):**
- Domain models: WebhookSource, WebhookRoute, WebhookEvent
- Database schema with all tables and indexes
- Ingest endpoint with signature verification
- Background event processor with retry logic
- Rate limiting per source

**Implemented in M2:**
- Repository methods for list, update, delete, stats
- DTOs for request/response objects
- API handlers for management endpoints
- Provider templates registry
- OpenAPI documentation (schemas registered)

---

## Implementation Phases

### Phase 1: Repository Extensions ✅

Extend existing repositories with methods needed for management operations.

#### 1.1 SourceRepository Extensions

**File:** `flovyn-server/plugins/eventhook/src/repository/source_repository.rs`

- [x] `list(tenant_id, filter)` - List sources with pagination
- [x] `update(source)` - Update source fields
- [x] `delete(tenant_id, slug)` - Delete source with cascade
- [x] `count_routes(source_id)` - Count associated routes
- [x] `get_stats(source_id)` - Event statistics (24h, 1h, failed)

#### 1.2 RouteRepository Extensions

**File:** `flovyn-server/plugins/eventhook/src/repository/route_repository.rs`

- [x] `find_by_id(id)` - Get single route by ID
- [x] `list_all_by_source(source_id, enabled_filter)` - List with optional filter
- [x] `update(route)` - Update route fields
- [x] `delete(id)` - Delete route
- [x] `update_priorities(updates)` - Batch update for reordering
- [x] `get_stats(route_id)` - Matched/executed/failed counts

#### 1.3 EventRepository Extensions

**File:** `flovyn-server/plugins/eventhook/src/repository/event_repository.rs`

- [x] `list(tenant_id, filter, limit, offset)` - List events with filters
- [x] `count(tenant_id, filter)` - Count matching events
- [x] `get_with_actions(event_id)` - Event with action details
- [x] `find_for_reprocess(tenant_id, filter, limit)` - Find reprocessable events
- [x] `reset_for_reprocess(ids)` - Reset status to PENDING

---

### Phase 2: DTOs and Validation ✅

#### 2.1 Request/Response DTOs

**File:** `flovyn-server/plugins/eventhook/src/api/dto.rs`

Source DTOs:
- [x] `SourceResponse` - List/get response (excludes secret)
- [x] `SourceDetailResponse` - Detailed with stats and config
- [x] `SourceStatsResponse` - Event statistics
- [x] `CreateSourceRequest` - Create with provider or verifier config
- [x] `UpdateSourceRequest` - Partial update fields
- [x] `TestSourceRequest` / `TestSourceResponse` - Verification test
- [x] `SourceListResponse` - Paginated list with total

Route DTOs:
- [x] `RouteResponse` - Route with stats
- [x] `RouteStatsResponse` - Matched/executed/failed counts
- [x] `CreateRouteRequest` - Create with target config
- [x] `UpdateRouteRequest` - Partial update fields
- [x] `ReorderRoutesRequest` / `RouteOrderItem` - Reordering
- [x] `RouteListResponse` - List wrapper

Event DTOs:
- [x] `EventResponse` - List item summary
- [x] `EventDetailResponse` - Full details with actions
- [x] `EventActionResponse` - Action details
- [x] `ReprocessEventsRequest` - By ID or filter
- [x] `ReprocessEventsResponse` - Result summary
- [x] `EventListResponse` - Paginated list with total

Provider DTOs:
- [x] `ProviderResponse` - Provider template info
- [x] `ProviderListResponse` - List wrapper

#### 2.2 VerifierConfig DTOs

- [x] `VerifierConfigRequest` - Input for verifier config
- [x] `VerifierConfigResponse` - Output (no secret)
- [x] `TargetConfigRequest` - Input for target config
- [x] `TargetConfigResponse` - Output for target config

#### 2.3 Add utoipa derives

- [x] Add `#[derive(ToSchema)]` to all DTOs
- [x] Query parameter structs with ToSchema

---

### Phase 3: Provider Templates ✅

#### 3.1 Provider Registry

**File:** `flovyn-server/plugins/eventhook/src/service/provider_templates.rs`

- [x] Define `ProviderTemplate` struct
- [x] Implement GitHub template (HMAC/SHA256, X-Hub-Signature-256)
- [x] Implement Stripe template (HMAC/SHA256, Stripe-Signature)
- [x] Implement Shopify template (HMAC/SHA256, X-Shopify-Hmac-Sha256, base64)
- [x] Implement Slack template (HMAC/SHA256, X-Slack-Signature, v0= prefix)
- [x] Implement Linear template (HMAC/SHA256, Linear-Signature)
- [x] Implement Twilio template (HMAC/SHA256, X-Twilio-Signature, base64)
- [x] `get_all_providers()` - List all templates
- [x] `get_provider(id)` - Get template by ID
- [x] `expand_provider(id, secret)` - Expand to full verifier config

#### 3.2 Integration with Source Creation

**File:** `flovyn-server/plugins/eventhook/src/service/mod.rs`

- [x] Export provider_templates module
- [x] Helper to expand provider template in CreateSourceRequest

---

### Phase 4: API Handlers - Sources ✅

#### 4.1 Sources Handler

**File:** `flovyn-server/plugins/eventhook/src/api/handlers/sources.rs`

- [x] `list_sources` - GET /sources with pagination and enabled filter
- [x] `create_source` - POST /sources with provider expansion
- [x] `get_source` - GET /sources/:slug with stats
- [x] `update_source` - PUT /sources/:slug partial update
- [x] `delete_source` - DELETE /sources/:slug cascade delete
- [x] `test_source` - POST /sources/:slug/test verification test

---

### Phase 5: API Handlers - Routes ✅

#### 5.1 Routes Handler

**File:** `flovyn-server/plugins/eventhook/src/api/handlers/routes.rs`

- [x] `list_routes` - GET /sources/:slug/routes
- [x] `create_route` - POST /sources/:slug/routes
- [x] `get_route` - GET /sources/:slug/routes/:id
- [x] `update_route` - PUT /sources/:slug/routes/:id
- [x] `delete_route` - DELETE /sources/:slug/routes/:id
- [x] `reorder_routes` - PUT /sources/:slug/routes/reorder

---

### Phase 6: API Handlers - Events ✅

#### 6.1 Events Handler

**File:** `flovyn-server/plugins/eventhook/src/api/handlers/events.rs`

- [x] `list_events` - GET /events with filters
- [x] `get_event` - GET /events/:id with actions
- [x] `get_event_payload` - GET /events/:id/payload raw bytes
- [x] `reprocess_events` - POST /events/reprocess

---

### Phase 7: API Handlers - Providers ✅

#### 7.1 Providers Handler

**File:** `flovyn-server/plugins/eventhook/src/api/handlers/providers.rs`

- [x] `list_providers` - GET /providers

---

### Phase 8: Route Registration and OpenAPI ✅

#### 8.1 Route Registration

**File:** `flovyn-server/plugins/eventhook/src/api/mod.rs`

- [x] Create nested routers for different state types
- [x] Mount sources routes
- [x] Mount routes routes (nested under sources)
- [x] Mount events routes
- [x] Mount providers route
- [x] Merge all routers together

#### 8.2 OpenAPI Documentation

**File:** `flovyn-server/plugins/eventhook/src/api/openapi.rs`

- [x] Create `EventhookApiDoc` struct with OpenApi derive
- [x] Register all DTOs in components/schemas
- [x] Define tags (Sources, Routes, Events, Providers)

#### 8.3 Plugin Integration

**File:** `flovyn-server/plugins/eventhook/src/lib.rs`

- [x] Merge management routes into plugin routes
- [x] Implement `openapi()` method to return plugin OpenAPI spec

---

### Phase 9: Final Integration and Cleanup ✅

#### 9.1 Compilation and Testing

- [x] Code compiles without errors
- [x] All 15 unit tests pass
- [x] Full test suite (113 integration tests) pass

#### 9.2 Code Quality

- [x] No clippy warnings (dead_code allowed for utility functions)
- [x] Repository methods properly handle errors
- [x] Handler error responses are consistent

---

## Testing Strategy

### Unit Tests (15 passing)
- Provider template expansion
- Event type matching (wildcard, prefix, suffix)
- Rate limiter behavior
- HMAC/API key verification

### Integration Tests
- Full test suite runs successfully with plugin enabled

### Test Command
```bash
# Run eventhook plugin tests
cargo test -p flovyn-plugin-eventhook

# Run with plugin feature enabled
cargo test --features plugin-eventhook
```

---

## File Structure Summary

```
plugins/eventhook/src/
├── api/
│   ├── mod.rs           # Routes registration with nested routers
│   ├── dto.rs           # All DTOs with ToSchema derives
│   ├── openapi.rs       # OpenAPI schema registration
│   ├── ingest.rs        # EXISTS - No changes
│   └── handlers/
│       ├── mod.rs       # ApiError, HandlerError types
│       ├── sources.rs   # Source CRUD handlers
│       ├── routes.rs    # Route CRUD handlers
│       ├── events.rs    # Event list/reprocess handlers
│       └── providers.rs # Provider list handler
├── service/
│   ├── mod.rs           # Exports provider_templates
│   ├── provider_templates.rs  # 6 provider templates
│   ├── processor.rs     # EXISTS - No changes
│   ├── verifier.rs      # EXISTS - No changes
│   └── rate_limiter.rs  # EXISTS - No changes
├── repository/
│   ├── source_repository.rs  # Extended with CRUD methods
│   ├── route_repository.rs   # Extended with CRUD methods
│   └── event_repository.rs   # Extended with list/reprocess methods
└── domain/              # EXISTS - No changes
```

---

## Exit Criteria ✅

M2 implementation is complete with:

- **Sources API:** All 6 operations implemented (list, create, get, update, delete, test)
- **Routes API:** All 6 operations implemented (list, create, get, update, delete, reorder)
- **Events API:** All 4 operations implemented (list, get, get_payload, reprocess)
- **Provider Templates:** 6 providers (GitHub, Stripe, Shopify, Slack, Linear, Twilio)
- **OpenAPI:** Schema definitions registered, plugin provides openapi() method

Note: utoipa path annotations for individual handlers to be added in follow-up for complete API documentation.
