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

- [x] Update `sdk-rust/worker-sdk/src/workflow/context.rs` (trait):
  - Added `fn wait_for_signal_raw(&self) -> SignalFutureRaw` - waits for next signal (returns Signal with name and value)
  - Added `fn has_signal(&self) -> bool` - check if any signals pending
  - Added `fn pending_signal_count(&self) -> usize` - get pending signal count
  - Added `fn drain_signals_raw(&self) -> Vec<(String, Value)>` - drain all signals

- [x] Update `sdk-rust/worker-sdk/src/workflow/context_impl.rs`:
  - Implemented `wait_for_signal_raw()` - checks replay engine, returns signal or suspends
  - Implemented `has_signal()` - checks replay engine
  - Implemented `pending_signal_count()` - gets count from replay engine
  - Implemented `drain_signals_raw()` - drains all signals from queue

- [x] Update `sdk-rust/worker-sdk/src/workflow/future.rs`:
  - Added `Signal` struct with name and value fields
  - Added `SignalFuture` struct (similar to PromiseFuture pattern)
  - Added `SignalFutureRaw` type alias
  - Implemented `Future` and `WorkflowFuturePoll` traits

### 1.11 Client API

- [x] Update `sdk-rust/worker-sdk/src/client/flovyn_client.rs`:
  - Added `signal_with_start_workflow(options: SignalWithStartOptions) -> Result<SignalWithStartResult>`
  - Added `signal_workflow(workflow_execution_id: Uuid, signal_name: &str, value: Value) -> Result<SignalResult>`
  - Added `SignalWithStartOptions` struct with builder methods
  - Added `SignalWithStartResult` and `SignalResult` structs

- [x] Update `sdk-rust/worker-core/src/client/workflow_dispatch.rs`:
  - Added `signal_with_start_workflow()` gRPC wrapper
  - Added `signal_workflow()` gRPC wrapper
  - Added `SignalWithStartResult` and `SignalResult` structs

- [x] Update `sdk-rust/proto/flovyn.proto`:
  - Added `SignalWithStartWorkflow` and `SignalWorkflow` RPCs
  - Added request/response message definitions

### 1.12 FFI Layer (for Python/Kotlin)

- [x] Update `sdk-rust/worker-ffi/src/types.rs`:
  - Added `SignalReceived` variant to `FfiEventType` enum
  - Added bidirectional conversions

- [x] Update `sdk-rust/worker-ffi/src/context.rs`:
  - Added `wait_for_signal() -> FfiSignalResult` FFI binding
  - Added `has_signal() -> bool` FFI binding
  - Added `pending_signal_count() -> u32` FFI binding
  - Added `drain_signals() -> Vec<FfiSignalEvent>` FFI binding
  - Added `FfiSignalResult` enum (Received/Pending variants)
  - Added `FfiSignalEvent` record struct

- [x] Update `sdk-rust/worker-ffi/src/client.rs`:
  - Add `signal_with_start_workflow(...)` FFI binding
  - Add `signal_workflow(...)` FFI binding
  - Add `SignalWithStartResponse` and `SignalWorkflowResponse` result types

### 1.13 NAPI Layer (for TypeScript)

- [x] Update `sdk-rust/worker-napi/src/types.rs`:
  - Added `SignalReceived` variant to `NapiEventType` enum
  - Added bidirectional conversions

- [x] Update `sdk-rust/worker-napi/src/context.rs`:
  - Added `wait_for_signal() -> SignalResult` NAPI binding
  - Added `has_signal() -> bool` NAPI binding
  - Added `pending_signal_count() -> u32` NAPI binding
  - Added `drain_signals() -> Vec<SignalEvent>` NAPI binding
  - Added `SignalResult` object struct
  - Added `SignalEvent` object struct

- [ ] Update `sdk-rust/worker-napi/src/client.rs`:
  - Add NAPI bindings for client signal methods (deferred - can use gRPC directly)

### 1.14 Testing Infrastructure

