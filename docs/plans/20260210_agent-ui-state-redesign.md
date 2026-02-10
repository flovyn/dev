# Agent UI State Redesign — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the frontend status-driven: derive all UI state from `workflow.status` + task lifecycle events + SSE stream events. Remove dead state writes from the agent workflow. Fix page-reload rendering bugs.

**Architecture:** Three phases — (1) fix frontend to be status-driven (workflow status + task lifecycle), (2) remove backend dead writes that are now unnecessary, (3) end-to-end verification.

**Design:** [Agent UI State Redesign](../design/20260210_agent-ui-state-redesign.md)
**Reference:** [Agent UI Data Architecture](../research/20260209_conversation_event_flow.md)

**Target status mapping (source: `WorkflowStatus` enum in `flovyn-server/crates/core/src/domain/workflow.rs`):**

| `workflow.status` | UI rendering | Input enabled | Cancel visible |
|---|---|---|---|
| `PENDING` | Spinner: "Starting..." | No | No |
| `RUNNING` | Spinner: "Thinking..." or tool execution | No | Yes |
| `WAITING` | Idle, ready for input | Yes | No |
| `CANCELLING` | Spinner: "Cancelling..." | No | No |
| `COMPLETED` | Final message shown, input disabled | No | No |
| `FAILED` | Error banner with message | No | No |
| `CANCELLED` | "Cancelled" banner | No | No |

---

## Phase 1: Frontend — workflow status integration

### Task 1: Extract presentational parts from thread.tsx + write stories

`thread.tsx` bundles everything — assistant-ui wiring AND pure presentational components. Extract the presentational components into `parts/` so they can be tested in Storybook independently. This enables visual verification for all subsequent tasks.

**Files:**
- Create: `flovyn-app/apps/web/components/ai/assistant-ui/parts/tool-fallback.tsx`
- Create: `flovyn-app/apps/web/components/ai/assistant-ui/parts/tool-fallback.stories.tsx`
- Create: `flovyn-app/apps/web/components/ai/assistant-ui/parts/reasoning.tsx`
- Create: `flovyn-app/apps/web/components/ai/assistant-ui/parts/reasoning.stories.tsx`
- Modify: `flovyn-app/apps/web/components/ai/assistant-ui/thread.tsx` (import from parts/)

**Step 1: Extract `ToolFallbackPart` + helpers**

Move `toolLabel()`, `toolDetail()`, and `ToolFallbackPart` from `thread.tsx` into `parts/tool-fallback.tsx`. Export the component and helpers.

```typescript
// parts/tool-fallback.tsx
export function toolLabel(name: string): string { ... }
export function toolDetail(name: string, args: Record<string, unknown>): string | undefined { ... }

export interface ToolFallbackPartProps {
  toolName: string;
  argsText?: string;
  args?: Record<string, unknown>;
  result?: unknown;
  status?: { type: string };
}

export const ToolFallbackPart: FC<ToolFallbackPartProps> = ({ ... }) => { ... };
```

Update `thread.tsx` to import from `./parts/tool-fallback`.

**Step 2: Write stories for `ToolFallbackPart`**

```typescript
// parts/tool-fallback.stories.tsx
const meta: Meta<typeof ToolFallbackPart> = {
  title: 'AI/Parts/ToolFallbackPart',
  component: ToolFallbackPart,
};

// Running — pulsing orange dot
export const Running: Story = {
  args: { toolName: 'bash', args: { command: 'ls -la' }, status: { type: 'running' } },
};

// Complete — green checkmark
export const Complete: Story = {
  args: { toolName: 'bash', args: { command: 'ls -la' }, status: { type: 'complete' } },
};

// Complete with result — expandable output
export const CompleteWithResult: Story = {
  args: { toolName: 'read-file', args: { path: '/src/main.rs' }, result: 'fn main() { ... }', status: { type: 'complete' } },
};

// Failed — with error result
export const Failed: Story = {
  args: { toolName: 'bash', args: { command: 'rm -rf /' }, result: 'Permission denied', isError: true, status: { type: 'complete' } },
};

// No status (page reload) — BUG: currently shows running, should show complete
export const NoStatus: Story = {
  args: { toolName: 'bash', args: { command: 'echo hello' } },
  name: 'No Status (page reload)',
};

// Different tool types
export const ReadFile: Story = { args: { toolName: 'read-file', args: { path: '/src/lib.rs' }, status: { type: 'complete' } } };
export const WriteFile: Story = { args: { toolName: 'write-file', args: { path: '/src/new.rs' }, status: { type: 'running' } } };
export const RunSandbox: Story = { args: { toolName: 'run-sandbox', args: { code: 'print("hello")' }, status: { type: 'running' } } };
```

**Step 3: Extract `ReasoningPart`**

