# CLI Workflow Execution Gantt Chart Tab

## Overview

Add a "Timeline" tab to the workflow detail panel in the Flovyn CLI TUI that displays a Gantt chart visualization of the execution, showing the hierarchical relationship between the workflow, child workflows, tasks, and timers with real-time progress updates.

## Goals

- Add Timeline tab to existing workflow detail panel (alongside Overview, Events, Logs, Actions)
- Visualize workflow execution as a Gantt chart within the detail panel
- Show execution tree hierarchy (workflow → child workflows → tasks)
- Display real-time progress for running tasks
- Support parallel execution visualization

## Non-Goals

- Standalone CLI command for Gantt view (use TUI tab instead)
- Loop iteration display (loops appear as repeated task instances)
- Historical comparison between workflow runs

## User Experience

### Access

1. Select a workflow in the TUI list panel
2. Press `Tab` or `5` to switch to the Timeline tab
3. Data auto-refreshes every 2 seconds (existing TUI behavior)

### Tab Integration

The TUI uses a top/bottom split layout. Timeline is a tab in the bottom detail panel:

```
┌─ Workflows ─────────────────────────────────────────────────────────────────────┐
│  ID              KIND              STATUS      STARTED      DURATION            │
│  order-abc123    order-processing  RUNNING     10:00:00     2m 15s              │
│> user-def456     user-signup       COMPLETED   09:45:00     1m 30s              │
│  sync-ghi789     data-sync         FAILED      09:30:00     45s                 │
│  batch-jkl012    batch-process     PENDING     -            -                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│  [1 Overview] [2 Events] [3 Logs] [4 Actions] [5 Timeline]                      │
│                                                                                 │
│  (current tab content here - Overview, Events, Logs, Actions, or Timeline)     │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

When **Timeline tab** is selected, the detail panel shows the Gantt chart:

```
┌─ Workflows ─────────────────────────────────────────────────────────────────────┐
│  ID              KIND              STATUS      STARTED      DURATION            │
│> order-abc123    order-processing  RUNNING     10:00:00     2m 15s              │
│  user-def456     user-signup       COMPLETED   09:45:00     1m 30s              │
├─ Detail ──────────────────────────────────────────────────────────── ● LIVE ────┤
│  [1 Overview] [2 Events] [3 Logs] [4 Actions] [5 Timeline] ←                    │
│                                                                                 │
│  TREE                                    TIMELINE (0s ─────────────────→ 120s)  │
│  ─────────────────────────────────────   ───────────────────────────────────────│
│                                          │   0s    30s    60s    90s   120s    │
│  ▼ order-processing            ⠹         ├─────────────────────────────────────┐│
│    ├─ validate-order   ✓                 │ ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ││
│    ├─ ▼ payment-flow   ✓                 │ ░░░░░░░░████████████████░░░░░░░░░░░░ ││
│    │   ├─ auth-card    ✓                 │ ░░░░░░░░████░░░░░░░░░░░░░░░░░░░░░░░░ ││
│    │   └─ charge       ✓                 │ ░░░░░░░░░░░░████████░░░░░░░░░░░░░░░░ ││
│  > ├─ ship-order       ⠹                 │ ░░░░░░░░░░░░░░░░░░░░████▓▓▓▓░░░░░░░░ ││
│    └─ notify           ○                 │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ││
│                                          └─────────────────────────────────────┘│
│                                                                                 │
│  ✓ Done  ⠋ Running  ○ Pending  ✗ Failed  ⊘ Cancelled  ⧗ Timer                   │
│  [↑↓] Select  [←→] Scroll time  [Space] Collapse  [f] Follow  [+/-] Zoom        │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**With row selected** (shows inline details):

