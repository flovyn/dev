# Implementation Plan: Remove WorkerNotifier

**Date**: 2026-01-13
**Design Reference**: [20260112_remove-worker-notifier.md](../design/20260112_remove_worker_notifier.md)

## Overview

This plan implements the removal of WorkerNotifier as specified in the design document. The work is split into phases to allow incremental testing and validation.

## Pre-Implementation Verification

Before starting, establish baselines:

```bash
# Run integration tests to ensure clean starting point
./bin/dev/run-tests-loop.sh 3

# Build to verify no compilation issues
./bin/dev/build.sh
```

---

## Phase 1: Server-Side Removal

Remove WorkerNotifier from flovyn-server including proto definitions. Proto and RPC handler must be removed together (tonic requires all proto-defined RPCs to be implemented).

### TODO List

- [ ] **1.1** Remove from `server/proto/flovyn.proto`:
  - `rpc SubscribeToNotifications(SubscriptionRequest) returns (stream WorkAvailableEvent);`
  - `message SubscriptionRequest { ... }`
  - `message WorkAvailableEvent { ... }`
- [ ] **1.2** Remove `subscribe_to_notifications` RPC handler from `flovyn-server/server/src/api/grpc/workflow_dispatch.rs`
- [ ] **1.3** Remove `WorkNotification` struct and `WorkerNotifier` from `flovyn-server/server/src/api/grpc/mod.rs` (lines 26-63)
- [ ] **1.4** Remove `notifier` field from `GrpcState` struct in `flovyn-server/server/src/api/grpc/mod.rs` (line 94)
- [ ] **1.5** Remove `notifier` from `AppState` in `flovyn-server/server/src/api/rest/mod.rs`
- [ ] **1.6** Remove notifier creation and injection in `flovyn-server/server/src/main.rs`
- [ ] **1.7** Remove all `notify_work_available` calls (26 occurrences across 11 files):
  - `flovyn-server/server/src/api/grpc/workflow_dispatch.rs` (7 calls)
  - `flovyn-server/server/src/scheduler.rs` (5 calls)
  - `flovyn-server/server/src/api/grpc/task_execution.rs` (3 calls)
  - `flovyn-server/server/src/api/rest/workflows.rs` (2 calls)
  - `flovyn-server/server/src/api/rest/promises.rs` (2 calls)
  - `flovyn-server/server/src/service/promise_resolver.rs` (2 calls)
  - `flovyn-server/server/src/api/rest/tasks.rs` (1 call)
  - `flovyn-server/server/src/api/rest/schedules.rs` (1 call)
  - `flovyn-server/server/src/service/workflow_launcher.rs` (1 call)
  - `flovyn-server/server/src/service/task_launcher.rs` (1 call)
- [ ] **1.8** Verify build: `./bin/dev/build.sh`
- [ ] **1.9** Run integration tests: `./bin/dev/run-tests-loop.sh 5`

### Notes for Phase 1

- All existing tests should pass since they rely on polling fallback
- Workers will fall back to polling (which they already do)

---

## Phase 2: SDK-Rust Removal

Remove notification subscription from sdk-rust worker.

**Path**: `/Users/manhha/Developer/manhha/flovyn/sdk-rust/sdk/src/worker/`

### TODO List

- [ ] **2.1** Remove `subscribe_to_notifications` client method from `flovyn-server/client/mod.rs` or `flovyn-server/client/flovyn_client.rs`
- [ ] **2.2** Remove `enable_notifications` field from `WorkflowWorkerConfig` (line 51)
- [ ] **2.3** Remove `enable_notifications: true` default (line 79)
- [ ] **2.4** Remove `enable_notifications` from Debug impl (line 102)
- [ ] **2.5** Remove `work_available_notify: Arc<Notify>` field from `WorkflowExecutorWorker` struct (line 127)
- [ ] **2.6** Remove `work_available_notify` initialization in constructor (line 165)
- [ ] **2.7** Remove entire `notification_subscription_loop` method (lines 250-318)
- [ ] **2.8** Remove notification subscription spawn from `start()` method (lines 377-393)
- [ ] **2.9** Remove `work_available_notify` clone in start() (line 404)
- [ ] **2.10** Simplify `poll_and_execute` - remove notification wait logic (lines 539, 616-627):
  ```rust
  // Before: tokio::select! with work_available_notify.notified() and sleep
  // After: just tokio::time::sleep(config.no_work_backoff).await;
  ```
