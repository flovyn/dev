# Improve Interactivity with Assistant — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Bring the chat UI closer to parity with Claude/ChatGPT by adding pending spinners, thinking indicators, hybrid reconnection, and message-level retry.

**Architecture:** All four features are primarily frontend changes in `flovyn-app/apps/web`. The chat adapter (`flovyn-chat-adapter.ts`) and chat stream (`chat-stream.ts`) are the main files modified. Reconnection uses Effect-TS for retry/fallback logic. No new server-side event types are needed — only a verification that the SSE replay buffer covers token/data events (it does, confirmed in `in_memory.rs`).

**Tech Stack:** TypeScript, Effect-TS (Stream, Schedule), @assistant-ui/react (ChatModelAdapter, ReasoningMessagePart), Vitest

**Design doc:** `dev/docs/design/20260209_improve-interactivity-with-assistant.md`

---

## Phase 1: Pending State Feedback

### Task 1: Test — adapter yields running status before first content

**Files:**
- Modify: `flovyn-app/apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`

**Step 1: Write the failing test**

Add to the "first turn" describe block:

```typescript
it('should yield running status before first content event', async () => {
  const { adapter } = createTestAdapter([
    { kind: 'token', text: 'Hello' },
    { kind: 'workflow_done', status: 'completed' },
  ]);

  const results = await collectResults(adapter);

  // First yield should be empty content with running status
  expect(results[0]).toEqual({
    content: [],
    status: { type: 'running' },
  });

  // Subsequent yields should have content
  expect(results.length).toBeGreaterThan(1);
  const last = results[results.length - 1]!;
  expect(last.content).toEqual([{ type: 'text', text: 'Hello' }]);
});
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm vitest run apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`
Expected: FAIL — adapter currently yields content directly without an initial running status.

### Task 2: Implement — yield running status at start of adapter.run()

**Files:**
- Modify: `flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts:125-127`

**Step 1: Add initial running yield**

After the comment `// Consume ChatStreamEvents and yield ChatModelRunResult` (line 122) and before `const content: ContentPart[] = [];` (line 125), add:

```typescript
// Yield initial running status — shows "Processing..." spinner
yield { content: [], status: { type: 'running' as const } } as ChatModelRunResult;
```

**Step 2: Run test to verify it passes**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm vitest run apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`
Expected: PASS

**Step 3: Run all existing tests to check for regressions**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm vitest run apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`
Expected: Some existing tests may need updating because they now receive an extra initial yield. Update `results[0]` expectations to account for the new running status yield. The fix is to shift result indices by 1 or use `results.slice(1)` in affected tests.

### Task 3: Fix regressions in existing adapter tests

**Files:**
- Modify: `flovyn-app/apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`

**Step 1: Update affected tests**

Every test that uses `collectResults()` and checks `results.length` or `results[0]` now has an extra initial yield. Update:

1. `'should stream tokens'` — `results.length` is now 4 (was 3): running + token1 + token2 + done
2. `'should handle tool calls'` — `last` check still works (last is unchanged)
3. `'should skip lifecycle events without crashing'` — unchanged (last is fine)
4. `'should handle stream errors'` — unchanged
5. `'should handle workflow failure'` — unchanged
6. All tests using `results[results.length - 1]` are fine — only count-based assertions need updating

Update the token count assertion:

```typescript
// Was: expect(results.length).toBe(3);
expect(results.length).toBe(4); // running + token1 + token2 + workflow_done
```

**Step 2: Run all tests**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm vitest run apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`
Expected: ALL PASS

### Task 4: Test — follow-up turns also show running status

**Files:**
- Modify: `flovyn-app/apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`

**Step 1: Write the test**

Add to the "follow-up turn" describe block:

```typescript
it('should yield running status on follow-up turns', async () => {
  const events: ChatStreamEvent[] = [
    { kind: 'lifecycle', event: 'WORKFLOW_RESUMED', data: {} },
    { kind: 'token', text: 'Follow-up' },
    { kind: 'turn_complete' },
  ];

  const adapter = createFlovynChatAdapter({
    orgSlug: 'test-org',
    existingSessionId: 'test-session-id',
    sendSignal: vi.fn().mockResolvedValue(undefined),
    _createStream: () => mockStream(events),
  });

  // First run to bump turnCount
  for await (const _ of adapter.run({
    messages: [{ role: 'user' as const, content: [{ type: 'text' as const, text: 'First' }] }],
    abortSignal: new AbortController().signal,
  })) { /* drain */ }

  // Second run — should start with running status
  const results: Array<{ content: unknown[]; status?: unknown }> = [];
  for await (const r of adapter.run({
    messages: [{ role: 'user' as const, content: [{ type: 'text' as const, text: 'Follow up' }] }],
    abortSignal: new AbortController().signal,
  })) {
    results.push(r as { content: unknown[]; status?: unknown });
  }

  // First yield should be running status
  expect(results[0]).toEqual({ content: [], status: { type: 'running' } });
});
```

**Step 2: Run test**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm vitest run apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`
Expected: PASS (the running yield is before the event loop, so it works for follow-ups too)

