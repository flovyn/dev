# Bug: High CPU with Idle Worker (~23% per worker)

**Date**: 2026-01-06
**Severity**: High
**Status**: Root cause confirmed - Fix verified

## Symptoms

- Server uses ~23% CPU per connected worker even when idle
- CPU usage scales with number of connected workers
- Profile shows 98% of time in wait states (`__psynch_cvwait`, `kevent`)
- 48% of samples have <1ms between them (frequent wake-ups)
- High network I/O (`__sendto`, `__recvfrom`) even when idle

## Key Observation

98% time in wait states but 23% CPU suggests:
- Threads wake up very frequently
- Do minimal work per wake
- Go back to sleep immediately
- The overhead is from context switches and small work bursts, not sustained computation

## Hypotheses

### Hypothesis 1: SDK 100ms polling fallback
**Theory**: SDK polls every 100ms when no work, causing 10 polls/sec per worker.

**Against**: 10 requests/sec is trivial. Modern systems handle thousands of req/sec. This alone shouldn't cause 23% CPU.

**Test**: Change interval to 5s, measure CPU. If CPU drops proportionally, this is a factor.

### Hypothesis 2: Expensive poll_workflow handler
**Theory**: Each poll triggers expensive operations (complex queries, locks, etc.)

**Test**: Add timing logs to poll_workflow, check how long each call takes and what it does.

### Hypothesis 3: Notification streaming overhead
**Theory**: The gRPC notification stream (SubscribeToNotifications) has continuous overhead even when idle.

**Test**: Connect worker WITHOUT notification subscription, compare CPU.

### Hypothesis 4: Broadcast wake-all pattern
**Theory**: WorkerNotifier broadcasts to ALL workers, causing O(N) wake-ups per notification.

**Against**: Profile was with 1 worker, so no wake-all problem in this case.

**Note**: Could be a factor with multiple workers, but not the primary cause here.

### Hypothesis 5: Scheduler/timer overhead
**Theory**: Background scheduler wakes up frequently and does work.

**Test**: Check scheduler interval (should be 500ms). Add logging to see if it's active.

### Hypothesis 6: Database connection pool activity
**Theory**: Connection pool maintenance causes frequent wakes.

**Test**: Profile database layer specifically.

### Hypothesis 7: gRPC/tonic keepalive or internal polling
**Theory**: tonic or h2 has internal keepalive/polling that causes overhead.

**Test**: Check tonic configuration, look for keepalive settings.

## Investigation Plan

### Step 1: Understand the code paths

Look at:
- `flovyn-server/server/src/api/grpc/workflow_dispatch.rs` - poll_workflow and notification subscription
- `flovyn-server/server/src/api/grpc/mod.rs` - WorkerNotifier
- `flovyn-server/server/src/scheduler.rs` - Background scheduler

### Step 2: Add instrumentation

Add timing/logging to:
- poll_workflow handler (entry/exit times)
- Notification send/receive
- Scheduler tick

### Step 3: Isolate components

Test scenarios:
1. Worker connected, notifications DISABLED → measure CPU
2. Worker connected, notifications ENABLED, no polling → measure CPU
3. Worker connected, both enabled → measure CPU (baseline)

### Step 4: Profile with symbols

Use `cargo build --profile profiling` to get proper function names in samply.

## Evidence from Profile

- Total samples: 1,888,374 over ~293 seconds
- 84% in `__psynch_cvwait` (condition variable wait)
- 48% of samples have delta <1ms (rapid wake/sleep cycles)
- Multiple tokio-runtime-worker threads show high sample counts

## Test Environment

**Setup**:
- Server: `cd ../dev && just server saas`
- Worker: `cd ../sdk-rust && cargo run -p standalone-tasks-sample`
- CPU measurement: `ps -p <PID> -o %cpu=`

## Findings

### Finding 1: 2026-01-06 - Code analysis shows no obvious tight loops

Analyzed the following code paths:
- `poll_workflow` handler: Parse → Authorize → DB query → Return (reasonable)
- Notification subscription server task: Waits on broadcast channel or 30s timeout
- SDK polling loop: Waits on notification or timeout (currently 30s)

**No obvious tight loops in application code.** The rapid wake-ups (<1ms delta in 48% samples) must be coming from something else.

### Finding 2: 2026-01-06 - Baseline CPU is 0% without workers

**Experiment 1 Results**:
- Server running with `just server saas`
- No workers connected
- CPU samples over 10 seconds: 0.0%, 0.0%, 0.0%, 0.0%, 0.0%
- **Baseline: 0% CPU**

### Finding 3: 2026-01-06 - With 1 worker (100ms polling): ~24% server CPU

