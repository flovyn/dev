# Stateright Model Checking for Flovyn

## Overview

[Stateright](https://github.com/stateright/stateright) is a Rust actor library for building and formally verifying distributed systems. Unlike TLA+ where models must be reimplemented in a different language for production, stateright allows the same Rust code to run both in the model checker and on a real network.

### Key Features

- **Model Checking**: Exhaustive state space exploration with BFS/DFS
- **Property Verification**: Invariants (always), nontriviality (sometimes), liveness (eventually)
- **Interactive Explorer**: Web UI for visualizing system behavior
- **Actor Runtime**: Same code runs in model checker and production
- **Symmetry Reduction**: State space optimization

## Potential Applications to Flovyn

### 1. Workflow State Machine Verification

**Target**: `flovyn-server/server/src/domain/workflow.rs`

The workflow execution follows a well-defined state machine:

```
PENDING → RUNNING → WAITING → COMPLETED
                 ↓         ↓
              FAILED    CANCELLED
                         ↓
                     CANCELLING
```

**Model Checking Opportunities**:

```rust
use stateright::Model;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum WorkflowState {
    Pending,
    Running { worker_id: WorkerId },
    Waiting,
    Completed,
    Failed,
    Cancelled,
    Cancelling,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum WorkflowAction {
    WorkerClaim { worker_id: WorkerId },
    Suspend,
    Resume,
    Complete,
    Fail,
    RequestCancel,
    ChildCompleted,
}

impl Model for WorkflowStateMachine {
    type State = WorkflowState;
    type Action = WorkflowAction;

    fn init_states(&self) -> Vec<Self::State> {
        vec![WorkflowState::Pending]
    }

    fn actions(&self, state: &Self::State, actions: &mut Vec<Self::Action>) {
        match state {
            WorkflowState::Pending => {
                actions.push(WorkflowAction::WorkerClaim { worker_id: 0 });
            }
            WorkflowState::Running { .. } => {
                actions.push(WorkflowAction::Suspend);
                actions.push(WorkflowAction::Complete);
                actions.push(WorkflowAction::Fail);
                actions.push(WorkflowAction::RequestCancel);
            }
            // ...
        }
    }

    fn next_state(&self, state: &Self::State, action: Self::Action) -> Option<Self::State> {
        // State transition logic
    }

    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::always("terminal states are absorbing", |_, state| {
                !matches!(state, WorkflowState::Completed | WorkflowState::Failed | WorkflowState::Cancelled)
            }),
            Property::sometimes("can reach completed", |_, state| {
                matches!(state, WorkflowState::Completed)
            }),
        ]
    }
}
```

**Invariants to Verify**:
- Terminal states (Completed, Failed, Cancelled) are absorbing
- Only PENDING workflows transition to RUNNING
- Only RUNNING workflows transition to WAITING
- Cancellation propagates correctly through CANCELLING state

### 2. Event Sourcing Consistency

**Target**: `flovyn-server/server/src/repository/event_repository.rs`

The event sourcing system uses advisory locks and sequence numbers to ensure consistency.

**Model Checking Opportunities**:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct EventLog {
    events: Vec<Event>,
    next_sequence: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum EventAction {
    AppendEvent { writer_id: WriterId, event_type: EventType },
    ConcurrentAppend { writer_id: WriterId, event_type: EventType },
}

impl Model for EventSourcingModel {
    // ...

    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::always("sequence numbers strictly increasing", |_, state| {
                state.events.windows(2).all(|w| w[0].sequence < w[1].sequence)
            }),
            Property::always("no duplicate sequences", |_, state| {
                let sequences: HashSet<_> = state.events.iter().map(|e| e.sequence).collect();
                sequences.len() == state.events.len()
            }),
            Property::always("advisory lock prevents conflicts", |_, state| {
                // Verify concurrent writers cannot produce conflicting sequences
            }),
        ]
    }
}
```

**Invariants to Verify**:
- Sequence numbers are strictly monotonic
- No duplicate sequence numbers per workflow
- Advisory locks serialize concurrent appends
- Replay produces identical state

### 3. Work Distribution and Single-Writer Invariant

**Target**: `flovyn-server/server/src/repository/workflow_repository.rs`, `task_repository.rs`

The `SELECT FOR UPDATE SKIP LOCKED` pattern ensures only one worker executes a workflow/task.

**Model Checking Opportunities**:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct WorkDistributionState {
    pending_work: Vec<WorkId>,
    running_work: HashMap<WorkId, WorkerId>,
    workers: Vec<WorkerId>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum WorkAction {
    WorkerPoll { worker_id: WorkerId },
    WorkerComplete { worker_id: WorkerId, work_id: WorkId },
    WorkerFail { worker_id: WorkerId },
    NewWorkArrives,
}
```

**Invariants to Verify**:
- **Single-writer**: At most one worker executes any given workflow/task
- **No starvation**: Pending work eventually gets picked up
- **Fair distribution**: Work distributed reasonably among workers
- **Lost worker recovery**: Work reassigned when worker fails

### 4. Child Workflow Coordination

**Target**: `flovyn-server/server/src/scheduler.rs`, child workflow handling