```
├─ Detail ──────────────────────────────────────────────────────────── ● LIVE ────┤
│  [1 Overview] [2 Events] [3 Logs] [4 Actions] [5 Timeline] ←                    │
│                                                                                 │
│  TREE                                    TIMELINE (0s ─────────────────→ 120s)  │
│  ─────────────────────────────────────   ───────────────────────────────────────│
│  ▼ order-processing            ⠹         ├─────────────────────────────────────┐│
│    ├─ validate-order   ✓                 │ ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ││
│  > ├─ ship-order       ⠹                 │ ░░░░░░░░░░░░░░░░░░░░████▓▓▓▓░░░░░░░░ ││
│    └─ notify           ○                 │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ││
│                                          └─────────────────────────────────────┘│
│ ─────────────────────────────────────────────────────────────────────────────── │
│ ▶ ship-order (e3f2a1b8)  RUNNING  45%  Duration: 3.2s  Worker: worker-2         │
│   [Enter] Logs  [i] Input/Output  [Esc] Dismiss                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Scrolling Behavior

Both the tree and timeline are independently scrollable:

**Vertical scroll** (tree has more rows than viewport):
```
┌─ Timeline ─────────────────────────────────────────────────────────────────────┐
│  TREE                              TIMELINE (0s → 120s)            scroll: 5/20│
│  ────────────────────────────────  ────────────────────────────────────────────│
│    ├─ task-5             ✓         │ ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ ▲
│    ├─ task-6             ✓         │ ░░░░████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ █
│    ├─ task-7             ✓         │ ░░░░░░░░████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ █
│  > ├─ task-8             ⠹         │ ░░░░░░░░░░░░████▓▓▓▓░░░░░░░░░░░░░░░░░░░░ │ ░
│    ├─ task-9             ○         │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ ░
│    └─ task-10            ○         │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ ▼
│                                                                                 │
│  [↑/↓] Scroll tree  [j/k] Vim-style                                            │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Horizontal scroll** (timeline extends beyond viewport):
```
┌─ Timeline ─────────────────────────────────────────────────────────────────────┐
│  TREE                              TIMELINE (30s ──────────────────→ 150s)     │
│  ────────────────────────────────  ◀ ──────────────────────────────────── ▶    │
│                                    │  30s    60s    90s   120s   150s         │
│  ▼ long-workflow           ⠹       │──────────────────────────────▓▓▓▓▓▓▓▓▓▓▓ │
│    ├─ step-1               ✓       │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ (off-screen left)
│    ├─ step-2               ✓       │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ (off-screen left)
│    ├─ step-3               ✓       │ ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    └─ step-4               ⠹       │ ░░░░░░░░░░░░░░░░████████████▓▓▓▓▓▓▓▓▓▓▓ │
│                                                                                 │
│  [←/→] Scroll timeline  [h/l] Vim-style  [Home] Start  [End] Now               │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Scroll indicators**:
- `◀` / `▶` arrows when content extends beyond visible timeline
- `▲` / `▼` or scrollbar when tree has more rows
- Current position indicator: `scroll: 5/20` (row 5 of 20)

**Scroll synchronization**:
- Tree and timeline rows scroll together vertically (same selected row)
- Timeline horizontal scroll is independent
- Selected row always stays visible (auto-scroll to keep in view)

**Scroll state in TimelineState**:
```rust
struct TimelineState {
    // ... existing fields ...

    // Vertical scroll (tree rows)
    scroll_offset_rows: usize,    // First visible row index
    visible_rows: usize,          // Number of rows that fit in viewport

    // Horizontal scroll (timeline)
    scroll_offset_seconds: i64,   // Left edge of visible timeline (seconds from start)
    visible_duration: i64,        // Seconds visible in viewport

    // Total counts
    total_rows: usize,            // Total flattened tree rows
    total_duration_seconds: i64,  // Total workflow duration
}
```

**Keyboard controls for scrolling**:

| Key | Action |
|-----|--------|
| `↑/↓` or `j/k` | Move selection (auto-scrolls tree) |
| `←/→` or `h/l` | Scroll timeline left/right |
| `PgUp/PgDn` | Scroll tree by page |
| `Home` | Jump to timeline start (t=0) |
| `End` | Jump to timeline end (now) |
| `Ctrl+↑/↓` | Scroll tree without moving selection |

**Notes**:
- `● LIVE` indicator appears when follow mode is active (SSE streaming)
- The spinner symbol (⠹) animates for running tasks
- Selected row details appear inline at the bottom of the detail panel

### Layout Configuration

The TUI supports two layout modes, configurable via `L` key or config file:

**Vertical layout** (default for wide terminals ≥120 cols):
```
┌─ Workflows ─────────────────────┬─ Detail ──────────────────────────────────────┐
│  ID           STATUS            │  [1 Overview] [2 Events] ... [5 Timeline]     │
│> order-abc    RUNNING           │                                               │
│  user-def     COMPLETED         │  TREE                    TIMELINE             │
│  sync-ghi     FAILED            │  ▼ order-processing      ├────────────────┐   │
│                                 │    ├─ validate   ✓       │ ████░░░░░░░░░░ │   │
│                                 │    └─ ship       ⠹       │ ░░░░████▓▓░░░░ │   │
│                                 │                          └────────────────┘   │
└─────────────────────────────────┴───────────────────────────────────────────────┘
```

**Horizontal layout** (default for narrow terminals <120 cols):
```
┌─ Workflows ─────────────────────────────────────────────────────────────────────┐
│  ID              KIND              STATUS      STARTED      DURATION            │
│> order-abc123    order-processing  RUNNING     10:00:00     2m 15s              │
│  user-def456     user-signup       COMPLETED   09:45:00     1m 30s              │
├─ Detail ────────────────────────────────────────────────────────────────────────┤
│  [1 Overview] [2 Events] [3 Logs] [4 Actions] [5 Timeline]                      │
│                                                                                 │
│  TREE                                    TIMELINE (0s → 120s)                   │
│  ▼ order-processing            ⠹         ├─────────────────────────────────────┐│
│    ├─ validate-order   ✓                 │ ████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ││
│    └─ ship-order       ⠹                 │ ░░░░░░░░░░░░░░░░░░░░████▓▓▓▓░░░░░░░░ ││
│                                          └─────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Configuration**:
```toml
# ~/.config/flovyn/config.toml
[tui]
layout = "auto"  # "auto" | "vertical" | "horizontal"
# auto: vertical if terminal width >= 120, else horizontal
```

