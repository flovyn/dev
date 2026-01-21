# Implementation Plan: Promise UUID Primary Key

**Date:** 2026-01-02
**Design Document:** [20260102_promise_uuid_primary_key.md](../design/20260102_promise_uuid_primary_key.md)
**Status:** Completed

## Overview

Change the promise table primary key from composite string (`{workflow_execution_id}:{name}`) to UUID. This aligns with industry standards (Temporal, Hatchet) and makes the API cleaner.

Since backward compatibility is NOT required, we use UUID everywhere with no legacy format support.

## TODO List

### Phase 1: Database Schema

- [x] Update `flovyn-server/server/migrations/20251214220815_init.sql`:
  - Change `promise.id` from `VARCHAR(255) PRIMARY KEY` to `UUID PRIMARY KEY DEFAULT gen_random_uuid()`
  - Add `UNIQUE(workflow_execution_id, name)` constraint
- [x] Update `flovyn-server/server/migrations/20260101204520_add_promise_idempotency.sql`:
  - Change `promise_id VARCHAR(255)` to `promise_id UUID`

### Phase 2: Promise Repository

- [x] Update `flovyn-server/server/src/repository/promise_repository.rs`:
  - Change `Promise.id` from `String` to `Uuid`
  - Update `get(&self, id: &str)` → `get(&self, id: Uuid)`
  - Update `resolve(&self, id: &str, ...)` → `resolve(&self, id: Uuid, ...)`
  - Update `reject(&self, id: &str, ...)` → `reject(&self, id: Uuid, ...)`
  - Update `create()` to accept UUID parameter (pre-generated before event creation)

### Phase 3: Idempotency Key Repository

- [x] Update `flovyn-server/server/src/repository/idempotency_key_repository.rs`:
  - Change `IdempotencyError::KeyConflict.existing_promise_id` from `String` to `Uuid`
  - Change `create_for_promise(promise_id: &str)` → `create_for_promise(promise_id: Uuid)`
  - Change `find_promise_by_key()` return type from `Option<String>` → `Option<Uuid>`
  - Change `clear_for_promise(promise_id: &str)` → `clear_for_promise(promise_id: Uuid)`

### Phase 4: gRPC Workflow Dispatch

- [x] Update `flovyn-server/server/src/api/grpc/workflow_dispatch.rs`:
  - Remove composite ID generation
  - Pre-generate UUIDs before processing commands
  - Include `promiseId` (UUID) and `promiseName` in PROMISE_CREATED events
  - Update `resolve_promise` and `reject_promise` to accept UUID only
  - Update tracing/logging

### Phase 5: REST API

- [x] Update `flovyn-server/server/src/api/rest/promises.rs`:
  - Change `IdentifierType::PromiseId(String)` → `IdentifierType::PromiseId(Uuid)`
  - Update `parse_identifier()` to parse UUID only
  - Change `PromiseResponse.promise_id` from `String` to `Uuid`

### Phase 6: SDK Updates

- [x] Update `sdk-rust/sdk/src/client/flovyn_client.rs`:
  - Add `get_promise_id()` helper to fetch UUID from PROMISE_CREATED events
  - Update `resolve_promise` and `reject_promise` to use UUID
- [x] Update `sdk-rust/sdk/src/workflow/context_impl.rs`:
  - Change replay logic to use `promiseName` instead of `promiseId` for validation
- [x] Update `sdk-rust/ffi/src/context.rs`:
  - Change replay logic to use `promiseName` instead of `promiseId`
  - Update `build_promise_results` to use `promiseName`
- [x] Update `sdk-rust/sdk/src/error.rs`:
  - Add `PromiseNotFound` error variant

### Phase 7: Testing

- [x] Run `cargo check` to verify compilation
- [x] Run SDK unit tests (202 passed)
- [x] Run server unit tests (268 passed)
- [x] Run `cargo test --test integration_tests` for integration tests (113 passed)
- [x] Update test in `workflow_tests.rs` to get UUID from PROMISE_CREATED event

### Phase 8: Remove Promise Name Uniqueness Constraint

**Rationale:** A workflow might legitimately want to create multiple promises with the same name (e.g., in a loop). The UUID should be the unique identifier, not the name.

- [x] Remove `UNIQUE(workflow_execution_id, name)` constraint from `flovyn-server/server/migrations/20251214220815_init.sql`
- [x] Update SDK replay logic to use `promiseId` (UUID) instead of `promiseName` for:
  - `build_promise_results()` in `flovyn-server/ffi/src/context.rs` - key by UUID
  - `find_terminal_promise_event()` in `flovyn-server/core/src/workflow/execution.rs` - match by UUID
  - Promise result cache lookups
- [x] Update PROMISE_RESOLVED/PROMISE_REJECTED events to include `promiseId` for correlation
- [x] Run all tests (202 SDK, 268 server unit, 113 integration)

## File Changes

| File | Change |
|------|--------|
| `flovyn-server/server/migrations/20251214220815_init.sql` | `promise.id`: VARCHAR → UUID, remove name uniqueness constraint |
| `flovyn-server/server/migrations/20260101204520_add_promise_idempotency.sql` | `promise_id`: VARCHAR → UUID |
| `flovyn-server/server/src/repository/promise_repository.rs` | `Promise.id`: String → Uuid |
| `flovyn-server/server/src/repository/idempotency_key_repository.rs` | `promise_id` type changes |
| `flovyn-server/server/src/api/grpc/workflow_dispatch.rs` | Pre-generate UUIDs, include in events, UUID-only resolution |
| `flovyn-server/server/src/api/rest/promises.rs` | `IdentifierType`, `PromiseResponse`, UUID-only |
| `flovyn-server/server/tests/integration/workflow_tests.rs` | Get UUID from PROMISE_CREATED event |
| `sdk-rust/sdk/src/client/flovyn_client.rs` | Add `get_promise_id()`, use UUID |
| `sdk-rust/sdk/src/workflow/context_impl.rs` | Use `promiseName` for replay validation |
| `sdk-rust/ffi/src/context.rs` | Use `promiseName` for replay validation |
| `sdk-rust/sdk/src/error.rs` | Add `PromiseNotFound` error |

## Acceptance Criteria

- [x] Promise table uses UUID primary key
- [x] REST API accepts UUID format: `/promises/id:{uuid}/resolve`
- [x] Idempotency key lookup returns UUID
- [x] SDK resolves promises by UUID (fetched from PROMISE_CREATED events)
- [x] All tests pass (113 integration tests, 202 SDK tests, 268 server unit tests)
- [x] Promise name uniqueness constraint removed (allows same name multiple times per workflow)
- [x] SDK uses `promiseId` (UUID) for all internal lookups, not `promiseName`