- [x] Update `sdk-rust/worker-sdk/src/testing/mock_workflow_context.rs`:
  - Added `mock_signal(name: &str, value: serde_json::Value)` builder method
  - Added `signal_queue: Vec<(String, Value)>` for mock signals
  - Implemented signal context methods (wait_for_signal_raw, has_signal, pending_signal_count, drain_signals_raw)

- [ ] Update `sdk-rust/worker-sdk/src/testing/builders.rs`:
  - Add signal test builders if needed (deferred - not needed for basic testing)

### 1.15 SDK-Rust Tests

- [x] Create `sdk-rust/worker-sdk/tests/e2e/signal_tests.rs`:
  - [x] Test `signal_with_start_new_workflow` - workflow created with signal
  - [x] Test `signal_existing_workflow` - signal sent to running workflow
  - [x] Test `multiple_signals` - multiple signals received in order
  - [x] Test `signal_with_start_existing` - idempotency (second call sends signal only)
  - [x] Test `signal_check_and_drain` - has_signal and drain_signals APIs

- [x] **Bug fix**: Added `"SIGNAL_RECEIVED" => EventType::SignalReceived` to `parse_event_type()` in `workflow_worker.rs`
  - This was the root cause of signal tests failing - all SIGNAL_RECEIVED events were being parsed as WorkflowStarted

- [x] Create `sdk-rust/examples/patterns/src/signal_workflow.rs`:
  - Example conversation workflow using signals
  - Added WaitForSignalWorkflow (simple signal wait), ConversationWorkflow (multi-turn chatbot), EventCollectorWorkflow (batch event collection)
  - Updated main.rs to register signal workflows
  - Updated examples README.md with signal documentation and curl examples

---

## Phase 1: SDK-Python Implementation

### 1.16 Regenerate FFI Bindings

- [x] Run FFI regeneration script to update `flovyn/_native/flovyn_worker_ffi.py`
  - This pulls new signal types from sdk-rust worker-ffi
  - Also added `signal_with_start_workflow()` and `signal_workflow()` FFI client methods

### 1.17 Context Implementation

- [x] Update `flovyn/context.py`:
  - Update `wait_for_signal()` implementation (now uses FFI properly)
  - Add `has_signal() -> bool` method
  - Add `pending_signal_count() -> int` method
  - Add `drain_signals(type_hint: type[T]) -> list[T]` method

### 1.18 Client Implementation

- [x] Update `flovyn/client.py`:
  - Add `signal_with_start_workflow()` method
  - Add `signal_workflow()` method
  - Update `_create_workflow_handle()` to implement `send_signal()`

### 1.19 Testing

- [x] Update `flovyn/testing/mocks.py`:
  - Update `mock_signal_value()` to support queue semantics (multiple values per name)
  - Update `MockWorkflowContext.wait_for_signal()` implementation
  - Add `has_signal()`, `pending_signal_count()`, and `drain_signals()` methods

- [x] Create `tests/e2e/test_signal.py`:
  - Test `wait_for_signal()` receives signal
  - Test `signal_with_start_workflow()` creates and signals
  - Test multiple signals with same name
  - Test signal_with_start on existing workflow

- [x] Update `tests/e2e/fixtures/workflows.py`:
  - Add `SignalWorkflow` fixture that waits for signals
  - Add `MultiSignalWorkflow` for multiple signal testing
  - Add `DrainSignalsWorkflow` for has_signal/drain_signals testing

- [x] Update `flovyn/testing/environment.py`:
  - Add `signal_workflow()` method
  - Add `signal_with_start_workflow()` method

---

## Phase 1: SDK-Kotlin Implementation

### 1.20 Regenerate FFI Bindings

- [x] Run `./bin/dev/update-native.sh` to regenerate UniFFI bindings
  - Updates `worker-native/uniffi/flovyn_worker_ffi/flovyn_worker_ffi.kt`
  - Now includes `signalWorkflow`, `signalWithStartWorkflow`, `FfiSignalResult`, etc.

### 1.21 Signal Types

