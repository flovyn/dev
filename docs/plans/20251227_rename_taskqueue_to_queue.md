# Implementation Plan: Rename `taskQueue` to `queue` in REST API

**Date:** 2025-12-27
**Status:** Completed

## Problem

The REST API has an inconsistency in field naming:
- **Tasks endpoints** (`tasks.rs`): Use `queue` consistently
- **Workflows endpoints** (`workflows.rs`): Use `taskQueue` (serialized as `task_queue` in JSON)

For API consistency, workflow endpoints should use `queue` instead of `taskQueue`.

## Scope of Changes

### Files to Modify

| File | Changes Required |
|------|-----------------|
| `flovyn-server/server/src/api/rest/workflows.rs` | Rename fields in DTOs, update helper function |
| `flovyn-server/crates/rest-client/src/types.rs` | Rename fields in client types |

### Specific Field Changes

#### 1. `flovyn-server/server/src/api/rest/workflows.rs`

| Location | Current | New |
|----------|---------|-----|
| Line 31-33 | `fn default_task_queue()` | `fn default_queue()` |
| Line 50-51 | `TriggerWorkflowRequest.task_queue` | `TriggerWorkflowRequest.queue` |
| Line 114-115 | `WorkflowExecutionResponse.task_queue` | `WorkflowExecutionResponse.queue` |
| Line 160 | `task_queue: wf.task_queue.clone()` | `queue: wf.task_queue.clone()` |
| Line 350-351 | `WorkflowSummary.task_queue` | `WorkflowSummary.queue` |
| Line 372 | `task_queue: wf.task_queue.clone()` | `queue: wf.task_queue.clone()` |

Note: Internal code still uses `task_queue` for the domain model field; only the API serialization name changes.

#### 2. `flovyn-server/crates/rest-client/src/types.rs`

| Location | Current | New |
|----------|---------|-----|
| Line 18 | `TriggerWorkflowRequest.task_queue` | `TriggerWorkflowRequest.queue` |
| Line 49 | `WorkflowExecutionResponse.task_queue` | `WorkflowExecutionResponse.queue` |
| Line 173 | `WorkflowSummary.task_queue` | `WorkflowSummary.queue` |

## TODO List

- [x] **Phase 1: Update Server DTOs**
  - [x] Rename `default_task_queue()` to `default_queue()` in `workflows.rs`
  - [x] Update `TriggerWorkflowRequest.task_queue` → `queue`
  - [x] Update `WorkflowExecutionResponse.task_queue` → `queue`
  - [x] Update `WorkflowSummary.task_queue` → `queue`
  - [x] Update `From` implementations to map correctly

- [x] **Phase 2: Update REST Client Types**
  - [x] Update `TriggerWorkflowRequest.task_queue` → `queue`
  - [x] Update `WorkflowExecutionResponse.task_queue` → `queue`
  - [x] Update `WorkflowSummary.task_queue` → `queue`

- [x] **Phase 3: Verify and Test**
  - [x] Run `cargo check` to verify compilation
  - [x] Update integration tests to use new field name
  - [x] Verify tests compile

## Verification Commands

```bash
# Build and check
./bin/dev/build.sh

# Run unit tests
./bin/dev/test.sh

# Run integration tests
cargo test --test integration_tests

# Verify OpenAPI spec
./target/debug/export-openapi | jq '.components.schemas | keys[] | select(contains("Workflow"))'
```
