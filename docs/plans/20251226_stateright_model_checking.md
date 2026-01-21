# Implementation Plan: Stateright Model Checking

**Design Document**: `.dev/docs/design/20251226_stateright-model-checking.md`

**Status**: Implemented ✅

---

## Implementation Summary

This implementation adds formal model checking to the Flovyn server using the Stateright framework. The models verify key correctness properties of workflow execution, parallel completion, recovery, and infrastructure operations.

### What Was Implemented

| Model | File | Properties Verified |
|-------|------|---------------------|
| CompositeWorkflowModel | `composite_workflow.rs` | Cross-state-machine consistency, causality, uniqueness |
| ParallelCompletionModel | `parallel_completion.rs` | N! completion orderings for join_all/select/race |
| RecoveryModel | `recovery.rs` | Convergence from faulty states, bounded recovery |
| EventAppendModel | `event_append.rs` | Advisory lock serialization |
| SchedulerModel | `scheduler.rs` | Timer exactly-once firing |
| WorkDistributionModel | `work_distribution.rs` | SKIP LOCKED semantics |

### Mutation Tests

Each model includes mutation tests that verify the model can catch bugs:

| Model | Mutation | Bug Caught |
|-------|----------|------------|
| CompositeWorkflow | CompletesWithPendingMutant | Completing with pending work |
| CompositeWorkflow | NoResumeOnCompletionMutant | Not resuming on task completion |
| ParallelCompletion | WrongJoinAllOrderMutant | Wrong result order |
| ParallelCompletion | SelectNoCancelMutant | Not canceling losers |
| ParallelCompletion | NoFailFastMutant | Not failing fast |
| Recovery | UndetectedOrphanMutant | Missing fault detection |
| Recovery | IneffectiveRecoveryMutant | Recovery doesn't fix fault |
| Recovery | UnboundedRecoveryMutant | Infinite recovery loop |
| EventAppend | AppendWithoutLockMutant | Append without lock |
| Scheduler | DoubleFireMutant | Timer fires twice |
| WorkDistribution | NoSkipLockedMutant | Claim stealing |

---

## Usage

### Running Model Tests

```bash
# Run all model tests
cargo test --test model_tests

# Run specific model tests
cargo test --test model_tests composite_workflow
cargo test --test model_tests parallel_completion
cargo test --test model_tests recovery

# Run with output
cargo test --test model_tests -- --nocapture

# Run in release mode (faster)
cargo test --test model_tests --release
```

### Interactive State Explorer

The model explorer provides a web UI for exploring the workflow state space:

```bash
# Build and run the explorer
cargo run --bin model-explorer

# Open http://localhost:3000 in your browser
```

The explorer allows you to:
- Navigate the state graph interactively
- See all possible actions from each state
- Explore counterexamples for property violations
- Understand the state space structure

---

## Project Structure

```
server/
├── Cargo.toml                          # stateright dependency
├── src/bin/
│   └── model_explorer.rs               # Interactive state explorer
├── tests/
│   ├── model_tests.rs                  # Model test entry point
│   ├── model_tests/
│   │   ├── composite_workflow.rs       # Cross-state-machine model
│   │   ├── parallel_completion.rs      # N! ordering model
│   │   ├── recovery.rs                 # Convergence model
│   │   ├── event_append.rs             # Lock serialization model
│   │   ├── scheduler.rs                # Timer model
│   │   └── work_distribution.rs        # SKIP LOCKED model
│   └── integration/
│       └── oracle_tests.rs             # Oracle tests connecting models to real DB
└── .github/workflows/ci.yml            # CI job for model tests
```

---

## Test Results

All 28 tests pass:

