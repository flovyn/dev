# Developer Experience for AI Agents

This document defines how developers build, run, and debug AI agents on Flovyn.

**Related documents:**
- [Content Storage Strategy](./20260103_11_content_storage_strategy.md) - Storage architecture and compression
- [Architecture Patterns](./20260103_01_architecture_patterns.md) - Agent loop patterns
- [Human-in-the-Loop](./20260103_04_human_in_the_loop.md) - Approval flows

---

## Industry Comparison

Before designing Flovyn's DX, let's understand what developers expect from existing SDKs.

### OpenAI Agents SDK Patterns

```python
# Agent definition - declarative dataclass
agent = Agent(
    name="assistant",
    instructions="You are a helpful assistant",
    tools=[get_weather, search_files],
    handoffs=[specialist_agent],
    model="gpt-4.1",
    model_settings=ModelSettings(temperature=0.7),
    hooks=MyAgentHooks(),
    output_type=StructuredOutput,
)

# Tool definition - decorator
@function_tool
def get_weather(city: str) -> str:
    """Get weather for a city."""
    return f"Weather in {city}: sunny"

# Session for memory persistence
session = SQLiteSession("user_123", "conversations.db")

# Execution
result = await Runner.run(agent, "What's the weather?", session=session)
```

**Key patterns:**
- Declarative agent config via dataclass
- `@function_tool` decorator auto-generates schema from type hints
- Session protocol: `get_items()`, `add_items()`, `clear_session()`
- Lifecycle hooks: `on_llm_start`, `on_llm_end`, `on_tool_start`, `on_tool_end`, `on_handoff`
- Context object for dependency injection

### Claude Agent SDK Patterns

```python
# Options-based configuration
options = ClaudeAgentOptions(
    system_prompt="You are a code assistant",
    allowed_tools=["Read", "Write", "Bash"],
    mcp_servers={"tools": my_mcp_server},
    permission_mode="acceptEdits",
    max_turns=10,
    model="sonnet",
    hooks={"PreToolUse": [HookMatcher(matcher="Bash", hooks=[check_command])]},
)

# Tool definition via MCP
@tool("greet", "Greet a user", {"name": str})
async def greet_user(args):
    return {"content": [{"type": "text", "text": f"Hello, {args['name']}!"}]}

server = create_sdk_mcp_server(name="tools", tools=[greet_user])

# Execution
async with ClaudeSDKClient(options=options) as client:
    await client.query("Hello")
    async for msg in client.receive_response():
        if isinstance(msg, AssistantMessage):
            for block in msg.content:
                if isinstance(block, ThinkingBlock):
                    print(f"Thinking: {block.thinking}")
```

**Key patterns:**
- Options dataclass for all configuration
- MCP servers for tool registration (in-process or external)
- Hooks with pattern matching: `PreToolUse`, `PostToolUse`, `UserPromptSubmit`
- `ThinkingBlock` is a first-class content type
- Permission system: `allow`, `deny`, `ask`

### What Both Have in Common

| Aspect | OpenAI | Claude | Why It Matters |
|--------|--------|--------|----------------|
| **Declarative config** | Agent dataclass | ClaudeAgentOptions | Easy to understand and modify |
| **Tool decorator** | `@function_tool` | `@tool` | Type-safe, auto-schema |
| **Lifecycle hooks** | Class-based hooks | Dict-based hooks | Observability and control |
| **Context injection** | `RunContextWrapper[T]` | `HookContext` | Dependency injection |
| **Structured output** | `output_type=` | `output_format=` | Typed responses |

### What They're Missing (That Flovyn Provides)

| Gap | OpenAI | Claude | Flovyn |
|-----|--------|--------|--------|
| **Durability** | Session stores history, but no replay | No persistence | Event sourcing - full state reconstruction |
| **Resume on failure** | No | No | Yes - workflow checkpoints |
| **Content separation** | All in session items | All in messages | Large content in content_store |
| **Reasoning capture** | Not built-in | ThinkingBlock exists | ThinkingBlock + auto-storage |
| **Compression** | Manual | Manual (PreCompact hook) | Automatic with checkpoints |

