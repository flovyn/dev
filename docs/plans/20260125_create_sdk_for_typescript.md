# Implementation Plan: TypeScript SDK

**Design**: [20260124_create_sdk_for_typescript.md](../design/20260124_create_sdk_for_typescript.md)
**Created**: 2026-01-25

## Overview

This plan implements the TypeScript SDK in phases, following the proven patterns from Python and Kotlin SDKs. The work spans two codebases:

- **sdk-rust/worker-napi**: New Rust crate with NAPI-RS bindings (lives alongside worker-ffi)
- **sdk-typescript**: New repository with `@flovyn/native` and `@flovyn/sdk` packages

## Phase 1: Rust NAPI-RS Bindings (worker-napi)

Create the NAPI-RS crate that wraps `worker-core`, following the same pattern as `worker-ffi`.

### 1.1 Crate Setup

- [x] Create `sdk-rust/worker-napi/` directory structure
- [x] Create `Cargo.toml` with dependencies:
  - `napi = "2"`, `napi-derive = "2"`
  - `flovyn-worker-core` (workspace dependency)
  - `tokio = { version = "1", features = ["rt-multi-thread"] }`
  - `serde_json = "1.0"`
- [x] Create `build.rs` for NAPI-RS build configuration
- [x] Create `package.json` for npm package metadata (`@flovyn/native`)
- [x] Add `worker-napi` to `sdk-rust/Cargo.toml` workspace members
- [x] Create platform-specific npm package directories under `npm/` (following NAPI-RS convention)

### 1.2 Core Types

Implement data types that will be auto-generated to TypeScript definitions.

- [x] Create `src/lib.rs` - Module entry point with `#[napi]` setup
- [x] Create `src/error.rs` - Error conversions to `napi::Error`
- [x] Create `src/config.rs` - Configuration types:
  - `WorkerConfig` struct with server URL, org ID, queue, auth options
  - `OAuth2Credentials` struct
  - All fields with `#[napi(object)]` for TypeScript generation

### 1.3 Activation Types

- [x] Create `src/activation.rs`:
  - `WorkflowActivationData` (plain object) with jobs and replay events
  - `TaskActivationData` (plain object) with metadata
  - `WorkflowCompletionStatus` enum (Completed, Suspended, Cancelled, Failed)
  - `TaskCompletion` struct
  - `WorkflowActivationJob` variants (initialize, fire_timer, signal, query, cancel_workflow)

### 1.4 Context Implementations

- [x] Create `src/context.rs`:
  - `NapiWorkflowContext` with `ReplayEngine` from worker-core
  - Result types inline in context: `TaskResult`, `PromiseResult`, `TimerResult`, `ChildWorkflowResult`, `OperationResult`
  - Methods: `schedule_task`, `start_timer`, `create_promise`, `schedule_child_workflow`, `run_operation`, `record_operation_result`, `current_time_millis`, `random_uuid`, `random`, `get_state`, `set_state`, `clear_state`, `is_cancellation_requested`, `take_commands`, `get_commands_json`

### 1.5 Worker Implementation

- [x] Create `src/worker.rs`:
  - `NapiWorker` struct with gRPC clients for workflow dispatch and task execution
  - Constructor with `WorkerConfig`
  - Async methods: `register()`, `poll_workflow_activation()`, `poll_task_activation()`
  - Methods: `complete_workflow_activation()`, `complete_task()`
  - Shutdown: `shutdown()`, `is_shutdown_requested` getter
  - Lifecycle: `pause()`, `resume()`, `poll_lifecycle_events()`
  - Helper function `parse_commands_from_json()` for command JSON parsing

### 1.6 Client Implementation

- [x] Create `src/client.rs`:
  - `NapiClient` struct for workflow operations (not worker polling)
  - Methods: `start_workflow()`, `query_workflow()`, `resolve_promise()`, `reject_promise()`

### 1.7 Build & Verification

