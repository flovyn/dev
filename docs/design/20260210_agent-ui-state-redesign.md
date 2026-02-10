# Agent UI State Redesign

## Problem

The agent workflow uses `ctx.set_raw()` to store 6 keys in workflow state:
`status`, `currentTurn`, `messages`, `currentToolCall`, `lastArtifact`, `totalUsage`.

This causes two problems:

1. **Stale state**: When the SSE stream breaks (network, server restart, proxy timeout) or the user reloads the page, the frontend falls back to reading persisted state. But the state can be stale — e.g., `currentToolCall` still contains `tool_call_start` after the tool completed, `status` still says `running` after the workflow suspended. The frontend renders "Running" forever.

2. **Redundant state**: `status` duplicates `workflow.status` (the execution status from the API). `currentToolCall` and `lastArtifact` are ephemeral events masquerading as state — they only matter during live streaming. `currentTurn` has no consumer.

## Root Cause Analysis

The agent workflow conflates two concerns:

| Concern | Purpose | Lifetime | Current mechanism |
|---------|---------|----------|-------------------|
| **Conversation history** | Reconstruct chat on page load | Permanent | `ctx.set_raw("messages", ...)` |
| **Token usage** | Display cost/usage | Permanent | `ctx.set_raw("totalUsage", ...)` |
| **Tool execution events** | Show tool start/end during streaming | Ephemeral | `ctx.set_raw("currentToolCall", ...)` |
| **File artifact events** | Notify UI of file changes | Ephemeral | `ctx.set_raw("lastArtifact", ...)` |
| **Workflow phase** | Is the agent running or waiting? | Derived | `ctx.set_raw("status", ...)` |
| **Turn counter** | Debug info | Unused | `ctx.set_raw("currentTurn", ...)` |

Ephemeral events should NOT be persisted as state. They should flow through the SSE stream and be discarded.

Derived values should NOT be stored. The workflow execution status is the source of truth.

## Data Flow: React Query as Single Source of Truth

React Query (`useGetWorkflow`) is the single source of truth for `workflow.status`. The SSE stream must update the React Query cache — not a local `useState` — to keep all consumers in sync.

```
useFlovynChatRuntime hook (in unified-run-view.tsx)
┌─────────────────────────────────────────────────────────┐
│  useGetWorkflow() ──► workflowStatus                    │
│  useGetWorkflowState() ──► initialMessages              │
│  adapter.onStatusChange ──► queryClient.setQueryData()  │
│  useLocalRuntime() ──► runtime                          │
└─────────────────────────────────────────────────────────┘
          │ re-render on cache update
          ▼
   workflowStatus, isActive, runtime → UI
```

1. **Page load**: Hook calls `useGetWorkflow()` → `workflow.status`, `useGetWorkflowState()` → messages
2. **During streaming**: Adapter fires `onStatusChange('waiting')` on `turn_complete`, etc.
3. **Cache update**: `onStatusChange` calls `queryClient.setQueryData(workflowQueryKey, old => ({...old, status: newStatus}))` — updates React Query cache in-place
4. **Re-render**: React Query notifies subscribers → hook re-renders → `workflowStatus`, `isActive`, `showCancel` update

No round trip: the hook both reads and writes React Query. `page.tsx` is a thin wrapper that just passes `orgSlug` + `runId`.

Why not `useState`? A local `useState(workflowStatus)` diverges from the React Query cache. Updating React Query directly keeps a single source of truth.

## Status Mapping Table

### Workflow execution status → UI state

Source: `WorkflowStatus` enum in `flovyn-server/crates/core/src/domain/workflow.rs`

| `workflow.status` | UI rendering | Input enabled | Cancel visible |
|-------------------|-------------|---------------|----------------|
| `PENDING` | Spinner: "Starting..." | No | No |
| `RUNNING` | Spinner: "Thinking..." or tool execution | No | Yes |
| `WAITING` | Idle, ready for input | Yes | No |
| `CANCELLING` | Spinner: "Cancelling..." | No | No |
| `COMPLETED` | Final message shown, input disabled | No | No |
| `FAILED` | Error banner with message | No | No |
| `CANCELLED` | "Cancelled" banner | No | No |