---

## Flovyn's Agent API

Based on industry patterns + Flovyn's unique capabilities:

### 1. Agent Definition

```rust
use flovyn_agent::{Agent, AgentConfig, Tool, tool};

#[derive(Default)]
struct CodeAssistant;

impl Agent for CodeAssistant {
    fn name(&self) -> &str { "code-assistant" }

    fn config(&self) -> AgentConfig {
        AgentConfig {
            // Instructions (system prompt)
            instructions: "You are a code assistant. Help users with their code.",

            // Model configuration
            model: "claude-sonnet-4-20250514",
            model_settings: ModelSettings {
                temperature: 0.7,
                max_tokens: 4096,
            },

            // Tools available to this agent
            tools: vec![
                Tool::ReadFile,
                Tool::WriteFile,
                Tool::Search,
                Tool::Bash,
                Tool::Custom(my_custom_tool()),
            ],

            // Context management (automatic)
            context: ContextConfig {
                compression_threshold: 0.7,  // Compress at 70% of limit
                compression_strategy: CompressionStrategy::LlmSummary,
                preserve_recent: 0.3,        // Keep latest 30% unchanged
            },

            // Approval policy
            approval: ApprovalPolicy::RequireFor(vec!["WriteFile", "Bash"]),

            // Reasoning capture (default: ON)
            capture_reasoning: true,
        }
    }

    async fn execute(&self, ctx: &AgentContext) -> Result<AgentOutput> {
        // Developer writes the agent loop
        let input = ctx.input::<UserRequest>()?;

        ctx.set_system_prompt(&self.config().instructions).await?;
        ctx.add_message(Role::User, &input.prompt).await?;

        loop {
            let response = ctx.call_llm().await?;
            ctx.add_message(Role::Assistant, &response.content).await?;

            for tool_call in response.tool_calls {
                let result = ctx.execute_tool(&tool_call).await?;
                ctx.add_tool_result(&tool_call.id, &result).await?;
            }

            if response.is_done() {
                break;
            }
        }

        Ok(AgentOutput {
            response: ctx.last_assistant_message()?,
        })
    }
}
```

### 2. Tool Definition

**Pattern 1: Decorator-style (like OpenAI/Claude)**

```rust
use flovyn_agent::{tool, ToolContext};

#[tool(
    name = "search_codebase",
    description = "Search for code patterns in the codebase"
)]
async fn search_codebase(
    ctx: &ToolContext,
    #[arg(description = "The search query")] query: String,
    #[arg(description = "File pattern to search")] pattern: Option<String>,
) -> Result<String> {
    let results = do_search(&query, pattern.as_deref()).await?;
    Ok(format_results(&results))
}

// Schema auto-generated from function signature:
// {
//   "name": "search_codebase",
//   "description": "Search for code patterns in the codebase",
//   "parameters": {
//     "type": "object",
//     "properties": {
//       "query": { "type": "string", "description": "The search query" },
//       "pattern": { "type": "string", "description": "File pattern to search" }
//     },
//     "required": ["query"]
//   }
// }
```

**Pattern 2: Struct-based (for complex tools)**

```rust
use flovyn_agent::{Tool, ToolInput, ToolOutput};

struct FileEditor;

#[derive(Deserialize, JsonSchema)]
struct EditInput {
    path: String,
    old_content: String,
    new_content: String,
}

#[async_trait]
impl Tool for FileEditor {
    fn name(&self) -> &str { "edit_file" }

    fn description(&self) -> &str {
        "Edit a file by replacing content"
    }

    fn input_schema(&self) -> JsonSchema {
        schema_for!(EditInput)
    }

    async fn execute(&self, ctx: &ToolContext, input: Value) -> Result<ToolOutput> {
        let input: EditInput = serde_json::from_value(input)?;

        // Tool implementation
        let result = edit_file(&input.path, &input.old_content, &input.new_content).await?;

        Ok(ToolOutput::text(result))
    }
}
```

