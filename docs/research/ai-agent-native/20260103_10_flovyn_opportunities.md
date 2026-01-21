# Flovyn Opportunities

## 10.1 Current Flovyn Strengths

1. **Event-sourced workflows** - Natural fit for agent state
2. **Durable timers** - Support long-running agents
3. **Task execution model** - Maps to tool execution
4. **Multi-tenancy** - Enterprise-ready
5. **gRPC streaming** - Real-time communication

## 10.2 Gaps to Address

| Gap | Current State | Recommendation |
|-----|---------------|----------------|
| **Human-in-the-loop** | Basic promise support | Add approval primitives |
| **Streaming output** | Limited | Add streaming task output |
| **Context compression** | None | Add LLM-aware history management |
| **Tool registry** | Manual | Add dynamic tool registration |
| **Sandboxing** | None | Add execution policies |
| **Large event payloads** | Content inline in events | Content-addressed store (see [11-content-storage-strategy.md](./20260103_11_content_storage_strategy.md)) |

## 10.3 Recommended Additions

### 10.3.1 Agent-Native Primitives

```rust
// New workflow commands for AI agents
enum AgentCommand {
    // Tool execution with approval
    ExecuteTool {
        tool_name: String,
        args: Value,
        requires_approval: bool,
    },

    // Streaming output
    StreamOutput {
        chunk: OutputChunk,
    },

    // Context management
    CompressHistory {
        strategy: CompressionStrategy,
    },

    // Human-in-the-loop
    RequestApproval {
        action: String,
        context: Value,
        timeout: Duration,
    },
}
```

### 10.3.2 Agent Workflow Template

```rust
// Opinionated agent workflow structure
struct AgentWorkflow {
    // Configuration
    max_turns: u32,
    loop_detection: LoopDetectionConfig,
    approval_policy: ApprovalPolicy,

    // State
    conversation: ConversationState,
    tool_registry: ToolRegistry,

    // Execution
    fn step() -> StepResult;
    fn compress_if_needed() -> Result<()>;
    fn request_approval() -> Promise<ApprovalDecision>;
}
```

### 10.3.3 Observability Enhancements

```rust
// Agent-specific events
enum AgentEvent {
    TurnStarted { turn_number: u32 },
    ToolCalled { tool: String, duration: Duration },
    ApprovalRequested { action: String },
    ContextCompressed { before: usize, after: usize },
    LoopDetected { pattern: String },
}
```

### 10.3.4 Context Management System

**Option A: Event-Sourced Context with Checkpoints (Recommended)**

```rust
// Leverage Flovyn's existing event sourcing
struct AgentContext {
    // Full event log (like workflow_event table)
    events: Vec<AgentEvent>,

    // Periodic checkpoints for fast reconstruction
    checkpoints: Vec<ContextCheckpoint>,

    // Current working context (derived from events)
    working_context: WorkingContext,
}

struct ContextCheckpoint {
    event_index: u64,           // Position in event log
    summary: ContextSummary,    // LLM-generated or algorithmic
    token_estimate: u32,        // For context window tracking
    created_at: DateTime,
}

struct ContextSummary {
    overall_goal: String,
    key_facts: Vec<String>,
    current_plan: Vec<PlanStep>,
    tool_results_summary: HashMap<String, String>,
}

impl AgentContext {
    // Check if compression needed (Gemini-style)
    fn needs_compression(&self, model_limit: u32) -> bool {
        self.working_context.token_estimate > (model_limit as f32 * 0.7) as u32
    }

    // Compress using continue-as-new pattern (Temporal-style)
    async fn compress(&mut self, llm: &LlmClient) -> Result<()> {
        // 1. Generate summary of old events
        let summary = llm.summarize(&self.events[..self.split_point()]).await?;

        // 2. Create checkpoint
        let checkpoint = ContextCheckpoint {
            event_index: self.events.len() as u64,
            summary,
            token_estimate: estimate_tokens(&summary),
            created_at: Utc::now(),
        };
        self.checkpoints.push(checkpoint);

        // 3. Rebuild working context from checkpoint + recent events
        self.working_context = self.rebuild_from_checkpoint(&checkpoint)?;

        Ok(())
    }

    // Reconstruct context for LLM call
    fn to_llm_messages(&self) -> Vec<Message> {
        let mut messages = vec![];

        // Add latest checkpoint summary
        if let Some(checkpoint) = self.checkpoints.last() {
            messages.push(Message::system(format!(
                "<context_summary>\n{}\n</context_summary>",
                checkpoint.summary.to_xml()
            )));
        }

        // Add recent events since checkpoint
        for event in &self.events[self.checkpoint_index()..] {
            messages.extend(event.to_messages());
        }

        messages
    }
}
```

**Option B: Workflow-Native Compression via Continue-as-New**