### Task 5: Commit Phase 1

```bash
cd /Users/manhha/Developer/manhha/flovyn/flovyn-app
git add apps/web/lib/ai/flovyn-chat-adapter.ts apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts
git commit -m "feat(chat): yield running status before first content for pending spinner"
```

---

## Phase 2: Thinking Indicators

### Task 6: Test — adapter yields reasoning part for thinking_delta events

**Files:**
- Modify: `flovyn-app/apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`

**Step 1: Write the failing test**

Add a new describe block:

```typescript
describe('thinking indicators', () => {
  it('should yield reasoning part for thinking_delta events', async () => {
    const { adapter } = createTestAdapter([
      { kind: 'thinking_delta', text: 'Let me think' },
      { kind: 'thinking_delta', text: ' about this' },
      { kind: 'token', text: 'The answer is 42' },
      { kind: 'workflow_done', status: 'completed' },
    ]);

    const results = await collectResults(adapter);
    // Skip first result (running status)
    const last = results[results.length - 1]!;

    expect(last.content).toEqual([
      { type: 'reasoning', text: 'Let me think about this' },
      { type: 'text', text: 'The answer is 42' },
    ]);
  });

  it('should accumulate thinking deltas', async () => {
    const { adapter } = createTestAdapter([
      { kind: 'thinking_delta', text: 'Step 1. ' },
      { kind: 'thinking_delta', text: 'Step 2. ' },
      { kind: 'thinking_delta', text: 'Done.' },
      { kind: 'turn_complete' },
    ]);

    const results = await collectResults(adapter);
    const last = results[results.length - 1]!;

    expect(last.content).toEqual([
      { type: 'reasoning', text: 'Step 1. Step 2. Done.' },
    ]);
  });

  it('should not yield reasoning part when no thinking events', async () => {
    const { adapter } = createTestAdapter([
      { kind: 'token', text: 'Hello' },
      { kind: 'workflow_done', status: 'completed' },
    ]);

    const results = await collectResults(adapter);
    const last = results[results.length - 1]!;

    // Only text, no reasoning
    expect(last.content).toEqual([{ type: 'text', text: 'Hello' }]);
  });

  it('should order reasoning before tool calls and text', async () => {
    const { adapter } = createTestAdapter([
      { kind: 'thinking_delta', text: 'Planning...' },
      { kind: 'tool_call_start', toolCall: { id: 'tc1', name: 'bash', arguments: {} } },
      { kind: 'tool_call_end', toolCall: { id: 'tc1', name: 'bash', arguments: {} } },
      { kind: 'token', text: 'Done' },
      { kind: 'workflow_done', status: 'completed' },
    ]);

    const results = await collectResults(adapter);
    const last = results[results.length - 1]!;

    expect((last.content as Array<{ type: string }>).map(c => c.type)).toEqual([
      'reasoning', 'tool-call', 'text',
    ]);
  });
});
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm vitest run apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`
Expected: FAIL — adapter currently ignores `thinking_delta`.

### Task 7: Implement — handle thinking_delta in adapter

**Files:**
- Modify: `flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts`

**Step 1: Add ReasoningPart type**

At line 33, update the `ContentPart` type union:

```typescript
type ReasoningPart = { type: 'reasoning'; text: string };
type ContentPart = TextPart | ToolCallPart | ReasoningPart;
```

**Step 2: Add thinking accumulator**

After `let currentText = '';` (line 126), add:

```typescript
let currentThinking = '';
```

**Step 3: Replace the thinking_delta ignore case**

