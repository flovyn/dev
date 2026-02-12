# Research: External Coding Agent Integration

**Date**: 2026-02-11
**Status**: Research
**Related**: [Durable Agent System Plan](../plans/20260211_durable_agent_system.md), [AI Conversation Durability](20260128_ai_conversation_durability.md)

---

## Summary

This document explores how Flovyn's durable agent system can coordinate with external coding agents like Claude Code and Pi. Unlike simple tool calls, coding agents are long-running, interactive, and maintain their own state. We need integration patterns that preserve durability guarantees while enabling multi-turn coordination.

## Problem Statement

### What Makes Coding Agents Different

| Characteristic | Flovyn Task | Coding Agent |
|---------------|-------------|--------------|
| Lifetime | Seconds to minutes | Hours to days |
| Interactions | Single input → output | Multi-turn conversation |
| User involvement | None during execution | Continuous feedback/steering |
| State | Stateless | Rich conversation history |
| Process model | Ephemeral | Long-running |

### Use Cases

1. **Orchestrated coding tasks**: Flovyn agent delegates file modifications to Claude Code or Pi
2. **Multi-agent collaboration**: Different agents for different tasks (Pi for code gen, Claude for review)
3. **Supervised execution**: Flovyn provides durability wrapper around existing coding agents
4. **Hybrid workflows**: Mix Flovyn-native tools with external agent capabilities

---

## External Agent Analysis

### Claude Code

Claude Code is Anthropic's CLI tool for AI-assisted coding.

**Invocation Methods:**
- CLI: `claude` command with various flags
- Print mode: `claude -p "prompt"` for single-shot output
- SDK: Programmatic access via Agent SDK

**Key Characteristics:**
- Maintains conversation state in memory during session
- Supports MCP (Model Context Protocol) for tool integration
- Interactive TUI with multi-turn conversation
- Can be run in non-interactive/headless mode

**Integration Points:**
- Subprocess invocation with stdin/stdout
- Agent SDK for programmatic embedding
- MCP server for standardized tool protocol

### Pi Coding Agent

Pi is an open-source coding agent with sophisticated session management.

**Invocation Methods:**
- CLI: `pi [options] [messages...]`
- RPC mode: `pi --mode rpc` - JSON protocol over stdin/stdout
- SDK: `@mariozechner/pi-coding-agent` npm package
- JSON mode: `pi --mode json` - streams all events as JSON lines

**RPC Protocol:**
```json
// Commands (stdin)
{"type": "prompt", "message": "Your task", "id": "req-1"}
{"type": "steer", "message": "Actually do X instead"}
{"type": "follow_up", "message": "Now do Y"}
{"type": "abort"}
{"type": "get_state"}
{"type": "compact", "customInstructions": "..."}

// Events (stdout)
{"type": "agent_start"}
{"type": "message_update", "assistantMessageEvent": {...}}
{"type": "tool_execution_start", "toolCall": {...}}
{"type": "tool_execution_end", "result": {...}}
{"type": "turn_end"}
{"type": "agent_end", "messages": [...]}
```

**Session Management:**
- JSONL files with tree structure: `~/.pi/agent/sessions/{cwd-hash}/{timestamp}_{sessionId}.jsonl`
- Supports branching, forking, resuming
- Automatic LLM-based compaction when context fills
- Each entry has `id`/`parentId` for tree traversal

**Key Commands (50+):**
- `prompt`, `steer`, `follow_up`, `abort`
- `set_model`, `cycle_model`, `set_thinking_level`
- `get_state`, `get_messages`
- `compact` (manual compaction trigger)
- Session control: `/tree`, `/fork`, `/resume`

---

## Integration Patterns

### Pattern 1: Agent Adapter (External Agent as Flovyn Agent)

Wrap the external agent in a Flovyn `AgentDefinition` that proxies the interaction.