**Runtime toggle**: Press `L` to cycle between layouts

### Repeated Task Executions (Loops)

When a workflow runs the same task type multiple times (e.g., in a loop), each invocation creates a separate `task_execution` record. These are grouped by task type and indexed by execution order:

**Data model**: Multiple task executions with same `task_type` but different `id`:
```
task_execution { id: "aaa", task_type: "process-item", ... }
task_execution { id: "bbb", task_type: "process-item", ... }
task_execution { id: "ccc", task_type: "process-item", ... }
```

**Display**: Group under collapsible parent with count, show index suffix:

**Sequential loop** (e.g., process 5 items one at a time):
```
│  ▼ batch-processor                 ├──────────────────────────────────────────┐
│    ├─ fetch-batch          ✓       │ ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    ├─ ▼ process-items [5]          │ ░░░░████████████████████████████░░░░░░░░ │
│    │   ├─ process-item[0]  ✓       │ ░░░░████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    │   ├─ process-item[1]  ✓       │ ░░░░░░░░████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    │   ├─ process-item[2]  ✓       │ ░░░░░░░░░░░░████░░░░░░░░░░░░░░░░░░░░░░░░ │
│    │   ├─ process-item[3]  ✓       │ ░░░░░░░░░░░░░░░░████░░░░░░░░░░░░░░░░░░░░ │
│    │   └─ process-item[4]  ✓       │ ░░░░░░░░░░░░░░░░░░░░████░░░░░░░░░░░░░░░░ │
│    └─ save-results         ✓       │ ░░░░░░░░░░░░░░░░░░░░░░░░████░░░░░░░░░░░░ │
```

**Parallel loop** (e.g., process 5 items concurrently):
```
│  ▼ batch-processor                 ├──────────────────────────────────────────┐
│    ├─ fetch-batch          ✓       │ ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    ├─ ▼ process-items [5]          │ ░░░░████████████░░░░░░░░░░░░░░░░░░░░░░░░ │
│    │   ├─ process-item[0]  ✓       │ ░░░░████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    │   ├─ process-item[1]  ✓       │ ░░░░██████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    │   ├─ process-item[2]  ✓       │ ░░░░████████████░░░░░░░░░░░░░░░░░░░░░░░░ │
│    │   ├─ process-item[3]  ✓       │ ░░░░████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    │   └─ process-item[4]  ✓       │ ░░░░██████████░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    └─ save-results         ✓       │ ░░░░░░░░░░░░████░░░░░░░░░░░░░░░░░░░░░░░░ │
```

**Collapsed view** (hide individual iterations):
```
│  ▼ batch-processor                 ├──────────────────────────────────────────┐
│    ├─ fetch-batch          ✓       │ ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    ├─ ▶ process-items [5/5] ✓      │ ░░░░████████████░░░░░░░░░░░░░░░░░░░░░░░░ │
│    └─ save-results         ✓       │ ░░░░░░░░░░░░████░░░░░░░░░░░░░░░░░░░░░░░░ │
```

**Loop with failure** (3rd iteration failed, workflow retried):
```
│    ├─ ▼ process-items [5]          │ ░░░░████████████████████████████░░░░░░░░ │
│    │   ├─ process-item[0]  ✓       │ ░░░░████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    │   ├─ process-item[1]  ✓       │ ░░░░░░░░████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    │   ├─ process-item[2]  ✗ [2]   │ ░░░░░░░░░░░░██░░██████░░░░░░░░░░░░░░░░░░ │
│    │   ├─ process-item[3]  ✓       │ ░░░░░░░░░░░░░░░░░░░░░░████░░░░░░░░░░░░░░ │
│    │   └─ process-item[4]  ✓       │ ░░░░░░░░░░░░░░░░░░░░░░░░░░████░░░░░░░░░░ │
```

The `[2]` indicates 2 attempts (1 failure + 1 retry). The bar shows a gap between the failed attempt and successful retry.

**Grouping logic**:
1. Query all task executions for the workflow
2. Group by `task_type`
3. If a task type has multiple executions → create collapsible group node
4. Sort executions within group by `created_at`
5. Index suffix `[0]`, `[1]`, `[2]` based on sort order

### Parallel Execution

Parallel tasks/workflows are visualized with overlapping timeline bars. The tree structure is flat (siblings), and bars occupy the same horizontal time range:

