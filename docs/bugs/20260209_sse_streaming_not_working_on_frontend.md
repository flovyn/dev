# SSE Streaming Not Working on Frontend

**Date**: 2026-02-09
**Severity**: Critical
**Status**: In Progress

## Symptom

When opening a workflow run page (`/org/{slug}/ai/runs/{id}`) and sending messages, no real-time streaming appears. Messages only load after manual refresh via the state API. The user sees "no streaming, no message" during workflow execution.

## Root Cause Analysis

### Bug 1: WORKFLOW_RESUMED Never Published (Critical)

**Mechanism**: The `StateEventPayload::workflow_resumed()` method exists in `crates/core/src/domain/task_stream.rs` but is **never called** anywhere in the server code.

**Impact**: The frontend chat adapter (`flovyn-chat-adapter.ts`) uses a `skipUntilResume` flag for follow-up turns. When `existingSessionId` is set (which it always is on the run page), `turnCount` starts at 1, making every interaction a "follow-up". The adapter sets `skipUntilResume = true` and waits for a `WORKFLOW_RESUMED` event before processing any events. Since this event is never published, **all stream events are silently discarded**.

**Code path**:
- `flovyn-chat-adapter.ts:178`: `let skipUntilResume = isFollowUp;` (always true on run page)
- `flovyn-chat-adapter.ts:280-286`: Waits for `WORKFLOW_RESUMED` to clear the skip flag
- `workflow_dispatch.rs:1343-1376`: Signal handler calls `append_signal_and_resume()` but never publishes `WORKFLOW_RESUMED` stream event

**Fix**: Publish `WORKFLOW_RESUMED` as a `Data` stream event after `append_signal_and_resume()` returns with `was_resumed = true`.

### Bug 2: All Resume Points Missing WORKFLOW_RESUMED (Medium)

There are 6 places in `workflow_dispatch.rs` where `workflow_repo.resume()` is called, but none publish `WORKFLOW_RESUMED`:

1. Line 258: Parent workflow resumed after child completion
2. Line 981: Workflow resumed after promise resolution
3. Line 1142: Workflow resumed after promise rejection
4. Line 1343: Signal handler (`append_signal_and_resume`)
5. Line 2084: Auto-resume after unconsumed signal detection
6. Line 2161: Auto-resume after all tasks completed

