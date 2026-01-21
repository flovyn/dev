# AI Agent Production Requirements Research

Date: 2025-12-31

## Executive Summary

This research analyzes 9 production AI agent frameworks to identify common patterns, architectural decisions, and requirements for running AI agents in production. The goal is to understand how Flovyn's durable execution system can better serve AI agent workloads.

## Frameworks Analyzed

| Framework | Type | Language | Source |
|-----------|------|----------|--------|
| [Temporal AI Agent](https://github.com/temporalio/temporal-ai-agent) | Durable Workflow Agent | Python | Temporal |
| [Hatchet](https://github.com/hatchet-dev/hatchet) | Workflow Engine | Go | Hatchet |
| [Restate](https://github.com/restatedev/restate) | Durable Execution | Rust | Restate |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | CLI Agent | TypeScript | Google |
| [OpenAI Codex](https://github.com/openai/codex) | Sandboxed Agent | Rust | OpenAI |
| [Open Interpreter](https://github.com/openinterpreter/open-interpreter) | Code Execution Agent | Python | Open Source |
| [Dyad](https://github.com/dyad-sh/dyad) | Desktop AI Builder | TypeScript | Open Source |
| [Libra](https://github.com/libra-ai/libra) | Web Dev Platform | TypeScript | Open Source |
| [OpenManus](https://github.com/mannaandpoem/OpenManus) | Agent Framework | Python | Open Source |

---

## 1. Common Architecture Patterns

### 1.1 Agent Loop Structure

All frameworks implement variations of the **ReAct (Reasoning + Acting) loop**:

```
┌─────────────────────────────────────────────────┐
│                 AGENT LOOP                       │
├─────────────────────────────────────────────────┤
│  1. THINK: LLM generates next action/tool call  │
│  2. VALIDATE: Check tool exists, parse args     │
│  3. APPROVE: User confirmation (if required)    │
│  4. ACT: Execute tool/command                   │
│  5. OBSERVE: Capture output, truncate if needed │
│  6. LOOP: Feed result back, repeat or terminate │
└─────────────────────────────────────────────────┘
```

**Key Findings:**

| Framework | Max Steps | Loop Detection | Termination |
|-----------|-----------|----------------|-------------|
| Temporal AI Agent | 250 turns | History summarization | Signal-based |
| Gemini CLI | 100 turns | Pattern matching | LoopDetectionService |
| Codex | Configurable | Turn limit | Explicit terminate tool |
| Open Interpreter | Unlimited | Loop breaker phrases | Text matching |
| Dyad | 25 rounds | AI SDK stepCountIs | Tool or phrase |
| OpenManus | 20 steps | Duplicate detection | Terminate tool |

### 1.2 Tool System Architecture

**Universal Pattern: Declarative Tool Definitions**

```python
# Common structure across all frameworks
Tool:
  name: str                    # Unique identifier
  description: str             # For LLM understanding
  parameters: Schema           # JSON Schema / Zod / Pydantic
  execute(args) -> Result      # Execution logic
```

**Tool Categories:**

| Category | Examples | Approval Required |
|----------|----------|-------------------|
| **Readers** | read_file, grep, ls, list_dir | No |
| **Writers** | write_file, edit, patch | Yes (usually) |
| **Executors** | shell, bash, python | Yes (usually) |
| **Search** | web_search, web_fetch | No |
| **MCP** | External MCP server tools | Configurable |

**Source References:**
- Gemini CLI: `flovyn-server/packages/core/src/tools/tool-registry.ts`
- Codex: `codex-rs/core/src/tools/handlers/`
- OpenManus: `flovyn-server/app/tool/base.py`
- Dyad: `src/pro/main/ipc/handlers/local_agent/tools/`

### 1.3 State Management Patterns

**Three-Tier State Architecture (common across all):**

```
┌─────────────────────────────────────────────────┐
│ SESSION STATE (Long-lived)                       │
│ - Authentication, configuration                  │
│ - Approval cache, tool registry                  │
│ - MCP connections                                │
├─────────────────────────────────────────────────┤
│ CONVERSATION STATE (Per-conversation)            │
│ - Message history, tool calls/results            │
│ - Current context, last response ID              │
│ - Compressed summaries                           │
├─────────────────────────────────────────────────┤
│ TURN STATE (Per-turn)                            │
│ - Current step, pending approvals               │
│ - Active tool calls, streaming output            │
│ - Abort signals                                  │
└─────────────────────────────────────────────────┘
```

**State Persistence Mechanisms:**

| Framework | Primary Storage | History Compression |
|-----------|-----------------|---------------------|
| Temporal AI Agent | Workflow history | LLM summarization at 250 turns |
| Gemini CLI | In-memory | Compress oldest 70% at 70% context |
| Codex | In-memory + DB | Context manager with truncation |
| Dyad | SQLite (Drizzle) | aiMessagesJson per message |
| OpenManus | Memory class | max_messages trimming (100) |

### 1.4 Context Window Management (Deep Dive)

Context management is **critical** for production AI agents. LLM context windows are finite (8K-200K tokens), and agent conversations grow unbounded. Each framework handles this differently:

#### 1.4.1 Gemini CLI - LLM-Based Semantic Compression

**The most sophisticated approach.** Automatically compresses when reaching 70% of context window.

**Trigger Condition:**
```typescript
const COMPRESSION_TOKEN_THRESHOLD = 0.7;  // 70% of context
const COMPRESSION_PRESERVE_THRESHOLD = 0.3;  // Keep latest 30%

if (tokenCount >= COMPRESSION_TOKEN_THRESHOLD * tokenLimit(model)) {
  await tryCompressChat();
}
```

**Split Point Algorithm** (`findCompressSplitPoint`):
```typescript
// Find where to split - ONLY at user message boundaries
function findCompressSplitPoint(contents: Content[], fraction: number): number {
  const totalCharCount = contents.reduce((sum, c) => sum + JSON.stringify(c).length, 0);
  const targetCharCount = totalCharCount * fraction;  // 70%

  let cumulativeCharCount = 0;
  for (let i = 0; i < contents.length; i++) {
    // Only split at user messages (not mid-turn)
    if (content.role === 'user' && !hasFunctionResponse(content)) {
      if (cumulativeCharCount >= targetCharCount) {
        return i;  // Split here
      }
    }
    cumulativeCharCount += charCounts[i];
  }
}
```

**Compression Process:**
```typescript
// 1. Split history
const historyToCompress = curatedHistory.slice(0, splitPoint);  // Oldest 70%
const historyToKeep = curatedHistory.slice(splitPoint);          // Latest 30%

// 2. Generate structured XML summary via separate LLM call
const summaryResponse = await generateContent({
  contents: [
    ...historyToCompress,
    { role: 'user', parts: [{ text: 'Generate the <state_snapshot>.' }] }
  ],
  config: { systemInstruction: getCompressionPrompt() }
});

// 3. Create new chat: [summary] + [ack] + [kept history]
this.chat = await startChat([
  { role: 'user', parts: [{ text: summary }] },
  { role: 'model', parts: [{ text: 'Got it. Thanks for the context!' }] },
  ...historyToKeep
]);
```

**Compression Prompt Output Format:**
```xml
<state_snapshot>
  <overall_goal>
    Refactor the authentication service to use JWT library v2.0
  </overall_goal>

  <key_facts>
    <fact>User prefers functional React components</fact>
    <fact>File src/auth/jwt.ts was created with token validation</fact>
    <fact>Tests in __tests__/auth.test.ts are failing</fact>
  </key_facts>

  <current_plan>
    1. [DONE] Install @auth/jwt-v2 library
    2. [DONE] Create token generation in src/auth/jwt.ts
    3. [IN PROGRESS] Refactor UserProfile.tsx to use new API
    4. [TODO] Fix failing tests
    5. [TODO] Update documentation
  </current_plan>
</state_snapshot>
```

**Source:** `gemini-cli/packages/core/src/core/client.ts:73-113, 731-851`

#### 1.4.2 Temporal AI Agent - Workflow Continue-as-New

**Uses Temporal's `continue_as_new` to reset workflow history while preserving agent memory.**

**Trigger:** Fixed message count (default 250)
```python
MAX_TURNS = 250

async def continue_as_new_if_needed(conversation_history, prompt_queue, agent_goal):
    if len(conversation_history["messages"]) >= MAX_TURNS:
        # Generate 2-sentence summary
        summary_prompt = (
            "Please produce a two sentence summary of this conversation. "
            'Put the summary in the format { "summary": "<plain text>" }'
        )

        summary = await workflow.execute_activity(
            "agent_toolPlanner",
            ToolPromptInput(prompt=summary_prompt, context=history_string)
        )

        # Restart workflow with clean history but preserved summary
        workflow.continue_as_new(args=[{
            "tool_params": {
                "conversation_summary": summary,
                "prompt_queue": prompt_queue
            },
            "agent_goal": agent_goal
        }])
```

**Key Insight:** The **Temporal workflow event history resets** (solving the unbounded history problem), but the **agent's semantic memory continues** via the summary.

**Source:** `temporal-ai-agent/workflows/workflow_helpers.py:145-191`

#### 1.4.3 Dyad - Raw SDK Message Preservation

**Stores complete AI SDK messages for multi-turn tool call fidelity.**

**Strategy:** Persist `aiMessagesJson` alongside human-readable content
```typescript
// After each LLM response, save raw SDK messages
const response = await streamResult.response;
const aiMessagesJson = getAiMessagesJsonIfWithinLimit(response.messages);

await db.update(messages)
  .set({ aiMessagesJson })  // Full tool call chain preserved
  .where(eq(messages.id, messageId));
```

**Message Reconstruction on Resume:**
```typescript
// Reconstruct full history including tool calls
const messageHistory: ModelMessage[] = chat.messages
  .filter(msg => msg.content || msg.aiMessagesJson)
  .flatMap(msg => parseAiMessagesJson(msg));

// Send to LLM with full tool call context
await streamText({ messages: messageHistory, tools: allTools });
```

**Stored Format:**
```json
{
  "messages": [
    { "role": "user", "content": "Create a login form" },
    { "role": "assistant", "content": "", "toolUses": [
      { "toolUseId": "abc123", "toolName": "write_file", "args": {...} }
    ]},
    { "role": "user", "toolResults": [
      { "toolUseId": "abc123", "result": "File created" }
    ]}
  ],
  "sdkVersion": "ai@v5"
}
```

**Cleanup:** Old entries purged after 7 days to manage storage
```typescript
// Cleanup job
await db.update(messages)
  .set({ aiMessagesJson: null })
  .where(lt(messages.createdAt, cutoffDate));
```

**Source:** `dyad/src/pro/main/ipc/handlers/local_agent/local_agent_handler.ts:188-370`

#### 1.4.4 OpenManus - Simple FIFO Trimming

**Fixed-size sliding window with no semantic preservation.**

```python
class Memory(BaseModel):
    messages: list[Message] = Field(default_factory=list)
    max_messages: int = 100

    def add_message(self, message: Message) -> None:
        self.messages.append(message)
        # Drop oldest messages when limit exceeded
        while len(self.messages) > self.max_messages:
            self.messages.pop(0)
```

**Trade-off:** Simple but loses context. Suitable for short tasks, not long-running agents.

#### 1.4.5 Open Interpreter - No Compression, Output Truncation Only

**Full history preserved, only tool outputs are truncated.**

```python
# No history compression - full persistence
with open(conversation_history_path, 'w') as f:
    json.dump(self.messages, f)

# Only tool OUTPUT is truncated (not history)
max_output = 2800  # tokens per tool result
```

**Relies on:** User managing context manually or starting new sessions.

#### 1.4.6 Context Management Comparison

| Framework | Trigger | Strategy | Tool Call Fidelity | Semantic Preservation |
|-----------|---------|----------|-------------------|----------------------|
| **Gemini CLI** | 70% context | LLM → XML summary | Lost (summarized) | High (structured) |
| **Temporal** | 250 messages | LLM → 2 sentences | Lost | Medium |
| **Dyad** | None | Store raw SDK msgs | Full | N/A (no compression) |
| **OpenManus** | 100 messages | FIFO drop | Lost | None |
| **Open Interpreter** | None | Full history | Full | N/A |
| **Codex** | Configurable | Truncation | Partial | Low |

#### 1.4.7 Key Design Decisions

**When to compress:**
- **Token-based** (Gemini): Most accurate, requires token counting
- **Message-count** (Temporal, OpenManus): Simple, predictable
- **Never** (Dyad, Open Interpreter): Full fidelity, risks context overflow

**What to preserve:**
- **Semantic summary** (Gemini, Temporal): Captures intent, loses details
- **Raw messages** (Dyad): Full tool call chains, expensive storage
- **Nothing** (OpenManus FIFO): Loses context, simple implementation

**How to compress:**
- **LLM-generated summary**: Best quality, adds latency and cost
- **Algorithmic truncation**: Fast, loses semantic meaning
- **Checkpoint/restart**: Clean slate with minimal carryover

---

## 2. Durable Execution Requirements

### 2.1 Why AI Agents Need Durable Execution

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

### 2.2 Key Durability Features Needed

| Feature | Description | Frameworks Using |
|---------|-------------|------------------|
| **Activity Retries** | Automatic retry with backoff for LLM calls | Temporal, Hatchet, Restate |
| **Checkpointing** | Save state after each tool execution | All |
| **Continue-as-New** | Prevent unbounded history growth | Temporal, Restate |
| **Timeout Handling** | Configurable per-activity timeouts | All |
| **Cancellation** | Graceful abort with cleanup | All |
| **Idempotency** | Deduplicate duplicate requests | Temporal, Hatchet, Restate |

### 2.3 Event Sourcing for AI Agents

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

---

## 3. Human-in-the-Loop Patterns

### 3.1 Approval Flow Architecture

**Common Pattern across frameworks:**

```
┌──────────────────────────────────────────────────┐
│              APPROVAL FLOW                        │
├──────────────────────────────────────────────────┤
│ 1. Agent generates tool call                     │
│ 2. Check approval policy:                        │
│    - Auto-approve (readers, trusted patterns)    │
│    - Request approval (writers, executors)       │
│    - Forbidden (dangerous operations)            │
│ 3. If approval needed:                           │
│    - Yield/emit approval request event           │
│    - Suspend execution (durable wait)            │
│    - Resume on user response                     │
│ 4. Cache decision for session (optional)         │
│ 5. Execute tool                                  │
└──────────────────────────────────────────────────┘
```

**Approval Modes Comparison:**

| Framework | Modes | Caching | Modification |
|-----------|-------|---------|--------------|
| Gemini CLI | YOLO, EXPLICIT, TRUSTED_FILES | Per-session | Editor-based |
| Codex | Skip, OnFailure, OnRequest, UnlessTrusted | Per-session | Policy amendments |
| Dyad | ask, always, never (per-tool) | Persistent | Accept-always option |
| Open Interpreter | auto_run, safe_mode | None | Code editing |
| Temporal AI Agent | confirm signal | None | None |

### 3.2 Durable Approval Waits

**Temporal Pattern** (production-ready):
```python
# Agent suspends durably waiting for user
@workflow.signal
async def confirm(self):
    self.confirmed = True

# In workflow loop
if next_step == "confirm":
    self.confirmed = False
    await workflow.wait_condition(lambda: self.confirmed)
    # Resume after user confirms
```

**Flovyn Equivalent:**
```rust
// Using promises for durable human-in-the-loop
let approval = ctx.create_promise("approval_request")?;
ctx.emit_event(Event::ApprovalRequired { ... })?;
let decision = ctx.await_promise(approval).await?;
```

---

## 4. Streaming and Real-Time Patterns

### 4.1 Streaming Architecture

**All modern AI agents use streaming for UX:**

```
┌─────────────────────────────────────────────────┐
│           STREAMING PIPELINE                     │
├─────────────────────────────────────────────────┤
│ LLM API (SSE) → Chunk Parser → Event Emitter    │
│                      ↓                           │
│              Typed Events:                       │
│              - content (text delta)              │
│              - thinking (reasoning)              │
│              - tool_call_start                   │
│              - tool_call_delta (args streaming)  │
│              - tool_call_end                     │
│              - tool_result                       │
│              - error                             │
│              - finished                          │
└─────────────────────────────────────────────────┘
```

**Gemini CLI Implementation:**
```typescript
// Layered streaming architecture
for await (const event of client.sendMessageStream(...)) {
  switch (event.type) {
    case 'content': ui.displayText(event.value); break;
    case 'thought': ui.displayThinking(event.value); break;
    case 'tool_call_request': await scheduler.schedule(...); break;
    case 'finished': ui.showComplete(); break;
  }
}
```

**Source:** `flovyn-server/gemini-cli/packages/core/src/core/client.ts`

### 4.2 Tool Argument Streaming

**Dyad's XML Streaming Pattern:**
```typescript
// Stream tool arguments as they're generated
case "tool-input-delta": {
  entry.argsAccumulated += part.delta;
  partial = parsePartialJson(entry.argsAccumulated);
  xml = toolDef.buildXml(partial, false);  // Live preview
  ctx.onXmlStream(xml);
}

case "tool-input-end": {
  xml = toolDef.buildXml(args, true);  // Final version
  ctx.onXmlComplete(xml);  // Persist to DB
}
```

**Source:** `flovyn-server/dyad/src/pro/main/ipc/handlers/local_agent/local_agent_handler.ts`

---

## 5. Safety and Sandboxing

### 5.1 Multi-Layer Defense Strategy

**Codex (most comprehensive):**

```
┌─────────────────────────────────────────────────┐
│           SAFETY LAYERS                          │
├─────────────────────────────────────────────────┤
│ Layer 1: Command Safety Analysis                 │
│   - Whitelist known-safe commands (ls, cat)     │
│   - Detect dangerous patterns (rm -rf, dd)      │
│                                                  │
│ Layer 2: Approval System                         │
│   - Policy-based: Skip/Ask/Forbid               │
│   - Cached decisions per session                │
│                                                  │
│ Layer 3: Platform Sandboxing                     │
│   - macOS: Seatbelt (sandbox-exec)              │
│   - Linux: Landlock + Seccomp                   │
│   - Windows: Restricted Token                    │
│                                                  │
│ Layer 4: Retry Without Sandbox                   │
│   - On sandbox denial, retry with user approval │
└─────────────────────────────────────────────────┘
```

**Source:** `flovyn-server/codex/codex-rs/core/src/tools/orchestrator.rs`

### 5.2 Sandbox Implementations

| Platform | Technology | Scope |
|----------|------------|-------|
| macOS | Seatbelt (sandbox-exec) | File paths, network |
| Linux | Landlock + Seccomp | File system, syscalls |
| Windows | Restricted Token | Capability drops |
| Docker | Container isolation | Full isolation |
| E2B/Daytona | Cloud sandbox | Full isolation + VNC |

### 5.3 Output Truncation (Critical for Token Management)

**All frameworks implement output limits:**

| Framework | Max Output | Strategy |
|-----------|------------|----------|
| Gemini CLI | 10K tokens | First 20% + Last 80% of lines |
| Open Interpreter | 2800 tokens | Head truncation |
| Dyad | 10K chars | Truncation |
| OpenManus | 10K-15K chars | Per-agent limits |

**Gemini CLI Pattern:**
```typescript
// Save full output, return summary
saveToTempFile(fullOutput);
return `${first20Percent}\n...\n${last80Percent}\n[Full output: ${path}]`;
```

---

## 6. Observability Requirements

### 6.1 Essential Metrics

| Metric | Purpose | Frameworks Tracking |
|--------|---------|---------------------|
| Token usage | Cost, context management | All |
| Tool execution time | Performance | Gemini CLI, Codex |
| Turn count | Loop detection | All |
| Error rates | Reliability | All |
| Approval latency | UX | Codex, Dyad |

### 6.2 Telemetry Events

**Gemini CLI's comprehensive telemetry:**
```typescript
logToolCall(config, new ToolCallEvent(completedCall));
logAgentStart(config, new AgentStartEvent(agentId, name));
logAgentFinish(config, new AgentFinishEvent(agentId, duration, turnCount));
logChatCompression(config, new ChatCompressionEvent(tokensBefore, tokensAfter));
logContentRetry(config, new ContentRetryEvent(attempt, errorType));
```

**Source:** `gemini-cli/packages/core/src/telemetry/`

### 6.3 Conversation Replay

**Critical for debugging AI agents:**
- Full message history with tool calls/results
- Timing information per step
- Decision points (approvals, branches)
- Error context with stack traces

---

## 7. Error Handling Patterns

### 7.1 Retry Strategies

| Error Type | Strategy | Example |
|------------|----------|---------|
| Rate limit (429) | Exponential backoff | 1s → 2s → 4s → ... → 60s |
| Server error (5xx) | Retry with limit | Max 3-6 attempts |
| Auth error (401) | Fail fast, re-auth | No retry |
| Token limit | Compress context | Summarize history |
| Invalid response | Inject continuation | "Please continue" |

### 7.2 Graceful Degradation

**Gemini CLI's fallback pattern:**
```typescript
// On quota exceeded, switch to cheaper model
if (error.status === 429 && model === 'pro') {
  isInFallbackMode = true;
  return retry(withModel: 'flash');
}
```

### 7.3 Tool Error Categories

**Codex's error classification:**
```rust
enum ToolErrorType {
    // Recoverable (LLM can self-correct)
    FileNotFound, EditNoOccurrence, InvalidParams,

    // Fatal (stop execution)
    NoSpaceLeft, PermissionDenied (sometimes),
}
```

---

## 8. MCP (Model Context Protocol) Integration

### 8.1 Why MCP Matters

MCP enables **dynamic tool ecosystems**:
- Tools can be added/removed at runtime
- External services exposed as tools
- Standardized protocol across frameworks

### 8.2 MCP Integration Patterns

| Framework | MCP Support | Connection Types |
|-----------|-------------|------------------|
| Dyad | Full | stdio, HTTP |
| OpenManus | Full | SSE, stdio |
| Gemini CLI | Limited | Via custom tools |
| Codex | Full | stdio, HTTP |

**Dynamic Tool Refresh (OpenManus):**
```python
async def _refresh_tools(self):
    """Check for tool additions/removals/changes"""
    current = await self.mcp_client.list_tools()
    added = current - self.known_tools
    removed = self.known_tools - current
    # Update tool registry dynamically
```

**Source:** `flovyn-server/OpenManus/app/agent/mcp.py`

---

## 9. Flovyn Opportunities

### 9.1 Current Flovyn Strengths

1. **Event-sourced workflows** - Natural fit for agent state
2. **Durable timers** - Support long-running agents
3. **Task execution model** - Maps to tool execution
4. **Multi-tenancy** - Enterprise-ready
5. **gRPC streaming** - Real-time communication

### 9.2 Gaps to Address

| Gap | Current State | Recommendation |
|-----|---------------|----------------|
| **Human-in-the-loop** | Basic promise support | Add approval primitives |
| **Streaming output** | Limited | Add streaming task output |
| **Context compression** | None | Add LLM-aware history management |
| **Tool registry** | Manual | Add dynamic tool registration |
| **Sandboxing** | None | Add execution policies |

### 9.3 Recommended Additions

#### 9.3.1 Agent-Native Primitives

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

#### 9.3.2 Agent Workflow Template

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

#### 9.3.3 Observability Enhancements

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

#### 9.3.4 Context Management System (Detailed Design)

Based on research findings, Flovyn should implement a **hybrid context management system**:

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

---

## 10. Key Takeaways

### 10.1 Universal Requirements

1. **Durable execution** - LLM calls must survive failures
2. **Human-in-the-loop** - Approval flows are essential
3. **Streaming** - Real-time feedback is expected
4. **Safety** - Multi-layer defense is standard
5. **Observability** - Full conversation replay required
6. **Context management** - Automatic compression is critical for long-running agents

### 10.2 Context Management Best Practices

| Practice | Recommendation | Source |
|----------|----------------|--------|
| **Compression trigger** | 70% of context window | Gemini CLI |
| **Split strategy** | Only at user message boundaries | Gemini CLI |
| **Preserve ratio** | Keep latest 30% unchanged | Gemini CLI |
| **Summary format** | Structured XML with goal/facts/plan | Gemini CLI |
| **Tool call fidelity** | Store raw SDK messages | Dyad |
| **Workflow integration** | Use continue-as-new | Temporal |

### 10.3 Differentiation Opportunities

| Opportunity | Why Flovyn | Competitors |
|-------------|------------|-------------|
| **Event-sourced agents** | Native support | Temporal only |
| **Multi-org agents** | Built-in | Manual setup |
| **Hybrid local/cloud** | Worker model | Limited |
| **Enterprise security** | JWT/RBAC ready | Basic |
| **Context checkpointing** | Event log + checkpoints | None native |

### 10.4 Next Steps

1. **Phase 1**: Add approval primitives (Promise-based HITL)
2. **Phase 2**: Add streaming task output
3. **Phase 3**: Add agent workflow template with context management
4. **Phase 4**: Add MCP server integration
5. **Phase 5**: Add sandboxing policies
6. **Phase 6**: Add context compression strategies (LLM + algorithmic)

---

## Appendix: Source Code References

### Agent Architectures
- Temporal AI Agent: `flovyn-server/temporal-ai-agent/workflows/agent_goal_workflow.py`
- Gemini CLI: `flovyn-server/gemini-cli/AGENT_ARCHITECTURE.md` (46KB)
- Codex: `flovyn-server/codex/codex-rs/core/src/codex.rs`
- OpenManus: `flovyn-server/OpenManus/app/agent/base.py`

### Tool Systems
- Gemini CLI: `gemini-cli/packages/core/src/tools/`
- Codex: `codex/codex-rs/core/src/tools/`
- Dyad: `dyad/src/pro/main/ipc/handlers/local_agent/tools/`
- OpenManus: `OpenManus/app/tool/`

### Context Management
- Gemini CLI compression: `gemini-cli/packages/core/src/core/client.ts:73-113, 731-851`
- Gemini CLI prompts: `gemini-cli/packages/core/src/core/prompts.ts:419-481`
- Temporal continue-as-new: `temporal-ai-agent/workflows/workflow_helpers.py:145-191`
- Dyad SDK messages: `dyad/src/pro/main/ipc/handlers/local_agent/local_agent_handler.ts:188-370`
- OpenManus Memory: `flovyn-server/OpenManus/app/schema.py` (Memory class)

### Durable Execution
- Temporal: `temporal/` (full SDK)
- Restate: `restate/crates/types/src/journal_v2/`
- Hatchet: `flovyn-server/hatchet/sql/schema/v1-core.sql`

### Sandboxing
- Codex macOS: `flovyn-server/codex/codex-rs/core/src/seatbelt.rs`
- Codex Linux: `flovyn-server/codex/codex-rs/core/src/landlock.rs`
- OpenManus: `OpenManus/app/sandbox/`