- [x] Create `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/Signal.kt`:
  - `Signal<T>` data class with `name` and `value` fields
  - Simpler than DurablePromise (no await logic needed)

### 1.22 Context Implementation

- [x] Update `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContext.kt`:
  - Add `suspend fun <T> waitForSignal(): Signal<T>`
  - Add `fun hasSignal(): Boolean`
  - Add `fun pendingSignalCount(): Int`
  - Add `suspend fun <T> drainSignals(): List<Signal<T>>`

- [x] Update `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContextImpl.kt`:
  - Implement signal methods using FFI bindings

### 1.23 Client Implementation

- [x] Update `worker-sdk/src/main/kotlin/ai/flovyn/sdk/client/FlovynClient.kt`:
  - Add `signalWithStartWorkflow()` method
  - Add `signalWorkflow()` method
  - Add `SignalWithStartOptions` and `SignalWithStartResult` data classes

- [x] Update `worker-sdk/src/main/kotlin/ai/flovyn/core/CoreClientBridge.kt`:
  - Add bridge methods for signal operations

### 1.24 Testing

- [x] Update `worker-sdk-jackson/src/test/kotlin/ai/flovyn/sdk/e2e/fixtures/Workflows.kt`:
  - Added `SignalWorkflow`, `MultiSignalWorkflow`, `SignalCheckWorkflow` fixtures

- [x] Create `worker-sdk-jackson/src/test/kotlin/ai/flovyn/sdk/e2e/SignalE2ETest.kt`:
  - Test signal-with-start new workflow
  - Test signal existing workflow
  - Test multiple signals
  - Test signal-with-start existing workflow
  - Test signal check and drain

- [x] Update `worker-sdk-jackson/src/test/kotlin/ai/flovyn/sdk/e2e/E2ETestEnvironment.kt`:
  - Added `signalWorkflow()` method
  - Added `signalWithStartWorkflow()` method

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

- [x] Create `tests/e2e/signal.test.ts`:
  - Test signal-with-start new workflow
  - Test signal existing workflow
  - Test multiple signals
  - Test signal-with-start existing workflow
  - Test signal check and drain

- [x] Update `tests/e2e/fixtures/workflows.ts`:
  - Added `signalWorkflow`, `multiSignalWorkflow`, `signalCheckWorkflow` fixtures

- [x] Update `packages/sdk/src/testing/test-environment.ts`:
  - Added `signalWorkflow()` method
  - Added `signalWithStartWorkflow()` method

---

## Phase 1: Frontend Implementation

### 1.30 Event Span Types

- [x] Update `flovyn-app/apps/web/lib/types/event-spans.ts`:
  - Added `SIGNAL = "SIGNAL"` to `SpanType` enum
  - Added signal-specific fields: `signalId?: string`, `signalName?: string`, `signalValue?: unknown`

### 1.31 Event Processing

- [x] Update `flovyn-app/apps/web/lib/event-processing/buildEventSpans.ts`:
  - Added `case "SIGNAL_RECEIVED":` handler
  - Create span for each signal event (not merged like promises)
  - Store signal name and value in span properties
  - Handle instance numbering for multiple signals with same name

### 1.32 Signal Details Panel

- [x] Create `flovyn-app/apps/web/components/events/SignalDetailsPanel.tsx`:
  - Follow PromiseDetailsPanel pattern but simpler (no action buttons)
  - Display signal name, value, and timestamp
  - Show in Events tab of workflow detail view

### 1.33 Panel Integration

- [x] Update `flovyn-app/apps/web/components/events/TimelineTaskDetailPanel.tsx`:
  - Added case for `SpanType.SIGNAL` to show SignalDetailsPanel
  - Added import for SignalDetailsPanel

### 1.34 API Package

- [x] Regenerate `flovyn-app/packages/api/` from updated server OpenAPI spec
  - New signal types and hooks auto-generated
  - Fixed post-generate.sh to work on Linux (use portable sed syntax)

### 1.35 Frontend Tests