### Task execution status → UI (within RUNNING)

Source: `TaskStatus` enum in `flovyn-server/crates/core/src/domain/task.rs`

The agent workflow schedules two kinds of tasks. Each task goes through `PENDING → RUNNING → COMPLETED/FAILED/CANCELLED`.

**LLM request task (`llm-request`)**:

| Task status | SSE events available | UI rendering |
|---|---|---|
| `PENDING` | `TASK_CREATED` lifecycle | "Thinking..." spinner |
| `RUNNING` | `token`, `thinking_delta`, `tool_call_start/end` | Progressive text + tool cards |
| `COMPLETED` | `TASK_COMPLETED` lifecycle | Text complete, proceed to tool execution |
| `FAILED` | `TASK_FAILED` lifecycle | Error in conversation |

**Tool execution tasks (`run-sandbox`, `bash`, `read-file`, etc.)**:

| Task status | SSE events available | UI rendering |
|---|---|---|
| `PENDING` | `TASK_CREATED` lifecycle | Tool card "Running..." (pulsing orange) |
| `RUNNING` | `terminal` (for bash/sandbox) | Tool card "Running...", terminal output |
| `COMPLETED` | `TASK_COMPLETED` lifecycle | Tool card "Complete" (green checkmark) |
| `FAILED` | `TASK_FAILED` lifecycle | Tool card "Failed" (error) |

**Current implementation**: The tool call UI uses LLM streaming events (`tool_call_start`/`tool_call_end` from the LLM response), not task lifecycle events. Task lifecycle events (`task.created`, `task.completed`, `task.failed`) arrive as `{ kind: 'lifecycle' }` SSE events but are currently **ignored** by the adapter (`case 'lifecycle': break` in `flovyn-chat-adapter.ts:307`).

**Proposed**: Consume task lifecycle events for tool call status. The adapter already tracks the most recently started tool call via `lastToolCallUniqueId`. Since tool calls execute sequentially, task lifecycle events for non-`llm-request` tasks map to the last started tool call.

| Lifecycle event | Task kind | Adapter action |
|---|---|---|
| `task.completed` | tool task | Set synthetic `result` on last tool call → "Complete" |
| `task.failed` | tool task | Set `result` + `isError` on last tool call → "Failed" with error |
| `task.failed` | `llm-request` | Show error immediately (e.g., LLM timeout) |
| `task.created` | any | No action (tool card already shown from `tool_call_start`) |

Benefits: tool cards transition individually (not all at once on `turn_complete`), task failures surface server error details immediately, more resilient if agent crashes mid-processing.