```
running 28 tests
test composite_workflow::tests::catches_complete_with_pending_bug ... ok
test composite_workflow::tests::catches_no_resume_on_completion_bug ... ok
test composite_workflow::tests::test_parallel_task_completions ... ok
test composite_workflow::tests::test_with_children ... ok
test composite_workflow::tests::verify_composite_model_properties ... ok
test event_append::tests::catches_append_without_lock ... ok
test event_append::tests::test_3_writers ... ok
test event_append::tests::verify_event_append_model ... ok
test parallel_completion::tests::catches_no_fail_fast ... ok
test parallel_completion::tests::catches_select_no_cancel ... ok
test parallel_completion::tests::catches_wrong_join_all_order ... ok
test parallel_completion::tests::test_5_operations_tractable ... ok
test parallel_completion::tests::test_join_all_3_operations ... ok
test parallel_completion::tests::test_race_3_operations ... ok
test parallel_completion::tests::test_select_3_operations ... ok
test recovery::tests::catches_ineffective_recovery ... ok
test recovery::tests::catches_unbounded_recovery ... ok
test recovery::tests::catches_undetected_orphan ... ok
test recovery::tests::test_bounded_recovery ... ok
test recovery::tests::test_recovery_from_orphan ... ok
test recovery::tests::verify_recovery_model_properties ... ok
test scheduler::tests::catches_double_fire ... ok
test scheduler::tests::test_3_schedulers ... ok
test scheduler::tests::verify_scheduler_model ... ok
test work_distribution::tests::catches_no_skip_locked ... ok
test work_distribution::tests::test_3_workers_3_work ... ok
test work_distribution::tests::test_contention ... ok
test work_distribution::tests::verify_work_distribution_model ... ok

test result: ok. 28 passed; 0 failed
```

---

## Properties Verified

### CompositeWorkflowModel

1. **waiting implies pending work** - If workflow is WAITING, there must be pending tasks/timers/children
2. **completed implies no pending work** - Completed workflows have no unfinished work
3. **children terminal before complete** - All child workflows must be terminal before parent completes
4. **cancellation propagates** - Cancelling workflow cancels all children
5. **task scheduled before completed** - TaskCompleted requires prior TaskScheduled
6. **timer started before fired** - TimerFired requires prior TimerStarted
7. **child initiated before completed** - ChildCompleted requires prior ChildInitiated
8. **timer fires at most once** - No duplicate timer fires
9. **no duplicate task ids** - Each task ID is unique

### ParallelCompletionModel

1. **join_all result order independent** - Results in index order, not completion order
2. **join_all waits for all** - Only resolves when ALL operations complete
3. **join_all fails fast** - Fails immediately on first failure
4. **select has one winner** - Exactly one operation wins
5. **select cancels losers** - All non-winners are cancelled

### RecoveryModel

1. **recovery leads to consistency** - After recovery, state is consistent
2. **faults detected** - Faulty states are marked as inconsistent
3. **can recover and complete** - Eventually can reach consistent completion

### Infrastructure Models

1. **sequences monotonic** - Event sequences are strictly increasing
2. **no duplicate sequences** - No duplicate sequence numbers
3. **appends serialized by lock** - Lock required for appending
4. **timer fires at most once** - Exactly-once timer semantics
5. **single worker per work** - No double-claiming with SKIP LOCKED

---

## CI Integration

Model tests run automatically in CI:

```yaml
model-tests:
  name: Model Tests
  runs-on: ubuntu-latest
  timeout-minutes: 5
  steps:
    - uses: actions/checkout@v4
    - name: Install protobuf compiler
      run: sudo apt-get update && sudo apt-get install -y protobuf-compiler
    - name: Install Rust
      uses: dtolnay/rust-toolchain@master
      with:
        toolchain: "1.92.0"
    - name: Run model tests
      run: cargo test --test model_tests --release
```

---

## Model Testing Guide

This guide explains how to use Stateright for model checking in the Flovyn codebase.

### What is Model Testing?

Model testing uses formal methods to verify correctness properties by exhaustively exploring all possible states of a system. Unlike unit tests that check specific scenarios, model tests check **all possible orderings** of concurrent operations.

**Why use it?**
- Finds race conditions that are nearly impossible to catch with traditional tests
- Verifies invariants hold across all reachable states
- Documents system properties formally
- Catches bugs before they reach production

### Writing a New Model

#### Step 1: Define State and Actions

```rust
use stateright::{Model, Property};
use std::hash::Hash;

/// State must implement Hash, Clone, Debug, PartialEq, Eq
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct MyState {
    pub counter: u32,
    pub is_locked: bool,
}

/// Actions represent possible state transitions
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum MyAction {
    Increment,
    Lock,
    Unlock,
}
```

#### Step 2: Implement the Model Trait