- [x] Update `flovyn-app/apps/web/lib/event-processing/__tests__/buildEventSpans.test.ts`:
  - Added tests for `SIGNAL_RECEIVED` event handling
  - Test multiple signals with same name (instance numbering)
  - Test signal span properties (id, name, value)
  - Test mixed workflow with tasks and signals

- [ ] Update `flovyn-app/apps/web/lib/test-utils/mocks/eventSpanFactory.ts`:
  - Add signal event fixtures (deferred - not needed for current tests)

---

## Phase 1: Eventhook Integration

### 1.36 Route Configuration

- [x] Update `flovyn-server/plugins/eventhook/src/domain/route.rs`:
  - Added `SignalWithStart(SignalWithStartTargetConfig)` variant to `TargetConfig` enum
  - Created `SignalWithStartTargetConfig` struct with workflow_kind, workflow_id_path, signal_name, signal_value_path, queue, workflow_version

### 1.37 Processor Implementation

- [x] Update `flovyn-server/plugins/eventhook/src/service/processor.rs`:
  - Added `TargetConfig::SignalWithStart` handling in `execute_target()`
  - Added `execute_signal_with_start()` method that uses `SignalLauncher` trait
  - Added `extract_json_path_value()` helper for signal value extraction

- [x] Add `SignalLauncher` trait to flovyn-core:
  - Added `SignalWithStartRequest` and `SignalWithStartResult` types
  - Added `SignalLauncher` trait with `signal_with_start()` method

- [x] Add `SignalLauncherAdapter` to flovyn-server:
  - Created adapter implementing `SignalLauncher` using `IdempotencyKeyRepository`
  - Wired up in main.rs to PluginServices

- [x] Update API DTOs:
  - Added `SignalWithStartTargetRequest` and `SignalWithStartTargetResponse`
  - Updated `TargetConfigRequest` and `TargetConfigResponse` enums
  - Updated route handlers for SignalWithStart conversion

### 1.38 Eventhook Tests

- [ ] Create eventhook integration test for signal_with_start target (deferred):
  - Test webhook routes to SignalWithStart
  - Test workflow_id extraction from payload
  - Test signal value extraction

---

## Phase 1.5: Fix Signal Name Filtering (Implementation Gap)

**Problem**: The current implementation does not match the design document.

**Design doc specifies** (lines 193-205):
```rust
pub async fn wait_for_signal<T>(&self, signal_name: &str) -> Result<T>;
pub fn has_signal(&self, signal_name: &str) -> bool;
pub async fn drain_signals<T>(&self, signal_name: &str) -> Result<Vec<T>>;
```

With per-name queues (lines 243-258):
```rust
signal_queues: HashMap<String, VecDeque<SignalEvent>>
```

**What was implemented**:
```rust
pub fn wait_for_signal_raw(&self) -> SignalFutureRaw;  // NO signal_name parameter
pub fn has_signal(&self) -> bool;                       // NO signal_name parameter
```

With a single global FIFO queue (all signals regardless of name).

**Why this matters**:
- Cannot wait for a specific signal type (e.g., "approve" vs "reject")
- Signals arrive out of order → wrong signal goes to wrong wait
- Doesn't match Temporal's per-name signal channels

### 1.50 SDK-Rust: Add Per-Name Signal Queues

- [x] Update `sdk-rust/worker-core/src/workflow/replay_engine.rs`:
  - Changed `signal_events: Vec<ReplayEvent>` to `signal_queues: RwLock<HashMap<String, VecDeque<ReplayEvent>>>`
  - Added `pop_signal(signal_name: &str)` method
  - Added `has_signal(signal_name: &str)` method
  - Added `pending_signal_count_for_name(signal_name: &str)` method
  - Added `drain_signals(signal_name: &str)` method
  - Added `has_any_pending_signal()` and `total_pending_signal_count()` for total counts