Parent-child workflow relationships require careful coordination:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct ParentChildState {
    parent_state: WorkflowState,
    children: Vec<ChildState>,
    parent_waiting_for: HashSet<ChildId>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum ChildState {
    Running,
    Completed { result: Value },
    Failed { error: String },
    Cancelling,
    Cancelled,
}
```

**Invariants to Verify**:
- Parent notified exactly once per child completion
- Cancellation propagates to all children
- Parent cannot complete while children are running
- No orphaned children after parent completes

### 5. Timer Firing Semantics

**Target**: `flovyn-server/server/src/scheduler.rs`, timer handling

Timers must fire exactly once after expiration:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct TimerState {
    timers: Vec<Timer>,
    fired_events: HashSet<TimerId>,
    current_time: u64,
}

impl Model for TimerModel {
    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::always("timers fire exactly once", |_, state| {
                // No duplicate TIMER_FIRED events
            }),
            Property::eventually("expired timers eventually fire", |_, state| {
                state.timers.iter().all(|t| {
                    t.fire_at > state.current_time || state.fired_events.contains(&t.id)
                })
            }),
        ]
    }
}
```

**Invariants to Verify**:
- Expired timers fire exactly once
- Timer cancellation prevents firing
- Timers fire in approximately correct order
- No timers lost during scheduler restarts

### 6. SDK Determinism Validation

**Target**: `sdk-rust/core/src/workflow/replay_engine.rs`, `recorder.rs`

The SDK must ensure workflow execution is deterministic across replays:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum ReplayState {
    Fresh,
    Replaying { position: usize, events: Vec<Event> },
    Extended,
    Violated { reason: ViolationType },
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum ViolationType {
    TypeMismatch,
    OperationNameMismatch,
    TaskTypeMismatch,
    SequenceGap,
}
```

**Invariants to Verify**:
- Same input produces same command sequence
- Violations detected before causing inconsistency
- Per-type sequence counters are monotonic
- State lookups are O(1) via pre-filtered lists

### 7. Worker Lifecycle and Heartbeats

**Target**: `sdk-rust/sdk/src/worker/workflow_worker.rs`

Worker coordination involves multiple concurrent loops:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct WorkerState {
    registration: RegistrationState,
    heartbeat: HeartbeatState,
    polling: PollingState,
    notifications: NotificationState,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum RegistrationState {
    Unregistered,
    Registering,
    Registered { worker_id: WorkerId },
    Failed { retries: u32 },
}
```

**Invariants to Verify**:
- Heartbeats only sent when registered
- Registration retried on failure
- Polling waits for registration
- Graceful shutdown coordination

## Cross-State-Machine Event History Verification

A key challenge in Flovyn is that a single workflow's event log contains interleaved events from multiple sub-state-machines:

```
WorkflowStarted(seq=1)
  └─ TaskScheduled(seq=2, task="send-email")
  └─ TimerStarted(seq=3, id="timeout-1")
  └─ ChildWorkflowInitiated(seq=4, name="payment")
  └─ TaskCompleted(seq=5, task="send-email")
  └─ TimerFired(seq=6, id="timeout-1")
  └─ ChildWorkflowCompleted(seq=7, name="payment")
WorkflowCompleted(seq=8)
```

Each event type follows its own lifecycle rules, but they're all part of one unified event stream. The challenge is verifying that **any valid event history is consistent across all sub-state-machines**.

### Composite State Machine Approach

Model the entire workflow state as a product of sub-states:

```rust
use stateright::Model;
use std::collections::HashMap;

type TaskId = String;
type TimerId = String;
type ChildName = String;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct CompositeWorkflowState {
    // Top-level workflow state
    workflow: WorkflowPhase,

    // Sub-state-machines (indexed by their identifier)
    tasks: HashMap<TaskId, TaskPhase>,
    timers: HashMap<TimerId, TimerPhase>,
    children: HashMap<ChildName, ChildPhase>,
    promises: HashMap<String, PromisePhase>,

    // Event log for verification
    event_log: Vec<EventType>,
    next_sequence: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum WorkflowPhase { Started, Suspended, Completed, Failed, Cancelled }

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum TaskPhase { Scheduled, Started, Completed, Failed, Cancelled }

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum TimerPhase { Started, Fired, Cancelled }

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum ChildPhase { Initiated, Started, Completed, Failed, CancellationRequested, Cancelled }

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum PromisePhase { Created, Resolved, Rejected }
```

### Event Type as Actions

Each event type becomes an action in the model:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum WorkflowEvent {
    // Workflow lifecycle
    WorkflowStarted,
    WorkflowCompleted,
    WorkflowFailed { error: String },
    WorkflowSuspended,
    WorkflowResumed,
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

    // Promise lifecycle
    PromiseCreated { promise_id: String },
    PromiseResolved { promise_id: String },
    PromiseRejected { promise_id: String },
}
```

### Model Implementation

```rust
struct CompositeWorkflowModel {
    max_tasks: usize,
    max_timers: usize,
    max_children: usize,
}

impl Model for CompositeWorkflowModel {
    type State = CompositeWorkflowState;
    type Action = WorkflowEvent;

    fn init_states(&self) -> Vec<Self::State> {
        vec![CompositeWorkflowState {
            workflow: WorkflowPhase::Started,
            tasks: HashMap::new(),
            timers: HashMap::new(),
            children: HashMap::new(),
            promises: HashMap::new(),
            event_log: vec![EventType::WorkflowStarted],
            next_sequence: 1,
        }]
    }

    fn actions(&self, state: &Self::State, actions: &mut Vec<Self::Action>) {
        // Only generate valid actions based on current composite state

        match &state.workflow {
            WorkflowPhase::Started => {
                // Can schedule new tasks (up to limit)
                if state.tasks.len() < self.max_tasks {
                    actions.push(WorkflowEvent::TaskScheduled {
                        task_id: format!("task-{}", state.tasks.len()),
                        task_type: "example".to_string(),
                    });
                }

                // Can start timers
                if state.timers.len() < self.max_timers {
                    actions.push(WorkflowEvent::TimerStarted {
                        timer_id: format!("timer-{}", state.timers.len()),
                        duration_ms: 1000,
                    });
                }

                // Can initiate child workflows
                if state.children.len() < self.max_children {
                    actions.push(WorkflowEvent::ChildWorkflowInitiated {
                        name: format!("child-{}", state.children.len()),
                        kind: "child-workflow".to_string(),
                    });
                }

                // Can complete if all pending work is done
                if state.all_work_complete() {
                    actions.push(WorkflowEvent::WorkflowCompleted);
                }

                // Can always fail or suspend
                actions.push(WorkflowEvent::WorkflowFailed {
                    error: "error".to_string()
                });
                actions.push(WorkflowEvent::WorkflowSuspended);
            }
            WorkflowPhase::Suspended => {
                // External events can complete pending work
                for (task_id, phase) in &state.tasks {
                    if *phase == TaskPhase::Scheduled || *phase == TaskPhase::Started {
                        actions.push(WorkflowEvent::TaskCompleted {
                            task_id: task_id.clone()
                        });
                        actions.push(WorkflowEvent::TaskFailed {
                            task_id: task_id.clone()
                        });
                    }
                }

                for (timer_id, phase) in &state.timers {
                    if *phase == TimerPhase::Started {
                        actions.push(WorkflowEvent::TimerFired {
                            timer_id: timer_id.clone()
                        });
                    }
                }

                for (name, phase) in &state.children {
                    if *phase == ChildPhase::Initiated || *phase == ChildPhase::Started {
                        actions.push(WorkflowEvent::ChildWorkflowCompleted {
                            name: name.clone()
                        });
                        actions.push(WorkflowEvent::ChildWorkflowFailed {
                            name: name.clone()
                        });
                    }
                }

                // Resume when work completes
                actions.push(WorkflowEvent::WorkflowResumed);
            }
            _ => {} // Terminal states have no actions
        }
    }

    fn next_state(&self, state: &Self::State, action: Self::Action)
        -> Option<Self::State>
    {
        let mut next = state.clone();
        next.next_sequence += 1;

        match action {
            WorkflowEvent::TaskScheduled { ref task_id, .. } => {
                next.tasks.insert(task_id.clone(), TaskPhase::Scheduled);
            }
            WorkflowEvent::TaskCompleted { ref task_id } => {
                // Only valid if task exists and is in Scheduled or Started
                let phase = next.tasks.get(task_id)?;
                if !matches!(phase, TaskPhase::Scheduled | TaskPhase::Started) {
                    return None; // Invalid transition
                }
                next.tasks.insert(task_id.clone(), TaskPhase::Completed);
            }
            WorkflowEvent::TimerStarted { ref timer_id, .. } => {
                next.timers.insert(timer_id.clone(), TimerPhase::Started);
            }
            WorkflowEvent::TimerFired { ref timer_id } => {
                let phase = next.timers.get(timer_id)?;
                if *phase != TimerPhase::Started {
                    return None;
                }
                next.timers.insert(timer_id.clone(), TimerPhase::Fired);
            }
            WorkflowEvent::ChildWorkflowInitiated { ref name, .. } => {
                next.children.insert(name.clone(), ChildPhase::Initiated);
            }
            WorkflowEvent::ChildWorkflowCompleted { ref name } => {
                let phase = next.children.get(name)?;
                if !matches!(phase, ChildPhase::Initiated | ChildPhase::Started) {
                    return None;
                }
                next.children.insert(name.clone(), ChildPhase::Completed);
            }
            WorkflowEvent::WorkflowCompleted => {
                next.workflow = WorkflowPhase::Completed;
            }
            WorkflowEvent::WorkflowSuspended => {
                next.workflow = WorkflowPhase::Suspended;
            }
            WorkflowEvent::WorkflowResumed => {
                next.workflow = WorkflowPhase::Started;
            }
            // ... handle other events
            _ => {}
        }

        next.event_log.push(action.to_event_type());
        Some(next)
    }

    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            // Cross-state-machine invariants
            Property::always("task lifecycle valid", |_, state| {
                state.tasks.values().all(|phase| {
                    // Tasks can only be in valid phases
                    matches!(phase,
                        TaskPhase::Scheduled |
                        TaskPhase::Started |
                        TaskPhase::Completed |
                        TaskPhase::Failed |
                        TaskPhase::Cancelled
                    )
                })
            }),

            Property::always("no orphaned completions", |_, state| {
                // Every TaskCompleted event must have a prior TaskScheduled
                let scheduled: HashSet<_> = state.event_log.iter()
                    .filter_map(|e| match e {
                        EventType::TaskScheduled { task_id, .. } => Some(task_id),
                        _ => None,
                    })
                    .collect();

                state.event_log.iter()
                    .filter_map(|e| match e {
                        EventType::TaskCompleted { task_id } => Some(task_id),
                        _ => None,
                    })
                    .all(|id| scheduled.contains(id))
            }),

            Property::always("workflow cannot complete with pending children", |_, state| {
                if state.workflow == WorkflowPhase::Completed {
                    state.children.values().all(|phase| {
                        matches!(phase, ChildPhase::Completed | ChildPhase::Failed | ChildPhase::Cancelled)
                    })
                } else {
                    true
                }
            }),

            Property::always("timer fires at most once", |_, state| {
                let fired: Vec<_> = state.event_log.iter()
                    .filter_map(|e| match e {
                        EventType::TimerFired { timer_id } => Some(timer_id),
                        _ => None,
                    })
                    .collect();
                let unique: HashSet<_> = fired.iter().collect();
                fired.len() == unique.len()
            }),

            Property::always("sequence numbers monotonic", |_, state| {
                state.event_log.windows(2).enumerate().all(|(i, _)| {
                    // Sequence i+1 > sequence i (implicit from vector ordering)
                    true
                })
            }),

            Property::sometimes("can complete workflow", |_, state| {
                state.workflow == WorkflowPhase::Completed
            }),

            Property::sometimes("can complete with children", |_, state| {
                state.workflow == WorkflowPhase::Completed &&
                !state.children.is_empty()
            }),
        ]
    }
}
```

### Event History Validator

Beyond the model checker, we can build a **validator** that checks any given event history:

```rust
/// Validates that an event history is consistent across all sub-state-machines
pub struct EventHistoryValidator {
    tasks: HashMap<TaskId, TaskPhase>,
    timers: HashMap<TimerId, TimerPhase>,
    children: HashMap<ChildName, ChildPhase>,
    promises: HashMap<String, PromisePhase>,
    workflow: WorkflowPhase,
}