```
┌─────────────────────────────────────────────────────────────────┐
│                  ExternalCodingAgentAdapter                     │
│                  (implements AgentDefinition)                   │
│                                                                 │
│  ┌─────────────┐     ┌──────────────┐     ┌───────────────┐   │
│  │ Flovyn      │────▶│ Event Bridge │────▶│ External      │   │
│  │ AgentContext│◀────│              │◀────│ Agent Process │   │
│  └─────────────┘     └──────────────┘     └───────────────┘   │
│                                                                 │
│  - User signals → agent.steer() / agent.prompt()               │
│  - Agent events → ctx.stream_*() / ctx.append_*()              │
│  - Turn boundaries → ctx.checkpoint()                          │
│  - Session file path stored in checkpoint                      │
└─────────────────────────────────────────────────────────────────┘
```

**Implementation Sketch:**
```rust
pub struct ExternalCodingAgentAdapter {
    agent_type: String, // "pi" | "claude-code"
}

impl AgentDefinition for ExternalCodingAgentAdapter {
    async fn execute(&self, ctx: &dyn AgentContext, input: Input) -> Result<Output> {
        // Restore or start external agent
        let session_file = ctx.state().get("session_file");
        let mut agent = self.spawn_agent(&input.working_dir, session_file).await?;

        // Send initial prompt if new session
        if session_file.is_none() {
            agent.send_prompt(&input.initial_prompt).await?;
        }

        loop {
            tokio::select! {
                // External agent event
                event = agent.next_event() => {
                    match event? {
                        AgentEvent::TextDelta(text) => {
                            ctx.stream_token(&text).await?;
                        }
                        AgentEvent::ToolCall(tool) => {
                            ctx.append_tool_call(&tool).await?;
                        }
                        AgentEvent::ToolResult(result) => {
                            ctx.append_tool_result(&result).await?;
                        }
                        AgentEvent::TurnEnd => {
                            // Checkpoint at turn boundary
                            ctx.checkpoint(json!({
                                "session_file": agent.session_file(),
                                "turn_count": agent.turn_count(),
                            })).await?;

                            // Wait for next user message
                            let signal = ctx.wait_for_signal_raw().await?;
                            agent.send_prompt(&signal.message).await?;
                        }
                        AgentEvent::Complete => break,
                    }
                }

                // User steering signal (interrupt)
                signal = ctx.drain_signals_raw() => {
                    if let Some(sig) = signal {
                        agent.steer(&sig.message).await?;
                    }
                }

                // Cancellation check
                _ = ctx.check_cancellation() => {
                    agent.abort().await?;
                    return Err(anyhow!("Cancelled"));
                }
            }
        }

        Ok(Output { session_file: agent.session_file() })
    }
}
```

**Pros:**
- Fits cleanly into existing Flovyn agent model
- Reuses signals, checkpoints, streaming infrastructure
- No new database tables or server changes
- External agent's session file provides recovery point

**Cons:**
- Two levels of state (Flovyn checkpoint + agent session)
- Must keep external process alive during execution
- Recovery requires re-spawning process and loading session

---

### Pattern 2: Sidecar Process with Session Registry

External agents run as persistent sidecars. Flovyn manages session bindings.

```
┌─────────────────────────────────────────────────────────────────┐
│                        Flovyn Server                            │
│                                                                 │
│  ┌─────────────────┐    ┌─────────────────────────────────┐    │
│  │ agent_execution │───▶│ external_agent_session          │    │
│  │ id: exec-123    │    │ id: eas-456                     │    │
│  │ kind: "pi-proxy"│    │ agent_type: "pi"                │    │
│  │ status: running │    │ process_id: 12345               │    │
│  └─────────────────┘    │ session_file: /tmp/s-123.jsonl  │    │
│                         │ rpc_socket: /tmp/pi-123.sock    │    │
│                         │ status: running                 │    │
│                         │ last_heartbeat: 2026-02-11T...  │    │
│                         └─────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                                    │
                                    │ RPC / Unix socket
                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                    External Agent Process (Sidecar)             │
│  pi --mode rpc --session /tmp/s-123.jsonl --socket /tmp/...    │
│                                                                 │
│  - Long-lived process (survives Flovyn agent restarts)         │
│  - Maintains own conversation state                             │
│  - Receives prompts/steers from Flovyn                         │
│  - Streams events back to Flovyn                               │
└─────────────────────────────────────────────────────────────────┘
```