The signal handler (#4) is the critical one for the chat use case.

### Bug 3: Duplicate toolCallId Crashes Page (Medium)

The run page (`page.tsx`) crashes with "Duplicate key toolCallId" error when historical messages contain tool calls with the same ID across turns. `assistant-ui` requires globally unique toolCallIds.

**Fix**: Added dedup logic using a `seenToolCallIds` set with suffix generation for duplicates.

## Evidence

### Experiment 1: Server-side — Stream Events Published to JetStream

Server logs confirm stream events reach JetStream:
```
2026-02-09T12:17:48.399624Z DEBUG flovyn_server::streaming::nats: Published stream event to JetStream
  subject=flovyn.streams.workflow.ce68a6ac-... sequence=0 event_type=Data
...
2026-02-09T12:17:49.068894Z DEBUG flovyn_server::streaming::nats: Published stream event to JetStream
  subject=flovyn.streams.workflow.ce68a6ac-... sequence=8 event_type=Data
```

**Conclusion**: Server → JetStream pipeline works. Both lifecycle events (via StateEventPayload) and SDK stream events (tokens, data) are published.

### Experiment 2: Browser SSE — Events Received But All Skipped

Tested on workflow `4ebd2298-f34a-486e-9e0e-85ce1fa4ca02` (run page). Injected SSE monitor via JavaScript to capture all events.

**Results** (follow-up message "Say hello in one sentence"):

| Metric | Value |
|--------|-------|
| Total SSE events received | 815 |
| Token events | 579 |
| Data events | 236 |
| WORKFLOW_STARTED count | 24 |
| WORKFLOW_SUSPENDED count | 24 |
| **WORKFLOW_RESUMED count** | **0** |

**Frontend console logs**:
```
[flovyn-chat] Follow-up turn, subscribe-before-signal for: 4ebd2298-...
[flovyn-chat] Signal sent for follow-up turn
```

No `[flovyn-chat] WORKFLOW_RESUMED — processing new turn events` log appeared.

**Conclusion**: SSE pipeline works end-to-end. 815 events (including 579 tokens!) are received by the browser. But the adapter silently discards ALL of them because `skipUntilResume = true` and no `WORKFLOW_RESUMED` event ever arrives.

### Experiment 3: Binary Verification

The fix was compiled into the binary on disk (`target/debug/flovyn-server`) — confirmed via `strings` showing "Failed to publish WorkflowResumed stream event". However, the running server process was started BEFORE the binary was rebuilt:

| Timestamp | Event |
|-----------|-------|
| 13:58:30 | Server process started (PID 20043) |
| 14:01:14 | Binary rebuilt with fix |

The running server does not have the fix. Needs restart.

### Bug 4: WORKFLOW_SUSPENDED Fires for Task Suspensions, Not Just Signal Waits (Critical)

**Mechanism**: When the workflow schedules an `llm-request` task and calls `task.result().await`, the workflow suspends. The server publishes `WORKFLOW_SUSPENDED` for this internal suspension. But the adapter treats ANY `WORKFLOW_SUSPENDED` as "turn complete" and exits.

**Impact**: For first-turn messages on the new chat page, the adapter sees 3 events (WORKFLOW_STARTED → TASK_CREATED → WORKFLOW_SUSPENDED), exits at WORKFLOW_SUSPENDED, and never processes any token events. The LLM task hasn't even started producing tokens yet.

**Evidence**: Console logs from workflow `e52c4b99-370e-468c-aa86-b09cb04ba10f`:
```
[flovyn-chat] Starting new workflow
[flovyn-chat] Workflow created: e52c4b99-370e-468c-aa86-b09cb04ba10f
[flovyn-chat] Event #1: type=data, skipUntilResume=false, data={"type":"Event","event":"WORKFLOW_STARTED",...}
[flovyn-chat] Event #2: type=data, skipUntilResume=false, data={"type":"Event","event":"TASK_CREATED",...}
[flovyn-chat] Event #3: type=data, skipUntilResume=false, data={"type":"Event","event":"WORKFLOW_SUSPENDED",...}
[flovyn-chat] WORKFLOW_SUSPENDED — turn complete
```
Zero token events received. The adapter exited at event #3.
React/assistant-ui re-invoked `run()` 7 times in a loop, each time replaying the same 3 events and exiting.

**Event timeline** (what happens after the adapter exits):
1. WORKFLOW_STARTED → TASK_CREATED (llm-request) → WORKFLOW_SUSPENDED (task wait) ← adapter exits here
2. TASK_STARTED (llm-request) → tokens stream → TASK_COMPLETED
3. WORKFLOW_STARTED (resumed) → more tasks → WORKFLOW_SUSPENDED (signal wait = real turn end)

**Fix**:
- **Server**: Include `suspendType` field in the WORKFLOW_SUSPENDED event payload. The server already extracts `SuspendType` (line 2057-2075 in `workflow_dispatch.rs`), now it's included in the `WorkflowSnapshot`.
- **Frontend**: Only end the turn when `data.suspendType === 'SUSPEND_TYPE_SIGNAL'`. For `SUSPEND_TYPE_TASK` and other types, continue processing events.

## Fixes Applied

### Fix 1: WORKFLOW_RESUMED publication (`workflow_dispatch.rs`)

Added WORKFLOW_RESUMED stream event in signal handler after `append_signal_and_resume()` returns `was_resumed = true`.

### Fix 2: toolCallId dedup (`page.tsx`)

Added `seenToolCallIds` Set with suffix generation to prevent "Duplicate key" crash in assistant-ui.

### Fix 3: suspendType in WORKFLOW_SUSPENDED (`task_stream.rs` + `workflow_dispatch.rs`)

Added `suspend_type: Option<String>` field to `WorkflowSnapshot`. When publishing WORKFLOW_SUSPENDED, the server now includes the suspend type from the protobuf `SuspendType` enum (e.g., `"SUSPEND_TYPE_TASK"`, `"SUSPEND_TYPE_SIGNAL"`).

### Fix 4: Frontend signal-only turn termination (`flovyn-chat-adapter.ts`)

Changed WORKFLOW_SUSPENDED handler from unconditional turn-complete to:
- `SUSPEND_TYPE_SIGNAL` → turn complete (workflow waiting for user input)
- `SUSPEND_TYPE_TASK` / other → continue processing (internal suspension)

### Bug 5: `window.history.replaceState` Triggers Next.js Route Navigation (Critical)

**Date**: 2026-02-09

**Mechanism**: In `unified-run-view.tsx`, the `createSession` callback calls `window.history.replaceState(null, '', '/org/{slug}/ai/runs/{workflowId}')` to update the URL after workflow creation. Next.js 16.1.1 monkey-patches `history.replaceState` in `app-router.js` (lines 240-266) to intercept URL changes. When the URL changes from `/runs/new` to `/runs/{id}`, Next.js dispatches an `ACTION_RESTORE` router action via `startTransition()`, causing:

1. `new/page.tsx` unmounts → `UnifiedRunView` unmounts → active streaming adapter destroyed
2. `[runId]/page.tsx` mounts → API calls start loading → `UnifiedRunView` mounts with NEW adapter
3. New adapter has fresh state (`sid=null, turnCount=0, runActive=false`)
4. Pattern repeats: adapter created → run → session → replaceState → adapter destroyed → repeat

**Evidence**: Console logs show 4+ "adapter created" messages per workflow run, each with fresh state:
```
[8]  20:00:11 [flovyn-adapter] adapter created
[9]  20:00:11 [flovyn-adapter] run() turn=1 followUp=false sid=null active=false
[10] 20:00:12 [flovyn-adapter] session created sid=4f39925e-...
[11] 20:00:12 [flovyn-adapter] adapter created     ← SECOND adapter (replaceState triggered)
[12] 20:00:12 [flovyn-adapter] run() turn=1 followUp=false sid=null active=false
[15] 20:00:27 [flovyn-adapter] adapter created     ← THIRD adapter
```

No "event" or "stream ended" logs ever appear — adapters are destroyed before SSE events arrive.

**Fix**: Restructure the flow:
1. `new/page.tsx` triggers the workflow directly (not via adapter)
2. Shows loading state while creating
3. Once `workflowExecutionId` is obtained, `router.replace()` to `[runId]/page.tsx`
4. `[runId]/page.tsx` creates adapter with `existingSessionId` and connects to SSE
5. JetStream replays all events from the beginning — no events lost

This eliminates `replaceState` entirely. Workflow creation happens BEFORE navigation.

## Verification

- [ ] Restart server with fixed binary
- [ ] First-turn streaming works (new chat page) — tokens stream in real-time
- [ ] WORKFLOW_SUSPENDED with `suspendType: "SUSPEND_TYPE_TASK"` does NOT end turn
- [ ] WORKFLOW_SUSPENDED with `suspendType: "SUSPEND_TYPE_SIGNAL"` ends turn correctly
- [ ] Follow-up turn streaming works (WORKFLOW_RESUMED → tokens → signal suspension)
- [ ] Historical messages still load correctly on run page refresh
- [ ] No `replaceState` — `new/page.tsx` creates workflow then redirects via `router.replace()`
- [ ] `[runId]/page.tsx` auto-streams running workflows via JetStream replay
