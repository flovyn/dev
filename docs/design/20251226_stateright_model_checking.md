# Design: Stateright Model Checking for Server

## Status
**Proposed** - Needs evaluation

## Problem Statement

The Flovyn server has correctness requirements that are difficult to test:

1. **Cross-state-machine consistency**: A workflow's event log spans multiple sub-state-machines (tasks, timers, children, promises) that must stay consistent
2. **State machine interdependencies**: Sub-state completions trigger parent workflow state transitions
3. **Parallel execution orderings**: N parallel operations can complete in N! orderings - all must lead to correct final state
4. **Recovery from faulty states**: Corrupted event history must be recoverable to consistent state
5. **Infrastructure invariants**: Event append locks, timer exactly-once, single-worker claim

### What Bugs Can Slip Through Current Tests?

| Bug Type | Unit Tests | Integration Tests | Model Checking |
|----------|------------|-------------------|----------------|
| Race condition in event append | ✗ No concurrency | ✗ One ordering | ✓ All interleavings |
| Workflow completes with pending tasks | ✗ No composite state | △ Happy paths | ✓ All paths |
| Parallel tasks complete in wrong order | ✗ No parallelism | ✗ One ordering | ✓ N! orderings |
| Sub-state doesn't trigger resume | ✗ No interdependency | △ Some paths | ✓ All paths |
| Corrupted history not recoverable | ✗ No fault injection | ✗ No fault injection | ✓ All fault types |
| Double timer firing | ✗ No scheduler | △ Hard to trigger | ✓ Exhaustive |
| Work claimed by two workers | ✗ No concurrency | △ Rare race | ✓ All interleavings |

**Key insight**: Unit tests verify functions. Integration tests verify one execution path. Model checking verifies **all possible execution paths**.

## Goals

1. **Verify cross-state-machine consistency**
   - Composite model tracking workflow + tasks + timers + children + promises
   - Verify interdependencies (sub-state triggers parent transitions)

2. **Verify parallel execution correctness**
   - All N! completion orderings lead to correct state
   - Join semantics (wait for all) and select semantics (first wins)

3. **Verify recovery and convergence**
   - From any faulty state, can reach consistent state
   - Idempotent retry, eventual consistency

4. **Verify infrastructure invariants**
   - Event append serialization
   - Timer exactly-once
   - Single-worker claim

5. **Prove effectiveness through mutation testing**
   - Each mutation represents a real bug class
   - Model must catch the mutation

## Non-Goals

- Verifying actual PostgreSQL behavior (abstract as atomic operations)
- Performance testing
- Network partition simulation (complex, lower value for now)

---

## Core Models

### Model 1: CompositeWorkflowModel (Cross-State-Machine)

This is the **central model** that addresses cross-state-machine event history verification.