**New Domain Entity:**
```rust
pub struct ExternalAgentSession {
    pub id: Uuid,
    pub agent_execution_id: Uuid,      // Link to Flovyn agent
    pub agent_type: String,            // "pi", "claude-code"
    pub process_id: Option<i32>,       // OS PID when running
    pub session_file: String,          // Path to agent's session
    pub rpc_endpoint: String,          // Socket/port for RPC
    pub status: ExternalAgentStatus,   // starting, running, suspended, terminated
    pub last_heartbeat: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
}

pub enum ExternalAgentStatus {
    Starting,
    Running,
    Suspended,   // Process stopped, session file preserved
    Terminated,  // Completed or failed
}
```

**Lifecycle:**
1. User starts coding task → Flovyn creates `agent_execution`
2. Flovyn spawns external agent process, creates `external_agent_session`
3. User messages → Flovyn routes to external agent via RPC
4. External agent events → Flovyn streams to frontend
5. User disconnects → External agent continues (or suspends after idle timeout)
6. User reconnects → Flovyn reconnects to existing process or resumes from session file
7. Task complete → External agent terminates, session archived

**Pros:**
- External agent survives Flovyn restarts
- Can detach and reattach to running agents
- Natural fit for long-running coding sessions
- Clear separation of concerns

**Cons:**
- New infrastructure (process manager, session registry)
- More complex deployment (sidecar management)
- Need health checks, process supervision

---

### Pattern 3: Agent-to-Agent Protocol (A2A)

Define a standardized protocol for agent-to-agent communication.

```rust
/// Protocol for communicating with external agents
#[async_trait]
pub trait ExternalAgentProtocol: Send + Sync {
    /// Start a new session with the external agent
    async fn start(&self, config: SessionConfig) -> Result<SessionHandle>;

    /// Send a message (user prompt, follow-up)
    async fn send_message(&self, handle: &SessionHandle, msg: Message) -> Result<()>;

    /// Steer/interrupt the current operation
    async fn steer(&self, handle: &SessionHandle, msg: Message) -> Result<()>;

    /// Subscribe to events from the agent
    fn subscribe(&self, handle: &SessionHandle) -> Pin<Box<dyn Stream<Item = AgentEvent>>>;

    /// Suspend the session (persist state, optionally stop process)
    async fn suspend(&self, handle: &SessionHandle) -> Result<SessionSnapshot>;

    /// Resume a suspended session
    async fn resume(&self, snapshot: SessionSnapshot) -> Result<SessionHandle>;

    /// Abort/cancel the session
    async fn abort(&self, handle: &SessionHandle) -> Result<()>;

    /// Query current state
    async fn get_state(&self, handle: &SessionHandle) -> Result<AgentState>;
}

pub struct SessionConfig {
    pub working_dir: PathBuf,
    pub model: Option<String>,
    pub thinking_level: Option<String>,
    pub tools: Vec<String>,
    pub system_prompt: Option<String>,
}

pub struct SessionHandle {
    pub session_id: String,
    pub process_id: Option<u32>,
    pub rpc_endpoint: String,
}

pub struct SessionSnapshot {
    pub session_file: PathBuf,
    pub config: SessionConfig,
    pub message_count: usize,
    pub last_checkpoint: DateTime<Utc>,
}

pub enum AgentEvent {
    TurnStart,
    TextDelta(String),
    ThinkingDelta(String),
    ToolCallStart { id: String, name: String, input: Value },
    ToolCallEnd { id: String, output: Value },
    TurnEnd,
    Error(String),
    Complete,
}
```

