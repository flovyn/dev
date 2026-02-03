# Research: Durable AI Conversations and Context Management

**Date**: 2026-01-28
**Status**: Research
**Related**: [SignalWithStart Design](../design/20260127_implement_signalwithstart.md), [Execution Patterns](20260128_execution_patterns_multi_message.md)

---

## Summary

This document explores how to make AI conversations (chatbots, coding agents) durable - able to track what the agent did, its reasoning, and resume on any machine without losing progress. It also covers context window management strategies.

## Requirements for Durable AI Conversations

1. **Track what the agent did and its reasoning**
   - Full message history (user + assistant)
   - Tool executions and their results
   - LLM reasoning/thinking content

2. **Resume on any machine without losing track**
   - Persist state durably
   - Handle crashes during tool execution
   - Handle crashes during LLM streaming

---

## Competitor Analysis

### DBOS: Separated State Model

DBOS uses a fundamentally different approach from event-sourced systems:

**Key insight: DBOS doesn't use full event sourcing replay!**

```typescript
// Recovery model: "resume from last completed step"
async function workflowFunction() {
  await DBOS.runStep(stepOne);  // Checkpoint after completion
  await DBOS.runStep(stepTwo);  // Checkpoint after completion
}
```

**How DBOS Handles Chatbots:**

