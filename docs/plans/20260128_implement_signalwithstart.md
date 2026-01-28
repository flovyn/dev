# Implementation Plan: SignalWithStart API

**Date**: 2026-01-28
**Design Doc**: [20260127_implement_signalwithstart.md](../design/20260127_implement_signalwithstart.md)
**GitHub Issue**: https://github.com/flovyn/dev/issues/10

---

## Overview

This plan implements the **SignalWithStart API** as specified in the design document. The implementation follows an incremental approach:

1. **Phase 1**: Add signal support alongside existing promises
2. **Phase 2**: Verify with comprehensive tests
3. **Phase 3**: Remove promise code (separate effort after verification)

---

## Design Document Corrections

The following file paths in the design doc need correction:

| Design Doc Path | Actual Path |
|-----------------|-------------|
| `server/src/service/signal_service.rs` | N/A - business logic goes in REST/gRPC handlers and repositories (server has no `service/` layer) |
| `plugins/eventhook/src/route.rs` | `plugins/eventhook/src/domain/route.rs` |
| `plugins/eventhook/src/dispatch.rs` | `plugins/eventhook/src/service/processor.rs` |

---

## Phase 1: Server Implementation

### 1.1 Database Migration

- [x] Create migration `server/migrations/20260128100000_add_signal_received_event.sql`
  - No new tables needed - signals are stored as events in `workflow_event` table
  - Event types are stored as strings (VARCHAR), not enum - no schema change needed
  - Added index for efficient signal counting per workflow (for the 10k limit)

### 1.2 Proto & Generated Code

- [x] Update `server/proto/flovyn.proto`:
  - Add `SignalWithStartWorkflowRequest` and `SignalWithStartWorkflowResponse` messages
  - Add `SignalWorkflowRequest` and `SignalWorkflowResponse` messages
  - Add `SignalWithStartWorkflow` and `SignalWorkflow` RPCs to `WorkflowDispatch` service
  - Keep existing promise RPCs for now
- [x] Run `cargo build` to regenerate `server/src/generated/flovyn.v1.rs`

### 1.3 Domain Types

- [x] Update `crates/core/src/domain/workflow_event.rs`:
  - Add `SignalReceived` variant to `EventType` enum
  - Add string conversion methods for SIGNAL_RECEIVED

### 1.4 Repository Layer

- [x] Update `server/src/repository/event_repository.rs`:
  - Add `append_signal_and_resume()` method to atomically insert SIGNAL_RECEIVED event and resume workflow
  - Add `count_signals_for_workflow()` for enforcing 10k limit

- [x] Update `server/src/repository/idempotency_key_repository.rs`:
  - Add `signal_with_start_workflow_atomically()` for atomic get-or-create workflow + append signal + resume
  - Add `SignalWithStartResult` struct

### 1.5 gRPC Implementation

- [x] Update `server/src/api/grpc/workflow_dispatch.rs`:
  - Implement `signal_with_start_workflow` handler (atomic operation)
  - Implement `signal_workflow` handler (signal existing workflow)
  - Follows existing patterns for auth, tracing, error handling

### 1.6 REST Implementation

- [x] Create `server/src/api/rest/signals.rs`:
  - `POST /api/orgs/{org_slug}/workflow-executions/signal-with-start` handler
  - `POST /api/orgs/{org_slug}/workflow-executions/{workflow_execution_id}/signal` handler
  - Use `#[utoipa::path]` for OpenAPI documentation
  - Add request/response DTOs with `#[derive(ToSchema)]`

- [x] Update `server/src/api/rest/mod.rs`:
  - Register signal routes

- [x] Update `server/src/api/rest/openapi.rs`:
  - Add signal handlers to `paths(...)`
  - Add signal DTOs to `components(schemas(...))`
  - Add "Signals" tag definition

### 1.7 Server Integration Tests

- [x] Create `tests/integration/signal_tests.rs`:
  - [x] Test `SignalWithStartWorkflow` creates workflow and delivers signal
  - [x] Test `SignalWithStartWorkflow` on existing workflow only delivers signal
  - [x] Test `SignalWorkflow` delivers signal to existing workflow
  - [x] Test `SignalWorkflow` returns error for non-existent workflow
  - [x] Test multiple signals to same workflow (sequences strictly increasing)
  - [ ] Test `SignalWorkflow` returns error for completed/failed workflow (deferred to E2E)
  - [ ] Test signal limit (10k signals per workflow) (deferred - requires many signals)
  - [ ] Test concurrent `SignalWithStartWorkflow` calls (atomicity) (deferred)

