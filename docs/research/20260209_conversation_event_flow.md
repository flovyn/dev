# Research: Conversation Event Flow

**Date**: 2026-02-09
**Status**: Research
**Related**: [AI Conversation Durability](20260128_ai_conversation_durability.md), [Execution Patterns](20260128_execution_patterns_multi_message.md)

---

## Summary

This document maps how conversation data flows from the agent workflow through the server to the frontend. There are two independent mechanisms for displaying conversations: **live streaming** (ephemeral, real-time) and **historical state reconstruction** (durable, on-demand). They use different data paths and have different characteristics.

---

## Architecture Overview

```
                    LIVE STREAMING                          HISTORICAL
                    (ephemeral)                             (durable)

 ┌──────────────────────────────────────────────────────────────────────────┐
 │  agent-server (worker process)                                          │
 │                                                                         │
 │  AgentWorkflow                     LLM Request Task                     │
 │  ├─ ctx.set_raw("messages", [...]) ├─ ctx.stream_token("Hello")         │
 │  ├─ ctx.set_raw("currentToolCall") ├─ ctx.stream_data_value(tool_call)  │
 │  ├─ ctx.set_raw("status", ...)     └─ ctx.stream_data_value(thinking)   │
 │  └─ ctx.set_raw("currentTurn", n)                                       │
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
 │  │  → event_repo.append_batch()    │  → stream_publisher.publish()      │
 │  │  → persisted to DB ✓            │  → ephemeral, NOT persisted ✗      │
 │  │  → NOT published to stream ✗    │                                    │
 │  │                                 │                                    │
 │  ├─ Lifecycle events               │                                    │
 │  │  → WORKFLOW_SUSPENDED           │                                    │
 │  │  → WORKFLOW_COMPLETED/FAILED    │                                    │
 │  │  → stream_publisher.publish()   │                                    │
 │  │  → event_publisher.publish()    │                                    │
 │  │                                 │                                    │
 │  └─ get_current_state()            │                                    │
 │     → replays STATE_SET events     │                                    │
 │     → returns final state map      │                                    │
 │                                    │                                    │
 │            REST API                │      SSE Endpoint                  │
 │  GET .../state → state map         │  GET .../stream/consolidated       │
 │                                    │  ├─ stream_subscriber (tokens,     │
 │                                    │  │  tool_calls, data)              │
 │                                    │  └─ event_subscriber (lifecycle)   │
 └────────────┬─────────────────────────────────────┬──────────────────────┘
              │                                     │
              ▼                                     ▼
 ┌──────────────────────────────────────────────────────────────────────────┐
 │  flovyn-app (Next.js frontend)                                          │
 │                                                                         │
 │  Historical Load                   Live Streaming                       │
 │  [runId]/page.tsx                  chat-stream.ts → chat-adapter.ts     │
 │  ├─ GET /state                     ├─ SSE EventSource                   │
 │  ├─ extract state.messages         ├─ parse → ChatStreamEvent           │
 │  ├─ toThreadMessages()             ├─ yield → ChatModelRunResult        │
 │  └─ pass to assistant-ui           └─ render via assistant-ui           │
 └──────────────────────────────────────────────────────────────────────────┘
```

---

## Layer 1: Agent Workflow (`agent-server`)

### State Keys (Durable — via `ctx.set_raw()`)

The agent workflow sets workflow state at key points during execution. Each call produces a `SetState` gRPC command that is persisted as a `STATE_SET` workflow event.

| State Key | Type | Set When | Purpose |
|-----------|------|----------|---------|
| `messages` | `Message[]` | After LLM response, tool result, signal consumption | Full conversation history |
| `status` | `"running"` \| `"waiting_for_input"` | Start of turn, before signal wait | Workflow lifecycle |
| `currentTurn` | `number` | Before each LLM call | Turn counter |
| `currentToolCall` | `{type, toolCall, result?}` | Before/after each tool execution | Tool execution tracking |
| `lastArtifact` | `{type, path, action}` | After write-file/edit-file tools | File modification tracking |
| `totalUsage` | `{input, output, ...}` | Before waiting for input | Token usage accumulation |

**Key insight**: `messages` contains the **complete** conversation history. It's the single source of truth for historical reconstruction.

### Streaming Events (Ephemeral — via `ctx.stream_*()`)

The `llm-request` task streams real-time events from the LLM provider. These go through a separate path (`StreamTaskData` gRPC) and are **not persisted**.