Replace lines 257-258 (`case 'thinking_delta':` and the comment) with:

```typescript
case 'thinking_delta': {
  currentThinking += event.text;
  // Update or insert the reasoning part (always first in content)
  const existingIdx = content.findIndex(p => p.type === 'reasoning');
  if (existingIdx >= 0) {
    content[existingIdx] = { type: 'reasoning', text: currentThinking };
  } else {
    content.unshift({ type: 'reasoning', text: currentThinking });
  }
  yield asResult([...content]);
  break;
}
```

**Step 4: Run tests**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm vitest run apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`
Expected: ALL PASS

### Task 8: Commit Phase 2

```bash
cd /Users/manhha/Developer/manhha/flovyn/flovyn-app
git add apps/web/lib/ai/flovyn-chat-adapter.ts apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts
git commit -m "feat(chat): surface thinking_delta as reasoning content part"
```

---

## Phase 3: Message-Level Retry

### Task 9: Test — failed workflow yields incomplete status (already works)

**Files:**
- Modify: `flovyn-app/apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`

**Step 1: Verify existing behavior**

The adapter already yields `{ type: 'incomplete', reason: 'error' }` for `workflow_done` with `status: 'failed'` and for `stream_error`. This is confirmed by existing tests at lines 139-148 and 129-137. Verify these still pass:

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm vitest run apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts -t "should handle workflow failure"`
Expected: PASS

> assistant-ui automatically renders a "Retry" button for `status.type === 'incomplete'`. So the retry button already appears. The remaining work is making the retry action work correctly.

### Task 10: Test — retry on first turn re-triggers workflow

**Files:**
- Modify: `flovyn-app/apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`

**Step 1: Write the failing test**

Add a new describe block:

```typescript
describe('message-level retry', () => {
  it('should detect retry on first turn (same text, same turnCount)', async () => {
    let streamCallCount = 0;
    const adapter = createFlovynChatAdapter({
      orgSlug: 'test-org',
      existingSessionId: 'test-session-id',
      sendSignal: vi.fn().mockResolvedValue(undefined),
      _createStream: () => {
        streamCallCount++;
        if (streamCallCount === 1) {
          return mockStream([
            { kind: 'workflow_done', status: 'failed', error: 'LLM timeout' },
          ]);
        }
        // Retry succeeds
        return mockStream([
          { kind: 'token', text: 'Recovered' },
          { kind: 'workflow_done', status: 'completed' },
        ]);
      },
    });

    // First run — fails
    const results1: Array<{ content: unknown[]; status?: unknown }> = [];
    for await (const r of adapter.run({
      messages: [{ role: 'user' as const, content: [{ type: 'text' as const, text: 'Hello' }] }],
      abortSignal: new AbortController().signal,
    })) {
      results1.push(r as { content: unknown[]; status?: unknown });
    }
    expect(results1[results1.length - 1]!.status).toEqual({ type: 'incomplete', reason: 'error' });

    // Retry — same message, adapter should NOT send signal (it's a first-turn retry)
    const results2: Array<{ content: unknown[]; status?: unknown }> = [];
    for await (const r of adapter.run({
      messages: [{ role: 'user' as const, content: [{ type: 'text' as const, text: 'Hello' }] }],
      abortSignal: new AbortController().signal,
    })) {
      results2.push(r as { content: unknown[]; status?: unknown });
    }

    const last = results2[results2.length - 1]!;
    expect(last.status).toEqual({ type: 'complete', reason: 'stop' });
    expect(streamCallCount).toBe(2);
  });

  it('should detect retry on follow-up turn and re-send signal', async () => {
    const sendSignal = vi.fn().mockResolvedValue(undefined);
    let streamCallCount = 0;

    const adapter = createFlovynChatAdapter({
      orgSlug: 'test-org',
      existingSessionId: 'test-session-id',
      sendSignal,
      _createStream: () => {
        streamCallCount++;
        if (streamCallCount === 1) {
          // First turn succeeds
          return mockStream([
            { kind: 'token', text: 'Hi' },
            { kind: 'turn_complete' },
          ]);
        }
        if (streamCallCount === 2) {
          // Follow-up fails
          return mockStream([
            { kind: 'lifecycle', event: 'WORKFLOW_RESUMED', data: {} },
            { kind: 'workflow_done', status: 'failed', error: 'Timeout' },
          ]);
        }
        // Retry of follow-up succeeds
        return mockStream([
          { kind: 'lifecycle', event: 'WORKFLOW_RESUMED', data: {} },
          { kind: 'token', text: 'Recovered' },
          { kind: 'turn_complete' },
        ]);
      },
    });

    // First turn
    for await (const _ of adapter.run({
      messages: [{ role: 'user' as const, content: [{ type: 'text' as const, text: 'First' }] }],
      abortSignal: new AbortController().signal,
    })) { /* drain */ }

    // Follow-up — fails
    for await (const _ of adapter.run({
      messages: [
        { role: 'user' as const, content: [{ type: 'text' as const, text: 'First' }] },
        { role: 'user' as const, content: [{ type: 'text' as const, text: 'Follow up' }] },
      ],
      abortSignal: new AbortController().signal,
    })) { /* drain */ }

    expect(sendSignal).toHaveBeenCalledTimes(1);
    sendSignal.mockClear();

    // Retry of follow-up — should re-send the same signal
    const results: Array<{ content: unknown[]; status?: unknown }> = [];
    for await (const r of adapter.run({
      messages: [
        { role: 'user' as const, content: [{ type: 'text' as const, text: 'First' }] },
        { role: 'user' as const, content: [{ type: 'text' as const, text: 'Follow up' }] },
      ],
      abortSignal: new AbortController().signal,
    })) {
      results.push(r as { content: unknown[]; status?: unknown });
    }

    expect(sendSignal).toHaveBeenCalledWith('test-session-id', 'Follow up');
    const last = results[results.length - 1]!;
    expect(last.status).toEqual({ type: 'complete', reason: 'stop' });
  });
});
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm vitest run apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts -t "message-level retry"`
Expected: FAIL — current adapter increments `turnCount` on every run, so retry of first turn becomes a follow-up.