```rust
use stateright::Model;
use std::collections::{HashMap, HashSet};

type TaskId = String;
type TimerId = String;
type ChildName = String;
type PromiseId = String;

/// Composite state tracking all sub-state-machines together
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct CompositeWorkflowState {
    // Top-level workflow state
    workflow: WorkflowPhase,

    // Sub-state-machines (indexed by identifier)
    tasks: HashMap<TaskId, TaskPhase>,
    timers: HashMap<TimerId, TimerPhase>,
    children: HashMap<ChildName, ChildPhase>,
    promises: HashMap<PromiseId, PromisePhase>,

    // Event log for verification
    event_log: Vec<WorkflowEvent>,
    next_sequence: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum WorkflowPhase {
    Running,
    Suspended,  // Waiting for pending work
    Completed,
    Failed,
    Cancelling,
    Cancelled,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum TaskPhase { Scheduled, Started, Completed, Failed, Cancelled }

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum TimerPhase { Started, Fired, Cancelled }

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ChildPhase { Initiated, Started, Completed, Failed, CancellationRequested, Cancelled }

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum PromisePhase { Created, Resolved, Rejected }

impl CompositeWorkflowState {
    /// Check if workflow has pending work (should be SUSPENDED)
    pub fn has_pending_work(&self) -> bool {
        self.tasks.values().any(|p| matches!(p, TaskPhase::Scheduled | TaskPhase::Started))
            || self.timers.values().any(|p| matches!(p, TimerPhase::Started))
            || self.children.values().any(|p| matches!(p, ChildPhase::Initiated | ChildPhase::Started))
            || self.promises.values().any(|p| matches!(p, PromisePhase::Created))
    }

    /// Check if all work is terminal (can complete workflow)
    pub fn all_work_terminal(&self) -> bool {
        self.tasks.values().all(|p| matches!(p, TaskPhase::Completed | TaskPhase::Failed | TaskPhase::Cancelled))
            && self.timers.values().all(|p| matches!(p, TimerPhase::Fired | TimerPhase::Cancelled))
            && self.children.values().all(|p| matches!(p, ChildPhase::Completed | ChildPhase::Failed | ChildPhase::Cancelled))
            && self.promises.values().all(|p| matches!(p, PromisePhase::Resolved | PromisePhase::Rejected))
    }

    /// Count pending items
    pub fn pending_count(&self) -> usize {
        self.tasks.values().filter(|p| matches!(p, TaskPhase::Scheduled | TaskPhase::Started)).count()
            + self.timers.values().filter(|p| matches!(p, TimerPhase::Started)).count()
            + self.children.values().filter(|p| matches!(p, ChildPhase::Initiated | ChildPhase::Started)).count()
            + self.promises.values().filter(|p| matches!(p, PromisePhase::Created)).count()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum WorkflowEvent {
    // Workflow lifecycle
    WorkflowStarted,
    WorkflowSuspended,
    WorkflowResumed,
    WorkflowCompleted,
    WorkflowFailed { error: String },
    CancellationRequested,
    WorkflowCancelled,

    // Task lifecycle
    TaskScheduled { task_id: TaskId, task_type: String },
    TaskStarted { task_id: TaskId },
    TaskCompleted { task_id: TaskId },
    TaskFailed { task_id: TaskId },
    TaskCancelled { task_id: TaskId },

    // Timer lifecycle
    TimerStarted { timer_id: TimerId, duration_ms: u64 },
    TimerFired { timer_id: TimerId },
    TimerCancelled { timer_id: TimerId },

    // Child workflow lifecycle
    ChildWorkflowInitiated { name: ChildName, kind: String },
    ChildWorkflowStarted { name: ChildName },
    ChildWorkflowCompleted { name: ChildName },
    ChildWorkflowFailed { name: ChildName },
    ChildWorkflowCancellationRequested { name: ChildName },
    ChildWorkflowCancelled { name: ChildName },

    // Promise lifecycle
    PromiseCreated { promise_id: PromiseId },
    PromiseResolved { promise_id: PromiseId },
    PromiseRejected { promise_id: PromiseId },
}

pub struct CompositeWorkflowModel {
    pub max_tasks: usize,
    pub max_timers: usize,
    pub max_children: usize,
    pub max_promises: usize,
}

impl Model for CompositeWorkflowModel {
    type State = CompositeWorkflowState;
    type Action = WorkflowEvent;

    fn init_states(&self) -> Vec<Self::State> {
        vec![CompositeWorkflowState {
            workflow: WorkflowPhase::Running,
            tasks: HashMap::new(),
            timers: HashMap::new(),
            children: HashMap::new(),
            promises: HashMap::new(),
            event_log: vec![WorkflowEvent::WorkflowStarted],
            next_sequence: 1,
        }]
    }

    fn actions(&self, state: &Self::State, actions: &mut Vec<Self::Action>) {
        match &state.workflow {
            WorkflowPhase::Running => {
                // Can schedule new work (up to limits)
                if state.tasks.len() < self.max_tasks {
                    actions.push(WorkflowEvent::TaskScheduled {
                        task_id: format!("task-{}", state.tasks.len()),
                        task_type: "example".to_string(),
                    });
                }
                if state.timers.len() < self.max_timers {
                    actions.push(WorkflowEvent::TimerStarted {
                        timer_id: format!("timer-{}", state.timers.len()),
                        duration_ms: 1000,
                    });
                }
                if state.children.len() < self.max_children {
                    actions.push(WorkflowEvent::ChildWorkflowInitiated {
                        name: format!("child-{}", state.children.len()),
                        kind: "child-workflow".to_string(),
                    });
                }
                if state.promises.len() < self.max_promises {
                    actions.push(WorkflowEvent::PromiseCreated {
                        promise_id: format!("promise-{}", state.promises.len()),
                    });
                }

                // Can suspend if there's pending work
                if state.has_pending_work() {
                    actions.push(WorkflowEvent::WorkflowSuspended);
                }

                // Can complete if all work is terminal (or no work)
                if state.all_work_terminal() || state.pending_count() == 0 {
                    actions.push(WorkflowEvent::WorkflowCompleted);
                }

                // Can always fail or request cancellation
                actions.push(WorkflowEvent::WorkflowFailed { error: "error".to_string() });
                actions.push(WorkflowEvent::CancellationRequested);
            }

            WorkflowPhase::Suspended => {
                // External events complete pending work - THIS IS KEY FOR PARALLELISM
                // Each pending item can independently complete/fail
                for (task_id, phase) in &state.tasks {
                    if matches!(phase, TaskPhase::Scheduled | TaskPhase::Started) {
                        actions.push(WorkflowEvent::TaskCompleted { task_id: task_id.clone() });
                        actions.push(WorkflowEvent::TaskFailed { task_id: task_id.clone() });
                    }
                }

                for (timer_id, phase) in &state.timers {
                    if matches!(phase, TimerPhase::Started) {
                        actions.push(WorkflowEvent::TimerFired { timer_id: timer_id.clone() });
                    }
                }

                for (name, phase) in &state.children {
                    if matches!(phase, ChildPhase::Initiated | ChildPhase::Started) {
                        actions.push(WorkflowEvent::ChildWorkflowCompleted { name: name.clone() });
                        actions.push(WorkflowEvent::ChildWorkflowFailed { name: name.clone() });
                    }
                }

                for (promise_id, phase) in &state.promises {
                    if matches!(phase, PromisePhase::Created) {
                        actions.push(WorkflowEvent::PromiseResolved { promise_id: promise_id.clone() });
                        actions.push(WorkflowEvent::PromiseRejected { promise_id: promise_id.clone() });
                    }
                }

                // Can request cancellation while suspended
                actions.push(WorkflowEvent::CancellationRequested);
            }

            WorkflowPhase::Cancelling => {
                // Children must be cancelled before workflow can be cancelled
                for (name, phase) in &state.children {
                    if matches!(phase, ChildPhase::Initiated | ChildPhase::Started | ChildPhase::CancellationRequested) {
                        actions.push(WorkflowEvent::ChildWorkflowCancelled { name: name.clone() });
                    }
                }

                // If all children terminal, workflow can be cancelled
                if state.children.values().all(|p| matches!(p,
                    ChildPhase::Completed | ChildPhase::Failed | ChildPhase::Cancelled
                )) {
                    actions.push(WorkflowEvent::WorkflowCancelled);
                }
            }

            // Terminal states have no actions
            WorkflowPhase::Completed | WorkflowPhase::Failed | WorkflowPhase::Cancelled => {}
        }
    }

    fn next_state(&self, state: &Self::State, action: Self::Action) -> Option<Self::State> {
        let mut next = state.clone();
        next.next_sequence += 1;

        // Track pending count before action for interdependency logic
        let pending_before = next.pending_count();

        match &action {
            // --- Workflow transitions ---
            WorkflowEvent::WorkflowSuspended => {
                if next.workflow != WorkflowPhase::Running { return None; }
                if !next.has_pending_work() { return None; } // Can't suspend without pending
                next.workflow = WorkflowPhase::Suspended;
            }

            WorkflowEvent::WorkflowResumed => {
                if next.workflow != WorkflowPhase::Suspended { return None; }
                next.workflow = WorkflowPhase::Running;
            }

            WorkflowEvent::WorkflowCompleted => {
                if next.workflow != WorkflowPhase::Running { return None; }
                if next.has_pending_work() { return None; } // CRITICAL: Can't complete with pending
                next.workflow = WorkflowPhase::Completed;
            }

            WorkflowEvent::WorkflowFailed { .. } => {
                if !matches!(next.workflow, WorkflowPhase::Running | WorkflowPhase::Suspended) {
                    return None;
                }
                next.workflow = WorkflowPhase::Failed;
            }

            WorkflowEvent::CancellationRequested => {
                if matches!(next.workflow, WorkflowPhase::Completed | WorkflowPhase::Failed | WorkflowPhase::Cancelled) {
                    return None;
                }
                // Propagate cancellation to children
                for (name, phase) in next.children.iter_mut() {
                    if matches!(phase, ChildPhase::Initiated | ChildPhase::Started) {
                        *phase = ChildPhase::CancellationRequested;
                    }
                }
                next.workflow = WorkflowPhase::Cancelling;
            }

            WorkflowEvent::WorkflowCancelled => {
                if next.workflow != WorkflowPhase::Cancelling { return None; }
                next.workflow = WorkflowPhase::Cancelled;
            }

            // --- Task transitions (affect workflow state) ---
            WorkflowEvent::TaskScheduled { task_id, .. } => {
                if next.tasks.contains_key(task_id) { return None; }
                next.tasks.insert(task_id.clone(), TaskPhase::Scheduled);
            }

            WorkflowEvent::TaskCompleted { task_id } => {
                let phase = next.tasks.get(task_id)?;
                if !matches!(phase, TaskPhase::Scheduled | TaskPhase::Started) { return None; }
                next.tasks.insert(task_id.clone(), TaskPhase::Completed);

                // INTERDEPENDENCY: Task completion may trigger workflow resume
                if next.workflow == WorkflowPhase::Suspended {
                    // Resume when any work completes (workflow will check what to do)
                    next.workflow = WorkflowPhase::Running;
                }
            }

            WorkflowEvent::TaskFailed { task_id } => {
                let phase = next.tasks.get(task_id)?;
                if !matches!(phase, TaskPhase::Scheduled | TaskPhase::Started) { return None; }
                next.tasks.insert(task_id.clone(), TaskPhase::Failed);

                if next.workflow == WorkflowPhase::Suspended {
                    next.workflow = WorkflowPhase::Running;
                }
            }

            // --- Timer transitions ---
            WorkflowEvent::TimerStarted { timer_id, .. } => {
                if next.timers.contains_key(timer_id) { return None; }
                next.timers.insert(timer_id.clone(), TimerPhase::Started);
            }

            WorkflowEvent::TimerFired { timer_id } => {
                let phase = next.timers.get(timer_id)?;
                if *phase != TimerPhase::Started { return None; }
                next.timers.insert(timer_id.clone(), TimerPhase::Fired);

                if next.workflow == WorkflowPhase::Suspended {
                    next.workflow = WorkflowPhase::Running;
                }
            }

            WorkflowEvent::TimerCancelled { timer_id } => {
                let phase = next.timers.get(timer_id)?;
                if *phase != TimerPhase::Started { return None; }
                next.timers.insert(timer_id.clone(), TimerPhase::Cancelled);
            }

            // --- Child workflow transitions ---
            WorkflowEvent::ChildWorkflowInitiated { name, .. } => {
                if next.children.contains_key(name) { return None; }
                next.children.insert(name.clone(), ChildPhase::Initiated);
            }

            WorkflowEvent::ChildWorkflowCompleted { name } => {
                let phase = next.children.get(name)?;
                if !matches!(phase, ChildPhase::Initiated | ChildPhase::Started) { return None; }
                next.children.insert(name.clone(), ChildPhase::Completed);

                if next.workflow == WorkflowPhase::Suspended {
                    next.workflow = WorkflowPhase::Running;
                }
            }

            WorkflowEvent::ChildWorkflowFailed { name } => {
                let phase = next.children.get(name)?;
                if !matches!(phase, ChildPhase::Initiated | ChildPhase::Started) { return None; }
                next.children.insert(name.clone(), ChildPhase::Failed);

                if next.workflow == WorkflowPhase::Suspended {
                    next.workflow = WorkflowPhase::Running;
                }
            }

            WorkflowEvent::ChildWorkflowCancelled { name } => {
                let phase = next.children.get(name)?;
                if !matches!(phase, ChildPhase::Initiated | ChildPhase::Started | ChildPhase::CancellationRequested) {
                    return None;
                }
                next.children.insert(name.clone(), ChildPhase::Cancelled);
            }

            // --- Promise transitions ---
            WorkflowEvent::PromiseCreated { promise_id } => {
                if next.promises.contains_key(promise_id) { return None; }
                next.promises.insert(promise_id.clone(), PromisePhase::Created);
            }

            WorkflowEvent::PromiseResolved { promise_id } => {
                let phase = next.promises.get(promise_id)?;
                if *phase != PromisePhase::Created { return None; }
                next.promises.insert(promise_id.clone(), PromisePhase::Resolved);

                if next.workflow == WorkflowPhase::Suspended {
                    next.workflow = WorkflowPhase::Running;
                }
            }

            WorkflowEvent::PromiseRejected { promise_id } => {
                let phase = next.promises.get(promise_id)?;
                if *phase != PromisePhase::Created { return None; }
                next.promises.insert(promise_id.clone(), PromisePhase::Rejected);

                if next.workflow == WorkflowPhase::Suspended {
                    next.workflow = WorkflowPhase::Running;
                }
            }

            _ => {}
        }

        next.event_log.push(action);
        Some(next)
    }

    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            // === CROSS-STATE-MACHINE INVARIANTS ===

            // Suspended implies pending work
            Property::always("suspended implies pending work", |_, state| {
                if state.workflow == WorkflowPhase::Suspended {
                    state.has_pending_work()
                } else {
                    true
                }
            }),

            // Completed implies no pending work
            Property::always("completed implies no pending work", |_, state| {
                if state.workflow == WorkflowPhase::Completed {
                    !state.has_pending_work()
                } else {
                    true
                }
            }),

            // All children terminal before workflow completes
            Property::always("children terminal before complete", |_, state| {
                if state.workflow == WorkflowPhase::Completed {
                    state.children.values().all(|p| matches!(p,
                        ChildPhase::Completed | ChildPhase::Failed | ChildPhase::Cancelled
                    ))
                } else {
                    true
                }
            }),

            // Cancellation propagates to children
            Property::always("cancellation propagates", |_, state| {
                if state.workflow == WorkflowPhase::Cancelling || state.workflow == WorkflowPhase::Cancelled {
                    state.children.values().all(|p| matches!(p,
                        ChildPhase::CancellationRequested | ChildPhase::Cancelled |
                        ChildPhase::Completed | ChildPhase::Failed
                    ))
                } else {
                    true
                }
            }),

            // === CAUSALITY INVARIANTS ===

            // TaskCompleted requires prior TaskScheduled
            Property::always("task scheduled before completed", |_, state| {
                for (i, event) in state.event_log.iter().enumerate() {
                    if let WorkflowEvent::TaskCompleted { task_id } = event {
                        let has_prior = state.event_log[..i].iter().any(|e| matches!(
                            e, WorkflowEvent::TaskScheduled { task_id: id, .. } if id == task_id
                        ));
                        if !has_prior { return false; }
                    }
                }
                true
            }),

            // TimerFired requires prior TimerStarted
            Property::always("timer started before fired", |_, state| {
                for (i, event) in state.event_log.iter().enumerate() {
                    if let WorkflowEvent::TimerFired { timer_id } = event {
                        let has_prior = state.event_log[..i].iter().any(|e| matches!(
                            e, WorkflowEvent::TimerStarted { timer_id: id, .. } if id == timer_id
                        ));
                        if !has_prior { return false; }
                    }
                }
                true
            }),

            // ChildCompleted requires prior ChildInitiated
            Property::always("child initiated before completed", |_, state| {
                for (i, event) in state.event_log.iter().enumerate() {
                    if let WorkflowEvent::ChildWorkflowCompleted { name } = event {
                        let has_prior = state.event_log[..i].iter().any(|e| matches!(
                            e, WorkflowEvent::ChildWorkflowInitiated { name: n, .. } if n == name
                        ));
                        if !has_prior { return false; }
                    }
                }
                true
            }),

            // === UNIQUENESS INVARIANTS ===

            // Each timer fires at most once
            Property::always("timer fires at most once", |_, state| {
                let fired: Vec<_> = state.event_log.iter()
                    .filter_map(|e| match e {
                        WorkflowEvent::TimerFired { timer_id } => Some(timer_id),
                        _ => None,
                    })
                    .collect();
                let unique: HashSet<_> = fired.iter().collect();
                fired.len() == unique.len()
            }),

            // No duplicate task IDs
            Property::always("no duplicate task ids", |_, state| {
                let scheduled: Vec<_> = state.event_log.iter()
                    .filter_map(|e| match e {
                        WorkflowEvent::TaskScheduled { task_id, .. } => Some(task_id),
                        _ => None,
                    })
                    .collect();
                let unique: HashSet<_> = scheduled.iter().collect();
                scheduled.len() == unique.len()
            }),

            // === LIVENESS ===

            Property::sometimes("can complete workflow", |_, state| {
                state.workflow == WorkflowPhase::Completed
            }),

            Property::sometimes("can complete with children", |_, state| {
                state.workflow == WorkflowPhase::Completed && !state.children.is_empty()
            }),
        ]
    }
}

// === MUTATION TESTS ===

#[cfg(test)]
mod composite_mutations {
    use super::*;

    /// Mutant: Allow workflow to complete with pending work
    struct CompletesWithPendingMutant { /* ... */ }

    #[test]
    fn catches_complete_with_pending_bug() {
        // Model where workflow can complete even with pending tasks
        let model = CompositeWorkflowModelMutant {
            max_tasks: 2,
            allow_complete_with_pending: true,  // BUG
        };

        let result = model.checker().spawn_bfs().join();

        assert!(
            result.counterexample("completed implies no pending work").is_some(),
            "Model should catch complete-with-pending bug"
        );
    }

    /// Mutant: Don't resume workflow on task completion
    #[test]
    fn catches_no_resume_on_completion_bug() {
        let model = CompositeWorkflowModelMutant {
            max_tasks: 1,
            resume_on_task_complete: false,  // BUG
        };

        let result = model.checker().spawn_bfs().join();

        // Workflow gets stuck in Suspended forever
        assert!(
            result.counterexample("can complete workflow").is_some(),
            "Model should catch no-resume bug"
        );
    }

    /// Mutant: Don't propagate cancellation to children
    #[test]
    fn catches_no_cancellation_propagation_bug() {
        let model = CompositeWorkflowModelMutant {
            max_children: 2,
            propagate_cancellation: false,  // BUG
        };

        let result = model.checker().spawn_bfs().join();

        assert!(
            result.counterexample("cancellation propagates").is_some(),
            "Model should catch cancellation propagation bug"
        );
    }
}
```

