# Implementation Plan: Eventhook Milestone 1 - Receive & Route

**Date:** 2026-01-01
**Status:** In Progress
**Design:** [M1 Design](../design/20250101_eventhook_milestone1_receive_route.md)
**Prerequisites:** M0 complete (FlovynEvent, EventPublisher infrastructure - ✅ verified in `server/src/streaming/`)

## Overview

This plan implements webhook reception and routing as defined in the M1 design document. Reference the design doc for architecture diagrams, API contracts, and schema definitions.

## Phase 1: Plugin Skeleton & Infrastructure

### Goal
Create the eventhook plugin structure with feature flag and empty registration.

### TODO List
- [ ] Create `flovyn-server/plugins/eventhook/Cargo.toml` with required dependencies
- [ ] Create `flovyn-server/plugins/eventhook/src/lib.rs` with `EventhookPlugin` struct implementing `Plugin` trait
- [ ] Add `flovyn-plugin-eventhook` to workspace in root `Cargo.toml`
- [ ] Add `plugin-eventhook` feature flag to `flovyn-server/server/Cargo.toml`
- [ ] Register plugin in `flovyn-server/server/src/plugin/registry.rs` under feature flag
- [ ] Verify: `cargo check --features plugin-eventhook` passes

### Files to Create/Modify
```
plugins/eventhook/
├── Cargo.toml
└── src/
    └── lib.rs

Cargo.toml                 (workspace member)
server/Cargo.toml          (feature flag + dependency)
server/src/plugin/registry.rs  (conditional registration)
```

---

## Phase 2: Database Schema & Migrations

### Goal
Create the 4 database tables: source, route, event, event_action.

### TODO List
- [ ] Create `flovyn-server/plugins/eventhook/migrations/20260101000001_init.up.sql` with all tables
- [ ] Create `flovyn-server/plugins/eventhook/migrations/20260101000001_init.down.sql`
- [ ] Update `EventhookPlugin::migrations()` to use `flovyn_plugin::plugin_migrations!()`
- [ ] Verify: Run server with plugin enabled, tables created in database

### Tables (from design doc)
- `p_eventhook__source` - Webhook sources with verification config
- `p_eventhook__route` - Routing rules from source to targets
- `p_eventhook__event` - Received webhook events
- `p_eventhook__event_action` - Actions taken per event

---

## Phase 3: Domain Types & Repositories

### Goal
Create domain entities and repository layer.

### TODO List
- [ ] Create `flovyn-server/src/domain/mod.rs` with module declarations
- [ ] Create `flovyn-server/src/domain/source.rs` - `WebhookSource` entity, `NewWebhookSource`
- [ ] Create `flovyn-server/src/domain/route.rs` - `WebhookRoute` entity, `TargetType` enum, `TargetConfig`
- [ ] Create `flovyn-server/src/domain/event.rs` - `WebhookEvent` entity, `EventStatus` enum
- [ ] Create `flovyn-server/src/domain/event_action.rs` - `WebhookEventAction` entity, `ActionStatus` enum
- [ ] Create `flovyn-server/src/domain/verifier.rs` - `VerifierConfig` enum (Hmac, BasicAuth, ApiKey, None)
- [ ] Create `flovyn-server/src/repository/mod.rs` with module declarations
- [ ] Create `flovyn-server/src/repository/source_repository.rs` with CRUD operations
- [ ] Create `flovyn-server/src/repository/route_repository.rs` with `find_by_source` ordering by priority
- [ ] Create `flovyn-server/src/repository/event_repository.rs` with status update methods
- [ ] Create `flovyn-server/src/repository/event_action_repository.rs`
- [ ] Write unit tests for domain type serialization (VerifierConfig, TargetConfig)

### Repository Methods Needed
```rust
// SourceRepository
find_by_slug(tenant_id, slug) -> Option<WebhookSource>
find_enabled_by_slug(tenant_id, slug) -> Option<WebhookSource>

// RouteRepository
find_enabled_by_source(source_id) -> Vec<WebhookRoute>  // ordered by priority DESC

// EventRepository
create(NewEvent) -> Uuid
update_verification(id, verified, error) -> ()
update_parsed(id, parsed, event_type) -> ()
update_status(id, status) -> ()

// EventActionRepository
create(NewEventAction) -> Uuid
update_success(id, target_result) -> ()
update_failed(id, error) -> ()
```

---

## Phase 4: Signature Verification