impl EventHistoryValidator {
    pub fn new() -> Self {
        Self {
            tasks: HashMap::new(),
            timers: HashMap::new(),
            children: HashMap::new(),
            promises: HashMap::new(),
            workflow: WorkflowPhase::Started,
        }
    }

    /// Apply an event and check if it's valid given current state
    pub fn apply(&mut self, event: &WorkflowEvent) -> Result<(), ValidationError> {
        match event {
            WorkflowEvent::TaskScheduled { task_id, .. } => {
                if self.tasks.contains_key(task_id) {
                    return Err(ValidationError::DuplicateTaskId(task_id.clone()));
                }
                self.tasks.insert(task_id.clone(), TaskPhase::Scheduled);
            }
            WorkflowEvent::TaskCompleted { task_id } => {
                match self.tasks.get(task_id) {
                    Some(TaskPhase::Scheduled) | Some(TaskPhase::Started) => {
                        self.tasks.insert(task_id.clone(), TaskPhase::Completed);
                    }
                    Some(phase) => {
                        return Err(ValidationError::InvalidTaskTransition {
                            task_id: task_id.clone(),
                            from: phase.clone(),
                            to: TaskPhase::Completed,
                        });
                    }
                    None => {
                        return Err(ValidationError::TaskNotFound(task_id.clone()));
                    }
                }
            }
            WorkflowEvent::ChildWorkflowCompleted { name } => {
                match self.children.get(name) {
                    Some(ChildPhase::Initiated) | Some(ChildPhase::Started) => {
                        self.children.insert(name.clone(), ChildPhase::Completed);
                    }
                    Some(phase) => {
                        return Err(ValidationError::InvalidChildTransition {
                            name: name.clone(),
                            from: phase.clone(),
                            to: ChildPhase::Completed,
                        });
                    }
                    None => {
                        return Err(ValidationError::ChildNotFound(name.clone()));
                    }
                }
            }
            WorkflowEvent::WorkflowCompleted => {
                // Check all children are terminal
                for (name, phase) in &self.children {
                    if !matches!(phase,
                        ChildPhase::Completed |
                        ChildPhase::Failed |
                        ChildPhase::Cancelled
                    ) {
                        return Err(ValidationError::PendingChild(name.clone()));
                    }
                }
                self.workflow = WorkflowPhase::Completed;
            }
            // ... other events
            _ => {}
        }
        Ok(())
    }