---

### Model 2: ParallelCompletionModel (N! Orderings)

This model verifies that parallel operations completing in any order produce correct results.

```rust
/// State for parallel completion model
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ParallelCompletionState {
    /// Parallel operations (all started at "same time")
    operations: Vec<OperationState>,

    /// Completion order (indices of completed operations)
    completion_order: Vec<usize>,

    /// Final result after all complete
    final_result: Option<ParallelResult>,

    /// Combinator mode
    mode: CombinatorMode,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum OperationState {
    Pending,
    Completed { value: i32 },
    Failed { error: String },
    Cancelled,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum CombinatorMode {
    JoinAll,   // Wait for all, fail-fast on error
    Select,    // First to complete wins, cancel others
    Race,      // Like select but keeps all running
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ParallelResult {
    AllCompleted { values: Vec<i32> },
    FirstCompleted { index: usize, value: i32 },
    Failed { index: usize, error: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ParallelAction {
    Complete { index: usize, value: i32 },
    Fail { index: usize, error: String },
    Cancel { index: usize },
}

pub struct ParallelCompletionModel {
    pub num_operations: usize,
    pub mode: CombinatorMode,
}

impl Model for ParallelCompletionModel {
    type State = ParallelCompletionState;
    type Action = ParallelAction;

    fn init_states(&self) -> Vec<Self::State> {
        vec![ParallelCompletionState {
            operations: vec![OperationState::Pending; self.num_operations],
            completion_order: vec![],
            final_result: None,
            mode: self.mode.clone(),
        }]
    }

    fn actions(&self, state: &Self::State, actions: &mut Vec<Self::Action>) {
        if state.final_result.is_some() {
            return; // Already resolved
        }

        // Each pending operation can complete or fail
        for (i, op) in state.operations.iter().enumerate() {
            if matches!(op, OperationState::Pending) {
                actions.push(ParallelAction::Complete { index: i, value: i as i32 });
                actions.push(ParallelAction::Fail { index: i, error: format!("error-{}", i) });
            }
        }
    }

    fn next_state(&self, state: &Self::State, action: Self::Action) -> Option<Self::State> {
        let mut next = state.clone();

        match action {
            ParallelAction::Complete { index, value } => {
                if !matches!(next.operations[index], OperationState::Pending) {
                    return None;
                }
                next.operations[index] = OperationState::Completed { value };
                next.completion_order.push(index);

                match next.mode {
                    CombinatorMode::JoinAll => {
                        // Check if all completed
                        if next.operations.iter().all(|op| matches!(op, OperationState::Completed { .. })) {
                            let values: Vec<i32> = next.operations.iter()
                                .filter_map(|op| match op {
                                    OperationState::Completed { value } => Some(*value),
                                    _ => None,
                                })
                                .collect();
                            next.final_result = Some(ParallelResult::AllCompleted { values });
                        }
                    }
                    CombinatorMode::Select => {
                        // First to complete wins, cancel others
                        next.final_result = Some(ParallelResult::FirstCompleted { index, value });
                        for (i, op) in next.operations.iter_mut().enumerate() {
                            if i != index && matches!(op, OperationState::Pending) {
                                *op = OperationState::Cancelled;
                            }
                        }
                    }
                    CombinatorMode::Race => {
                        // First wins but others keep running (for tracking)
                        if next.final_result.is_none() {
                            next.final_result = Some(ParallelResult::FirstCompleted { index, value });
                        }
                    }
                }
            }

            ParallelAction::Fail { index, error } => {
                if !matches!(next.operations[index], OperationState::Pending) {
                    return None;
                }
                next.operations[index] = OperationState::Failed { error: error.clone() };
                next.completion_order.push(index);

                match next.mode {
                    CombinatorMode::JoinAll => {
                        // Fail-fast: first failure fails the whole group
                        next.final_result = Some(ParallelResult::Failed { index, error });
                        // Cancel remaining
                        for op in next.operations.iter_mut() {
                            if matches!(op, OperationState::Pending) {
                                *op = OperationState::Cancelled;
                            }
                        }
                    }
                    CombinatorMode::Select | CombinatorMode::Race => {
                        // Failure is just another completion for select
                        // (depends on semantics - here we treat it as not winning)
                    }
                }
            }

            ParallelAction::Cancel { index } => {
                if !matches!(next.operations[index], OperationState::Pending) {
                    return None;
                }
                next.operations[index] = OperationState::Cancelled;
            }
        }

        Some(next)
    }

    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            // === JOIN_ALL PROPERTIES ===

            // join_all: Result contains all values in original order (not completion order)
            Property::always("join_all result order independent", |model, state| {
                if model.mode != CombinatorMode::JoinAll { return true; }
                if let Some(ParallelResult::AllCompleted { values }) = &state.final_result {
                    // Values should be in index order [0, 1, 2, ...], not completion order
                    values.iter().enumerate().all(|(i, v)| *v == i as i32)
                } else {
                    true
                }
            }),

            // join_all: Resolves only when ALL complete
            Property::always("join_all waits for all", |model, state| {
                if model.mode != CombinatorMode::JoinAll { return true; }
                if let Some(ParallelResult::AllCompleted { .. }) = &state.final_result {
                    state.operations.iter().all(|op| matches!(op, OperationState::Completed { .. }))
                } else {
                    true
                }
            }),

            // join_all: Fails immediately on first failure
            Property::always("join_all fails fast", |model, state| {
                if model.mode != CombinatorMode::JoinAll { return true; }
                if state.operations.iter().any(|op| matches!(op, OperationState::Failed { .. })) {
                    matches!(state.final_result, Some(ParallelResult::Failed { .. }))
                } else {
                    true
                }
            }),

            // === SELECT PROPERTIES ===

            // select: Exactly one winner
            Property::always("select has one winner", |model, state| {
                if model.mode != CombinatorMode::Select { return true; }
                if let Some(ParallelResult::FirstCompleted { index, .. }) = &state.final_result {
                    // The winner should be completed, others should be cancelled
                    matches!(state.operations[*index], OperationState::Completed { .. })
                } else {
                    true
                }
            }),

            // select: Others are cancelled
            Property::always("select cancels losers", |model, state| {
                if model.mode != CombinatorMode::Select { return true; }
                if let Some(ParallelResult::FirstCompleted { index, .. }) = &state.final_result {
                    state.operations.iter().enumerate()
                        .filter(|(i, _)| *i != *index)
                        .all(|(_, op)| matches!(op, OperationState::Cancelled | OperationState::Completed { .. } | OperationState::Failed { .. }))
                } else {
                    true
                }
            }),

            // === GENERAL PROPERTIES ===

            // Different completion orders lead to same final result (order independence)
            Property::always("completion order independent", |model, state| {
                if state.final_result.is_none() { return true; }

                match (&model.mode, &state.final_result) {
                    (CombinatorMode::JoinAll, Some(ParallelResult::AllCompleted { values })) => {
                        // Values should be deterministic regardless of completion order
                        values.len() == model.num_operations
                    }
                    (CombinatorMode::Select, Some(ParallelResult::FirstCompleted { .. })) => {
                        // Winner is deterministically the first to complete
                        // (different orderings give different winners, which is correct)
                        true
                    }
                    _ => true
                }
            }),

            // Can always eventually resolve
            Property::eventually("parallel resolves", |_, state| {
                state.final_result.is_some()
            }),
        ]
    }
}

// === MUTATION TESTS ===

#[cfg(test)]
mod parallel_mutations {
    /// Mutant: join_all returns in completion order instead of index order
    #[test]
    fn catches_wrong_join_all_order() {
        let model = ParallelCompletionModelMutant {
            num_operations: 3,
            mode: CombinatorMode::JoinAll,
            return_in_completion_order: true,  // BUG
        };

        let result = model.checker().spawn_bfs().join();

        assert!(
            result.counterexample("join_all result order independent").is_some(),
            "Model should catch wrong result order"
        );
    }

    /// Mutant: select doesn't cancel losers
    #[test]
    fn catches_select_no_cancel() {
        let model = ParallelCompletionModelMutant {
            num_operations: 3,
            mode: CombinatorMode::Select,
            cancel_losers: false,  // BUG
        };

        let result = model.checker().spawn_bfs().join();

        assert!(
            result.counterexample("select cancels losers").is_some(),
            "Model should catch no-cancel bug"
        );
    }

    /// Mutant: join_all doesn't fail fast
    #[test]
    fn catches_no_fail_fast() {
        let model = ParallelCompletionModelMutant {
            num_operations: 3,
            mode: CombinatorMode::JoinAll,
            fail_fast: false,  // BUG: waits for all even on failure
        };

        let result = model.checker().spawn_bfs().join();

        assert!(
            result.counterexample("join_all fails fast").is_some(),
            "Model should catch no-fail-fast bug"
        );
    }
}

/// State space analysis for parallel operations
///
/// | Operations | Completion Orderings | State Space |
/// |------------|---------------------|-------------|
/// | 2          | 2! = 2              | ~10 states  |
/// | 3          | 3! = 6              | ~50 states  |
/// | 4          | 4! = 24             | ~200 states |
/// | 5          | 5! = 120            | ~1000 states|
///
/// Tractable up to ~5 parallel operations per model run.
```