**Protocol Implementations:**
```rust
// Pi coding agent via RPC mode
pub struct PiAgentProtocol {
    process_manager: ProcessManager,
}

// Claude Code via subprocess
pub struct ClaudeCodeProtocol {
    sdk_path: PathBuf,
}

// Generic MCP-based agent
pub struct McpAgentProtocol {
    server_command: String,
}
```

**Orchestrator Agent:**
```rust
impl AgentDefinition for CodingAgentOrchestrator {
    async fn execute(&self, ctx: &dyn AgentContext, input: Input) -> Result<Output> {
        // Select protocol based on agent type
        let protocol: Box<dyn ExternalAgentProtocol> = match input.agent_type.as_str() {
            "pi" => Box::new(PiAgentProtocol::new()),
            "claude-code" => Box::new(ClaudeCodeProtocol::new()),
            _ => return Err(anyhow!("Unknown agent type")),
        };

        // Resume or start session
        let handle = match ctx.state().get::<SessionSnapshot>("snapshot") {
            Some(snapshot) => protocol.resume(snapshot).await?,
            None => protocol.start(input.into()).await?,
        };

        // Initial prompt if new
        if ctx.checkpoint_sequence() == 0 {
            protocol.send_message(&handle, input.initial_prompt.into()).await?;
        }

        // Event loop
        let mut events = protocol.subscribe(&handle);
        loop {
            tokio::select! {
                Some(event) = events.next() => {
                    match event {
                        AgentEvent::TextDelta(text) => ctx.stream_token(&text).await?,
                        AgentEvent::ToolCallStart { id, name, input } => {
                            ctx.append_tool_call(&ToolCall { id, name, input }).await?;
                        }
                        AgentEvent::ToolCallEnd { id, output } => {
                            ctx.append_tool_result(&ToolResult { id, output }).await?;
                        }
                        AgentEvent::TurnEnd => {
                            let snapshot = protocol.suspend(&handle).await?;
                            ctx.checkpoint(json!({"snapshot": snapshot})).await?;

                            let signal = ctx.wait_for_signal_raw().await?;
                            protocol.resume(snapshot).await?;
                            protocol.send_message(&handle, signal.into()).await?;
                        }
                        AgentEvent::Complete => break,
                        AgentEvent::Error(e) => return Err(anyhow!(e)),
                        _ => {}
                    }
                }

                signal = ctx.next_signal(), if ctx.has_pending_signal() => {
                    protocol.steer(&handle, signal.into()).await?;
                }

                _ = ctx.check_cancellation() => {
                    protocol.abort(&handle).await?;
                    return Err(anyhow!("Cancelled"));
                }
            }
        }

        Ok(Output { completed: true })
    }
}
```

**Pros:**
- Clean abstraction over different agents
- Easy to add new agent types
- Testable (can mock protocol)
- Portable across agent implementations

**Cons:**
- Abstraction may not capture all agent-specific features
- Protocol translation overhead
- Need to maintain adapters for each agent

---

### Pattern 4: MCP Bridge (Future)

Use Model Context Protocol as the standardized integration layer.

```
┌─────────────────────────────────────────────────────────────────┐
│                        Flovyn Agent                             │
│                   (MCP Client Implementation)                   │
│                                                                 │
│  - Discovers tools from MCP servers                            │
│  - Calls tools via MCP protocol                                │
│  - Receives structured responses                               │
└──────────────────────────────┬──────────────────────────────────┘
                               │ MCP Protocol (JSON-RPC over stdio/SSE)
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    MCP Server Wrapper                           │
│                                                                 │
│  Exposes external agent as MCP tools:                          │
│  - coding_agent.start_session                                  │
│  - coding_agent.send_message                                   │
│  - coding_agent.steer                                          │
│  - coding_agent.get_status                                     │
│  - coding_agent.abort                                          │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    External Coding Agent                        │
│                    (Pi, Claude Code, etc.)                      │
└─────────────────────────────────────────────────────────────────┘
```