### 3. Context Management

The `AgentContext` handles all context operations automatically:

```rust
/// What developers see
trait AgentContext {
    // === Messages ===

    /// Add a message to the conversation
    async fn add_message(&self, role: Role, content: &str) -> Result<()>;

    /// Get all messages (respects compression - may return checkpoint + recent)
    async fn messages(&self) -> Result<Vec<Message>>;

    /// Get raw LLM-formatted messages
    async fn llm_messages(&self) -> Result<Vec<LlmMessage>>;

    // === LLM Calls ===

    /// Call the LLM with current context
    async fn call_llm(&self) -> Result<LlmResponse>;

    /// Call with specific model (override config)
    async fn call_llm_with_model(&self, model: &str) -> Result<LlmResponse>;

    // === Tools ===

    /// Execute a tool (handles approval automatically)
    async fn execute_tool(&self, tool_call: &ToolCall) -> Result<String>;

    /// Add tool result to context
    async fn add_tool_result(&self, tool_id: &str, result: &str) -> Result<()>;

    // === State ===

    /// Get typed input
    fn input<T: DeserializeOwned>(&self) -> Result<T>;

    /// Get/set workflow state
    async fn get_state<T: DeserializeOwned>(&self, key: &str) -> Result<Option<T>>;
    async fn set_state<T: Serialize>(&self, key: &str, value: &T) -> Result<()>;

    // === Observability ===

    /// Get context statistics
    async fn context_stats(&self) -> Result<ContextStats>;

    /// Get last assistant message
    fn last_assistant_message(&self) -> Result<String>;
}
```

**What happens behind the scenes:**

```rust
impl AgentContext {
    pub async fn call_llm(&self) -> Result<LlmResponse> {
        // 1. Build context from checkpoint + recent messages
        let messages = self.build_context().await?;

        // 2. Check if compression needed BEFORE the call
        if self.should_compress(&messages) {
            self.compress_context().await?;
            // Rebuild after compression
            messages = self.build_context().await?;
        }

        // 3. Call LLM with thinking blocks enabled (default)
        let response = self.llm_client
            .chat(&messages)
            .model(&self.config.model)
            .thinking(self.config.capture_reasoning)
            .await?;

        // 4. Store response in content store
        let response_ref = self.content_store
            .store(&response.content, ContentType::AssistantMessage)
            .await?;

        // 5. Store thinking block if present
        let thinking_ref = if let Some(thinking) = &response.thinking {
            Some(self.content_store.store(thinking, ContentType::ThinkingBlock).await?)
        } else {
            None
        };

        // 6. Infer attribution (best-effort)
        let attribution = self.infer_attribution(&messages, &response);

        // 7. Emit event (durable)
        self.emit_event(AgentEvent::LlmCalled {
            model: self.config.model.clone(),
            input_tokens: response.usage.input_tokens,
            output_tokens: response.usage.output_tokens,
            response_ref,
            thinking_ref,
            attribution,
        }).await?;

        Ok(response)
    }
}
```

### 4. Lifecycle Hooks

Like OpenAI/Claude, but workflow-native:

```rust
#[async_trait]
trait AgentHooks {
    /// Called before LLM call
    async fn on_llm_start(
        &self,
        ctx: &HookContext,
        messages: &[LlmMessage],
    ) -> Result<()> {
        Ok(())
    }

    /// Called after LLM call
    async fn on_llm_end(
        &self,
        ctx: &HookContext,
        response: &LlmResponse,
    ) -> Result<()> {
        Ok(())
    }

    /// Called before tool execution
    async fn on_tool_start(
        &self,
        ctx: &HookContext,
        tool_call: &ToolCall,
    ) -> Result<ToolDecision> {
        Ok(ToolDecision::Allow)
    }

    /// Called after tool execution
    async fn on_tool_end(
        &self,
        ctx: &HookContext,
        tool_call: &ToolCall,
        result: &str,
    ) -> Result<()> {
        Ok(())
    }

    /// Called before context compression
    async fn on_compress_start(
        &self,
        ctx: &HookContext,
        stats: &CompressionStats,
    ) -> Result<()> {
        Ok(())
    }

    /// Called after context compression
    async fn on_compress_end(
        &self,
        ctx: &HookContext,
        checkpoint: &Checkpoint,
    ) -> Result<()> {
        Ok(())
    }

    /// Called when approval is needed
    async fn on_approval_needed(
        &self,
        ctx: &HookContext,
        action: &Action,
    ) -> Result<ApprovalDecision> {
        Ok(ApprovalDecision::Ask)  // Default: ask user
    }
}

enum ToolDecision {
    Allow,
    Deny { reason: String },
    Modify { new_args: Value },
}
```

### 5. Registration and Execution

```rust
// Register agent with Flovyn
let worker = FlovynWorker::new()
    .register_agent::<CodeAssistant>()
    .register_agent::<DataAnalyst>()
    .connect("grpc://flovyn:9090")
    .await?;

// Or start via workflow
let workflow_id = client
    .start_agent("code-assistant", AgentInput { prompt: "Help me refactor auth.rs" })
    .await?;

// Agent runs durably - survives crashes, can be resumed
```

---

## Configuration Options

### AgentConfig Reference

```rust
struct AgentConfig {
    // === Core ===

    /// System prompt / instructions
    instructions: String,

    /// Default model for LLM calls
    model: String,

    /// Model-specific settings
    model_settings: ModelSettings,

    /// Tools available to this agent
    tools: Vec<Tool>,

    // === Context Management ===

    context: ContextConfig,

    // === Approval ===

    /// When to require human approval
    approval: ApprovalPolicy,

    // === Reasoning Capture ===

    /// Capture thinking blocks (default: true)
    capture_reasoning: bool,

    // === Limits ===

    /// Maximum turns before stopping
    max_turns: Option<u32>,

    /// Maximum cost in USD
    max_cost_usd: Option<f64>,
}

struct ContextConfig {
    /// Compress when context reaches this ratio of model limit (default: 0.7)
    compression_threshold: f32,

    /// How to compress
    compression_strategy: CompressionStrategy,

    /// Ratio of recent messages to preserve (default: 0.3)
    preserve_recent: f32,
}

enum CompressionStrategy {
    /// Use LLM to summarize (recommended)
    LlmSummary { model: Option<String> },

    /// Sliding window - drop oldest messages
    SlidingWindow { max_messages: usize },

    /// No compression - fail if limit exceeded
    None,
}

enum ApprovalPolicy {
    /// Never require approval
    None,

    /// Require for specific tools
    RequireFor(Vec<String>),

    /// Require for all tools
    RequireAll,

    /// Custom policy
    Custom(Box<dyn ApprovalFn>),
}

struct ModelSettings {
    temperature: f32,
    max_tokens: u32,
    top_p: Option<f32>,
    stop_sequences: Vec<String>,
}
```

### Dynamic Configuration

Like both SDKs, configuration can be changed at runtime:

```rust
async fn execute(&self, ctx: &AgentContext) -> Result<AgentOutput> {
    // Start with default model
    let plan = ctx.call_llm().await?;  // Uses config.model

    // Switch to better model for complex task
    ctx.set_model("claude-opus-4-20250514").await?;
    let analysis = ctx.call_llm().await?;  // Uses opus

    // Or per-call override
    let quick_check = ctx.call_llm_with_model("claude-haiku").await?;

    // Change compression strategy mid-execution
    ctx.set_compression_strategy(CompressionStrategy::None).await?;
}
```

---

## What Developers Get for Free

### Automatic (Zero Configuration)

