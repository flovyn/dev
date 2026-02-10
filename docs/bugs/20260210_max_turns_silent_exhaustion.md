# Bug: max_turns_per_round silently exhausted — agent stops without summary

**Date:** 2026-02-10
**Severity:** Medium (user-facing UX degradation)
**Status:** Quick fix applied (terminal status), long-term improvement needed
**Affected component:** agent-server (`src/workflows/agent.rs`)

## Symptom

User asks agent "What are common topics that people are working on that they mention in HN?". The agent runs 25 LLM+tool iterations (writing files, running bash commands), then silently stops and goes to WAITING state. No summary is ever presented to the user. The UI shows "Agent is working..." but the agent has actually given up.

## Observed Workflow

Workflow `3d3f35de-c947-4d9a-aa6b-ae81fd596bf1`:

| Seq | Event | Detail |
|-----|-------|--------|
| 25 | SIGNAL_RECEIVED | User's second message |
| 27-223 | TASK_SCHEDULED/COMPLETED x50 | 25 LLM requests + 25 tool executions |
| 225 | TASK_COMPLETED | Last bash task completed with output |
| 226-228 | STATE_SET | Messages + usage saved |
| 229 | WORKFLOW_SUSPENDED | `suspendType: SUSPEND_TYPE_SIGNAL` |

- **25 LLM requests** in the second turn (counted from events)
- `max_turns_per_round` defaults to **25** (`agent.rs:36`)
- The `for _ in 0..max_turns_per_round` loop exhausted all iterations
- After the loop, the workflow falls through to line 152-164: save state, then `wait_for_signal_raw("userMessage")`

## Root Cause

In `agent-server/src/workflows/agent.rs:40`, the inner loop:

```rust
for _ in 0..max_turns_per_round {
    // ... LLM call + tool execution ...
    if tool_calls.is_empty() {
        break;  // Normal exit: LLM returned text-only
    }
    // Execute tools, continue loop
}
// Falls through here when max_turns exhausted OR when break is hit
// Both paths are identical — no distinction
```

When the loop runs all `max_turns_per_round` iterations without the LLM returning a text-only response, it silently falls through to the signal wait. There is:

1. **No indication** to the user that max turns was reached
2. **No final LLM call** to summarize what was accomplished
3. **No state marker** to distinguish "agent chose to stop" vs "agent was forcibly stopped"

## Why this is NOT a reclamation/replay bug

Initial hypothesis was that server restart caused the workflow to lose its place. Investigation proved this wrong:
- All 229 events were committed to the database before any restart
- The last LLM response (seq 221) had `stopReason: "toolUse"` — the LLM wanted to continue
- Event 229 is `SUSPEND_TYPE_SIGNAL` — the workflow chose to suspend for signal
- This happened during normal execution, not after reclamation

## Quick Fix Applied

When `max_turns_per_round` is exhausted, the workflow now completes with `{ "reason": "turn_limit_reached" }` instead of silently suspending for a signal. The frontend shows "Agent reached its turn limit." banner (orange, same as failed/cancelled). Test: `test_turn_limit_completes_workflow`.

This is a hard stop — the user cannot continue the conversation.

## How Other Systems Handle This

Research into Replit, Lovable, Devin, Cursor, and Claude Code shows most systems do NOT hard-stop:

### 1. Credit/message-based (no per-session turn limit)
- **Lovable**: Each prompt = 1 credit. Free: 5/day, Pro: 100/month. No per-session turn limit — you just run out of credits. Bug-fix prompts are free.
- **Replit**: Usage-based billing (effort-based pricing). Agent 3 runs 200 minutes autonomously. No artificial turn cap — just credit consumption.
- **Devin**: ACU (Agent Compute Unit) system. 150 ACUs/subscription, $2/extra ACU. Performance degrades after 10 ACUs/conversation but doesn't hard stop. Can run for hours/days with persistent memory + todo lists.

### 2. Context window management (auto-continue)
- **Claude Code**: Auto-compacts at ~95% context capacity — summarizes earlier messages and continues seamlessly. No hard stop, but quality degrades with each compaction cycle.
- **Cursor**: Shadow environment for self-testing. Context managed via automatic relevance finding across repository.

### 3. Graceful degradation
- **Devin**: Warns that quality may drop after threshold. Uses persistent memory (todo lists) to maintain coherence across long sessions.
- **Claude Code**: Manual checkpointing at 70% capacity recommended over auto-compact at 95%.

### Key takeaway

Our current hard-stop at 25 turns is the most abrupt approach. Every major competitor either bills per usage (letting users keep going) or auto-compacts context and continues.

## Long-Term Improvement: Context Compaction

Instead of hard-stopping, the agent should **compact its message history and continue**:

1. When approaching the turn limit (or context window limit), summarize the conversation so far into a condensed form
2. Replace the full message history with the summary + recent messages
3. Continue the agent loop with the compacted context

This mirrors Claude Code's auto-compact approach and is the most user-friendly solution.

### Sketch

```rust
for turn in 0..max_turns_per_round {
    // ... existing loop ...

    // Check if context is getting large (e.g., token count approaching model limit)
    if should_compact(&messages, &input.model) {
        let summary = ctx.schedule_raw("llm-request", compact_prompt(&messages)).await?;
        messages = vec![
            Message::system_text(&format!("Conversation summary:\n{}", summary)),
            // Keep last N messages for immediate context
            ...messages[messages.len()-4..].to_vec(),
        ];
        // Reset turn counter — compaction gives us a fresh budget
        // (this requires restructuring the loop)
    }
}
```

### Open questions for compaction approach
- What triggers compaction? Token count vs turn count vs both?
- How many recent messages to preserve after compaction?
- Should we use a separate (cheaper/faster) model for summarization?
- How to handle tool call history — summarize tool results or keep them verbatim?
- Should the user be notified when compaction happens?

## Existing Documentation

This was already identified in the design docs:

> `dev/docs/plans/2026-02-07-multi-turn-conversation.md:166`:
> "**`max_turns_per_round` exhaustion is silent**: When the inner loop hits the turn limit, the workflow transitions directly to `waiting_for_input` with no indication the agent was forcibly stopped."

## Reproduction

1. Start a workflow with a complex task requiring many tool calls (e.g., "Scrape HN and analyze common topics")
2. Use default `max_turns` of 25
3. Observe that after 25 LLM iterations, the agent stops without a summary
4. Workflow enters COMPLETED state with `output.reason = "turn_limit_reached"`
5. UI shows "Agent reached its turn limit." banner

## References

- [Replit Agent Docs](https://docs.replit.com/replitai/agent)
- [Replit Agent 3 Review](https://hackceleration.com/replit-review/)
- [Lovable Free Limits](https://apidog.com/blog/lovable-free-limits-and-open-source-alternative/)
- [Lovable Agent Mode](https://lovable.dev/blog/agent-mode-beta)
- [Devin Pricing](https://devin.ai/pricing/)
- [Devin First Session Docs](https://docs.devin.ai/get-started/first-run)
- [Claude Code Auto-Compact](https://claudelog.com/faqs/what-is-claude-code-auto-compact/)
- [How Claude Code Protects Context](https://hyperdev.matsuoka.com/p/how-claude-code-got-better-by-protecting)