**MCP Tool Definitions:**
```json
{
  "tools": [
    {
      "name": "coding_agent.start_session",
      "description": "Start a new coding agent session",
      "inputSchema": {
        "type": "object",
        "properties": {
          "working_dir": { "type": "string" },
          "agent_type": { "enum": ["pi", "claude-code"] },
          "initial_prompt": { "type": "string" }
        }
      }
    },
    {
      "name": "coding_agent.send_message",
      "description": "Send a message to the coding agent",
      "inputSchema": {
        "type": "object",
        "properties": {
          "session_id": { "type": "string" },
          "message": { "type": "string" }
        }
      }
    }
  ]
}
```

**Pros:**
- Standard protocol (MCP is gaining adoption)
- Works with any MCP-compatible client
- Can expose Flovyn agents as MCP servers too
- Ecosystem compatibility

**Cons:**
- MCP designed for tool calls, not streaming agent interaction
- Would need extensions for long-running sessions
- Additional layer of indirection

---

## Key Design Decisions

### 1. Process Lifetime

| Option | Description | When to Use |
|--------|-------------|-------------|
| **Per-execution** | Spawn/kill with each Flovyn execution | Simple tasks, short sessions |
| **Per-session** | Live while user session active | Interactive coding sessions |
| **Long-lived sidecar** | Persistent process, multiple executions attach | Heavy-weight agents, shared state |

**Recommendation**: Start with **per-execution** for simplicity. Move to **per-session** when user experience demands it.

### 2. State Ownership

| Option | Description | Trade-offs |
|--------|-------------|------------|
| **External agent owns** | Flovyn stores session file path only | Simple, but recovery depends on file |
| **Flovyn mirrors** | Entries synced into `agent_entry` table | Full observability, but duplication |
| **Hybrid** | External agent owns content, Flovyn tracks metadata | Balance of both |

**Recommendation**: **External agent owns** state for MVP. Flovyn checkpoints contain session file path and metadata (turn count, timestamps). Consider mirroring for audit/compliance use cases later.

### 3. Recovery Semantics

| Scenario | Behavior |
|----------|----------|
| Flovyn agent crashes | Restart, load checkpoint, resume external agent from session file |
| External agent crashes | Restart external agent, load session file, continue |
| Both crash | Flovyn restarts first, then restarts external agent with session |
| Session file missing | Start fresh session, inform user of state loss |

**Critical**: External agent session files should be stored on durable storage (not /tmp in production).

### 4. Event Translation

Map external agent events to Flovyn's entry/streaming model:

| External Agent Event | Flovyn Action |
|---------------------|---------------|
| `text_delta` | `ctx.stream_token()` |
| `thinking_delta` | `ctx.stream_token()` (with thinking flag) |
| `tool_call_start` | `ctx.append_tool_call()` |
| `tool_call_end` | `ctx.append_tool_result()` |
| `turn_end` | `ctx.checkpoint()` + `ctx.wait_for_signal()` |
| `agent_end` | Return from `execute()` |
| `error` | Return `Err()` or stream error |

### 5. Signal Routing

| Flovyn Signal Type | External Agent Action |
|-------------------|----------------------|
| User message (after turn) | `agent.send_message()` |
| User message (during turn) | `agent.steer()` |
| Cancellation | `agent.abort()` |
| Model change | `agent.set_model()` (if supported) |

---

## Comparison Matrix