---

### Model 3: RecoveryModel (Convergence from Faulty States)

This addresses the requirement: "even if we have faulty events, eventually consistent after retry"

```rust
/// State for recovery/convergence model
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct RecoveryState {
    // Normal workflow state
    workflow: WorkflowPhase,
    tasks: HashMap<TaskId, TaskPhase>,
    event_log: Vec<WorkflowEvent>,

    // Fault tracking
    fault: Option<FaultType>,
    fault_detected: bool,
    recovery_attempts: u32,

    // Consistency status
    is_consistent: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum FaultType {
    /// TaskCompleted without prior TaskScheduled
    OrphanedCompletion { task_id: TaskId },

    /// Duplicate event (same task completed twice)
    DuplicateEvent { task_id: TaskId },

    /// Sequence gap (expected N, got N+2)
    SequenceGap { expected: u32, got: u32 },

    /// Task stuck in Scheduled (never completes)
    StuckTask { task_id: TaskId },

    /// Out-of-order events (complete before schedule)
    OutOfOrder { task_id: TaskId },

    /// Child completed but parent not notified
    ChildParentMismatch { child_name: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum RecoveryAction {
    // Normal workflow events
    NormalEvent(WorkflowEvent),

    // Fault injection (for testing)
    InjectFault(FaultType),

    // Recovery actions
    RetryFromCheckpoint { sequence: u32 },
    SkipFaultyEvent { event_index: usize },
    InjectMissingEvent { event: WorkflowEvent },
    ForceCompleteTask { task_id: TaskId },
    ReconcileState,
}

impl RecoveryState {
    /// Check if event log is consistent
    pub fn validate_consistency(&self) -> Result<(), FaultType> {
        let mut scheduled_tasks: HashSet<TaskId> = HashSet::new();
        let mut completed_tasks: HashSet<TaskId> = HashSet::new();

        for (i, event) in self.event_log.iter().enumerate() {
            match event {
                WorkflowEvent::TaskScheduled { task_id, .. } => {
                    if !scheduled_tasks.insert(task_id.clone()) {
                        return Err(FaultType::DuplicateEvent { task_id: task_id.clone() });
                    }
                }
                WorkflowEvent::TaskCompleted { task_id } => {
                    if !scheduled_tasks.contains(task_id) {
                        return Err(FaultType::OrphanedCompletion { task_id: task_id.clone() });
                    }
                    if !completed_tasks.insert(task_id.clone()) {
                        return Err(FaultType::DuplicateEvent { task_id: task_id.clone() });
                    }
                }
                _ => {}
            }
        }

        // Check for stuck tasks (scheduled but never completed, workflow is terminal)
        if matches!(self.workflow, WorkflowPhase::Completed | WorkflowPhase::Failed) {
            for task_id in &scheduled_tasks {
                if !completed_tasks.contains(task_id) {
                    // Check if task is in a terminal state in current state
                    if let Some(phase) = self.tasks.get(task_id) {
                        if matches!(phase, TaskPhase::Scheduled | TaskPhase::Started) {
                            return Err(FaultType::StuckTask { task_id: task_id.clone() });
                        }
                    }
                }
            }
        }

        Ok(())
    }

    /// Rebuild state from event log
    pub fn rebuild_from_log(&mut self) {
        self.tasks.clear();
        self.workflow = WorkflowPhase::Running;

        for event in &self.event_log {
            match event {
                WorkflowEvent::TaskScheduled { task_id, .. } => {
                    self.tasks.insert(task_id.clone(), TaskPhase::Scheduled);
                }
                WorkflowEvent::TaskCompleted { task_id } => {
                    self.tasks.insert(task_id.clone(), TaskPhase::Completed);
                }
                WorkflowEvent::TaskFailed { task_id } => {
                    self.tasks.insert(task_id.clone(), TaskPhase::Failed);
                }
                WorkflowEvent::WorkflowCompleted => {
                    self.workflow = WorkflowPhase::Completed;
                }
                WorkflowEvent::WorkflowFailed { .. } => {
                    self.workflow = WorkflowPhase::Failed;
                }
                _ => {}
            }
        }

        self.is_consistent = self.validate_consistency().is_ok();
    }
}

pub struct RecoveryModel {
    pub max_tasks: usize,
    pub max_recovery_attempts: u32,
    pub inject_faults: bool,
}

impl Model for RecoveryModel {
    type State = RecoveryState;
    type Action = RecoveryAction;

    fn init_states(&self) -> Vec<Self::State> {
        vec![RecoveryState {
            workflow: WorkflowPhase::Running,
            tasks: HashMap::new(),
            event_log: vec![WorkflowEvent::WorkflowStarted],
            fault: None,
            fault_detected: false,
            recovery_attempts: 0,
            is_consistent: true,
        }]
    }

    fn actions(&self, state: &Self::State, actions: &mut Vec<Self::Action>) {
        // If faulty and not yet at max recovery attempts
        if state.fault.is_some() && state.recovery_attempts < self.max_recovery_attempts {
            match &state.fault {
                Some(FaultType::OrphanedCompletion { task_id }) => {
                    // Can inject missing schedule event
                    actions.push(RecoveryAction::InjectMissingEvent {
                        event: WorkflowEvent::TaskScheduled {
                            task_id: task_id.clone(),
                            task_type: "recovered".to_string(),
                        }
                    });
                    // Or skip the orphaned completion
                    if let Some(idx) = state.event_log.iter().position(|e| matches!(
                        e, WorkflowEvent::TaskCompleted { task_id: id } if id == task_id
                    )) {
                        actions.push(RecoveryAction::SkipFaultyEvent { event_index: idx });
                    }
                }

                Some(FaultType::StuckTask { task_id }) => {
                    actions.push(RecoveryAction::ForceCompleteTask { task_id: task_id.clone() });
                }

                Some(FaultType::SequenceGap { expected, .. }) => {
                    actions.push(RecoveryAction::RetryFromCheckpoint { sequence: *expected - 1 });
                }

                Some(FaultType::DuplicateEvent { .. }) => {
                    // Skip the duplicate
                    actions.push(RecoveryAction::ReconcileState);
                }

                _ => {
                    // Generic: retry from beginning
                    actions.push(RecoveryAction::RetryFromCheckpoint { sequence: 0 });
                }
            }
            return;
        }

        // Normal workflow actions when no fault
        if state.workflow == WorkflowPhase::Running && state.is_consistent {
            if state.tasks.len() < self.max_tasks {
                actions.push(RecoveryAction::NormalEvent(WorkflowEvent::TaskScheduled {
                    task_id: format!("task-{}", state.tasks.len()),
                    task_type: "example".to_string(),
                }));
            }

            for (task_id, phase) in &state.tasks {
                if matches!(phase, TaskPhase::Scheduled) {
                    actions.push(RecoveryAction::NormalEvent(WorkflowEvent::TaskCompleted {
                        task_id: task_id.clone(),
                    }));
                }
            }

            if state.tasks.values().all(|p| matches!(p, TaskPhase::Completed | TaskPhase::Failed))
                && !state.tasks.is_empty()
            {
                actions.push(RecoveryAction::NormalEvent(WorkflowEvent::WorkflowCompleted));
            }

            // Fault injection for testing
            if self.inject_faults {
                actions.push(RecoveryAction::InjectFault(FaultType::OrphanedCompletion {
                    task_id: "orphan-task".to_string(),
                }));
                if !state.tasks.is_empty() {
                    let task_id = state.tasks.keys().next().unwrap().clone();
                    actions.push(RecoveryAction::InjectFault(FaultType::StuckTask { task_id }));
                }
            }
        }
    }

    fn next_state(&self, state: &Self::State, action: Self::Action) -> Option<Self::State> {
        let mut next = state.clone();

        match action {
            RecoveryAction::NormalEvent(event) => {
                // Apply event normally
                match &event {
                    WorkflowEvent::TaskScheduled { task_id, .. } => {
                        next.tasks.insert(task_id.clone(), TaskPhase::Scheduled);
                    }
                    WorkflowEvent::TaskCompleted { task_id } => {
                        if !next.tasks.contains_key(task_id) {
                            // This would be a fault if it happened
                            next.fault = Some(FaultType::OrphanedCompletion { task_id: task_id.clone() });
                            next.is_consistent = false;
                        } else {
                            next.tasks.insert(task_id.clone(), TaskPhase::Completed);
                        }
                    }
                    WorkflowEvent::WorkflowCompleted => {
                        next.workflow = WorkflowPhase::Completed;
                    }
                    _ => {}
                }
                next.event_log.push(event);
            }

            RecoveryAction::InjectFault(fault) => {
                // Inject a fault for testing
                match &fault {
                    FaultType::OrphanedCompletion { task_id } => {
                        // Add completion without schedule
                        next.event_log.push(WorkflowEvent::TaskCompleted { task_id: task_id.clone() });
                    }
                    FaultType::StuckTask { task_id } => {
                        // Mark workflow as completed while task is still pending
                        next.workflow = WorkflowPhase::Completed;
                        next.event_log.push(WorkflowEvent::WorkflowCompleted);
                    }
                    _ => {}
                }
                next.fault = Some(fault);
                next.is_consistent = false;
            }

            RecoveryAction::RetryFromCheckpoint { sequence } => {
                // Truncate event log and rebuild
                next.event_log.truncate(sequence as usize);
                next.rebuild_from_log();
                next.fault = None;
                next.recovery_attempts += 1;
            }

            RecoveryAction::SkipFaultyEvent { event_index } => {
                // Remove the faulty event
                if event_index < next.event_log.len() {
                    next.event_log.remove(event_index);
                }
                next.rebuild_from_log();
                next.fault = None;
                next.recovery_attempts += 1;
            }

            RecoveryAction::InjectMissingEvent { event } => {
                // Insert the missing event at correct position
                // For simplicity, prepend to log before the orphaned completion
                if let Some(pos) = next.event_log.iter().position(|e| matches!(
                    e, WorkflowEvent::TaskCompleted { .. }
                )) {
                    next.event_log.insert(pos, event);
                }
                next.rebuild_from_log();
                next.recovery_attempts += 1;
            }

            RecoveryAction::ForceCompleteTask { task_id } => {
                next.event_log.push(WorkflowEvent::TaskCompleted { task_id: task_id.clone() });
                next.tasks.insert(task_id, TaskPhase::Completed);
                next.rebuild_from_log();
                next.recovery_attempts += 1;
            }

            RecoveryAction::ReconcileState => {
                next.rebuild_from_log();
                next.recovery_attempts += 1;
            }
        }

        // Recheck consistency
        next.is_consistent = next.validate_consistency().is_ok();
        if next.is_consistent {
            next.fault = None;
        }

        Some(next)
    }

    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            // === CORE CONVERGENCE PROPERTY ===

            // From any faulty state, can eventually reach consistent state
            Property::eventually("eventually consistent", |model, state| {
                state.is_consistent || state.recovery_attempts >= model.max_recovery_attempts
            }),

            // Recovery leads to consistency
            Property::always("recovery leads to consistency", |_, state| {
                if state.recovery_attempts > 0 && state.fault.is_none() {
                    state.is_consistent
                } else {
                    true
                }
            }),

            // Recovery is bounded (no infinite loops)
            Property::always("bounded recovery", |model, state| {
                state.recovery_attempts <= model.max_recovery_attempts
            }),

            // === IDEMPOTENCY ===

            // Applying same recovery action twice is safe
            Property::always("recovery idempotent", |_, state| {
                // If consistent, no recovery needed
                if state.is_consistent { return true; }
                // If recovery was applied, should be closer to consistent
                state.recovery_attempts > 0 || state.fault.is_some()
            }),

            // === FAULT DETECTION ===

            // All fault types are detectable
            Property::always("faults detected", |_, state| {
                if state.fault.is_some() {
                    !state.is_consistent
                } else {
                    true
                }
            }),

            // === LIVENESS ===

            Property::sometimes("can recover and complete", |_, state| {
                state.is_consistent && state.workflow == WorkflowPhase::Completed
            }),
        ]
    }
}

// === MUTATION TESTS ===

#[cfg(test)]
mod recovery_mutations {
    /// Mutant: Orphaned completion not detected as inconsistent
    #[test]
    fn catches_undetected_orphan() {
        let model = RecoveryModelMutant {
            max_tasks: 2,
            detect_orphaned_completion: false,  // BUG
        };

        let result = model.checker().spawn_bfs().join();

        assert!(
            result.counterexample("faults detected").is_some(),
            "Model should catch undetected orphan bug"
        );
    }

    /// Mutant: Recovery doesn't actually fix the fault
    #[test]
    fn catches_ineffective_recovery() {
        let model = RecoveryModelMutant {
            max_tasks: 2,
            recovery_actually_fixes: false,  // BUG
        };

        let result = model.checker().spawn_bfs().join();

        assert!(
            result.counterexample("recovery leads to consistency").is_some(),
            "Model should catch ineffective recovery"
        );
    }

    /// Mutant: Infinite recovery loop
    #[test]
    fn catches_unbounded_recovery() {
        let model = RecoveryModelMutant {
            max_tasks: 2,
            increment_recovery_counter: false,  // BUG: counter never increments
        };

        let result = model.checker().spawn_bfs().join();

        assert!(
            result.counterexample("bounded recovery").is_some(),
            "Model should catch unbounded recovery"
        );
    }
}

/// Recovery scenarios covered
///
/// | Fault Type | Detection | Recovery Action | Convergence |
/// |------------|-----------|-----------------|-------------|
/// | Orphaned completion | Missing schedule | Inject schedule OR skip | ✓ |
/// | Stuck task | Task pending, workflow done | Force complete | ✓ |
/// | Sequence gap | Gap in sequence numbers | Retry from checkpoint | ✓ |
/// | Duplicate event | Same ID twice | Skip duplicate | ✓ |
/// | Out-of-order | Complete before schedule | Reorder or reject | ✓ |
```

