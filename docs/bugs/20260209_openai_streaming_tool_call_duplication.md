# Bug: OpenAI Streaming Tool Call Duplication (Deepseek)

**Date**: 2026-02-09
**Status**: Fixed
**Affected**: `agent-server/src/llm/providers/openai.rs`, `agent-server/src/workflows/agent.rs`
**Run**: `a27050de` (962 events in ~2 minutes)

## Symptoms

- A single LLM response produced 231 ToolCall content blocks instead of 1
- 186 TASK_FAILED events ("Task kind not found: ") and 192 TASK_SCHEDULED events
- Workflow entered an infinite loop scheduling tasks with empty names
- Frontend error: "Duplicate key toolCallId-functions.run-sandbox:2 in tapResources"

## Root Cause

### Issue 1: Streaming assembly `is_new` detection (openai.rs:448-451)

The code that determines whether an SSE streaming chunk starts a NEW tool call vs. continues the current one was:

```rust
let is_new = match &current {
    CurrentBlock::ToolCall(_, _) => tc_id.is_some(),
    _ => true,
};
```

This checks if `tc_id` (the `id` field in the chunk) is present. Standard OpenAI streaming only sends `id` in the first chunk of a new tool call. **But Deepseek (via OpenRouter) sends `id` in EVERY chunk.** This caused every streaming chunk to be treated as a new tool call, producing 231 separate ToolCall blocks from a single response.

Only the first block had the correct `name: "run-sandbox"` and `arguments`. The remaining 230 had `name: ""` and `arguments: {}`.

### Issue 2: No validation of tool call names (agent.rs:114)

The agent workflow dispatched ALL tool calls including those with empty names:

```rust
for (i, (id, name, args)) in tool_calls.iter().enumerate() {
    ctx.schedule_raw(name, args.clone()).await;  // name="" → "Task kind not found: "
}
```

Each empty-name task immediately failed, the agent retried on the next turn (same LLM response cached), creating an infinite loop within `max_turns_per_round`.

## Fix

### openai.rs: Use `index` field for tool call identity

OpenAI streaming standard includes an `index` field in `tool_calls[]` array items. This correctly identifies which tool call each chunk belongs to. The fix:

1. Read `tc_index` from `tc.get("index")`
2. Track current index in `CurrentBlock::ToolCall(ci, args, Option<i64>)`
3. New tool call only when index changes, or (without index) when ID differs from current block

Also: skip empty name updates (`if !name.is_empty()`) to avoid overwriting a valid name with an empty one from subsequent chunks.

### agent.rs: Filter empty-name tool calls

Added `if !name.is_empty()` guard in the tool call extraction filter_map:

```rust
AssistantContentBlock::ToolCall { id, name, arguments, .. }
    if !name.is_empty() => Some(...)
```

## Tests

- `test_deepseek_streaming_same_id_every_chunk` — Deepseek-style chunks (same id in every chunk with index) → 1 tool call
- `test_standard_openai_streaming_id_first_chunk_only` — Standard OpenAI (id only in first chunk) → 1 tool call
- `test_multiple_tool_calls_different_indexes` — Different indexes → separate tool calls
- `test_deepseek_no_index_same_id_merges` — No index field, same id → merges correctly
- `test_empty_name_tool_calls_are_filtered` — Agent skips tool calls with empty names

## DB Investigation

```sql
-- 962 events total for run a27050de
SELECT event_type, COUNT(*) FROM workflow_event
WHERE workflow_execution_id = 'a27050de-...' GROUP BY event_type;

-- LLM response at seq 28 contained 231 tool_call content blocks
-- First: name="run-sandbox", args={"code":"..."}
-- Rest: name="", args={}
```
