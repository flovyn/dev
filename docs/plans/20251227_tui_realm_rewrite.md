# Implementation Plan: TUI Rewrite with tui-realm

## Problem Statement

The current TUI implementation has accumulated significant complexity that makes it unreliable and difficult to maintain:

1. **Monolithic App struct** (3143 lines, ~156 fields): All state for 5 different views in a single struct
2. **Manual state management**: Cache clearing, selection tracking, and view switching scattered across functions
3. **Keybinding complexity**: 60+ actions with context-dependent routing (panel + view_mode + detail_tab + key)
4. **Hardcoded layout coupling**: Mouse handling hardcodes 35/65 split matching layout.rs
5. **No request deduplication**: Rapid clicks spawn multiple identical requests
6. **Testing difficulty**: Mocking entire App required for unit tests
7. **Timeline subsystem overengineering**: 2600+ lines across 4 files with complex SSE streaming

Each change introduces bugs because state transitions and event handling aren't encapsulated.

## Solution: tui-realm Framework

[tui-realm](https://github.com/veeso/tui-realm) (v3.3.0) is a framework built on ratatui that provides:

- **Component-based architecture**: Reusable, self-contained UI components with encapsulated state
- **Model-View-Update pattern**: Predictable state updates through explicit message passing
- **Automatic focus management**: Framework handles which component receives events
- **Subscription system**: Cross-component event routing without coupling
- **Standard component library**: Pre-built components (lists, tables, inputs) via `tui-realm-stdlib`
- **Derive macros**: Reduce boilerplate with `#[derive(MockComponent)]`

## Architecture Design

### Current vs New Structure

```
CURRENT (Monolithic)                    NEW (Component-Based)
========================                ========================
App {                                   Model {
  // 156 fields mixed together            client: ApiClient,
  workflows: Vec<...>,                    tenant: String,
  tasks: Vec<...>,                      }
  workers: Vec<...>,
  timeline_state: TimelineState,        Components:
  selected_index: usize,                  WorkflowList
  detail_tab: DetailTab,                  WorkflowDetail
  filter_text: String,                    TaskList
  ...                                     TaskDetail
}                                         WorkerList
                                          WorkerDetail
                                          TimelinePanel
                                          FilterInput
                                          HelpOverlay
```

### Core Concepts Mapping

| Current | tui-realm Equivalent |
|---------|---------------------|
| `App` struct | `Model` (minimal shared state) + Component states |
| `handle_event()` + keybindings | `Component::on()` per component |
| `dispatch_action()` | Message passing between components |
| `spawn_*()` async tasks | Ports for async data fetching |
| `render_*_panel()` | `MockComponent::view()` |
| `DetailTab` enum | Mounted/unmounted components |
| `ViewMode` enum | Different component sets mounted |

### Component Hierarchy

```
Application
├── HeaderBar (static: tenant, time, status)
├── MainView (focus container)
│   ├── ListPanel (left 35%)
│   │   ├── WorkflowList (when ViewMode::Workflows)
│   │   ├── TaskList (when ViewMode::Tasks)
│   │   ├── WorkerList (when ViewMode::Workers)
│   │   └── DefinitionList (when ViewMode::*Defs)
│   └── DetailPanel (right 65%)
│       ├── TabBar (Overview, Events, Logs, Actions, Timeline)
│       ├── OverviewTab
│       ├── EventsTab
│       ├── LogsTab
│       ├── ActionsTab
│       └── TimelineTab
│           ├── TreeColumn
│           └── GanttColumn
├── FilterBar (conditional, when filtering)
├── HelpOverlay (conditional, modal)
└── Footer (keybinding hints, status messages)
```

### Message Types

```rust
/// Component IDs
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Id {
    Header,
    WorkflowList,
    TaskList,
    WorkerList,
    DefinitionList,
    DetailTabBar,
    OverviewTab,
    EventsTab,
    LogsTab,
    ActionsTab,
    TimelineTree,
    TimelineGantt,
    FilterInput,
    HelpOverlay,
    Footer,
}

/// Application messages
#[derive(Debug, Clone, PartialEq)]
pub enum Msg {
    // Navigation
    SwitchView(ViewMode),
    SelectItem(usize),
    FocusPanel(Panel),
    SwitchTab(DetailTab),

    // Data operations
    RefreshList,
    LoadDetail(Uuid),
    DataLoaded(DataPayload),
    DataError(String),

    // Actions
    CancelWorkflow(Uuid),
    RetryTask(Uuid),
    ActionCompleted(String),

    // Timeline
    TimelineScroll { direction: Direction, amount: i32 },
    TimelineZoom(f64),
    TimelineToggleNode(Uuid),
    TimelineStreamEvent(StreamEvent),

    // UI
    ShowHelp,
    HideHelp,
    StartFilter,
    ApplyFilter(String),
    ClearFilter,

    // Application
    Quit,
    Tick,
    None,
}
```

### Async Data Loading with Ports

```rust
/// Port for async API operations
pub struct ApiPort {
    rx: mpsc::Receiver<UserEvent>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum UserEvent {
    WorkflowsLoaded(Vec<WorkflowSummary>),
    WorkflowDetailLoaded(WorkflowDetail),
    TasksLoaded(Vec<TaskSummary>),
    TimelineData(TimelineData),
    StreamEvent(StreamEvent),
    Error(String),
}

impl Poll<UserEvent> for ApiPort {
    fn poll(&mut self) -> ListenerResult<Option<Event<UserEvent>>> {
        match self.rx.try_recv() {
            Ok(event) => Ok(Some(Event::User(event))),
            Err(TryRecvError::Empty) => Ok(None),
            Err(TryRecvError::Disconnected) => Err(ListenerError::...),
        }
    }
}
```

## File Structure

```
cli/src/tui/
├── mod.rs                      # Module exports, run_tui() entry point
├── app.rs                      # Model, Application setup, main loop (< 300 lines)
├── ids.rs                      # Component Id enum
├── msg.rs                      # Msg enum and UserEvent
├── ports/
│   ├── mod.rs
│   └── api_port.rs             # Async API port
├── components/
│   ├── mod.rs
│   ├── header.rs               # Header bar
│   ├── footer.rs               # Footer with hints/status
│   ├── filter.rs               # Filter input component
│   ├── help.rs                 # Help overlay modal
│   ├── list/
│   │   ├── mod.rs
│   │   ├── workflow_list.rs    # Workflow list component
│   │   ├── task_list.rs        # Task list component
│   │   ├── worker_list.rs      # Worker list component
│   │   └── definition_list.rs  # Definition list component
│   ├── detail/
│   │   ├── mod.rs
│   │   ├── tab_bar.rs          # Tab selector component
│   │   ├── overview.rs         # Overview tab
│   │   ├── events.rs           # Events tab
│   │   ├── logs.rs             # Logs tab
│   │   └── actions.rs          # Actions tab
│   └── timeline/
│       ├── mod.rs              # Module exports
│       ├── tree.rs             # ExecutionNode, ExecutionStatus, NodeType
│       ├── builder.rs          # build_execution_tree(), TimelineData
│       └── timeline_tab.rs     # Combined tree + gantt view component
└── theme.rs                    # Colors, styles, constants
```

## TODO List

### Phase 1: Project Setup and Dependencies

- [x] **1.1** Add tui-realm dependencies to `flovyn-server/cli/Cargo.toml`:
  ```toml
  tuirealm = "3.3"
  tui-realm-stdlib = "3.1"
  ```
- [x] **1.2** Create new module structure under `cli/src/tui_v2/` (parallel to existing)
- [x] **1.3** Create `ids.rs` with component ID enum
- [x] **1.4** Create `msg.rs` with Msg enum and UserEvent enum
- [x] **1.5** Create `theme.rs` with color constants and style helpers
- [x] **1.6** Create minimal `app.rs` with Model struct and Application setup

### Phase 2: Core Infrastructure

- [x] **2.1** Implement `ApiPort` for async data fetching
- [x] **2.2** Create `ApiClient` wrapper that spawns async tasks and sends to port
- [x] **2.3** Implement main event loop skeleton with tick handling
- [x] **2.4** Add terminal setup/teardown (reuse existing crossterm config)
- [x] **2.5** Implement Model::update() stub with Msg matching

### Phase 3: Basic Components (No Data)

- [x] **3.1** Create `HeaderComponent` - static header bar with tenant/status
- [x] **3.2** Create `FooterComponent` - keybinding hints based on context
- [x] **3.3** Create `HelpOverlay` component - modal help display
- [x] **3.4** Create `FilterInput` component - text input for filtering
- [x] **3.5** Test: Render header + footer, verify layout and styling

### Phase 4: List Components

- [x] **4.1** Create `WorkflowList` component with workflow rendering
- [x] **4.2** Create `TaskList` with task-specific rendering
- [x] **4.3** Create `WorkerList` with worker-specific rendering
- [x] **4.4** Create `WorkflowDefList` and `TaskDefList` for workflow/task definitions
- [x] **4.5** Implement view mode switching (mount/unmount appropriate list)
- [x] **4.6** Connect list selection to detail loading via Msg
- [x] **4.7** Test: Load workflows, navigate with j/k, verify selection highlighting

### Phase 5: Detail Tab Components

- [x] **5.1** Create `TabBar` component for tab switching
- [x] **5.2** Create `OverviewTab` component with workflow/task summary
- [x] **5.3** Create `EventsTab` component with event list
- [x] **5.4** Create `LogsTab` component (placeholder)
- [x] **5.5** Create `ActionsTab` component with cancel workflow support
- [x] **5.6** Implement tab switching via TabBar messages
- [x] **5.7** Test: Switch tabs with 1-5 keys, verify content updates

### Phase 6: Focus and Navigation

- [x] **6.1** Configure focus chain: List <-> Detail panels (partial - Tab key switches)
- [x] **6.2** Add Tab/Shift+Tab for panel focus switching
- [x] **6.3** Add arrow key navigation within focused component
- [x] **6.4** Add global subscriptions for quit (q), help (?), refresh (r)
- [x] **6.5** Test: Navigate between panels, verify focus indicators

### Phase 7: Actions and Workflows

- [x] **7.1** Implement workflow cancel action flow
- [x] **7.2** Implement workflow retry action flow
- [x] **7.3** Add action confirmation prompts
- [x] **7.4** Add action result status display in ActionsTab
- [ ] **7.5** Test: Cancel a workflow, verify state updates

### Phase 8: Filter System

- [x] **8.1** Connect FilterInput to list components via subscription
- [x] **8.2** Implement filter activation ('/' key globally subscribed)
- [x] **8.3** Implement filter application on Enter
- [x] **8.4** Implement filter clear on Escape
- [ ] **8.5** Test: Filter workflows by name, verify filtered list

### Phase 9: Timeline Migration

- [x] **9.1** Create local tree module (`tree.rs`, `builder.rs`) with `ExecutionNode`, `ExecutionStatus`, `NodeType`
- [x] **9.2** Create `TimelineTab` component combining tree and gantt views
- [x] **9.3** Build proper execution tree from workflow detail, tasks, and events
  - Workflow as root node with kind name (e.g., "order-fulfillment")
  - Tasks with task_type names, grouped by type when multiple
  - Operations and timers extracted from events with names
  - Collapsible nodes with ▸/▾ indicators
- [x] **9.4** Component-local state for scrolling, zoom, selection
- [x] **9.5** Implement timeline-specific keybindings:
  - `j/k` or `↑/↓`: Navigate tree nodes
  - `h/l` or `←/→`: Horizontal scroll timeline
  - `+/-` or `=/-`: Zoom in/out
  - `0`: Reset zoom and enable auto-scale
  - `Enter/Space`: Toggle collapse on selected node
- [x] **9.6** Add `WorkflowTasksLoaded` event and `load_workflow_tasks()` API method
- [x] **9.7** Dynamic time axis with proper tick marks:
  - Tick intervals adapt to visible time range (1s, 5s, 10s, 30s, 1m, 5m, etc.)
  - Labels placed at tick marks: `0──5s──10s──15s──20s──`
  - Auto-scaling: running workflows expand timeline as time passes
  - All bars scale down proportionally when timeline expands
- [ ] **9.8** Connect SSE streaming via UserEvent port for real-time updates
- [ ] **9.9** Test: View timeline, navigate with j/k/h/l, verify animations

### Phase 10: Polish and Edge Cases

- [x] **10.1** Collapse borders between adjacent panels
- [x] **10.2** Implement mouse click handling via component positions
- [x] **10.3** Add window resize handling
- [x] **10.4** Add loading indicators during data fetch
- [x] **10.5** Add error state display for failed requests
- [x] **10.6** Add empty state messages ("No workflows found")
- [ ] **10.7** Verify all keybindings work in all contexts
- [ ] **10.8** Test: Rapid navigation, verify no duplicate requests

### Phase 11: Integration and Cleanup

- [x] **11.1** Create `dashboard-v2` command to access new TUI (via `flovyn ui2`)
- [ ] **11.2** Run full manual test suite against new TUI
- [ ] **11.3** Add snapshot tests for component rendering
- [ ] **11.4** Remove old TUI code once new version is stable
- [ ] **11.5** Update documentation

## Component Implementation Pattern

Each component follows this pattern:

```rust
use tuirealm::props::{Alignment, Color, Style, TextSpan};
use tuirealm::tui::layout::Rect;
use tuirealm::tui::widgets::{Block, Borders, List, ListItem};
use tuirealm::{
    command::{Cmd, CmdResult},
    event::{Key, KeyEvent},
    AttrValue, Attribute, Component, Event, Frame, MockComponent, Props, State,
};

use crate::tui_v2::{Id, Msg, UserEvent};

/// Props for WorkflowList
#[derive(Default)]
pub struct WorkflowListProps {
    workflows: Vec<WorkflowSummary>,
    selected: usize,
    filter: Option<String>,
}

/// WorkflowList component
pub struct WorkflowList {
    props: WorkflowListProps,
}

impl Default for WorkflowList {
    fn default() -> Self {
        Self {
            props: WorkflowListProps::default(),
        }
    }
}

impl MockComponent for WorkflowList {
    fn view(&mut self, frame: &mut Frame, area: Rect) {
        let items: Vec<ListItem> = self
            .visible_workflows()
            .enumerate()
            .map(|(i, w)| {
                let style = if i == self.props.selected {
                    Style::default().bg(Color::Blue)
                } else {
                    Style::default()
                };
                ListItem::new(format_workflow_line(w)).style(style)
            })
            .collect();

        let list = List::new(items)
            .block(Block::default().borders(Borders::ALL).title("Workflows"));
        frame.render_widget(list, area);
    }

    fn query(&self, attr: Attribute) -> Option<AttrValue> {
        match attr {
            Attribute::Value => Some(AttrValue::Usize(self.props.selected)),
            _ => None,
        }
    }

    fn attr(&mut self, attr: Attribute, value: AttrValue) {
        match attr {
            Attribute::Content => {
                if let AttrValue::Payload(p) = value {
                    // Decode workflows from payload
                }
            }
            _ => {}
        }
    }

    fn state(&self) -> State {
        State::One(StateValue::Usize(self.props.selected))
    }

    fn perform(&mut self, cmd: Cmd) -> CmdResult {
        match cmd {
            Cmd::Move(Direction::Down) => {
                if self.props.selected < self.props.workflows.len().saturating_sub(1) {
                    self.props.selected += 1;
                    CmdResult::Changed(State::One(StateValue::Usize(self.props.selected)))
                } else {
                    CmdResult::None
                }
            }
            Cmd::Move(Direction::Up) => {
                if self.props.selected > 0 {
                    self.props.selected -= 1;
                    CmdResult::Changed(State::One(StateValue::Usize(self.props.selected)))
                } else {
                    CmdResult::None
                }
            }
            Cmd::Submit => {
                // Return selected workflow for detail loading
                CmdResult::Submit(State::One(StateValue::Usize(self.props.selected)))
            }
            _ => CmdResult::None,
        }
    }
}

impl Component<Msg, UserEvent> for WorkflowList {
    fn on(&mut self, ev: Event<UserEvent>) -> Option<Msg> {
        match ev {
            Event::Keyboard(KeyEvent { code: Key::Char('j'), .. })
            | Event::Keyboard(KeyEvent { code: Key::Down, .. }) => {
                match self.perform(Cmd::Move(Direction::Down)) {
                    CmdResult::Changed(_) => Some(Msg::SelectItem(self.props.selected)),
                    _ => None,
                }
            }
            Event::Keyboard(KeyEvent { code: Key::Char('k'), .. })
            | Event::Keyboard(KeyEvent { code: Key::Up, .. }) => {
                match self.perform(Cmd::Move(Direction::Up)) {
                    CmdResult::Changed(_) => Some(Msg::SelectItem(self.props.selected)),
                    _ => None,
                }
            }
            Event::Keyboard(KeyEvent { code: Key::Enter, .. }) => {
                let selected = self.props.selected;
                if let Some(workflow) = self.props.workflows.get(selected) {
                    Some(Msg::LoadDetail(workflow.id))
                } else {
                    None
                }
            }
            Event::User(UserEvent::WorkflowsLoaded(workflows)) => {
                self.props.workflows = workflows;
                self.props.selected = 0;
                Some(Msg::None) // Trigger redraw
            }
            _ => None,
        }
    }
}
```

## Key Benefits After Migration

1. **Encapsulated state**: Each component owns its state, no 156-field mega-struct
2. **Predictable event flow**: Event → Component → Msg → Model → State update
3. **Automatic focus**: Framework handles which component receives events
4. **Testable components**: Each component can be unit tested in isolation
5. **Clear keybinding ownership**: Components define their own keys in `on()`
6. **Subscription for globals**: Quit, help, refresh work anywhere via subscriptions
7. **Simpler async**: Ports provide clean async boundary

## Migration Strategy

1. Build new TUI in `tui_v2/` parallel to existing `tui/`
2. Use feature flag to switch: `--features new-tui`
3. Migrate one view mode at a time (Workflows first)
4. Run side-by-side testing
5. Once stable, remove old code and rename `tui_v2` to `tui`

## Testing Strategy

1. **Unit tests**: Each component tested with mock events/props
2. **Snapshot tests**: Render components to TestBackend, compare output
3. **Integration tests**: Full app with testcontainers for real API

## Dependencies

```toml
[dependencies]
tuirealm = "3.3"
tui-realm-stdlib = "3.1"  # Pre-built components (lists, inputs, etc.)
```

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Learning curve for tui-realm | Start with simple components, follow examples |
| Performance regression | Profile early, tui-realm is thin wrapper |
| Timeline complexity | Migrate last, reuse existing rendering logic |
| Breaking changes in tui-realm | Pin version, framework is stable (v3.3) |