### Goal
Implement HMAC, API key, and basic auth verification.

### TODO List
- [ ] Create `flovyn-server/src/service/verifier.rs` with `Verifier` trait
- [ ] Implement `HmacVerifier` with constant-time comparison
- [ ] Implement `BasicAuthVerifier`
- [ ] Implement `ApiKeyVerifier`
- [ ] Create `VerifyError` enum with variants: MissingHeader, InvalidHeader, InvalidSignature, InvalidPrefix
- [ ] Write unit tests: `test_hmac_verify_github_signature` (sha256, hex, "sha256=" prefix)
- [ ] Write unit tests: `test_hmac_verify_stripe_signature`
- [ ] Write unit tests: `test_hmac_verify_invalid_signature`
- [ ] Write unit tests: `test_api_key_verify_success`, `test_api_key_verify_missing_header`
- [ ] Write unit tests: `test_basic_auth_verify_success`, `test_basic_auth_verify_wrong_password`

### Dependencies to Add
```toml
hmac.workspace = true
sha2.workspace = true
sha-1.workspace = true  # For legacy SHA1 support
base64.workspace = true
hex.workspace = true
subtle.workspace = true  # For constant_time_eq
```

---

## Phase 5: Target Execution

### Goal
Implement workflow, task, and promise targets.

### TODO List
- [ ] Create `flovyn-server/src/target/mod.rs` with module declarations and `TargetResult` enum
- [ ] Create `flovyn-server/src/target/workflow.rs` - `WorkflowTarget::execute()`
- [ ] Create `flovyn-server/src/target/task.rs` - `TaskTarget::execute()`
- [ ] Create `flovyn-server/src/target/promise.rs` - `PromiseTarget::execute()`
- [ ] Write unit tests: `test_workflow_target_config_deserialization`
- [ ] Write unit tests: `test_task_target_config_deserialization`
- [ ] Write unit tests: `test_promise_target_extract_id_from_path`

### Integration Points
- WorkflowTarget needs: `WorkflowExecutionRepository`, `WorkerNotifier`
- TaskTarget needs: `TaskExecutionRepository`, `WorkerNotifier` (standalone task creation)
- PromiseTarget needs: `PromiseRepository`

---

## Phase 6: Event Processing Service

### Goal
Implement route matching and event processing.

### TODO List
- [ ] Create `flovyn-server/src/service/mod.rs` with module declarations
- [ ] Create `flovyn-server/src/service/processor.rs` - `EventProcessor` struct
- [ ] Implement `process(event_id, source, payload)` method
- [ ] Implement `matches_route(route, payload)` - event type filtering
- [ ] Implement `extract_event_type(payload)` - try common paths
- [ ] Write unit tests: `test_route_matches_event_type`
- [ ] Write unit tests: `test_route_matches_all_events_when_no_filter`
- [ ] Write unit tests: `test_route_no_match_wrong_type`
- [ ] Write unit tests: `test_extract_event_type_stripe` (from /type)
- [ ] Write unit tests: `test_extract_event_type_github` (from /action)

---

## Phase 7: Ingest Endpoint

### Goal
Create the webhook reception HTTP endpoint.

### TODO List
- [ ] Create `flovyn-server/src/api/mod.rs` with router creation
- [ ] Create `flovyn-server/src/api/ingest.rs` with `receive_webhook` handler
- [ ] Create `EventhookState` struct with all required services
- [ ] Create `EventhookError` enum with proper HTTP status mappings
- [ ] Implement handler flow: lookup → store → verify → parse → process
- [ ] Mount router at `/api/tenants/{tenant_slug}/eventhook/in/{source_slug}`
- [ ] Ensure endpoint bypasses standard auth middleware
- [ ] Add OpenAPI documentation with `utoipa`
- [ ] Write integration test: `test_ingest_endpoint_returns_404_for_unknown_source`
- [ ] Write integration test: `test_ingest_endpoint_returns_401_for_invalid_signature`
- [ ] Write integration test: `test_ingest_endpoint_stores_event_on_success`

### Handler Response Codes
| Code | Condition |
|------|-----------|
| 200 | Event received and processing started |
| 400 | Invalid payload (parse error) |
| 401 | Signature verification failed |
| 404 | Tenant/source not found or source disabled |
| 500 | Internal error |

---

## Phase 8: Integration Tests

### Goal
End-to-end tests demonstrating webhook → target execution.

