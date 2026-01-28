# OpenHands Competitor Analysis: AI Software Engineer Platform

Date: 2026-01-28

## Executive Summary

This research analyzes **OpenHands** (formerly OpenDevin), an open-source AI software engineering platform. Like Suna, OpenHands implements **autonomous agents** using a ReAct loop, but focuses specifically on software development tasks with benchmark-driven quality (77.6% on SWE-bench).

**Key Finding**: OpenHands has a more mature architecture than Suna with better separation of concerns (V1 SDK), multiple runtime backends (Docker, Kubernetes, Remote), and sophisticated memory management (6 condenser strategies). However, it has fewer built-in tools and is more focused on coding than general-purpose agent tasks.

---

## 1. OpenHands Overview

### 1.1 What is OpenHands?

| Attribute | Value |
|-----------|-------|
| **Repository** | `github.com/All-Hands-AI/OpenHands` |
| **Former Name** | OpenDevin |
| **Type** | Autonomous AI Software Engineer |
| **Architecture** | Event-driven with pluggable runtimes |
| **Primary Language** | Python (backend), React (frontend) |
| **Stars** | ~40k+ |

### 1.2 Core Value Proposition

OpenHands provides an **AI software engineer** that can:
- Write, edit, and debug code autonomously
- Run commands in isolated sandboxes
- Browse the web for documentation/research
- Delegate subtasks to specialized agents
- Achieve 77.6% on SWE-bench (software engineering benchmark)

**Deployment Options**:
- SDK: Composable Python library
- CLI: Command-line interface
- Local GUI: Web-based interface
- Cloud: Hosted solution
- Enterprise: Self-hosted with RBAC

---

## 2. Architecture

### 2.1 Component Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    OPENHANDS ARCHITECTURE                    │
├─────────────────────────────────────────────────────────────┤
│  Frontend (React)                                            │
│  - Conversation UI                                           │
│  - File browser                                              │
│  - Terminal view                                             │
├─────────────────────────────────────────────────────────────┤
│  App Server (FastAPI)                                        │
│  - REST API + SSE streaming                                  │
│  - Conversation management                                   │
│  - Session handling                                          │
├─────────────────────────────────────────────────────────────┤
│  Agent Controller                                            │
│  - ReAct loop orchestration                                  │
│  - State management                                          │
│  - Memory/condenser strategies                               │
├─────────────────────────────────────────────────────────────┤
│  EventStream (Pub/Sub)                                       │
│  - Actions (agent → environment)                             │
│  - Observations (environment → agent)                        │
│  - Thread-safe queue processing                              │
├─────────────────────────────────────────────────────────────┤
│  Runtime Layer (Pluggable)                                   │
│  - DockerRuntime (default)                                   │
│  - KubernetesRuntime                                         │
│  - RemoteRuntime                                             │
│  - LocalRuntime (no isolation)                               │
├─────────────────────────────────────────────────────────────┤
│  Storage                                                     │
│  - File-based event store (JSON)                             │
│  - SQL database (conversation metadata)                      │
│  - S3/GCS (optional cloud storage)                           │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Key Files

| Component | Location | Purpose |
|-----------|----------|---------|
| **Agent Controller** | `openhands/controller/agent_controller.py` | Main ReAct loop (~1000 lines) |
| **CodeAct Agent** | `openhands/agenthub/codeact_agent/codeact_agent.py` | Production agent |
| **EventStream** | `openhands/events/stream.py` | Pub/sub backbone |
| **Docker Runtime** | `openhands/runtime/impl/docker/docker_runtime.py` | Container management |
| **Action Server** | `openhands/runtime/action_execution_server.py` | HTTP server in container |
| **Memory Condenser** | `openhands/memory/condenser/` | 6 history compression strategies |

---

## 3. Multi-Turn Agent Execution

### 3.1 Agent Type Classification