---

## Phase 1: SDK-Rust Implementation

### 1.8 Worker Core (Events & Commands)

- [x] Update `sdk-rust/worker-core/src/workflow/event.rs`:
  - Added `SignalReceived` variant to `EventType` enum
  - Added `is_signal_event()` helper
  - Added `as_str()` for "SIGNAL_RECEIVED"
  - Added `with_signal_name()` builder method

- [x] Update `sdk-rust/worker-core/src/workflow/command.rs`:
  - No new commands needed - signals don't generate commands (they're external input)
  - Verified: signals are passive, no `CREATE_SIGNAL` command

- [ ] Sync `sdk-rust/worker-core/proto/flovyn.proto` with server proto

### 1.9 Replay Engine

- [x] Update `sdk-rust/worker-core/src/workflow/replay_engine.rs`:
  - Added `signal_events: Vec<ReplayEvent>` to pre-filter SIGNAL_RECEIVED events
  - Added `next_signal_seq: AtomicU32` for tracking consumed signals
  - Added `next_signal_seq()` method to get and increment
  - Added `peek_signal_seq()` method to peek without incrementing
  - Added `get_signal_event(seq)` method for lookup by sequence
  - Added `has_pending_signal()` method to check if signals available
  - Added `pending_signal_count()` method to get remaining signal count
  - Added `signal_event_count()` accessor

NOTE: Queue-based semantics (per signal name) to be added as needed

### 1.10 Workflow Context

- [ ] Update `sdk-rust/worker-sdk/src/workflow/context.rs` (trait):
  - Add `async fn wait_for_signal<T: DeserializeOwned>(&self, name: &str) -> Result<T>`
  - Add `fn has_signal(&self, name: &str) -> bool`
  - Add `fn drain_signals<T: DeserializeOwned>(&self, name: &str) -> Result<Vec<T>>`

- [ ] Update `sdk-rust/worker-sdk/src/workflow/context_impl.rs`:
  - Implement `wait_for_signal()`:
    - Check replay engine signal queue first
    - If signal present, deserialize and return
    - If no signal, suspend workflow (set suspension cell)
  - Implement `has_signal()` - check queue without consuming
  - Implement `drain_signals()` - drain all signals from queue

- [ ] Create `sdk-rust/worker-sdk/src/workflow/signal.rs`:
  - `SignalFuture<T>` struct (similar to PromiseFuture pattern)
  - Implement `Future` trait
  - Implement `WorkflowFuturePoll` trait

- [ ] Update `sdk-rust/worker-sdk/src/workflow/future.rs`:
  - Export signal future types

### 1.11 Client API

- [ ] Update `sdk-rust/worker-sdk/src/client/flovyn_client.rs`:
  - Add `signal_with_start_workflow(options: SignalWithStartOptions) -> Result<SignalWithStartResponse>`
  - Add `signal_workflow(execution_id: &str, signal_name: &str, value: impl Serialize) -> Result<SignalResponse>`
  - Add `SignalWithStartOptions` struct
  - Add response types

### 1.12 FFI Layer (for Python/Kotlin)

- [x] Update `sdk-rust/worker-ffi/src/types.rs`:
  - Added `SignalReceived` variant to `FfiEventType` enum
  - Added bidirectional conversions

- [ ] Update `sdk-rust/worker-ffi/src/context.rs`:
  - Add `wait_for_signal(name: String) -> FfiSignalResult` FFI binding
  - Add `has_signal(name: String) -> bool` FFI binding
  - Add `drain_signals(name: String) -> Vec<FfiSignalEvent>` FFI binding
  - Add `FfiSignalResult` enum (Received/Pending variants)

- [ ] Update `sdk-rust/worker-ffi/src/client.rs`:
  - Add `signal_with_start_workflow(...)` FFI binding
  - Add `signal_workflow(...)` FFI binding

### 1.13 NAPI Layer (for TypeScript)

