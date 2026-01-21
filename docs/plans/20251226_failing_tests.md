# Bug Report: Failing Integration Tests - FIXED

**Date:** 2025-12-26

**Status:** ✅ ALL FIXED

**Context:** After implementing atomic event appending for race condition fixes, 4 integration tests were failing. All issues have been fixed.

---

## Summary

| Test | Status | Fix Applied |
|------|--------|-------------|
| `oracle_work_distribution_skip_locked_prevents_double_claim` | ✅ FIXED | Use unique task_type/queue per test |
| `test_discovery_get_worker_with_capabilities` | ✅ FIXED | Multiple fixes (see below) |
| `test_discovery_get_task_definition` | ✅ FIXED | Same fixes as above |
| `test_discovery_full_e2e_flow` | ✅ FIXED | Same fixes as above |

---

## Fixes Applied

### 1. Oracle Test Isolation (server)
**File:** `flovyn-server/server/tests/integration/oracle_tests.rs`
**Fix:** Use unique task_type and queue names per test to avoid interference from scheduler or parallel tests.

### 2. Discovery Tests - Multiple Fixes

#### 2a. SDK Fix: Remove `-task` suffix from task worker name
**File:** `sdk-rust/sdk/src/client/flovyn_client.rs`
**Fix:** The task worker now uses the same worker_name as the workflow worker, ensuring both register capabilities under the same worker entry.

#### 2b. Server Fix: Atomic worker upsert
**File:** `flovyn-server/server/src/repository/worker_repository.rs`
**Fix:** Changed `upsert` to use `INSERT ... ON CONFLICT ... RETURNING id` for atomic handling of concurrent registrations.

#### 2c. Server Fix: Type-specific capability clearing
**File:** `flovyn-server/server/src/api/grpc/worker_lifecycle.rs`
**Fix:** When a worker registers:
- WORKFLOW type workers only clear workflow capabilities
- TASK type workers only clear task capabilities
- UNIFIED type workers clear both

This allows the SDK's separate workflow/task workers to independently manage their capabilities without overwriting each other.

#### 2d. Schema Fix: Unique constraint on worker name
**File:** `flovyn-server/server/migrations/20251226093042_workload_discovery.sql`
**Fix:** Added `CONSTRAINT worker_tenant_name_unique UNIQUE (tenant_id, worker_name)` to prevent duplicate worker entries.

#### 2e. SDK Package Rename
**Files:** `sdk-rust/core/Cargo.toml` and related files
**Fix:** Renamed `flovyn-core` to `flovyn-sdk-core` to avoid package name collision with the server's `flovyn-core`.

---

## Follow-up Improvement: Unified Worker Registration ✅ IMPLEMENTED

The SDK now uses unified worker registration:

**Files modified:**
- `sdk-rust/sdk/src/client/flovyn_client.rs` - Added `register_unified()` method
- `sdk-rust/sdk/src/worker/workflow_worker.rs` - Removed individual registration, accepts `server_worker_id` from client
- `sdk-rust/sdk/src/worker/task_worker.rs` - Removed individual registration, accepts `server_worker_id` from client

**Implementation:**
- `FlovynClient.start()` now calls `register_unified()` before starting workers
- `register_unified()` collects all workflow and task metadata from registries
- Makes a single registration call with `WorkerType::Unified`
- Passes the returned `server_worker_id` to both internal workers
- Individual `register_with_server` methods removed from both workers

This reduces network calls from 2 to 1 and simplifies the registration flow.

---

## Verification

All 92 integration tests pass:
```bash
cargo test --test integration_tests
# test result: ok. 92 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```