**Experiment 5 Results** (100ms interval):
- Worker: `cargo run -p standalone-tasks-sample`
- Polling interval: 100ms (current default)
- Measured every 10s for 2 minutes:

| Time | Server CPU | Worker CPU |
|------|------------|------------|
| 10s  | 0.0%       | 0.0%       |
| 20s  | 24.1%      | 20.1%      |
| 30s  | 25.1%      | 20.8%      |
| 40s  | 24.8%      | 20.5%      |
| 50s  | 25.1%      | 20.8%      |
| 60s  | 25.1%      | 21.1%      |
| 70s  | 24.3%      | 20.4%      |
| 80s  | 24.8%      | 20.7%      |
| 90s  | 23.6%      | 19.7%      |
| 100s | 24.1%      | 20.2%      |
| 110s | 24.1%      | 20.4%      |
| 120s | 23.8%      | 20.0%      |

**Average: Server ~24.5% CPU, Worker ~20.4% CPU**

### Finding 4: 2026-01-06 - CPU does NOT scale with polling interval - POLLING IS NOT THE CAUSE

**Experiment 5 Results** (comparing intervals):

| Interval | Polls/sec | Server CPU | Worker CPU | Notes |
|----------|-----------|------------|------------|-------|
| 100ms    | 10        | ~24.5%     | ~20.4%     | Current default |
| 500ms    | 2         | ~24.2%     | ~19.8%     | 5x slower polling |
| 1s       | 1         | ~24.7%     | ~20.1%     | 10x slower polling |

**CONCLUSION: Polling interval has NO effect on CPU usage!**

The CPU stays constant at ~24% whether polling 10x/sec or 1x/sec. This definitively rules out Hypothesis 1 (SDK 100ms polling) as the root cause.

### Finding 5: 2026-01-06 - Notifications disabled: Still ~24% CPU

Disabling workflow notifications (`enable_notifications: false`) had NO effect on CPU usage.
This rules out Hypothesis 3 (Notification streaming overhead).

### Finding 6: 2026-01-06 - Task worker has NO sleep between polls (hypothesis)

The standalone-tasks-sample only registers **tasks** (not workflows), so only the **TaskExecutorWorker** runs.

Looking at `sdk-rust/sdk/src/worker/task_worker.rs`:

**Server-side `poll_task`** (task_execution.rs:250):
- Queries database immediately
- Returns immediately (no long-polling, no waiting)

**Client-side task worker loop** (task_worker.rs:287-371):
```rust
while self.running.load(Ordering::SeqCst) {
    // ... pause check ...

    tokio::select! {
        // ... shutdown checks ...
        result = self.poll_and_execute() => {
            // If Ok(()) (no task), loops immediately with NO SLEEP!
        }
    }
}
```

When `poll_and_execute()` returns `Ok(())` (no task available), the loop continues **immediately** with no delay!

**This is the root cause:** Task worker polls as fast as possible when idle.

**Contrast with workflow worker** (`workflow_worker.rs:615-622`):
```rust
// When no workflow available:
tokio::select! {
    _ = work_available_notify.notified() => { ... }
    _ = tokio::time::sleep(Duration::from_millis(100)) => { ... }  // Has sleep!
}
```

The workflow worker has a 100ms fallback sleep, but the task worker has NONE.

## Solution

Add a fallback sleep to the task worker loop when no task is available, similar to workflow worker:

```rust
// In task_worker.rs, after poll_and_execute returns Ok(()) with no task:
tokio::time::sleep(Duration::from_millis(100)).await;
```

Or better: implement notifications for task workers similar to workflow workers.

### Finding 7: 2026-01-06 - CONFIRMED: Adding 100ms sleep drops CPU from 24% to <1%

**Test**: Added 100ms sleep to task_worker.rs when no task available:
```rust
None => {
    // No task available - sleep before next poll to avoid tight loop
    tokio::time::sleep(Duration::from_millis(100)).await;
    return Ok(());
}
```

**Results** (2 minute measurement):

| Time | Server CPU | Worker CPU |
|------|------------|------------|
| 10s  | 0.7%       | 0.8%       |
| 20s  | 0.3%       | 0.6%       |
| 30s  | 0.5%       | 0.8%       |
| 40s  | 0.7%       | 1.0%       |
| 50s  | 0.7%       | 0.8%       |
| 60s  | 0.6%       | 0.6%       |
| 70s  | 0.5%       | 0.9%       |
| 80s  | 0.2%       | 0.5%       |
| 90s  | 0.3%       | 0.6%       |
| 100s | 0.3%       | 0.7%       |
| 110s | 0.6%       | 0.7%       |
| 120s | 0.4%       | 0.7%       |