| Aspect | Pattern 1: Adapter | Pattern 2: Sidecar | Pattern 3: A2A | Pattern 4: MCP |
|--------|-------------------|-------------------|----------------|----------------|
| Complexity | Low | Medium | Medium | High |
| New infrastructure | None | Process manager | Protocol layer | MCP server |
| Recovery | Good | Excellent | Good | Good |
| Process isolation | Per-execution | Long-lived | Configurable | Per-tool-call |
| Agent survival | Tied to Flovyn | Independent | Configurable | Per-call |
| Multi-agent | Manual | Easy | Easy | Easy |
| Standards-based | No | No | No | Yes (MCP) |
| Implementation effort | Days | Weeks | Week | Weeks |

---

## Recommendations

### Phase 1: Agent Adapter (MVP)

Implement **Pattern 1** as the foundation:

1. Create `ExternalCodingAgentAdapter` implementing `AgentDefinition`
2. Start with Pi agent (well-documented RPC protocol)
3. Bridge events to Flovyn streaming
4. Checkpoint session file path at turn boundaries
5. Handle signals for steering and cancellation

**Deliverables:**
- `agent-worker/src/workflows/external_agent.rs` - Adapter implementation
- `agent-worker/src/external/mod.rs` - External agent process management
- `agent-worker/src/external/pi.rs` - Pi-specific RPC client

### Phase 2: Protocol Abstraction

Extract **Pattern 3** abstractions:

1. Define `ExternalAgentProtocol` trait
2. Implement for Pi and Claude Code
3. Generalize the adapter to use protocol trait
4. Add configuration for agent selection

### Phase 3: Session Registry (Optional)

If long-running sessions needed, implement **Pattern 2**:

1. Add `external_agent_session` table
2. Build process supervisor service
3. Enable attach/detach from running agents
4. Add health monitoring and auto-restart

---

## Open Questions

### Q1: Should external agent output be fully mirrored in Flovyn?

Mirroring pros:
- Full audit trail in Flovyn
- Can replay/analyze without external agent
- Consistent observability

Mirroring cons:
- Duplication of data
- More complex sync logic
- Storage cost

**Tentative answer**: Don't mirror for MVP. Flovyn tracks operations (which tools ran, when), external agent owns content. Consider mirroring for enterprise/compliance later.

### Q2: How to handle external agent-specific features?

Examples:
- Pi's `/tree`, `/fork`, `/resume` session commands
- Claude Code's MCP integrations
- Model-specific parameters

Options:
- Expose as Flovyn signal types
- Pass through as opaque metadata
- Agent-specific adapter extensions

**Tentative answer**: Core features (prompt, steer, abort) are universal. Agent-specific features are pass-through in signal metadata.

### Q3: How to handle context window management?

External agents manage their own context (compaction, summarization). Should Flovyn:
- A) Let external agent handle entirely
- B) Coordinate compaction with checkpoints
- C) Take over context management

**Tentative answer**: (A) for MVP. External agents like Pi have sophisticated auto-compaction. Flovyn just tracks turn count and session metadata.

### Q4: What about security/sandboxing?

External agents execute arbitrary code (bash, file writes). Considerations:
- Run in isolated containers?
- Limit filesystem access?
- Network isolation?

**Tentative answer**: Inherit external agent's security model for MVP. The agent runs with user's permissions as if invoked directly. Production deployments may want container isolation.

---

## References

### External Agent Documentation
- [Pi Coding Agent RPC Docs](../../competitors/pi-mono/packages/coding-agent/docs/rpc.md)
- [Pi Session Management](../../competitors/pi-mono/packages/coding-agent/src/core/session-manager.ts)
- [Claude Code Agent SDK](https://docs.anthropic.com/en/docs/agents/agent-sdk)

### Flovyn Documentation
- [Durable Agent System Plan](../plans/20260211_durable_agent_system.md)
- [AI Conversation Durability Research](20260128_ai_conversation_durability.md)
- [Agent Context Interface](../../sdk-rust/worker-sdk/src/agent/context.rs)

### Related Research
- [Model Context Protocol Spec](https://modelcontextprotocol.io/)
- [LangGraph Checkpointer Pattern](https://langchain-ai.github.io/langgraph/concepts/persistence/)