| SDK Call | StreamEventType | Payload | Frontend Event |
|----------|----------------|---------|----------------|
| `ctx.stream_token(text)` | `Token` | `{"type":"token","text":"..."}` | `{ kind: 'token' }` |
| `ctx.stream_data_value(json!({"type":"tool_call_start",...}))` | `Data` | `{"type":"tool_call_start","tool_call":{...}}` | `{ kind: 'tool_call_start' }` |
| `ctx.stream_data_value(json!({"type":"tool_call_end",...}))` | `Data` | `{"type":"tool_call_end","tool_call":{...}}` | `{ kind: 'tool_call_end' }` |
| `ctx.stream_data_value(json!({"type":"thinking_delta",...}))` | `Data` | `{"type":"thinking_delta","delta":"..."}` | `{ kind: 'thinking_delta' }` |

**Source**: `agent-server/src/tasks/llm_request.rs:119-164`

### Dual Publication of Tool Calls

Tool calls are published through **both** mechanisms:

1. **LLM streaming** (`llm_request.rs`): Real-time `tool_call_start`/`tool_call_end` streamed from the LLM provider during token generation. These reflect the LLM's **intent** to call a tool.

2. **Workflow state** (`agent.rs`): `ctx.set_raw("currentToolCall", ...)` set before/after actual tool execution. These reflect the **execution** of the tool (with result/error).

The frontend currently uses **only the streaming path** for live display. The state path exists for historical reconstruction and debugging.

---

## Layer 2: Server (`flovyn-server`)

### Two Independent Publish Systems

| System | Interface | Transport | Persistence | Scope |
|--------|-----------|-----------|-------------|-------|
| **Stream Publisher** | `StreamEventPublisher` | NATS / In-Memory broadcast | Ephemeral (replay buffer only) | Per workflow execution |
| **Event Publisher** | `EventPublisher` | NATS / In-Memory broadcast | Ephemeral | Per org + workflow |

### What Gets Published Where

| Event Source | Event Store (DB) | Stream Publisher | Event Publisher |
|-------------|:---:|:---:|:---:|
| `SetState` (STATE_SET) | Yes | **No** | No |
| `StreamTaskData` (tokens, tool_calls) | No | **Yes** | No |
| `WORKFLOW_SUSPENDED` | Yes | **Yes** | Yes |
| `WORKFLOW_COMPLETED` | Yes | **Yes** | Yes |
| `WORKFLOW_FAILED` | Yes | **Yes** | Yes |
| `TASK_CREATED` | Yes | **Yes** | Yes |
| `TASK_COMPLETED` | Yes | No | Yes |
| `TIMER_STARTED` | Yes | **Yes** | No |

**Key insight**: STATE_SET events are persisted to the event store but **never** published to the stream. This means late-subscribing SSE clients cannot see state changes — they must use the REST state API instead.

### SSE Consolidated Endpoint

`GET /api/orgs/{org}/workflow-executions/{id}/stream/consolidated`

Merges two streams into a single SSE connection:
- **Stream events** from `stream_subscriber.subscribe()` — tokens, data, lifecycle
- **Lifecycle events** from `event_subscriber.subscribe()` — workflow/task state transitions

Also merges child workflow streams (fetches child IDs from DB and subscribes to all).

**Query parameter**: `?types=token,data,error,workflow.completed,...` filters event types.

### StreamEvent Structure

```rust
pub struct StreamEvent {
    pub task_execution_id: String,
    pub workflow_execution_id: String,  // routing key for SSE subscriptions
    pub sequence: i32,
    pub event_type: StreamEventType,    // Token | Progress | Data | Error
    pub payload: String,                // JSON string
    pub timestamp_ms: i64,
}
```

### State Reconstruction (REST)

`GET /api/orgs/{org}/workflow-executions/{id}/state`

Replays all `STATE_SET` and `STATE_CLEARED` events from `workflow_event` table in sequence order:
- `STATE_SET` → upsert key in map
- `STATE_CLEARED` → remove key from map
- Returns final state: `{ messages: [...], status: "...", currentTurn: N, ... }`

**Source**: `server/src/repository/event_repository.rs:get_current_state()`

---

## Layer 3: Frontend (`flovyn-app`)

### ChatStreamEvent Types

Parsed from SSE events in `chat-stream.ts`:

| Kind | Source SSE Type | Trigger |
|------|----------------|---------|
| `token` | `event: token` | LLM text delta |
| `tool_call_start` | `event: data` | Inner `type: "tool_call_start"` |
| `tool_call_end` | `event: data` | Inner `type: "tool_call_end"` |
| `thinking_delta` | `event: data` | Inner `type: "thinking_delta"` |
| `terminal` | `event: data` | Inner `type: "terminal"` |
| `lifecycle` | `event: data` | `type: "Event"` (generic) |
| `turn_complete` | `event: data` | `WORKFLOW_SUSPENDED` + `suspendType === "SUSPEND_TYPE_SIGNAL"` |
| `workflow_done` | `event: data` | `WORKFLOW_COMPLETED` / `WORKFLOW_FAILED` / `WORKFLOW_CANCELLED` |
| `stream_error` | `event: error` | SSE error |

### Chat Adapter Consumption

`flovyn-chat-adapter.ts` bridges `ChatStreamEvent` → assistant-ui `ChatModelRunResult`:

| ChatStreamEvent | Adapter Action |
|-----------------|----------------|
| `token` | Append to current text part, yield updated content |
| `tool_call_start` | Create new tool-call part (with deduped ID), yield |
| `tool_call_end` | Update matching tool-call's arguments, yield |
| `terminal` | Forward to `onTerminalData` callback (no yield) |
| `turn_complete` | Yield with `status: { type: 'complete', reason: 'stop' }`, return |
| `workflow_done` | Yield final status (complete/error/cancelled), return |
| `stream_error` | Yield error text, return |
| `thinking_delta` | Ignored |
| `lifecycle` | Ignored |

### Follow-Up Turn Handling

For follow-up messages (same session, `turnCount > 0`):
1. Open SSE stream first (subscribe-before-signal)
2. Send `userMessage` signal via REST
3. Skip all replayed events until `WORKFLOW_RESUMED` lifecycle event
4. Process new events normally from that point

### Historical Load

`[runId]/page.tsx`:
1. `GET /workflow-executions/{id}` — metadata (status, input, timestamps)
2. `GET /workflow-executions/{id}/state` — final state map
3. Extract `state.messages` → convert via `toThreadMessages()` → pass as `initialMessages` to assistant-ui runtime

---

## Observations and Gaps

### 1. STATE_SET Not Streamed

STATE_SET events are persisted but not published to the SSE stream. This means:
- Live clients see tokens/tool_calls from the LLM streaming path
- But they don't see `messages`, `status`, `currentTurn` changes in real-time
- If an SSE client disconnects and reconnects, it cannot reconstruct the conversation from stream events alone — it must call the state API

### 2. Dual Tool Call Events are Redundant

Tool calls are emitted twice:
- **LLM streaming** (`llm_request.rs`): During LLM response generation
- **Workflow state** (`agent.rs`): During actual tool execution

The streaming path shows tool calls as they appear in the LLM response (real-time, with arguments building up). The state path shows them as discrete start/end with execution results. Only the streaming path is consumed by the frontend for live display.

### 3. Token Streaming is Not Persisted

Tokens from `ctx.stream_token()` are ephemeral — they pass through `StreamTaskData` gRPC → `stream_publisher` → SSE and are never saved. The **final text** is only available via the `messages` state key after the LLM call completes.

This means:
- If a client joins mid-stream, it misses previous tokens
- Reconnecting mid-LLM-response loses partial text
- Historical display reconstructs from `messages` state, not from tokens

### 4. No Stream-to-State Bridge

There is no mechanism to reconstruct a live streaming session from persisted state. The two paths are completely independent:
- **Stream path**: Real-time, granular (tokens, tool_call deltas), ephemeral
- **State path**: Checkpoint-based (full `messages` array), durable

A client that loses its SSE connection must either:
- Reconnect to SSE (may miss events during the gap)
- Fall back to the state API (loses granularity — no streaming, just final values)

---

## Data Flow Summary

| What | Persisted? | Streamed Live? | Available for Historical? |
|------|:---:|:---:|:---:|
| LLM tokens (text deltas) | No | Yes (SSE `token`) | No (only final text via `messages` state) |
| Tool call start/end (LLM intent) | No | Yes (SSE `data`) | No |
| Tool call execution + result | Yes (STATE_SET `currentToolCall`) | No | Yes (via state API) |
| Full message history | Yes (STATE_SET `messages`) | No | Yes (via state API) |
| Workflow lifecycle (suspended, done) | Yes (workflow events) | Yes (SSE `data` + lifecycle) | Yes |
| Thinking deltas | No | Yes (SSE `data`) | No |
| Terminal output | No | Yes (SSE `data`) | No |