**Parallel tasks** (fan-out pattern):
```
│  ▼ order-fulfillment               ├──────────────────────────────────────────┐
│    ├─ validate-order       ✓       │ ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    ├─ check-inventory      ✓       │ ░░░░████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │  ┐
│    ├─ check-fraud          ✓       │ ░░░░██████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │  ├─ parallel
│    ├─ reserve-payment      ✓       │ ░░░░████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │  ┘
│    └─ ship-order           ✓       │ ░░░░░░░░░░░░████░░░░░░░░░░░░░░░░░░░░░░░░ │
```

The three middle tasks start at the same time (bars aligned left) and complete independently.

**Parallel child workflows**:
```
│  ▼ batch-orchestrator              ├──────────────────────────────────────────┐
│    ├─ split-batch          ✓       │ ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    ├─ ▼ process-chunk-1    ✓       │ ░░░░████████████░░░░░░░░░░░░░░░░░░░░░░░░ │  ┐
│    │   ├─ transform        ✓       │ ░░░░████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │  │
│    │   └─ validate         ✓       │ ░░░░░░░░░░░░████░░░░░░░░░░░░░░░░░░░░░░░░ │  │
│    ├─ ▼ process-chunk-2    ✓       │ ░░░░██████████████░░░░░░░░░░░░░░░░░░░░░░ │  ├─ parallel
│    │   ├─ transform        ✓       │ ░░░░████████████░░░░░░░░░░░░░░░░░░░░░░░░ │  │  child
│    │   └─ validate         ✓       │ ░░░░░░░░░░░░░░░░████░░░░░░░░░░░░░░░░░░░░ │  │  workflows
│    ├─ ▼ process-chunk-3    ✓       │ ░░░░████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │  ┘
│    │   ├─ transform        ✓       │ ░░░░██████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    │   └─ validate         ✓       │ ░░░░░░░░░░████░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    └─ merge-results        ✓       │ ░░░░░░░░░░░░░░░░░░░░████░░░░░░░░░░░░░░░░ │
```

**Visual indicator for parallelism** (optional enhancement):
```
│    ├─ ╠═ check-inventory   ✓       │ ░░░░████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    ├─ ╠═ check-fraud       ✓       │ ░░░░██████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    ├─ ╚═ reserve-payment   ✓       │ ░░░░████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
```

The `╠═` / `╚═` connectors indicate these tasks were scheduled together (same parent event or Promise.all equivalent).

**Detecting parallelism**:
```rust
fn detect_parallel_groups(tasks: &[TaskExecution]) -> Vec<Vec<&TaskExecution>> {
    // Tasks are parallel if their start times overlap significantly
    // (started within 100ms of each other, or from same TASK_SCHEDULED batch)

    let mut groups: Vec<Vec<&TaskExecution>> = vec![];
    for task in tasks {
        if let Some(group) = groups.iter_mut().find(|g| is_parallel_with(task, g)) {
            group.push(task);
        } else {
            groups.push(vec![task]);
        }
    }
    groups
}

fn is_parallel_with(task: &TaskExecution, group: &[&TaskExecution]) -> bool {
    // Check if task overlaps in time with any task in group
    group.iter().any(|other| {
        let task_start = task.started_at.unwrap_or(task.created_at);
        let other_start = other.started_at.unwrap_or(other.created_at);
        let other_end = other.completed_at.unwrap_or(Utc::now());

        // Task started while other was running
        task_start >= other_start && task_start < other_end
    })
}
```

```rust
fn group_task_executions(tasks: Vec<TaskExecution>) -> Vec<ExecutionNode> {
    let mut by_type: HashMap<String, Vec<TaskExecution>> = HashMap::new();
    for task in tasks {
        by_type.entry(task.task_type.clone()).or_default().push(task);
    }

    by_type.into_iter().map(|(task_type, mut execs)| {
        execs.sort_by_key(|t| t.created_at);
        if execs.len() == 1 {
            // Single execution - no grouping needed
            task_to_node(&execs[0], None)
        } else {
            // Multiple executions - create group with indexed children
            ExecutionNode {
                kind: format!("{} [{}]", task_type, execs.len()),
                node_type: NodeType::TaskGroup,
                children: execs.iter().enumerate()
                    .map(|(i, t)| task_to_node(t, Some(i)))
                    .collect(),
                // Group timing spans from first start to last end
                started_at: execs.iter().filter_map(|t| t.started_at).min(),
                completed_at: execs.iter().filter_map(|t| t.completed_at).max(),
                ..Default::default()
            }
        }
    }).collect()
}
```

### Child Workflow Execution Tree

Child workflows are nested within the parent's tree. Each child workflow is collapsible and shows its own tasks, timers, and grandchild workflows:

**Expanded child workflow**:
```
│  ▼ order-processing                ├──────────────────────────────────────────┐
│    ├─ validate-order       ✓       │ ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    ├─ ▼ payment-flow       ✓       │ ░░░░████████████████░░░░░░░░░░░░░░░░░░░░ │ ← child workflow
│    │   ├─ auth-card        ✓       │ ░░░░████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    │   ├─ charge-card      ✓       │ ░░░░░░░░████████░░░░░░░░░░░░░░░░░░░░░░░░ │
│    │   ├─ ▼ notify-flow    ✓       │ ░░░░░░░░░░░░░░░░████████░░░░░░░░░░░░░░░░ │ ← grandchild
│    │   │   ├─ send-email   ✓       │ ░░░░░░░░░░░░░░░░████░░░░░░░░░░░░░░░░░░░░ │
│    │   │   └─ send-sms     ✓       │ ░░░░░░░░░░░░░░░░░░░░████░░░░░░░░░░░░░░░░ │
│    │   └─ update-ledger    ✓       │ ░░░░░░░░░░░░░░░░░░░░░░░░████░░░░░░░░░░░░ │
│    └─ ship-order           ✓       │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░████░░░░░░░░ │
```

**Collapsed child workflow** (shows aggregate bar):
```
│  ▼ order-processing                ├──────────────────────────────────────────┐
│    ├─ validate-order       ✓       │ ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    ├─ ▶ payment-flow       ✓       │ ░░░░████████████████░░░░░░░░░░░░░░░░░░░░ │ ← collapsed
│    └─ ship-order           ✓       │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░████░░░░░░░░ │
```

**Child workflow states**:
```
├─ ▼ payment-flow       ✓       │ Complete - green bar
├─ ▼ payment-flow       ⠹       │ Running - animated, growing bar
├─ ▼ payment-flow       ✗       │ Failed - red bar
├─ ▼ payment-flow       ○       │ Pending - no bar yet
├─ ▶ payment-flow [4]   ✓       │ Collapsed with task count
```

**Data fetching for child workflows**:
```rust
async fn load_workflow_tree(
    client: &FlovynClient,
    tenant: &str,
    workflow_id: Uuid,
    depth: usize,
) -> Result<ExecutionNode, Error> {
    // 1. Fetch parent workflow
    let workflow = client.get_workflow(tenant, workflow_id).await?;

    // 2. Fetch tasks for this workflow
    let tasks = client.get_workflow_tasks(tenant, workflow_id).await?;

    // 3. Fetch child workflows
    let children = client.get_workflow_children(tenant, workflow_id).await?;

    // 4. Recursively load each child (with depth limit)
    let child_nodes = if depth < MAX_DEPTH {
        futures::future::join_all(
            children.iter().map(|c| load_workflow_tree(client, tenant, c.id, depth + 1))
        ).await
    } else {
        // At max depth, show placeholder
        children.iter().map(|c| shallow_workflow_node(c)).collect()
    };

    // 5. Build tree: workflow -> [tasks..., child_workflows...]
    Ok(ExecutionNode {
        id: workflow.id,
        kind: workflow.kind,
        node_type: NodeType::Workflow,
        status: workflow.state.into(),
        started_at: workflow.started_at,
        completed_at: workflow.completed_at,
        children: merge_and_sort_by_time(
            task_nodes(&tasks),
            child_nodes,
        ),
        ..Default::default()
    })
}
```

**Tree depth limits**:
- Default max depth: 5 levels
- Beyond max depth: show `▶ child-workflow [+]` with "expand to load" indicator
- User can press `Enter` on a shallow node to load its children on demand

**Ordering within tree**:
Children (tasks + child workflows) are sorted by `started_at` or `created_at`, so the tree reflects execution order:
```
│    ├─ task-a           ✓       │ ████░░░░░░░░  │  t=0
│    ├─ ▼ child-wf       ✓       │ ░░░░████████  │  t=2  (started after task-a)
│    │   └─ ...
│    └─ task-b           ✓       │ ░░░░░░░░████  │  t=5  (started after child-wf)
```

### Visual Elements

| Element | Symbol | Bar Style |
|---------|--------|-----------|
| Completed task/workflow | ✓ | `████` solid green |
| Running task/workflow | ⠋ | `▓▓▓▓` animated spinner, growing bar |
| Pending task/workflow | ○ | Empty/no bar |
| Failed task/workflow | ✗ | `████` solid red |
| Cancelled task/workflow | ⊘ | `░░░░` dimmed |
| Timer (waiting) | ⧗ | `····` dotted |
| Child workflow (expanded) | ▼ | Collapsible, contains nested items |
| Child workflow (collapsed) | ▶ | Shows aggregate bar span |
| Task group (loop) | `[N]` | Count suffix, collapsible |
| Retry attempt | `[2]` | Attempt count on failed tasks |
| Depth limit reached | `[+]` | Load on demand |

### Timeline Features