- [x] Verify code compiles: `cargo check -p flovyn-worker-napi`
- [x] Verify unit tests pass: `cargo test -p flovyn-worker-napi` (18 tests)
- [ ] Verify TypeScript definitions are generated correctly (`index.d.ts`)
- [ ] Build for current platform: `napi build --release`
- [ ] Test basic round-trip: create worker, get types in Node.js

## Phase 2: TypeScript Package Setup (sdk-typescript)

Set up the TypeScript monorepo with proper tooling.

### 2.1 Repository Structure

- [x] Create `sdk-typescript/` directory
- [x] Create `pnpm-workspace.yaml` with packages config
- [x] Create root `package.json` with workspace scripts
- [x] Create `tsconfig.base.json` with shared compiler options
- [x] Create `eslint.config.js` and `.prettierrc` for code quality
- [x] Create `vitest.config.ts` for testing
- [x] Create `CLAUDE.md` with project-specific guidance

### 2.2 @flovyn/native Package

- [x] Create `packages/native/package.json`
- [x] Create `packages/native/src/index.ts` - Re-exports from generated bindings with type definitions
- [x] Create `packages/native/src/loader.ts` - Platform detection and binary loading
- [x] Set up NAPI-RS binary resolution for development (from `sdk-rust/worker-napi/target`)
- [ ] Verify native module loads correctly in Node.js (requires building native module)

### 2.3 @flovyn/sdk Package

- [x] Create `packages/sdk/package.json` with dependency on `@flovyn/native`
- [x] Create `packages/sdk/tsconfig.json` extending base config
- [x] Create `packages/sdk/src/index.ts` - Public API exports
- [x] Create `packages/sdk/src/duration.ts` - Duration utilities
- [x] Create `packages/sdk/src/errors.ts` - Error types
- [x] Create `packages/sdk/src/types.ts` - Type definitions
- [x] Create `packages/sdk/src/testing/index.ts` - Testing exports stub

## Phase 3: Core SDK Implementation

Implement the high-level TypeScript API.

### 3.1 Duration & Utilities

- [x] Create `packages/sdk/src/duration.ts`:
  - `Duration` class with static factories (`milliseconds`, `seconds`, `minutes`, `hours`, `days`)
  - `toMilliseconds()` method for internal use
  - Additional methods: `divide()`, `isGreaterThan()`, `isLessThan()`, `toString()`

### 3.2 Error Types

- [x] Create `packages/sdk/src/errors.ts`:
  - `FlovynError` base class with cause chaining
  - `WorkflowSuspended` (internal, for replay control flow)
  - `WorkflowCancelled`, `WorkflowFailed`, `DeterminismViolation`
  - `TaskFailed` (with `retryable` flag), `TaskCancelled`, `TaskTimeout`
  - `PromiseTimeout`, `PromiseRejected`
  - `ChildWorkflowFailed`

### 3.3 Type Definitions

- [x] Create `packages/sdk/src/types.ts`:
  - `WorkflowDefinition<I, O>` interface
  - `TaskDefinition<I, O>` interface
  - `WorkflowOptions`, `TaskOptions`, `ChildWorkflowOptions`, `PromiseOptions`
  - `RetryPolicy` interface
  - `WorkflowHandle<O>`, `TaskHandle<O>` interfaces
  - `WorkflowHook` interface (onStarted, onCompleted, onFailed)
  - `Logger` interface

### 3.4 Workflow Definition

- [x] Create `packages/sdk/src/workflow.ts`:
  - `workflow<I, O>(config)` factory function
  - Returns `WorkflowDefinition<I, O>` with `run`, `handlers`
  - `WorkflowConfig` interface with name, description, version, timeout, run function, handlers

### 3.5 Task Definition

- [x] Create `packages/sdk/src/task.ts`:
  - `task<I, O>(config)` factory function
  - Returns `TaskDefinition<I, O>`
  - `TaskConfig` interface with name, description, timeout, retry, run function, lifecycle hooks

### 3.6 Workflow Context

