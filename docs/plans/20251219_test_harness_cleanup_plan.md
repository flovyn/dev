# Test Harness Container Cleanup Plan

**Goal**: Prevent orphaned Docker containers from accumulating after integration test runs

## Problem

Integration tests leave orphaned Docker containers running after test completion. Investigation found:

- **23 containers** running (postgres:18-alpine + nats:latest pairs)
- **Only 2** active test processes
- Containers from 8+ hours ago still running
- No Ryuk cleanup daemon active
- No testcontainers labels on containers

### Root Causes

1. **No `Drop` implementation** on `TestHarness` - containers aren't explicitly stopped
2. **Static `OnceCell`** - harness lives for process lifetime, never dropped normally
3. **No Ryuk cleanup** - testcontainers' automatic cleanup daemon not being used
4. **No shutdown hooks** - abnormal termination (timeout, kill, panic) leaves containers orphaned
5. **Server process not killed** - child `flovyn-server` process continues running

## TODO

### Phase 1: Immediate Fix

#### 1.1 Add Drop Implementation
- [x] Implement `Drop` for `TestHarness` in `flovyn-server/tests/integration/harness.rs`
- [x] Verify: Run tests, confirm server process is killed on exit

#### 1.2 Explicit Container Cleanup
- [x] Add `shutdown()` method to `TestHarness`
- [x] Note: This is for manual cleanup; Drop handles automatic cleanup

### Phase 2: Robust Cleanup

#### 2.1 Use atexit Handler
- [ ] Add `ctor` crate as dev-dependency for `dtor` macro (deferred - not needed with current approach)
- [ ] Register cleanup on process exit (deferred - Drop impl sufficient)

#### 2.2 Alternative: Use ctrlc Handler
- [ ] Add `ctrlc` crate as dev-dependency (deferred - not needed with current approach)
- [ ] Register handler in harness initialization (deferred)

#### 2.3 Container Labeling for External Cleanup
- [x] Add labels to containers for identification (`flovyn-test`, `flovyn-test-session`)
- [x] Create cleanup script `flovyn-server/bin/dev/cleanup-test-containers.sh`

### Phase 3: Test Timeout Handling

#### 3.1 Graceful Timeout Handling
- [x] Add `run_test_with_cleanup` function with timeout and panic handling
- [x] Add `with_timeout!` macro for simpler usage

#### 3.2 Test Panic Handling
- [x] Use `std::panic::catch_unwind` with `AssertUnwindSafe` in `run_test_with_cleanup`

### Phase 4: Alternative Architecture (Optional)

#### 4.1 Non-Static Harness
- [ ] Consider removing static `OnceCell` and using per-test or per-module harness
- [ ] Trade-off: Slower tests (container startup per test) vs reliable cleanup
- [ ] Use `#[fixture]` from `rstest` crate if per-test harness is desired

#### 4.2 Enable Ryuk
- [ ] Investigate why Ryuk isn't running with testcontainers-rs 0.23
- [ ] Ensure `TESTCONTAINERS_RYUK_DISABLED` is not set
- [ ] Verify Ryuk image is accessible

## File Changes

```
tests/integration/
└── harness.rs                    # Add Drop impl, shutdown method, labels

bin/dev/
└── cleanup-test-containers.sh    # NEW: Manual cleanup script

Cargo.toml                        # Add dev-dependencies if needed
```

## Verification

1. Run integration tests: `cargo test --test integration_tests`
2. Verify no orphaned containers: `docker ps | grep -E "(postgres|nats)"`
3. Kill test process mid-run (Ctrl+C) and verify cleanup
4. Verify cleanup script works: `./bin/dev/cleanup-test-containers.sh`

## Immediate Cleanup (Before Fix)

Run this to clean up existing orphaned containers:

```bash
# Stop all postgres and nats containers (careful if you have other uses)
docker stop $(docker ps -q --filter ancestor=postgres:18-alpine)
docker stop $(docker ps -q --filter ancestor=nats:latest)

# Or more targeted - kill flovyn-server processes first
pkill -f "target/debug/flovyn-server"
# Then containers will be orphaned but can be stopped
```