1. **Auto-scaling**: Timeline width adjusts based on total execution duration
2. **Relative positioning**: Tasks positioned based on their start time relative to workflow start
3. **Progress indication**: Running tasks show partial fill with percentage
4. **Parallel execution**: Multiple bars at same vertical position for concurrent tasks

## Data Sources

### Required API Data

```rust
// WorkflowExecution fields needed:
- id, kind, state
- created_at, started_at, completed_at
- parent_workflow_execution_id (for hierarchy)

// TaskExecution fields needed:
- id, task_type, status
- created_at, started_at, completed_at
- progress (0.0-1.0), progress_details
- execution_count (for retry indicator)

// WorkflowEvent types to parse:
- TASK_SCHEDULED, TASK_STARTED, TASK_COMPLETED, TASK_FAILED
- TIMER_STARTED, TIMER_FIRED
- CHILD_WORKFLOW_INITIATED, CHILD_WORKFLOW_STARTED, CHILD_WORKFLOW_COMPLETED
```

### Data Fetching Strategy

1. **Initial load**:
   - Fetch workflow execution: `GET /api/tenants/{tenant}/workflows/{id}`
   - Fetch workflow events: `GET /api/tenants/{tenant}/workflows/{id}/events`
   - Fetch child workflows: `GET /api/tenants/{tenant}/workflows/{id}/children`
   - For each child: recursively fetch its events

2. **Real-time updates** (follow mode):
   - Subscribe to SSE: `GET /api/tenants/{tenant}/stream/workflows/{id}/consolidated`
   - Update timeline bars on PROGRESS events
   - Add/complete tasks on lifecycle events

### Execution Tree Construction

Build tree from events:

```rust
struct ExecutionNode {
    id: Uuid,
    kind: String,           // workflow kind or task type
    node_type: NodeType,    // Workflow, Task, Timer
    status: Status,
    started_at: Option<DateTime<Utc>>,
    completed_at: Option<DateTime<Utc>>,
    progress: f64,          // 0.0-1.0
    retry_count: u32,
    children: Vec<ExecutionNode>,
}

enum NodeType {
    Workflow,
    Task,
    Timer,
}
```

## Technical Design

### New Files

```
cli/src/tui/panels/timeline.rs  # Timeline tab rendering
cli/src/tui/timeline/           # Timeline-specific modules
  mod.rs
  tree.rs                       # Execution tree data structure
  bar.rs                        # Timeline bar rendering
```

### Timeline State (added to App struct)

```rust
// In App struct, add:
pub timeline_state: TimelineState,

struct TimelineState {
    root: Option<ExecutionNode>,

    // View state
    timeline_offset: i64,       // Scroll position (seconds from start)
    timeline_scale: f64,        // Seconds per character
    selected_row: usize,
    collapsed: HashSet<Uuid>,   // Collapsed child workflows

    // Loaded data
    child_workflows: Vec<WorkflowExecutionResponse>,
    workflow_tasks: Vec<TaskResponse>,
}
```

### Integration with Existing TUI

1. Add `DetailTab::Timeline` to existing enum:
   ```rust
   pub enum DetailTab {
       Overview,
       Events,
       Logs,
       Actions,
       Timeline,  // NEW
   }
   ```

2. Add keybinding `5` to switch to Timeline tab (following existing 1-4 pattern)

3. Load timeline data when tab is selected:
   ```rust
   KeyCode::Char('5') => {
       app.detail_tab = DetailTab::Timeline;
       if let Some(wf) = app.selected_workflow_summary() {
           spawn_load_timeline_data(&app, wf.id, tx.clone());
       }
   }
   ```

4. Add new messages for timeline data:
   ```rust
   enum AppMessage {
       // ... existing ...
       TimelineDataLoaded(Box<Result<TimelineData, String>>),
   }
   ```

5. Render timeline in `render_detail_panel()` when `DetailTab::Timeline` is active

### Dependencies

Consider adding to `flovyn-server/cli/Cargo.toml`:

```toml
# Already have ratatui 0.29, crossterm 0.28 - sufficient for basic Gantt

# Optional: for enhanced animations (evaluate necessity)
# tachyonfx = "0.7"  # Smooth animations, may be overkill for MVP
```

The existing `ratatui` widgets (Paragraph, Block, Gauge) combined with custom rendering are sufficient. `tachyonfx` could be added later for polish.

## Timeline Rendering Algorithm