- [x] Update `sdk-rust/worker-napi/src/types.rs`:
  - Added `SignalReceived` variant to `NapiEventType` enum
  - Added bidirectional conversions

- [ ] Update `sdk-rust/worker-napi/src/context.rs`:
  - Add NAPI bindings for signal context methods

- [ ] Update `sdk-rust/worker-napi/src/client.rs`:
  - Add NAPI bindings for client signal methods

### 1.14 Testing Infrastructure

- [ ] Update `sdk-rust/worker-sdk/src/testing/mock_workflow_context.rs`:
  - Add `mock_signal(name: &str, value: serde_json::Value)` method
  - Add signal tracking: `received_signals: Vec<(String, Value)>`

- [ ] Update `sdk-rust/worker-sdk/src/testing/builders.rs`:
  - Add signal test builders if needed

### 1.15 SDK-Rust Tests

- [ ] Create `sdk-rust/worker-sdk/tests/e2e/signal_tests.rs`:
  - Test `wait_for_signal()` receives signal value
  - Test multiple signals with same name (queue semantics)
  - Test `has_signal()` returns true/false correctly
  - Test `drain_signals()` returns all buffered signals
  - Test signal replay (workflow crashes and restarts)
  - Test signal before `wait_for_signal()` is called (buffered)

- [ ] Create `sdk-rust/examples/patterns/src/signal_workflow.rs`:
  - Example conversation workflow using signals

---

## Phase 1: SDK-Python Implementation

### 1.16 Regenerate FFI Bindings

- [ ] Run FFI regeneration script to update `flovyn/_native/flovyn_worker_ffi.py`
  - This pulls new signal types from sdk-rust worker-ffi

### 1.17 Context Implementation

- [ ] Update `flovyn/context.py`:
  - Update `wait_for_signal()` implementation (currently proxies to promise)
  - Implement proper signal semantics using FFI `wait_for_signal()`
  - Add `has_signal(name: str) -> bool` method
  - Add `drain_signals(name: str, type_hint: type[T]) -> list[T]` method

### 1.18 Client Implementation

- [ ] Update `flovyn/client.py`:
  - Add `signal_with_start_workflow()` method
  - Add `signal_workflow()` method
  - Update `_create_workflow_handle()` to implement `send_signal()` (currently `pass`)

### 1.19 Testing

- [ ] Update `flovyn/testing/mocks.py`:
  - Update `mock_signal_value()` to support queue semantics (multiple values per name)
  - Update `MockWorkflowContext.wait_for_signal()` implementation

- [ ] Create `tests/e2e/test_signal.py`:
  - Test `wait_for_signal()` receives signal
  - Test `signal_with_start_workflow()` creates and signals
  - Test multiple signals with same name
  - Test signal replay after workflow restart

- [ ] Update `tests/e2e/fixtures/workflows.py`:
  - Add `SignalWorkflow` fixture that waits for signals

---

## Phase 1: SDK-Kotlin Implementation

### 1.20 Regenerate FFI Bindings

- [ ] Run `./bin/dev/update-native.sh` to regenerate UniFFI bindings
  - Updates `worker-native/uniffi/flovyn_worker_ffi/flovyn_worker_ffi.kt`

### 1.21 Signal Types

- [ ] Create `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/DurableSignal.kt`:
  - `DurableSignal<T>` interface
  - `ReceivedDurableSignal<T>` implementation
  - `PendingDurableSignal<T>` implementation

### 1.22 Context Implementation

- [ ] Update `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContext.kt`:
  - Add `suspend fun <T> waitForSignal(name: String): T`
  - Add `fun hasSignal(name: String): Boolean`
  - Add `suspend fun <T> drainSignals(name: String): List<T>`

- [ ] Update `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContextImpl.kt`:
  - Implement signal methods using FFI bindings

### 1.23 Client Implementation

- [ ] Update `worker-sdk/src/main/kotlin/ai/flovyn/sdk/client/FlovynClient.kt`:
  - Add `signalWithStartWorkflow()` method
  - Add `signalWorkflow()` method

- [ ] Update `worker-sdk/src/main/kotlin/ai/flovyn/core/CoreClientBridge.kt`:
  - Add bridge methods for signal operations

### 1.24 Testing

