# Missing Then Property

**Date:** 2026-01-28
**Feature:** missing-then-property
**Status:** Draft

**Issue:** [flovyn/sdk-typescript#2](https://github.com/flovyn/sdk-typescript/issues/2)

## Context

Failed build

> Run pnpm build
> 
> > flovyn-sdk-typescript@0.1.0 build /home/runner/work/sdk-typescript/sdk-typescript
> > pnpm -r build
> 
> Scope: 5 of 6 workspace projects
> packages/native build$ tsc
> packages/native build: Done
> packages/sdk build$ tsc
> Error: packages/sdk build: src/client.ts(358,5): error TS2322: Type 'WorkflowHandleImpl<O>' is not assignable to type 'O'.
> packages/sdk build:   'O' could be instantiated with an arbitrary type which could be unrelated to 'WorkflowHandleImpl<O>'.
> Error: packages/sdk build: src/client.ts(381,5): error TS2741: Property 'then' is missing in type 'WorkflowHandleImpl<O>' but required in type 'WorkflowHandle<O>'.
> Error: packages/sdk build: src/handles.ts(37,14): error TS2420: Class 'WorkflowHandleImpl<O>' incorrectly implements interface 'WorkflowHandle<O>'.
> packages/sdk build:   Property 'then' is missing in type 'WorkflowHandleImpl<O>' but required in type 'WorkflowHandle<O>'.
> Error: packages/sdk build: src/testing/test-environment.ts(312,33): error TS2345: Argument of type 'Awaited<O>' is not assignable to parameter of type 'WorkflowHandle<O>'.
> packages/sdk build:   Type 'O | (O extends object & { then(onfulfilled: infer F, ...args: infer _): any; } ? F extends (value: infer V, ...args: infer _) => any ? Awaited<V> : never : O)' is not assignable to type 'WorkflowHandle<O>'.
> packages/sdk build:     Type '(null | undefined) & O' is not assignable to type 'WorkflowHandle<O>'.
> packages/sdk build:       Type 'undefined & O' is not assignable to type 'WorkflowHandle<O>'.
> packages/sdk build: Failed
> /home/runner/work/sdk-typescript/sdk-typescript/packages/sdk:
>  ERR_PNPM_RECURSIVE_RUN_FIRST_FAIL  @flovyn/sdk@0.1.0 build: `tsc`
> Exit status 2
>  ELIFECYCLE  Command failed with exit code 2.
> Error: Process completed with exit code 2. 

## Problem Statement

<!-- What problem does this solve? Why is it needed? -->

## Solution

<!-- High-level approach. What are we building? -->

## Architecture

<!-- Diagrams, component interactions, data flow -->

```
<!-- ASCII diagram here -->
```

## Implementation Notes

<!-- Key technical decisions, constraints, dependencies -->

## Open Questions

<!-- Unresolved decisions that need input -->

- [ ] Question 1?
- [ ] Question 2?

## References

<!-- Related docs, external resources -->