| Feature | What Happens | Developer Effort |
|---------|--------------|------------------|
| **Event sourcing** | All actions recorded as events | None |
| **Content storage** | Large payloads stored efficiently | None |
| **Deduplication** | Same content stored once | None |
| **Checkpoint** | State saved for resume | None |
| **Context tracking** | Token counts maintained | None |
| **Timing** | Duration of each operation | None |
| **Attribution** | Why decisions were made (inferred) | None |

### Default ON (Can Opt-Out)

| Feature | Default | Opt-Out |
|---------|---------|---------|
| **Reasoning capture** | ThinkingBlock stored | `capture_reasoning: false` |
| **Auto-compression** | At 70% of limit | `compression_strategy: None` |
| **Approval for writes** | Ask for file writes | `approval: None` |

### Opt-In (Need Configuration)

| Feature | How to Enable |
|---------|---------------|
| **Custom tools** | Register in `tools` |
| **Custom hooks** | Implement `AgentHooks` |
| **Structured output** | Define `output_type` |
| **Multi-agent** | Register multiple agents, use handoffs |

---

## Debugging Tools

After execution, developers have access to:

### 1. CLI Tools

```bash
# List agent runs
flovyn agent list --workflow-type code-assistant

# Inspect specific run
flovyn agent inspect <workflow-id>

# Time travel to specific point
flovyn agent state-at <workflow-id> --sequence 15

# View decisions and reasoning
flovyn agent decisions <workflow-id>

# View token usage over time
flovyn agent tokens <workflow-id>

# Search across runs
flovyn agent search --query "tool:edit_file" --failed
```

### 2. Debug API

```rust
// Get state at any point
let snapshot = debug_client
    .get_state_at(workflow_id, sequence: 15)
    .await?;

println!("Context at step 15:");
println!("  Messages: {}", snapshot.messages.len());
println!("  Tokens: {}", snapshot.token_count);
println!("  LLM saw: {:?}", snapshot.llm_context);

// Get decision points
let decisions = debug_client
    .get_decisions(workflow_id)
    .await?;

for d in decisions {
    println!("Step {}: {} ({})", d.sequence, d.action, d.attribution);
    if let Some(thinking) = d.thinking {
        println!("  Reasoning: {}", thinking);
    }
}

// Compression audit
let audit = debug_client
    .compression_audit(workflow_id, checkpoint_seq: 20)
    .await?;

println!("Compression at step 20:");
println!("  Before: {} messages, {} tokens", audit.messages_before, audit.tokens_before);
println!("  After: {} tokens (summary)", audit.tokens_after);
println!("  Preserved: {:?}", audit.preserved);
println!("  Potentially lost: {:?}", audit.potentially_lost);
```

### 3. What's Captured for Debugging

| Data | How It's Captured | When Available |
|------|-------------------|----------------|
| **LLM calls** | Auto (event) | Always |
| **Tool calls** | Auto (event) | Always |
| **Tool results** | Auto (content store) | Always |
| **Context at each step** | Reconstructable from events | Always |
| **Thinking/reasoning** | Auto if `capture_reasoning: true` | Default ON |
| **Attribution** | Inferred | Always (~70% accuracy) |
| **Token counts** | From LLM response | Always |
| **Compression details** | Auto (checkpoint event) | When compression occurs |

---

## Multi-Agent Patterns

Both OpenAI and Claude SDKs support multi-agent orchestration. Flovyn adds durable orchestration.

### Industry Patterns

**OpenAI Agents SDK - Handoffs:**

```python
# Define specialized agents
spanish_agent = Agent(name="spanish", instructions="Respond in Spanish")
english_agent = Agent(name="english", instructions="Respond in English")

# Triage agent routes to specialists
triage_agent = Agent(
    name="triage",
    instructions="Route to appropriate language specialist",
    handoffs=[spanish_agent, english_agent],
)

# Handoff = transfer conversation to another agent
result = await Runner.run(triage_agent, "Hola, como estas?")
# → Triage hands off to spanish_agent
```

