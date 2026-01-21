# Implementation Plan: Rename `state` to `status` for Workflow Execution

**Date:** 2025-12-28

## Problem

The codebase has inconsistent naming for workflow execution state:
- `workflow_execution` table uses `state` column
- `task_execution` table uses `status` column
- REST API response DTOs mix `state` and `status`

This inconsistency is confusing. We should standardize on `status` everywhere.

## Changes Required

### 1. Database Migration

**File:** `flovyn-server/server/migrations/20251214220815_init.sql`

| Change | From | To |
|--------|------|-----|
| Column name | `state` | `status` |
| Constraint | `workflow_state_check` | `workflow_status_check` |
| Index | `idx_workflow_state` | `idx_workflow_status` |
| Index | `idx_workflow_dispatch` filter | `status = 'PENDING'` |

### 2. Domain Model

**File:** `flovyn-server/server/src/domain/workflow.rs`

| Change | From | To |
|--------|------|-----|
| Enum name | `WorkflowState` | `WorkflowStatus` |
| Field name | `state_str` | `status_str` |
| SQLx rename | `#[sqlx(rename = "state")]` | `#[sqlx(rename = "status")]` |
| Method name | `fn state()` | `fn status()` |

### 3. Repository Layer

**File:** `flovyn-server/server/src/repository/workflow_repository.rs`
- All SQL queries referencing `state` column -> `status`
- Import `WorkflowState` -> `WorkflowStatus`
- Method `update_state` -> `update_status`
- Parameter `state: WorkflowState` -> `status: WorkflowStatus`

**File:** `flovyn-server/server/src/repository/idempotency_key_repository.rs`
- Lines 106, 397: `SELECT state FROM` -> `SELECT status FROM`

**File:** `flovyn-server/server/src/repository/event_repository.rs`
- Line 324: `w.state = 'WAITING'` -> `w.status = 'WAITING'`

### 4. Scheduler

**File:** `flovyn-server/server/src/scheduler.rs`
- Lines 333, 337, 338: All `state` references -> `status`

### 5. gRPC Services

**File:** `flovyn-server/server/src/api/grpc/workflow_dispatch.rs`
- Line 199: `state_str` -> `status_str`
- Line 246: `child.state()` -> `child.status()`
- Line 247: `child_state` -> `child_status`
- Line 252: variable rename

### 6. REST API

**File:** `flovyn-server/server/src/api/rest/workflows.rs`
- Line 118: `pub state: String` -> `pub status: String`
- Line 161: `state: wf.state_str.clone()` -> `status: wf.status_str.clone()`

### 7. REST Client Library

**File:** `flovyn-server/crates/rest-client/src/types.rs`
- Line 50: `pub state: String` -> `pub status: String`

### 8. Integration Tests

**File:** `flovyn-server/server/tests/integration/workflows_tests.rs`
- Line 320: `SET state = 'FAILED'` -> `SET status = 'FAILED'`
- Line 904: `body.state` -> `body.status`
- Line 1318: `get_body.state` -> `get_body.status`
- Line 1605: `SET state = 'FAILED'` -> `SET status = 'FAILED'`
- Line 1661: `get_body.state` -> `get_body.status`

**File:** `flovyn-server/server/tests/integration/oracle_tests.rs`
- Multiple SQL queries with `state` column

## TODO

- [x] 1. Update database migration `flovyn-server/server/migrations/20251214220815_init.sql`
- [x] 2. Update domain model `flovyn-server/server/src/domain/workflow.rs`
- [x] 3. Update workflow repository `flovyn-server/server/src/repository/workflow_repository.rs`
- [x] 4. Update idempotency repository `flovyn-server/server/src/repository/idempotency_key_repository.rs`
- [x] 5. Update event repository `flovyn-server/server/src/repository/event_repository.rs`
- [x] 6. Update scheduler `flovyn-server/server/src/scheduler.rs`
- [x] 7. Update gRPC workflow dispatch `flovyn-server/server/src/api/grpc/workflow_dispatch.rs`
- [x] 8. Update REST API workflows `flovyn-server/server/src/api/rest/workflows.rs`
- [x] 9. Update REST client types `flovyn-server/crates/rest-client/src/types.rs`
- [x] 10. Update integration tests `flovyn-server/server/tests/integration/workflows_tests.rs`
- [x] 11. Update oracle tests `flovyn-server/server/tests/integration/oracle_tests.rs`
- [x] 12. Run tests and fix any remaining issues
