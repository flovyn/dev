# Durable Execution Requirements

## 3.1 Why AI Agents Need Durable Execution

**Problem: LLM calls are expensive and unreliable**
- API calls can timeout (30s-5min typical)
- Rate limits cause retries
- Network failures mid-stream
- Context window management requires checkpointing

**Temporal AI Agent Pattern** (most mature):
```python
# Each LLM call is a durable activity
tool_data = await workflow.execute_activity_method(
    ToolActivities.agent_toolPlanner,
    args=...,
    retry_policy=RetryPolicy(
        initial_interval=timedelta(seconds=5),
        backoff_coefficient=1
    ),
    start_to_close_timeout=timedelta(seconds=20)
)
```

**Source:** `temporal-ai-agent/workflows/agent_goal_workflow.py:134-177`

## 3.2 Key Durability Features Needed

| Feature | Description | Frameworks Using |
|---------|-------------|------------------|
| **Activity Retries** | Automatic retry with backoff for LLM calls | Temporal, Hatchet, Restate |
| **Checkpointing** | Save state after each tool execution | All |
| **Continue-as-New** | Prevent unbounded history growth | Temporal, Restate |
| **Timeout Handling** | Configurable per-activity timeouts | All |
| **Cancellation** | Graceful abort with cleanup | All |
| **Idempotency** | Deduplicate duplicate requests | Temporal, Hatchet, Restate |

## 3.3 Event Sourcing for AI Agents

**Restate Pattern** (most elegant for AI):
```
Journal Entry Types:
├── Call          → Invoke another service/tool
├── OneWayCall    → Fire-and-forget
├── Sleep         → Durable timer
├── GetState      → Read keyed state
├── SetState      → Write keyed state
├── GetPromise    → Await external signal
├── CompletePromise → Resolve signal
└── Run           → Execute side-effect
```

**Benefits for AI Agents:**
1. **Deterministic Replay**: On crash, replay journal to reconstruct state
2. **Tool Result Caching**: Never re-execute successful tool calls
3. **Long-Running Support**: Agent can suspend for hours/days
4. **Exactly-Once Semantics**: Tools execute exactly once despite failures

**Source:** `restate/crates/types/src/journal_v2/`

## Source Code References

- Temporal: `temporal/` (full SDK)
- Restate: `restate/crates/types/src/journal_v2/`
- Hatchet: `flovyn-server/hatchet/sql/schema/v1-core.sql`