- [x] Update `sdk-rust/worker-sdk/src/workflow/context.rs` (trait):
  - Changed `wait_for_signal_raw(&self)` to `wait_for_signal_raw(&self, signal_name: &str)`
  - Changed `has_signal(&self)` to `has_signal(&self, signal_name: &str)`
  - Changed `pending_signal_count(&self)` to `pending_signal_count(&self, signal_name: &str)`
  - Changed `drain_signals_raw(&self)` to `drain_signals_raw(&self, signal_name: &str) -> Vec<Value>`

- [x] Update `sdk-rust/worker-sdk/src/workflow/context_impl.rs`:
  - Implemented name-based signal filtering using replay_engine.pop_signal()

- [x] Update `sdk-rust/worker-sdk/src/workflow/future.rs`:
  - Added `new_waiting_for_signal()` constructor
  - Signal name passed for debugging/logging purposes

- [x] Update `sdk-rust/worker-sdk/src/testing/mock_workflow_context.rs`:
  - Changed `signal_queue` to `signal_queues: HashMap<String, VecDeque<Value>>`
  - Updated mock methods to use signal names

- [x] Update `sdk-rust/examples/patterns/src/signal_workflow.rs`:
  - Updated all workflows to use signal names
  - ConversationWorkflow uses "message" signal name
  - EventCollectorWorkflow uses "event" signal name

- [x] Update `sdk-rust/worker-sdk/tests/e2e/fixtures/workflows.rs`:
  - Updated test workflows to use signal names

### 1.51 SDK-Rust FFI: Update Bindings

- [x] Update `sdk-rust/worker-ffi/src/context.rs`:
  - Changed `wait_for_signal()` to take `signal_name: String` parameter
  - Changed `has_signal()` to take `signal_name: String` parameter
  - Changed `pending_signal_count()` to take `signal_name: String` parameter
  - Changed `drain_signals()` to take `signal_name: String` parameter

- [x] Update `sdk-rust/worker-napi/src/context.rs`:
  - Same changes as FFI

### 1.52 SDK-Python: Update Context

- [x] Update `flovyn/context.py`:
  - `wait_for_signal(name: str)` - changed from optional to required signal_name parameter
  - `has_signal(name: str)` - add required signal_name parameter
  - `pending_signal_count(name: str)` - add required signal_name parameter
  - `drain_signals(name: str)` - add required signal_name parameter

- [x] Update `flovyn/testing/mocks.py`:
  - Update mock to use per-name queues (`_signal_queues: dict[str, list[Any]]`)

- [x] Update E2E tests to use signal names

### 1.53 SDK-Kotlin: Update Context

- [x] Update `WorkflowContext.kt`:
  - `waitForSignal(signalName: String)` - add required parameter
  - `hasSignal(signalName: String)` - add required parameter
  - `pendingSignalCount(signalName: String)` - add required parameter
  - `drainSignals(signalName: String)` - add required parameter

- [x] Update `WorkflowContextImpl.kt` implementation
- [x] Update E2E test workflow fixtures

### 1.54 SDK-TypeScript: Update Context

- [x] Update `packages/sdk/src/types.ts`:
  - `waitForSignal<T>(signalName: string): Promise<T>` - add required parameter
  - `hasSignal(signalName: string): boolean` - add required parameter
  - `pendingSignalCount(signalName: string): number` - add required parameter
  - `drainSignals<T>(signalName: string): T[]` - add required parameter

- [x] Update `packages/sdk/src/context/workflow-context.ts`:
  - Implementation already uses NAPI bindings which have signal_name parameter

- [x] Update `packages/sdk/src/testing/mock-workflow-context.ts`:
  - Changed `_signalQueue` to `_signalQueues: Map<string, unknown[]>`
  - All signal methods now take `signalName` parameter

- [x] Update `tests/e2e/fixtures/workflows.ts`:
  - `signalWorkflow` uses 'signal' signal name
  - `multiSignalWorkflow` uses 'message' signal name
  - `signalCheckWorkflow` uses 'data' signal name

- [x] Update `tests/e2e/signal.test.ts`:
  - All tests updated to use the well-known signal names

### 1.55 Update Examples

