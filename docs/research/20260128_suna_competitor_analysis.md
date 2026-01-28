# Suna (Kortix) Competitor Analysis: AI Agent Platform

Date: 2026-01-28

## Executive Summary

This research analyzes **Suna** (repository: `kortix-ai/suna`, product: Kortix), a complete AI agent platform, to understand how it builds and manages autonomous agents. The goal is to identify patterns, capabilities, and gaps that inform Flovyn's AI agent strategy.

**Key Finding**: Suna implements **autonomous agents** (LLM controls flow via ReAct loop), not **workflow AI** (code controls flow). Flovyn can implement similar patterns using its durable execution primitives, but lacks agent-specific features like LLM integration, tool registry, and sandbox execution.

---

## 1. Suna Overview

### 1.1 What is Suna?

| Attribute | Value |
|-----------|-------|
| **Repository** | `github.com/kortix-ai/suna` |
| **Product Name** | Kortix |
| **Type** | Autonomous AI Agent Platform |
| **Architecture** | Stateless coordinator + sandboxed execution |
| **Primary Language** | Python (backend), TypeScript (frontend) |

### 1.2 Core Value Proposition

Suna provides a **turnkey platform** for building, deploying, and managing autonomous AI agents:
- 30+ built-in tools (browser, files, search, shell)
- Multi-LLM support via LiteLLM (Anthropic, OpenAI, Groq)
- Sandboxed execution via Docker/Daytona
- Real-time streaming via Redis
- Agent versioning and configuration management
- MCP (Model Context Protocol) integration

---

## 2. Architecture

### 2.1 Component Overview

```
┌─────────────────────────────────────────────────────────┐
│                    SUNA ARCHITECTURE                     │
├─────────────────────────────────────────────────────────┤
│  Frontend (Next.js 16)                                  │
│  - Agent configuration UI                               │
│  - Chat interface                                       │
│  - Real-time streaming display                          │
├─────────────────────────────────────────────────────────┤
│  Backend (FastAPI)                                      │
│  - REST API endpoints                                   │
│  - Agent orchestration (StatelessCoordinator)           │
│  - Tool registry and execution                          │
│  - LLM integration (LiteLLM)                            │
├─────────────────────────────────────────────────────────┤
│  Runtime (Docker/Daytona)                               │
│  - Sandboxed agent execution                            │
│  - Browser automation (Playwright)                      │
│  - File system isolation                                │
├─────────────────────────────────────────────────────────┤
│  Storage                                                │
│  - PostgreSQL (Supabase): Agent configs, threads        │
│  - Redis: Real-time streaming, session cache            │
└─────────────────────────────────────────────────────────┘
```

### 2.2 Key Files

| Component | Location | Purpose |
|-----------|----------|---------|
| **Agent Execution** | `backend/core/agents/runner/executor.py` | Main execution entry point |
| **Coordinator** | `backend/core/agents/runner/stateless_coordinator.py` | ReAct loop orchestration |
| **State Management** | `backend/core/agents/runner/state.py` | RunState with message history |
| **Tool Registry** | `backend/core/tools/tool_registry.py` | 30+ built-in tools |
| **Auto-Continue** | `backend/core/agents/runner/auto_continue.py` | Determines when to loop |
| **Agent Loader** | `backend/core/agents/agent_loader.py` | Agent configuration loading |

---

## 3. Multi-Turn Agent Execution

### 3.1 Agent Type Classification