- [x] Create `packages/sdk/src/context/workflow-context.ts`:
  - `WorkflowContext` interface (as per design document)
  - `WorkflowContextImpl` class wrapping `NapiWorkflowContext`
  - Serialization layer (JSON encode/decode for inputs/outputs)
  - Methods: `task()`, `scheduleTask()`, `workflow()`, `scheduleWorkflow()`, `sleep()`, `sleepUntil()`, `promise()`, `run()`, `getState()`, `setState()`, `clearState()`, `currentTime()`, `currentTimeMillis()`, `randomUUID()`, `random()`, `checkCancellation()`, `requestCancellation()`
  - `isCancellationRequested` getter, `log` getter

### 3.7 Task Context

- [x] Create `packages/sdk/src/context/task-context.ts`:
  - `TaskContext` interface (as per design document)
  - `TaskContextImpl` class
  - Methods: `reportProgress()`, `heartbeat()`, `checkCancellation()`, `cancellationError()`
  - Streaming: `streamToken()`, `streamProgress()`, `streamData()`, `streamError()`
  - `isCancelled` getter, `taskExecutionId` getter, `taskKind` getter, `attempt` getter, `log` getter

### 3.8 Internal Worker

- [x] Create `packages/sdk/src/worker/workflow-worker.ts`:
  - Workflow polling loop
  - Activation handling (Start, Signal, Query, Cancel jobs)
  - Context creation and user function invocation
  - Completion submission
  - Error handling and status mapping
- [x] Create `packages/sdk/src/worker/task-worker.ts`:
  - Task polling loop
  - Context creation and user function invocation
  - Progress reporting and heartbeat
  - Lifecycle hook invocation (onStart, onSuccess, onFailure)
  - Completion submission

### 3.9 FlovynClient

- [x] Create `packages/sdk/src/client.ts`:
  - `FlovynClient` class with configuration
  - Constructor with `FlovynClientOptions` interface
  - Registration: `registerWorkflow()`, `registerTask()`
  - Lifecycle: `start()`, `stop()`
  - Workflow operations: `startWorkflow()` returning `WorkflowHandle`
  - Promise operations: `resolvePromise()`, `rejectPromise()`
  - Status: `isStarted()`, `getActiveWorkflowExecutions()`, `getActiveTaskExecutions()`
- [x] Create `packages/sdk/src/handles.ts`:
  - `WorkflowHandleImpl` implementing `WorkflowHandle`:
    - `result()`, `query()`, `signal()`, `cancel()`
    - `workflowId` getter

### 3.10 Serialization

- [x] Create `packages/sdk/src/serde.ts`:
  - `Serializer` interface with `serialize<T>(value: T): string` and `deserialize<T>(data: string): T`
  - `JsonSerializer` implementation with Date, BigInt, Uint8Array support
  - Default serializer exported as module functions

## Phase 4: Testing

### 4.1 Unit Test Infrastructure

- [x] Create `packages/sdk/src/testing/index.ts` - Public testing exports
- [x] Create `packages/sdk/src/testing/mock-workflow-context.ts`:
  - `MockWorkflowContext` implementing `WorkflowContext`
  - `mockTaskResult(taskDef, result)` for stubbing task outputs
  - `mockPromiseResolution(name, value)` for stubbing promises
  - `mockChildWorkflowResult()`, `mockOperationResult()`
  - Tracking: `executedTasks`, `startedTimers`, `createdPromises`, `startedChildWorkflows`, `executedOperations`
- [x] Create `packages/sdk/src/testing/mock-task-context.ts`:
  - `MockTaskContext` implementing `TaskContext`
  - Progress/heartbeat tracking
  - Stream event tracking

### 4.2 Unit Tests

- [x] Create `packages/sdk/tests/duration.test.ts` - Duration utility tests (20 tests)
- [x] Create `packages/sdk/tests/workflow.test.ts` - workflow() factory tests (5 tests)
- [x] Create `packages/sdk/tests/task.test.ts` - task() factory tests (6 tests)
- [x] Create `packages/sdk/tests/task-context.test.ts` - TaskContext behavior tests (19 tests)
- [x] Create `packages/sdk/tests/client.test.ts` - Client registration and configuration tests (29 tests)
- [x] Create `packages/sdk/tests/errors.test.ts` - Error type tests (12 tests)
- [x] Create `packages/sdk/tests/serde.test.ts` - Serialization tests (9 tests)