```rust
// Use Flovyn's workflow system directly
impl AgentWorkflow {
    async fn maybe_continue_as_new(&self) -> Result<()> {
        if self.turn_count >= self.config.max_turns_before_compression {
            // Generate summary as a task
            let summary = self.execute_task(
                "compress_context",
                CompressContextInput {
                    conversation: self.conversation.clone(),
                    strategy: self.config.compression_strategy,
                }
            ).await?;

            // Continue-as-new with summary as initial state
            return Err(WorkflowAction::ContinueAsNew {
                input: AgentWorkflowInput {
                    initial_context: Some(summary),
                    ..self.input.clone()
                }
            });
        }
        Ok(())
    }
}
```

**Compression Strategies to Support:**

```rust
enum CompressionStrategy {
    // LLM generates structured XML summary (Gemini-style)
    LlmStructuredSummary {
        model: String,
        prompt_template: String,
        preserve_recent_percentage: f32,  // e.g., 0.3 = keep 30%
    },

    // Simple 2-sentence summary (Temporal-style)
    LlmBriefSummary {
        model: String,
        max_sentences: u32,
    },

    // Algorithmic: keep last N messages
    SlidingWindow {
        max_messages: u32,
    },

    // Algorithmic: keep last N tokens worth
    TokenBudget {
        max_tokens: u32,
        truncation_strategy: TruncationStrategy,
    },

    // Hybrid: algorithmic with periodic LLM summaries
    Hybrid {
        window_size: u32,
        summarize_every_n_turns: u32,
        llm_config: LlmSummaryConfig,
    },
}
```

**Tool Call Preservation (Dyad-style):**

```rust
// Store raw tool calls for fidelity
struct ToolCallRecord {
    call_id: String,
    tool_name: String,
    arguments: Value,
    result: ToolResult,
    timestamp: DateTime,

    // For reconstruction
    sdk_format: Option<Value>,  // Raw SDK message format
}

// Reconstruct tool call chain for LLM
fn reconstruct_tool_messages(records: &[ToolCallRecord]) -> Vec<Message> {
    records.iter().flat_map(|r| vec![
        Message::assistant_tool_call(r.call_id.clone(), r.tool_name.clone(), r.arguments.clone()),
        Message::tool_result(r.call_id.clone(), r.result.clone()),
    ]).collect()
}
```

**Integration with Flovyn's Event System:**

```rust
// New workflow event types for agents
enum WorkflowEvent {
    // Existing events...
    TaskScheduled { ... },
    TaskCompleted { ... },

    // New agent-specific events
    AgentTurnStarted {
        turn_number: u32,
        context_token_estimate: u32,
    },
    AgentToolCalled {
        tool_name: String,
        call_id: String,
        arguments: Value,
    },
    AgentToolCompleted {
        call_id: String,
        result: Value,
        duration_ms: u64,
    },
    AgentContextCompressed {
        strategy: String,
        tokens_before: u32,
        tokens_after: u32,
        checkpoint_id: String,
    },
    AgentApprovalRequested {
        request_id: String,
        action: String,
        context: Value,
    },
    AgentApprovalReceived {
        request_id: String,
        decision: ApprovalDecision,
    },
}
```

**API for Context Access:**

```rust
// New gRPC service for agent context
service AgentContextService {
    // Get current context for debugging/replay
    rpc GetContext(GetContextRequest) returns (GetContextResponse);

    // Force compression
    rpc CompressContext(CompressContextRequest) returns (CompressContextResponse);

    // Get context checkpoint history
    rpc ListCheckpoints(ListCheckpointsRequest) returns (ListCheckpointsResponse);

    // Restore to checkpoint (for debugging)
    rpc RestoreCheckpoint(RestoreCheckpointRequest) returns (RestoreCheckpointResponse);
}
```

## 10.4 Differentiation Opportunities

| Opportunity | Why Flovyn | Competitors |
|-------------|------------|-------------|
| **Event-sourced agents** | Native support | Temporal only |
| **Multi-org agents** | Built-in | Manual setup |
| **Hybrid local/cloud** | Worker model | Limited |
| **Enterprise security** | JWT/RBAC ready | Basic |
| **Context checkpointing** | Event log + checkpoints | None native |

## 10.5 Recommended Roadmap

1. **Phase 0**: Content-addressed store for large payloads (foundational)
2. **Phase 1**: Add approval primitives (Promise-based HITL)
3. **Phase 2**: Add streaming task output
4. **Phase 3**: Add agent workflow template with context management
5. **Phase 4**: Add MCP server integration
6. **Phase 5**: Add sandboxing policies
7. **Phase 6**: Add context compression strategies (LLM + algorithmic)

**Note:** Phase 0 (content storage) should be implemented first as it enables efficient context management in Phase 3 and 6. See [11-content-storage-strategy.md](./20260103_11_content_storage_strategy.md) for details.
