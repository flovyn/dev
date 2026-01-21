# Bug Report: Integer Overflow in Retry Workflow Exponential Backoff

**Date:** 2026-01-09
**Severity:** Medium
**Status:** Fixed
**Component:** SDK Examples / Retry Pattern

## Summary

The retry workflow example has an integer overflow bug in the exponential backoff calculation. When the attempt count exceeds 63 (or 31 for i32), the bit shift operation `1 << (attempt - 1)` overflows, causing a panic in debug mode or undefined behavior in release mode.

## Reproduction Steps

1. Start a retry workflow with high `max_attempts` (e.g., 100)
2. Set `failure_probability` to 1.0 (always fail) or near 1.0
3. Let the workflow run until attempt 59+
4. Worker panics with integer overflow

## Evidence

Worker panic output:
```
thread 'tokio-runtime-worker' panicked at 'attempt to shift left with overflow'
```

The problematic code at `sdk-rust/examples/patterns/src/retry_workflow.rs:156`:
```rust
let base_delay_ms: u64 = 100;  // line 94
let max_delay_ms: u64 = 10000; // line 95

// line 156:
let delay_ms = (base_delay_ms * (1 << (attempt - 1))).min(max_delay_ms);
```

## Root Cause Analysis

The expression `1 << (attempt - 1)` has the following issues:

1. **Default integer literal type**: The literal `1` defaults to `i32` in Rust
2. **Shift overflow**: `i32` can only hold 32 bits, so `1i32 << 31` is the maximum valid shift
3. **At attempt 59**: `1 << 58` overflows because 58 > 31 (for i32) or would need > 64 bits

Even with `u64`, the maximum safe shift is 63 bits. At attempt 65, `1u64 << 64` would overflow.

## Proposed Fix

Use saturating arithmetic and explicit types:

```rust
// Option 1: Use checked_shl with saturation
let shift_amount = (attempt - 1).min(63) as u32;
let multiplier = 1u64.checked_shl(shift_amount).unwrap_or(u64::MAX);
let delay_ms = base_delay_ms.saturating_mul(multiplier).min(max_delay_ms);

// Option 2: Simpler - just cap at max_delay early
let delay_ms = if attempt > 63 {
    max_delay_ms
} else {
    (base_delay_ms * (1u64 << (attempt - 1))).min(max_delay_ms)
};
```

Since `max_delay_ms` caps the result anyway, any attempt where `2^(attempt-1) * base_delay > max_delay` will just use `max_delay_ms`. For `base_delay_ms = 100` and `max_delay_ms = 10000`, this happens at attempt 8 (100 * 128 = 12800 > 10000).

So the simplest fix is:

```rust
// Cap shift to avoid overflow - result is capped to max_delay anyway
let effective_shift = (attempt - 1).min(63);
let delay_ms = (base_delay_ms * (1u64 << effective_shift)).min(max_delay_ms);
```

## Impact

- **Debug builds**: Worker panics and crashes
- **Release builds**: Undefined behavior (likely wraps to small value, causing rapid retries)
- **Affected workflows**: Any retry workflow that reaches attempt 59+

## Related Issues

This bug was discovered while investigating a stuck workflow issue (see `20260109_stuck_workflows_not_reclaimed.md`). When a workflow was manually reset to PENDING after being stuck, the worker picked it up at attempt 59 and immediately panicked.

## Related Files

- `flovyn-server//sdk-rust/examples/patterns/src/retry_workflow.rs` - Lines 94-95, 156
- Similar pattern may exist in `/flovyn-server/plugins/eventhook/src/service/processor.rs:354` (uses `2u64.pow()` which is safer but still needs bounds checking)

## Workaround

Do not set `max_attempts` higher than 63 until this is fixed.