    /// Validate an entire event history
    pub fn validate(events: &[WorkflowEvent]) -> Result<(), ValidationError> {
        let mut validator = Self::new();
        for event in events {
            validator.apply(event)?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub enum ValidationError {
    DuplicateTaskId(TaskId),
    TaskNotFound(TaskId),
    InvalidTaskTransition { task_id: TaskId, from: TaskPhase, to: TaskPhase },
    ChildNotFound(ChildName),
    InvalidChildTransition { name: ChildName, from: ChildPhase, to: ChildPhase },
    PendingChild(ChildName),
    // ... more error types
}
```

### Using Stateright to Generate Test Cases

The model checker can exhaustively explore the state space and generate:

1. **Valid event histories**: All reachable states represent valid histories
2. **Edge cases**: Histories that exercise corner cases (cancellation during child execution, etc.)
3. **Counterexamples**: If a property fails, stateright provides the exact sequence of events

```rust
#[test]
fn test_event_history_consistency() {
    let model = CompositeWorkflowModel {
        max_tasks: 2,
        max_timers: 1,
        max_children: 1,
    };

    // Run model checker
    model.checker()
        .threads(num_cpus::get())
        .spawn_bfs()
        .join();
}

#[test]
fn explore_interactively() {
    let model = CompositeWorkflowModel {
        max_tasks: 2,
        max_timers: 1,
        max_children: 1,
    };

    // Launch interactive explorer on port 3000
    model.checker()
        .serve("localhost:3000");
}
```

### State Machine Interdependencies

The sub-state machines don't just run independently - they directly affect the parent workflow state:

```
                    ┌─────────────────────────────────────────────────┐
                    │              WORKFLOW STATE                      │
                    │  PENDING → RUNNING → WAITING → COMPLETED         │
                    │              ↑    ↓     ↑   ↓                    │
                    └──────────────┼────┼─────┼───┼────────────────────┘
                                   │    │     │   │
    ┌──────────────────────────────┴────┴─────┴───┴──────────────────────┐
    │                        TRIGGERS                                     │
    │                                                                     │
    │  RUNNING → WAITING:                                                 │
    │    • ScheduleTask (task not yet complete)                          │
    │    • StartTimer (timer not yet fired)                              │
    │    • InitiateChildWorkflow (child not yet complete)                │
    │    • CreatePromise (promise not yet resolved)                      │
    │                                                                     │
    │  WAITING → RUNNING (resume):                                        │
    │    • TaskCompleted/TaskFailed                                      │
    │    • TimerFired                                                    │
    │    • ChildWorkflowCompleted/ChildWorkflowFailed                    │
    │    • PromiseResolved/PromiseRejected                               │
    │                                                                     │
    │  RUNNING → COMPLETED:                                               │
    │    • All pending tasks, timers, children, promises are terminal    │
    │                                                                     │
    │  ANY → CANCELLING:                                                  │
    │    • CancellationRequested                                         │
    │    → Propagates to all children                                    │
    │                                                                     │
    └─────────────────────────────────────────────────────────────────────┘
```

**Modeling the Interdependencies:**

```rust
impl CompositeWorkflowState {
    /// Check if the workflow should be WAITING (has pending work)
    fn has_pending_work(&self) -> bool {
        // Any pending tasks?
        self.tasks.values().any(|p|
            matches!(p, TaskPhase::Scheduled | TaskPhase::Started)
        ) ||
        // Any pending timers?
        self.timers.values().any(|p|
            matches!(p, TimerPhase::Started)
        ) ||
        // Any pending children?
        self.children.values().any(|p|
            matches!(p, ChildPhase::Initiated | ChildPhase::Started)
        ) ||
        // Any pending promises?
        self.promises.values().any(|p|
            matches!(p, PromisePhase::Created)
        )
    }

    /// Check if all work is complete (can finish workflow)
    fn all_work_complete(&self) -> bool {
        !self.has_pending_work()
    }

    /// Count how many pending items we're waiting for
    fn pending_count(&self) -> usize {
        self.tasks.values().filter(|p|
            matches!(p, TaskPhase::Scheduled | TaskPhase::Started)
        ).count() +
        self.timers.values().filter(|p|
            matches!(p, TimerPhase::Started)
        ).count() +
        self.children.values().filter(|p|
            matches!(p, ChildPhase::Initiated | ChildPhase::Started)
        ).count() +
        self.promises.values().filter(|p|
            matches!(p, PromisePhase::Created)
        ).count()
    }
}

impl Model for CompositeWorkflowModel {
    fn next_state(&self, state: &Self::State, action: Self::Action)
        -> Option<Self::State>
    {
        let mut next = state.clone();
        next.next_sequence += 1;

        // Track if this action should trigger a workflow state change
        let pending_before = next.pending_count();

        match action {
            // --- Sub-state machine transitions that affect workflow ---

            WorkflowEvent::TaskScheduled { ref task_id, .. } => {
                next.tasks.insert(task_id.clone(), TaskPhase::Scheduled);
                // Scheduling work → workflow enters WAITING if it was RUNNING
                if next.workflow == WorkflowPhase::Started && next.has_pending_work() {
                    // Note: In Flovyn, we don't auto-transition here
                    // The workflow explicitly calls suspend
                }
            }

            WorkflowEvent::TaskCompleted { ref task_id } => {
                let phase = next.tasks.get(task_id)?;
                if !matches!(phase, TaskPhase::Scheduled | TaskPhase::Started) {
                    return None;
                }
                next.tasks.insert(task_id.clone(), TaskPhase::Completed);

                // Task completion may trigger workflow resume
                if next.workflow == WorkflowPhase::Suspended {
                    // Check if this was the last pending item
                    if !next.has_pending_work() || self.should_resume_on_partial() {
                        // Workflow should resume to process the result
                        next.workflow = WorkflowPhase::Started;
                    }
                }
            }

            WorkflowEvent::TimerFired { ref timer_id } => {
                let phase = next.timers.get(timer_id)?;
                if *phase != TimerPhase::Started {
                    return None;
                }
                next.timers.insert(timer_id.clone(), TimerPhase::Fired);

                // Timer fire triggers workflow resume
                if next.workflow == WorkflowPhase::Suspended {
                    next.workflow = WorkflowPhase::Started;
                }
            }

            WorkflowEvent::ChildWorkflowCompleted { ref name } => {
                let phase = next.children.get(name)?;
                if !matches!(phase, ChildPhase::Initiated | ChildPhase::Started) {
                    return None;
                }
                next.children.insert(name.clone(), ChildPhase::Completed);

                // Child completion triggers workflow resume
                if next.workflow == WorkflowPhase::Suspended {
                    next.workflow = WorkflowPhase::Started;
                }
            }

            WorkflowEvent::PromiseResolved { ref promise_id } => {
                let phase = next.promises.get(promise_id)?;
                if *phase != PromisePhase::Created {
                    return None;
                }
                next.promises.insert(promise_id.clone(), PromisePhase::Resolved);

                // Promise resolution triggers workflow resume
                if next.workflow == WorkflowPhase::Suspended {
                    next.workflow = WorkflowPhase::Started;
                }
            }

            // --- Workflow-level transitions ---

            WorkflowEvent::WorkflowSuspended => {
                if next.workflow != WorkflowPhase::Started {
                    return None; // Can only suspend from RUNNING
                }
                if !next.has_pending_work() {
                    return None; // Can't suspend without pending work
                }
                next.workflow = WorkflowPhase::Suspended;
            }

            WorkflowEvent::WorkflowResumed => {
                if next.workflow != WorkflowPhase::Suspended {
                    return None;
                }
                next.workflow = WorkflowPhase::Started;
            }

            WorkflowEvent::WorkflowCompleted => {
                if next.workflow != WorkflowPhase::Started {
                    return None; // Can only complete from RUNNING
                }
                if next.has_pending_work() {
                    return None; // Cannot complete with pending work!
                }
                next.workflow = WorkflowPhase::Completed;
            }

            WorkflowEvent::CancellationRequested => {
                // Cancellation cascades to all children
                for (_, child_phase) in next.children.iter_mut() {
                    if matches!(child_phase, ChildPhase::Initiated | ChildPhase::Started) {
                        *child_phase = ChildPhase::CancellationRequested;
                    }
                }
                next.workflow = WorkflowPhase::Cancelling;
            }

            _ => {}
        }

        next.event_log.push(action.to_event_type());
        Some(next)
    }

    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            // --- Interdependency invariants ---

            Property::always("suspended implies pending work", |_, state| {
                if state.workflow == WorkflowPhase::Suspended {
                    state.has_pending_work()
                } else {
                    true
                }
            }),

            Property::always("completed implies no pending work", |_, state| {
                if state.workflow == WorkflowPhase::Completed {
                    !state.has_pending_work()
                } else {
                    true
                }
            }),

            Property::always("terminal child before workflow complete", |_, state| {
                if state.workflow == WorkflowPhase::Completed {
                    state.children.values().all(|phase| {
                        matches!(phase,
                            ChildPhase::Completed |
                            ChildPhase::Failed |
                            ChildPhase::Cancelled
                        )
                    })
                } else {
                    true
                }
            }),

            Property::always("cancelling propagates to children", |_, state| {
                if state.workflow == WorkflowPhase::Cancelling {
                    // All non-terminal children should have cancellation requested
                    state.children.values().all(|phase| {
                        matches!(phase,
                            ChildPhase::CancellationRequested |
                            ChildPhase::Cancelled |
                            ChildPhase::Completed |
                            ChildPhase::Failed
                        )
                    })
                } else {
                    true
                }
            }),

            // --- Liveness properties ---

            Property::eventually("pending work eventually resolves", |_, state| {
                // If workflow is suspended, it should eventually resume
                state.workflow != WorkflowPhase::Suspended
            }),

            Property::sometimes("can complete with nested children", |_, state| {
                state.workflow == WorkflowPhase::Completed &&
                state.children.len() > 0 &&
                state.children.values().all(|p| *p == ChildPhase::Completed)
            }),

            // ... other properties from before
        ]
    }
}
```

### Modeling Parallel Execution

In Flovyn, multiple tasks, timers, and child workflows can progress **concurrently**. This is the key complexity:

```rust
// Example: Parallel tasks scheduled, can complete in any order
ctx.schedule("task-a", input_a);  // → TaskScheduled(task-a)
ctx.schedule("task-b", input_b);  // → TaskScheduled(task-b)
ctx.schedule("task-c", input_c);  // → TaskScheduled(task-c)
// Workflow suspends, waiting for all three

// Tasks complete in non-deterministic order:
// Could be: TaskCompleted(task-b), TaskCompleted(task-a), TaskCompleted(task-c)
// Or:       TaskCompleted(task-c), TaskCompleted(task-b), TaskCompleted(task-a)
// Or any permutation!
```

**The Interleaving Problem:**

With N parallel operations, there are N! possible completion orderings. The model checker must explore all of them:

```rust
impl Model for CompositeWorkflowModel {
    fn actions(&self, state: &Self::State, actions: &mut Vec<Self::Action>) {
        // When suspended with pending work, ALL pending items
        // can independently complete (in any order)

        if state.workflow == WorkflowPhase::Suspended {
            // Each pending task can complete or fail
            for (task_id, phase) in &state.tasks {
                if matches!(phase, TaskPhase::Scheduled | TaskPhase::Started) {
                    actions.push(WorkflowEvent::TaskCompleted {
                        task_id: task_id.clone()
                    });
                    actions.push(WorkflowEvent::TaskFailed {
                        task_id: task_id.clone()
                    });
                }
            }

            // Each pending timer can fire
            for (timer_id, phase) in &state.timers {
                if *phase == TimerPhase::Started {
                    actions.push(WorkflowEvent::TimerFired {
                        timer_id: timer_id.clone()
                    });
                }
            }

            // Each pending child can complete or fail
            for (name, phase) in &state.children {
                if matches!(phase, ChildPhase::Initiated | ChildPhase::Started) {
                    actions.push(WorkflowEvent::ChildWorkflowCompleted {
                        name: name.clone()
                    });
                    actions.push(WorkflowEvent::ChildWorkflowFailed {
                        name: name.clone()
                    });
                }
            }

            // Each pending promise can resolve or reject
            for (promise_id, phase) in &state.promises {
                if *phase == PromisePhase::Created {
                    actions.push(WorkflowEvent::PromiseResolved {
                        promise_id: promise_id.clone()
                    });
                    actions.push(WorkflowEvent::PromiseRejected {
                        promise_id: promise_id.clone()
                    });
                }
            }
        }
    }
}
```

**State Space with Parallelism:**

| Parallel Items | Possible Orderings | State Space |
|----------------|-------------------|-------------|
| 2 tasks | 2! = 2 | Small |
| 3 tasks | 3! = 6 | Manageable |
| 4 tasks | 4! = 24 | Growing |
| 5 tasks | 5! = 120 | Large |
| N tasks + M timers + K children | (N+M+K)! | Explodes |

**Symmetry Reduction:**

Stateright supports symmetry reduction to collapse equivalent states. For tasks of the same type:

```rust
impl Representative for CompositeWorkflowState {
    fn representative(&self) -> Self {
        let mut repr = self.clone();

        // Sort tasks by their phase, treating same-phase tasks as equivalent
        // This reduces state space when tasks are interchangeable

        repr
    }
}
```

### Parallel Execution Invariants

```rust
fn properties(&self) -> Vec<Property<Self>> {
    vec![
        // Order independence: final state same regardless of completion order
        Property::always("parallel completion order independent", |_, state| {
            // If all tasks are terminal, workflow state is consistent
            if state.tasks.values().all(|p| p.is_terminal()) {
                // The order they completed doesn't matter
                // What matters: the final set of completed/failed
                true
            } else {
                true
            }
        }),

        // No race on workflow state
        Property::always("single resume per completion batch", |_, state| {
            // When multiple items complete "simultaneously" (in same tick),
            // workflow resumes exactly once
            true
        }),

        // Parallel children: all must complete before parent can complete
        Property::always("join semantics: wait for all", |_, state| {
            if state.workflow == WorkflowPhase::Completed {
                // ALL children must be terminal, not just one
                state.children.values().all(|p| p.is_terminal())
            } else {
                true
            }
        }),

        // Race semantics: first completion wins
        Property::sometimes("race: first to complete wins", |_, state| {
            // Model a select/race where only first matters
            // Other pending items can be cancelled
            state.tasks.values().filter(|p| p.is_terminal()).count() >= 1 &&
            state.tasks.values().filter(|p| *p == &TaskPhase::Cancelled).count() >= 1
        }),
    ]
}
```

### Multi-Workflow Parallelism

Beyond parallel work within a single workflow, multiple workflows can execute concurrently:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct MultiWorkflowState {
    // Multiple workflows running in parallel
    workflows: HashMap<WorkflowId, CompositeWorkflowState>,

    // Shared resources (workers, task queues)
    pending_tasks: Vec<(WorkflowId, TaskId)>,
    workers: Vec<WorkerState>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum MultiWorkflowAction {
    // Workflow-specific actions
    WorkflowAction { workflow_id: WorkflowId, action: WorkflowEvent },

    // Worker claims work
    WorkerClaimsTask { worker_id: WorkerId, workflow_id: WorkflowId, task_id: TaskId },

    // Worker completes task
    WorkerCompletesTask { worker_id: WorkerId, workflow_id: WorkflowId, task_id: TaskId },

    // New workflow starts
    StartWorkflow { workflow_id: WorkflowId },
}

impl Model for MultiWorkflowModel {
    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            // Cross-workflow invariant: task claimed by at most one worker
            Property::always("single worker per task", |_, state| {
                // Each task is being executed by at most one worker
                let claimed: Vec<_> = state.workers.iter()
                    .filter_map(|w| w.current_task.as_ref())
                    .collect();
                let unique: HashSet<_> = claimed.iter().collect();
                claimed.len() == unique.len()
            }),

            // Workflow isolation: one workflow's failure doesn't affect others
            Property::always("workflow isolation", |_, state| {
                // A failed workflow doesn't corrupt other workflows' state
                for (id1, wf1) in &state.workflows {
                    for (id2, wf2) in &state.workflows {
                        if id1 != id2 && wf1.workflow == WorkflowPhase::Failed {
                            // wf2 should still be valid
                            if !wf2.is_valid() {
                                return false;
                            }
                        }
                    }
                }
                true
            }),

            // Parent-child across workflows
            Property::always("child workflow in parent's children map", |_, state| {
                for (child_id, child_wf) in &state.workflows {
                    if let Some(parent_id) = &child_wf.parent_workflow_id {
                        if let Some(parent_wf) = state.workflows.get(parent_id) {
                            // Parent should have this child in its children map
                            if !parent_wf.children.contains_key(child_id) {
                                return false;
                            }
                        }
                    }
                }
                true
            }),
        ]
    }
}
```

### Interleaving of Parent and Child Events

When parent workflow P spawns child workflow C, their event logs are separate but causally related:

```
Parent P's event log:           Child C's event log:
─────────────────────           ─────────────────────
WorkflowStarted
ChildWorkflowInitiated(C)
WorkflowSuspended               WorkflowStarted
                                TaskScheduled(task-1)
                                TaskCompleted(task-1)
                                WorkflowCompleted
ChildWorkflowCompleted(C)
WorkflowResumed
WorkflowCompleted
```

**Cross-Workflow Invariants:**

```rust
Property::always("child started before parent's child-completed", |_, state| {
    for (parent_id, parent_wf) in &state.workflows {
        for (child_name, child_phase) in &parent_wf.children {
            if matches!(child_phase, ChildPhase::Completed | ChildPhase::Failed) {
                // The actual child workflow must exist and be terminal
                if let Some(child_wf) = find_child_workflow(state, parent_id, child_name) {
                    if !child_wf.workflow.is_terminal() {
                        return false;
                    }
                }
            }
        }
    }
    true
}),

Property::always("parent waiting while child running", |_, state| {
    for (parent_id, parent_wf) in &state.workflows {
        for (child_name, child_phase) in &parent_wf.children {
            if matches!(child_phase, ChildPhase::Initiated | ChildPhase::Started) {
                // Parent should be WAITING or CANCELLING
                if !matches!(parent_wf.workflow,
                    WorkflowPhase::Suspended | WorkflowPhase::Cancelling
                ) {
                    return false;
                }
            }
        }
    }
    true
}),
```

### Recovery and Convergence Properties

A critical property: even if faulty events exist in history (due to bugs), can the system **eventually recover** to a consistent state after retry?

#### Modeling Faulty States

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct RecoverableWorkflowState {
    // Normal state
    workflow: WorkflowPhase,
    tasks: HashMap<TaskId, TaskPhase>,
    children: HashMap<ChildName, ChildPhase>,
    event_log: Vec<WorkflowEvent>,

    // Fault tracking
    has_fault: bool,
    fault_type: Option<FaultType>,
    recovery_attempts: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum FaultType {
    // Orphaned completion (TaskCompleted without TaskScheduled)
    OrphanedCompletion { task_id: TaskId },

    // Duplicate event
    DuplicateEvent { event_index: usize },

    // Out-of-order events
    OutOfOrderEvents { expected: EventType, got: EventType },

    // Missing completion (task stuck in Scheduled)
    StuckTask { task_id: TaskId },

    // Inconsistent parent-child state
    ChildParentMismatch { child_name: ChildName },

    // Sequence gap
    SequenceGap { expected: u32, got: u32 },
}
```

#### Recovery Actions

Model the actions that can heal faulty states:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum RecoveryAction {
    // Retry the workflow from last known good state
    RetryFromCheckpoint { sequence: u32 },

    // Skip the faulty event and continue
    SkipFaultyEvent { event_index: usize },

    // Compensate by adding missing event
    InjectMissingEvent { event: WorkflowEvent },

    // Force-complete a stuck task
    ForceCompleteTask { task_id: TaskId },

    // Reconcile parent-child state
    ReconcileChildState { child_name: ChildName },

    // Normal workflow progression
    NormalEvent(WorkflowEvent),
}

impl Model for RecoverableWorkflowModel {
    type State = RecoverableWorkflowState;
    type Action = RecoveryAction;

    fn actions(&self, state: &Self::State, actions: &mut Vec<Self::Action>) {
        if state.has_fault {
            // Recovery actions available when in faulty state
            match &state.fault_type {
                Some(FaultType::OrphanedCompletion { task_id }) => {
                    // Can inject the missing TaskScheduled
                    actions.push(RecoveryAction::InjectMissingEvent {
                        event: WorkflowEvent::TaskScheduled {
                            task_id: task_id.clone(),
                            task_type: "recovered".to_string(),
                        }
                    });
                    // Or skip the orphaned completion
                    actions.push(RecoveryAction::SkipFaultyEvent {
                        event_index: find_orphan_index(state, task_id),
                    });
                }

                Some(FaultType::StuckTask { task_id }) => {
                    // Can force-complete the stuck task
                    actions.push(RecoveryAction::ForceCompleteTask {
                        task_id: task_id.clone()
                    });
                    // Or retry from before the task was scheduled
                    if let Some(seq) = find_task_schedule_sequence(state, task_id) {
                        actions.push(RecoveryAction::RetryFromCheckpoint {
                            sequence: seq - 1
                        });
                    }
                }

                Some(FaultType::SequenceGap { expected, .. }) => {
                    // Retry from before the gap
                    actions.push(RecoveryAction::RetryFromCheckpoint {
                        sequence: *expected - 1
                    });
                }

                _ => {
                    // Generic retry
                    actions.push(RecoveryAction::RetryFromCheckpoint {
                        sequence: 0
                    });
                }
            }
        } else {
            // Normal actions when not faulty
            // ... generate normal workflow events
        }
    }

    fn next_state(&self, state: &Self::State, action: Self::Action)
        -> Option<Self::State>
    {
        let mut next = state.clone();

        match action {
            RecoveryAction::RetryFromCheckpoint { sequence } => {
                // Truncate event log to checkpoint
                next.event_log.truncate(sequence as usize);
                // Rebuild state from truncated log
                next.rebuild_state_from_log();
                // Clear fault
                next.has_fault = false;
                next.fault_type = None;
                next.recovery_attempts += 1;
            }

            RecoveryAction::InjectMissingEvent { event } => {
                // Insert the missing event at correct position
                next.inject_event_at_correct_position(event);
                // Revalidate
                next.has_fault = !next.is_consistent();
                if !next.has_fault {
                    next.fault_type = None;
                }
            }

            RecoveryAction::ForceCompleteTask { task_id } => {
                // Add TaskCompleted event
                next.event_log.push(WorkflowEvent::TaskCompleted {
                    task_id: task_id.clone()
                });
                next.tasks.insert(task_id, TaskPhase::Completed);
                // Check if this resolved the fault
                next.has_fault = !next.is_consistent();
            }

            RecoveryAction::NormalEvent(event) => {
                // Normal event processing
                next.apply_event(event)?;
            }

            _ => {}
        }

        Some(next)
    }

    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            // CRITICAL: From any faulty state, we can eventually reach consistent
            Property::eventually("faults are recoverable", |_, state| {
                // Either no fault, or we haven't exhausted recovery attempts
                !state.has_fault || state.recovery_attempts < self.max_recovery_attempts
            }),

            // After recovery, system is consistent
            Property::always("recovery leads to consistency", |_, state| {
                if state.recovery_attempts > 0 && !state.has_fault {
                    state.is_consistent()
                } else {
                    true
                }
            }),

            // Recovery is bounded (no infinite recovery loops)
            Property::always("bounded recovery", |_, state| {
                state.recovery_attempts <= self.max_recovery_attempts
            }),

            // Recovery preserves completed work when possible
            Property::always("recovery preserves completed work", |_, state| {
                if state.recovery_attempts > 0 {
                    // Completed tasks before fault should still be completed
                    state.completed_tasks_preserved()
                } else {
                    true
                }
            }),
        ]
    }
}
```

#### Convergence Properties

The key liveness property - **eventually consistent**:

```rust
// From ANY state (including faulty), there EXISTS a path to consistent
Property::eventually("eventually consistent", |_, state| {
    state.is_consistent() && state.workflow.is_terminal()
})

// More specifically: fault detection + recovery = consistency
Property::always("detected faults are recoverable", |_, state| {
    if state.has_fault {
        // There must exist at least one recovery action
        !state.available_recovery_actions().is_empty()
    } else {
        true
    }
})
```

#### Idempotency Verification

Verify that retrying operations is safe:

```rust
Property::always("retry is idempotent", |_, state| {
    // Applying the same event twice should either:
    // 1. Be rejected (return None)
    // 2. Result in the same state
    for event in &state.event_log {
        let state_after_once = state.apply_event(event.clone());
        if let Some(s1) = state_after_once {
            let state_after_twice = s1.apply_event(event.clone());
            match state_after_twice {
                None => continue,  // Rejected, good
                Some(s2) => {
                    if s1 != s2 {
                        return false;  // Not idempotent!
                    }
                }
            }
        }
    }
    true
})

Property::always("duplicate events detected", |_, state| {
    // No duplicate (event_id, sequence) pairs
    let pairs: Vec<_> = state.event_log.iter()
        .map(|e| (e.id(), e.sequence()))
        .collect();
    let unique: HashSet<_> = pairs.iter().collect();
    pairs.len() == unique.len()
})
```

#### Recovery Scenarios to Model

| Fault | Detection | Recovery | Convergence |
|-------|-----------|----------|-------------|
| Orphaned completion | Missing schedule event | Inject schedule OR skip completion | ✓ |
| Stuck task | Task in Scheduled, workflow completed | Force complete OR retry | ✓ |
| Sequence gap | Expected N, got N+2 | Retry from N-1 | ✓ |
| Duplicate event | Same (id, seq) twice | Skip duplicate | ✓ |
| Child-parent mismatch | Child complete, parent unaware | Inject ChildCompleted in parent | ✓ |
| Out-of-order | Complete before schedule | Reorder OR reject | ✓ |

#### Testing Recovery Paths

```rust
#[test]
fn test_recovery_from_all_fault_types() {
    let model = RecoverableWorkflowModel {
        max_tasks: 2,
        max_children: 1,
        max_recovery_attempts: 3,
        inject_faults: true,  // Model can inject faults
    };

    // Verify: from any reachable state, we can reach consistent terminal
    let checker = model.checker()
        .threads(num_cpus::get())
        .spawn_bfs()
        .join();

    // Check that "eventually consistent" holds
    assert!(checker.is_done());
    checker.assert_properties();
}

#[test]
fn explore_recovery_paths() {
    let model = RecoverableWorkflowModel::with_fault(
        FaultType::OrphanedCompletion {
            task_id: "task-1".to_string()
        }
    );

    // Interactive exploration of recovery paths
    model.checker().serve("localhost:3000");
}
```

#### Visualizing Recovery

Stateright's explorer shows recovery paths:

```
State: FAULTY (OrphanedCompletion)
  event_log: [Started, TaskCompleted(task-1)]  ← fault: no TaskScheduled
  recovery_attempts: 0

  Available actions:
    → InjectMissingEvent(TaskScheduled(task-1))
    → SkipFaultyEvent(index=1)
    → RetryFromCheckpoint(seq=0)

  Path to consistent:
    1. InjectMissingEvent(TaskScheduled(task-1))
    2. [Now consistent: Started, TaskScheduled, TaskCompleted]
    3. WorkflowCompleted
    4. ✓ Terminal consistent state
```

### Causality Constraints

The event log must respect causal ordering:

```rust
Property::always("causality: schedule before complete", |_, state| {
    // For each TaskCompleted, there must be a prior TaskScheduled
    for (i, event) in state.event_log.iter().enumerate() {
        if let EventType::TaskCompleted { task_id } = event {
            let has_prior_schedule = state.event_log[..i].iter().any(|e| {
                matches!(e, EventType::TaskScheduled { id, .. } if id == task_id)
            });
            if !has_prior_schedule {
                return false;
            }
        }
    }
    true
}),

Property::always("causality: suspend before resume", |_, state| {
    let mut suspended = false;
    for event in &state.event_log {
        match event {
            EventType::WorkflowSuspended => suspended = true,
            EventType::WorkflowResumed => {
                if !suspended {
                    return false; // Resume without prior suspend!
                }
                suspended = false;
            }
            _ => {}
        }
    }
    true
}),

Property::always("causality: child complete after initiated", |_, state| {
    for (i, event) in state.event_log.iter().enumerate() {
        if let EventType::ChildWorkflowCompleted { name } = event {
            let has_prior_initiate = state.event_log[..i].iter().any(|e| {
                matches!(e, EventType::ChildWorkflowInitiated { n, .. } if n == name)
            });
            if !has_prior_initiate {
                return false;
            }
        }
    }
    true
}),
```

### Key Invariants Across State Machines

| Invariant | Description |
|-----------|-------------|
| **Lifecycle ordering** | Scheduled → Started → (Completed\|Failed\|Cancelled) |
| **No orphans** | Every terminal event has a corresponding initiation event |
| **No duplicates** | Each entity ID appears in at most one lifecycle |
| **Parent-child sync** | Parent cannot complete while children are pending |
| **Timer uniqueness** | Each timer fires or cancels exactly once |
| **Promise resolution** | Each promise resolves or rejects exactly once |
| **Sequence monotonicity** | Sequence numbers strictly increase |
| **Cancellation propagation** | Cancellation reaches all pending descendants |
| **Suspend/Resume consistency** | Suspended implies pending work |
| **Completion prerequisites** | Completed implies all work terminal |
| **Causal ordering** | Terminal events follow initiation events |

## Additional Patterns from E2E Tests

Based on the SDK E2E tests (`sdk-rust/sdk/tests/e2e/`), several additional patterns should be modeled:

### Worker Lifecycle State Machine

From `lifecycle_tests.rs` - worker has its own state machine:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum WorkerStatus {
    Initializing,
    Registering,
    Running { since: Instant },
    Paused { reason: String },
    Stopping,
    Stopped,
    Failed { error: String },
}

// Valid transitions:
// Initializing → Registering → Running
// Running ↔ Paused
// Running → Stopping → Stopped
// Any → Failed
```

**Invariants to Verify:**
- Cannot pause unless Running
- Cannot resume unless Paused
- Heartbeats only sent when Running
- Registration completes before Running

### Parallel Combinator Semantics

From `parallel_tests.rs` - three key patterns:

```rust
// 1. join_all: Wait for ALL to complete
let results = join_all(vec![
    ctx.schedule("task-a", input_a),
    ctx.schedule("task-b", input_b),
    ctx.schedule("task-c", input_c),
]).await?;
// Returns: Vec<Result> with all results

// 2. select: First to complete wins (race)
let (winner_index, result) = select(vec![
    ctx.schedule("primary", input),
    ctx.schedule("fallback", input),
]).await?;
// Returns: (index, result) of first to complete

// 3. with_timeout: Timeout protection
let result = with_timeout(
    Duration::from_secs(5),
    ctx.schedule("slow-task", input),
).await?;
// Returns: Result or timeout error
```

**Model for join_all:**

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct JoinAllState {
    pending: Vec<TaskId>,
    completed: Vec<(TaskId, TaskResult)>,
    failed: Option<TaskId>,
}

impl Model for JoinAllModel {
    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::always("waits for all", |_, state| {
                // Cannot return success until all completed
                if state.is_resolved_success() {
                    state.pending.is_empty()
                } else {
                    true
                }
            }),
            Property::always("fails fast on error", |_, state| {
                // Returns immediately on first failure
                if state.failed.is_some() {
                    state.is_resolved_failure()
                } else {
                    true
                }
            }),
        ]
    }
}
```

**Model for select (race):**

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct SelectState {
    pending: Vec<TaskId>,
    winner: Option<(usize, TaskResult)>,
    cancelled: Vec<TaskId>,
}

impl Model for SelectModel {
    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::always("exactly one winner", |_, state| {
                if state.is_resolved() {
                    state.winner.is_some() &&
                    state.cancelled.len() == state.pending.len() - 1
                } else {
                    true
                }
            }),
            Property::always("losers cancelled", |_, state| {
                // Non-winners should be cancelled
                if let Some((winner_idx, _)) = &state.winner {
                    state.pending.iter().enumerate()
                        .filter(|(i, _)| i != winner_idx)
                        .all(|(_, id)| state.cancelled.contains(id))
                } else {
                    true
                }
            }),
        ]
    }
}
```

### Determinism Violation Types

From `replay_tests.rs` - specific violation scenarios:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum DeterminismViolation {
    // Task type changed between executions
    TaskTypeMismatch {
        sequence: u32,
        expected: String,  // "task-A"
        actual: String,    // "task-B"
    },

    // Child workflow name changed
    ChildWorkflowMismatch {
        sequence: u32,
        field: String,     // "name" or "kind"
        expected: String,
        actual: String,
    },

    // Operation name changed
    OperationNameMismatch {
        sequence: u32,
        expected: String,  // "original-op"
        actual: String,    // "changed-op"
    },

    // Timer ID changed
    TimerIdMismatch {
        sequence: u32,
        expected: String,
        actual: String,
    },

    // State key changed
    StateKeyMismatch {
        sequence: u32,
        expected: String,
        actual: String,
    },
}

// Key insight from tests: extension BEYOND replay history is ALLOWED
// Only CHANGES to existing history cause violations
```

