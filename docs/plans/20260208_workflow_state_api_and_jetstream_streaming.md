# Plan: Get Workflow State API + JetStream Streaming Fix

## Context

Two separate issues with the AI chat run page:

1. **Empty page on refresh**: Historical messages not loading. Current approach reconstructs from STATE_SET events — fragile.
2. **SSE streaming never works**: EventSource subscribes AFTER workflow trigger. Broadcast channels have no replay.

## Issue 1: Get Workflow State API

### Current situation

- DB table `workflow_state(workflow_execution_id, key, value BYTEA)` exists but **no Rust code reads/writes it**
- State is only in `STATE_SET`/`STATE_CLEARED` events in `workflow_event` table
- Frontend reconstructs state client-side in `[runId]/page.tsx` and `WorkflowDetailsPanel.tsx`

### Steps

#### Step 1: Repository method

**File: `flovyn-server/server/src/repository/event_repository.rs`**

Add `get_current_state(workflow_id: Uuid) -> Result<HashMap<String, Value>>`:
1. Query `STATE_SET` and `STATE_CLEARED` events ordered by sequence
2. Replay: `STATE_SET` → upsert key, `STATE_CLEARED` → remove key
3. Return final state map

#### Step 2: REST endpoint

**File: `flovyn-server/server/src/api/rest/workflows.rs`**

```
GET /api/orgs/{org_slug}/workflow-executions/{workflow_execution_id}/state
```

Response:
```rust
#[derive(Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowStateResponse {
    pub state: HashMap<String, serde_json::Value>,
}
```

Auth + org ownership same as `get_workflow_events`.

#### Step 3: Register in OpenAPI + routes

- `openapi.rs`: Add handler + `WorkflowStateResponse` schema
- Route file: Mount at `/{id}/state`
- Tag: `"Workflow Executions"`

#### Step 4: Generate `packages/api`

```bash
cd flovyn-server && cargo build
./target/debug/export-openapi > ../flovyn-app/packages/api/spec.json
cd ../flovyn-app/packages/api && pnpm generate
```

Verify `useGetWorkflowState` hook is generated.

#### Step 5: Update AI runs page

**File: `flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/[runId]/page.tsx`**

Replace events-based approach:
- Use `useGetWorkflowState` instead of `useGetWorkflowEvents`
- Extract `state.messages` → pass to existing `toThreadMessages()`
- Remove `extractMessagesFromEvents` function
- Keep `toThreadMessages()` (still needed for message format conversion)

## Issue 2: JetStream Streaming

### Current situation

- Docker-compose starts NATS with `-js` (JetStream enabled) ✓
- `NatsStreaming` uses plain pub/sub (no persistence, no replay)
- `InMemoryStreaming` uses tokio broadcast (no persistence, no replay)
- Late subscribers miss past events (confirmed by test `test_stream_late_subscriber_misses_past_events`)

### Key requirements

1. **Replay**: New subscribers get historical events from the start of the workflow execution
2. **No re-streaming after restart**: Use SSE `Last-Event-ID` to resume from where the client left off
3. **Cleanup**: Auto-delete stream data after workflow completes (or time-based retention)
4. **Backward compatible**: Same `StreamSubscriber`/`StreamEventPublisher` trait interface

### Design

**JetStream stream**: Single stream `FLOVYN_STREAMS` capturing `flovyn.streams.workflow.>` subjects.

**Retention**: Limits-based with `max_age` (e.g., 1 hour). Messages auto-expire. Completed/failed workflows can also trigger explicit purge of their subject.

**Publishing**: Same subjects as now (`flovyn.streams.workflow.{id}`). JetStream automatically stores when the stream matches the subject.

**Subscribing**: Create an ephemeral ordered consumer per SSE connection.
- New connection (no `Last-Event-ID`): `DeliverPolicy::All` → gets all stored events for this workflow
- Reconnection (has `Last-Event-ID`): `DeliverPolicy::ByStartSequence(last_id + 1)` → resumes from where it left off

**Cleanup**: After workflow completes/fails, purge the subject (`flovyn.streams.workflow.{id}`) from the stream. This removes all messages for that workflow.

### Steps

#### Step 6: Update `StreamSubscriber` trait

**File: `flovyn-server/server/src/streaming/mod.rs`**

Add `since_sequence: Option<u64>` to `subscribe`. Add `purge_workflow` to publisher.

#### Step 7: Upgrade `NatsStreaming` to JetStream

**File: `flovyn-server/server/src/streaming/nats.rs`**

- On initialization: Create/get JetStream stream `FLOVYN_STREAMS` with:
  - Subjects: `["flovyn.streams.workflow.>"]`
  - Retention: Limits
  - Max age: 1 hour (configurable)
  - Storage: Memory (fast, acceptable for streaming data)
- **Publish**: Use `jetstream.publish()` instead of `client.publish()`
- **Subscribe**: Create ordered consumer with:
  - Filter subject: `flovyn.streams.workflow.{id}`
  - Deliver policy based on `since_sequence`
- **Purge**: `stream.purge().filter(subject).await`

#### Step 8: Upgrade `InMemoryStreaming` with replay buffer