- [ ] Update `worker-sdk-jackson/src/test/kotlin/ai/flovyn/sdk/e2e/fixtures/Workflows.kt`:
  - Add `SignalWorkflow` fixture

- [ ] Create `worker-sdk-jackson/src/test/kotlin/ai/flovyn/sdk/e2e/SignalE2ETest.kt`:
  - Test signal operations

---

## Phase 1: SDK-TypeScript Implementation

### 1.25 Regenerate Native Bindings

- [ ] Rebuild worker-napi and update `packages/native/`:
  - `packages/native/generated.d.ts` - regenerate type definitions
  - `packages/native/src/index.ts` - re-export new signal bindings

### 1.26 Context Implementation

- [ ] Update `packages/sdk/src/context/workflow-context.ts`:
  - Add `waitForSignal<T>(name: string): Promise<T>` method
  - Add `hasSignal(name: string): boolean` method
  - Add `drainSignals<T>(name: string): T[]` method

### 1.27 Client Implementation

- [ ] Update `packages/sdk/src/client.ts`:
  - Add `signalWithStartWorkflow()` method
  - Add `signalWorkflow()` method

- [ ] Update `packages/sdk/src/handles.ts`:
  - Update `WorkflowHandle.signal()` method implementation

- [ ] Update `packages/sdk/src/types.ts`:
  - Add signal-related types

### 1.28 Worker Integration

- [ ] Update `packages/sdk/src/worker/workflow-worker.ts`:
  - Handle `Signal` activation job type (already defined in FFI)

### 1.29 Testing

- [ ] Update `packages/sdk/src/testing/mock-workflow-context.ts`:
  - Add signal mocking methods

- [ ] Create `tests/e2e/signal.test.ts`:
  - Test signal operations

- [ ] Update `tests/e2e/fixtures/workflows.ts`:
  - Add signal workflow fixtures

---

## Phase 1: Frontend Implementation

### 1.30 Event Span Types

- [ ] Update `flovyn-app/apps/web/lib/types/event-spans.ts`:
  - Add `SIGNAL = "SIGNAL"` to `SpanType` enum
  - Add signal-specific fields: `signalId?: string`, `signalName?: string`, `signalValue?: unknown`

### 1.31 Event Processing

- [ ] Update `flovyn-app/apps/web/lib/event-processing/buildEventSpans.ts`:
  - Add `case "SIGNAL_RECEIVED":` handler
  - Create span for each signal event (not merged like promises)
  - Store signal name and value in span properties
  - Handle instance numbering for multiple signals with same name

### 1.32 Signal Details Panel

- [ ] Create `flovyn-app/apps/web/components/events/SignalDetailsPanel.tsx`:
  - Follow PromiseDetailsPanel pattern but simpler (no action buttons)
  - Display signal name, value, and timestamp
  - Show in Events tab of workflow detail view

### 1.33 Panel Integration

- [ ] Update `flovyn-app/apps/web/components/events/EventDetailPanel.tsx`:
  - Add case for `SpanType.SIGNAL` to show SignalDetailsPanel

### 1.34 API Package

- [ ] Regenerate `flovyn-app/packages/api/` from updated server OpenAPI spec
  - New signal types and hooks will be auto-generated

### 1.35 Frontend Tests

- [ ] Update `flovyn-app/apps/web/lib/event-processing/__tests__/buildEventSpans.test.ts`:
  - Add tests for `SIGNAL_RECEIVED` event handling
  - Test multiple signals with same name
  - Test signal span properties

- [ ] Update `flovyn-app/apps/web/lib/test-utils/mocks/eventSpanFactory.ts`:
  - Add signal event fixtures

---

## Phase 1: Eventhook Integration

### 1.36 Route Configuration

- [ ] Update `flovyn-server/plugins/eventhook/src/domain/route.rs`:
  - Add `SignalWithStart(SignalWithStartTargetConfig)` variant to `TargetConfig` enum
  - Create `SignalWithStartTargetConfig` struct:
    ```rust
    pub struct SignalWithStartTargetConfig {
        pub workflow_kind: String,
        pub workflow_id_path: String,  // JMESPath to extract workflow ID
        pub signal_name: String,
        pub signal_value_path: Option<String>,  // JMESPath for signal value (defaults to full payload)
        pub queue: Option<String>,
    }
    ```

### 1.37 Processor Implementation

