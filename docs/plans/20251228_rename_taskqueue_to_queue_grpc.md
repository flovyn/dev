# Implementation Plan: Rename `task_queue` to `queue` in gRPC API

**Date:** 2025-12-28
**Status:** Completed

## Problem

The gRPC API has inconsistent naming:
- **Task-related messages** already use `queue` (e.g., `SubmitTaskRequest.queue`, `PollTaskRequest.queue`)
- **Workflow-related messages** still use `task_queue`

## Scope of Changes

### Proto File Changes (`server/proto/flovyn.proto`)

| Message | Field | Line |
|---------|-------|------|
| `PollRequest` | `task_queue` → `queue` | 60 |
| `SubscriptionRequest` | `task_queue` → `queue` | 80 |
| `WorkflowExecution` | `task_queue` → `queue` | 105 |
| `WorkAvailableEvent` | `task_queue` → `queue` | 145 |
| `StartWorkflowRequest` | `task_queue` → `queue` | 158 |
| `StartChildWorkflowRequest` | `task_queue` → `queue` | 216 |
| `ScheduleChildWorkflowCommand` | `task_queue` → `queue` | 576 |

### Handler Code Updates

After proto changes, the generated code will use `queue` instead of `task_queue`. Need to update:
- `flovyn-server/server/src/api/grpc/workflow_dispatch.rs`
- `flovyn-server/server/src/api/grpc/mod.rs` (helper functions and notifications)

### Internal Code

Internal code (domain models, repositories) will continue using `task_queue` - only the API layer changes.

## TODO List

- [x] **Phase 1: Update Proto File**
  - [x] Rename all `task_queue` fields to `queue` in workflow messages
  - [x] Update comments accordingly

- [x] **Phase 2: Update gRPC Handler Code**
  - [x] Update `workflow_dispatch.rs` to use `.queue` instead of `.task_queue`
  - [x] Update `flovyn-server/domain/workflow.rs` to use `queue` in proto struct

- [x] **Phase 3: Verify**
  - [x] Run `cargo check` to verify compilation
  - [x] Run `cargo check --tests` to verify tests compile
