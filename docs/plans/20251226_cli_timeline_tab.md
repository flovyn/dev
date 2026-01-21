# Implementation Plan: CLI Workflow Execution Gantt Chart Tab

**Design document**: `.dev/docs/design/20251226_cli-workflow-execution-gantt-chart.md`

## Overview

Add a "Timeline" tab to the workflow detail panel in the Flovyn CLI TUI. This tab displays a Gantt chart visualization showing the workflow execution tree (workflow → child workflows → tasks) with real-time progress updates.

## Implementation Progress

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Data Structures and State | ✅ Complete |
| 2 | Data Loading | ✅ Complete |
| 3 | Tree Building Logic | ✅ Complete |
| 4 | Timeline Bar Rendering | ✅ Complete |
| 5 | Main Panel Rendering | ✅ Complete |
| 6 | Keyboard Controls | ⚠️ Broken - shortcuts not working |
| 7 | Animation Support | ✅ Complete |
| 8 | SSE Streaming Integration | ✅ Complete |
| 9 | Error Handling and Edge Cases | ✅ Complete |
| 10 | Layout Integration | ✅ Complete |
| 11 | Testing | ✅ Complete (41 unit + 11 integration tests) |

## Known Issues (To Fix)

### 🔴 Keyboard Shortcuts Not Working

**Status**: Timeline tab keyboard shortcuts are not responding. This regression occurred during the refactoring to implement the Keybinding Table + Action Dispatch pattern.

**Symptoms**:
- Timeline-specific keys (j/k, h/l, space, +/-, 0, f) do not work when in Timeline tab
- Global shortcuts (q, ?, r) may also be affected

**Root Cause Analysis Needed**:
1. Check if `find_action()` in `keybindings.rs` is correctly matching Timeline-specific bindings
2. Verify `Context` is correctly set with `panel`, `view_mode`, and `detail_tab`
3. Check that `Action` variants are handled in the main event loop in `app.rs`
4. Verify Timeline tab keybindings have correct constraints (`.in_panel()`, `.in_tab()`, `.in_view()`)

**Files to Investigate**:
- `flovyn-server/cli/src/tui/app.rs` - Event loop handling, context construction
- `flovyn-server/cli/src/tui/keybindings.rs` - Keybinding definitions and matching logic