| Type | Description | LLM Role | OpenHands? |
|------|-------------|----------|------------|
| **Workflow** | Orchestrated chains of LLM calls | Code controls flow | No |
| **Autonomous Agent** | LLM decides actions in a loop | LLM controls flow | **Yes** |

**OpenHands implements autonomous agents** using function-calling ReAct pattern.

### 3.2 ReAct Loop Implementation

```
User Message
     ↓
┌────────────────────────────────────────────────────────┐
│  AgentController._step() Loop                          │
│                                                        │
│  ┌──────────────────────────────────────────────────┐ │
│  │ Step N:                                           │ │
│  │  1. Get state & condense history                  │ │
│  │  2. Build LLM prompt (system + history + tools)   │ │
│  │  3. Call LLM with function calling                │ │
│  │  4. Parse tool calls → Action objects             │ │
│  │  5. Execute action in runtime (sandbox)           │ │
│  │  6. Receive Observation                           │ │
│  │  7. Update state & publish events                 │ │
│  │  8. Check termination conditions                  │ │
│  └──────────────────────────────────────────────────┘ │
│                    ↓                                   │
│  Repeat until: finish() OR max_iterations OR budget    │
└────────────────────────────────────────────────────────┘
     ↓
Final Response to User
```

**Source**: `agent_controller.py` lines 860-1033

### 3.3 Termination Conditions

| Condition | Trigger |
|-----------|---------|
| Agent calls `finish` tool | `AgentFinishAction` |
| Max iterations exceeded | `config.max_iterations` |
| Max budget exceeded | Token/cost limit |
| User stops agent | Manual intervention |
| Error encountered | Unrecoverable error |

**Note**: No hard-coded turn limit - controlled by configuration.

### 3.4 State Management

**State Object** (`controller/state/state.py`):
```python
@dataclass
class State:
    history: list[Event]      # Full event history
    start_id: int             # Event range tracking
    end_id: int
    inputs: dict              # Task inputs
    outputs: dict             # Task outputs
    iteration: int            # Current step count
    max_iterations: int       # Limit
    agent_state: AgentState   # LOADING, RUNNING, PAUSED, FINISHED
```

### 3.5 Memory Management (Condensers)

OpenHands has **6 condenser strategies** for handling long conversations:

| Strategy | Description |
|----------|-------------|
| **Recent Events** | Keep only N most recent events |
| **LLM Attention** | Use LLM to identify important events |
| **Structural Summary** | Generate structured summaries |
| **Observation Masking** | Hide large observation outputs |
| **Hybrid** | Combine multiple strategies |
| **No-op** | Keep everything (for debugging) |

**Location**: `openhands/memory/condenser/`

---

## 4. Tool System

### 4.1 Tool Categories

| Tool | File | Purpose |
|------|------|---------|
| **bash** | `tools/bash.py` | Execute shell commands |
| **ipython** | `tools/ipython.py` | Execute Python code (Jupyter) |
| **str_replace_editor** | `tools/str_replace_editor.py` | File viewing and editing |
| **browser** | `tools/browser.py` | Web browsing |
| **finish** | `tools/finish.py` | Signal task completion |
| **think** | `tools/think.py` | Internal reasoning (logged) |
| **task_tracker** | `tools/task_tracker.py` | Task management |
| **MCP tools** | Dynamic | Model Context Protocol integration |

