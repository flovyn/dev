# Reference: Agent UI Data Architecture

**Date**: 2026-02-09 (updated 2026-02-10)
**Status**: Reference
**Related**: [Agent UI State Redesign](../design/20260210_agent-ui-state-redesign.md)

---

## Summary

The agent UI derives its state from two sources: **workflow execution status** (durable, server-managed) and **SSE stream events** (ephemeral, real-time). Workflow status is the source of truth for what the UI should display. SSE events provide progressive updates within a single RUNNING phase.

---

## Source of Truth: Workflow Execution Status

The server manages the workflow lifecycle through a state machine. The frontend reads `workflow.status` to determine what to render.

Source: `WorkflowStatus` enum in `flovyn-server/crates/core/src/domain/workflow.rs`

```
PENDING ──→ RUNNING ──→ WAITING ──→ RUNNING ──→ ... ──→ COMPLETED
                │                                         ↑
                ├──→ CANCELLING ──→ CANCELLED              │
                └──→ FAILED ──────────────────────────────┘
```

| `workflow.status` | UI rendering | Input enabled | Cancel visible |
|-------------------|-------------|---------------|----------------|
| `PENDING` | Spinner: "Starting..." | No | No |
| `RUNNING` | Spinner: "Thinking..." or tool execution | No | Yes |
| `WAITING` | Idle, ready for input | Yes | No |
| `CANCELLING` | Spinner: "Cancelling..." | No | No |
| `COMPLETED` | Final message shown, input disabled | No | No |
| `FAILED` | Error banner with message | No | No |
| `CANCELLED` | "Cancelled" banner | No | No |

**Key rule**: When `workflow.status` is `WAITING` or terminal (`COMPLETED`/`FAILED`/`CANCELLED`), ALL tool calls in the conversation are complete. No tool call loaded from persisted state should ever show "Running".

---

## Former State Keys — All Write-Only Except `messages`

The agent workflow writes 6 keys via `ctx.set_raw()`. Only `messages` is read by the frontend. The rest are dead writes that can be removed with zero UI changes.

| State key | Written by agent | Read by frontend? | Replacement |
|-----------|-----------------|-------------------|-------------|
| `messages` | Yes | **Yes** (page load, SSE fallback) | Keep |
| `totalUsage` | Yes | No (not displayed yet) | Keep for future use |
| `status` | Yes | No | `workflow.status` from REST API |
| `currentToolCall` | Yes | No | SSE events (live), `messages` (reload) |
| `lastArtifact` | Yes | No | Not consumed anywhere |
| `currentTurn` | Yes | No | Not consumed anywhere |

## Two Data Layers

### Layer 1: Durable State (survives page reload)

| Data | Source | Persistence | Used for |
|------|--------|-------------|----------|
| Workflow status | `workflow.status` from REST API | DB (workflow_execution table) | UI chrome: spinners, input, cancel |
| Conversation history | `state.messages` via `ctx.set_raw()` | DB (workflow_event table, STATE_SET) | Reconstruct chat on page load |
| Lifecycle events | WORKFLOW_SUSPENDED, COMPLETED, FAILED | DB (workflow_event table) | Status transitions |

### Layer 2: Ephemeral Events (live streaming only)

| Data | Source | Persistence | Used for |
|------|--------|-------------|----------|
| LLM text deltas | `ctx.stream_token()` → SSE `token` | None | Progressive text rendering |
| Tool call start/end | `ctx.stream_data_value()` → SSE `data` | None | Tool execution UI during streaming |
| Thinking deltas | `ctx.stream_data_value()` → SSE `data` | None | Extended thinking UI |
| Terminal output | `ctx.stream_data_value()` → SSE `data` | None | Bash output viewer |

**Design principle**: Ephemeral events drive the UI *within* a RUNNING phase. They are discarded after the phase ends. On page reload, the UI reconstructs entirely from durable state.

---

## Data Flow