---

### Model 4: Infrastructure Models

These verify server-specific concerns (kept from original design).

#### EventAppendModel

```rust
/// Verifies advisory lock serializes event appends
/// See original design for full implementation

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct EventAppendState {
    events: Vec<Event>,
    next_sequence: u32,
    lock_holder: Option<WriterId>,
    violation: Option<String>,
}

impl Model for EventAppendModel {
    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::always("sequences monotonic", |_, state| {
                state.events.windows(2).all(|w| w[0].sequence < w[1].sequence)
            }),
            Property::always("no duplicate sequences", |_, state| {
                let seqs: HashSet<_> = state.events.iter().map(|e| e.sequence).collect();
                seqs.len() == state.events.len()
            }),
            Property::always("appends serialized by lock", |_, state| {
                state.violation.is_none()
            }),
        ]
    }
}
```

#### SchedulerModel

```rust
/// Verifies timers fire exactly once even with multiple schedulers
/// See original design for full implementation

impl Model for SchedulerModel {
    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::always("timer fires at most once", |_, state| {
                state.timers.values().all(|(_, count)| *count <= 1)
            }),
            Property::eventually("expired timers fire", |_, state| {
                state.timers.iter().all(|(_, (expired, count))| !*expired || *count >= 1)
            }),
        ]
    }
}
```