**Testing Approach**:
1. Add debug logging to `find_action()` to see what context is being passed
2. Add debug logging to see which keybindings match (or don't match)
3. Step through with manual testing: press 'j' in Timeline tab, trace the code path

**Workaround**: None currently - Timeline tab is view-only until fixed.

### Files Created
- `flovyn-server/cli/src/tui/timeline/mod.rs` - Module exports
- `flovyn-server/cli/src/tui/timeline/tree.rs` - ExecutionNode, NodeType, ExecutionStatus
- `flovyn-server/cli/src/tui/timeline/state.rs` - TimelineState
- `flovyn-server/cli/src/tui/timeline/builder.rs` - TimelineData, build_execution_tree
- `flovyn-server/cli/src/tui/timeline/bar.rs` - Bar rendering functions
- `flovyn-server/cli/src/tui/panels/timeline.rs` - Timeline tab panel rendering

### Files Modified
- `flovyn-server/cli/src/tui/mod.rs` - Added timeline module export
- `flovyn-server/cli/src/tui/app.rs` - Added DetailTab::Timeline, TimelineState, keyboard handlers, SSE streaming
- `flovyn-server/cli/src/tui/panels/mod.rs` - Added timeline panel exports
- `flovyn-server/cli/src/tui/panels/detail.rs` - Added Timeline case
- `flovyn-server/cli/src/tui/panels/task_detail.rs` - Added "not available" message

### Remaining Work
1. **Timer Visualization**: Parse timer events from workflow events (optional enhancement)

## Current State Analysis

**Existing TUI Structure:**
- `flovyn-server/cli/src/tui/app.rs` - App state with `DetailTab` enum (Overview, Events, Logs, Actions)
- `flovyn-server/cli/src/tui/panels/detail.rs` - Workflow detail panel with tab rendering
- `flovyn-server/cli/src/tui/layout.rs` - Layout rendering including tab bar
- Tabs switch via keyboard shortcuts 1-4 and Tab/Shift+Tab

**Available APIs (REST Client):**
- `get_workflow()` - Fetch workflow execution details
- `get_workflow_events()` - Fetch workflow event history
- `get_workflow_tasks()` - Fetch tasks for a workflow ✓
- `get_workflow_children()` - Fetch child workflows ✓
- `stream_workflow()` - SSE streaming (unused in TUI currently)

**Dependencies:** ratatui 0.29, crossterm 0.28 - sufficient for Gantt chart rendering.

## TODO List

### Phase 1: Data Structures and State

- [ ] **1.1** Add `DetailTab::Timeline` variant to `DetailTab` enum in `app.rs`
- [ ] **1.2** Add tab name "Timeline" and keybinding `5` to `DetailTab::name()` and `DetailTab::all()`
- [ ] **1.3** Create `flovyn-server/cli/src/tui/timeline/mod.rs` module with re-exports
- [ ] **1.4** Create `flovyn-server/cli/src/tui/timeline/tree.rs` with `ExecutionNode` and `NodeType` structs:
  ```rust
  struct ExecutionNode {
      id: Uuid,
      kind: String,           // workflow kind or task type
      node_type: NodeType,    // Workflow, Task, Timer, TaskGroup
      status: ExecutionStatus,
      started_at: Option<DateTime<Utc>>,
      completed_at: Option<DateTime<Utc>>,
      progress: Option<f64>,  // 0.0-1.0 for tasks with progress
      retry_count: u32,
      children: Vec<ExecutionNode>,
      collapsed: bool,        // For collapsible groups
  }

  enum NodeType {
      Workflow,
      Task,
      Timer,
      TaskGroup,  // For repeated task executions (loops)
  }

  enum ExecutionStatus {
      Pending,
      Running,
      Completed,
      Failed,
      Cancelled,
      Waiting,  // For timers and promises
  }
  ```
- [ ] **1.5** Create `TimelineState` struct in `flovyn-server/cli/src/tui/timeline/state.rs`:
  ```rust
  struct TimelineState {
      root: Option<ExecutionNode>,

      // Vertical scroll (tree rows)
      scroll_offset_rows: usize,
      selected_row: usize,

      // Horizontal scroll (timeline)
      scroll_offset_seconds: i64,
      timeline_scale: f64,     // seconds per character

      // Animation
      animation_tick: u8,      // 0-7 for spinner
      last_animation_frame: Instant,

      // Data loading
      is_loading: bool,
      error: Option<String>,

      // Follow mode (SSE streaming)
      follow_mode: bool,
  }
  ```
- [ ] **1.6** Add `timeline_state: TimelineState` field to `App` struct in `app.rs`
- [ ] **1.7** Initialize `TimelineState::default()` in `App::new()`

### Phase 2: Data Loading

- [ ] **2.1** Add `AppMessage::TimelineDataLoaded(Box<Result<TimelineData, String>>)` variant
- [ ] **2.2** Add `AppMessage::TimelineLoadError(String)` variant
- [ ] **2.3** Create `TimelineData` struct to hold loaded data:
  ```rust
  struct TimelineData {
      workflow: WorkflowExecutionResponse,
      tasks: Vec<WorkflowTaskResponse>,
      children: Vec<WorkflowExecutionResponse>,
      child_data: HashMap<Uuid, TimelineData>,  // Recursive for child workflows
  }
  ```
- [ ] **2.4** Create `spawn_load_timeline_data()` function in `app.rs`:
  - Fetch workflow details
  - Fetch workflow tasks via `get_workflow_tasks()`
  - Fetch child workflows via `get_workflow_children()`
  - Recursively fetch data for each child (with depth limit of 5)
  - Send `TimelineDataLoaded` message when complete
- [ ] **2.5** Add handler for `TimelineDataLoaded` in main event loop:
  - Build `ExecutionNode` tree from loaded data
  - Set `timeline_state.root`
  - Clear loading state
- [ ] **2.6** Trigger timeline data load when:
  - Switching to Timeline tab (key `5`)
  - Selecting a different workflow while on Timeline tab
  - Refresh triggered (key `r`)

### Phase 3: Tree Building Logic

- [ ] **3.1** Create `flovyn-server/cli/src/tui/timeline/builder.rs` with `build_execution_tree()` function:
  - Takes `TimelineData` as input
  - Returns `ExecutionNode` tree
- [ ] **3.2** Implement task grouping for repeated executions (loops):
  - Group tasks by `task_type`
  - If multiple executions exist, create `TaskGroup` parent node
  - Index children as `[0]`, `[1]`, `[2]`, etc.
  - Sort by `created_at` within group
- [ ] **3.3** Implement parallel task detection:
  - Tasks that overlap in time are marked as parallel
  - Used for display hints (optional `╠═`/`╚═` connectors)
- [ ] **3.4** Implement child ordering:
  - Sort children (tasks + child workflows) by `started_at` or `created_at`
  - Maintains execution order in tree
- [ ] **3.5** Implement `ExecutionNode::flatten_visible()` method:
  - Returns flat list of visible nodes for rendering
  - Respects collapsed state
  - Returns `(depth, &ExecutionNode)` tuples

### Phase 4: Timeline Bar Rendering

- [ ] **4.1** Create `flovyn-server/cli/src/tui/timeline/bar.rs` with bar rendering functions
- [ ] **4.2** Implement `calculate_bar_position()`:
  - Input: node start/end times, workflow start time, scale, viewport offset
  - Output: (bar_start_col, bar_width) tuple
- [ ] **4.3** Implement `render_bar_spans()`:
  - Generate `Span` elements for the bar based on status:
    - Completed: `████` green
    - Running: `▓▓▓▓` cyan with growing animation
    - Pending: empty (no bar)
    - Failed: `████` red
    - Cancelled: `░░░░` dimmed
    - Timer: `····` dotted yellow
    - Waiting: `▒▒▒▒` pattern
- [ ] **4.4** Implement progress indicator for running tasks with progress:
  - Show partial fill based on `progress` field (0.0-1.0)
- [ ] **4.5** Implement time axis labels rendering:
  - Show `0s`, `30s`, `60s`, etc. based on scale
  - Adapt to viewport width

### Phase 5: Main Panel Rendering

- [ ] **5.1** Create `flovyn-server/cli/src/tui/panels/timeline.rs` for timeline tab rendering
- [ ] **5.2** Implement `render_timeline_tab()` function:
  - Split area into tree column (fixed ~35 chars) and timeline column (remaining)
  - Handle empty/loading states
- [ ] **5.3** Implement tree column rendering:
  - Show hierarchy with `├─`, `└─`, `│`, `▼`/`▶` connectors
  - Truncate long names with ellipsis
  - Show status icon: `✓`, `⠋`, `○`, `✗`, `⊘`, `⧗`, `⏸`
  - Highlight selected row
- [ ] **5.4** Implement timeline column rendering:
  - Render timeline header with time markers
  - Render bar for each visible node
  - Show scroll indicators `◀`/`▶` when content extends beyond viewport
- [ ] **5.5** Implement selected row details section:
  - Show at bottom when a row is selected
  - Display: ID, status, duration, worker, timestamps
  - Show keyboard hints: `[Enter] Logs  [i] Input/Output  [Esc] Dismiss`
- [ ] **5.6** Implement legend rendering:
  - Show status icons and their meanings
  - Position at bottom of panel
- [ ] **5.7** Add `render_timeline_tab` call to `detail.rs` for `DetailTab::Timeline` case

### Phase 6: Keyboard Controls

- [ ] **6.1** Add keybinding `5` to switch to Timeline tab in main event handler
- [ ] **6.2** Add Timeline-specific key handlers in app event loop:
  - `↑`/`↓` or `j`/`k` - Move selection in tree (vertical scroll)
  - `←`/`→` or `h`/`l` - Scroll timeline horizontally
  - `Space` - Expand/collapse selected node (child workflows, task groups)
  - `+`/`-` - Zoom timeline in/out (adjust scale)
  - `0` - Reset zoom to auto-fit
  - `Home` - Jump to timeline start (t=0)
  - `End` - Jump to current time / end
  - `f` - Toggle follow mode (SSE streaming)
  - `PgUp`/`PgDn` - Scroll tree by page
- [ ] **6.3** Implement auto-scroll to keep selected row visible
- [ ] **6.4** Add `Enter` key to jump to Logs tab filtered to selected task (if on task row)
- [ ] **6.5** Add `i` key to show input/output modal for selected node

### Phase 7: Animation Support

- [ ] **7.1** Add animation tick to main event loop:
  - When Timeline tab is active, tick every 100ms
  - Update `timeline_state.animation_tick` (cycles 0-7)
- [ ] **7.2** Implement spinner animation for running tasks:
  - Cycle through: `⠋`, `⠙`, `⠹`, `⠸`, `⠼`, `⠴`, `⠦`, `⠧`
  - Select character based on `animation_tick`
- [ ] **7.3** Implement growing bar animation for running tasks:
  - Recalculate bar width based on elapsed time since start
  - Uses current time in render pass

### Phase 8: SSE Streaming Integration (Follow Mode)

- [ ] **8.1** Add `AppMessage::TimelineStreamEvent(StreamEvent)` variant
- [ ] **8.2** Add `AppMessage::TimelineStreamError(String)` variant
- [ ] **8.3** Create `spawn_timeline_stream()` function:
  - Uses existing `client.stream_workflow()` method
  - Sends `TimelineStreamEvent` messages on events
  - Handles disconnection/reconnection
- [ ] **8.4** Add handler for `TimelineStreamEvent`:
  - Update node status on state changes
  - Update progress for running tasks
  - Add new tasks/child workflows as they appear
- [ ] **8.5** Add `● LIVE` indicator in panel header when follow mode is active
- [ ] **8.6** Auto-enable follow mode for RUNNING workflows, disable for completed

### Phase 9: Error Handling and Edge Cases

- [ ] **9.1** Handle timeline data load failure:
  - Show "Failed to load timeline" with retry hint (`r` to refresh)
- [ ] **9.2** Handle child workflow fetch failure:
  - Show parent workflow with `[children unavailable]` indicator
  - Allow partial rendering
- [ ] **9.3** Handle empty workflow (no tasks yet):
  - Show workflow bar only with "(no tasks scheduled yet)" message
- [ ] **9.4** Handle deep nesting beyond max depth:
  - Show `▶ child-workflow [+]` with "expand to load" indicator
  - Press Enter to load children on demand
- [ ] **9.5** Handle very long workflows:
  - Time-based windowing in timeline view
  - Show position indicator relative to total duration

### Phase 10: Layout Integration

- [ ] **10.1** Ensure Timeline tab works in both horizontal and vertical layouts
- [ ] **10.2** Handle narrow terminal width:
  - Compress tree column names
  - Hide legend if too narrow
  - Show minimum width warning if < 80 cols
- [ ] **10.3** Add timeline viewport to terminal resize handler:
  - Recalculate visible rows and timeline width on resize

### Phase 11: Testing

- [ ] **11.1** Add unit tests for `ExecutionNode` tree building
- [ ] **11.2** Add unit tests for bar position calculation
- [ ] **11.3** Add unit tests for task grouping logic
- [ ] **11.4** Add unit tests for parallel detection
- [ ] **11.5** Test with various workflow scenarios:
  - Simple workflow with sequential tasks
  - Workflow with parallel tasks
  - Workflow with child workflows
  - Workflow with timers
  - Failed workflow with retries
  - Long-running workflow with many tasks

## File Changes Summary

**New files:**
- `flovyn-server/cli/src/tui/timeline/mod.rs` - Module exports
- `flovyn-server/cli/src/tui/timeline/tree.rs` - ExecutionNode data structure
- `flovyn-server/cli/src/tui/timeline/state.rs` - TimelineState
- `flovyn-server/cli/src/tui/timeline/builder.rs` - Tree building from API data
- `flovyn-server/cli/src/tui/timeline/bar.rs` - Bar rendering
- `flovyn-server/cli/src/tui/panels/timeline.rs` - Tab panel rendering

**Modified files:**
- `flovyn-server/cli/src/tui/app.rs` - Add Timeline tab, state, messages, spawn functions
- `flovyn-server/cli/src/tui/panels/detail.rs` - Add Timeline rendering dispatch
- `flovyn-server/cli/src/tui/layout.rs` - Update tab bar (add "5 Timeline")
- `flovyn-server/cli/src/tui/mod.rs` - Export timeline module

## Testing Strategy

**IMPORTANT**: Always use testcontainers for testing - do NOT use the dev environment (`docker compose` / `./dev/run.sh`). Testcontainers provide isolated, reproducible test environments that don't interfere with local development.

### Visual Testing During Development

Use testcontainers like the existing integration tests for self-contained visual verification:

```rust
// cli/tests/tui_timeline_visual.rs
use testcontainers::{clients::Cli, Container};
use testcontainers_modules::postgres::Postgres;

#[tokio::test]
async fn visual_test_timeline_tab() {
    // 1. Start testcontainers (PostgreSQL)
    let docker = Cli::default();
    let postgres = docker.run(Postgres::default());
    let db_url = format!(
        "postgres://postgres:postgres@localhost:{}/postgres",
        postgres.get_host_port_ipv4(5432)
    );

    // 2. Run migrations and start server
    let server = TestServer::start(&db_url).await;

    // 3. Create test workflow with tasks via REST client
    let client = FlovynClient::new(&server.url(), None);
    let workflow = client.trigger_workflow("test", "order-processing", json!({}), None, None, None, None).await.unwrap();

    // 4. Simulate task execution (or use test worker)
    // ... create tasks, complete some, leave some running ...

    // 5. Build App state and render timeline
    let mut app = App::new(client, "test".to_string());
    app.load_workflow_detail(workflow.id).await;
    app.detail_tab = DetailTab::Timeline;
    app.load_timeline_data().await;

    // 6. Render to test backend and snapshot
    let backend = TestBackend::new(120, 40);
    let mut terminal = Terminal::new(backend).unwrap();
    terminal.draw(|f| render_timeline_tab(f, &app, f.area())).unwrap();

    // 7. Visual inspection or snapshot assertion
    let output = buffer_to_string(terminal.backend().buffer());
    println!("{}", output);  // For manual inspection during development
    insta::assert_snapshot!(output);
}
```

Run with `cargo test visual_test_timeline --nocapture` to see rendered output.

### Ratatui Snapshot Testing

Ratatui supports capturing rendered output as text for comparison:

```rust
#[cfg(test)]
mod tests {
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    #[test]
    fn test_timeline_rendering() {
        let backend = TestBackend::new(80, 24);
        let mut terminal = Terminal::new(backend).unwrap();

        terminal.draw(|f| {
            render_timeline_tab(f, &test_app, f.area());
        }).unwrap();

        let buffer = terminal.backend().buffer();
        // Assert specific cells or snapshot the output
        insta::assert_snapshot!(buffer_to_string(buffer));
    }
}
```

Add `insta` crate for snapshot testing:
```toml
[dev-dependencies]
insta = "1.40"
```

### Integration Test Scenarios

Create test workflows programmatically and verify tree construction:

- [ ] **11.6** Test simple sequential workflow: `A → B → C`
- [ ] **11.7** Test parallel workflow: `A → [B, C, D] → E`
- [ ] **11.8** Test child workflows: parent with 2 child workflows
- [ ] **11.9** Test loop/repeated tasks: process 5 items sequentially
- [ ] **11.10** Test failed workflow with retry: task fails, retries, succeeds

## Implementation Order

Start with Phase 1-5 (basic static rendering), then add interactivity (Phase 6), animation (Phase 7), and streaming (Phase 8). Complete with error handling and testing.

Recommend implementing one test case to validate rendering after Phase 5 before continuing to interactivity.