**File: `flovyn-server/server/src/streaming/in_memory.rs`**

- Add a `Vec<TaskStreamEvent>` buffer per workflow alongside the broadcast channel
- On publish: Store in buffer + broadcast
- On subscribe: First yield all buffered events (optionally from `since_sequence`), then stream live events
- On purge: Clear the buffer for the workflow
- Buffer max size: 10,000 events per workflow (prevent unbounded growth)

#### Step 9: Update SSE endpoint for `Last-Event-ID`

**File: `flovyn-server/server/src/api/rest/streaming.rs`**

- Read `Last-Event-ID` from request headers
- Pass as `since_sequence` to `stream_subscriber.subscribe()`

#### Step 10: Cleanup on workflow completion

**File: `flovyn-server/server/src/api/grpc/workflow_dispatch.rs`**

After publishing `WORKFLOW_COMPLETED`/`WORKFLOW_FAILED` events, call `stream_publisher.purge_workflow(workflow_id)`. Use a delay (e.g., 30 seconds) to allow SSE clients to receive the final events before purging.

#### Step 11: Update chat adapter

**File: `flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts`**

- Remove `skipUntilResume` logic (no longer needed — JetStream handles replay)
- For follow-up turns: Open EventSource FIRST, then send signal (subscribe-before-signal)
- The EventSource will get all events from the current turn via JetStream replay
- Add diagnostic `console.debug` logging

### Not re-streaming concern

After server restart:
- JetStream stream data persists (stored on NATS server, not in the Rust process)
- SSE clients reconnect automatically and send `Last-Event-ID`
- Server creates consumer from `Last-Event-ID + 1` → no duplicate events
- If no `Last-Event-ID` (fresh connection), gets all events from start → OK for initial load

After workflow completion:
- `purge_workflow()` removes all messages for that workflow from JetStream
- Subsequent SSE connections to completed workflows get no stream events
- Historical data is loaded via the state API (Issue 1)

## Key Files

| File | Change |
|------|--------|
| `flovyn-server/server/src/repository/event_repository.rs` | `get_current_state()` |
| `flovyn-server/server/src/api/rest/workflows.rs` | `get_workflow_state` handler |
| `flovyn-server/server/src/api/rest/openapi.rs` | Register endpoint |
| `flovyn-server/server/src/streaming/mod.rs` | Update traits |
| `flovyn-server/server/src/streaming/nats.rs` | JetStream upgrade |
| `flovyn-server/server/src/streaming/in_memory.rs` | Add replay buffer |
| `flovyn-server/server/src/api/rest/streaming.rs` | Last-Event-ID support |
| `flovyn-server/server/src/api/grpc/workflow_dispatch.rs` | Purge on completion |
| `flovyn-app/packages/api/spec.json` | Updated spec |
| `flovyn-app/packages/api/src/*` | Generated hooks |
| `flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/[runId]/page.tsx` | Use state API |
| `flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts` | Remove skip logic, add logging |

## Verification

1. `mise run test` — all existing + new tests pass
2. State API: `curl /api/orgs/dev/workflow-executions/{id}/state` returns state map
3. Browser: refresh run page → messages load from state API
4. Browser: start new chat → tokens stream in real-time
5. Browser: send follow-up → streaming works
6. Kill and restart server → SSE clients reconnect, no duplicate events
7. Completed workflow → NATS stream data cleaned up

## TODO

- [x] Step 1: Add `get_current_state()` repository method
- [x] Step 2: Add `get_workflow_state` REST handler
- [x] Step 3: Register in OpenAPI + routes
- [x] Step 4: Generate `packages/api`
- [x] Step 5: Update AI runs page to use state API
- [x] Step 6: Update `StreamSubscriber` trait with `since_sequence`
- [x] Step 7: Upgrade `NatsStreaming` to JetStream
- [x] Step 8: Upgrade `InMemoryStreaming` with replay buffer
- [x] Step 9: Update SSE endpoint for `Last-Event-ID`
- [x] Step 10: Purge stream on workflow completion
- [x] Step 11: Update chat adapter (subscribe-before-signal, simplified skip logic)

## Additional Fixes (Post-Plan)

- [x] **Signal-during-RUNNING race** (server): When signals arrive while workflow is RUNNING, `append_signal_and_resume` can't resume (only WAITING→PENDING). Added unconsumed signal check in `workflow_dispatch.rs` when workflow suspends for signal. Test: `test_multiple_signals_queue_semantics`.
- [x] **Multi-turn signal replay bug** (SDK): Replay engine used `rposition` (last suspension) to split signal queues, causing inter-boundary signals to be visible to `has_signal()` during earlier rounds. Fixed to use `position` (first suspension) and removed deferred-to-available promotion. Test: `test_multi_turn_signals_not_visible_to_has_signal`.
- [x] **Token streaming wiring** (SDK): `task_worker.rs` had `on_stream: None` — all `ctx.stream_token()` calls were silently dropped. Added `TaskEvent::Stream` variant and wired `on_stream` callback.
- [x] **E2E test harness JetStream** (SDK): Added `-js` flag to NATS container in SDK E2E test harness to enable JetStream (required after Step 7).