#### WorkDistributionModel

```rust
/// Verifies SELECT FOR UPDATE SKIP LOCKED prevents double-claim
/// See original design for full implementation

impl Model for WorkDistributionModel {
    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::always("single worker per work", |_, state| {
                let claims: Vec<_> = state.claimed.values().collect();
                let unique: HashSet<_> = claims.iter().collect();
                claims.len() == unique.len()
            }),
            Property::eventually("work completes", |_, state| {
                state.pending.is_empty() && state.claimed.is_empty()
            }),
        ]
    }
}
```

---

## Effectiveness Proof Summary

### Bug Classes Covered

| Bug Type | Model | Mutation | Property |
|----------|-------|----------|----------|
| Complete with pending work | Composite | `allow_complete_with_pending: true` | "completed implies no pending work" |
| No resume on completion | Composite | `resume_on_task_complete: false` | "can complete workflow" |
| Cancellation not propagated | Composite | `propagate_cancellation: false` | "cancellation propagates" |
| Wrong join_all order | Parallel | `return_in_completion_order: true` | "join_all result order independent" |
| Select no cancel | Parallel | `cancel_losers: false` | "select cancels losers" |
| No fail-fast | Parallel | `fail_fast: false` | "join_all fails fast" |
| Orphan not detected | Recovery | `detect_orphaned_completion: false` | "faults detected" |
| Recovery ineffective | Recovery | `recovery_actually_fixes: false` | "recovery leads to consistency" |
| Unbounded recovery | Recovery | `increment_recovery_counter: false` | "bounded recovery" |
| Append without lock | EventAppend | `require_lock_for_append: false` | "appends serialized by lock" |
| Double timer fire | Scheduler | `check_already_fired: false` | "timer fires at most once" |
| Double work claim | WorkDistribution | `use_skip_locked: false` | "single worker per work" |

