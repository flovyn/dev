# Consistent API Across SDK-Python and SDK-TypeScript

**Date:** 2026-01-25
**Feature:** inconsistent-api-in-sdk-python-and-sdk-typescript
**Status:** Ready for Implementation

**Issue:** [flovyn/flovyn-server#9](https://github.com/flovyn/flovyn-server/issues/9)

---

## Context

The Flovyn platform has SDKs in four languages: Kotlin, Python, TypeScript, and Rust. The Kotlin SDK (`sdk-kotlin`) serves as the reference implementation for API design. However, `sdk-python` and `sdk-typescript` have diverged from this reference, using different method names and patterns for the same operations.

---

## Problem Statement

The SDK APIs for `sdk-python` and `sdk-typescript` are inconsistent with the reference implementation in `sdk-kotlin`. This creates:

1. **Developer Confusion**: Users switching between languages expect similar APIs
2. **Documentation Overhead**: Inconsistent APIs require maintaining separate docs per language
3. **Mental Model Fragmentation**: Users can't build a transferable mental model across SDKs
4. **Ecosystem Incoherence**: SDKs feel like separate projects rather than one unified platform

### Current Inconsistencies Summary

| Operation | Kotlin (Reference) | Python | TypeScript |
|-----------|-------------------|--------|------------|
| Task execution (sync) | `schedule()` | `execute_task()` | `task()` |
| Task scheduling (async) | `scheduleAsync()` | `schedule_task()` | `scheduleTask()` |
| Child workflow (sync) | `scheduleWorkflow()` | `execute_workflow()` | `workflow()` |
| Child workflow (async) | `scheduleWorkflowAsync()` | `schedule_workflow()` | `scheduleWorkflow()` |
| Promise/external wait | `promise()` | `wait_for_promise()` | `promise()` |
| State get | `get()` | `get_state()` | `getState()` |
| State set | `set()` | `set_state()` | `setState()` |
| State clear | `clear()` | `clear_state()` | `clearState()` |
| State keys | `stateKeys()` | *missing* | *missing* |
| Clear all state | `clearAll()` | *missing* | *missing* |
| Streaming (task) | `stream(StreamEvent)` | `stream_token()`, etc. | `streamToken()`, etc. |

---

## Solution

Standardize `sdk-python` and `sdk-typescript` APIs to match `sdk-kotlin`, using language-appropriate naming conventions:

- **Kotlin**: `camelCase` (e.g., `scheduleTask`, `getState`)
- **Python**: `snake_case` (e.g., `schedule_task`, `get_state`) per PEP 8
- **TypeScript**: `camelCase` (e.g., `scheduleTask`, `getState`)

### Target API Mapping

#### WorkflowContext Methods

| Operation | Kotlin | Python | TypeScript |
|-----------|--------|--------|------------|
| Schedule task (sync await) | `schedule()` | `schedule()` | `schedule()` |
| Schedule task (returns handle) | `scheduleAsync()` | `schedule_async()` | `scheduleAsync()` |
| Schedule workflow (sync await) | `scheduleWorkflow()` | `schedule_workflow()` | `scheduleWorkflow()` |
| Schedule workflow (returns handle) | `scheduleWorkflowAsync()` | `schedule_workflow_async()` | `scheduleWorkflowAsync()` |
| Create promise | `promise()` | `promise()` | `promise()` |
| Get state | `get()` | `get()` | `get()` |
| Set state | `set()` | `set()` | `set()` |
| Clear state | `clear()` | `clear()` | `clear()` |
| Clear all state | `clearAll()` | `clear_all()` | `clearAll()` |
| Get state keys | `stateKeys()` | `state_keys()` | `stateKeys()` |
| Sleep | `sleep()` | `sleep()` | `sleep()` |
| Sleep until | `sleepUntil()` | `sleep_until()` | `sleepUntil()` |
| Run side effect | `run()` | `run()` | `run()` |

#### TaskContext Methods

| Operation | Kotlin | Python | TypeScript |
|-----------|--------|--------|------------|
| Report progress | `reportProgress()` | `report_progress()` | `reportProgress()` |
| Heartbeat | `heartbeat()` | `heartbeat()` | `heartbeat()` |
| Is cancelled | `isCancelled()` | `is_cancelled` | `isCancelled` |
| Stream event | `stream(event)` | `stream(event)` | `stream(event)` |

---

## Architecture

### Current vs Target: WorkflowContext

```
                     CURRENT STATE
    ┌────────────────────────────────────────────────────┐
    │                    Kotlin (Reference)               │
    │  schedule() | scheduleAsync() | scheduleWorkflow() │
    │  promise() | get() | set() | clear() | clearAll()  │
    └────────────────────────────────────────────────────┘
                            │
          ┌─────────────────┴─────────────────┐
          ▼                                   ▼
    ┌──────────────────┐              ┌──────────────────┐
    │     Python       │              │   TypeScript     │
    │  execute_task()  │              │     task()       │
    │  schedule_task() │              │  scheduleTask()  │
    │execute_workflow()│              │    workflow()    │
    │wait_for_promise()│              │    promise()     │
    │   get_state()    │              │   getState()     │
    └──────────────────┘              └──────────────────┘
              ▲ DIVERGENT                   ▲ DIVERGENT


                      TARGET STATE
    ┌────────────────────────────────────────────────────┐
    │                    Kotlin (Reference)               │
    │  schedule() | scheduleAsync() | scheduleWorkflow() │
    │  promise() | get() | set() | clear() | clearAll()  │
    └────────────────────────────────────────────────────┘
                            │
          ┌─────────────────┴─────────────────┐
          ▼                                   ▼
    ┌──────────────────┐              ┌──────────────────┐
    │     Python       │              │   TypeScript     │
    │    schedule()    │              │    schedule()    │
    │ schedule_async() │              │  scheduleAsync() │
    │schedule_workflow│              │scheduleWorkflow()│
    │    promise()     │              │    promise()     │
    │      get()       │              │      get()       │
    └──────────────────┘              └──────────────────┘
              ▲ ALIGNED                     ▲ ALIGNED
```

### Streaming Events Architecture

```
Kotlin StreamEvent (sealed class)
    ├── Token(text: String)
    ├── Progress(progress: Double, details: String?)
    ├── Data(data: String)
    └── Error(message: String, code: String?)

                    │
    ┌───────────────┴───────────────┐
    ▼                               ▼

Python StreamEvent (dataclass)      TypeScript StreamEvent (union)
    ├── TokenEvent                      type StreamEvent =
    ├── ProgressEvent                     | { type: 'token'; text: string }
    ├── DataEvent                         | { type: 'progress'; ... }
    └── ErrorEvent                        | { type: 'data'; ... }
                                          | { type: 'error'; ... }
```

---

## Implementation Notes

### SDK-Python Changes

**Renames in WorkflowContext:**
- `execute_task()` → `schedule()` (sync variant that awaits result)
- `schedule_task()` → `schedule_async()` (returns TaskHandle)
- `execute_workflow()` → `schedule_workflow()` (sync variant that awaits)
- `schedule_workflow()` → `schedule_workflow_async()` (returns WorkflowHandle)
- `wait_for_promise()` → `promise()`
- `get_state()` → `get()`
- `set_state()` → `set()`
- `clear_state()` → `clear()`

**New methods to add:**
- `clear_all()` - clear all workflow state
- `state_keys()` - get all state keys

**Streaming consolidation:**
- Replace `stream_token()`, `stream_data()`, `stream_progress()`, `stream_error()`
- Add single `stream(event: StreamEvent)` method
- Add `StreamEvent` dataclass with variants

**Files to modify:**
- `sdk-python/flovyn/context.py` (WorkflowContext, TaskContext)
- `sdk-python/flovyn/types.py` (add StreamEvent)

**Tests to update:**
- All unit tests using old method names
- All integration/E2E tests
- Mock context implementations used in tests

### SDK-TypeScript Changes

**Renames in WorkflowContext:**
- `task()` → `schedule()` (sync variant that awaits)
- `scheduleTask()` → `scheduleAsync()` (returns TaskHandle)
- `workflow()` → `scheduleWorkflow()` (sync variant that awaits)
- `scheduleWorkflow()` → `scheduleWorkflowAsync()` (returns WorkflowHandle)
- Keep `promise()` (already correct)
- `getState()` → `get()`
- `setState()` → `set()`
- `clearState()` → `clear()`

**New methods to add:**
- `clearAll()` - clear all workflow state
- `stateKeys()` - get all state keys

**Streaming consolidation:**
- Replace `streamToken()`, `streamData()`, `streamProgress()`, `streamError()`
- Add single `stream(event: StreamEvent)` method
- Add `StreamEvent` discriminated union type

**Files to modify:**
- `sdk-typescript/packages/sdk/src/context/workflow-context.ts`
- `sdk-typescript/packages/sdk/src/context/task-context.ts`
- `sdk-typescript/packages/sdk/src/types.ts`

**Tests to update:**
- All unit tests in `sdk-typescript/packages/sdk/tests/`
- All E2E tests in `sdk-typescript/tests/e2e/`
- Mock context implementations in `sdk-typescript/packages/sdk/src/testing/`

### SDK-Rust Consideration

The Rust SDK uses `_raw` suffix for FFI-level methods (e.g., `schedule_raw()`, `promise_raw()`). This is appropriate for Rust FFI bindings working with raw bytes. **No changes needed** for sdk-rust.

### Migration Strategy

**Immediate breaking change** (no deprecation period):

1. **Rename methods directly** - old method names will be removed
2. **Update all tests** - unit, integration, and E2E tests must be updated alongside API changes
3. **Update all documentation** - use new method names throughout
4. **Update all examples** - in both SDK repositories
5. **Document in CHANGELOG** - list all renamed methods for migration reference

Users will need to update their code when upgrading to the new SDK version.

### Test Verification

After implementation, all tests must pass:

**SDK-Python:**
```bash
cd sdk-python
pytest                    # Unit tests
pytest tests/e2e/         # E2E tests (if applicable)
```

**SDK-TypeScript:**
```bash
cd sdk-typescript
pnpm test                 # Unit tests
pnpm test:e2e             # E2E tests
```

---

## Decisions (Resolved)

### D1: Sync method naming
**Decision:** Use `schedule()` to match Kotlin naming for cross-language consistency.

### D2: Add `sleepUntil()` to Kotlin
**Decision:** Yes, add to Kotlin for parity with Python/TypeScript.

### D3: Streaming API pattern
**Decision:** Use single `stream(event)` method with typed events, matching Kotlin's sealed class pattern.

### D4: Python's `type_hint` parameter
**Decision:** Keep `type_hint` as a Python-specific optional parameter (language limitation, not API inconsistency).

### D5: Deprecation timeline
**Decision:** Immediate breaking change, no deprecation period. Old method names will be removed directly.

---

## Success Criteria

1. All four SDKs (Kotlin, Python, TypeScript, Rust) use consistent method naming patterns
2. Migration notes in CHANGELOG for Python and TypeScript users
3. All documentation updated to reflect new API
4. Examples in all repositories updated
5. `sleepUntil()` added to Kotlin SDK for parity
6. **All tests pass** - unit tests, integration tests, and E2E tests in both sdk-python and sdk-typescript

---

## References

### Source Files Analyzed

**SDK-Kotlin (Reference):**
- `sdk-kotlin/worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContext.kt`
- `sdk-kotlin/worker-sdk/src/main/kotlin/ai/flovyn/sdk/task/TaskContext.kt`

**SDK-Python:**
- `sdk-python/flovyn/context.py`
- `sdk-python/flovyn/types.py`

**SDK-TypeScript:**
- `sdk-typescript/packages/sdk/src/context/workflow-context.ts`
- `sdk-typescript/packages/sdk/src/context/task-context.ts`
- `sdk-typescript/packages/sdk/src/types.ts`

**SDK-Rust:**
- `sdk-rust/worker-sdk/src/workflow/context.rs`
