# Observability Requirements

## 7.1 Essential Metrics

| Metric | Purpose | Frameworks Tracking |
|--------|---------|---------------------|
| Token usage | Cost, context management | All |
| Tool execution time | Performance | Gemini CLI, Codex |
| Turn count | Loop detection | All |
| Error rates | Reliability | All |
| Approval latency | UX | Codex, Dyad |
| Context compression events | Memory management | Gemini CLI, Temporal |

## 7.2 Telemetry Events

**Gemini CLI's comprehensive telemetry:**
```typescript
logToolCall(config, new ToolCallEvent(completedCall));
logAgentStart(config, new AgentStartEvent(agentId, name));
logAgentFinish(config, new AgentFinishEvent(agentId, duration, turnCount));
logChatCompression(config, new ChatCompressionEvent(tokensBefore, tokensAfter));
logContentRetry(config, new ContentRetryEvent(attempt, errorType));
```

**Source:** `gemini-cli/packages/core/src/telemetry/`

## 7.3 Conversation Replay

**Critical for debugging AI agents:**
- Full message history with tool calls/results
- Timing information per step
- Decision points (approvals, branches)
- Error context with stack traces

## 7.4 Flovyn's Unique Advantage: Causal Observability

Flovyn's event-sourced architecture enables observability beyond what tools like Langfuse provide:

| Langfuse Shows | Flovyn Can Show |
|----------------|-----------------|
| "LLM called with prompt X, returned Y" | "LLM called BECAUSE condition Z, AFTER retrieving docs A,B,C, LEADING TO tool T" |
| Flat list of LLM calls | Causal graph of decisions |
| Single run analysis | Cross-run pattern detection |

### 7.4.1 Causal Transparency

Every workflow event already captures causal relationships:

```rust
// Extend workflow events with reasoning context
struct ReasoningContext {
    decision: String,              // "call_retrieval_tool"
    trigger: String,               // "user_query_ambiguous"
    state_snapshot: Value,         // relevant state at decision time
    prior_event_ids: Vec<String>,  // events that led here
}

// Attach to agent events
enum AgentEvent {
    ToolCalled {
        tool_name: String,
        call_id: String,
        arguments: Value,
        reasoning: Option<ReasoningContext>,  // Why this tool?
    },
    // ...
}
```

### 7.4.2 Cross-Run Intelligence

Flovyn's event store enables patterns impossible with per-run tools:

```rust
// Analytics queries enabled by event sourcing
trait AgentAnalytics {
    // "30% of runs with condition Y fail at step Z"
    fn find_failure_patterns(&self, workflow_id: &str) -> Vec<FailurePattern>;

    // "Agent solving task X differently than last week"
    fn detect_reasoning_drift(&self, workflow_id: &str, window: Duration) -> DriftReport;

    // "Performance improving over time on task T"
    fn track_performance_trend(&self, agent_id: &str, metric: &str) -> TrendAnalysis;
}
```

## 7.5 Recommended Event Schema

```rust
// Agent-specific workflow events
enum AgentWorkflowEvent {
    TurnStarted {
        turn_number: u32,
        context_token_estimate: u32,
    },

    ToolCalled {
        tool_name: String,
        call_id: String,
        arguments: Value,
        reasoning: Option<ReasoningContext>,
    },

    ToolCompleted {
        call_id: String,
        result: Value,
        duration_ms: u64,
        success: bool,
    },

    ApprovalRequested {
        request_id: String,
        action: String,
        context: Value,
    },

    ApprovalReceived {
        request_id: String,
        decision: ApprovalDecision,
        latency_ms: u64,
    },

    ContextCompressed {
        strategy: String,
        tokens_before: u32,
        tokens_after: u32,
        checkpoint_id: String,
        preserved_percentage: f32,
    },

    LoopDetected {
        pattern: String,
        turn_count: u32,
    },

    TurnCompleted {
        turn_number: u32,
        tokens_used: u32,
        duration_ms: u64,
    },
}
```