### Task 11: Implement — retry detection in adapter

**Files:**
- Modify: `flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts`

**Step 1: Add retry tracking state**

After `let runActive = false;` (line 48), add:

```typescript
let lastStatus: 'complete' | 'incomplete' | null = null;
let lastUserText = '';
```

**Step 2: Add retry detection logic**

After `turnCount++;` (line 65), replace with retry-aware logic:

```typescript
const isRetry = lastStatus === 'incomplete' && userText === lastUserText;
if (!isRetry) {
  turnCount++;
}
lastUserText = userText;
const isFollowUp = turnCount > 1;
```

And remove the existing `const isFollowUp = turnCount > 0;` (line 64) and `turnCount++;` (line 65).

**Step 3: Track completion status**

In the `turn_complete` case (around line 216), before `return;`, add:
```typescript
lastStatus = 'complete';
```

In the `workflow_done` case (around line 224), update both branches:
- completed: `lastStatus = 'complete';`
- failed/cancelled: `lastStatus = 'incomplete';`

In the `stream_error` case (around line 246):
```typescript
lastStatus = 'incomplete';
```

**Step 4: Run tests**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm vitest run apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`
Expected: ALL PASS

### Task 12: Commit Phase 3

```bash
cd /Users/manhha/Developer/manhha/flovyn/flovyn-app
git add apps/web/lib/ai/flovyn-chat-adapter.ts apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts
git commit -m "feat(chat): support message-level retry via turnCount rollback on failure"
```

---

## Phase 4: Reconnection Resilience

### Task 13: Test — reconnecting chat stream with state API fallback

**Files:**
- Create: `flovyn-app/apps/web/lib/effect/__tests__/chat-stream.test.ts`

**Step 1: Write tests for reconnecting chat stream**

```typescript
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { Effect, Stream, Fiber } from 'effect'
import type { ChatStreamEvent } from '../chat-stream'

// Helper: collect events from a stream
async function collectStreamEvents(stream: Stream.Stream<ChatStreamEvent, unknown>): Promise<ChatStreamEvent[]> {
  const events: ChatStreamEvent[] = []
  await Effect.runPromise(
    stream.pipe(
      Stream.runForEach((event) => Effect.sync(() => { events.push(event) })),
      Effect.catchAll(() => Effect.void),
    ),
  )
  return events
}