```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │  agent-server (worker process)                                          │
 │                                                                         │
 │  AgentWorkflow                     LLM Request Task                     │
 │  ├─ ctx.set_raw("messages", [...]) ├─ ctx.stream_token("Hello")         │
 │  ├─ ctx.set_raw("totalUsage", ...) ├─ ctx.stream_data_value(tool_call)  │
 │  └─ ctx.wait_for_signal(...)       └─ ctx.stream_data_value(thinking)   │
 │         │                                │                              │
 │         │ gRPC: SubmitWorkflowCommands   │ gRPC: StreamTaskData         │
 └─────────┼────────────────────────────────┼──────────────────────────────┘
           │                                │
           ▼                                ▼
 ┌──────────────────────────────────────────────────────────────────────────┐
 │  flovyn-server                                                          │
 │                                                                         │
 │  WorkflowDispatch handler          TaskExecution handler                │
 │  ├─ SetState cmd                   ├─ StreamTaskData RPC                │
 │  │  → WorkflowEvent(STATE_SET)     │  → StreamEvent { type, payload }   │
 │  │  → persisted to DB ✓            │  → stream_publisher.publish()      │
 │  │  → NOT published to stream ✗    │  → ephemeral, NOT persisted ✗      │
 │  │                                 │                                    │
 │  ├─ Lifecycle events               │                                    │
 │  │  → WORKFLOW_SUSPENDED           │                                    │
 │  │  → WORKFLOW_COMPLETED/FAILED    │                                    │
 │  │  → stream_publisher.publish()   │                                    │
 │  │  → event_publisher.publish()    │                                    │
 │  │                                 │                                    │
 │  └─ get_current_state()            │                                    │
 │     → replays STATE_SET events     │                                    │
 │     → returns { messages, totalUsage }                                  │
 │                                    │                                    │
 │            REST API                │      SSE Endpoint                  │
 │  GET .../state → state map         │  GET .../stream/consolidated       │
 │  GET .../      → workflow.status   │  ├─ stream_subscriber (tokens,     │
 │                                    │  │  tool_calls, data)              │
 │                                    │  └─ event_subscriber (lifecycle)   │
 └────────────┬─────────────────────────────────────┬──────────────────────┘
              │                                     │
              ▼                                     ▼
 ┌──────────────────────────────────────────────────────────────────────────┐
 │  flovyn-app (Next.js frontend)                                          │
 │                                                                         │
 │  Page Load (durable)              Live Streaming (ephemeral)            │
 │  [runId]/page.tsx                 chat-stream.ts → chat-adapter.ts      │
 │  ├─ GET workflow → status         ├─ SSE EventSource                    │
 │  ├─ GET state → messages          ├─ parse → ChatStreamEvent            │
 │  ├─ toThreadMessages()            ├─ yield → ChatModelRunResult         │
 │  └─ UI driven by workflow.status  └─ progressive updates within RUNNING │
 └──────────────────────────────────────────────────────────────────────────┘
```

---

## Task Execution Status (within RUNNING)

Source: `TaskStatus` enum in `flovyn-server/crates/core/src/domain/task.rs`: `Pending`, `Running`, `Completed`, `Failed`, `Cancelled`

The agent workflow schedules two kinds of tasks:

**`llm-request` task** — streams tokens, tool_call intents, thinking deltas:

| Task status | SSE events | UI rendering |
|---|---|---|
| `PENDING` | `TASK_CREATED` lifecycle | "Thinking..." spinner |
| `RUNNING` | `token`, `thinking_delta`, `tool_call_start/end` | Progressive text + tool cards |
| `COMPLETED` | `TASK_COMPLETED` lifecycle | Text complete |
| `FAILED` | `TASK_FAILED` lifecycle | Error in conversation |

**Tool tasks** (`run-sandbox`, `bash`, `read-file`, etc.) — execute tools, return results:

| Task status | SSE events | UI rendering |
|---|---|---|
| `PENDING`/`RUNNING` | `TASK_CREATED`, `terminal` (bash/sandbox) | Tool card "Running..." |
| `COMPLETED` | `TASK_COMPLETED` lifecycle | Tool card "Complete" |
| `FAILED` | `TASK_FAILED` lifecycle | Tool card "Failed" |

