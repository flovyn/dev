# Design: Improve Interactivity with Assistant

**Date**: 2026-02-09
**Status**: Implemented
**Related**: [Conversation Event Flow Research](../research/20260209_conversation_event_flow.md)

---

## Summary

Improve the chat UI to bring it closer to parity with Claude/ChatGPT by adding: pending state feedback, thinking indicators, reconnection resilience, and message-level retry. All features are primarily frontend changes in `flovyn-app`, with a small server-side verification for reconnection.

---

## Scope

| Feature | Approach | Effort | Backend changes |
|---------|----------|--------|-----------------|
| Pending state feedback | Frontend spinner until first SSE event | Small | None |
| Thinking indicators | Surface `thinking_delta` in adapter + UI | Small | None |
| Reconnection resilience | Hybrid: `Last-Event-ID` replay, state API fallback (Effect) | Medium | Verify replay buffer |
| Message-level retry | "Retry" button on failed messages, re-triggers turn | Medium | None |

### Non-goals

- Queue position or ETA display
- Tool-level retry (partial re-execution mid-turn)
- Persisting token streams for full historical replay
- Changes to the workflow replay engine

### Constraints

- Use Effect-TS for reconnection and error handling logic
- Keep spinner/thinking/retry in plain React state
- No new server-side event types unless required by reconnection

---

## Current Architecture

See [Conversation Event Flow Research](../research/20260209_conversation_event_flow.md) for full details.

Key points relevant to this design:

- **Two data paths**: Live streaming (ephemeral SSE) and historical state reconstruction (durable `GET /state`)
- **STATE_SET events are not streamed** — persisted to DB but not published to SSE
- **Token events are not persisted** — flow through SSE only, lost on disconnect
- **`thinking_delta` events** flow through SSE but the adapter ignores them
- **No reconnection logic** — SSE drop ends the stream with an error
- **No retry mechanism** — errors show inline, user must type a follow-up

### Workflow Status Mapping

| Server Status | Proto Status | Frontend Display | When |
|---------------|-------------|------------------|------|
| `Pending` | — | "Processing..." spinner | Workflow created, waiting for worker |
| `Running` | `RUNNING` | "Processing..." spinner → streaming tokens | Worker executing workflow |
| `Waiting` | `SUSPENDED` | Input box enabled, waiting for user | Suspended on `SIGNAL` (waiting for user message) |
| `Completed` | `COMPLETED` | Final message shown | Workflow finished |
| `Failed` | `FAILED` | Error + Retry button | Workflow failed |
| `Cancelled` | `CANCELLED` | "Cancelled" indicator | Workflow was cancelled |

---

## Feature 1: Pending State Feedback

**Current behavior**: After the user sends a message, nothing happens visually until the first SSE `token` event arrives. This gap can be several seconds (workflow queuing + worker pickup + LLM first-token latency).

**Proposed behavior**: Show a spinner with "Processing..." immediately when `adapter.run()` is called. Dismiss it when the first meaningful SSE event arrives.

### Implementation

Entirely in the frontend, in `flovyn-chat-adapter.ts`:

1. Before opening the SSE stream, yield an initial `ChatModelRunResult` with a running status:
   ```ts
   yield { content: [], status: { type: 'running' } }
   ```
   assistant-ui renders its built-in loading indicator for `status.type === 'running'`.

2. When the first `token`, `thinking_delta`, or `tool_call_start` event arrives, the adapter starts yielding content. assistant-ui automatically transitions from the loading state to showing content.

3. Same behavior for follow-up turns. After sending the signal, yield the running status. The `skipUntilResume` logic already waits for `WORKFLOW_RESUMED`, so the spinner shows during replay skip too.

### Tests

- First yield from adapter has `status: { type: 'running' }` with empty content
- Spinner dismissed (content yielded) on first `token` event
- Spinner dismissed on first `thinking_delta` event
- Spinner dismissed on first `tool_call_start` event
- Follow-up turns also show spinner before `WORKFLOW_RESUMED`

---

## Feature 2: Thinking Indicators

**Current behavior**: `thinking_delta` events flow through SSE but the adapter ignores them. The thinking content is lost.

**Proposed behavior**: Render thinking content in a collapsible block above the assistant's text response, similar to Claude's "Thinking..." UI.

### Implementation

In `flovyn-chat-adapter.ts`:

1. Accumulate `thinking_delta` events into a `reasoning` content part and yield:
   ```ts
   content = [
     { type: 'reasoning', text: thinkingAccumulator },  // collapsible
     { type: 'text', text: tokenAccumulator },           // main response
   ]
   ```
   assistant-ui supports `reasoning` parts natively and renders them as collapsible blocks.

2. Thinking always comes before text in the content array. If thinking and tokens interleave, the adapter maintains two separate accumulators and always yields `[reasoning, ...toolCalls, text]`.

3. Historical view: Thinking is ephemeral (not persisted in `messages` state). When loading from state API, no thinking blocks appear. This is acceptable — thinking is a live-only enhancement.

### Tests

- Adapter yields `reasoning` part when `thinking_delta` events arrive
- Thinking text accumulates across multiple deltas
- Thinking + token interleaving produces correct content order: `[reasoning, text]`
- No `reasoning` part when no `thinking_delta` events occur
- Tool calls interleave correctly: `[reasoning, tool_call, text]`

