# Missing `then` Property in WorkflowHandleImpl

**Date:** 2026-01-28
**Feature:** missing-then-property
**Status:** Implemented

**Issue:** [flovyn/sdk-typescript#2](https://github.com/flovyn/sdk-typescript/issues/2)

## Context

The TypeScript SDK build is failing in CI with TypeScript errors related to the `WorkflowHandleImpl` class not implementing the `then` method required by the `PromiseLike<O>` interface.

Error output:
```
Error: packages/sdk build: src/client.ts(358,5): error TS2322: Type 'WorkflowHandleImpl<O>' is not assignable to type 'O'.
Error: packages/sdk build: src/client.ts(381,5): error TS2741: Property 'then' is missing in type 'WorkflowHandleImpl<O>' but required in type 'WorkflowHandle<O>'.
Error: packages/sdk build: src/handles.ts(37,14): error TS2420: Class 'WorkflowHandleImpl<O>' incorrectly implements interface 'WorkflowHandle<O>'.
```

## Problem Statement

The `WorkflowHandle<O>` interface (defined in `sdk-typescript/packages/sdk/src/types.ts:299`) extends `PromiseLike<O>`:

```typescript
export interface WorkflowHandle<O> extends PromiseLike<O> {
  result(): Promise<O>;
  query<T = any>(queryName: string, args?: any): Promise<T>;
  signal(signalName: string, payload?: any): Promise<void>;
  cancel(reason?: string): Promise<void>;
  readonly workflowId: string;
}
```

The `PromiseLike<T>` interface from TypeScript's standard library requires a `then` method:

```typescript
interface PromiseLike<T> {
    then<TResult1 = T, TResult2 = never>(
        onfulfilled?: ((value: T) => TResult1 | PromiseLike<TResult1>) | undefined | null,
        onrejected?: ((reason: any) => TResult2 | PromiseLike<TResult2>) | undefined | null
    ): PromiseLike<TResult1 | TResult2>;
}
```

However, `WorkflowHandleImpl` in `sdk-typescript/packages/sdk/src/handles.ts:37` declares it implements `WorkflowHandle<O>` but does not implement the `then` method.

This design decision to make handles "thenable" (Promise-like) enables ergonomic usage:

```typescript
// Can await directly
const result = await client.startWorkflow(myWorkflow, input);

// Or use with Promise.all
const [r1, r2] = await Promise.all([
  client.startWorkflow(workflow1, input1),
  client.startWorkflow(workflow2, input2),
]);
```

## Solution

Two changes were required:

### 1. Add `then` method to `WorkflowHandleImpl`

Add a `then` method that delegates to `this.result().then(...)`. This pattern is already used consistently elsewhere in the SDK:
- `TaskHandleImpl` in `workflow-context.ts:78-83`
- `ChildWorkflowHandleImpl` in `workflow-context.ts:129-133`

```typescript
then<TResult1 = O, TResult2 = never>(
  onfulfilled?: ((value: O) => TResult1 | PromiseLike<TResult1>) | null,
  onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null
): Promise<TResult1 | TResult2> {
  return this.result().then(onfulfilled, onrejected);
}
```

### 2. Change `startWorkflow` return type to avoid TypeScript unwrapping issues

Because `WorkflowHandle<O>` implements `PromiseLike<O>`, TypeScript's `Awaited<T>` type recursively unwraps it. This means `await Promise<WorkflowHandle<O>>` would have type `O` instead of `WorkflowHandle<O>`.

To provide a clean developer experience, `startWorkflow` now returns `Promise<{ handle: WorkflowHandle<O> }>`. The wrapper object is not thenable, so `await` stops there:

```typescript
// Clean API - no type assertions needed
const { handle } = await client.startWorkflow(workflow, input);
console.log(handle.workflowId);
const result = await handle.result();
```

Additionally, an `executeWorkflow` convenience method was added for when you just want the result:

```typescript
const result = await client.executeWorkflow(workflow, input);
```

## Architecture

The change is localized to a single file with no impact on the overall architecture:

```
sdk-typescript/packages/sdk/src/
├── types.ts              # WorkflowHandle<O> interface (unchanged)
├── handles.ts            # WorkflowHandleImpl class (ADD then method)
└── context/
    └── workflow-context.ts  # TaskHandleImpl, ChildWorkflowHandleImpl (reference)
```

The `WorkflowHandleImpl` is used in two places in `client.ts`:
1. `startWorkflow()` at line 358 - returns `WorkflowHandleImpl` as `WorkflowHandle`
2. `getWorkflowHandle()` at line 381 - returns `WorkflowHandleImpl` as `WorkflowHandle`

## Implementation Notes

- **Single file change**: Only `handles.ts` needs modification
- **Pattern consistency**: The `then` method implementation follows the exact pattern already used for `TaskHandleImpl` and `ChildWorkflowHandleImpl` within the codebase
- **Type signature**: Use `Promise<TResult1 | TResult2>` as return type (matches existing implementations)
- **Error handling**: The `then` method naturally propagates errors through `this.result()` which already throws appropriate errors for workflow failures, cancellations, and timeouts

## Open Questions

None - the solution is straightforward and follows established patterns in the codebase.

## References

- TypeScript SDK design doc: `dev/docs/design/20260124_create_sdk_for_typescript.md`
- Python SDK design doc: `dev/docs/design/20260119_design_sdk_python.md`
- TypeScript `PromiseLike` interface: [TypeScript lib.es5.d.ts](https://github.com/microsoft/TypeScript/blob/main/lib/lib.es5.d.ts)
