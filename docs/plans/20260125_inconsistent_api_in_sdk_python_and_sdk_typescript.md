# Implementation Plan: Consistent API Across SDK-Python and SDK-TypeScript

**Date:** 2026-01-25
**Feature:** inconsistent-api-in-sdk-python-and-sdk-typescript
**Design Doc:** `dev/docs/design/20260125_inconsistent_api_in_sdk_python_and_sdk_typescript.md`

---

## Phase 0: FFI Layer Updates (sdk-rust)

The `clear_all()` method is not currently exposed in the FFI layer. We need to add it to enable the Python/TypeScript SDKs to call it.

### 0.1 Add `clear_all()` to FFI (worker-ffi/src/context.rs)

- [x] Add `clear_all()` method to `FfiWorkflowContext` that:
  - Gets all keys via `state_keys()`
  - Calls `clear_state()` for each key (generates `ClearState` commands)
  - Clears local `ffi_state`

### 0.2 Add `clear_all()` to NAPI (worker-napi/src/context.rs)

- [x] Add `clear_all()` method with `#[napi]` attribute following the same pattern

### 0.3 Regenerate FFI Bindings

- [x] Run `./bin/dev/update-native.sh` in sdk-kotlin to regenerate Python bindings
- [x] Verify `clear_all()` appears in `sdk-python/flovyn/_native/flovyn_worker_ffi.py`
- [x] Rebuild NAPI package for TypeScript bindings

---

## Phase 1: SDK-Python API Changes

### 1.1 WorkflowContext Method Renames (context.py)

- [x] Rename `execute_task()` → `schedule()` (sync variant that awaits result)
- [x] Rename `schedule_task()` → `schedule_async()` (returns TaskHandle)
- [x] Rename `execute_workflow()` → `schedule_workflow()` (sync variant)
- [x] Rename `schedule_workflow()` → `schedule_workflow_async()` (returns WorkflowHandle)
- [x] Rename `wait_for_promise()` → `promise()`
- [x] Rename `get_state()` → `get()`
- [x] Rename `set_state()` → `set()`
- [x] Rename `clear_state()` → `clear()`

### 1.2 New Methods in WorkflowContext (context.py)

- [x] Add `state_keys()` method - calls `self._ffi.state_keys()`
- [x] Add `clear_all()` method - calls `self._ffi.clear_all()` (added in Phase 0)

### 1.3 TaskContext Streaming Consolidation (context.py)

- [x] Add `StreamEvent` dataclass with variants in `types.py`:
  - `TokenEvent(text: str)`
  - `ProgressEvent(progress: float, details: str | None)`
  - `DataEvent(data: Any)`
  - `ErrorEvent(message: str, code: str | None)`
- [x] Add unified `stream(event: StreamEvent)` method to TaskContext
- [x] Keep individual streaming methods as convenience wrappers (for compatibility)

### 1.4 Update SDK-Python Exports

- [x] Update `flovyn/__init__.py` to export new types (StreamEvent variants)
- [x] Verify all public API exports are correct

---

## Phase 2: SDK-TypeScript API Changes

### 2.1 WorkflowContext Method Renames (workflow-context.ts, types.ts)

- [x] Rename `task()` → `schedule()` (sync variant)
- [x] Rename `taskByName()` → `scheduleByName()` (untyped sync variant)
- [x] Rename `scheduleTask()` → `scheduleAsync()` (returns TaskHandle)
- [x] Rename `workflow()` → `scheduleWorkflow()` (sync variant)
- [x] Rename `scheduleWorkflow()` → `scheduleWorkflowAsync()` (returns WorkflowHandle)
- [x] Rename `getState()` → `get()`
- [x] Rename `setState()` → `set()`
- [x] Rename `clearState()` → `clear()`
- [x] Keep `promise()` unchanged (already matches Kotlin)

### 2.2 New Methods in WorkflowContext

- [x] Add `stateKeys()` method - calls `this.nativeCtx.stateKeys()`
- [x] Add `clearAll()` method - calls `this.nativeCtx.clearAll()` (added in Phase 0)

### 2.3 TaskContext Streaming Consolidation (task-context.ts)

- [x] Add `StreamEvent` discriminated union type in `types.ts`:
  ```typescript
  type StreamEvent =
    | { type: 'token'; text: string }
    | { type: 'progress'; progress: number; details?: string }
    | { type: 'data'; data: unknown }
    | { type: 'error'; message: string; code?: string }
  ```
- [x] Add unified `stream(event: StreamEvent)` method to TaskContext
- [x] Keep individual streaming methods as convenience wrappers (for compatibility)

### 2.4 Update SDK-TypeScript Exports

- [x] Update `packages/sdk/src/index.ts` to export StreamEvent type
- [x] Update `packages/sdk/src/types.ts` with interface changes