From the [Customer Service Agent example](https://docs.dbos.dev/python/examples/customer-service):

```python
# DBOS does NOT use workflows for the chat loop!
# Instead, they use LangGraph with PostgreSQL checkpointer:
pool = ConnectionPool(connection_string)
checkpointer = PostgresSaver(pool)
graph = graph_builder.compile(checkpointer=checkpointer)

# DBOS is only used for durable SIDE EFFECTS:
@tool
@DBOS.workflow()
def process_refund(order_id: int):
    """Durable refund processing - survives crashes"""
    purchase = get_purchase_by_id(order_id)
    # ... durable logic
```

**Key architectural insight:**
- **Chat state management**: External system (LangGraph + PostgreSQL checkpointer)
- **Durable operations**: DBOS workflows for side effects only

### Vercel Workflow: Pragmatic Multi-Turn

Vercel Workflow accepts event growth, optimizes for developer experience:

**Two Patterns:**

1. **Single-Turn** (Bounded): Each user message = NEW workflow
2. **Multi-Turn** (Unbounded, but recommended): ONE workflow handles entire conversation

```typescript
// Multi-Turn: ONE workflow handles entire conversation
export async function chat(initialMessages: UIMessage[]) {
  "use workflow";
  const messages: ModelMessage[] = [...initialMessages];
  const hook = chatMessageHook.create({ token: runId });

  while (true) {
    await agent.stream({ messages, writable, preventClose: true });
    const { message: followUp } = await hook;  // Wait for next user message
    if (followUp === "/done") break;
    messages.push({ role: "user", content: followUp });
  }
}
```

**Key insight**: Event growth is manageable for many practical use cases. 3000 events for 1000 messages is workable.

### Pi Coding Agent: Session Persistence with LLM Compaction

The pi-mono coding agent demonstrates a pragmatic "semi-durable" approach.

#### Architecture

JSONL files with tree structure for session persistence:

```
~/.pi/agent/sessions/{cwd-hash}/{timestamp}_{sessionId}.jsonl

Session File Structure:
├── SessionHeader { type: "session", id, cwd, version }
├── SessionMessageEntry { type: "message", id, parentId, message: AgentMessage }
├── ThinkingLevelChangeEntry { type: "thinking_level_change", thinkingLevel }
├── ModelChangeEntry { type: "model_change", provider, modelId }
├── CompactionEntry { type: "compaction", summary, firstKeptEntryId, tokensBefore }
├── BranchSummaryEntry { type: "branch_summary", fromId, summary }
├── CustomEntry { type: "custom", customType, data }  ← Extension state
└── LabelEntry { type: "label", targetId, label }     ← User bookmarks
```

Each entry has `id` + `parentId` enabling **in-place tree branching**.

#### Automatic LLM Compaction

```typescript
// From compaction.ts - when context approaches limits
if (contextTokens > contextWindow - reserveTokens) {
  // Find cut point that keeps ~20K recent tokens
  const cutPoint = findCutPoint(entries, keepRecentTokens);

  // Generate structured summary of old messages
  const summary = await generateSummary(messagesToSummarize, model, {
    previousSummary,  // Iterative update of existing summary
  });

  // Store compaction entry with file operations tracking
  session.appendCompaction(summary, firstKeptEntryId, tokensBefore, {
    readFiles: [...],
    modifiedFiles: [...],
  });
}
```

**Summary format is structured:**
```markdown
## Goal
[What user is trying to accomplish]

## Progress
### Done
- [x] Completed items
### In Progress
- [ ] Current work

## Key Decisions
- **Decision**: Rationale

## Next Steps
1. Ordered list

## Critical Context
- Data/references needed
```

#### Gap Analysis: Semi-Durable vs Full Durable

| Feature | Pi Agent | Full Durable |
|---------|----------|--------------|
| Message persistence | ✅ Full | ✅ |
| Resume capability | ✅ Full | ✅ |
| Context compaction | ✅ Auto LLM | ✅ |
| File operations tracking | ✅ Full | ✅ |
| In-flight tool execution | ❌ None | ✅ |
| Streaming state | ❌ Lost on crash | ✅ |
| Abort state | ❌ Not persisted | ✅ |

---

## Recovery Models Comparison

| Model | How It Works | Pros | Cons |
|-------|--------------|------|------|
| **Event Sourcing** (Temporal) | Replay all events | Full audit trail | Slow recovery, unbounded growth |
| **Checkpoint Resume** (DBOS) | Resume from last step | Fast recovery | Less granular audit |
| **Message-Level** (Pi agent) | Persist complete messages | Simple, fast | No mid-operation recovery |
| **Hybrid** | Events for ops, K/V for state | Best of both | More complex |

---

## Context Management Strategies

### Strategy 1: Continue-As-New (Manual)

```rust
if ctx.is_continue_as_new_suggested() {
    // Drain signals
    while ctx.has_signal("message") { ... }
    // Continue with state
    ctx.continue_as_new(ConversationState { history })?;
}
```

**Pros**: Explicit control, preserves full history in separate executions
**Cons**: Complex signal draining, developer burden

### Strategy 2: LLM Compaction (Automatic)

```rust
if estimated_tokens > COMPACTION_THRESHOLD {
    let summary = generate_summary(&messages, &previous_summary).await?;
    state.compaction = Some(CompactionInfo { summary, ... });
    state.messages = state.messages.split_off(cut_point);
}
```

**Pros**: Automatic, preserves semantic meaning, tracks file operations
**Cons**: LLM cost, potential information loss

### Strategy 3: Sliding Window (Simple)

```rust
if messages.len() > MAX_MESSAGES {
    messages = messages.split_off(messages.len() - KEEP_RECENT);
}
```

**Pros**: Simple, predictable, no LLM cost
**Cons**: Loses context abruptly, no semantic preservation

### Recommendation

Use **LLM Compaction** for AI conversations:
1. Preserves semantic meaning
2. Tracks what was done (file operations)
3. Automatic - no developer burden
4. Cost is acceptable for long-running conversations

---

## Tool Execution Durability

### Levels of Durability

1. **Tool-Level** (Start + Final Result)
   ```
   Events: TOOL_STARTED, TOOL_COMPLETED
   ```
   - If crash during tool, entire tool re-runs
   - Simple, low overhead

2. **Step-Level** (Internal Checkpoints)
   ```
   Events: TOOL_STARTED, STEP_1_DONE, STEP_2_DONE, TOOL_COMPLETED
   ```
   - Long-running tools can checkpoint progress
   - Resume from last step

3. **Full Event Sourcing** (Every Operation)
   ```
   Events: TOOL_STARTED, FILE_READ, API_CALL, PARSE_RESULT, TOOL_COMPLETED
   ```
   - Maximum observability
   - High overhead

### Recommendation

**Tool-Level** for most tools, **Step-Level** for long-running tools:

```rust
// Standard tool - restart on failure
#[tool]
async fn read_file(ctx: &ToolContext, path: &str) -> Result<String> {
    std::fs::read_to_string(path)
}

// Long-running tool with checkpoints
#[tool(checkpoints = true)]
async fn search_codebase(ctx: &ToolContext, query: &str) -> Result<Vec<Match>> {
    let mut results = ctx.checkpoint.get("results").unwrap_or_default();

    for dir in directories {
        if ctx.checkpoint.has(&dir) { continue; }
        let matches = search_directory(&dir, query).await?;
        results.extend(matches);
        ctx.checkpoint.set(&dir, true);
    }

    Ok(results)
}
```

---

## Streaming State

### The Problem

LLM responses stream token-by-token. If crash during streaming:
- Partial response is lost
- Must re-request from LLM (cost + latency)

### Options

1. **Accept Loss**: Checkpoint only complete messages
2. **Buffer + Checkpoint**: Periodically checkpoint partial response
3. **Stream to Durable Log**: Write tokens to durable stream

### Recommendation

**Accept Loss** for most cases:
- LLM calls are relatively cheap to retry
- Partial responses are rarely useful
- Simplicity wins

For critical conversations, consider **Buffer + Checkpoint** with large intervals (every 1000 tokens).

---

## Proposed Flovyn Architecture for Durable AI Agents

### Hybrid Model

```
Flovyn Workflow (tracks operations):
├── SIGNAL_RECEIVED: user message
├── STEP_STARTED: llm_call
├── STEP_COMPLETED: llm_call
├── STEP_STARTED: tool_read_file
├── STEP_COMPLETED: tool_read_file
└── ...

External State Store (full content):
├── messages: AgentMessage[]
├── compaction: { summary, readFiles, modifiedFiles }
├── lastCheckpoint: timestamp
└── metadata: { model, thinkingLevel }
```

### Implementation

```rust
#[workflow]
async fn agent_turn(ctx: &WorkflowContext, conv_id: &str, msg: Message) -> Result<Response> {
    // Load state
    let mut state: ConversationState = ctx.state.get(conv_id)?;

    // Auto-compact if needed
    if estimate_tokens(&state.messages) > THRESHOLD {
        let summary = ctx.step("compact", || generate_summary(&state)).await?;
        state.apply_compaction(summary);
    }

    state.messages.push(ChatMessage::user(&msg));

    // Durable LLM call
    let response = ctx.step("llm", || call_llm(&state.messages)).await?;
    state.messages.push(ChatMessage::assistant(&response));

    // Execute tools durably
    for tool_call in response.tool_calls {
        let result = ctx.step(&format!("tool_{}", tool_call.name), || {
            execute_tool(&tool_call)
        }).await?;
        state.messages.push(ChatMessage::tool_result(&result));
    }

    // Save state
    ctx.state.set(conv_id, &state);

    Ok(response)
}
```

### Benefits

1. **Lightweight event log**: Operations only, not full message content
2. **Full observability**: Can see what tools ran, when
3. **Fast recovery**: Load state from K/V, resume from last step
4. **Auto-compaction**: Context managed automatically
5. **File tracking**: Know what was read/modified

---

## Open Questions

### Q1: Compaction Model Selection

Should compaction be configurable per conversation type?

Options:
- A) Global default with per-workflow override
- B) Always LLM compaction
- C) Pluggable compaction strategies

**Recommendation**: (A) - Sensible defaults, escape hatch for custom needs.

### Q2: Compaction Summary Model

Which model should generate summaries?

Options:
- A) Same model as conversation
- B) Dedicated cheap model (gpt-4o-mini, claude-haiku)
- C) Configurable

**Recommendation**: (C) with default of (B) - Cheap model is usually sufficient.

### Q3: File Operations Tracking

How detailed should file tracking be?

Options:
- A) Just paths (readFiles, modifiedFiles)
- B) Paths + operation type (read, write, edit, delete)
- C) Full diffs

**Recommendation**: (B) - Useful for context without excessive storage.

---

## References

### Competitor Documentation
- [DBOS Customer Service Agent](https://docs.dbos.dev/python/examples/customer-service)
- [DBOS Agent Inbox](https://docs.dbos.dev/python/examples/agent-inbox)
- [Vercel Workflow Chat Modeling](https://sdk.vercel.ai/docs/ai-sdk-core/workflow)

### Source Code Analyzed
- `competitors/pi-mono/packages/coding-agent/src/core/session-manager.ts`
- `competitors/pi-mono/packages/coding-agent/src/core/compaction/compaction.ts`
- `competitors/pi-mono/packages/agent/src/agent-loop.ts`