Limitation: Sequential correlation assumes one active tool execution at a time. For future parallel tool execution, robust correlation would require passing `toolCallId` in task metadata (`TaskExecution.metadata` exists but isn't wired through the `ScheduleTaskCommand` gRPC path — see Non-Goals).

### SSE stream events → progressive UI updates (during RUNNING)

These events drive the UI **within** a single RUNNING phase. They are ephemeral — not persisted.

| SSE event | Source | UI transition |
|-----------|--------|--------------|
| `token` | LLM streaming | Append text to assistant message |
| `thinking_delta` | LLM streaming | Append to reasoning block |
| `tool_call_start` | LLM streaming | Add tool card with "Running" indicator |
| `tool_call_end` | LLM streaming | Update tool card arguments |
| `terminal` | Tool task streaming | Forward to terminal viewer |
| `TASK_CREATED` | Task lifecycle | (currently ignored) |
| `TASK_COMPLETED` | Task lifecycle | (currently ignored) |
| `TASK_FAILED` | Task lifecycle | (currently ignored) |
| `WORKFLOW_SUSPENDED` | Workflow lifecycle | → `turn_complete`: stop spinner, enable input |
| `WORKFLOW_COMPLETED` | Workflow lifecycle | → `workflow_done`: final state |
| `WORKFLOW_FAILED` | Workflow lifecycle | → `workflow_done`: error state |
| `stream_error` | SSE transport | Show error, attempt reconnection |

### Tool call status resolution (from multiple sources)

The tool call UI must work in three scenarios: live streaming, page reload, and SSE reconnection.

| Scenario | How tool status is determined |
|----------|------------------------------|
| **Live streaming** | `tool_call_start` → Running, `task.completed` → Complete, `task.failed` → Failed. Fallback: `turn_complete` marks all remaining as Complete |
| **Page reload** | Tool has a `result` attached in messages → Complete. No result → the workflow is WAITING/COMPLETED so it must be complete too |
| **SSE reconnection** | Fallback to state API, same as page reload |

**Key insight**: On page reload, if `workflow.status` is `WAITING` or terminal, ALL tool calls in persisted messages are complete. There is no scenario where a page-loaded tool call should show "Running".

## Proposed Changes

### 1. Remove redundant state keys from agent workflow

**Remove entirely:**
- `status` — use `workflow.status` instead
- `currentTurn` — no consumer
- `currentToolCall` — already flows through SSE stream events (tool_call_start/end go through the stream subscriber, not through state)
- `lastArtifact` — should be an SSE event, not state

**Keep:**
- `messages` — the conversation history, needed for page reload
- `totalUsage` — useful for displaying cost

After this change, `agent.rs` goes from 10 `ctx.set_raw()` calls to 4 (only `messages` and `totalUsage`).

### 2. Fix page-reload tool call rendering

In `ToolFallbackPart` (thread.tsx), the current default is:
```typescript
const statusType = status?.type ?? 'running'; // BUG: defaults to running
```

Fix: when a tool call has a `result`, it's complete regardless of `status`:
```typescript
const hasResult = result !== undefined && result !== null;
const statusType = hasResult ? 'complete' : (status?.type ?? 'running');
```

This is the minimal fix. No plumbing needed — the information is already available.

### 3. Add HTTP client timeouts (already done)

`connect_timeout(30s)` + `read_timeout(60s)` on both LLM providers catches connection hangs and silent servers. The task executor's 300s timeout remains the backstop.

## Verification

### What `currentToolCall` is actually used for

Before removing `currentToolCall` from state, verify it's not consumed on page reload:

1. **During live streaming**: `tool_call_start` and `tool_call_end` events reach the frontend through the SSE stream (via the stream subscriber, not via STATE_SET lifecycle events). The adapter creates tool-call content parts from these events directly. `currentToolCall` state is NOT read by the adapter.

2. **On page reload**: The `toThreadMessages()` function reads `state.messages` to reconstruct tool calls. It attaches `result` from `toolResult` messages. It does NOT read `state.currentToolCall`.

3. **Conclusion**: `currentToolCall` in workflow state is write-only from the frontend's perspective. Removing it has no impact on functionality.

### What `status` is actually used for

1. **During live streaming**: The adapter yields `status: { type: 'running' }` when the stream starts, and `status: { type: 'complete' }` on `turn_complete`. It does NOT read `state.status`.

2. **On page reload**: The page reads `workflow.status` (not `state.status`) to determine if the workflow is active. `state.status` is not used.

3. **Conclusion**: `state.status` is write-only. Removing it has no impact.

## Non-Goals

- Cancellation of individual tasks (requires server-side changes, separate design)
- Automatic model fallback on LLM timeout (LiteLLM-style `stream_timeout`)
- SSE reconnection improvements (the existing retry + fallback mechanism is adequate)
- Metadata propagation through `ScheduleTaskCommand` gRPC path (proto + SDK + server changes for `toolCallId` correlation — needed for future parallel tool execution, but sequential correlation is sufficient for now)
