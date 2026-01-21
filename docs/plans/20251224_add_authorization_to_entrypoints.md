# Implementation Plan: Add Authorization to Entrypoints

**Design Document:** [.dev/docs/design/add-authorization-to-entrypoints.md](../design/add-authorization-to-entrypoints.md)

## Overview

This plan implements fine-grained authorization for all REST and gRPC endpoints. The implementation is divided into phases to allow incremental rollout.

## Phase 1: Foundation (Rename Identity, Add AuthorizerExt) ✅ COMPLETED

### 1.1 Rename Identity to Principal ✅

- [x] Rename `flovyn-server/crates/core/src/auth/identity.rs` to `principal.rs`
- [x] Rename `Identity` struct to `Principal`
- [x] Update `flovyn-server/crates/core/src/auth/mod.rs` exports
- [x] Update all imports in `crates/core/`
- [x] Update all imports in `server/src/`
- [x] Update all imports in `plugins/`
- [x] Rename `AuthenticatedIdentity` to `AuthenticatedPrincipal` in server
- [x] Rename `extract_identity()` to `extract_principal()` in gRPC interceptor
- [x] Run `cargo check` to verify no compilation errors
- [x] Run tests to verify no regressions

### 1.2 Update Authorizer Trait ✅

- [x] Update `Authorizer::authorize()` signature to use `&Principal`
- [x] Update `NoOpAuthorizer` implementation
- [x] Update `TenantScopeAuthorizer` implementation
- [x] Update `CompositeAuthorizer` if exists
- [x] Run tests

### 1.3 Add AuthorizerExt Extension Trait ✅

- [x] Create `flovyn-server/server/src/auth/authorize.rs`
- [x] Implement `AuthorizerExt` trait with methods:
  - `require()` - base method
  - `require_view()`
  - `require_create()`
  - `require_update()`
  - `require_delete()`
  - `require_execute()`
  - `require_poll()`
  - `require_complete()` - for task completion
  - `require_fail()` - for task failure
  - `require_heartbeat()` - for heartbeats
- [x] Add blanket implementation for all `Authorizer` types
- [x] Export from `flovyn-server/server/src/auth/mod.rs`
- [x] Write unit tests for `AuthorizerExt`

### 1.4 Add Fluent Authorization API ✅ (Added)

- [x] Create `FromAuthzError` trait for protocol-specific error conversion
- [x] Create `Authorize<'a, E>` fluent helper with methods: `.create()`, `.view()`, `.update()`, `.delete()`, `.execute()`, `.poll()`, `.complete()`, `.fail()`, `.heartbeat()`
- [x] Create `CanAuthorize` trait with associated error type
- [x] Implement `FromAuthzError` for `tonic::Status` (gRPC)
- [x] Implement `CanAuthorize` for `GrpcState`
- [x] Implement `CanAuthorize` for `Arc<AuthStack>`
- [x] Implement `FromAuthzError` for `RestError` (REST)
- [x] Implement `CanAuthorize` for `AppState`
- [x] Export new types from `flovyn-server/server/src/auth/mod.rs`

## Phase 2: Add Authorization Calls to Endpoints ✅ COMPLETED

### 2.1 REST Endpoints ✅

- [x] `POST /api/tenants` - `state.authorize(principal).create("Tenant", tenant_id).await?`
- [x] `GET /api/tenants/:slug` - `state.authorize(principal).view("Tenant", ...).await?`
- [x] `POST /api/tenants/:slug/workflows/:kind/trigger` - `state.authorize(principal).execute(&kind, tenant.id).await?`
- [x] `GET /api/tenants/:slug/stream/workflows/:id` - `state.authorize(principal).view("WorkflowExecution", ...).await?`
- [x] `GET /api/tenants/:slug/stream/workflows/:id/consolidated` - `state.authorize(principal).view("WorkflowExecution", ...).await?`

### 2.2 gRPC WorkflowDispatch Service ✅