Per [Anthropic's "Building Effective Agents"](https://www.anthropic.com/engineering/building-effective-agents):

| Type | Description | LLM Role | Suna? |
|------|-------------|----------|-------|
| **Workflow** | Orchestrated chains of LLM calls | Code controls flow | No |
| **Autonomous Agent** | LLM decides actions in a loop | LLM controls flow | **Yes** |

**Suna implements autonomous agents** using the ReAct (Reasoning + Acting) pattern.

### 3.2 ReAct Loop Implementation

```
User Message
     ↓
┌────────────────────────────────────────────┐
│  StatelessCoordinator.execute() Loop       │
│                                            │
│  ┌─────────────────────────────────────┐  │
│  │ Turn N:                              │  │
│  │  1. LLM sees: [history + last turn]  │  │
│  │  2. LLM responds (content + tools)   │  │
│  │  3. Check finish_reason:             │  │
│  │     - "tool_calls" → execute tools,  │  │
│  │                       AUTO-CONTINUE  │  │
│  │     - "stop" → BREAK LOOP            │  │
│  └─────────────────────────────────────┘  │
│                   ↓                        │
│  Repeat until: stop OR max_steps (25)      │
└────────────────────────────────────────────┘
     ↓
Final Response to User
```

**Source**: `stateless_coordinator.py` lines 111-170

```python
while self._state.should_continue() and should_continue_loop:
    step = self._state.next_step()

    async for chunk in execution_engine.execute_step():
        yield chunk
        cont, term = AutoContinueChecker.check(chunk, ...)
        if term:
            force_terminate = True
        if cont:
            should_auto_continue = True

    if force_terminate or not should_auto_continue:
        self._state.complete()
        break
```

### 3.3 Two Levels of "Multi-Turn"

| Level | Definition | Mechanism |
|-------|------------|-----------|
| **Within a Run** | Multiple LLM calls in one agent_run | ReAct loop (up to 25 steps) |
| **Across Runs** | User sends follow-up messages | Thread persists full history |

**Within a Run Example**:
```
agent_run_1:
├─ Turn 1: LLM → "I'll search for info" + web_search()
├─ Turn 2: Tool result → LLM → "Found it, analyzing" + read_file()
├─ Turn 3: Tool result → LLM → "Here's my analysis..."
└─ (finish_reason="stop", 3 LLM calls total)
```

**Across Runs Example**:
```
Thread T1:
├─ agent_run_1: "What's the weather?" → [3 turns] → response
├─ agent_run_2: "What about tomorrow?" → loads all history → [2 turns]
└─ agent_run_3: "Thanks!" → loads all history → [1 turn]
```

### 3.4 Auto-Continue Logic

**Source**: `auto_continue.py`

```python
def check(chunk, count, max_steps):
    should_continue = False
    should_terminate = False

    if chunk.finish_reason == "tool_calls":
        should_continue = True  # Tools executed, continue loop
    elif chunk.finish_reason in ("stop", "end_turn"):
        should_terminate = True  # Agent decided to stop
    elif chunk.finish_reason == "length":
        should_continue = True  # Max tokens, continue for more

    if count >= max_steps:
        should_terminate = True  # Safety limit

    return should_continue, should_terminate
```

### 3.5 State Management

**In-Memory State** (per agent_run):
```python
class RunState:
    _messages: Deque[Dict]     # Conversation history (max 500)
    _step_counter: int         # Current turn number
    _accumulated_content: str  # LLM response accumulator
    _cancelled: bool
    _terminated: bool
```

**Persistent State** (across runs):
- **PostgreSQL**: Thread records, message history, agent configs
- **Redis**: Real-time cache, streaming buffers

### 3.6 Context Window Management

When conversation grows too long:

**Source**: `execution_engine.py` lines 39-124

```python
async def _check_and_compress_if_needed(self):
    if token_count > safety_threshold:
        # Keep last 2-8 messages as working memory
        # Summarize older messages using gpt-4o-mini
        summary = await compress_history(old_messages)
        self._state.replace_old_messages_with_summary(summary)
```

---

## 4. Tool System

### 4.1 Tool Categories

| Category | Examples | Count | Approval |
|----------|----------|-------|----------|
| **File Operations** | read_file, write_file, list_dir | 8 | Writers: Yes |
| **Shell** | execute_command, run_script | 2 | Yes |
| **Browser** | navigate, click, type, screenshot | 12 | No |
| **Search** | web_search, image_search, paper_search | 5 | No |
| **Knowledge** | store_knowledge, query_knowledge | 3 | No |
| **Agent Builder** | create_agent, config_agent | 5 | No |
| **Utilities** | canvas, spreadsheet, presentation | 6 | No |

**Total**: 30+ built-in tools

### 4.2 Tool Definition Pattern

```python
# From tool_registry.py
TOOL_METADATA = {
    "web_search": {
        "display_name": "Web Search",
        "description": "Search the web for information",
        "icon": "search",
        "usage_guide": "Use to find current information...",
        "requires_approval": False,
        "tier_restriction": None
    },
    ...
}
```

### 4.3 Parallel Tool Execution

**Source**: `response_processor.py` lines 135-171

```python
if execute_on_stream:
    # Tools execute in parallel while LLM streams
    for idx in sorted(tool_call_buffer.keys()):
        if is_tool_call_complete(tool_call_buffer[idx]):
            execution = self._tool_executor.start_tool_execution(...)
            pending_executions.append(execution)

    # Await all tool results
    results = await asyncio.gather(*pending_executions)
```

---

## 5. Streaming Architecture

### 5.1 Real-Time Output

**Pattern**: Redis Streams for token-by-token output

```python
# Executor publishes to Redis stream
await redis.publish_to_stream(
    f"agent_run:{agent_run_id}:stream",
    chunk
)

# Client polls stream for updates
async for chunk in redis.subscribe(stream_key):
    yield chunk
```

**Stream TTL**: 3600 seconds (1 hour)

### 5.2 Streaming Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| **Token streaming** | Each token as it's generated | Chat UI |
| **Tool result streaming** | Tool output chunks | Long operations |
| **Progress streaming** | Progress updates | File operations |

---

## 6. Sandbox Execution

Suna provides **isolated execution environments** for agent tools via Docker containers managed by Daytona.

### 6.1 Architecture Overview

```
Agent Tool Call (shell, file, browser)
         ↓
    SandboxToolsBase._ensure_sandbox()
         ↓
    ┌─────────────────────────────────┐
    │       SandboxResolver           │
    │                                 │
    │  Resolution Chain:              │
    │  1. Memory cache    (fastest)   │
    │  2. Database lookup             │
    │  3. Pool claim      (fast)      │
    │  4. Create new      (2-5s)      │
    └─────────────────────────────────┘
         ↓
    Daytona API (Container Management)
         ↓
    ┌─────────────────────────────────┐
    │     Docker Container            │
    │                                 │
    │  /workspace (agent files)       │
    │  Supervisord (process mgmt)     │
    │  Chrome + Playwright            │
    │  Python 3.11 + Node.js 20       │
    │  VNC server (debugging)         │
    └─────────────────────────────────┘
```

### 6.2 What's Inside a Sandbox

Each sandbox is a **full Linux environment** running these services:

| Service | Port | Purpose |
|---------|------|---------|
| **Xvfb** | - | Virtual display for headless browser |
| **X11VNC** | 5901 | VNC protocol server |
| **noVNC** | 6080 | Web-based VNC viewer (debugging) |
| **HTTP Server** | 8080 | File serving from /workspace |
| **Browser API** | 8004 | Stagehand automation server |
| **File Watcher** | - | Monitors /workspace changes |

**Installed Tools**:
- Chrome browser with Playwright
- Node.js 20 & npm/pnpm
- Python 3.11 with ML/data libraries
- Document processing (PDF, DOCX, PPTX converters)
- OCR (Tesseract)
- Text tools (grep, sed, awk, jq)
- Process management (tmux, screen, supervisord)

**Key Directory**: `/workspace` - All agent file operations happen here

### 6.3 Sandbox Pooling

Creating containers is expensive (2-5s), so Suna **pre-warms a pool**:

| Environment | Min Pool | Max Pool | Replenish Interval |
|-------------|----------|----------|-------------------|
| Local | 5 | 20 | 30s |
| Staging | 50 | 100 | 20s |
| Production | 100 | 300 | 15s |

**Background Tasks** (`pool_background.py`):

| Task | Interval | Purpose |
|------|----------|---------|
| **Warmup** | Startup | Fill pool to min_size |
| **Replenishment** | 15-30s | Create sandboxes when pool < 70% |
| **Keepalive** | 10 min | Ping containers to prevent timeout |
| **Cleanup** | 5-15 min | Delete sandboxes older than 1 hour |

**Performance**:
- Pool claim: ~100ms
- New creation: 2-5s
- Pool hit rate: ~70-80% in production

### 6.4 Sandbox Lifecycle & Content Persistence

```
pooled (warm, waiting in pool)
    ↓ claim_pooled_sandbox()
active (assigned to project)          ← /workspace content: ✅ accessible
    ↓ [agent uses sandbox]
    ↓ 15 min idle (auto_stop_interval)
stopped                               ← /workspace content: ✅ preserved
    ↓ 30 min idle (auto_archive_interval)
archived                              ← /workspace content: ✅ preserved (snapshot)
    ↓ cleanup task (max_age = 1 hour)
deleted                               ← /workspace content: ❌ GONE
```

**Key insight**: Sandbox is **stateful per project** - the same container is reused across multiple agent runs within a project. This means:
- Files persist between runs
- Browser state persists
- No startup cost after first run

### 6.5 Content Persistence Model

**Where agent-generated code is stored**: All files go to `/workspace` in the sandbox container.

**Resume behavior** (from `sandbox.py`):
```python
async def get_or_start_sandbox(sandbox_id: str) -> AsyncSandbox:
    sandbox = await daytona.sandbox.get(sandbox_id)

    if sandbox.state in ["ARCHIVED", "STOPPED", "ARCHIVING"]:
        # Resume sandbox - /workspace content is restored
        await sandbox.start()
        await wait_for_sandbox_ready(sandbox, timeout=30)

    return sandbox
```

**Per-project persistence**:
```
Project P1:
├─ agent_run_1: creates app.py → saved in sandbox S1
├─ agent_run_2: sees app.py, modifies it → still in S1
├─ agent_run_3: sees modified app.py → still in S1
│
│  (1 hour passes, cleanup runs, S1 deleted)
│
├─ agent_run_4: gets new sandbox S2 from pool
│              → app.py is GONE (unless saved externally)
```

**Content persistence summary**:

| Scenario | Content Preserved? |
|----------|-------------------|
| Same project, sandbox active | ✅ Yes |
| Same project, sandbox stopped/archived | ✅ Yes (resumes) |
| Same project, sandbox deleted (>1hr idle) | ❌ No |
| New project | ❌ No (fresh sandbox from pool) |

**For permanent storage**, agent must explicitly:
- Push to git (via `git_sync` tool)
- Upload to cloud storage
- Let user download files via HTTP server (port 8080)

**Design rationale**: Session persistence (not long-term storage) keeps infrastructure simple and costs low, but requires explicit save actions for important work.

### 6.6 Agent vs. Sandbox Execution

**Important distinction**: The agent runs on the Suna server; only tools execute in the sandbox.

```
┌─────────────────────────────────────────────────────────────┐
│                      SUNA SERVER                             │
│                                                              │
│  Agent Execution (StatelessCoordinator)                      │
│  ├─ LLM calls (via LiteLLM)        ← Runs here              │
│  ├─ ReAct loop orchestration       ← Runs here              │
│  ├─ Tool call parsing              ← Runs here              │
│  └─ State management               ← Runs here              │
│                                                              │
└──────────────────────────┬──────────────────────────────────┘
                           │ API calls
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                 SANDBOX (Daytona Container)                  │
│                                                              │
│  Tool Execution Only:                                        │
│  ├─ Shell commands (python, npm, etc.)  ← Runs here         │
│  ├─ File read/write operations          ← Runs here         │
│  ├─ Browser automation                  ← Runs here         │
│  └─ Code execution                      ← Runs here         │
│                                                              │
│  (No agent logic - just a "dumb" execution environment)      │
└─────────────────────────────────────────────────────────────┘
```

**Why this design?**
- **Security**: Agent logic (API keys, LLM access) stays on secure server
- **Isolation**: Untrusted code runs in disposable container
- **Efficiency**: One sandbox serves multiple agent runs
- **Cost**: LLM calls don't consume container resources

### 6.7 Tool → Sandbox Connection

All sandbox tools inherit from `SandboxToolsBase`:

```python
# From tool_base.py
class SandboxToolsBase(Tool):
    async def _ensure_sandbox(self) -> AsyncSandbox:
        sandbox_info = await resolve_sandbox(
            project_id=self.project_id,
            account_id=account_id,
            require_started=True
        )
        return sandbox_info.sandbox
```

**Shell Execution** (`sb_shell_tool.py`):
```python
# PTY session for real-time streaming
pty_handle = await sandbox.process.create_pty_session(
    id=pty_session_id,
    on_data=on_pty_data,  # Stream output to frontend
    pty_size=PtySize(cols=120, rows=40)
)
await pty_handle.send_input(f"cd /workspace\n{command}\n")
```

**File Operations** (`sb_files_tool.py`):
```python
# Daytona FS interface
await sandbox.fs.upload_file(content, path)
content = await sandbox.fs.download_file(path)
files = await sandbox.fs.list_files(path)
```

**Browser Automation** (`browser_tool.py`):
```python
# Via Stagehand API running inside container
POST http://sandbox:8004/api/navigate {"url": "..."}
POST http://sandbox:8004/api/act {"action": "click", "selector": "..."}
GET  http://sandbox:8004/api/screenshot
```

### 6.8 Isolation Guarantees

| Layer | Mechanism |
|-------|-----------|
| **Process** | Each command runs in isolated PTY/session |
| **File System** | All ops scoped to `/workspace` |
| **Network** | Container-level isolation via Docker |
| **Browser** | Separate Chromium instance, no shared state |
| **Compute** | Resource limits (CPU, memory, disk) |
| **Time** | Timeout enforcement (300-600s per tool) |

**Multi-tenant isolation**: Each project gets its own container. No cross-contamination between users.

### 6.9 Key Files

| File | Purpose |
|------|---------|
| `sandbox/sandbox.py` | Daytona integration (create/get/delete) |
| `sandbox/resolver.py` | Sandbox allocation (cache → DB → pool → create) |
| `sandbox/pool_service.py` | Pool management (claim, replenish) |
| `sandbox/pool_background.py` | Background tasks (warmup, keepalive, cleanup) |
| `sandbox/tool_base.py` | Base class for sandbox tools |
| `tools/sb_shell_tool.py` | Shell command execution |
| `tools/sb_files_tool.py` | File operations |
| `tools/browser_tool.py` | Browser automation |
| `sandbox/docker/Dockerfile` | Container image definition |
| `sandbox/docker/supervisord.conf` | Process supervision |
| `sandbox/docker/browserApi.ts` | Stagehand server |

### 6.10 Implications for Flovyn

To provide similar sandbox capabilities, Flovyn would need:

1. **Container orchestration** - Daytona, Firecracker, or Kubernetes integration
2. **Sandbox pooling** - Pre-warm containers for fast allocation
3. **Tool abstraction** - Base class for sandbox-aware tools
4. **State persistence** - Map sandbox to workflow/project
5. **Resource management** - Timeouts, cleanup, cost tracking

**Alternative approaches**:
- **E2B** - Managed sandbox service (used by some Suna tools)
- **Modal** - Serverless containers
- **Fly.io Machines** - Fast-booting VMs
- **Firecracker** - MicroVMs (what AWS Lambda uses)

---

## 7. Gap Analysis: Flovyn vs Suna

### 7.1 What Flovyn Has (Advantages)

| Feature | Flovyn | Suna | Notes |
|---------|--------|------|-------|
| **Durable Execution** | Native | None | Flovyn survives crashes |
| **Deterministic Replay** | Event-sourced | None | Debug any agent decision |
| **Multi-tenancy** | Built-in | Basic | Org + space isolation |
| **Task Retries** | Policy-based | Basic | Exponential backoff |
| **Durable Timers** | First-class | None | Agent can sleep days |
| **Durable Promises** | First-class | None | Wait for external events |
| **Child Workflows** | Native | None | Complex orchestration |
| **Type-safe SDKs** | Multi-lang | Python only | Rust, Python, Kotlin, TS |

### 7.2 What Flovyn Lacks

| Gap | Suna Implementation | Priority |
|-----|---------------------|----------|
| **LLM Integration** | LiteLLM (multi-provider) | P0 |
| **Tool Registry** | 30+ built-in tools | P0 |
| **ReAct Loop** | StatelessCoordinator | P0 |
| **Streaming** | Redis real-time | P1 |
| **Sandbox Execution** | Docker/Daytona + pooling | P1 |
| **Browser Automation** | Playwright + Stagehand | P1 |
| **MCP Support** | Full integration | P1 |
| **Context Compression** | LLM summarization | P2 |
| **Agent Versioning** | Full lifecycle | P2 |

### 7.3 Flovyn's Path to Parity

**Option A: Workflow-Based Agent** (Current Capability)

```python
@workflow(name="react-agent")
class ReActAgentWorkflow:
    async def run(self, ctx: WorkflowContext, input: AgentInput):
        messages = [{"role": "user", "content": input.query}]

        for turn in range(25):  # Max turns
            # Must implement LLMTask yourself
            response = await ctx.schedule(LLMTask, messages)
            messages.append({"role": "assistant", "content": response.content})

            if not response.tool_calls:
                return AgentOutput(response=response.content)

            # Must implement each tool as a task
            for tool_call in response.tool_calls:
                result = await ctx.schedule(ToolTask, tool_call)
                messages.append({"role": "tool", "content": result})

        return AgentOutput(response="Max turns reached")
```

**Pros**: Durable, replayable, auditable
**Cons**: No streaming, must implement everything

**Option B: First-Class Agent Support** (Future)

See `dev/docs/research/ai-agent-native/20260103_14_mvp_implementation.md` for detailed roadmap:

1. **Phase 0**: Content-addressed store for large payloads
2. **Phase 1**: `LlmTask` as built-in primitive
3. **Phase 2**: Streaming task output
4. **Phase 3**: Agent workflow template with context management
5. **Phase 4**: MCP integration
6. **Phase 5**: Sandbox execution policies

---

## 8. Key Architectural Patterns to Learn

### 8.1 Stateless Coordinator Pattern

Suna's "stateless" design means:
- No persistent state between API calls
- State recreated per agent_run from external storage
- No in-memory locks or shared state across runs
- Easy horizontal scaling

**Flovyn analogy**: Event-sourced workflows already follow this pattern.

### 8.2 Thread-Based Conversations

```
Thread (persistent container)
├─ agent_run_1 (ephemeral execution)
├─ agent_run_2 (loads full history)
└─ agent_run_3 (continues conversation)
```

**Flovyn mapping**:
- Thread → Workflow (or parent workflow)
- agent_run → Child workflow or workflow continuation

### 8.3 Auto-Continue Decision Tree

```
LLM Response
    ↓
┌───────────────────────────┐
│ finish_reason == ?        │
├───────────────────────────┤
│ "tool_calls" → CONTINUE   │  Execute tools, loop
│ "length"     → CONTINUE   │  Hit token limit, continue
│ "stop"       → TERMINATE  │  Agent decided to stop
│ "end_turn"   → TERMINATE  │  Explicit end
└───────────────────────────┘
    ↓
Also check: step_count < max_steps (25)
```

---

## 9. Recommendations

### 9.1 Short-Term (Use Current Primitives)

1. **Implement ReAct loop as workflow** - Leverage existing durability
2. **Use tasks for LLM calls** - Get retry semantics
3. **Use promises for user input** - Multi-turn conversations
4. **Use workflow state for context** - Persist message history

### 9.2 Medium-Term (New Features)

1. **Add streaming task output** - Real-time feedback
2. **Add `LlmTask` primitive** - Built-in LLM integration
3. **Add content store** - Efficient large payload storage

### 9.3 Long-Term (Full Parity)

1. **Tool registry** - Dynamic tool registration
2. **MCP support** - Protocol-based extensibility
3. **Sandbox integration** - Container orchestration with pooling (see Section 6)
4. **Context compression** - Automatic history management

### 9.4 Sandbox Strategy Options

| Option | Pros | Cons |
|--------|------|------|
| **Daytona** (like Suna) | Full-featured, proven | Complex setup, cost |
| **E2B** | Managed service, easy | Vendor lock-in, latency |
| **Modal** | Serverless, fast cold start | Python-focused |
| **Firecracker** | Fast microVMs, secure | Operational complexity |
| **Docker + K8s** | Familiar, flexible | Slower than microVMs |

**Recommendation**: Start with E2B for MVP (managed), migrate to Daytona/Firecracker for cost optimization at scale.

---

## 10. Flovyn's Unique Value Proposition

Even without full Suna parity, Flovyn offers advantages for AI agents:

| Capability | Benefit |
|------------|---------|
| **Durability** | Agents survive infrastructure failures |
| **Auditability** | Complete event log of agent decisions |
| **Debugging** | Replay any agent run deterministically |
| **Long-running** | Agents can run for days with durable timers |
| **Integration** | Wait for external events (webhooks, human approval) |
| **Scale** | Horizontal scaling via worker pools |

**Best Use Cases Today**:
- Batch processing agents (data analysis, research)
- Multi-step approval workflows
- Long-running background agents
- Agents requiring guaranteed completion

---

## 11. References

### Suna Codebase
- Repository: `competitors/suna/`
- Agent execution: `backend/core/agents/runner/`
- Tools: `backend/core/tools/`
- Sandbox: `backend/core/sandbox/`

### Flovyn AI Agent Research
- Main research: `dev/docs/research/20251231_ai_agent_native.md`
- Implementation plan: `dev/docs/research/ai-agent-native/20260103_14_mvp_implementation.md`
- Opportunities: `dev/docs/research/ai-agent-native/20260103_10_flovyn_opportunities.md`

### External
- [Anthropic: Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)
- [ReAct: Synergizing Reasoning and Acting](https://arxiv.org/abs/2210.03629)