```rust
fn render_timeline_bar(
    node: &ExecutionNode,
    workflow_start: DateTime<Utc>,
    now: DateTime<Utc>,
    timeline_width: u16,
    scale: f64,  // seconds per character
) -> Vec<Span> {
    let total_duration = (now - workflow_start).num_seconds() as f64;

    // Calculate bar position
    let start_offset = node.started_at
        .map(|t| (t - workflow_start).num_seconds() as f64)
        .unwrap_or(0.0);

    let duration = match (node.started_at, node.completed_at) {
        (Some(s), Some(e)) => (e - s).num_seconds() as f64,
        (Some(s), None) => (now - s).num_seconds() as f64,
        _ => 0.0,
    };

    // Convert to character positions
    let bar_start = (start_offset / scale) as u16;
    let bar_width = (duration / scale).max(1.0) as u16;

    // Build spans with appropriate styling
    render_bar_spans(bar_start, bar_width, timeline_width, node)
}
```

## Real-Time Updates & Animation

### Update Mechanisms

1. **Polling (default)**: Existing 2-second auto-refresh updates all data
2. **SSE streaming (optional)**: Subscribe to consolidated stream for instant updates
   - Enable with `--follow` flag or toggle in TUI
   - Receives PROGRESS events as tasks report progress

### Animation Types

#### 1. Running Task Spinner
For tasks without explicit progress, show animated spinner:

```
Frame 0:  ⠋ process-order
Frame 1:  ⠙ process-order
Frame 2:  ⠹ process-order
Frame 3:  ⠸ process-order
Frame 4:  ⠼ process-order
Frame 5:  ⠴ process-order
Frame 6:  ⠦ process-order
Frame 7:  ⠧ process-order
```

Animation rate: 100ms per frame (10 FPS)

#### 2. Progress Bar Animation
For tasks with explicit progress (0.0-1.0):

```
Static fill based on progress:
25%:  ▓▓░░░░░░░░░░
50%:  ▓▓▓▓▓▓░░░░░░
75%:  ▓▓▓▓▓▓▓▓▓░░░
```

Optional: animated "wave" effect on the leading edge:
```
Frame 0:  ▓▓▓▓▓▓▓▓░░░░
Frame 1:  ▓▓▓▓▓▓▓▓▒░░░
Frame 2:  ▓▓▓▓▓▓▓▓░░░░
```

#### 3. Growing Bar for Running Tasks
Bar length grows in real-time as elapsed time increases:

```
t=0s:   ▓░░░░░░░░░░░
t=5s:   ▓▓▓░░░░░░░░░
t=10s:  ▓▓▓▓▓▓░░░░░░
```

### Implementation

```rust
// In App struct
pub struct TimelineState {
    // ... existing fields ...

    // Animation
    animation_tick: u8,           // Cycles 0-7 for spinner
    last_animation_frame: Instant,
    sse_connected: bool,
}

// In main loop, add animation tick
if app.detail_tab == DetailTab::Timeline {
    if app.timeline_state.last_animation_frame.elapsed() > Duration::from_millis(100) {
        app.timeline_state.animation_tick =
            (app.timeline_state.animation_tick + 1) % 8;
        app.timeline_state.last_animation_frame = Instant::now();
    }
}
```

### SSE Integration for Real-Time

When Timeline tab is active with follow mode:

```rust
fn spawn_timeline_stream(app: &App, workflow_id: Uuid, tx: mpsc::Sender<AppMessage>) {
    let client = app.client.clone();
    let tenant = app.tenant.clone();

    tokio::spawn(async move {
        let mut stream = client.stream_workflow_consolidated(&tenant, workflow_id);
        while let Some(event) = stream.next().await {
            match event {
                Ok(e) if e.event_type == "progress" => {
                    let _ = tx.send(AppMessage::TimelineProgressUpdate(e)).await;
                }
                Ok(e) if e.event_type == "data" => {
                    // Task completed, workflow state changed, etc.
                    let _ = tx.send(AppMessage::TimelineEventUpdate(e)).await;
                }
                Err(_) => break,
            }
        }
    });
}
```

### Visual Feedback

| State | Animation | Update Source |
|-------|-----------|---------------|
| Running (no progress) | Spinner (⠋⠙⠹⠸⠼⠴⠦⠧) | Local animation loop |
| Running (with progress) | Growing bar | SSE PROGRESS events |
| Running (elapsed time) | Bar extends right | Local timer + SSE |
| Completed | Static green bar | SSE DATA event |
| Failed | Static red bar + ✗ | SSE DATA event |

## Keyboard Controls

Within the Timeline tab:

| Key | Action |
|-----|--------|
| `↑/↓` or `j/k` | Select row in tree |
| `←/→` or `h/l` | Scroll timeline horizontally |
| `Space` | Expand/collapse child workflow |
| `+/-` | Zoom in/out timeline |
| `0` | Reset timeline to auto-fit |
| `f` | Toggle follow mode (SSE streaming) |

Standard TUI controls still apply:

| Key | Action |
|-----|--------|
| `5` | Switch to Timeline tab |
| `Tab` | Cycle to next tab |
| `r` | Refresh all data |
| `Esc` | Return to list panel / dismiss details |
| `L` | Toggle layout (vertical ↔ horizontal) |
| `?` | Show help overlay |