- [x] `PollWorkflow` - `auth_stack.authorize(&principal).poll("WorkflowExecution", tenant_id).await?`
- [x] `StartWorkflow` - `auth_stack.authorize(&principal).execute(&workflow_kind, tenant_id).await?`
- [x] `StartChildWorkflow` - `auth_stack.authorize(&principal).create("WorkflowExecution", tenant_id).await?`
- [x] `SubmitWorkflowCommands` - `auth_stack.authorize(&principal).update("WorkflowExecution", ...).await?`
- [x] `GetEvents` - `auth_stack.authorize(&principal).view("WorkflowExecution", ...).await?`
- [x] `ResolvePromise` - `auth_stack.authorize(&principal).update("WorkflowExecution", ...).await?`
- [x] `RejectPromise` - `auth_stack.authorize(&principal).update("WorkflowExecution", ...).await?`
- [x] `SubscribeToNotifications` - `auth_stack.authorize(&principal).poll("WorkflowExecution", tenant_id).await?`

### 2.3 gRPC TaskExecution Service ✅

- [x] `SubmitTask` - `state.authorize(&principal).create("TaskExecution", tenant_id).await?`
- [x] `PollTask` - `state.authorize(&principal).poll("TaskExecution", tenant_id).await?`
- [x] `CompleteTask` - `state.authorize(&principal).complete("TaskExecution", ...).await?`
- [x] `FailTask` - `state.authorize(&principal).fail("TaskExecution", ...).await?`
- [x] `CancelTask` - `state.authorize(&principal).delete("TaskExecution", ...).await?`
- [x] `ReportProgress` - `state.authorize(&principal).update("TaskExecution", ...).await?`
- [x] `Heartbeat` - `state.authorize(&principal).heartbeat("TaskExecution", ...).await?`
- [x] `LogMessage` - `state.authorize(&principal).update("TaskExecution", ...).await?`
- [x] `GetState` - `state.authorize(&principal).view("TaskExecution", ...).await?`
- [x] `SetState` - `state.authorize(&principal).update("TaskExecution", ...).await?`
- [x] `ClearState` - `state.authorize(&principal).update("TaskExecution", ...).await?`
- [x] `ClearAllState` - `state.authorize(&principal).update("TaskExecution", ...).await?`
- [x] `GetStateKeys` - `state.authorize(&principal).view("TaskExecution", ...).await?`
- [x] `StreamTaskData` - `state.authorize(&principal).update("TaskExecution", ...).await?`

### 2.4 gRPC WorkerLifecycle Service ✅

- [x] `RegisterWorker` - `state.authorize(&principal).create("Worker", tenant_id).await?`
- [x] `SendHeartbeat` - `state.authorize(&principal).heartbeat("Worker", ...).await?`

### 2.5 Verify Phase 2 ✅

- [x] Run all unit tests (20 passed)
- [x] Run integration tests
- [x] Run E2E tests (52 passed)
- [x] Verify existing behavior unchanged (TenantScopeAuthorizer still allows same-tenant access)

## Phase 3: Principal Attribute Resolution ✅ COMPLETED

### 3.1 Core Types ✅

- [x] Create `flovyn-server/crates/core/src/auth/attributes.rs`
- [x] Implement `PrincipalAttributes` struct with `AttributeValue` enum
- [x] Implement `PrincipalAttributeResolver` trait
- [x] Implement `AttributeResolverError` enum
- [x] Export from `flovyn-server/crates/core/src/auth/mod.rs`

### 3.2 ClaimsAttributeResolver ✅

- [x] Create `flovyn-server/server/src/auth/attributes/mod.rs`
- [x] Create `flovyn-server/server/src/auth/attributes/claims.rs`
- [x] Implement `ClaimMapping` struct with `ClaimValueType` enum
- [x] Implement `ClaimsAttributeResolver` with tenant-scoped role/permissions support
- [x] Add configuration parsing for claim mappings (`ClaimMappingConfig`)
- [x] Write unit tests