- [ ] Update `flovyn-server/plugins/eventhook/src/service/processor.rs`:
  - Add `TargetConfig::SignalWithStart` handling in `execute_target()`
  - Call server's `SignalWithStartWorkflow` RPC or internal method

### 1.38 Eventhook Tests

- [ ] Create eventhook integration test for signal_with_start target:
  - Test webhook routes to SignalWithStart
  - Test workflow_id extraction from payload
  - Test signal value extraction

---

## Phase 2: Verification

### 2.1 End-to-End Testing

- [ ] Run full E2E test suite across all SDKs
- [ ] Test conversation workflow pattern (chatbot use case from design doc)
- [ ] Test concurrent SignalWithStart calls (stress test atomicity)
- [ ] Test signal replay after worker restart
- [ ] Test signal limit enforcement (10k signals)

### 2.2 Manual Testing

- [ ] Test signal workflow in Flovyn App UI
- [ ] Verify SignalDetailsPanel displays correctly
- [ ] Test eventhook webhook → SignalWithStart flow

---

## Phase 3: Remove Promises

After Phase 2 verification confirms signals work correctly, remove all promise code.

### 3.1 Server: Remove Promise Infrastructure

- [ ] Create migration `server/migrations/YYYYMMDDHHMMSS_drop_promise_table.sql`:
  - Drop `promise` table (existing promise events in `workflow_event` remain for historical record)
- [ ] Remove `server/src/repository/promise_repository.rs`
- [ ] Remove `server/src/api/rest/promises.rs`
- [ ] Update `server/proto/flovyn.proto`:
  - Remove `ResolvePromise`, `RejectPromise` RPCs
  - Remove `CREATE_PROMISE`, `RESOLVE_PROMISE` command types
- [ ] Update `server/src/api/grpc/workflow_dispatch.rs`:
  - Remove promise command handling
- [ ] Update `server/src/api/rest/mod.rs`:
  - Remove promise route registration
- [ ] Update `server/src/api/rest/openapi.rs`:
  - Remove promise endpoints and DTOs
- [ ] Update `server/src/repository/mod.rs`:
  - Remove promise module
- [ ] Update `server/src/scheduler.rs`:
  - Remove promise timeout handling

### 3.2 SDK-Rust: Remove Promise Code

- [ ] Remove `sdk-rust/examples/patterns/src/promise_workflow.rs`
- [ ] Remove `sdk-rust/worker-sdk/tests/e2e/promise_tests.rs`
- [ ] Remove promise replay corpus files if any
- [ ] Update `worker-sdk/src/workflow/context.rs`:
  - Remove `promise_*` methods and `PromiseOptions`
- [ ] Update `worker-sdk/src/workflow/future.rs`:
  - Remove `PromiseFuture`, `PromiseFutureRaw`
- [ ] Update `worker-core/src/workflow/command.rs`:
  - Remove `CreatePromise`, `ResolvePromise` commands
- [ ] Update `worker-core/src/workflow/event.rs`:
  - Remove `PromiseCreated`, `PromiseResolved`, `PromiseRejected`, `PromiseTimeout` event types
- [ ] Update `worker-core/src/workflow/replay_engine.rs`:
  - Remove promise sequence tracking and terminal event lookup
- [ ] Update `worker-ffi/src/*`:
  - Remove promise FFI bindings
- [ ] Update `worker-napi/src/*`:
  - Remove promise NAPI bindings
- [ ] Sync `worker-core/proto/flovyn.proto` with server

### 3.3 SDK-Python: Remove Promise Code

- [ ] Remove `tests/e2e/test_promise.py`
- [ ] Update `flovyn/context.py`:
  - Remove `promise()` method and promise-related imports
- [ ] Update `flovyn/testing/mocks.py`:
  - Remove `mock_promise_value()` and promise mock logic
- [ ] Update `tests/e2e/fixtures/workflows.py`:
  - Remove promise workflow fixtures
- [ ] Regenerate FFI bindings (promise methods removed)

### 3.4 SDK-Kotlin: Remove Promise Code

- [ ] Remove `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/DurablePromise.kt`
- [ ] Update `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContext.kt`:
  - Remove promise methods
- [ ] Update `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContextImpl.kt`:
  - Remove promise implementation
