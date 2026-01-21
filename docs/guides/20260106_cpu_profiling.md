# CPU Profiling Guide for flovyn-server

This guide covers techniques to debug high CPU usage in the flovyn-server.

## Quick Start: samply (Recommended for macOS)

`samply` is a sampling profiler that generates flame graphs viewable in Firefox Profiler.

### Installation

```bash
cargo install samply
```

### Profile the Server

```bash
# Build with profiling profile (optimized + debug symbols)
cargo build --profile profiling

# Profile the server
samply record ./target/profiling/flovyn-server

# Or attach to a running process (may have limited symbols)
samply record -p <PID>
```

**Important**: The default `--release` build strips symbols (`strip = true` in Cargo.toml).
Always use `--profile profiling` for CPU profiling to see function names.

This opens Firefox Profiler automatically with a flame graph showing where CPU time is spent.

### What to Look For

1. **Hot functions** - Functions with large self-time are spending CPU directly
2. **Call stacks** - Trace up to see what's calling the hot functions
3. **Async runtime** - Look for `tokio::` functions - excessive polling indicates issues
4. **Syscalls** - Heavy `epoll_wait` or `kevent` is normal for I/O; `futex` might indicate lock contention

## tokio-console (Async Runtime Debugging)

For debugging async task behavior (busy-waiting, excessive waking):

```bash
# Build and run with tokio-console support
./bin/dev/run-with-console.sh

# In another terminal
tokio-console
```

### What to Look For

1. **Poll times** - Tasks taking >1ms per poll may be doing blocking work
2. **Wake counts** - High wakes/sec indicates busy-waiting or hot loops
3. **Idle ratio** - Low idle time means tasks are constantly active
4. **Task count** - Growing task count may indicate spawn leaks

## Common CPU Issues in Async Rust

### 1. Busy-Waiting Loops

**Symptom**: High CPU even when idle
**Cause**: Loop that polls without yielding

```rust
// BAD: Spins CPU
loop {
    if let Some(work) = try_get_work() {
        process(work);
    }
}

// GOOD: Yields when no work
loop {
    match try_get_work() {
        Some(work) => process(work),
        None => tokio::time::sleep(Duration::from_millis(10)).await,
    }
}
```

### 2. Blocking in Async Context

**Symptom**: High CPU, poor throughput
**Cause**: Synchronous/blocking code in async functions

```rust
// BAD: Blocks the runtime
async fn process() {
    std::thread::sleep(Duration::from_secs(1)); // Blocks!
    heavy_computation(); // Blocks!
}

// GOOD: Use async or spawn_blocking
async fn process() {
    tokio::time::sleep(Duration::from_secs(1)).await;
    tokio::task::spawn_blocking(|| heavy_computation()).await;
}
```

### 3. Tight Polling Intervals

**Symptom**: Consistent CPU usage matching poll frequency
**Cause**: Database or timer polling too frequently

```rust
// BAD: Polls every 10ms
let mut interval = tokio::time::interval(Duration::from_millis(10));

// BETTER: Use longer intervals or notifications
let mut interval = tokio::time::interval(Duration::from_millis(500));
```

### 4. Channel/Broadcast Issues

**Symptom**: CPU spikes on notifications
**Cause**: All subscribers wake up even when message doesn't match

```rust
// Common pattern - filter after receiving
loop {
    let msg = rx.recv().await;
    if msg.matches_my_filter() {
        // process
    }
    // Even non-matching messages wake this task
}
```

## Profiling Workflow

1. **Reproduce the issue**
   ```bash
   # Run server and observe CPU
   ./dev.sh run
   top -pid $(pgrep flovyn-server)
   ```

2. **Capture a profile**
   ```bash
   # Record for 30 seconds
   samply record -d 30 -p $(pgrep flovyn-server)
   ```

3. **Analyze the flame graph**
   - Sort by self-time to find hot spots
   - Look for unexpected functions taking significant time
   - Check async runtime overhead

4. **Use tokio-console for async issues**
   ```bash
   ./bin/dev/run-with-console.sh
   # Watch task metrics in real-time
   ```

5. **Add tracing if needed**
   ```rust
   #[tracing::instrument]
   async fn suspect_function() {
       // ...
   }
   ```

## Quick Checks

### Is the server doing work or idle-spinning?

```bash
# Check if there are active workflows/tasks
psql $DATABASE_URL -c "SELECT status, count(*) FROM workflow_execution GROUP BY status"
psql $DATABASE_URL -c "SELECT status, count(*) FROM task_execution GROUP BY status"
```

If counts are low but CPU is high, something is spinning unnecessarily.

### Check scheduler frequency

The scheduler runs every 500ms by default (see `flovyn-server/server/src/scheduler.rs`). This should use minimal CPU unless there's work to process.

### Check connected workers

Workers use long-polling which should be efficient. High CPU with many connected workers might indicate notification broadcast overhead.

## Files to Investigate

| Symptom | Files to Check |
|---------|---------------|
| High CPU when idle | `scheduler.rs`, `workflow_dispatch.rs` (notifications) |
| High CPU during polling | `workflow_dispatch.rs`, `task_execution.rs` |
| CPU spikes on events | `streaming/` (NATS/in-memory streaming) |
| Lock contention | Any code using `Mutex`, `RwLock` |