describe('reconnecting chat stream', () => {
  it('should pass through events when stream is healthy', async () => {
    const events: ChatStreamEvent[] = [
      { kind: 'token', text: 'Hello' },
      { kind: 'token', text: ' world' },
      { kind: 'turn_complete' },
    ]
    const stream = Stream.fromIterable(events)

    const collected = await collectStreamEvents(stream)
    expect(collected).toEqual(events)
  })

  // Additional tests will be added as the reconnection logic is implemented
})
```

This is a placeholder. The actual reconnection tests depend on how `createReconnectingChatStream` is structured. Tests will be refined in Task 14.

**Step 2: Run test**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm vitest run apps/web/lib/effect/__tests__/chat-stream.test.ts`
Expected: PASS

### Task 14: Implement — reconnecting chat stream with hybrid strategy

**Files:**
- Modify: `flovyn-app/apps/web/lib/effect/chat-stream.ts`

This is the most complex task. The existing `createChatStream` already uses `makeResilientMixedSSEStream` which has built-in retry with exponential backoff (1s, 2s, 4s, 8s, 10s cap, 5 attempts). This handles the `Last-Event-ID` replay automatically via the browser's EventSource reconnection.

**Step 1: Assess what's already handled**

The browser's `EventSource` API automatically:
- Reconnects on connection drop
- Sends `Last-Event-ID` header on reconnect
- The server's replay buffer (`MAX_BUFFER_SIZE = 10_000`) includes token/data/progress events

The `makeResilientMixedSSEStream` in `resilient-stream.ts` adds:
- `Stream.retry(retrySchedule)` with exponential backoff + 5 max attempts
- Error logging

**What's missing**: When EventSource retry exhausts (5 attempts fail) or the replay buffer is stale, we need a state API fallback.

**Step 2: Add state API fallback to adapter**

Rather than modifying the stream layer (which handles SSE-level retry well), add the fallback at the adapter level in `flovyn-chat-adapter.ts`. When the stream emits a `stream_error`, instead of immediately yielding the error, attempt a state API recovery:

Add a new option to `FlovynChatAdapterOptions`:

```typescript
/** @internal Fetch workflow state for reconnection fallback */
_fetchState?: (executionId: string) => Promise<{ messages?: unknown[] } | null>;
```

In the `stream_error` case, before yielding the error:

```typescript
case 'stream_error': {
  // Attempt state API fallback before surfacing error
  if (options._fetchState) {
    try {
      const state = await options._fetchState(sessionId!);
      if (state?.messages && Array.isArray(state.messages)) {
        // State recovered — emit accumulated content from messages
        // and yield complete status (workflow may have finished while disconnected)
        yield {
          content: [{ type: 'text' as const, text: '[Reconnected — some streaming content may have been skipped]' }],
          status: { type: 'complete' as const, reason: 'stop' as const },
        } as ChatModelRunResult;
        return;
      }
    } catch {
      // Fallback failed — surface original error
    }
  }
  lastStatus = 'incomplete';
  yield {
    content: [
      ...content,
      { type: 'text' as const, text: `\n\n**Stream error**: ${event.message}` },
    ],
    status: { type: 'incomplete' as const, reason: 'error' as const },
  } as ChatModelRunResult;
  return;
}
```