```rust
pub struct MyModel {
    pub max_counter: u32,
}

impl Model for MyModel {
    type State = MyState;
    type Action = MyAction;

    fn init_states(&self) -> Vec<Self::State> {
        vec![MyState { counter: 0, is_locked: false }]
    }

    fn actions(&self, state: &Self::State, actions: &mut Vec<Self::Action>) {
        if state.counter < self.max_counter {
            actions.push(MyAction::Increment);
        }
        if !state.is_locked {
            actions.push(MyAction::Lock);
        } else {
            actions.push(MyAction::Unlock);
        }
    }

    fn next_state(&self, state: &Self::State, action: Self::Action) -> Option<Self::State> {
        let mut next = state.clone();
        match action {
            MyAction::Increment => next.counter += 1,
            MyAction::Lock => next.is_locked = true,
            MyAction::Unlock => next.is_locked = false,
        }
        Some(next)
    }

    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::always("counter bounded", |_, state: &MyState| {
                state.counter <= 10  // invariant
            }),
            Property::sometimes("can reach max", |model, state: &MyState| {
                state.counter == model.max_counter  // liveness
            }),
        ]
    }
}
```

#### Step 3: Write Tests

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use stateright::Checker;

    #[test]
    fn verify_properties() {
        let model = MyModel { max_counter: 5 };
        model.checker().spawn_bfs().join().assert_properties();
    }
}
```

### Writing Mutation Tests

Mutation tests verify your model can actually catch bugs. Create a "mutant" model that has a known bug, then verify the checker finds it.

```rust
/// Buggy version that doesn't check lock before incrementing
pub struct BuggyModel;

impl Model for BuggyModel {
    // ... same as MyModel but with a bug ...

    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            // This property should FAIL for the buggy model
            Property::always("increments require lock", |_, state: &MyState| {
                // Bug: we increment without checking lock
                state.is_locked || state.counter == 0
            }),
        ]
    }
}

#[test]
fn catches_unlock_bug() {
    let model = BuggyModel;
    let checker = model.checker().spawn_bfs().join();
    // Verify the checker FINDS the bug (discovers a counterexample)
    checker.assert_any_discovery("increments require lock");
}
```

### Writing Oracle Tests

Oracle tests connect abstract models to real implementation code. They execute against the actual database to verify the implementation matches model properties.

#### Pattern 1: Model-Generated Test Sequences

Use the model to generate action sequences, then replay them against real code. See `property_based_event_append_model_paths` in `oracle_tests.rs`:

```rust
/// Trait for executing model actions against real infrastructure
#[async_trait::async_trait]
trait ModelExecutor: Send + Sync {
    type Action: Clone + Send;
    type State: PartialEq + std::fmt::Debug + Send;

    async fn execute(&self, action: &Self::Action) -> Result<(), String>;
    async fn get_real_state(&self) -> Result<Self::State, String>;
}

/// Generate paths from a model using BFS exploration
fn generate_model_paths(num_writers: usize, events_per_writer: usize, max_paths: usize)
    -> Vec<Vec<ExecutorAction>>
{
    // BFS to enumerate all valid action sequences
    // Returns paths that reach terminal states
}