**Note**: Task lifecycle events (`TASK_CREATED`, `TASK_COMPLETED`, `TASK_FAILED`) are published through the SSE stream but currently ignored by the frontend adapter. Tool call UI uses the LLM streaming path (`tool_call_start`/`tool_call_end`) instead.

---

## SSE Stream Events → UI Updates (during RUNNING)

| SSE event | Source | UI transition |
|-----------|--------|--------------|
| `token` | LLM streaming | Append text to assistant message |
| `thinking_delta` | LLM streaming | Append to reasoning block |
| `tool_call_start` | LLM streaming | Add tool card with "Running" indicator |
| `tool_call_end` | LLM streaming | Update tool card arguments |
| `terminal` | Tool task streaming | Forward to terminal viewer |
| `TASK_CREATED` | Task lifecycle | Currently ignored |
| `TASK_COMPLETED` | Task lifecycle | Currently ignored |
| `TASK_FAILED` | Task lifecycle | Currently ignored |
| `WORKFLOW_SUSPENDED` | Workflow lifecycle | → `turn_complete`: stop spinner, enable input |
| `WORKFLOW_COMPLETED` | Workflow lifecycle | → `workflow_done`: final state |
| `WORKFLOW_FAILED` | Workflow lifecycle | → `workflow_done`: error state |
| `stream_error` | SSE transport | Show error, attempt reconnection |

---

## Tool Call Status Resolution

Tool calls must render correctly in three scenarios:

| Scenario | How tool status is determined |
|----------|------------------------------|
| **Live streaming** | `tool_call_start` → Running, `tool_call_end` or `turn_complete` → Complete |
| **Page reload** | Tool has `result` in messages → Complete. No result + workflow is WAITING/terminal → Complete |
| **SSE reconnection** | Fallback to state API, same as page reload |

---

## Page Load Reconstruction

On page load or SSE reconnection, the frontend reconstructs entirely from durable state:

1. `GET /workflow-executions/{id}` → `workflow.status` determines UI chrome
2. `GET /workflow-executions/{id}/state` → `state.messages` reconstructs conversation
3. `toThreadMessages()` converts messages to assistant-ui format
4. If `workflow.status` is `RUNNING`, open SSE stream for live updates
5. If `workflow.status` is `WAITING`, show input field, no streaming needed

---

## Server Publish Systems

| System | Persistence | What it carries |
|--------|-------------|-----------------|
| **Event Store** (DB) | Durable | STATE_SET, lifecycle events (suspended, completed, failed) |
| **Stream Publisher** | Ephemeral (in-memory/NATS) | Tokens, tool calls, data, lifecycle events |
| **Event Publisher** | Ephemeral (in-memory/NATS) | Lifecycle events (for org-level subscribers) |

**Key constraint**: STATE_SET events are persisted but NOT streamed. Late-joining SSE clients must use the REST state API to catch up.

---

## What Is and Is Not Persisted

| Data | Persisted? | Streamed live? | Available on page reload? |
|------|:---:|:---:|:---:|
| Workflow execution status | Yes | Yes (lifecycle events) | Yes (REST API) |
| Conversation messages | Yes (STATE_SET) | No | Yes (state API) |
| Token usage | Yes (STATE_SET) | No | Yes (state API) |
| LLM text deltas | No | Yes (SSE `token`) | No (final text in messages) |
| Tool call start/end (streaming) | No | Yes (SSE `data`) | No (tools in messages) |
| Thinking deltas | No | Yes (SSE `data`) | No |
| Terminal output | No | Yes (SSE `data`) | No |

---

## Follow-Up Turn Handling

For follow-up messages in the same session:

1. Open SSE stream first (subscribe-before-signal)
2. Send `userMessage` signal via REST → workflow resumes (WAITING → PENDING → RUNNING)
3. Skip replayed events until `WORKFLOW_RESUMED` lifecycle event
4. Process new events normally from that point