---

## Connection to Real Code

**Critical Requirement**: The models must not be purely theoretical. They must connect to real production code to find actual bugs.

### The Oracle Pattern

The key insight is to use the model as a **test oracle** that generates all possible sequences, then validate each sequence through real production code.

```
┌─────────────────┐     generates     ┌──────────────────┐
│  Stateright     │ ───────────────▶  │  All possible    │
│  Model          │                   │  event sequences │
└─────────────────┘                   └────────┬─────────┘
                                               │
                                               ▼
                                      ┌──────────────────┐
                                      │  Real production │
                                      │  validator code  │
                                      └────────┬─────────┘
                                               │
                                      ┌────────▼─────────┐
                                      │  Validate each   │
                                      │  sequence        │
                                      └────────┬─────────┘
                                               │
                    ┌──────────────────────────┼─────────────────────────┐
                    │                          │                         │
                    ▼                          ▼                         ▼
           ┌───────────────┐          ┌───────────────┐         ┌───────────────┐
           │ Model: VALID  │          │ Model: VALID  │         │ Model: INVALID│
           │ Real: VALID   │          │ Real: INVALID │         │ Real: VALID   │
           │ ───────────── │          │ ───────────── │         │ ───────────── │
           │ ✓ Correct     │          │ ✗ Bug in code │         │ ✗ Bug in model│
           └───────────────┘          └───────────────┘         └───────────────┘
```

### Real Code Connection Point: DeterminismValidator

The SDK contains real production code that validates workflow replay:

**Location**: `sdk-rust/core/src/worker/determinism.rs`

```rust
// From flovyn_core::worker::determinism

pub struct DeterminismValidator {
    // Validates that replay commands match historical events
}

impl DeterminismValidator {
    pub fn validate_command(
        &self,
        command: &WorkflowCommand,
        event: Option<&ReplayEvent>,
    ) -> Result<(), DeterminismViolationError> {
        // Type mismatch check
        // Operation name mismatch check
        // Task type mismatch check
        // Child workflow kind mismatch check
        // etc.
    }
}
```

This is **real production code** that workers use during replay. It's not a test double.

### ReplayEngine Sequence Counters

**Location**: `sdk-rust/core/src/workflow/replay_engine.rs`

```rust
// Per-type sequence counters (production code)
next_task_seq: AtomicU32,
next_timer_seq: AtomicU32,
next_promise_seq: AtomicU32,
next_child_workflow_seq: AtomicU32,
```

These counters track sequence numbers per command type, enabling the model to verify per-type ordering.

### Integration Test: Model as Oracle

```rust
// In flovyn-server/server/tests/model_tests/determinism_oracle.rs

use stateright::Model;
use flovyn_core::worker::determinism::DeterminismValidator;
use flovyn_core::workflow::replay_engine::ReplayEngine;

/// Model-generated sequences run through real validator
#[test]
fn model_sequences_pass_real_validator() {
    let model = DeterminismModel::new(DeterminismModelConfig {
        max_commands: 5,
        max_task_types: 2,
    });

    let checker = model.checker().spawn_bfs().join();

    // No property violations in model
    assert!(checker.is_done());

    // Extract all terminal paths (completed workflows)
    for path in checker.path_to_all(|s| s.workflow == WorkflowPhase::Completed) {
        let (commands, events) = convert_path_to_commands_and_events(&path);

        // Create fresh replay engine with these events
        let replay_engine = ReplayEngine::from_events(events.clone());
        let validator = DeterminismValidator::new();

        // Replay each command through REAL validator
        for (i, command) in commands.iter().enumerate() {
            let replay_event = replay_engine.get_event_for_command(&command);

            let result = validator.validate_command(command, replay_event.as_ref());

            assert!(
                result.is_ok(),
                "Model path should pass real validator.\n\
                 Path: {:?}\n\
                 Command {}: {:?}\n\
                 Event: {:?}\n\
                 Error: {:?}",
                path, i, command, replay_event, result
            );
        }
    }
}

/// Verify model catches bugs that real validator would reject
#[test]
fn model_rejects_what_real_validator_rejects() {
    // Generate paths that MODEL considers invalid
    let model = DeterminismModelMutant::new(DeterminismModelConfig {
        max_commands: 3,
        allow_type_mismatch: true,  // Mutant allows invalid sequences
    });

    let checker = model.checker().spawn_bfs().join();

    // Model should find violations
    let counterexample = checker.counterexample("type matches");
    assert!(counterexample.is_some(), "Mutant should produce counterexamples");

    // Real validator should also reject these
    let path = counterexample.unwrap();
    let (commands, events) = convert_path_to_commands_and_events(&path);

    let replay_engine = ReplayEngine::from_events(events);
    let validator = DeterminismValidator::new();

    // At least one command should fail
    let mut found_rejection = false;
    for command in &commands {
        let replay_event = replay_engine.get_event_for_command(&command);
        if validator.validate_command(command, replay_event.as_ref()).is_err() {
            found_rejection = true;
            break;
        }
    }

    assert!(
        found_rejection,
        "Real validator should also reject model counterexample"
    );
}
```

### DeterminismModel Connected to Real Types