**OpenAI - Agent as Tool:**

```python
# Agent can call other agents as tools (not handoff)
research_agent = Agent(name="researcher", ...)
writer_agent = Agent(
    name="writer",
    tools=[research_agent.as_tool("researcher", "Research a topic")],
)
# Writer calls researcher, gets result back, continues writing
```

**Claude Agent SDK - Sub-agents:**

```python
# Define custom agents
agents = {
    "code-reviewer": AgentDefinition(
        description="Reviews code for issues",
        prompt="You are a code reviewer...",
        tools=["Read", "Grep"],
    ),
    "test-writer": AgentDefinition(
        description="Writes tests",
        prompt="You are a test writer...",
        tools=["Read", "Write"],
    ),
}

options = ClaudeAgentOptions(
    agents=agents,
    allowed_tools=["Task"],  # Task tool spawns sub-agents
)
```

### Flovyn's Multi-Agent Support

Flovyn provides three patterns, all with durable execution:

#### Pattern 1: Handoffs (Transfer Control)

Like OpenAI, but durable:

```rust
struct TriageAgent;

impl Agent for TriageAgent {
    fn config(&self) -> AgentConfig {
        AgentConfig {
            instructions: "Route to appropriate specialist",
            handoffs: vec![
                Handoff::to::<SpanishAgent>()
                    .description("Handles Spanish conversations"),
                Handoff::to::<EnglishAgent>()
                    .description("Handles English conversations"),
            ],
            ..Default::default()
        }
    }

    async fn execute(&self, ctx: &AgentContext) -> Result<AgentOutput> {
        let response = ctx.call_llm().await?;

        // LLM decides to handoff
        if let Some(handoff) = response.handoff {
            // Durable handoff - survives crashes
            return ctx.handoff(handoff).await;
        }

        Ok(AgentOutput::done(response.content))
    }
}
```

**What happens on handoff:**

```
Event log:
  seq=1: AgentStarted { agent: "triage" }
  seq=2: LlmCalled { ... }
  seq=3: HandoffRequested { to: "spanish" }
  seq=4: AgentStarted { agent: "spanish" }  ← New agent takes over
  seq=5: LlmCalled { ... }
  seq=6: AgentCompleted { agent: "spanish" }
```

#### Pattern 2: Agent as Tool (Call & Return)

Agent calls another agent, gets result, continues:

```rust
struct WriterAgent;

impl Agent for WriterAgent {
    fn config(&self) -> AgentConfig {
        AgentConfig {
            instructions: "Write articles with research",
            tools: vec![
                Tool::AgentTool {
                    agent: "researcher",
                    description: "Research a topic in depth",
                },
                Tool::WriteFile,
            ],
            ..Default::default()
        }
    }

    async fn execute(&self, ctx: &AgentContext) -> Result<AgentOutput> {
        loop {
            let response = ctx.call_llm().await?;

            for tool_call in response.tool_calls {
                if tool_call.name == "researcher" {
                    // This runs researcher agent as a child workflow
                    // Durable: if writer crashes, researcher result is preserved
                    let research = ctx.execute_tool(&tool_call).await?;
                    ctx.add_tool_result(&tool_call.id, &research).await?;
                }
            }

            if response.is_done() { break; }
        }

        Ok(AgentOutput::done(ctx.last_assistant_message()?))
    }
}
```

**Event log shows nesting:**

```
Parent (writer):
  seq=1: AgentStarted { agent: "writer" }
  seq=2: LlmCalled { decision: "need research" }
  seq=3: ChildWorkflowStarted { child_id: "abc", agent: "researcher" }
  seq=4: ChildWorkflowCompleted { child_id: "abc", result: "..." }  ← Durable result
  seq=5: LlmCalled { with research result }
  seq=6: AgentCompleted

Child (researcher):
  seq=1: AgentStarted { agent: "researcher" }
  seq=2: LlmCalled { ... }
  seq=3: ToolCalled { tool: "web_search" }
  seq=4: AgentCompleted { result: "..." }
```

