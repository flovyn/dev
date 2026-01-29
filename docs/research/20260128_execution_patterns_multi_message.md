# Research: Execution Patterns for Multi-Message Workflows

**Date**: 2026-01-28
**Status**: Research
**Related**: [SignalWithStart Design](../design/20260127_implement_signalwithstart.md)

---

## Summary

This document explores different execution patterns for handling multi-message workflows (like chatbots) in durable execution systems. The core challenge is **unbounded event/journal growth** when a single workflow handles many messages over time.

## The Problem

In event-sourced durable execution systems (Temporal, Restate, Vercel Workflow), every operation creates an event that must be replayed on recovery:

```
1000-message conversation:
├── 1000 SIGNAL_RECEIVED events (one per user message)
├── 1000 STEP events (AI calls)
├── 1000+ TOOL events (tool executions)
└── Total: 3000+ events to replay on each wake-up
```

This creates:
- Slow recovery times
- Memory pressure during replay
- Event storage costs
- Potential hard limits (Temporal: 51,200 events)

---

## Pattern 1: Workflow + Signals + Continue-As-New (Temporal-Style)

**Use for**: Complex orchestration, saga patterns, approval workflows

```rust
async fn conversation_workflow(ctx: &WorkflowContext, state: Option<ConversationState>) -> Result<()> {
    let mut history = state.map(|s| s.history).unwrap_or_default();

    loop {
        // Signal creates an event (queue semantics)
        let msg: Message = ctx.wait_for_signal("message").await?;

        let response = process(&msg, &history).await?;
        history.push(ChatMessage { user: msg, assistant: response });

        // Check if history is getting too long
        if ctx.is_continue_as_new_suggested() {
            // Drain remaining signals first!
            while ctx.has_signal("message") {
                let msg: Message = ctx.wait_for_signal("message").await?;
                // ... process
            }
            // Continue as new with conversation state
            ctx.continue_as_new(ConversationState { history })?;
        }
    }
}
```