### TODO List
- [ ] Add test helper: `create_webhook_source(slug, verifier_config)` via direct DB insert
- [ ] Add test helper: `create_webhook_route(source_id, target_config, filter)`
- [ ] Add test helper: `compute_github_signature(secret, payload)`
- [ ] Write integration test: `test_webhook_triggers_workflow`
- [ ] Write integration test: `test_webhook_triggers_task`
- [ ] Write integration test: `test_webhook_resolves_promise`
- [ ] Write integration test: `test_webhook_event_type_filtering`
- [ ] Write integration test: `test_multiple_routes_executed_in_priority_order`
- [ ] Verify: All 11 exit criteria from design doc pass

### Test Strategy
Tests use testcontainers (PostgreSQL). Sources/routes created via direct DB inserts since Management API is M2 scope.

---

## Phase 9: Documentation & Cleanup

### Goal
Final polish and documentation.

### TODO List
- [ ] Add module-level documentation to all public modules
- [ ] Update `CLAUDE.md` with eventhook plugin info if needed
- [ ] Verify feature flag works: `cargo build --features plugin-eventhook`
- [ ] Verify feature flag off: `cargo build` (no eventhook code included)
- [ ] Run `cargo clippy --features plugin-eventhook` - no warnings
- [ ] Run `cargo fmt` - code formatted

---

## File Structure Summary

```
plugins/eventhook/
├── Cargo.toml
├── migrations/
│   ├── 20260101000001_init.up.sql
│   └── 20260101000001_init.down.sql
└── src/
    ├── lib.rs                    # Plugin trait implementation
    ├── api/
    │   ├── mod.rs
    │   └── ingest.rs             # POST /api/tenants/{slug}/eventhook/in/{source}
    ├── domain/
    │   ├── mod.rs
    │   ├── source.rs             # WebhookSource
    │   ├── route.rs              # WebhookRoute, TargetConfig
    │   ├── event.rs              # WebhookEvent
    │   ├── event_action.rs       # WebhookEventAction
    │   └── verifier.rs           # VerifierConfig enum
    ├── repository/
    │   ├── mod.rs
    │   ├── source_repository.rs
    │   ├── route_repository.rs
    │   ├── event_repository.rs
    │   └── event_action_repository.rs
    ├── service/
    │   ├── mod.rs
    │   ├── verifier.rs           # Signature verification logic
    │   └── processor.rs          # Route matching & execution
    └── target/
        ├── mod.rs
        ├── workflow.rs
        ├── task.rs
        └── promise.rs
```

---

## Dependencies

New dependencies for `flovyn-server/plugins/eventhook/Cargo.toml`:
```toml
[dependencies]
flovyn-core.workspace = true
flovyn-plugin.workspace = true

async-trait.workspace = true
axum.workspace = true
sqlx.workspace = true
uuid.workspace = true
serde.workspace = true
serde_json.workspace = true
thiserror.workspace = true
tracing.workspace = true
utoipa.workspace = true
chrono.workspace = true
bytes.workspace = true

# Crypto for signature verification
hmac.workspace = true
sha2.workspace = true
sha-1.workspace = true
base64.workspace = true
hex.workspace = true
subtle.workspace = true
```

---

## Exit Criteria Checklist

From design document:

1. [ ] Plugin skeleton created with proper registration
2. [ ] Database schema created with all 4 tables
3. [ ] Ingest endpoint receives webhooks at `/api/tenants/{slug}/eventhook/in/{source}`
4. [ ] HMAC signature verification works for GitHub-style webhooks
5. [ ] API key and basic auth verification work
6. [ ] WorkflowTarget triggers new workflow executions
7. [ ] TaskTarget creates standalone task executions
8. [ ] PromiseTarget resolves/rejects promises
9. [ ] Events stored in database with status tracking
10. [ ] All unit tests pass
11. [ ] Integration test demonstrates end-to-end flow

**Verification command:**
```bash
curl -X POST /api/tenants/acme/eventhook/in/github \
  -H "X-Hub-Signature-256: sha256=..." \
  -d '{"action": "push", ...}'
# -> 200 OK, workflow created
```

---

## Notes

- **No Management API** - Sources/routes created via direct DB or migrations in M1
- **No Event Replay** - Events stored but replay is M2+
- **No Transformations** - Payload passed as-is to targets in M1
- **Secret Storage** - Verifier secrets stored as JSONB (encryption deferred)