**Total**: ~10 core tools (fewer than Suna's 30+, but more focused)

### 4.2 Tool Definition Pattern

```python
# OpenAI-compatible function calling format
ChatCompletionToolParam(
    type='function',
    function=ChatCompletionToolParamFunctionChunk(
        name='execute_bash',
        description='Execute bash command...',
        parameters={
            'type': 'object',
            'properties': {
                'command': {'type': 'string'},
                'timeout': {'type': 'number'},
                'security_risk': {'type': 'string', 'enum': ['LOW', 'MEDIUM', 'HIGH']},
            },
            'required': ['command', 'security_risk']
        }
    )
)
```

### 4.3 Security Risk Assessment

Each action includes a **security_risk** level:
- **LOW**: Safe operations (read files, list directories)
- **MEDIUM**: Modifications with limited scope
- **HIGH**: Requires user confirmation (destructive operations)

---

## 5. Streaming Architecture

### 5.1 Protocol

OpenHands uses **HTTP Server-Sent Events (SSE)**, not WebSockets.

```python
# From app_conversation_router.py
@router.post('/stream-start')
async def stream_conversation_start(...) -> StreamingResponse:
    return StreamingResponse(
        _stream_app_conversation_start(request, user_context),
        media_type='application/json'
    )

async def _stream_app_conversation_start(...) -> AsyncGenerator[str, None]:
    yield '[\n'
    async for task in app_conversation_service.start_app_conversation(request):
        yield task.model_dump_json()
    yield ']'
```

### 5.2 LLM Streaming

```python
# From streaming_llm.py
async def async_streaming_completion_wrapper(*args, **kwargs):
    kwargs['stream'] = True
    resp = await litellm_acompletion(**kwargs)

    async for chunk in resp:
        content = chunk['choices'][0]['delta'].get('content', '')
        yield content

        if config.on_cancel_requested_fn():
            break
```

---

## 6. Sandbox Execution

### 6.1 Architecture Overview

```
Agent Process (App Server)
         │
         │ HTTP Request (execute_action)
         ▼
┌─────────────────────────────────────────────────────────────┐
│              Docker Container (Sandbox)                      │
│                                                              │
│  Action Execution Server (FastAPI, uvicorn)                  │
│  ├─ POST /execute_action                                     │
│  ├─ POST /upload_file                                        │
│  ├─ POST /list_files                                         │
│  └─ POST /update_mcp_server                                  │
│                                                              │
│  Working Directory: /openhands/code/                         │
│                                                              │
│  Plugins:                                                    │
│  ├─ Jupyter (IPython kernel)                                 │
│  ├─ VSCode Server (optional)                                 │
│  ├─ Browser (optional)                                       │
│  └─ AgentSkills (Python utilities)                           │
│                                                              │
│  User: Per-session account with passwordless sudo            │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 Runtime Backends

| Runtime | Use Case | Isolation |
|---------|----------|-----------|
| **DockerRuntime** | Default, local development | Full container isolation |
| **KubernetesRuntime** | Production, scaling | Pod-level isolation |
| **RemoteRuntime** | Cloud/distributed | Network isolation |
| **LocalRuntime** | Testing only | **No isolation** |

### 6.3 Agent vs. Sandbox Separation

**Same pattern as Suna**: Agent runs on server, tools execute in sandbox.

```
┌─────────────────────────────────────────────────────────────┐
│                      APP SERVER                              │
│                                                              │
│  Agent Controller                                            │
│  ├─ LLM calls (via LiteLLM)        ← Runs here              │
│  ├─ ReAct loop orchestration       ← Runs here              │
│  ├─ Tool call parsing              ← Runs here              │
│  └─ State management               ← Runs here              │
│                                                              │
└──────────────────────────┬──────────────────────────────────┘
                           │ HTTP API
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                 SANDBOX (Docker Container)                   │
│                                                              │
│  Tool Execution Only:                                        │
│  ├─ Bash commands                   ← Runs here             │
│  ├─ Python/Jupyter execution        ← Runs here             │
│  ├─ File operations                 ← Runs here             │
│  └─ Browser automation              ← Runs here             │
└─────────────────────────────────────────────────────────────┘
```

### 6.4 Container Lifecycle

```
Session Creation
    ↓
Container Init
├─ Port allocation (with locks to prevent races)
│  ├─ Execution server: 30000-39999
│  ├─ VSCode: 40000-49999
│  └─ App ports: 50000-59999
├─ Volume mounting (workspace)
├─ Environment setup
└─ User account creation
    ↓
Container Start (tini init + action server)
    ↓
Wait Until Alive (health check, 120s timeout)
    ↓
Ready for Actions
    ↓
Session Close
├─ keep_runtime_alive=true → Container persists
└─ keep_runtime_alive=false → Container removed
```

### 6.5 Content Persistence

**Two-tier model** (similar to Suna):

| Layer | Storage | Persistence |
|-------|---------|-------------|
| **Workspace files** | `/openhands/code/` in container | Via Docker volume mounts |
| **Event history** | File store (JSON) or S3/GCS | Always persisted |
| **Agent state** | Pickle + Base64 | Resumable |

**File Store Structure**:
```
sessions/{sid}/
├── events/0.json, 1.json, ...  # Immutable event log
├── metadata.json               # Session metadata
├── init.json                   # Initialization params
├── agent_state.pkl             # Agent state (resumable)
└── conversation_stats.pkl      # Statistics
```

**Key difference from Suna**: OpenHands has explicit support for **session resume** via pickled agent state.

### 6.6 Content Persistence Across Sessions

| Scenario | Files Preserved? | Events Preserved? |
|----------|------------------|-------------------|
| Same session, active | ✅ Yes | ✅ Yes |
| Same session, container stopped | ✅ Yes (if volume mounted) | ✅ Yes |
| Same session, container removed | ❌ No (unless volume) | ✅ Yes |
| Session resume | ✅ Via volume | ✅ Via file store |
| New session | ❌ Fresh container | ❌ New event stream |

### 6.7 Isolation & Security

| Layer | Mechanism |
|-------|-----------|
| **Container** | Docker namespace isolation |
| **User** | Per-session user account (not root) |
| **Ports** | Unique port ranges with locks |
| **Actions** | Security risk assessment (LOW/MEDIUM/HIGH) |
| **Confirmation** | User approval for HIGH-risk actions |

**Security Analyzers** (`openhands/security/`):
1. **LLM Risk Analyzer** - Uses LLM to assess risk
2. **Invariant Analyzer** - Detects secret leaks, malicious commands
3. **Gray Swan Analyzer** - External AI safety monitoring

---

## 7. Event System

### 7.1 Event Types

**Actions** (Agent → Environment):
- `MessageAction` - User/agent messages
- `CmdRunAction` - Shell commands
- `FileEditAction`, `FileReadAction` - File operations
- `IPythonRunCellAction` - Python execution
- `BrowseInteractiveAction` - Browser automation
- `AgentFinishAction` - Task completion
- `AgentDelegateAction` - Subtask delegation

**Observations** (Environment → Agent):
- `CmdOutputObservation` - Command output
- `FileReadObservation` - File contents
- `ErrorObservation` - Errors
- `AgentStateChangedObservation` - State transitions

### 7.2 EventStream Architecture

```python
# From events/stream.py
class EventStream:
    def add_event(self, event: Event, source: EventSource):
        event._timestamp = datetime.now().isoformat()
        event._id = self.cur_id
        self.cur_id += 1

        # Persist to file store
        self.file_store.write(filename, event_json)

        # Publish to subscribers
        self._queue.put(event)

# Subscribers
class EventStreamSubscriber(Enum):
    AGENT_CONTROLLER = 'agent_controller'
    SERVER = 'server'
    RUNTIME = 'runtime'
    MEMORY = 'memory'
    RESOLVER = 'resolver'
```

---

## 8. LLM Integration

### 8.1 Provider Support

OpenHands uses **LiteLLM** supporting 100+ providers:
- OpenAI
- Anthropic (with prompt caching)
- Google Gemini
- AWS Bedrock
- Custom endpoints

### 8.2 Key Features

| Feature | Support |
|---------|---------|
| **Function calling** | ✅ Native |
| **Streaming** | ✅ Async generators |
| **Vision** | ✅ Multi-modal |
| **Prompt caching** | ✅ Anthropic |
| **Extended thinking** | ✅ Gemini, Claude |
| **Cost tracking** | ✅ Per-call metrics |
| **Retry logic** | ✅ Exponential backoff |

---

## 9. Gap Analysis: Flovyn vs OpenHands

### 9.1 What Flovyn Has (Advantages)

| Feature | Flovyn | OpenHands | Notes |
|---------|--------|-----------|-------|
| **Durable Execution** | ✅ Native | ⚠️ File-based | Flovyn's event sourcing is more robust |
| **Deterministic Replay** | ✅ Event-sourced | ⚠️ Partial | OpenHands can resume but not fully replay |
| **Multi-tenancy** | ✅ Built-in | ⚠️ Basic | Flovyn has org + space isolation |
| **Task Retries** | ✅ Policy-based | ⚠️ Basic | Flovyn has exponential backoff |
| **Durable Timers** | ✅ First-class | ❌ None | Agent can sleep days |
| **Durable Promises** | ✅ First-class | ❌ None | Wait for external events |

### 9.2 What Flovyn Lacks

| Gap | OpenHands Implementation | Priority |
|-----|--------------------------|----------|
| **LLM Integration** | LiteLLM (100+ providers) | P0 |
| **ReAct Loop** | AgentController | P0 |
| **Memory/Condensers** | 6 strategies | P1 |
| **Streaming** | SSE + async generators | P1 |
| **Sandbox** | Docker + Kubernetes + Remote | P1 |
| **File Editor** | str_replace_editor tool | P2 |
| **Jupyter** | IPython kernel plugin | P2 |
| **Security Analyzer** | 3 implementations | P2 |

### 9.3 Key Architectural Differences

| Aspect | Suna | OpenHands | Flovyn |
|--------|------|-----------|--------|
| **Sandbox** | Daytona (external) | Docker (built-in) | None |
| **Pooling** | Pre-warmed pool | On-demand | N/A |
| **Streaming** | Redis | SSE | Emerging |
| **Memory** | Basic compression | 6 condenser strategies | None |
| **Multi-agent** | No | Yes (delegation) | Child workflows |
| **Durability** | None | File-based resume | Event-sourced |

---

## 10. Flovyn's Unique Value Proposition

Even without full OpenHands parity, Flovyn offers advantages:

| Capability | Benefit |
|------------|---------|
| **True Durability** | Workflows survive any failure |
| **Deterministic Replay** | Debug any agent decision exactly |
| **Long-running** | Agents can pause for days/weeks |
| **External Integration** | Durable promises for webhooks |
| **Multi-tenant** | Enterprise-grade isolation |

**Best Use Cases for Flovyn AI Agents**:
- Long-running code generation pipelines
- Multi-step approval workflows
- Agents requiring guaranteed completion
- Integration with external systems (CI/CD, review tools)

---

## 11. Comparison: Suna vs OpenHands

| Aspect | Suna | OpenHands |
|--------|------|-----------|
| **Focus** | General-purpose agents | Software engineering |
| **Tools** | 30+ built-in | ~10 focused tools |
| **Sandbox** | Daytona (external) | Docker (built-in) |
| **Memory** | Basic | 6 condenser strategies |
| **Multi-agent** | No | Yes (delegation) |
| **Benchmark** | None published | 77.6% SWE-bench |
| **Maturity** | Newer | More mature (V1 SDK) |
| **Community** | Smaller | ~40k stars |

**Recommendation**: Study OpenHands for:
- Memory/condenser patterns
- Security analyzer architecture
- Multi-runtime support (Docker, K8s, Remote)
- Session resume/persistence

---

## 12. References

### OpenHands Codebase
- Repository: `competitors/OpenHands/`
- Agent execution: `openhands/controller/`
- Tools: `openhands/agenthub/codeact_agent/tools/`
- Runtime: `openhands/runtime/`
- Memory: `openhands/memory/condenser/`
- Security: `openhands/security/`

### External
- [OpenHands GitHub](https://github.com/All-Hands-AI/OpenHands)
- [SWE-bench Leaderboard](https://www.swebench.com/)
- [Anthropic: Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)