**Model for Replay Validation:**

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct ReplayValidationState {
    replay_events: Vec<Event>,
    replay_position: usize,
    new_commands: Vec<Command>,
    violation: Option<DeterminismViolation>,
}

impl Model for ReplayValidationModel {
    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::always("matching commands pass", |_, state| {
                // If we're replaying and command matches event, no violation
                if state.replay_position < state.replay_events.len() {
                    let event = &state.replay_events[state.replay_position];
                    let cmd = state.new_commands.last();
                    if cmd.map(|c| c.matches(event)).unwrap_or(true) {
                        state.violation.is_none()
                    } else {
                        true
                    }
                } else {
                    true
                }
            }),
            Property::always("extension allowed", |_, state| {
                // Beyond replay history, new commands are allowed
                if state.replay_position >= state.replay_events.len() {
                    state.violation.is_none()
                } else {
                    true
                }
            }),
            Property::always("mismatch detected", |_, state| {
                // If command doesn't match event, violation is set
                if state.replay_position < state.replay_events.len() {
                    let event = &state.replay_events[state.replay_position];
                    let cmd = state.new_commands.last();
                    if cmd.map(|c| !c.matches(event)).unwrap_or(false) {
                        state.violation.is_some()
                    } else {
                        true
                    }
                } else {
                    true
                }
            }),
        ]
    }
}
```

### Multiple Workers Sharing Queue

From `concurrency_tests.rs` - work distribution:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct WorkDistributionState {
    queue: Vec<WorkflowId>,
    workers: Vec<WorkerState>,
    completed: HashMap<WorkflowId, WorkerId>,  // Which worker completed which workflow
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct WorkerState {
    id: WorkerId,
    current_work: Option<WorkflowId>,
    completed_count: u32,
}

impl Model for MultiWorkerModel {
    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::always("no duplicate claims", |_, state| {
                // Each workflow claimed by at most one worker
                let claimed: Vec<_> = state.workers.iter()
                    .filter_map(|w| w.current_work)
                    .collect();
                let unique: HashSet<_> = claimed.iter().collect();
                claimed.len() == unique.len()
            }),
            Property::eventually("all work completed", |_, state| {
                state.queue.is_empty() &&
                state.workers.iter().all(|w| w.current_work.is_none())
            }),
            Property::always("fair distribution", |_, state| {
                // No worker has > 2x work of another (rough fairness)
                let counts: Vec<_> = state.workers.iter()
                    .map(|w| w.completed_count)
                    .collect();
                if let (Some(&min), Some(&max)) = (counts.iter().min(), counts.iter().max()) {
                    max <= min * 2 + 1  // Allow some imbalance
                } else {
                    true
                }
            }),
        ]
    }
}
```