### 3.3 DatabaseAttributeResolver ✅

- [x] Create `flovyn-server/server/src/auth/attributes/database.rs`
- [x] Implement `DatabaseAttributeResolver`
- [x] Add query for `tenant_member` role lookup (forward-compatible, awaits table creation)
- [x] Write unit tests with stub resolver

### 3.4 Supporting Resolvers ✅

- [x] Create `flovyn-server/server/src/auth/attributes/noop.rs` - `NoOpAttributeResolver`
- [x] Create `flovyn-server/server/src/auth/attributes/composite.rs` - `CompositeAttributeResolver`
- [x] Create `flovyn-server/server/src/auth/attributes/caching.rs` - `CachingAttributeResolver`
- [x] Write unit tests for each

### 3.5 Integrate with AuthStack ✅

- [x] Add `attribute_resolver` field to `AuthStack`
- [x] Add `with_pool()` method to `AuthStackBuilder` for database resolver
- [x] Add `build_attribute_resolver()` method to `AuthStackBuilder`
- [x] Support all resolver types: noop, claims, database, composite

### 3.6 Configuration ✅

- [x] Add `AttributeResolverConfig` to `AuthConfig`
- [x] Add `ClaimMappingConfig` for claims resolver
- [x] Add `CacheConfig` for cache settings
- [x] Support `resolver_type`: noop, claims, database, composite
- [x] Support `mappings` for custom claim mappings
- [x] Support `cache.enabled` and `cache.ttl_secs`

### 3.7 Verify Phase 3 ✅

- [x] Run all unit tests (200 passed)
- [x] Run integration tests (20 passed)
- [x] Run E2E tests (52 passed)
- [x] Existing behavior unchanged (TenantScopeAuthorizer works)

## Phase 4: Cedar Authorizer ✅ COMPLETED

### 4.1 Add Cedar Dependency ✅

- [x] Add `cedar-policy = "4"` to `flovyn-server/server/Cargo.toml`
- [x] Add feature flag `cedar-authz` (enabled by default)

### 4.2 Cedar Entity Adapter ✅

- [x] Create `flovyn-server/server/src/auth/authorizer/cedar/mod.rs`
- [x] Create `flovyn-server/server/src/auth/authorizer/cedar/entity.rs`
- [x] Implement `CedarEntityAdapter`:
  - `principal_uid()` - convert Principal to Cedar EntityUid
  - `action_uid()` - convert action string to Cedar EntityUid
  - `resource_uid()` - convert resource type/id to Cedar EntityUid
  - `build_entities()` - build Cedar Entities from Principal and AuthzContext

### 4.3 Policy Store ✅

- [x] Create `flovyn-server/server/src/auth/authorizer/cedar/store.rs`
- [x] Implement `PolicyStore` trait
- [x] Implement `EmbeddedPolicyStore` - loads from compiled-in policies
- [x] Implement `FilePolicyStore` - loads from file path

### 4.4 CedarAuthorizer ✅

- [x] Create `flovyn-server/server/src/auth/authorizer/cedar/authorizer.rs`
- [x] Implement `CedarAuthorizer` struct
- [x] Implement `Authorizer` trait for `CedarAuthorizer`
- [x] Write unit tests with test policies

### 4.5 Base Policies ✅

- [x] Embed base policies in `flovyn-server/server/src/auth/authorizer/cedar/store.rs` (as `BASE_POLICIES` const)
- [x] Implement tenant-level policies (OWNER, ADMIN, MEMBER)
- [x] Implement worker policies (poll, execute, complete, fail, heartbeat, view, update, create)
- [x] Implement anonymous access policy (for disabled auth mode)
- [x] Implement system-level access policy (principals without tenant_id)
- [x] Implement cross-tenant forbid rule
- [x] Write policy tests

### 4.6 Configuration ✅