## Error Handling

- If events fail to load: show "Failed to load timeline" message in tab content
- If child workflow fetch fails: show parent workflow only with "[children unavailable]" indicator
- If task list fails: show workflow bar only with "[tasks unavailable]" indicator
- All errors allow retry via `r` key (standard refresh)

## Performance Considerations

1. **Large event counts**: Paginate events, load incrementally
2. **Deep nesting**: Limit tree depth display, collapse by default
3. **Many concurrent tasks**: Group parallel tasks, show count if > threshold
4. **Long-running workflows**: Use time-based windowing for very long timelines

## Additional Considerations

### Timers Visualization

Timers appear as dotted bars showing the wait period:

```
│    ├─ send-reminder      ✓       │ ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    ├─ ⧗ wait-24h               │ ░░░░································░░░░ │ ← timer
│    └─ check-response     ⠹       │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▓▓▓▓ │
```

Timer states:
- `⧗` waiting (dotted bar `····`)
- `✓` fired (solid bar, timer completed)
- `⊘` cancelled (dimmed dotted bar)

### Workflow Suspension (WAITING state)

When workflow is suspended waiting for external signal/promise:

```
│  ▼ approval-flow           ⏸       │ ████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    ├─ submit-request     ✓         │ ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    ├─ ⏸ await-approval             │ ░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░░░░░░░░░░░░░░░░░ │ ← waiting
│    └─ ○ process-result             │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
```

The `⏸` symbol and `▒▒▒` pattern indicate suspended/waiting state.

### Selected Row Details

When a row is selected, show details in a popup or bottom section:

```
┌─ Timeline ─────────────────────────────────────────────────────────── ● LIVE ──┐
│  TREE                              TIMELINE                                     │
│  ...                               ...                                          │
│  > ├─ charge-card      ✓           │ ░░░░░░░░████████░░░░░░░░░░░░░░░░░░░░░░░░ │ │
│  ...                               ...                                          │
├─────────────────────────────────────────────────────────────────────────────────┤
│ Task: charge-card (e3f2a1b8)                                                    │
│ Status: COMPLETED  Duration: 2.3s  Worker: worker-1                             │
│ Started: 10:00:05  Completed: 10:00:07  Attempts: 1                             │
│ [Enter] View logs  [i] View input/output                                        │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Cancellation Cascade

When parent is cancelled, children show propagated cancellation:

```
│  ▼ batch-job               ⊘       │ ████████████⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘⊘ │
│    ├─ step-1               ✓       │ ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    ├─ step-2               ✓       │ ░░░░████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    ├─ step-3               ⊘       │ ░░░░░░░░██⊘⊘░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ ← cancelled mid-execution
│    └─ step-4               ⊘       │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ ← never started
```

### Error Indicator

Failed tasks show error hint, full details on selection:

```
│    ├─ process-payment  ✗ [!]   │ ░░░░████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
```

The `[!]` indicates an error message is available. Selecting the row shows:
```
│ Error: PaymentDeclined - Card ending 4242 was declined by issuer               │
```

### Empty/Loading States

```
# Loading
┌─ Timeline ──────────────────────────────────────────────────────────────────────┐
│                                                                                 │
│                            ⠹ Loading timeline...                                │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘

# Workflow just started, no tasks yet
┌─ Timeline ──────────────────────────────────────────────────────────────────────┐
│  ▼ order-processing        ⠹       │ ▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│    (no tasks scheduled yet)        │                                           │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Truncation for Long Names

Task/workflow names truncated with ellipsis, full name on hover/selection:

```
│    ├─ process-user-registrat… ✓   │ ████████░░░░░░░░░░░░░░░░░░░░░░ │
```

Tree column has fixed width (e.g., 30 chars), timeline takes remaining space.

### Terminal Size Handling

- **Minimum width**: 80 columns (show warning if smaller)
- **Narrow terminal**: Hide legend, compress tree names
- **Wide terminal**: More timeline resolution, show more task name

### Accessibility

- Color is not the only indicator (symbols: ✓ ✗ ⠹ ○ ⊘ ⧗)
- High contrast mode option (bold colors)
- Reduce motion option (disable spinner animation)

## Open Questions

1. **Timezone**: Display times in local timezone or UTC? (Recommend: local with UTC option)
2. **Log integration**: Should `Enter` on a task jump to Logs tab filtered to that task?
3. **Input/Output viewing**: Add `i` key to show task input/output JSON in modal?
4. **Workflow retries**: How to show a workflow that was retried from failure? Separate tree or inline?

## Future Enhancements

- Export timeline as ASCII art or image
- Compare multiple workflow runs side-by-side
- Filter/search within timeline by task name or status
- Show worker assignment per task
- Link to distributed tracing (via traceparent)
- Keyboard shortcut to copy task/workflow ID