### Nested Child Workflows

From `child_workflow_tests.rs` - grandparent → parent → child:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct NestedWorkflowState {
    grandparent: WorkflowPhase,
    parent: Option<WorkflowPhase>,
    child: Option<WorkflowPhase>,
    depth: u32,
}

impl Model for NestedWorkflowModel {
    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::always("parent waits for child", |_, state| {
                // If child exists and is not terminal, parent is WAITING
                if let Some(child_phase) = &state.child {
                    if !child_phase.is_terminal() {
                        matches!(state.parent, Some(WorkflowPhase::Suspended))
                    } else {
                        true
                    }
                } else {
                    true
                }
            }),
            Property::always("grandparent waits for parent", |_, state| {
                // Same for grandparent → parent
                if let Some(parent_phase) = &state.parent {
                    if !parent_phase.is_terminal() {
                        state.grandparent == WorkflowPhase::Suspended
                    } else {
                        true
                    }
                } else {
                    true
                }
            }),
            Property::always("completion bubbles up", |_, state| {
                // If child completes, parent can complete, then grandparent
                if state.grandparent == WorkflowPhase::Completed {
                    matches!(state.parent, Some(WorkflowPhase::Completed)) &&
                    matches!(state.child, Some(WorkflowPhase::Completed) | None)
                } else {
                    true
                }
            }),
            Property::always("failure bubbles up", |_, state| {
                // Child failure can cause parent failure, which causes grandparent failure
                if matches!(state.child, Some(WorkflowPhase::Failed)) {
                    // Parent should handle or propagate
                    matches!(state.parent, Some(WorkflowPhase::Failed) | Some(WorkflowPhase::Completed))
                } else {
                    true
                }
            }),
        ]
    }
}
```

### Error Propagation

From `error_tests.rs` - error handling flow:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct ErrorState {
    workflow_phase: WorkflowPhase,
    error: Option<WorkflowError>,
    error_recorded: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct WorkflowError {
    message: String,
    error_type: Option<String>,
    stack_trace: Option<String>,
}

impl Model for ErrorHandlingModel {
    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            Property::always("error recorded on failure", |_, state| {
                if state.workflow_phase == WorkflowPhase::Failed {
                    state.error.is_some() && state.error_recorded
                } else {
                    true
                }
            }),
            Property::always("error message preserved", |_, state| {
                // Error message should not be lost or truncated
                if let Some(error) = &state.error {
                    !error.message.is_empty()
                } else {
                    true
                }
            }),
            Property::always("WORKFLOW_EXECUTION_FAILED event", |_, state| {
                // Failure should generate the correct event type
                if state.workflow_phase == WorkflowPhase::Failed {
                    state.error_recorded  // Event was appended
                } else {
                    true
                }
            }),
        ]
    }
}
```