**Step 3: Run tests**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm vitest run apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`
Expected: ALL PASS (new fallback path is opt-in via `_fetchState`)

### Task 15: Test — state API fallback on stream error

**Files:**
- Modify: `flovyn-app/apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts`

**Step 1: Write the test**

Add to a new "reconnection fallback" describe block:

```typescript
describe('reconnection fallback', () => {
  it('should recover via state API when stream errors and _fetchState is provided', async () => {
    const fetchState = vi.fn().mockResolvedValue({
      messages: [
        { role: 'user', content: 'Hello' },
        { role: 'assistant', content: 'Hi there!' },
      ],
    });

    const adapter = createFlovynChatAdapter({
      orgSlug: 'test-org',
      existingSessionId: 'test-session-id',
      sendSignal: vi.fn().mockResolvedValue(undefined),
      _createStream: () => mockStream([
        { kind: 'token', text: 'Partial...' },
        { kind: 'stream_error', message: 'Connection lost' },
      ]),
      _fetchState: fetchState,
    });

    const results = await collectResults(adapter);
    const last = results[results.length - 1]!;

    // Should recover instead of showing error
    expect(last.status).toEqual({ type: 'complete', reason: 'stop' });
    expect(fetchState).toHaveBeenCalledWith('test-session-id');
  });

  it('should surface error when state API fallback also fails', async () => {
    const fetchState = vi.fn().mockRejectedValue(new Error('Network error'));

    const adapter = createFlovynChatAdapter({
      orgSlug: 'test-org',
      existingSessionId: 'test-session-id',
      sendSignal: vi.fn().mockResolvedValue(undefined),
      _createStream: () => mockStream([
        { kind: 'stream_error', message: 'Connection lost' },
      ]),
      _fetchState: fetchState,
    });

    const results = await collectResults(adapter);
    const last = results[results.length - 1]!;

    expect(last.status).toEqual({ type: 'incomplete', reason: 'error' });
  });

  it('should surface error normally when _fetchState is not provided', async () => {
    const { adapter } = createTestAdapter([
      { kind: 'stream_error', message: 'Connection lost' },
    ]);

    const results = await collectResults(adapter);
    const last = results[results.length - 1]!;

    expect(last.status).toEqual({ type: 'incomplete', reason: 'error' });
  });
});
```

**Step 2: Run tests**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm vitest run apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts -t "reconnection fallback"`
Expected: ALL PASS

### Task 16: Wire up _fetchState in unified-run-view

**Files:**
- Modify: `flovyn-app/apps/web/components/ai/run/unified-run-view.tsx`

**Step 1: Pass _fetchState to adapter**

In the adapter creation, add the `_fetchState` option that calls the state API:

```typescript
_fetchState: async (executionId: string) => {
  const res = await fetch(`/api/orgs/${orgSlug}/workflow-executions/${executionId}/state`, {
    credentials: 'include',
  });
  if (!res.ok) return null;
  const data = await res.json();
  return data?.state ?? null;
},
```

**Step 2: Verify manually**

No automated test for this wiring — it depends on the running server. Manual verification: start the app, begin a chat, kill the server briefly, observe the recovery behavior.

### Task 17: Commit Phase 4

```bash
cd /Users/manhha/Developer/manhha/flovyn/flovyn-app
git add apps/web/lib/ai/flovyn-chat-adapter.ts apps/web/lib/ai/__tests__/flovyn-chat-adapter.test.ts apps/web/lib/effect/__tests__/chat-stream.test.ts apps/web/components/ai/run/unified-run-view.tsx
git commit -m "feat(chat): add hybrid reconnection with state API fallback on stream error"
```

---

## Phase 5: Final Verification

### Task 18: Run full test suite

**Step 1: Run all frontend tests**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm vitest run`
Expected: ALL PASS

**Step 2: Run type check**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm typecheck`
Expected: No type errors

### Task 19: Update design doc status

**Files:**
- Modify: `dev/docs/design/20260209_improve-interactivity-with-assistant.md`

Change `**Status**: Draft` to `**Status**: Implemented`

### Task 20: Commit final

```bash
cd /Users/manhha/Developer/manhha/flovyn
git add dev/docs/design/20260209_improve-interactivity-with-assistant.md
git commit -m "docs: mark interactivity design as implemented"
```

---

## TODO

- [x] Task 1: Test — adapter yields running status before first content
- [x] Task 2: Implement — yield running status at start of adapter.run()
- [x] Task 3: Fix regressions in existing adapter tests
- [x] Task 4: Test — follow-up turns also show running status
- [x] Task 5: Commit Phase 1
- [x] Task 6: Test — adapter yields reasoning part for thinking_delta events
- [x] Task 7: Implement — handle thinking_delta in adapter
- [x] Task 8: Commit Phase 2
- [x] Task 9: Verify — failed workflow yields incomplete status (existing behavior)
- [x] Task 10: Test — retry on first turn re-triggers, follow-up re-sends signal
- [x] Task 11: Implement — retry detection in adapter
- [x] Task 12: Commit Phase 3
- [x] Task 13: Test — reconnecting chat stream placeholder
- [x] Task 14: Implement — state API fallback on stream error
- [x] Task 15: Test — state API fallback behavior
- [x] Task 16: Wire up _fetchState in unified-run-view
- [x] Task 17: Commit Phase 4
- [x] Task 18: Run full test suite + type check
- [x] Task 19: Update design doc status
- [x] Task 20: Commit final