---

## Feature 3: Reconnection Resilience

**Current behavior**: If the SSE connection drops, the stream ends. The adapter yields an error and the user sees a broken state. No automatic recovery.

**Proposed behavior**: Automatic reconnection with hybrid strategy — try `Last-Event-ID` replay first, fall back to state API if the gap is too large.

### Implementation

New Effect service `ReconnectingChatStream` in `chat-stream.ts`:

#### Step 1: Reconnect with `Last-Event-ID`

- On SSE disconnect, retry with exponential backoff: 1s → 2s → 4s (max 3 retries)
- Reconnect with `Last-Event-ID` header (the SSE endpoint already supports this)
- If replay succeeds (events resume), continue streaming transparently
- If replay fails (buffer expired, 410 Gone, or gap too large), fall back to step 2

#### Step 2: State API fallback

- Fetch `GET /state` to get current `messages`
- Diff against locally accumulated content to determine what was missed
- Emit missing content as a batch (text "pops in")
- Re-open SSE stream from current position and resume

#### Step 3: UI during reconnection

- The adapter yields `status: { type: 'running' }` during reconnection
- Shows the same "Processing..." spinner from Feature 1
- User sees: `streaming → spinner → content pops in → streaming resumes`

#### Server-side prerequisite

Verify the SSE consolidated endpoint properly handles `Last-Event-ID` for token/data events (not just lifecycle). If the replay buffer doesn't include stream events, this needs a small server fix to include them.

### Tests

- Reconnection triggers on SSE error/close
- Exponential backoff timing: 1s, 2s, 4s (use Effect `TestClock`)
- `Last-Event-ID` header passed on reconnect attempt
- Successful `Last-Event-ID` replay resumes streaming transparently
- Fallback to state API when replay buffer is exhausted (410 or similar)
- Content continuity after state API fallback — no duplicates, no gaps
- Max retry limit (3) reached → yield error to user
- Spinner shown during reconnection attempt

---

## Feature 4: Message-Level Retry

**Current behavior**: If the assistant response fails (LLM error, timeout, workflow failure), the error text is shown inline and the user must type a follow-up to recover.

**Proposed behavior**: Show a "Retry" button on the failed message. Clicking it re-triggers the same turn.

### Implementation

In `flovyn-chat-adapter.ts`:

1. When the adapter receives `workflow_done` with `status: 'failed'` or a `stream_error`, yield with incomplete status:
   ```ts
   yield { content, status: { type: 'incomplete', reason: 'error' } }
   ```
   assistant-ui renders a "Retry" button automatically for `incomplete` status.

2. When the user clicks retry, assistant-ui calls `adapter.run()` again with the same messages. The adapter detects this is a retry (same `turnCount`, no new user text) and:
   - **First turn** (turn 0): Re-triggers the workflow via the trigger API, gets a new `executionId`, opens a new SSE stream
   - **Follow-up turns**: Re-sends the same `userMessage` signal, opens SSE stream with `skipUntilResume`

3. The adapter keeps a `lastUserText` ref. On retry, if the incoming user message matches `lastUserText` and there's no new content, treat it as a retry rather than a new message.

4. Error display: Before the retry button, show a concise error message extracted from the `workflow_done` error field or `stream_error` message.

### Tests

- Failed workflow (`workflow_done` with `status: 'failed'`) yields `incomplete` status
- Stream error yields `incomplete` status
- Retry on first turn re-triggers workflow with new execution ID
- Retry on follow-up turn re-sends the same signal
- Successful retry clears error state and streams normally
- Error message content is passed through to the UI
- Retry detection: same user text → retry, different text → new turn

---

## Testing Strategy

### Unit tests

| Area | File | What's tested |
|------|------|---------------|
| Pending spinner | `flovyn-chat-adapter.test.ts` | First yield has `status: running`, dismissed on first content event |
| Thinking | `flovyn-chat-adapter.test.ts` | `thinking_delta` → `reasoning` part, accumulation, ordering |
| Retry | `flovyn-chat-adapter.test.ts` | Error → `incomplete` status, retry re-triggers or re-sends signal |
| Reconnection | `chat-stream.test.ts` | Backoff timing, `Last-Event-ID`, state API fallback, content continuity |

### Test approach

- Mock the SSE stream as an async iterable of `ChatStreamEvent`
- Each test pushes events and asserts the sequence of `ChatModelRunResult` yields
- For reconnection: mock both SSE connection (simulate disconnect/reconnect) and state API response
- Use Effect `TestClock` for controlling backoff timing without real delays

### Integration tests (optional, lower priority)

- Spin up flovyn-server + agent-server, trigger a workflow, verify SSE events include the expected types
- Verify `Last-Event-ID` replay returns correct events after simulated gap

### What's NOT tested

- Visual rendering of spinner/thinking/retry (assistant-ui's responsibility)
- LLM provider behavior (mocked at the stream level)

---

## Implementation Order

1. **Pending spinner** — smallest change, immediate UX improvement
2. **Thinking indicators** — small, independent of other features
3. **Message-level retry** — medium, depends on understanding error flows
4. **Reconnection resilience** — largest scope, may need server verification, benefits from 1-3 being stable