### Summary of E2E Test Coverage for Model Checking

| Test File | Patterns to Model | Priority |
|-----------|-------------------|----------|
| `lifecycle_tests.rs` | Worker state machine, pause/resume, heartbeats | P1 |
| `parallel_tests.rs` | join_all, select (race), with_timeout | P1 |
| `concurrency_tests.rs` | Multi-worker distribution, no duplicate claims | P1 |
| `child_workflow_tests.rs` | Nested workflows, failure propagation | P1 |
| `replay_tests.rs` | Determinism validation, extension allowed | P0 |
| `error_tests.rs` | Error recording, message preservation | P2 |
| `timer_tests.rs` | Timer firing, cancellation | P2 |
| `promise_tests.rs` | Promise resolution, rejection | P2 |
| `state_tests.rs` | State set/clear, persistence | P2 |
| `streaming_tests.rs` | Streaming (ephemeral, less critical) | P3 |

## Implementation Approach

### Phase 1: Individual State Machines

Model each state machine in isolation:

1. **WorkflowStateMachine**: Verify state transitions (PENDING → RUNNING → WAITING → COMPLETED)
2. **TaskStateMachine**: Verify retry logic and terminal states
3. **TimerStateMachine**: Verify exactly-once firing
4. **PromiseStateMachine**: Verify resolution semantics