#[tokio::test]
async fn property_based_event_append_model_paths() {
    let paths = generate_model_paths(2, 2, 50);  // 50 paths

    for path in paths {
        let executor = EventAppendExecutor::new(pool.clone(), tenant_id).await?;

        // Execute each action
        for action in &path {
            executor.execute(action).await?;
        }

        // Verify properties on real state
        let state = executor.get_real_state().await?;
        assert!(!state.has_duplicates, "No duplicate sequences");
        assert!(state.is_monotonic, "Sequences monotonic");
    }
}
```

#### Pattern 2: Random Path Sampling

For large state spaces, sample random paths instead of exhaustive replay. See `property_based_random_path_sampling` in `oracle_tests.rs`:

```rust
#[tokio::test]
async fn property_based_random_path_sampling() {
    let mut rng = rand::rngs::StdRng::seed_from_u64(42);  // Reproducible

    for _ in 0..num_paths {
        let executor = EventAppendExecutor::new(pool.clone(), tenant_id).await?;
        let mut lock_holder: Option<u32> = None;

        // Generate and execute random path
        for _ in 0..max_depth {
            let mut actions = generate_valid_actions(&lock_holder, &events_written);
            if actions.is_empty() { break; }

            let action = actions.choose(&mut rng).unwrap().clone();
            executor.execute(&action).await?;
            update_tracking_state(&action, &mut lock_holder, &mut events_written);
        }

        // Verify properties
        let state = executor.get_real_state().await?;
        assert!(!state.has_duplicates && state.is_monotonic);
    }
}
```

#### Pattern 3: Test Correct Implementation (Manual)

```rust
#[tokio::test]
async fn oracle_property_holds() {
    let pool = get_test_database().await;

    // Execute real code that should satisfy the property
    let result = real_implementation(&pool).await;

    // Verify the model property holds
    assert!(result.satisfies_property(), "ORACLE FAILURE: Property violated!");
}
```

#### Pattern 4: Test Buggy Implementation (Negative Test)

```rust
#[tokio::test]
async fn oracle_buggy_code_fails() {
    let pool = get_test_database().await;

    // Execute buggy code pattern
    let found_bug = buggy_implementation(&pool).await;

    // Verify we CAN trigger the bug (confirms our model catches real issues)
    assert!(found_bug, "Should be able to trigger bug without proper locking");
}
```

#### Pattern 5: Concurrent Execution

```rust
#[tokio::test]
async fn oracle_concurrent_safety() {
    let pool = Arc::new(get_test_database().await);
    let success_count = Arc::new(AtomicU32::new(0));

    // Spawn concurrent workers
    let handles: Vec<_> = (0..5).map(|id| {
        let pool = pool.clone();
        let count = success_count.clone();
        tokio::spawn(async move {
            if try_operation(&pool, id).await.is_ok() {
                count.fetch_add(1, Ordering::SeqCst);
            }
        })
    }).collect();

    for h in handles { h.await.unwrap(); }

    // Model property: exactly one should succeed
    assert_eq!(success_count.load(Ordering::SeqCst), 1);
}
```

### Best Practices

1. **Keep models small** - State explosion is real. Start with 2-3 concurrent actors, max.

2. **Use `Property::always` for invariants** - Things that must never be violated:
   - "no duplicate IDs"
   - "completed implies no pending work"
   - "lock held during mutation"

3. **Use `Property::sometimes` for liveness** - Things that must eventually be possible:
   - "can reach completion"
   - "can recover from failure"

4. **Write mutation tests for every property** - If a property can't catch a bug, it's not useful.

5. **Connect to real code with oracle tests** - Abstract models are only valuable if they match reality.

6. **Model the concurrency, not the details** - Focus on interleavings, not business logic.

### Common Pitfalls

| Pitfall | Solution |
|---------|----------|
| State space explosion | Reduce max_tasks, max_workers, etc. |
| HashMap doesn't impl Hash | Implement Hash manually, sort entries by key |
| Closure type inference fails | Add explicit type: `\|_, state: &MyState\|` |
| Property always passes | Write a mutation test to verify it can fail |
| Oracle test is flaky | Use proper locking or increase iteration count |

---

## State Space Considerations

Keep model configurations small to avoid state space explosion:

| Model | Recommended Config | Approx. States |
|-------|-------------------|----------------|
| CompositeWorkflow | max_tasks: 1, max_children: 0 | ~500 |
| ParallelCompletion | num_operations: 3 | ~100 |
| Recovery | max_tasks: 1 | ~200 |
| EventAppend | num_writers: 2 | ~100 |
| Scheduler | num_timers: 2, num_schedulers: 2 | ~50 |
| WorkDistribution | num_work_items: 2, num_workers: 2 | ~50 |

If you need more coverage, run with `--release` and consider using Stateright's DFS or symmetry reduction.

---

## Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| stateright | 0.30 | Model checking framework |

---

## Oracle Testing

Oracle tests were added to connect the abstract Stateright models to the real server implementation. These tests execute against a real PostgreSQL database to verify that the implementation matches the model's properties.

### Oracle Tests

| Test | Property Verified | Result |
|------|-------------------|--------|
| `oracle_event_append_with_locks_ensures_unique_sequences` | Event sequences are unique and monotonic | PASS |
| `oracle_event_append_without_locks_can_cause_conflicts` | Without locks, conflicts can occur | PASS (confirms bug) |
| `oracle_work_distribution_skip_locked_prevents_double_claim` | SKIP LOCKED prevents double-claiming | PASS |
| `oracle_work_distribution_without_skip_locked_can_double_claim` | Without SKIP LOCKED, double-reads possible | PASS (confirms bug) |
| `oracle_timer_fires_exactly_once` | Timer fires exactly once | PASS (after fix) |
| `oracle_child_completion_fires_exactly_once` | Child completion notifies parent exactly once | PASS (after fix) |
| `oracle_child_completion_fires_multiple_times_BUG` | Documents race condition in old code | PASS (confirms bug) |
| `oracle_workflow_cannot_complete_with_pending_tasks` | Workflow can't complete with pending work | PASS |
| `property_based_event_append_model_paths` | Model-generated paths satisfy properties | PASS (50 paths) |
| `property_based_random_path_sampling` | Random path sampling finds no violations | PASS (20 paths) |
| `property_based_concurrent_execution` | Concurrent writes with proper locking | PASS (10 runs) |
| `property_based_concurrent_finds_bugs_in_buggy_code` | Buggy code (no locks) fails | PASS (finds bugs 10/10) |

### Bugs Found and Fixed

Oracle testing discovered **two real bugs** with the same race condition pattern:

#### Bug 1: Timer Firing Race Condition

**Bug:** Multiple schedulers could fire the same timer simultaneously due to a check-then-act race condition in `fire_expired_timers()`.

**Root Cause:** The function queried for expired timers, then processed them in a loop calling `event_repo.append()`. Between the query and insert, another scheduler could also query and see the same unfired timer.

**Fix:** Added `EventRepository::fire_timer_atomically()` which uses PostgreSQL advisory locks to:
1. Acquire exclusive lock on the workflow
2. Check if timer already fired (within lock)
3. Insert TIMER_FIRED event only if not already fired
4. Release lock on commit

Files changed:
- `flovyn-server/server/src/repository/event_repository.rs` - Added `fire_timer_atomically()` method
- `flovyn-server/server/src/scheduler.rs` - Updated `fire_expired_timers()` to use atomic method

#### Bug 2: Child Workflow Completion Race Condition

**Bug:** Multiple schedulers could send duplicate `CHILD_WORKFLOW_COMPLETED` events to parent workflows due to the same check-then-act pattern.

**Root Cause:** The `handle_completed_child_workflows()` function found completed children needing notification, then inserted completion events. Multiple schedulers running concurrently could all see the same unnotified child and each insert a completion event.

**Evidence:** Oracle test output showed "Child completion fired 3 times!" with 3 `CHILD_WORKFLOW_COMPLETED` events in the database.

**Fix:** Added `EventRepository::notify_child_completion_atomically()` which uses the same advisory lock pattern:
1. Acquire exclusive lock on the parent workflow
2. Check if child completion already notified (within lock)
3. Insert CHILD_WORKFLOW_COMPLETED/FAILED event only if not already notified
4. Release lock on commit

Files changed:
- `flovyn-server/server/src/repository/event_repository.rs` - Added `notify_child_completion_atomically()` method
- `flovyn-server/server/src/scheduler.rs` - Updated `handle_completed_child_workflows()` to use atomic method
- `flovyn-server/server/src/api/grpc/workflow_dispatch.rs` - Updated `notify_parent_of_child_completion()` to use atomic method

#### Bug 3: Promise Resolution Race Condition

**Bug:** Concurrent calls to resolve or reject the same promise could cause duplicate `PROMISE_RESOLVED` or `PROMISE_REJECTED` events.

**Root Cause:** The `resolve_promise()` and `reject_promise()` gRPC methods checked `promise.resolved` then appended events. Two concurrent calls could both see `resolved=false` and both append events.

**Fix:** Added `EventRepository::resolve_promise_atomically()` using the same advisory lock pattern:
1. Acquire exclusive lock on the workflow
2. Check if promise already resolved (within lock)
3. Insert PROMISE_RESOLVED/REJECTED event only if not already resolved
4. Release lock on commit

Files changed:
- `flovyn-server/server/src/repository/event_repository.rs` - Added `resolve_promise_atomically()` method
- `flovyn-server/server/src/api/grpc/workflow_dispatch.rs` - Updated `resolve_promise()` and `reject_promise()` to use atomic method

---

## Related Documents

- Design document: `.dev/docs/design/20251226_stateright-model-checking.md`
- Stateright documentation: https://docs.rs/stateright/latest/stateright/