**Characteristics:**
- Single long-running workflow execution
- Signals are queue-based (each signal = event)
- Continue-As-New resets event history with state carryover
- Must drain signals before Continue-As-New (or they're lost)

**Required Features:**
1. `ctx.wait_for_signal()` - queue-based signal reception
2. `ctx.is_continue_as_new_suggested()` - history size tracking
3. `ctx.continue_as_new(state)` - reset history with state carryover
4. `ctx.has_signal()` - check for buffered signals

**Pros:**
- Coordinated flow across messages
- Full audit trail in event history
- Mature pattern (Temporal)

**Cons:**
- Complex Continue-As-New handling
- Must manage signal draining
- Overhead of full replay between Continue-As-New

---

## Pattern 2: Entity/Handler (Restate Virtual Object-Style)

**Use for**: Chatbots, multi-message conversations, state machines

```rust
#[entity("conversation")]
impl Conversation {
    #[handler]
    async fn send_message(&self, ctx: &EntityContext, msg: Message) -> Result<Response> {
        // Each call is a SEPARATE invocation with ~3 events

        // State is stored in entity K/V, not events
        let mut history: Vec<ChatMessage> = ctx.state.get("history").unwrap_or_default();
        history.append(ChatMessage::user(&msg));

        let response = ctx.run("ai", || call_ai(&history)).await?;
        history.append(ChatMessage::assistant(&response));

        ctx.state.set("history", &history);

        Ok(response)
    }
}

// Each HTTP call creates a NEW invocation with fresh, small history
// POST /conversation/conv-123/send_message {"text": "Hello"}  → 3 events
// POST /conversation/conv-123/send_message {"text": "World"}  → 3 events (new invocation!)
```

**Characteristics:**
- Each message = separate invocation with bounded events
- State in K/V, not reconstructed from events
- No Continue-As-New needed
- Automatic "start-or-route" semantics

**Pros:**
- Naturally bounded event history
- Simple mental model
- No signal buffering complexity
- Fast recovery (small event log per invocation)

**Cons:**
- No coordination between messages (each handler is independent)
- State must be explicitly loaded/saved each call
- No "workflow-level" logic spanning multiple messages

---

## Pattern 3: Separated State Model (DBOS-Inspired)

**Use for**: AI chatbots where conversation state is large/complex

```rust
#[derive(Serialize, Deserialize)]
struct ConversationState {
    messages: Vec<ChatMessage>,
    context: LLMContext,
    metadata: ConversationMetadata,
}

// Workflow handles DURABLE OPERATIONS only
#[workflow]
async fn handle_user_message(ctx: &WorkflowContext, conversation_id: &str, msg: Message) -> Result<Response> {
    // Load conversation state from K/V (not from workflow events)
    let mut state: ConversationState = ctx.state.get(conversation_id)?;

    // Add user message
    state.messages.push(ChatMessage::user(&msg));

    // Durable AI call (checkpointed)
    let response = ctx.step("ai_call", || call_ai(&state.messages)).await?;

    // Add assistant response
    state.messages.push(ChatMessage::assistant(&response));

    // Save state back to K/V
    ctx.state.set(conversation_id, &state);

    Ok(response)
}
```

**Key Insight (from DBOS):**
- Workflow events track OPERATIONS (AI calls, tool executions)
- Conversation state is in EXTERNAL STORAGE (K/V, database)
- Recovery = resume from last step checkpoint + load conversation from K/V
- No unbounded workflow event growth from messages themselves

**Pros:**
- Lightweight workflow journal (operations only)
- Large conversation state doesn't bloat events
- Fast recovery

**Cons:**
- Two storage systems (events + K/V)
- Consistency between workflow and state store
- More complex implementation

---

## Pattern 4: Actor with Message Queue (Hybrid)

**Use for**: Long-running AI conversations with complex coordination

```rust
#[actor("conversation")]
impl ConversationActor {
    // Actor is long-lived but state is snapshotted
    async fn on_activate(&self, ctx: &ActorContext) -> Result<()> {
        // Load state from K/V (not replay)
        self.history = ctx.state.get("history")?;
    }

    #[message]
    async fn send_message(&self, ctx: &ActorContext, msg: Message) -> Result<Response> {
        // Message creates a small event log for THIS operation only
        let response = ctx.run("ai", || call_ai(&self.history, &msg)).await?;

        self.history.push(ChatEntry { user: msg, assistant: response });

        // Periodic snapshot (not per-message)
        if self.history.len() % 10 == 0 {
            ctx.state.set("history", &self.history);
        }

        Ok(response)
    }

    async fn on_deactivate(&self, ctx: &ActorContext) -> Result<()> {
        // Final state snapshot on passivation
        ctx.state.set("history", &self.history);
    }
}
```

**Characteristics:**
- Long-lived in-memory state between messages
- Periodic snapshots (not per-message)
- Bounded events per operation
- Actor can be passivated/reactivated on any node

**Pros:**
- Coordination between messages (unlike Entity/Handler)
- Bounded event log (unlike Workflow+Signals)
- In-memory state for performance

**Cons:**
- Requires actor placement/routing
- Requires passivation/reactivation lifecycle
- More complex runtime (similar to Orleans/Akka)

---

## Pattern Comparison

| Aspect | Workflow+Signals | Entity/Handler | Separated State | Actor |
|--------|------------------|----------------|-----------------|-------|
| **State source** | Events (replay) | K/V per call | K/V + checkpoints | K/V with snapshots |
| **Event log** | Unbounded | Bounded per call | Bounded (ops only) | Bounded per message |
| **Coordination** | Full replay | None (stateless) | None | In-memory |
| **Recovery** | Full replay | Load state | Checkpoint + K/V | Load snapshot |
| **Complexity** | High | Low | Medium | High |
| **Continue-As-New** | Required | Not needed | Not needed | Not needed |

## When to Use Which

| Use Case | Recommended Pattern |
|----------|---------------------|
| **Chatbot conversations** | Entity/Handler or Separated State |
| **Order processing with updates** | Entity/Handler |
| **Saga orchestration** | Workflow + Signals |
| **Approval workflows** | Workflow + Signals |
| **Batch processing** | Workflow + Continue-As-New |
| **Complex AI agent with tool coordination** | Actor or Separated State |

---

## Competitor Implementations

### Temporal
- Uses Workflow + Signals pattern
- Continue-As-New for long-running workflows
- Hard limits: 51,200 events, 50MB history

### Restate
- Virtual Objects for Entity/Handler pattern
- Workflows for one-shot operations (NOT for loops)
- No Continue-As-New for Workflows (architectural choice)

### Vercel Workflow
- Multi-turn pattern (Workflow + hooks)
- No Continue-As-New (accepts growth)
- Optimizes for developer experience

### DBOS
- Separated State Model
- Step-based checkpoints (not event replay)
- External K/V for application state

---

## Open Questions

### Should Flovyn implement all four patterns?

**Recommendation**: Start with Entity/Handler + Workflow+Signals, defer Actor.

1. **Entity/Handler** - Covers most multi-message use cases
2. **Workflow+Signals** - Covers saga/orchestration use cases
3. **Actor** - Defer until real-world demand is clear

### How should patterns be exposed in SDKs?

Options:
- A) Separate decorators: `@workflow`, `@entity`, `@actor`
- B) Single decorator with mode: `@durable(mode="entity")`
- C) Implicit based on usage patterns

**Recommendation**: (A) - Clear, explicit, no magic.

---

## References

- [Temporal Workflows](https://docs.temporal.io/workflows)
- [Temporal Continue-As-New](https://docs.temporal.io/workflow-execution/continue-as-new)
- [Restate Virtual Objects](https://docs.restate.dev/concepts/durable_building_blocks/#virtual-objects)
- [DBOS Workflows](https://docs.dbos.dev/typescript/reference/methods)
- [Microsoft Orleans](https://learn.microsoft.com/en-us/dotnet/orleans/)