**Value**: Quick wins, catch basic transition bugs.

### Phase 2: Composite Single-Workflow Model

Model all sub-state-machines together in one workflow:

1. **CompositeWorkflowModel**: Workflow + tasks + timers + children + promises
2. Verify interdependencies (suspend/resume triggers, completion prerequisites)
3. Verify event log consistency and causal ordering

**Value**: Catch bugs where sub-state-machines interact incorrectly.

### Phase 3: Parallel Execution

Extend the composite model with parallelism:

1. **ParallelTasksModel**: N tasks completing in any order
2. **ParallelChildrenModel**: Multiple child workflows
3. Verify join semantics (wait for all) and race semantics (first wins)
4. Use symmetry reduction to manage state space

**Value**: Catch order-dependent bugs that only manifest under specific interleavings.

### Phase 4: Multi-Workflow & Worker Coordination

Model the full distributed system:

1. **MultiWorkflowModel**: Multiple workflows with shared workers
2. **WorkerPoolModel**: Work distribution with SELECT FOR UPDATE semantics
3. Verify single-writer invariant across workflows
4. Verify parent-child relationships across workflow boundaries

**Value**: Catch resource contention and coordination bugs.

### Phase 5: Actor-Based Runtime Model

Use stateright's actor framework for realistic scenarios:

1. **SchedulerActor**: Timer and child workflow completion handling
2. **WorkerActor**: Polling, heartbeats, registration
3. **ServerActor**: Event append, workflow state updates
4. Model network delays and failures

**Value**: Catch distributed system bugs (message reordering, lost messages).

### Example: Two-Phase Commit for Task Completion

Inspired by stateright's 2PC example, model task completion:

```rust
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct TaskCompletionState {
    task_status: TaskStatus,
    event_appended: bool,
    workflow_resumed: bool,
    worker_notified: bool,
}

enum TaskCompletionAction {
    WorkerCompletes { result: Value },
    AppendEvent,
    ResumeWorkflow,
    NotifyWorkers,
}

impl Model for TaskCompletionModel {
    fn properties(&self) -> Vec<Property<Self>> {
        vec![
            // Must notify after resume
            Property::always("notify only after resume", |_, state| {
                !state.worker_notified || state.workflow_resumed
            }),
            // Eventually reaches final state
            Property::eventually("task completion completes", |_, state| {
                state.worker_notified
            }),
        ]
    }
}
```

## Integration with Existing Tests

Stateright models can complement existing tests:

1. **Unit tests**: Test specific functions
2. **Integration tests**: Test real database interactions
3. **Stateright models**: Exhaustively verify state machine properties

The stateright models don't replace integration tests but provide stronger guarantees about state machine correctness.

## Effort Estimation

| Phase | Model | Complexity | Value | Priority |
|-------|-------|------------|-------|----------|
| 1 | Workflow State Machine | Low | High | P0 |
| 1 | Task State Machine | Low | High | P0 |
| 1 | Timer State Machine | Low | Medium | P0 |
| 2 | Composite Single-Workflow | Medium | High | P0 |
| 2 | Event Log Consistency | Medium | High | P0 |
| 2 | Interdependency Invariants | Medium | High | P1 |
| 3 | Parallel Task Completion | Medium | High | P1 |
| 3 | Parallel Child Workflows | Medium | High | P1 |
| 4 | Multi-Workflow Coordination | High | High | P1 |
| 4 | Worker Pool / Single-Writer | High | High | P1 |
| 5 | Actor-Based Scheduler | High | Medium | P2 |
| 5 | Network Failure Simulation | High | Medium | P2 |
| - | SDK Determinism Validation | High | Medium | P2 |
| - | Worker Lifecycle | Medium | Low | P3 |

### Recommended Starting Point

Start with Phase 2 (Composite Single-Workflow) as it provides the most value for the effort:
- Catches interaction bugs between sub-state-machines
- Verifies the core event history consistency
- Foundation for Phase 3 parallel execution

The individual state machines (Phase 1) are almost trivially correct and provide less value unless you suspect bugs in basic transitions.

## Challenges and Limitations

### State Space Explosion

Complex systems with many actors can have enormous state spaces. Mitigations:
- Use symmetry reduction (stateright supports this)
- Abstract away non-essential details
- Focus on specific subsystems

### Database Semantics

Stateright doesn't model PostgreSQL directly. We must:
- Abstract database operations as atomic actions
- Model advisory locks as mutex-like primitives
- Trust `SELECT FOR UPDATE SKIP LOCKED` semantics

### Async/Network Behavior

Real network behavior includes:
- Message delays
- Message reordering
- Connection failures

Stateright's network model can simulate these, but adds complexity.

## Conclusion

Stateright offers significant value for verifying Flovyn's correctness:

1. **Workflow State Machine**: Verify state transitions are valid
2. **Event Sourcing**: Verify sequence consistency and replay correctness
3. **Work Distribution**: Verify single-writer invariant
4. **Child Workflows**: Verify parent-child coordination
5. **Timers**: Verify exactly-once firing

Starting with the workflow and task state machines (Phase 1) provides immediate value with low effort. More complex distributed models (Phase 2-3) can follow as the simpler models mature.

## References

- [Stateright GitHub](https://github.com/stateright/stateright)
- [Stateright Examples](https://github.com/stateright/stateright/tree/master/examples)
- [Building Distributed Systems with Stateright (Blog)](https://www.stateright.rs/)
- [TLA+ Comparison](https://github.com/stateright/stateright#how-does-it-compare-to-tla)