### 4.3 E2E Test Infrastructure

Reference: `sdk-python/tests/e2e/conftest.py`

- [x] Create `tests/e2e/setup.ts`:
  - Session-scoped test harness using testcontainers
  - Start Flovyn server containers once for all tests
  - Cleanup on test suite completion
- [x] Create `packages/sdk/src/testing/test-harness.ts`:
  - `TestHarness` class managing Docker containers (PostgreSQL, NATS, Flovyn server)
  - `getTestHarness()` global singleton function
  - `cleanupTestHarness()` for cleanup
- [x] Create `packages/sdk/src/testing/test-environment.ts`:
  - `FlovynTestEnvironment` class with methods:
    - `start()`, `stop()` - Lifecycle management
    - `startWorkflow(workflowDef, input)` - Returns `WorkflowHandle`
    - `awaitCompletion(handle, timeout?)` - Wait for result
    - `startAndAwait(workflowDef, input)` - Combined helper
    - `resolvePromise(promiseId, value)` - External promise resolution
    - `rejectPromise(promiseId, reason)` - External promise rejection
  - Worker status accessors: (pending - requires FlovynClient status API)
  - Worker control: (pending - requires FlovynClient pause/resume API)
  - Each test gets unique queue to prevent interference

### 4.4 E2E Test Fixtures

Reference: `sdk-python/tests/e2e/fixtures/`

- [x] Create `tests/e2e/fixtures/tasks.ts`:
  - [x] `echoTask` - Returns input message unchanged
  - [x] `addTask` - Adds two integers
  - [x] `slowTask` - Sleeps with progress reporting and cancellation support
  - [x] `failingTask` - Fails N times before succeeding (retry testing)
  - [x] `progressTask` - Reports progress in steps
  - [x] `streamingTokenTask` - Streams tokens via `ctx.streamToken()`
  - [x] `streamingProgressTask` - Streams progress via `ctx.streamProgress()`
  - [x] `streamingDataTask` - Streams data via `ctx.streamData()`
  - [x] `streamingErrorTask` - Streams errors via `ctx.streamError()`
  - [x] `streamingAllTypesTask` - Streams all event types

- [x] Create `tests/e2e/fixtures/workflows.ts`:
  - **Basic workflows:**
    - [x] `echoWorkflow` - Echo input with timestamp
    - [x] `doublerWorkflow` - Double an integer
    - [x] `failingWorkflow` - Always fails with message
    - [x] `statefulWorkflow` - Tests `ctx.getState()`/`ctx.setState()`
    - [x] `runOperationWorkflow` - Tests `ctx.run()` durable side effects
    - [x] `randomWorkflow` - Tests deterministic `ctx.randomUUID()`/`ctx.random()`
    - [x] `sleepWorkflow` - Tests `ctx.sleep()`
  - **Task-related:**
    - [x] `taskSchedulingWorkflow` - Sequential tasks with cumulative results
    - [x] `multiTaskWorkflow` - 10 sequential tasks with aggregation
    - [x] `parallelTasksWorkflow` - Parallel task execution
  - **Promise workflows:**
    - [x] `awaitPromiseWorkflow` - Creates and waits for external promise
  - **Child workflows:**
    - [x] `childWorkflowWorkflow` - Simple child execution
    - [x] `childFailureWorkflow` - Tests child failure handling
    - [x] `nestedChildWorkflow` - Multi-level nesting (3 levels)
    - [x] `childLoopWorkflow` - Child workflows in loop
  - **Replay/determinism:**
    - [x] `mixedCommandsWorkflow` - Operations, timers, tasks in sequence
  - **Parallel patterns:**
    - [x] `fanOutFanInWorkflow` - Fan-out/fan-in pattern
    - [x] `largeBatchWorkflow` - 20 parallel tasks
    - [x] `mixedParallelWorkflow` - Mixed parallel operations
  - **Integration:**
    - [x] `comprehensiveWorkflow` - Multi-feature test (input, run, state, multiple ops)
    - [x] `taskSchedulerWorkflow` - Generic task scheduler by name
    - [x] `typedTaskWorkflow` - Typed task execution