#### Pattern 3: Orchestrator (Explicit Control)

Developer explicitly controls agent routing:

```rust
struct OrchestratorAgent;

impl Agent for OrchestratorAgent {
    async fn execute(&self, ctx: &AgentContext) -> Result<AgentOutput> {
        let input = ctx.input::<TaskRequest>()?;

        // Phase 1: Planning
        let plan = ctx.run_agent::<PlannerAgent>(PlannerInput {
            task: input.task.clone(),
        }).await?;

        // Phase 2: Execute each step (parallel or sequential)
        let mut results = Vec::new();
        for step in plan.steps {
            let result = match step.agent.as_str() {
                "coder" => ctx.run_agent::<CoderAgent>(step.input.clone()).await?,
                "reviewer" => ctx.run_agent::<ReviewerAgent>(step.input.clone()).await?,
                "tester" => ctx.run_agent::<TesterAgent>(step.input.clone()).await?,
                _ => return Err(anyhow!("Unknown agent: {}", step.agent)),
            };
            results.push(result);
        }

        // Phase 3: Synthesize
        let final_result = ctx.run_agent::<SynthesizerAgent>(SynthesizerInput {
            results,
        }).await?;

        Ok(AgentOutput::done(final_result))
    }
}
```

#### Pattern 4: Parallel Agents

Run multiple agents concurrently:

```rust
async fn execute(&self, ctx: &AgentContext) -> Result<AgentOutput> {
    // Run multiple agents in parallel (all durable)
    let (code_review, security_scan, performance_check) = tokio::join!(
        ctx.run_agent::<CodeReviewer>(input.clone()),
        ctx.run_agent::<SecurityScanner>(input.clone()),
        ctx.run_agent::<PerformanceAnalyzer>(input.clone()),
    );

    // Combine results
    let combined = CombinedAnalysis {
        code_issues: code_review?.issues,
        security_issues: security_scan?.issues,
        performance_issues: performance_check?.issues,
    };

    Ok(AgentOutput::done(combined))
}
```

### Multi-Agent Communication

#### Shared Context

```rust
// Parent can share context with children
ctx.run_agent_with_context::<ResearcherAgent>(
    ResearcherInput { query: "auth patterns" },
    SharedContext {
        // Share relevant messages from parent
        include_messages: ctx.filter_messages(|m| m.has_tag("important")),
        // Share state
        shared_state: ctx.get_state("project_info").await?,
    },
).await?
```

#### Message Passing

```rust
// Agents communicate via workflow state
ctx.set_state("researcher_findings", &findings).await?;

// Other agent reads it
let findings: Findings = ctx.get_state("researcher_findings").await?
    .ok_or(anyhow!("No findings"))?;
```

### Multi-Agent Debugging

```bash
# View full execution tree
flovyn agent tree <workflow-id>

# Output:
# writer (workflow-123)
# ├── seq 3: researcher (child-abc) ✓
# │   ├── seq 2: web_search
# │   └── seq 3: completed
# └── seq 5: completed

# Debug specific child
flovyn agent inspect child-abc

# View cross-agent decisions
flovyn agent decisions <workflow-id> --include-children
```

### Multi-Agent Comparison

| Pattern | OpenAI | Claude | Flovyn |
|---------|--------|--------|--------|
| **Handoff** | `handoffs=[...]` | Via Task tool | `Handoff::to::<Agent>()` |
| **Agent as tool** | `agent.as_tool()` | Via Task tool | `Tool::AgentTool` |
| **Parallel** | Manual `asyncio.gather` | Manual | `tokio::join!` + durable |
| **Orchestrator** | Manual | Manual | `ctx.run_agent()` |
| **Durability** | None | None | Full (survives crashes) |
| **Child visibility** | Separate traces | Separate | Same workflow tree |
| **Shared context** | Manual | Manual | `SharedContext` |

### When to Use Which Pattern