**Average: Server ~0.5% CPU, Worker ~0.7% CPU**

**Comparison**:
| Condition | Server CPU | Worker CPU |
|-----------|------------|------------|
| Before fix (no sleep) | ~24.5% | ~20.4% |
| After fix (100ms sleep) | ~0.5% | ~0.7% |
| **Reduction** | **98%** | **97%** |

**ROOT CAUSE CONFIRMED**: Task worker tight polling loop without sleep.

### Possible hidden causes to investigate:
1. gRPC/tonic HTTP/2 keepalive ping-pong
2. Database connection pool maintenance
3. Tracing/telemetry overhead
4. tokio runtime internals
5. The notification gRPC stream itself

## Concrete Experiments

### Experiment 1: Baseline without worker

**Goal**: Measure server CPU with no workers connected
**Steps**:
1. Start server: `./dev.sh run`
2. Wait 30 seconds for stabilization
3. Measure CPU: `top -pid $(pgrep flovyn-server)`
4. Record: Expected ~0-2% CPU

### Experiment 2: Server only, worker polls manually (no SDK)

**Goal**: Isolate if SDK is causing overhead
**Steps**:
1. Start server
2. Use `grpcurl` to call `poll_workflow` once per second
3. Measure server CPU
4. Compare to baseline

### Experiment 3: Worker with notifications DISABLED

**Goal**: Test if notification streaming causes overhead
**Steps**:
1. Modify SDK to NOT subscribe to notifications
2. Start worker with long polling interval (e.g., 10s)
3. Measure CPU
4. Compare to baseline

### Experiment 4: Worker with notifications ENABLED but polling DISABLED

**Goal**: Test notification stream in isolation
**Steps**:
1. Modify SDK to NOT poll, only subscribe to notifications
2. Start worker (will just hold notification stream open)
3. Measure CPU
4. Compare to baseline

### Experiment 5: Different polling intervals

**Goal**: Quantify polling impact on CPU
**Location**: `sdk-rust/sdk/src/worker/workflow_worker.rs:619`
**Current value**: `Duration::from_millis(100)`

**Steps**:
1. Build SDK and server
2. For each interval (100ms, 500ms, 1s):
   - Modify line 619: `Duration::from_millis(X)` or `Duration::from_secs(X)`
   - Rebuild SDK
   - Start server, connect 1 worker, wait 60s
   - Record CPU usage
3. Create table:

| Interval | Polls/sec | Server CPU % | Notes |
|----------|-----------|--------------|-------|
| 100ms    | 10        | ?            | Current |
| 500ms    | 2         | ?            |       |
| 1s       | 1         | ?            |       |

**Expected outcome**:
- If CPU scales linearly with poll frequency → polling is the cause
- If CPU stays high regardless → polling is NOT the cause

### Experiment 6: Profile with symbols

**Goal**: See actual function names in profile
**Steps**:
```bash
cargo build --profile profiling
samply record ./target/profiling/flovyn-server
# Connect worker, wait for CPU to spike, stop samply
```

## Next Steps

1. Run Experiment 1 (baseline)
2. Run Experiment 6 (profile with symbols)
3. Based on results, narrow down hypothesis

## Files to Investigate

- `flovyn-server/server/src/api/grpc/workflow_dispatch.rs` - poll_workflow, subscribe_to_notifications
- `flovyn-server/server/src/api/grpc/mod.rs` - WorkerNotifier
- `flovyn-server/server/src/scheduler.rs` - Background scheduler
- `sdk-rust/sdk/src/worker/workflow_worker.rs` - SDK polling logic

## Fix Applied

Added configurable `no_work_backoff` to both TaskWorkerConfig and WorkflowWorkerConfig:

### Task Worker (`sdk-rust/sdk/src/worker/task_worker.rs`)
```rust
// Config field (line 30-31)
pub no_work_backoff: Duration,

// Default (line 64)
no_work_backoff: Duration::from_millis(100),

// Usage when no task available (lines 411-417)
None => {
    tokio::time::sleep(self.config.no_work_backoff).await;
    return Ok(());
}
```

### Workflow Worker (`sdk-rust/sdk/src/worker/workflow_worker.rs`)
```rust
// Config field (line 36-37)
pub no_work_backoff: Duration,

// Default (line 72)
no_work_backoff: Duration::from_millis(100),

// Usage when no workflow available (line 622)
_ = tokio::time::sleep(config.no_work_backoff) => {}
```

The workflow worker already had the 100ms sleep, but it was hardcoded. Now both workers have configurable backoff via their respective config structs.