### 4.5 E2E Tests

Each test file maps to Python SDK equivalent for feature parity.

#### 4.5.1 Basic Workflow Tests
Reference: `sdk-python/tests/e2e/test_workflow.py`

- [x] Create `tests/e2e/workflow.test.ts`:
  - `test_echo_workflow` - Basic workflow execution returning echoed message
  - `test_doubler_workflow` - Workflow with arithmetic computation
  - `test_failing_workflow` - Workflow error handling with custom error messages
  - `test_stateful_workflow` - State get/set operations via `ctx.getState()`/`ctx.setState()`
  - `test_run_operation_workflow` - Durable side effects via `ctx.run()`
  - `test_random_workflow` - Deterministic UUID and random number generation
  - `test_sleep_workflow` - Durable timer functionality
  - `test_multiple_workflows_parallel` - Multiple workflows running concurrently

#### 4.5.2 Task Execution Tests
Reference: `sdk-python/tests/e2e/test_task.py`

- [x] Create `tests/e2e/task.test.ts`:
  - `test_workflow_scheduling_tasks` - Sequential task execution with cumulative results
  - `test_workflow_many_tasks` - Multiple sequential tasks with aggregation
  - `test_workflow_parallel_tasks` - Parallel task execution using `ctx.scheduleTask()` + `handle.result()`

#### 4.5.3 Timer Tests
Reference: `sdk-python/tests/e2e/test_timer.py`

- [x] Create `tests/e2e/timer.test.ts` (2 tests):
  - `test_short_timer` - 100ms sleep with wall-clock time verification (elapsed >= 100ms)
  - `test_durable_timer_sleep` - 1 second sleep with min/max time bounds

#### 4.5.4 Promise Tests
Reference: `sdk-python/tests/e2e/test_promise.py`

- [x] Create `tests/e2e/promise.test.ts` (3 tests):
  - `test_promise_resolve` - External promise resolution
  - `test_promise_reject` - External promise rejection
  - `test_promise_timeout` - Promise timeout handling

#### 4.5.5 Error Handling Tests
Reference: `sdk-python/tests/e2e/test_error.py`

- [x] Create `tests/e2e/error.test.ts` (1 test):
  - `test_error_message_preserved` - Custom error messages preserved through failure chain

#### 4.5.6 Streaming Tests
Reference: `sdk-python/tests/e2e/test_streaming.py`

- [x] Create `tests/e2e/streaming.test.ts` (6 tests):
  - `test_task_streams_tokens` - Token streaming (0-N tokens)
  - `test_task_streams_progress` - Progress updates (0.0-1.0)
  - `test_task_streams_data` - Arbitrary data serialization
  - `test_task_streams_errors` - Error notifications (non-fatal)
  - `test_task_streams_all_types` - Mixed stream types in single task
  - `test_task_streams_custom_tokens` - Special characters, Unicode, empty tokens

#### 4.5.7 Replay/Determinism Tests
Reference: `sdk-python/tests/e2e/test_replay.py`

- [x] Create `tests/e2e/replay.test.ts` (5 tests):
  - `test_mixed_commands_workflow` - Operations, timers, tasks in sequence replay correctly
  - `test_sequential_tasks_in_loop` - Tasks scheduled in loop replay correctly
  - `test_parallel_tasks_replay` - Parallel tasks matched to results correctly
  - `test_sleep_replay` - Timer events replay from history
  - `test_child_workflow_loop_replay` - Child workflows in loop replay correctly

#### 4.5.8 Worker Lifecycle Tests
Reference: `sdk-python/tests/e2e/test_lifecycle.py`