| Pattern | Use Case |
|---------|----------|
| **Handoff** | Language routing, expertise switching, conversation transfer |
| **Agent as Tool** | Agent needs specific capability, then continues |
| **Orchestrator** | Complex workflows with explicit control flow |
| **Parallel** | Independent analyses that can run concurrently |

---

## Comparison with Existing SDKs

### OpenAI Agents SDK

| Aspect | OpenAI | Flovyn |
|--------|--------|--------|
| Agent definition | `Agent` dataclass | `Agent` trait |
| Tool definition | `@function_tool` | `#[tool]` |
| Memory | `Session` protocol (SQLite, Redis) | Event sourcing (built-in) |
| Context limit | Manual handling | Automatic compression |
| Hooks | Class-based (`AgentHooks`) | Trait-based (`AgentHooks`) |
| Resume on failure | No | Yes (workflow checkpoint) |
| Multi-agent | Handoffs | Handoffs + child workflows |

### Claude Agent SDK

| Aspect | Claude | Flovyn |
|--------|--------|--------|
| Agent definition | `ClaudeAgentOptions` dataclass | `Agent` trait + `AgentConfig` |
| Tool definition | MCP servers | `#[tool]` + optional MCP |
| Memory | No built-in | Event sourcing (built-in) |
| Context limit | Manual (PreCompact hook) | Automatic compression |
| Hooks | Dict-based matchers | Trait-based |
| ThinkingBlock | First-class | First-class + auto-stored |
| Permission | `allow`/`deny`/`ask` | `ApprovalPolicy` |
| Resume on failure | No | Yes (workflow checkpoint) |

### What Flovyn Adds

```
OpenAI/Claude SDKs                    Flovyn
━━━━━━━━━━━━━━━━━━━━━━              ━━━━━━━━━━━━━━━━━━━━━━

                                     ┌─────────────────────┐
┌─────────────────────┐              │  Same DX patterns   │
│  Developer writes   │      →       │  (familiar API)     │
│  agent code         │              └──────────┬──────────┘
└─────────────────────┘                         │
                                                ▼
                                     ┌─────────────────────┐
┌─────────────────────┐              │  Automatic storage  │
│  External storage   │      →       │  (content store)    │
│  (manual)           │              └──────────┬──────────┘
└─────────────────────┘                         │
                                                ▼
                                     ┌─────────────────────┐
┌─────────────────────┐              │  Automatic compress │
│  Manual compression │      →       │  (with checkpoints) │
│  (or none)          │              └──────────┬──────────┘
└─────────────────────┘                         │
                                                ▼
                                     ┌─────────────────────┐
┌─────────────────────┐              │  Durable execution  │
│  No durability      │      →       │  (event sourcing)   │
│  (crash = lost)     │              └──────────┬──────────┘
└─────────────────────┘                         │
                                                ▼
                                     ┌─────────────────────┐
┌─────────────────────┐              │  Full debug tools   │
│  Basic tracing      │      →       │  (time travel, etc) │
│  (external)         │              └─────────────────────┘
└─────────────────────┘
```

---

## Summary

### Developer Writes

```rust
// 1. Define agent
impl Agent for MyAgent {
    fn config(&self) -> AgentConfig { ... }
    async fn execute(&self, ctx: &AgentContext) -> Result<AgentOutput> { ... }
}

// 2. Define tools
#[tool]
async fn my_tool(ctx: &ToolContext, arg: String) -> Result<String> { ... }

// 3. Optional: Define hooks
impl AgentHooks for MyHooks { ... }
```

### System Provides

- Event sourcing (state reconstruction)
- Content storage (large payload handling)
- Automatic compression (context management)
- Reasoning capture (thinking blocks)
- Attribution inference (decision tracking)
- Durable execution (crash recovery)
- Debug tools (time travel, decision analysis)

### The Goal

**Writing an AI agent should feel like writing normal async code. The infrastructure complexity (durability, storage, compression, debugging) is handled by the platform.**