- [ ] Update `worker-sdk-jackson/src/test/kotlin/ai/flovyn/sdk/e2e/fixtures/Workflows.kt`:
  - Remove promise fixtures
- [ ] Regenerate UniFFI bindings

### 3.5 SDK-TypeScript: Remove Promise Code

- [ ] Remove `tests/e2e/promise.test.ts`
- [ ] Update `packages/sdk/src/context/workflow-context.ts`:
  - Remove promise methods
- [ ] Update `packages/sdk/src/testing/mock-workflow-context.ts`:
  - Remove promise mocks
- [ ] Update `tests/e2e/fixtures/workflows.ts`:
  - Remove promise fixtures
- [ ] Regenerate native bindings

### 3.6 Frontend: Remove Promise UI

- [ ] Remove `flovyn-app/apps/web/components/events/PromiseDetailsPanel.tsx`
- [ ] Update `flovyn-app/apps/web/lib/types/event-spans.ts`:
  - Remove `SpanType.PROMISE` and promise-specific fields
- [ ] Update `flovyn-app/apps/web/lib/event-processing/buildEventSpans.ts`:
  - Remove `PROMISE_CREATED`, `PROMISE_RESOLVED`, `PROMISE_REJECTED` handlers
- [ ] Regenerate `flovyn-app/packages/api/` (promise hooks removed)

### 3.7 Eventhook: Remove Promise Target

- [ ] Update `flovyn-server/plugins/eventhook/src/domain/route.rs`:
  - Remove `Promise(PromiseTargetConfig)` variant from `TargetConfig`
- [ ] Update `flovyn-server/plugins/eventhook/src/service/processor.rs`:
  - Remove promise target handling

### 3.8 Final Verification

- [ ] Run full test suite across all projects (no promise references remain)
- [ ] Verify build succeeds with no dead code warnings related to promises

---

## Rollout Considerations

1. **Backward Compatibility**: Signal code is additive. Existing promise workflows continue to work during Phase 1.

2. **Feature Flag**: Consider adding a feature flag to enable SignalWithStart endpoints separately from the rest of the signal implementation.

3. **Monitoring**: Add metrics for:
   - Signal events created per minute
   - SignalWithStart calls (created vs signaled existing)
   - Signal limit rejections

4. **Documentation**: Update SDK documentation before release:
   - Migration guide from promises to signals
   - Signal best practices (naming conventions, payload size)
   - SignalWithStart usage examples

---

## Test Plan Summary

| Component | Test Type | Test File |
|-----------|-----------|-----------|
| Server | Integration | `tests/integration/signal_test.rs` |
| SDK-Rust | E2E | `worker-sdk/tests/e2e/signal_tests.rs` |
| SDK-Python | E2E | `tests/e2e/test_signal.py` |
| SDK-Kotlin | E2E | `worker-sdk-jackson/.../SignalE2ETest.kt` |
| SDK-TypeScript | E2E | `tests/e2e/signal.test.ts` |
| Frontend | Unit | `buildEventSpans.test.ts` |
| Eventhook | Integration | TBD |

---

## Dependencies

```
                    ┌─────────────────┐
                    │  flovyn-server  │
                    │   (Phase 1.1-1.7)│
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
    ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
    │  sdk-rust   │  │  flovyn-app │  │  eventhook  │
    │  worker-core│  │  (1.30-1.35)│  │  (1.36-1.38)│
    │  (1.8-1.15) │  └─────────────┘  └─────────────┘
    └──────┬──────┘
           │
    ┌──────┴──────┐
    │             │
    ▼             ▼
┌────────┐  ┌────────┐
│worker- │  │worker- │
│  ffi   │  │  napi  │
│(1.12)  │  │(1.13)  │
└────┬───┘  └────┬───┘
     │           │
     ▼           ▼
┌─────────┐  ┌──────────┐
│sdk-python│ │sdk-typescript│
│(1.16-1.19)│ │(1.25-1.29)   │
└─────────┘  └──────────┘
     │
     ▼
┌─────────┐
│sdk-kotlin│
│(1.20-1.24)│
└─────────┘
```

**Critical Path**: Server → SDK-Rust worker-core → FFI layers → Language SDKs

The frontend and eventhook can be developed in parallel with SDK work after server is complete.