---

## Phase 3: SDK-Kotlin API Changes

### 3.1 Add `sleepUntil()` to WorkflowContext

- [x] Add `sleepUntil(timestamp: Instant)` method to `WorkflowContext` interface
  - Location: `sdk-kotlin/worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContext.kt`
- [x] Implement `sleepUntil()` in `WorkflowContextImpl`
  - Location: `sdk-kotlin/worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContextImpl.kt`
  - Implementation: Calculate duration from `currentTimeMillis()` to target timestamp, call `sleep(duration)`

### 3.2 Update Kotlin Tests

- [ ] Add unit tests for `sleepUntil()` method (Deferrable - no Java environment available)
- [ ] Add E2E test for `sleepUntil()` if applicable (Deferrable - no Java environment available)

### 3.3 Update Kotlin Documentation

- [ ] Update `sdk-kotlin/CHANGELOG.md` with new method
- [ ] Update any examples that could benefit from `sleepUntil()`

---

## Phase 4: SDK-Python Test Updates

### 4.1 Update Unit Tests

- [x] Update `tests/unit/test_mocks.py` - mock context method names
- [x] Update `tests/unit/test_decorators.py` if needed
- [x] Update `tests/conftest.py` - fixtures and helpers

### 4.2 Update E2E Test Fixtures

- [x] Update `tests/e2e/fixtures/workflows.py`:
  - `execute_task()` → `schedule()`
  - `schedule_task()` → `schedule_async()`
  - `execute_workflow()` → `schedule_workflow()`
  - `schedule_workflow()` → `schedule_workflow_async()`
  - `wait_for_promise()` → `promise()`
  - `get_state()` → `get()`
  - `set_state()` → `set()`
- [x] Update `tests/e2e/fixtures/tasks.py` - streaming method changes

### 4.3 Update E2E Tests

- [x] Update `tests/e2e/test_workflow.py`
- [x] Update `tests/e2e/test_task.py`
- [x] Update `tests/e2e/test_promise.py`
- [x] Update `tests/e2e/test_streaming.py`
- [x] Update `tests/e2e/test_timer.py`
- [x] Update `tests/e2e/test_error.py`
- [x] Update `tests/e2e/test_replay.py`
- [x] Update `tests/e2e/test_concurrency.py`
- [x] Update `tests/e2e/test_child_workflow.py`
- [x] Update `tests/e2e/test_comprehensive.py`
- [x] Update `tests/e2e/test_lifecycle.py`
- [x] Update `tests/e2e/test_parallel.py`
- [x] Update `tests/e2e/test_typed_api.py`

---

## Phase 5: SDK-TypeScript Test Updates

### 5.1 Update Mock Contexts

- [x] Update `packages/sdk/src/testing/mock-workflow-context.ts`:
  - Rename methods to match new API
  - Add `clearAll()`, `stateKeys()` implementations
- [x] Update `packages/sdk/src/testing/mock-task-context.ts`:
  - Replace individual stream methods with `stream()`

### 5.2 Update E2E Test Fixtures

- [x] Update `tests/e2e/fixtures/workflows.ts`:
  - `ctx.task()` → `ctx.schedule()`
  - `ctx.scheduleTask()` → `ctx.scheduleAsync()`
  - `ctx.workflow()` → `ctx.scheduleWorkflow()`
  - `ctx.scheduleWorkflow()` → `ctx.scheduleWorkflowAsync()`
  - `ctx.getState()` → `ctx.get()`
  - `ctx.setState()` → `ctx.set()`
  - `ctx.clearState()` → `ctx.clear()`
- [x] Update `tests/e2e/fixtures/tasks.ts` - streaming changes

### 5.3 Update E2E Tests

- [x] Update `tests/e2e/workflow.test.ts`
- [x] Update `tests/e2e/task.test.ts`
- [x] Update `tests/e2e/promise.test.ts`
- [x] Update `tests/e2e/streaming.test.ts`
- [x] Update `tests/e2e/timer.test.ts`
- [x] Update `tests/e2e/error.test.ts`
- [x] Update `tests/e2e/replay.test.ts`
- [x] Update `tests/e2e/concurrency.test.ts`
- [x] Update `tests/e2e/child-workflow.test.ts`
- [x] Update `tests/e2e/comprehensive.test.ts`
- [x] Update `tests/e2e/lifecycle.test.ts`
- [x] Update `tests/e2e/parallel.test.ts`
- [x] Update `tests/e2e/typed-api.test.ts`

### 5.4 Update Unit Tests

- [x] Update `packages/sdk/tests/` unit tests if any use old method names

---

## Phase 6: Documentation Updates

### 6.1 SDK-Python Documentation

