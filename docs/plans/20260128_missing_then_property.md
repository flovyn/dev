# Implementation Plan: Missing `then` Property in WorkflowHandleImpl

**Date:** 2026-01-28
**Feature:** missing-then-property
**Design:** `dev/docs/design/20260128_missing_then_property.md`

## Overview

Add the missing `then` method to `WorkflowHandleImpl` to satisfy the `PromiseLike<O>` interface requirement.

## TODO

### Phase 1: Implementation

- [x] Add `then` method to `WorkflowHandleImpl` in `sdk-typescript/packages/sdk/src/handles.ts`
  - Add after line 150 (before the closing brace of the class)
  - Follow exact signature and pattern from `TaskHandleImpl` (workflow-context.ts:78-83)
  - Include JSDoc comment for consistency

- [x] Change `startWorkflow` return type to `Promise<{ handle: WorkflowHandle<O> }>`
  - Wrapping in `{ handle }` avoids TypeScript's `Awaited<T>` unwrapping the PromiseLike
  - This provides better developer experience (no type assertions needed)

- [x] Add `executeWorkflow` convenience method for "start and wait" pattern

- [x] Update all examples to use new `{ handle }` destructuring pattern

- [x] Update all E2E tests to use new `{ handle }` destructuring pattern

### Phase 2: Verification

- [x] Run TypeScript build: `cd sdk-typescript && pnpm build`
- [x] Verify build succeeds without TS2741 or TS2420 errors
- [x] Run unit tests: `cd sdk-typescript && pnpm test` - 100/100 passed
- [x] Run type checking: `cd sdk-typescript && pnpm typecheck`
- [x] Run E2E tests: `cd sdk-typescript && pnpm test:e2e` - 61/62 passed (1 pre-existing flaky test)

## Test Plan

**Build verification:**
- The primary test is that `pnpm build` completes without the errors listed in the design doc
- Specifically, no errors at `client.ts:358`, `client.ts:381`, or `handles.ts:37`

**Functional verification:**
- Existing unit tests should continue to pass
- No new tests are needed since:
  1. The `then` method simply delegates to `result()` which is already tested
  2. The pattern is identical to `TaskHandleImpl` and `ChildWorkflowHandleImpl` which are already exercised

**Manual smoke test (optional):**
- Create a simple workflow and verify `await client.startWorkflow(...)` resolves correctly

## API Changes

The implementation required an API change to provide good developer experience:

**Before:**
```typescript
// Would require type assertion due to TypeScript's Awaited<T> behavior
const handle = await client.startWorkflow(workflow, input) as unknown as WorkflowHandle<O>;
```

**After:**
```typescript
// Clean destructuring, no type assertions needed
const { handle } = await client.startWorkflow(workflow, input);
console.log(handle.workflowId);
const result = await handle.result();

// Or use convenience method for simple cases:
const result = await client.executeWorkflow(workflow, input);
```

## Rollout

- This is a bug fix with an API improvement
- The `startWorkflow` return type change is a breaking change for existing code
- Existing code using `const handle = await client.startWorkflow(...)` needs to change to `const { handle } = await client.startWorkflow(...)`
- Can be merged once all tests pass