## 7.6 Integration Strategy: Flovyn + External Tools

Don't replace existing observability tools - complement them:

```
┌─────────────────────────────────────┐
│        Developer UI / API           │
└────────────┬───────────────────────┘
             │
    ┌────────┴──────────┐
    │                   │
    ▼                   ▼
┌──────────┐      ┌─────────────┐
│ Langfuse │      │   Flovyn    │
│   (UI)   │◄─────│ Observability│
└──────────┘      │   Service   │
                  └──────┬──────┘
                         │
        ┌────────────────┴────────────────┐
        │                                 │
        ▼                                 ▼
   ┌─────────┐                    ┌──────────┐
   │ Event   │                    │ Causal   │
   │ Store   │                    │ Graph    │
   └─────────┘                    └──────────┘
```

**Data Flow:**
1. **Workflow execution** → Events stored in Flovyn (causal, structured)
2. **LLM calls** → Exported to Langfuse (for prompt/response inspection)
3. **Reasoning analysis** → Flovyn analytics (patterns, drift, trends)
4. **Human debugging** → Langfuse UI (qualitative review, scoring)
5. **Forensic replay** → Flovyn (deterministic re-execution)

### Export Adapter

```rust
// Export agent runs to external observability tools
struct LangfuseExporter {
    client: LangfuseClient,
}

impl LangfuseExporter {
    async fn export_workflow_run(&self, run_id: &str) -> Result<()> {
        let events = self.event_store.get_events(run_id).await?;

        // Create trace
        let trace = self.client.create_trace(TraceInput {
            id: run_id.to_string(),
            name: workflow.name.clone(),
            metadata: json!({
                "org_id": workflow.org_id,
                "causality": extract_causal_graph(&events),
            }),
        }).await?;

        // Export LLM calls as spans
        for event in events.iter().filter_map(|e| e.as_llm_call()) {
            self.client.create_span(SpanInput {
                trace_id: trace.id.clone(),
                name: event.model.clone(),
                input: event.prompt.clone(),
                output: event.response.clone(),
                metadata: event.reasoning.clone(),
            }).await?;
        }

        Ok(())
    }
}
```

## 7.7 Dashboards and Alerts

**Key dashboards:**
- Token usage over time (cost tracking)
- Tool success/failure rates
- Average turn count per session
- Approval wait times
- Context compression frequency
- Cross-run pattern trends

**Critical alerts:**
- High error rates
- Excessive token usage (budget exceeded)
- Long-running agents (potential loops)
- Approval queue depth
- Frequent context compression (agent struggling)
- Reasoning drift detected

## 7.8 Instrumentation Levels

Balance visibility vs overhead:

```rust
enum InstrumentationLevel {
    Minimal,    // Events only, no payloads
    Standard,   // + tool arguments/results
    Detailed,   // + reasoning context, state snapshots
    Full,       // + token counts, embeddings
}

// Configure per-org or per-workflow
struct ObservabilityConfig {
    level: InstrumentationLevel,
    sampling_rate: f32,           // 0.1 = 10% of runs
    export_to_langfuse: bool,
    retain_days: u32,
}
```

## 7.9 Natural Language Debugging (Future)

Leverage LLMs for observability:

```rust
// Query agent runs in natural language
trait AgentDebugger {
    // "Show me runs where the agent changed its plan mid-execution"
    async fn query(&self, question: &str) -> DebugResult;

    // "Why did workflow X fail at step Y?"
    async fn explain_failure(&self, run_id: &str, step: u32) -> Explanation;

    // "What's different between successful and failed runs?"
    async fn compare_outcomes(&self, workflow_id: &str) -> ComparisonReport;
}
```

## Source Code References

- Gemini CLI telemetry: `gemini-cli/packages/core/src/telemetry/`
- Previous Flovyn observability design: `leanapp/flovyn/docs/plans/ai-observability/`