- [x] Create `tests/e2e/lifecycle.test.ts` (14 tests):
  - `test_worker_registration` - Worker registers with server
  - `test_worker_processes_multiple_workflows` - Handle multiple workflows sequentially
  - `test_worker_status_running` - Status API returns 'running'
  - `test_worker_continues_after_workflow` - Worker doesn't exit after work
  - `test_worker_handles_workflow_errors` - Worker resilient to failures
  - `test_worker_uptime` - Uptime metric increases over time
  - `test_worker_metrics` - Metrics API provides uptime, status fields
  - `test_client_connection_maintained` - Client maintains connection through operations
  - `test_rapid_workflow_submissions` - Handle rapid workflow submissions
  - `test_different_workflow_types` - Process different workflow types
  - `test_error_recovery` - Recover from errors and continue processing
  - `test_concurrent_executions` - Handle concurrent workflow executions
  - `test_long_term_stability` - Maintain stability over time
  - Note: Some Python tests (pause/resume, lifecycle events) require APIs not yet implemented

#### 4.5.9 Parallel Execution Tests
Reference: `sdk-python/tests/e2e/test_parallel.py`

- [x] Create `tests/e2e/parallel.test.ts` (6 tests):
  - `test_fan_out_fan_in` - 4 items: schedule parallel, collect results
  - `test_parallel_large_batch` - 20 parallel tasks with aggregation
  - `test_parallel_empty_batch` - Edge case: 0 items
  - `test_parallel_single_item` - Edge case: 1 item
  - `test_parallel_tasks_join_all` - Basic join_all pattern
  - `test_mixed_parallel_operations` - Tasks, timer, then tasks again

#### 4.5.10 Concurrency Tests
Reference: `sdk-python/tests/e2e/test_concurrency.py`

- [x] Create `tests/e2e/concurrency.test.ts` (4 tests):
  - `test_concurrent_workflow_execution` - 5 workflows running concurrently
  - `test_concurrent_task_execution` - 3 workflows with parallel tasks each
  - `test_high_throughput_small_workflows` - 20 simple workflows started quickly
  - `test_mixed_workflow_types_concurrent` - Echo, Doubler, Sleep workflows together

#### 4.5.11 Child Workflow Tests
Reference: `sdk-python/tests/e2e/test_child_workflow.py`

- [x] Create `tests/e2e/child-workflow.test.ts` (3 tests):
  - [x] `test_child_workflow_success` - Child workflow executes and returns result
  - [x] `test_child_workflow_failure` - Child failure caught by parent (ChildWorkflowFailed)
  - [x] `test_nested_child_workflows` - Multi-level nesting (3 levels deep)

#### 4.5.12 Typed API Tests
Reference: `sdk-python/tests/e2e/test_typed_api.py`

- [x] Create `tests/e2e/typed-api.test.ts` (4 tests):
  - `test_start_workflow_with_typed_input_output` - Workflow definition + typed input
  - `test_start_workflow_with_typed_input_output_doubler` - Typed API with Doubler
  - `test_start_and_await_with_typed_input_output` - Combined startAndAwait helper
  - `test_typed_task_execution_in_workflow` - Typed task execution in workflow

#### 4.5.13 Comprehensive Integration Tests
Reference: `sdk-python/tests/e2e/test_comprehensive.py`

- [x] Create `tests/e2e/comprehensive.test.ts` (3 tests):
  - `test_comprehensive_workflow_features` - Tests 5 features in single workflow
  - `test_comprehensive_with_different_input` - Same features with different input value
  - `test_all_basic_workflows` - Runs 5 different workflow types (echo, doubler, random, sleep, stateful)

## Phase 5: Examples

- [x] Create `examples/basic/`:
  - Task definitions (`greetTask`, `sendEmailTask`) with typed I/O
  - Workflow definitions (`greetingWorkflow`, `countdownWorkflow`, `parentWorkflow`)
  - Example entry point with FlovynClient usage
  - `package.json` with SDK dependency
  - `tsconfig.json` extending base config