Move `ReasoningPart` from `thread.tsx` into `parts/reasoning.tsx`. Export it. Update `thread.tsx` to import from `./parts/reasoning`.

**Step 4: Write stories for `ReasoningPart`**

```typescript
// parts/reasoning.stories.tsx
export const Thinking: Story = {
  args: { text: 'Let me analyze the user request...', status: { type: 'running' } },
};

export const Thought: Story = {
  args: { text: 'The user wants to refactor the authentication module.', status: { type: 'complete' } },
};
```

**Step 5: Verify**

```bash
cd flovyn-app && pnpm --filter web typecheck
cd flovyn-app && pnpm storybook  # Visual check: all stories render correctly
```

**Step 6: Commit**

```bash
git add flovyn-app/apps/web/components/ai/assistant-ui/parts/ flovyn-app/apps/web/components/ai/assistant-ui/thread.tsx
git commit -m "refactor: extract ToolFallbackPart and ReasoningPart into parts/ with stories"
```

---

### Task 2: Fix ToolFallbackPart default status on page reload

The bug: `ToolFallbackPart` defaults `status?.type` to `'running'` when undefined. On page reload, status is always undefined (assistant-ui doesn't set it on messages loaded from `initialMessages`), so every tool call shows a pulsing orange "Running" indicator forever.

**Files:**
- Modify: `flovyn-app/apps/web/components/ai/assistant-ui/parts/tool-fallback.tsx`

**Step 1: Apply the fix**

Change:
```typescript
const statusType = status?.type ?? 'running';
```
to:
```typescript
const statusType = status?.type ?? 'complete';
```

Rationale: during live streaming, the adapter always sets `status.type` explicitly. The only time it's undefined is page reload, where all tool calls are necessarily complete.

**Step 2: Verify in Storybook**

Open the `NoStatus (page reload)` story — should now show green checkmark instead of pulsing orange. All other stories unchanged.

**Step 3: Commit**

```bash
git add flovyn-app/apps/web/components/ai/assistant-ui/parts/tool-fallback.tsx
git commit -m "fix: default tool call status to 'complete' on page reload"
```

---

### Task 3: Add `onStatusChange` callback to the chat adapter (test-first)

The adapter already processes every lifecycle event that maps to a workflow status transition. It just doesn't propagate the change upward. Add a callback so the hook (Task 4) can sync status to React Query.

**Files:**
- Create: `flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.test.ts`
- Modify: `flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts`

**Step 1: Create test file with helpers**

```typescript
// flovyn-chat-adapter.test.ts
import { describe, it, expect, vi } from 'vitest';
import { Stream } from 'effect';
import { createFlovynChatAdapter } from './flovyn-chat-adapter';
import type { ChatStreamEvent } from '@/lib/effect/chat-stream';

/** Run adapter with a mock stream, collect all yielded results */
async function runAdapter(
  events: ChatStreamEvent[],
  opts?: Partial<Parameters<typeof createFlovynChatAdapter>[0]>,
) {
  const onStatusChange = vi.fn();
  const adapter = createFlovynChatAdapter({
    orgSlug: 'test',
    existingSessionId: 'wf-1',
    sendSignal: vi.fn(),
    onStatusChange,
    _createStream: () => Stream.fromIterable(events),
    ...opts,
  });

  const results = [];
  const ac = new AbortController();
  for await (const r of adapter.run({
    messages: [{ role: 'user', content: [{ type: 'text', text: 'hello' }] }],
    abortSignal: ac.signal,
    config: {},
  })) {
    results.push(r);
  }
  return { results, onStatusChange, adapter };
}
```

**Step 2: Write failing tests for `onStatusChange`**

```typescript
describe('onStatusChange', () => {
  it('emits running on stream start', async () => {
    const { onStatusChange } = await runAdapter([
      { kind: 'turn_complete' },
    ]);
    expect(onStatusChange).toHaveBeenCalledWith('running');
  });

  it('emits waiting on turn_complete', async () => {
    const { onStatusChange } = await runAdapter([
      { kind: 'turn_complete' },
    ]);
    expect(onStatusChange).toHaveBeenCalledWith('waiting');
  });

  it('emits completed on workflow_done completed', async () => {
    const { onStatusChange } = await runAdapter([
      { kind: 'workflow_done', status: 'completed' },
    ]);
    expect(onStatusChange).toHaveBeenCalledWith('completed');
  });

  it('emits failed on workflow_done failed', async () => {
    const { onStatusChange } = await runAdapter([
      { kind: 'workflow_done', status: 'failed', error: 'timeout' },
    ]);
    expect(onStatusChange).toHaveBeenCalledWith('failed');
  });

  it('emits cancelled on workflow_done cancelled', async () => {
    const { onStatusChange } = await runAdapter([
      { kind: 'workflow_done', status: 'cancelled' },
    ]);
    expect(onStatusChange).toHaveBeenCalledWith('cancelled');
  });
});
```

**Step 3: Run tests — verify they fail**

```bash
cd flovyn-app && pnpm --filter web test -- --run lib/ai/flovyn-chat-adapter.test.ts
```

Expected: All 5 tests fail (onStatusChange never called).

**Step 4: Add `onStatusChange` to options type**

```typescript
export interface FlovynChatAdapterOptions {
  // ... existing fields ...
  /** Called when workflow status changes during streaming */
  onStatusChange?: (status: 'running' | 'waiting' | 'cancelling' | 'completed' | 'failed' | 'cancelled') => void;
}
```

**Step 5: Emit status changes at transition points in `run()`**

- Line 136 (initial yield): `options.onStatusChange?.('running');`
- Line 230 (`turn_complete`): `options.onStatusChange?.('waiting');`
- Line 240 (`workflow_done` completed): `options.onStatusChange?.('completed');`
- Line 247 (`workflow_done` cancelled/error): `options.onStatusChange?.(event.status === 'cancelled' ? 'cancelled' : 'failed');`

**Step 6: Run tests — verify they pass**

```bash
cd flovyn-app && pnpm --filter web test -- --run lib/ai/flovyn-chat-adapter.test.ts
```

Expected: All 5 tests pass.

**Step 7: Commit**

```bash
git add flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.test.ts flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts
git commit -m "feat: add onStatusChange callback to chat adapter with tests"
```

---

### Task 4: Extract `useFlovynChatRuntime` hook (owns data fetching) + WorkflowStatus context

Extract all non-UI concerns from `unified-run-view.tsx` and `page.tsx` into a `useFlovynChatRuntime` hook. The hook owns: data fetching (`useGetWorkflow`, `useGetWorkflowState`), message conversion, adapter creation, runtime, and status sync (`onStatusChange → queryClient.setQueryData`). No round trip — the hook reads and updates React Query directly.

**Files:**
- Create: `flovyn-app/apps/web/lib/ai/use-flovyn-chat-runtime.ts`
- Create: `flovyn-app/apps/web/components/ai/assistant-ui/parts/workflow-status.tsx`
- Modify: `flovyn-app/apps/web/components/ai/run/unified-run-view.tsx` (simplify — use hook)
- Modify: `flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/[runId]/page.tsx` (thin wrapper)

**Step 1: Create WorkflowStatus context in parts/workflow-status.tsx**

```typescript
// parts/workflow-status.tsx
export type WorkflowStatus = 'pending' | 'running' | 'waiting' | 'cancelling' | 'completed' | 'failed' | 'cancelled';

export const WorkflowStatusContext = createContext<WorkflowStatus | undefined>(undefined);

export function WorkflowStatusProvider({
  children,
  status,
}: {
  children: ReactNode;
  status?: WorkflowStatus;
}) {
  return (
    <WorkflowStatusContext.Provider value={status}>
      {children}
    </WorkflowStatusContext.Provider>
  );
}
```

**Step 2: Create `useFlovynChatRuntime` hook**

The hook consolidates data fetching + adapter + runtime + status sync. Moves `toThreadMessages()` from `page.tsx` and adapter creation from `unified-run-view.tsx`.

```typescript
// lib/ai/use-flovyn-chat-runtime.ts
import { useRef, useMemo, useCallback } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useLocalRuntime, type ThreadMessageLike } from '@assistant-ui/react';
import { useGetWorkflow, useGetWorkflowState, useSignalWorkflow, getWorkflowQuery } from '@workspace/api';
import { createFlovynChatAdapter } from './flovyn-chat-adapter';
import type { WorkflowStatus } from '@/components/ai/assistant-ui/parts/workflow-status';

export function useFlovynChatRuntime(orgSlug: string, runId: string, opts: {
  onTerminalData: (data: string, stream: 'stdout' | 'stderr') => void;
}) {
  const queryClient = useQueryClient();

  // Data fetching — React Query as source of truth
  const { data: workflow, isLoading: wfLoading } = useGetWorkflow(
    { pathParams: { orgSlug, workflowExecutionId: runId } },
  );
  const { data: stateData, isLoading: stLoading } = useGetWorkflowState(
    { pathParams: { orgSlug, workflowExecutionId: runId } },
  );

  const workflowStatus = workflow?.status?.toLowerCase() as WorkflowStatus | undefined;
  const isActive = workflowStatus
    ? ['pending', 'running', 'waiting'].includes(workflowStatus)
    : false;

  // Convert persisted messages for initialMessages
  const initialMessages = useMemo(() => {
    if (!stateData?.state) return undefined;
    const messages = stateData.state.messages;
    if (!Array.isArray(messages) || messages.length === 0) return undefined;
    return toThreadMessages(messages);
  }, [stateData]);

  // For running workflows with no state yet — trigger auto-send
  const initialPrompt = useMemo(() => {
    if (!isActive || !workflow) return undefined;
    if (stateData?.state) {
      const messages = stateData.state.messages;
      if (Array.isArray(messages) && messages.length > 0) return undefined;
    }
    return ((workflow.input as Record<string, unknown>)?.userPrompt as string) || undefined;
  }, [isActive, workflow, stateData]);

  // Adapter + runtime
  const signalMutation = useSignalWorkflow();
  const signalRef = useRef(signalMutation);
  signalRef.current = signalMutation;

  const adapterRef = useRef<ReturnType<typeof createFlovynChatAdapter> | null>(null);
  if (!adapterRef.current) {
    adapterRef.current = createFlovynChatAdapter({
      orgSlug,
      onTerminalData: opts.onTerminalData,
      existingSessionId: runId,
      onStatusChange: (status) => {
        const { queryKey } = getWorkflowQuery({
          pathParams: { orgSlug, workflowExecutionId: runId },
        });
        queryClient.setQueryData(queryKey, (old: any) =>
          old ? { ...old, status: status.toUpperCase() } : old
        );
      },
      sendSignal: async (sessionId, userText) => {
        await signalRef.current.mutateAsync({
          pathParams: { orgSlug, workflowExecutionId: sessionId },
          body: { signalName: 'userMessage', signalValue: { text: userText } },
        });
      },
      _fetchState: async (executionId) => {
        const res = await fetch(
          `/api/orgs/${orgSlug}/workflow-executions/${executionId}/state`,
          { credentials: 'include' },
        );
        if (!res.ok) return null;
        const data = await res.json();
        return data?.state ?? null;
      },
    });
  }

  const runtime = useLocalRuntime(
    adapterRef.current,
    initialMessages ? { initialMessages } : undefined,
  );

  return {
    runtime,
    workflow,
    workflowStatus,
    isActive,
    initialPrompt,
    isLoading: wfLoading || stLoading,
  };
}
```

**Step 3: Simplify `page.tsx` to thin wrapper**

Remove data fetching, `toThreadMessages`, `initialPrompt` computation — all moved into hook. Page just extracts params:

```typescript
// page.tsx
export default function RunExecutionPage({ params }: { params: Promise<{ orgSlug: string; runId: string }> }) {
  const { orgSlug, runId } = use(params);
  return <UnifiedRunView orgSlug={orgSlug} runId={runId} />;
}
```

**Step 4: Simplify `unified-run-view.tsx`**

Remove adapter/signal/runtime code AND `historicalRun` prop. Replace with hook:

```typescript
// unified-run-view.tsx
interface UnifiedRunViewProps {
  orgSlug: string;
  runId: string;
}

export const UnifiedRunView: FC<UnifiedRunViewProps> = ({ orgSlug, runId }) => {
  const {
    runtime, workflow, workflowStatus, isActive, initialPrompt, isLoading,
  } = useFlovynChatRuntime(orgSlug, runId, { onTerminalData: handleTerminalData });

  if (isLoading) return <div>Loading run...</div>;
  if (!workflow) return <div>Run not found</div>;

  const showCancel = workflowStatus === 'running';

  // ... rest of layout unchanged, but simpler (no historicalRun prop drilling)

  <WorkflowStatusProvider status={workflowStatus}>
    <Thread />
  </WorkflowStatusProvider>
};
```

**Step 5: Verify**

```bash
cd flovyn-app && pnpm --filter web typecheck
```

Run dev server — verify existing behavior unchanged.

**Step 6: Commit**

```bash
git add flovyn-app/apps/web/lib/ai/use-flovyn-chat-runtime.ts flovyn-app/apps/web/components/ai/assistant-ui/parts/workflow-status.tsx flovyn-app/apps/web/components/ai/run/unified-run-view.tsx flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/[runId]/page.tsx
git commit -m "refactor: extract useFlovynChatRuntime hook, simplify page + view"
```

---

### Task 5: Create TerminalBanner + stories, conditionally hide Composer

When `workflowStatus` is `completed`, `failed`, or `cancelled`, show a banner below the messages instead of the Composer. Because `workflowStatus` is reactive (updated by `onStatusChange`), the banner appears immediately when the workflow completes during a live session — not just on page reload.

**Files:**
- Create: `flovyn-app/apps/web/components/ai/assistant-ui/parts/terminal-banner.tsx`
- Create: `flovyn-app/apps/web/components/ai/assistant-ui/parts/terminal-banner.stories.tsx`
- Modify: `flovyn-app/apps/web/components/ai/assistant-ui/thread.tsx`

**Step 1: Create TerminalBanner in parts/terminal-banner.tsx**

```typescript
// parts/terminal-banner.tsx
import { useContext, type FC } from 'react';
import { COLORS } from '@/lib/ai/colors';
import { WorkflowStatusContext } from './workflow-status';

export const TerminalBanner: FC = () => {
  const status = useContext(WorkflowStatusContext);
  if (!status || !['completed', 'failed', 'cancelled', 'cancelling'].includes(status)) return null;

  const config = {
    completed: { label: 'Completed', color: COLORS.green, bg: `${COLORS.green}15` },
    failed: { label: 'Failed', color: COLORS.orange, bg: `${COLORS.orange}15` },
    cancelled: { label: 'Cancelled', color: COLORS.orange, bg: `${COLORS.orange}15` },
    cancelling: { label: 'Cancelling...', color: COLORS.orange, bg: `${COLORS.orange}15` },
  }[status]!;

  return (
    <div
      className="flex items-center justify-center gap-2 rounded-lg px-4 py-2.5 text-xs font-medium"
      style={{ background: config.bg, color: config.color, border: `1px solid ${config.color}30` }}
    >
      {config.label}
    </div>
  );
};
```

**Step 2: Write stories for TerminalBanner**

```typescript
// parts/terminal-banner.stories.tsx
import { WorkflowStatusProvider } from './workflow-status';

const meta: Meta<typeof TerminalBanner> = {
  title: 'AI/Parts/TerminalBanner',
  component: TerminalBanner,
  decorators: [(Story, context) => (
    <WorkflowStatusProvider status={context.args.status}>
      <div style={{ maxWidth: 720 }}><Story /></div>
    </WorkflowStatusProvider>
  )],
};

export const Completed: Story = { args: { status: 'completed' } };
export const Failed: Story = { args: { status: 'failed' } };
export const Cancelled: Story = { args: { status: 'cancelled' } };
export const Cancelling: Story = { args: { status: 'cancelling' } };
export const Waiting: Story = { args: { status: 'waiting' }, name: 'Waiting (renders nothing)' };
```

**Step 3: Conditionally render Composer vs TerminalBanner in Thread**

In `thread.tsx`, import `TerminalBanner` from `./parts/terminal-banner` and replace the unconditional `<Composer />`:
```typescript
const Thread: FC = () => {
  const workflowStatus = useContext(WorkflowStatusContext);
  const isTerminal = workflowStatus && ['completed', 'failed', 'cancelled', 'cancelling'].includes(workflowStatus);

  return (
    <ThreadPrimitive.Root ...>
      <ThreadPrimitive.Viewport ...>
        ...
      </ThreadPrimitive.Viewport>
      <div className="mx-auto w-full max-w-[720px] px-4 pb-4">
        {isTerminal ? <TerminalBanner /> : <Composer />}
      </div>
    </ThreadPrimitive.Root>
  );
};
```

**Step 4: Verify in Storybook + app**

Storybook: all TerminalBanner stories render correctly. `Waiting` story renders nothing.

App:
1. Open a WAITING conversation → Composer visible, no banner
2. Open a COMPLETED conversation → banner "Completed", no Composer
3. Open a FAILED conversation → banner "Failed", no Composer
4. During live session, let workflow complete → Composer replaced by "Completed" banner in real-time

**Step 5: Commit**

```bash
git add flovyn-app/apps/web/components/ai/assistant-ui/parts/terminal-banner.tsx flovyn-app/apps/web/components/ai/assistant-ui/parts/terminal-banner.stories.tsx flovyn-app/apps/web/components/ai/assistant-ui/thread.tsx
git commit -m "feat: add TerminalBanner for terminal workflow states with stories"
```

---

### Task 6: Fix cancel button — only visible during RUNNING

Currently, `showCancel` is true for all `isActive` states (PENDING, RUNNING, WAITING). Per the design table, cancel should only be visible during RUNNING. Now that `workflowStatus` is reactive, this works correctly during live sessions too.

**Files:**
- Modify: `flovyn-app/apps/web/components/ai/run/unified-run-view.tsx:170`

**Step 1: Apply the fix**

Change from:
```typescript
const showCancel = isActive;
```
to:
```typescript
const showCancel = workflowStatus === 'running';
```

`workflowStatus` comes from the `useFlovynChatRuntime` hook (Task 4), which is reactive via React Query cache updates. The cancel button appears when streaming starts and disappears when the turn completes (WAITING) or workflow finishes.

**Step 2: Verify**

1. Start a new conversation → cancel button appears when RUNNING (streaming)
2. After turn completes (WAITING) → cancel button disappears
3. Send follow-up → cancel reappears during RUNNING
4. Reload a WAITING conversation → no cancel button

**Step 3: Commit**

```bash
git add flovyn-app/apps/web/components/ai/run/unified-run-view.tsx
git commit -m "fix: only show cancel button during RUNNING state"
```

---

### Task 7: Consume task lifecycle events in the chat adapter (test-first)

The adapter currently ignores all lifecycle events (`case 'lifecycle': break` at line 307). Task lifecycle events (`task.completed`, `task.failed`) are already delivered through the SSE stream — we just need to handle them.

**Approach:** Sequential correlation. The agent processes tool calls one at a time. The adapter already tracks the active tool call via `lastToolCallUniqueId` (set on `tool_call_start`). When a task lifecycle event arrives for a non-`llm-request` task, it maps to the most recently started tool call.

See design doc: [Tool call status resolution](../design/20260210_agent-ui-state-redesign.md#tool-call-status-resolution-from-multiple-sources)

**Files:**
- Modify: `flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.test.ts`
- Modify: `flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts`

**Step 1: Write failing tests for lifecycle events**

Add to the existing test file (`flovyn-chat-adapter.test.ts`):

```typescript
describe('task lifecycle events', () => {
  it('task.completed marks last tool call as complete', async () => {
    const { results } = await runAdapter([
      { kind: 'tool_call_start', toolCall: { id: 'tc1', name: 'bash', arguments: { command: 'ls' } } },
      { kind: 'lifecycle', event: 'task.completed', data: { kind: 'bash' } },
      { kind: 'turn_complete' },
    ]);
    // Find the yield after lifecycle event — tool call should have result
    const afterLifecycle = results.find(r =>
      r.content?.some((p: any) => p.type === 'tool-call' && p.result),
    );
    expect(afterLifecycle).toBeDefined();
    const toolPart = afterLifecycle!.content.find((p: any) => p.type === 'tool-call');
    expect(toolPart.result).toEqual({ status: 'complete' });
  });

  it('task.failed marks last tool call as failed with error', async () => {
    const { results } = await runAdapter([
      { kind: 'tool_call_start', toolCall: { id: 'tc1', name: 'bash', arguments: {} } },
      { kind: 'lifecycle', event: 'task.failed', data: { kind: 'bash', error: 'Timeout after 300s' } },
      { kind: 'turn_complete' },
    ]);
    const afterLifecycle = results.find(r =>
      r.content?.some((p: any) => p.type === 'tool-call' && p.isError),
    );
    expect(afterLifecycle).toBeDefined();
    const toolPart = afterLifecycle!.content.find((p: any) => p.type === 'tool-call');
    expect(toolPart.result).toBe('Timeout after 300s');
    expect(toolPart.isError).toBe(true);
  });

  it('llm-request task.failed shows error text', async () => {
    const { results } = await runAdapter([
      { kind: 'lifecycle', event: 'task.failed', data: { kind: 'llm-request', error: 'API timeout' } },
      { kind: 'turn_complete' },
    ]);
    const hasError = results.some(r =>
      r.content?.some((p: any) => p.type === 'text' && p.text.includes('API timeout')),
    );
    expect(hasError).toBe(true);
  });

  it('ignores task.completed for llm-request', async () => {
    const { results } = await runAdapter([
      { kind: 'lifecycle', event: 'task.completed', data: { kind: 'llm-request' } },
      { kind: 'turn_complete' },
    ]);
    // Should not crash, no tool calls to mark
    expect(results.length).toBeGreaterThan(0);
  });
});
```

**Step 2: Run tests — verify lifecycle tests fail**

```bash
cd flovyn-app && pnpm --filter web test -- --run lib/ai/flovyn-chat-adapter.test.ts
```

Expected: `onStatusChange` tests pass, lifecycle tests fail.

**Step 3: Replace the lifecycle case in the switch**

Replace the ignored lifecycle case (line 307-309) with:

```typescript
case 'lifecycle': {
  const eventName = event.event;
  const data = event.data;
  const taskKind = data.kind as string | undefined;

  // Tool task completed — mark the last tool call as complete
  if (eventName === 'task.completed' && taskKind && taskKind !== 'llm-request') {
    if (lastToolCallUniqueId) {
      for (let i = content.length - 1; i >= 0; i--) {
        const p = content[i];
        if (p && p.type === 'tool-call' && p.toolCallId === lastToolCallUniqueId && !p.result) {
          content[i] = { ...p, result: { status: 'complete' } };
          yield asResult([...content]);
          break;
        }
      }
    }
  }

  // Tool task failed — mark the last tool call as failed with error
  if (eventName === 'task.failed' && taskKind && taskKind !== 'llm-request') {
    if (lastToolCallUniqueId) {
      const error = (data.error as string) || 'Task failed';
      for (let i = content.length - 1; i >= 0; i--) {
        const p = content[i];
        if (p && p.type === 'tool-call' && p.toolCallId === lastToolCallUniqueId && !p.result) {
          content[i] = { ...p, result: error, isError: true };
          yield asResult([...content]);
          break;
        }
      }
    }
  }

  // LLM request failed — show error immediately (timeout, API error)
  if (eventName === 'task.failed' && taskKind === 'llm-request') {
    const error = (data.error as string) || 'LLM request failed';
    content.push({ type: 'text', text: `\n\n**Error**: ${error}` });
    yield asResult([...content]);
  }

  break;
}
```

**Step 4: Run tests — verify all pass**

```bash
cd flovyn-app && pnpm --filter web test -- --run lib/ai/flovyn-chat-adapter.test.ts
```

Expected: All tests pass (onStatusChange + lifecycle).

**Step 5: Manual verification**

1. Start a conversation with tool calls — tool cards transition individually (not all at once on `turn_complete`)
2. Trigger a tool task failure (e.g., sandbox timeout) — tool card shows "Failed" with error details
3. Trigger an LLM timeout — error message appears in the conversation immediately

**Step 6: Commit**

```bash
git add flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.test.ts flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts
git commit -m "feat: consume task lifecycle events for tool call status with tests"
```

---

## Phase 2: Backend — remove dead state writes

### Task 8: Remove dead state writes from agent workflow

Remove 4 state keys that the frontend never reads: `status`, `currentTurn`, `currentToolCall`, `lastArtifact`. This is safe because Tasks 1-7 made the frontend fully status-driven.

**Files:**
- Modify: `agent-server/src/workflows/agent.rs`

**Step 1: Update tests — remove assertions on dead state keys**

Find and remove these assertion patterns in the test module:
- `ctx.get_raw("status")` assertions
- `ctx.get_raw("currentTurn")` assertions
- `ctx.get_raw("currentToolCall")` assertions
- `ctx.get_raw("lastArtifact")` assertions

Keep all assertions on `messages` and `totalUsage` — those are still written.

**Step 2: Run tests**

```bash
cd agent-server && cargo test
```

Expected: All tests pass.

**Step 3: Remove the state writes**

Remove these `ctx.set_raw()` calls from the workflow function:
- `ctx.set_raw("status", json!("running"))` (line 41)
- `ctx.set_raw("currentTurn", json!(total_turns))` (line 47)
- `ctx.set_raw("currentToolCall", json!({...}))` (lines 140-147, line 163)
- `ctx.set_raw("lastArtifact", json!({...}))` (lines 168-177)
- `ctx.set_raw("status", json!("waiting_for_input"))` (line 192)

Keep `total_turns` variable — it's still used for the loop limit.

**Step 4: Run tests and clippy**

```bash
cd agent-server && cargo test && cargo clippy
```

Expected: All tests pass. No clippy warnings from unused variables.

**Step 5: Commit**

```bash
git add agent-server/src/workflows/agent.rs
git commit -m "refactor: remove dead state writes from agent workflow

Remove status, currentTurn, currentToolCall, lastArtifact.
These were never read by the frontend.
Only messages and totalUsage remain."
```

---

## Phase 3: Verification

### Task 9: End-to-end verification

**Step 1: Run all test suites**

```bash
cd agent-server && cargo test
cd ../sdk-rust && cargo test -p flovyn-worker-core
cd ../flovyn-app && pnpm --filter web typecheck
```

Expected: All pass.

**Step 2: Manual verification against status mapping table**

Start the dev environment and verify each status:

| Status | How to reach it | Expected UI |
|---|---|---|
| RUNNING | Send a message | Spinner, tool cards with pulsing orange, cancel button visible |
| RUNNING → tool complete | Watch tool cards during streaming | Each tool card flips to green individually as its task completes |
| WAITING | Wait for turn to complete | Composer enabled, cancel button hidden |
| COMPLETED | Let workflow finish (or check old completed run) | "Completed" banner, no Composer |
| FAILED | Trigger a failure (or check old failed run) | "Failed" banner, no Composer |
| Tool task failure | Trigger tool timeout or error | Tool card shows "Failed" with error message |
| LLM task failure | Trigger LLM timeout | Error text appears immediately in conversation |
| Page reload (WAITING) | Reload mid-conversation | Tool cards show green checkmarks, Composer visible |
| Page reload (COMPLETED) | Reload completed conversation | "Completed" banner, no Composer, all tools green |

**Step 3: Commit any fixups**

---

---

## Investigation: SSE Streaming Reconnection for Active Workflows (2026-02-10)

### Problem

When navigating to `/runs/[runId]` for an **active** workflow (already has messages), SSE streaming is never activated. All content comes from 3-second state polling. This means:
- No real-time streaming (3s latency on all updates)
- No "Agent is working..." banner between tool completion and next LLM response
- Tool calls never show live "running" indicators

**Root cause**: By the time the page loads, state poll already has messages → `initialPrompt` returns `undefined` → `autoSend` never fires → `adapter.run()` never called → no SSE connection.

### What Was Attempted

#### Approach: `runtime.thread.startRun()` to manually trigger SSE

The idea: after loading initial messages, call `startRun()` to trigger the adapter's `run()` method, establishing an SSE connection. The adapter would skip past historical events using a `resumesToSkip` counter.

**Changes made:**
1. **Adapter**: Replaced `skipUntilResume` boolean with `resumesToSkip` counter (skip N `WORKFLOW_RESUMED` events)
2. **Data hook**: Added `reconnectMessages` (strips in-progress assistant turn to prevent duplication), `userMessageCount` for computing skip count
3. **View**: `useEffect` calling `runtime.thread.startRun()` when active workflow has existing messages

#### Why It Failed

**Fundamental tension between `startRun()` and polling fallback:**

1. **`startRun()` creates a NEW assistant message** in the thread. This duplicates content that polling already provides. If SSE delivers text that polling also delivers, the user sees it twice.

2. **Stripping polling content (`reconnectMessages`)** to avoid duplication means if SSE fails or drops, the user loses all assistant content — they see only their initial user message with "Agent is working..." forever.

3. **`messageVersion: isActive ? 0`** was needed to prevent re-mounts during SSE (since polling changes `initialMessages.length`), but this **broke the polling fallback entirely** — the component never re-mounts, so new polling data is never reflected.

4. **`useLocalRuntime` only uses `initialMessages` on first mount** — subsequent prop changes don't update the thread. This means polling data after mount is invisible unless the component re-mounts (via key change).

**In short**: `startRun()` and polling are fundamentally incompatible. You can't use both simultaneously because they write to the same thread state and will conflict.

### What Survived (Still in Codebase)

These changes are independent of SSE reconnection and provide genuine value:

1. **`resumesToSkip` counter** (`flovyn-chat-adapter.ts`): Fixes a latent multi-turn follow-up bug. The old `skipUntilResume` boolean only skipped 1 `WORKFLOW_RESUMED` event, so turn 3+ follow-ups would replay turn 2 content. The counter correctly skips `actualTurnNumber - 1` events. *Note: `completedTurnCount` option is in the adapter but not wired up from the runtime hook yet.*

2. **`ActivityBanner` threadIsRunning check** (`activity-banner.tsx`): Prevents "Processing..." (AssistantInProgress) and "Agent is working..." (ActivityBanner) from showing simultaneously during SSE streaming.

3. **Test file type fixes** (`flovyn-chat-adapter.test.ts`): Added `userMsg()` and `runOpts()` helpers to satisfy `ThreadMessage` and `ChatModelRunOptions` type requirements. All 36 tests pass.

4. **`reconnectMessages` and `userMessageCount` memos** (`use-flovyn-chat-runtime.ts`): Added to `useFlovynChatData` and exported, but currently unused. Available for future use.

### Alternative Approaches (Not Yet Attempted)

1. **`unstable_resumeRun()`** (assistant-ui API): Instead of `startRun()` (creates new message), `unstable_resumeRun()` resumes the last assistant message. This could avoid duplication since it appends to existing content rather than creating a new message. Needs investigation — API is unstable and behavior unclear.

2. **Side-channel SSE listener**: Don't use the adapter for reconnection at all. Instead, create a separate SSE listener that updates React Query cache directly (like polling does, but real-time). The adapter remains only for fresh turns. This avoids the `startRun()` vs polling conflict entirely.

3. **Server-push via polling enhancement**: Instead of SSE reconnection, reduce polling interval to 1s during active workflows. Simpler but higher server load.

### Lessons Learned

- `useLocalRuntime` treats `initialMessages` as a **one-time seed**, not a reactive prop. Once mounted, the only way to update thread content is through the adapter's async generator or by re-mounting the component (key change).
- `startRun()` is designed for user-initiated turns, not for background reconnection. It always creates a new assistant message.
- Any SSE reconnection approach must coexist with the polling fallback — users navigate away and back, SSE connections drop, etc. The polling fallback is the safety net and cannot be disabled.
- Stabilizing the component key (`messageVersion: isActive ? 0`) to prevent re-mounts during SSE also prevents the polling fallback from ever updating the UI.

---

## TODO

- [ ] Task 1: Extract presentational parts + write Storybook stories
- [ ] Task 2: Fix ToolFallbackPart default status on page reload
- [ ] Task 3: Add `onStatusChange` callback to chat adapter
- [ ] Task 4: Add reactive WorkflowStatus context (REST + SSE)
- [ ] Task 5: Create TerminalBanner + stories, conditionally hide Composer
- [ ] Task 6: Fix cancel button — RUNNING only
- [ ] Task 7: Consume task lifecycle events for tool call status
- [ ] Task 8: Remove dead state writes from agent workflow
- [ ] Task 9: End-to-end verification
- [ ] Task 10: SSE reconnection for active workflows (blocked — needs new approach, see investigation above)