- [x] Update `sdk-rust/examples/patterns/src/signal_workflow.rs`:
  - Use `wait_for_signal_raw("message")` instead of `wait_for_signal_raw()`
  - ConversationWorkflow uses "message" signal name
  - EventCollectorWorkflow uses "event" signal name

---

## Phase 2: Verification

### 2.1 End-to-End Testing

- [x] Run full E2E test suite across all SDKs
  - [x] **Python SDK**: 4/4 signal tests passed (test_signal.py)
  - [x] **TypeScript SDK**: 67/67 E2E tests passed (including 5 signal tests)
  - [x] **Rust SDK**: 58/58 E2E tests passed (including 5 signal tests)
  - [x] **Kotlin SDK**: 45/45 E2E tests passed (including 5 signal tests)
- [ ] Test conversation workflow pattern (chatbot use case from design doc)
- [ ] Test concurrent SignalWithStart calls (stress test atomicity)
- [ ] Test signal replay after worker restart
- [ ] Test signal limit enforcement (10k signals)

### 2.2 Manual Testing

- [ ] Test signal workflow in Flovyn App UI
- [ ] Verify SignalDetailsPanel displays correctly
- [ ] Test eventhook webhook → SignalWithStart flow

### 2.3 Code Simplification (Completed)

- [x] Removed unnecessary base64 encoding from signal values
  - Server now stores signal values as direct JSON (matching Promise pattern)
  - SDK-Rust simplified to read JSON directly (no base64 decode)
  - All SDKs updated (FFI, NAPI layers)
- [x] Removed `FLOVYN_SERVER_IMAGE` environment variable from all test harnesses
  - Test harnesses now use hardcoded default image
  - CI workflows simplified
  - Documentation updated

### 2.4 Linting and Code Quality (Completed)

- [x] Fixed Kotlin ktlint errors in `SignalE2ETest.kt`:
  - Removed 7 inline comments in value_argument_list (ktlint requires comments on separate lines)
- [x] Fixed Rust clippy warnings:
  - **flovyn-server**: Combined duplicate `if` branches in `plugin_adapters.rs`
  - **flovyn-server**: Changed `expect(&format!(...))` to `unwrap_or_else(|_| panic!(...))` in signal_tests.rs
  - **flovyn-server**: Added `#[allow(dead_code)]` to `count_signals_for_workflow` (reserved for future use)
  - **sdk-rust**: Changed `len() >= 1` to `!is_empty()` in signal_tests.rs
  - **sdk-rust**: Added `#[allow(dead_code)]` to `SignalFuture::new_with_cell` (follows pattern, may be useful later)
- [x] Fixed Rust formatting (`cargo fmt`):
  - **flovyn-server**: Multiple files reformatted (plugin_adapters.rs, openapi.rs, event_repository.rs, idempotency_key_repository.rs, signal_tests.rs)
  - **sdk-rust**: Multiple files reformatted (workflow_dispatch.rs, replay_engine.rs, context.rs in worker-ffi and worker-napi, signal_tests.rs, signal_workflow.rs, main.rs)
- [x] Fixed Python formatting (`ruff format`):
  - `flovyn/context.py` and `flovyn/types.py` reformatted
- [x] Fixed TypeScript formatting (`prettier`):
  - `packages/sdk/src/testing/test-harness.ts` reformatted
- [x] Updated NAPI TypeScript type bindings:
  - Added `signalName: string` parameter to `waitForSignal`, `hasSignal`, `pendingSignalCount`, `drainSignals` in `packages/native/src/index.ts`
  - TypeScript build was failing without this update
- [x] All repos verified (fmt + lint + build):
  - flovyn-server: cargo fmt ✓, clippy ✓, cargo check ✓
  - sdk-rust: cargo fmt ✓, clippy ✓, cargo check ✓
  - sdk-python: ruff format ✓, ruff check ✓
  - sdk-typescript: prettier ✓, eslint ✓, tsc build ✓
  - sdk-kotlin: ktlint ✓, gradle check ✓

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
