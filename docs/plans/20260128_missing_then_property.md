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

### Phase 2: Verification

- [x] Run TypeScript build: `cd sdk-typescript && pnpm build`
- [x] Verify build succeeds without TS2741 or TS2420 errors
- [x] Run unit tests: `cd sdk-typescript && pnpm test`
- [x] Run type checking: `cd sdk-typescript && pnpm typecheck`

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

## Rollout

No special rollout considerations:
- This is a bug fix, not a new feature
- No API changes (the interface already required `then`, we're just implementing it)
- No backwards compatibility concerns
- Can be merged and released immediately once tests pass