- [x] Create/update `sdk-python/CHANGELOG.md` with migration guide:
  ```markdown
  ## [Unreleased] - Breaking Changes

  ### WorkflowContext API Changes
  - `execute_task()` → `schedule()`
  - `schedule_task()` → `schedule_async()`
  - `execute_workflow()` → `schedule_workflow()`
  - `schedule_workflow()` → `schedule_workflow_async()`
  - `wait_for_promise()` → `promise()`
  - `get_state()` → `get()`
  - `set_state()` → `set()`
  - `clear_state()` → `clear()`

  ### New Methods
  - `clear_all()` - clear all workflow state
  - `state_keys()` - get all state keys

  ### TaskContext API Changes
  - Individual streaming methods replaced with unified `stream(event)` method
  - Added `StreamEvent` types: `TokenEvent`, `ProgressEvent`, `DataEvent`, `ErrorEvent`
  ```

### 6.2 SDK-TypeScript Documentation

- [x] Create/update `sdk-typescript/CHANGELOG.md` with migration guide:
  ```markdown
  ## [Unreleased] - Breaking Changes

  ### WorkflowContext API Changes
  - `task()` → `schedule()`
  - `taskByName()` → `scheduleByName()`
  - `scheduleTask()` → `scheduleAsync()`
  - `workflow()` → `scheduleWorkflow()`
  - `scheduleWorkflow()` → `scheduleWorkflowAsync()`
  - `getState()` → `get()`
  - `setState()` → `set()`
  - `clearState()` → `clear()`

  ### New Methods
  - `clearAll()` - clear all workflow state
  - `stateKeys()` - get all state keys

  ### TaskContext API Changes
  - Individual streaming methods replaced with unified `stream(event)` method
  - Added `StreamEvent` discriminated union type
  ```

### 6.3 Update CLAUDE.md Files

- [x] Update `sdk-python/CLAUDE.md` if API examples exist
- [x] Update `sdk-typescript/CLAUDE.md` if API examples exist

---

## Phase 7: Verification

### 7.1 SDK-Python Verification

- [x] Run unit tests: `cd sdk-python && uv run pytest tests/unit/` (32 passed)
- [x] Run E2E tests: `cd sdk-python && uv run pytest tests/e2e -m e2e` (63 passed)
- [x] Run type checking: `cd sdk-python && uv run mypy flovyn/` (Success, no issues)
- [x] Run linting: `cd sdk-python && uv run ruff check flovyn/` (All checks passed)

### 7.2 SDK-TypeScript Verification

- [x] Run unit tests: `cd sdk-typescript && pnpm test` (71 tests passed)
- [x] Run E2E tests: `cd sdk-typescript && pnpm test:e2e` (62 passed)
- [x] Run type checking: `cd sdk-typescript && pnpm typecheck` (Success)
- [x] Run linting: `cd sdk-typescript && pnpm lint` (Passed)

### 7.3 SDK-Kotlin Verification

- [ ] Run unit tests (Deferrable - no Java environment)
- [ ] Run E2E tests (Deferrable - no Java environment)
- [ ] Verify `sleepUntil()` works correctly (Deferrable - no Java environment)

### 7.4 Final API Audit

- [x] Verify Python API matches Kotlin (snake_case equivalents)
- [x] Verify TypeScript API matches Kotlin (camelCase equivalents)
- [x] Verify StreamEvent types are consistent across SDKs

---

## Test Plan

### Pre-Implementation

1. Ensure all existing tests pass before making changes
2. Note any flaky tests to distinguish from regressions

### During Implementation

1. Update implementation and tests together per phase
2. Run affected test suite after each phase
3. Do not proceed to next phase until current phase tests pass

### Post-Implementation

1. Run full test suite for both SDKs
2. Manual verification of API changes by reviewing public interface
3. Review CHANGELOG entries for completeness

---

## Implementation Order

Execute phases in order (0 → 1 → 2 → 3 → 4 → 5 → 6 → 7). Within each phase, complete all items before moving to the next phase.

**Rationale:**
- Phase 0 adds FFI layer support needed by Phase 1 & 2
- Phase 1-3 make API changes (Python, TypeScript, Kotlin)
- Phase 4 & 5 fix tests (must follow API changes)
- Phase 6 documents changes (must reflect final API)
- Phase 7 verifies everything works

---

## Risk Considerations

### High Risk Items

1. **Streaming API consolidation** - Most complex change, affects FFI layer integration
   - Mitigation: Verify FFI methods support the unified approach
   - The design shows the existing FFI context already has individual methods, so `stream(event)` will dispatch to these internally

### Medium Risk Items

1. **Test coverage gaps** - Some tests might not exercise renamed methods
   - Mitigation: Search for all usages of old method names after changes

2. **External examples or documentation** - Any examples outside the SDK repos
   - Mitigation: These would be updated separately; this plan covers SDK repos only