- [ ] **2.11** Remove `work_available_notify` parameter from `poll_and_execute` call (line 464)
- [ ] **2.12** Update/remove unit tests that reference `enable_notifications` (lines 1075, 1094)
- [ ] **2.13** Verify build: `cd ../sdk-rust && cargo build`
- [ ] **2.14** Run SDK tests: `cd ../sdk-rust && cargo test`
- [ ] **2.15** Run server integration tests with updated SDK: `./bin/dev/run-tests-loop.sh 5`

### Notes for Phase 2

- TaskWorker does NOT have notification subscription (already uses simple polling)
- Keep `no_work_backoff` config (100ms default) - this is the polling interval

---

## Phase 3: SDK-Kotlin Review

Review sdk-kotlin for any notification-related code.

### TODO List

- [ ] **3.1** Search for notification-related code: `grep -r "notification\|subscribe" sdk-kotlin/sdk/src --include="*.kt"`
- [ ] **3.2** Remove any notification subscription logic if found
- [ ] **3.3** Verify Kotlin SDK builds and tests pass

**Note**: Based on exploration, sdk-kotlin does not appear to have notification subscription implemented.

---

## Verification Checklist

After all phases complete:

- [ ] **V1** Full build passes: `./bin/dev/build.sh`
- [ ] **V2** Unit tests pass: `./bin/dev/test.sh`
- [ ] **V3** Integration tests pass (10 runs for flakiness): `./bin/dev/run-tests-loop.sh 10`
- [ ] **V4** E2E tests pass: `./bin/dev/run-e2e-tests.sh`
- [ ] **V5** Manual test: Start server, connect worker, trigger workflow, verify execution within ~100ms

---

## Rollback Plan

If issues are discovered post-deployment:

1. Revert commits for this change
2. WorkerNotifier is self-contained - reverting brings back full functionality
3. No database migrations involved - clean rollback

---

## Files Modified Summary

### flovyn-server (Phase 1)
- `server/proto/flovyn.proto` - Remove notification RPC and messages
- `flovyn-server/server/src/api/grpc/mod.rs` - Remove WorkerNotifier struct and GrpcState field
- `flovyn-server/server/src/api/grpc/workflow_dispatch.rs` - Remove 7 notify calls, remove RPC handler
- `flovyn-server/server/src/api/grpc/task_execution.rs` - Remove 3 notify calls
- `flovyn-server/server/src/api/rest/mod.rs` - Remove AppState field
- `flovyn-server/server/src/api/rest/workflows.rs` - Remove 2 notify calls
- `flovyn-server/server/src/api/rest/promises.rs` - Remove 2 notify calls
- `flovyn-server/server/src/api/rest/tasks.rs` - Remove 1 notify call
- `flovyn-server/server/src/api/rest/schedules.rs` - Remove 1 notify call
- `flovyn-server/server/src/scheduler.rs` - Remove 5 notify calls
- `flovyn-server/server/src/service/workflow_launcher.rs` - Remove 1 notify call
- `flovyn-server/server/src/service/task_launcher.rs` - Remove 1 notify call
- `flovyn-server/server/src/service/promise_resolver.rs` - Remove 2 notify calls
- `flovyn-server/server/src/main.rs` - Remove notifier creation

### sdk-rust (Phase 2)
- `flovyn-server/sdk/src/worker/workflow_worker.rs` - Remove notification subscription logic
- `flovyn-server/sdk/src/client/mod.rs` or `flovyn-server/sdk/src/client/flovyn_client.rs` - Remove subscribe_to_notifications method
