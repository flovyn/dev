# Multi-Turn Signal Replay Bug

**Date**: 2026-02-08
**Status**: Fixed
**Component**: SDK Replay Engine (`worker-core/src/workflow/replay_engine.rs`)
**Severity**: Critical — multi-turn conversations are completely broken
**Fix**: Implemented deferred signal queues in `ReplayEngine::new()`. Signals after the last `WORKFLOW_SUSPENDED` event go into `deferred_signal_queues` (invisible to `has_signal()`, only accessible via `pop_signal()`). Option A from proposed fixes below.

## Symptom

When a workflow uses `has_signal()` for steering checks in a loop AND `wait_for_signal_raw()` for durable suspension, the second turn never executes. The workflow enters an infinite suspend loop:

```
Event 1-11: First turn completes normally
Event 12:   SIGNAL_RECEIVED (follow-up message)
Event 13:   WORKFLOW_SUSPENDED (SIGNAL) ← immediately suspends again
```

No STATE_SET or TASK_SCHEDULED events between events 12 and 13.

## Root Cause

The `ReplayEngine::new()` loads ALL `SIGNAL_RECEIVED` events into a per-name FIFO queue at initialization (lines 120-134):

```rust
let mut signal_queues: HashMap<String, VecDeque<ReplayEvent>> = HashMap::new();
for event in events.iter().filter(|e| e.event_type() == EventType::SignalReceived) {
    signal_queues.entry(signal_name).or_default().push_back(event.clone());
}
```

This does NOT respect the causal ordering of events. A signal that arrived AFTER the workflow suspended (post-suspension signal) is indistinguishable from a signal that was available before the workflow ran (pre-existing/steering signal).

### Detailed Replay Trace

**Original execution** (first run):
1. `has_signal("userMessage")` → **false** (no signal exists yet)
2. `schedule_raw("llm-request")` → LLM responds with text
3. `wait_for_signal_raw("userMessage")` → **suspends** (WORKFLOW_SUSPENDED)
4. External signal arrives → SIGNAL_RECEIVED event added

**Replay after signal** (second run):
1. `has_signal("userMessage")` → **TRUE** ← BUG! Signal is in queue from init
2. `wait_for_signal_raw("userMessage")` → **consumes** the signal as steering
3. `schedule_raw("llm-request")` → replays from event log
4. `wait_for_signal_raw("userMessage")` → queue is **empty** → suspends again

The signal intended for step 3 of the original execution is consumed at step 2 during replay.

### Why It Doesn't Cause Determinism Violations

The `set_raw` replay validation only checks key names match, not values. During the diverged replay:
- state_seq=0: `set_raw("status", "running")` → key matches ✓
- state_seq=1: `set_raw("currentTurn", 1)` → key matches ✓
- task_seq=0: `schedule_raw("llm-request")` → matches ✓ (returns same result)
- state_seq=2: `set_raw("messages", [...])` → key "messages" matches ✓ (but value differs!)

The state events have the same keys in the same order because the steering consumption doesn't produce state events, and the subsequent operations follow the same code path (just with different message content).

## Affected Pattern

Any workflow that combines:
1. `has_signal()` / `wait_for_signal_raw()` in a non-blocking check loop (steering)
2. `wait_for_signal_raw()` as a durable suspension point

This is the pattern used by the `AgentWorkflow` (agent.rs lines 50-55 + line 205):

```rust
loop {
    for _ in 0..max_turns {
        // Steering check — consumes signals that arrive WHILE running
        while ctx.has_signal("userMessage") {
            let sig = ctx.wait_for_signal_raw("userMessage").await?;
            // ... add to messages ...
        }
        // ... LLM call ...
    }
    // Durable wait — suspends until next user message
    let signal = ctx.wait_for_signal_raw("userMessage").await?;
    // ... add to messages, loop back ...
}
```

## Proposed Fix

The replay engine needs to distinguish between **pre-existing signals** (available when the workflow was first run) and **post-suspension signals** (arrived after a WORKFLOW_SUSPENDED event).

**Option A: Causal signal ordering**

During `ReplayEngine::new()`, track WORKFLOW_SUSPENDED events. Signals that appear after a WORKFLOW_SUSPENDED(SIGNAL) should be placed in a "deferred" queue that is only accessible to `wait_for_signal_raw`, not to `has_signal`.

**Option B: Sequence-based signal matching**

Track signal consumptions with per-name sequence counters (like tasks/states). Each `wait_for_signal_raw` that consumes a signal gets a sequence number. `has_signal` checks if the next sequence has a signal, not just if the queue is non-empty.

**Option C: Workflow-level fix**

Skip the `has_signal` check in the first inner loop iteration after a signal wake-up, since the follow-up message was already added by the outer loop's `wait_for_signal_raw`. This is simpler but doesn't fix the underlying replay engine issue for other workflows.

## Reproduction

### Unit test (replay engine level)
See `replay_engine.rs::test_has_signal_returns_true_for_post_suspension_signal`

### Unit test (agent workflow level)
See `agent.rs::test_multi_turn_signal_consumed_as_follow_up_not_steering`

### E2E test
See `signal_tests.rs::test_conversation_loop_multi_turn`

## Fix Verification

Before claiming fixed:
1. Replay engine test must show `has_signal` returns false for post-suspension signals
2. Agent workflow test must show 2 turns and 4 messages (not 1 turn and 3 messages)
3. E2E test must complete a 2-turn conversation without hanging