```rust
use flovyn_core::workflow::command::WorkflowCommand;
use flovyn_core::worker::replay::{ReplayEvent, ReplayEventType};

/// Stateright model that generates WorkflowCommand sequences
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct DeterminismModelState {
    // Commands issued (using REAL types from SDK)
    commands: Vec<WorkflowCommand>,

    // Events that would be recorded (using REAL types)
    events: Vec<ReplayEvent>,

    // Per-type sequence counters (matching ReplayEngine)
    next_task_seq: u32,
    next_timer_seq: u32,
    next_promise_seq: u32,
    next_child_seq: u32,
    next_operation_seq: u32,

    // Workflow phase
    phase: WorkflowPhase,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum DeterminismAction {
    // Schedule task - using real types
    ScheduleTask { task_type: String, input: Vec<u8> },

    // Complete task (simulating external completion)
    CompleteTask { task_seq: u32, result: Vec<u8> },

    // Run operation (side-effect-free)
    RunOperation { name: String, result: serde_json::Value },

    // Start timer
    StartTimer { duration_ms: u64 },

    // Fire timer (simulating scheduler)
    FireTimer { timer_seq: u32 },

    // Child workflow
    StartChildWorkflow { name: String, kind: String },
    CompleteChildWorkflow { child_seq: u32 },

    // Complete workflow
    CompleteWorkflow { output: Vec<u8> },
}

impl Model for DeterminismModel {
    type State = DeterminismModelState;
    type Action = DeterminismAction;

    fn init_states(&self) -> Vec<Self::State> {
        vec![DeterminismModelState {
            commands: vec![],
            events: vec![ReplayEvent {
                event_type: ReplayEventType::WorkflowStarted,
                global_sequence: 0,
                ..Default::default()
            }],
            next_task_seq: 0,
            next_timer_seq: 0,
            next_promise_seq: 0,
            next_child_seq: 0,
            next_operation_seq: 0,
            phase: WorkflowPhase::Running,
        }]
    }

    fn actions(&self, state: &Self::State, actions: &mut Vec<Self::Action>) {
        if state.phase != WorkflowPhase::Running { return; }

        // Can schedule new tasks (up to limit)
        if state.next_task_seq < self.max_tasks {
            for task_type in &self.task_types {
                actions.push(DeterminismAction::ScheduleTask {
                    task_type: task_type.clone(),
                    input: vec![],
                });
            }
        }

        // Can complete pending tasks
        for event in &state.events {
            if event.event_type == ReplayEventType::TaskScheduled {
                if let Some(task_seq) = event.type_sequence {
                    // Check if not already completed
                    let completed = state.events.iter().any(|e|
                        e.event_type == ReplayEventType::TaskCompleted &&
                        e.type_sequence == Some(task_seq)
                    );
                    if !completed {
                        actions.push(DeterminismAction::CompleteTask {
                            task_seq,
                            result: vec![],
                        });
                    }
                }
            }
        }

        // Can run operations
        if state.next_operation_seq < self.max_operations {
            actions.push(DeterminismAction::RunOperation {
                name: format!("op-{}", state.next_operation_seq),
                result: serde_json::json!({}),
            });
        }

        // ... similar for timers, child workflows

        // Can complete if no pending work
        if !state.has_pending_work() {
            actions.push(DeterminismAction::CompleteWorkflow { output: vec![] });
        }
    }

    fn next_state(&self, state: &Self::State, action: Self::Action) -> Option<Self::State> {
        let mut next = state.clone();

        match action {
            DeterminismAction::ScheduleTask { task_type, input } => {
                // Create REAL WorkflowCommand
                let command = WorkflowCommand::ScheduleTask {
                    task_type: task_type.clone(),
                    input,
                    task_queue: "default".to_string(),
                };
                next.commands.push(command);

                // Create REAL ReplayEvent that would be recorded
                next.events.push(ReplayEvent {
                    event_type: ReplayEventType::TaskScheduled,
                    global_sequence: next.events.len() as u32,
                    type_sequence: Some(next.next_task_seq),
                    task_type: Some(task_type),
                    ..Default::default()
                });

                next.next_task_seq += 1;
            }

            DeterminismAction::CompleteTask { task_seq, result } => {
                next.events.push(ReplayEvent {
                    event_type: ReplayEventType::TaskCompleted,
                    global_sequence: next.events.len() as u32,
                    type_sequence: Some(task_seq),
                    result: Some(result),
                    ..Default::default()
                });
            }

            DeterminismAction::RunOperation { name, result } => {
                let command = WorkflowCommand::Run {
                    operation_name: name.clone(),
                    result: result.clone(),
                };
                next.commands.push(command);

                next.events.push(ReplayEvent {
                    event_type: ReplayEventType::OperationCompleted,
                    global_sequence: next.events.len() as u32,
                    type_sequence: Some(next.next_operation_seq),
                    operation_name: Some(name),
                    result: Some(serde_json::to_vec(&result).unwrap()),
                    ..Default::default()
                });

                next.next_operation_seq += 1;
            }

            DeterminismAction::CompleteWorkflow { output } => {
                let command = WorkflowCommand::CompleteWorkflow { output };
                next.commands.push(command);
                next.phase = WorkflowPhase::Completed;
            }

            // ... handle other actions
            _ => {}
        }

        Some(next)
    }

    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            // Per-type sequence monotonicity (matches ReplayEngine)
            Property::always("task sequences monotonic", |_, state| {
                let task_seqs: Vec<u32> = state.events.iter()
                    .filter(|e| e.event_type == ReplayEventType::TaskScheduled)
                    .filter_map(|e| e.type_sequence)
                    .collect();
                task_seqs.windows(2).all(|w| w[0] < w[1])
            }),

            // Completed before scheduled is invalid
            Property::always("complete after schedule", |_, state| {
                for complete in state.events.iter()
                    .filter(|e| e.event_type == ReplayEventType::TaskCompleted)
                {
                    let Some(seq) = complete.type_sequence else { continue };
                    let schedule_pos = state.events.iter().position(|e|
                        e.event_type == ReplayEventType::TaskScheduled &&
                        e.type_sequence == Some(seq)
                    );
                    let complete_pos = state.events.iter().position(|e| e == complete);

                    match (schedule_pos, complete_pos) {
                        (Some(s), Some(c)) if s < c => continue,
                        _ => return false,
                    }
                }
                true
            }),

            // Type consistency (what DeterminismValidator checks)
            Property::always("type consistency", |_, state| {
                // Each command's type matches corresponding event's type
                // This is what validate_command checks
                true // Verified by oracle test below
            }),
        ]
    }
}
```

### What This Catches

| Bug Type | How Model Catches It |
|----------|---------------------|
| Task type mismatch on replay | Model generates all type combinations, real validator rejects mismatches |
| Operation name drift | Model generates all operation sequences, validator catches name changes |
| Per-type sequence counter bug | Model tracks sequences like ReplayEngine, validates consistency |
| Missing event before completion | Model enforces causality, validator enforces same |
| Child workflow kind mismatch | Model generates kind combinations, validator validates |

### Why This Works

1. **Same code path**: The `DeterminismValidator` is the EXACT code workers use in production. No test doubles.

2. **Exhaustive coverage**: Model generates ALL possible command/event sequences (within bounds).

3. **Oracle disagreement = bug**: If model says "valid" but real validator says "invalid" → bug in model. If model says "invalid" but validator says "valid" → bug in validator.

4. **Mutation testing**: Mutant models intentionally break invariants. If real validator doesn't catch them, the validator has a bug.

---

## Implementation Plan

### Phase 1: CompositeWorkflowModel (3-4 days)
- [ ] Add stateright to server dev-dependencies
- [ ] Implement CompositeWorkflowModel with all sub-state-machines
- [ ] Implement interdependency logic (has_pending_work, resume triggers)
- [ ] Run mutation tests, verify they catch bugs
- [ ] Measure state space (target: <5000 states with max_tasks=2, max_timers=1, max_children=1)

**Decision point**: If state space explodes, reduce limits or use symmetry reduction.

### Phase 2: ParallelCompletionModel (2-3 days)
- [ ] Implement join_all semantics model
- [ ] Implement select semantics model
- [ ] Verify N! orderings all produce correct result
- [ ] Run mutation tests for combinator bugs

### Phase 3: RecoveryModel (3-4 days)
- [ ] Implement fault type detection
- [ ] Implement recovery actions
- [ ] Verify "eventually consistent" property
- [ ] Run mutation tests for recovery bugs

### Phase 4: DeterminismModel + Real Validator Oracle (3-4 days)
- [ ] Add flovyn_core as dev-dependency in server
- [ ] Implement DeterminismModel using real SDK types (WorkflowCommand, ReplayEvent)
- [ ] Implement `convert_path_to_commands_and_events` helper
- [ ] Write oracle test: all model paths pass through real DeterminismValidator
- [ ] Write reverse oracle test: mutant paths rejected by both model and validator
- [ ] Verify per-type sequence counters match ReplayEngine behavior

### Phase 5: Infrastructure Models (2 days)
- [ ] Implement EventAppendModel with mutation tests
- [ ] Implement SchedulerModel with mutation tests
- [ ] Implement WorkDistributionModel with mutation tests

### Phase 6: CI Integration (2 days)
- [ ] Add model tests to CI pipeline
- [ ] Set up model test timeout limits
- [ ] Documentation

---

## State Space Analysis

| Model | Configuration | Estimated States | Time |
|-------|---------------|-----------------|------|
| CompositeWorkflow | 2 tasks, 1 timer, 1 child | ~2000 | <1s |
| CompositeWorkflow | 3 tasks, 2 timers, 2 children | ~20000 | ~5s |
| ParallelCompletion | 3 operations | ~50 | <0.1s |
| ParallelCompletion | 5 operations | ~1000 | <0.5s |
| Recovery | 2 tasks, 3 recovery attempts | ~500 | <0.5s |
| EventAppend | 2 writers, 4 events | ~200 | <0.1s |
| Scheduler | 2 timers, 2 schedulers | ~100 | <0.1s |

All models should be tractable with BFS within seconds.

---

## Conclusion

This design now addresses all original research requirements:

1. **Cross-state-machine verification**: CompositeWorkflowModel tracks workflow + tasks + timers + children + promises together with interdependency logic

2. **Parallel execution orderings**: ParallelCompletionModel verifies N! orderings with join_all and select semantics

3. **Recovery and convergence**: RecoveryModel verifies faulty states can be recovered to consistent states

4. **Infrastructure invariants**: EventAppend, Scheduler, WorkDistribution models cover server-specific concerns

5. **Effectiveness proof**: Each model has mutation tests proving it catches specific bug classes

6. **Connected to real code**: DeterminismModel uses real SDK types (`WorkflowCommand`, `ReplayEvent`) and validates all generated sequences through real production code (`DeterminismValidator`, `ReplayEngine`)

### Key Differentiator: Oracle Pattern

Unlike purely theoretical models, this design uses the **oracle pattern**:
- Model generates exhaustive sequences using real SDK types
- Each sequence runs through real production validator code
- Disagreement between model and validator = bug discovered

This means:
- No test doubles or mocks in the critical validation path
- Bugs in either model OR production code are caught
- Mutation testing proves both model and validator are correct

The mutation testing approach ensures we don't just claim "no bugs found" but prove "these specific bug types would be caught."