- [x] Add `cedar` option to endpoint authorizer config
- [x] Add `CedarAuthConfig` with optional `policy_path` for custom policies
- [x] Update `AuthStackBuilder` to support Cedar authorizer

### 4.7 Verify Phase 4 ✅

- [x] Run all unit tests (222 passed)
- [x] Run integration tests (20 passed)
- [x] Test RBAC policies (OWNER, ADMIN, MEMBER roles)
- [x] Test worker policies
- [x] Test cross-tenant access denial
- [x] Test anonymous access
- [x] Test system-level access

## Phase 5: ScriptAttributeResolver ✅ COMPLETED

### 5.1 Research JavaScript Runtimes ✅

- [x] Evaluated `rquickjs`, `boa_engine`, `deno_core`
- [x] Selected `rquickjs` (QuickJS bindings) for:
  - Small footprint (~210KB)
  - Fast startup (<300μs)
  - ES2020 support
  - Good Rust integration

### 5.2 Create Separate Crate ✅

- [x] Create `flovyn-server/crates/auth-script/Cargo.toml`
- [x] Create `flovyn-server/crates/auth-script/src/lib.rs`
- [x] Create `flovyn-server/crates/auth-script/src/resolver.rs`
- [x] Add to workspace `Cargo.toml`

### 5.3 Implement ScriptAttributeResolver ✅

- [x] Implement `ScriptAttributeResolver` struct
- [x] Implement `PrincipalAttributeResolver` trait
- [x] Support `new(script)` for inline JavaScript
- [x] Support `from_file(path)` for external scripts
- [x] Script interface: `function resolve(principal, tenantId) -> { role?, permissions?, ... }`
- [x] Parse result into `PrincipalAttributes` (String, StringList, Bool, Number)

### 5.4 Configuration ✅

- [x] Add `ScriptResolverConfig` with `path` and `inline` options
- [x] Add `script` field to `AttributeResolverConfig`
- [x] Support `resolver_type: "script"` in config

### 5.5 Server Integration ✅

- [x] Add `script-authz` feature flag to `flovyn-server/server/Cargo.toml`
- [x] Add `flovyn-auth-script` as optional dependency
- [x] Add `build_script_resolver()` method to `AuthStackBuilder`
- [x] Export `ScriptResolverConfig` from `auth::core`

### 5.6 Verify Phase 5 ✅

- [x] Run auth-script crate tests (12 passed)
- [x] Run integration tests (20 passed)
- [x] Test script creation and validation
- [x] Test attribute extraction from principal
- [x] Test array/boolean/number value types

## Testing Strategy

### Unit Tests
- Test `AuthorizerExt` methods with mock `Authorizer`
- Test each `PrincipalAttributeResolver` implementation
- Test `CedarAuthorizer` with test policies
- Test `CedarEntityAdapter` entity building

### Integration Tests
- Test full authorization flow with `TenantScopeAuthorizer`
- Test full authorization flow with `CedarAuthorizer`
- Test attribute resolution with claims
- Test attribute resolution with database

### E2E Tests
- Test REST endpoints with authenticated user (different roles)
- Test gRPC endpoints with worker token
- Test cross-tenant access denial
- Test permission denied scenarios

## Rollout Strategy

1. **Phase 1-2**: Deploy with `TenantScopeAuthorizer` (current behavior)
2. **Phase 3**: Deploy with attribute resolution, still using `TenantScopeAuthorizer`
3. **Phase 4a**: Deploy `CedarAuthorizer` in staging with permissive policies
4. **Phase 4b**: Tune policies based on staging feedback
5. **Phase 4c**: Enable `CedarAuthorizer` in production

## Dependencies

- `cedar-policy = "4"` (Phase 4) ✅ Added
- `moka` for caching (Phase 3) ✅ Already present in workspace
- `rquickjs = "0.10"` (Phase 5) ✅ Added (QuickJS JavaScript engine bindings)