- [x] Create `examples/order-processing/`:
  - Multi-step workflow as shown in design
  - External promise for approval
  - Compensation logic
- [x] Create `examples/data-pipeline/`:
  - Parallel task execution
  - Error handling patterns

## Phase 6: Documentation & Packaging

### 6.1 Documentation

- [x] Create `sdk-typescript/CLAUDE.md` with project guidance
- [x] Add JSDoc comments to all public APIs
- [x] Create `README.md` with:
  - Installation instructions
  - Quick start example (tasks, workflows, client)
  - Workflow Context API documentation
  - Task Context API documentation
  - Testing utilities documentation
  - Duration utilities
  - Error handling
- [x] Create `CONTRIBUTING.md` with development setup

### 6.2 Build & Publish Setup

- [x] Configure pnpm workspace with all packages
- [x] Configure TypeScript project references
- [x] Configure ESLint and Prettier
- [x] Configure Vitest for testing
- [x] Create `.gitignore`
- [x] Create GitHub Actions workflow for CI:
  - Lint, type-check, test on push
  - Downloads native binaries from sdk-rust releases
- [ ] Create GitHub Actions workflow for release:
  - Build native binaries (Linux x64/arm64, macOS x64/arm64, Windows x64)
  - Publish `@flovyn/native` platform packages to npm
  - Publish `@flovyn/sdk` to npm
- [ ] Set up npm publish configuration
- [x] Add `bin/dev/build.sh` for local development builds
- [x] Add `bin/dev/test.sh` for running tests
- [x] Add `bin/download-napi.sh` for downloading native modules from releases
- [x] Add `bin/dev/update-native.sh` for building/downloading native modules locally

## Critical Considerations

### What Could Be Missed

1. **Native binary loading edge cases**: Different Node.js installations (nvm, volta, system) may have different resolution paths. Test with multiple Node version managers.

2. **Async/Tokio integration**: NAPI-RS handles async via ThreadsafeFunction, but care needed for:
   - Long-running operations not blocking the Node.js event loop
   - Proper cleanup on process exit
   - Signal handling (SIGINT, SIGTERM)

3. **Memory management**: Buffer objects passed between Rust and JS need proper ownership semantics. NAPI-RS handles this, but verify no leaks in long-running workers.

4. **Error mapping**: Rust errors from worker-core need consistent mapping to TypeScript error types. Don't lose error context or stack traces.

5. **Serialization round-trips**: JSON serialization must handle:
   - BigInt (common in financial apps)
   - Date objects
   - Circular references (should error clearly)
   - Buffer/Uint8Array

6. **Graceful shutdown**: Worker shutdown must:
   - Stop accepting new activations
   - Complete in-progress workflows/tasks
   - Timeout after configurable period
   - Clean up gRPC connections

7. **Reconnection handling**: gRPC connection drops need automatic reconnection with backoff, matching Python SDK behavior.

8. **Type inference edge cases**: Generic type inference in TypeScript can fail with complex nested types. Test with real-world workflow patterns.

### Rollout Considerations

1. **Internal testing first**: Run SDK against Flovyn staging environment before public release.

2. **Alpha release**: Publish as `@flovyn/sdk@0.1.0-alpha.x` for early adopters.

3. **Documentation completeness**: API docs must be complete before beta.

4. **Migration guides**: If API changes from alpha to beta, provide migration guide.

5. **Version compatibility**: Document which Flovyn server versions are compatible with which SDK versions.

## Dependencies Between Phases

```
Phase 1 (worker-napi)
    │
    └──▶ Phase 2 (sdk-typescript setup)
              │
              └──▶ Phase 3 (SDK implementation)
                        │
                        ├──▶ Phase 4 (Testing)
                        │         │
                        │         └──▶ Phase 5 (Examples)
                        │                   │
                        └───────────────────┴──▶ Phase 6 (Docs & Packaging)
```

Phase 1 must complete before Phase 2 can start (native bindings needed).
Phase 3 must complete before Phase 4 E2E tests can run.
Phases 4-6 can partially overlap.
