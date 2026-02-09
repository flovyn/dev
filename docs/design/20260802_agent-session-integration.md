# Agent Session Integration

**Date:** 2026-02-08
**Status:** Draft

## Context

We have three pieces of working software that need to be connected:

1. **flovyn-app** (Next.js 15) has a [PoC AI UI](/Users/manhha/Developer/manhha/flovyn/dev/docs/design/20260207_migrate_ai_ui_to_flovyn_app.md) with chat interface, tool execution visualization, artifact display, and run management — all on mock data. Uses `@assistant-ui/react` as the chat framework, with Effect-based SSE streaming infrastructure already wired. Original UX rationale in [idea.txt](/Users/manhha/Developer/manhha/flovyn/flovyn-ai/.local/idea.txt).

2. **agent-server** (Rust) is a durable AI agent running as a Flovyn worker. It supports multi-turn conversations with signals, Anthropic/OpenAI/OpenRouter LLM providers, a Docker `run-sandbox` tool for isolated code execution, token streaming, thinking, and steering. ~2,500 lines, 65 tests, production-ready for MVP.

3. **flovyn-server** (Rust) already has the full orchestration infrastructure: workflow execution with event sourcing, SSE streaming (consolidated stream includes task tokens), signal delivery, queryable state, long-polling dispatch to workers, and org-scoped REST API.

These three components are already designed to work together via the Flovyn SDK — agent-server polls flovyn-server for work, streams tokens back, and exposes state. The gap is connecting flovyn-app's mock UI to the real backend.

## Problem Statement

The pieces exist but aren't connected:

1. **flovyn-app** uses a mock chat adapter that simulates 5 hardcoded tool steps. It needs a real adapter that creates workflow executions, streams SSE events, and sends follow-up signals.

2. **agent-server** only has `run-sandbox` (Docker-based isolated execution). For a Manus-like experience where the agent works with the user's project, it needs host-level tools: read/write/edit files, run shell commands, search the codebase.

3. **The streaming protocol** between agent-server and flovyn-app needs a defined contract so the UI knows how to render tokens, thinking blocks, tool executions, and terminal output.

## Goals

1. **End-to-end one-shot task execution**: User types a prompt in flovyn-app, agent executes with real LLM + tools, results stream back in real-time.
2. **Interactive multi-turn chat**: User can send follow-up messages. The agent maintains conversation history across turns.
3. **Host OS tools**: Agent can read/write/edit files and execute shell commands directly on the host filesystem.
4. **Real-time streaming**: LLM tokens, thinking, tool calls, and terminal output stream to the UI as they happen.

## Non-Goals

- **Workflows** (visual DAG builder) — separate effort, mock data stays
- **Tools marketplace** (reusable tool definitions) — separate effort
- **Agent templates** (predefined agent configs) — separate effort
- **Cloud sandbox** (remote sandboxed environments) — the existing Docker `run-sandbox` is sufficient; full cloud sandbox is a separate product concern
- **Extensions/plugins** for the agent — no extension system for MVP
- **Session branching/forking** — linear conversations only
- **Context compaction** — the durable workflow persists full history; compaction is an optimization for later

## Architecture Overview

A session is a **workflow execution** of kind `"agent"`. All existing Flovyn infrastructure works as-is.

```
flovyn-app (browser)                  flovyn-server              agent-server (worker)
─────────────────────                 ──────────────             ─────────────────────

1. POST /workflow-executions ───────► Create execution ──┐
   { kind: "agent",                   (persisted)        │
     input: AgentWorkflowInput }                         │
                                                         ▼
2. GET  /workflow-executions/         ◄─── SSE ──── Consolidated stream
   {id}/stream/consolidated                              ▲
   (EventSource)                                         │
                                      PollWorkflow ──────┘
                                      (gRPC long-poll)
                                                         │
                                                         ▼
                                                    AgentWorkflow.execute()
                                                    ├─ LlmRequestTask (stream tokens)
                                                    ├─ RunSandboxTask (stream terminal)
                                                    ├─ ReadFileTask
                                                    ├─ WriteFileTask
                                                    ├─ EditFileTask
                                                    ├─ BashTask (stream terminal)
                                                    ├─ GrepTask
                                                    └─ FindTask
                                                         │
3. POST /workflow-executions/ ──────► SignalWorkflow ─────┘
   {id}/signal                        (gRPC)          (userMessage signal
   { name: "userMessage",                              consumed by workflow)
     payload: { text: "..." } }

4. GET  /workflow-executions/ ──────► Read workflow_state
   {id}/state?key=messages            (PostgreSQL)
```

**Key insight**: No new server infrastructure is needed. The workflow execution API, SSE streaming, and signal delivery already exist. We're wiring the UI to use them and adding tools to the agent.

## Session Lifecycle

### 1. Create Session

User submits a prompt from the "New Run" page. flovyn-app calls:

```
POST /api/orgs/{orgSlug}/workflow-executions
{
  "kind": "agent",
  "input": {
    "systemPrompt": "You are a helpful coding assistant...",
    "userPrompt": "Analyze the top 10 trending GitHub repos...",
    "model": {
      "provider": "openrouter",
      "modelId": "deepseek/deepseek-chat-v3-0324"
    },
    "tools": ["read", "write", "edit", "bash", "grep", "find", "run-sandbox"],
    "config": {
      "maxTurns": 25,
      "maxTokens": 16384,
      "temperature": 0.7,
      "thinking": "medium"
    }
  }
}
```

Response: `{ "id": "<workflow-execution-id>", "status": "RUNNING", ... }`

The UI immediately subscribes to the consolidated SSE stream and navigates to the run detail page.

### 2. Stream Events

flovyn-app connects to:
```
GET /api/orgs/{orgSlug}/workflow-executions/{id}/stream/consolidated
Accept: text/event-stream
```

Events arrive as the agent executes. See [Streaming Protocol](#streaming-protocol) for the event format.

### 3. Send Follow-up

When the agent reaches `waiting_for_input` status (visible via SSE state change or state query), the user can type a follow-up:

```
POST /api/orgs/{orgSlug}/workflow-executions/{id}/signal
{
  "name": "userMessage",
  "payload": { "text": "Add a comparison table to the report" }
}
```

The agent's outer loop consumes this signal and starts a new inner loop of LLM calls + tool execution.

### 4. Steering (Interrupt)

If the agent is mid-execution (running tools) and the user sends a message, it works as **steering**: the agent checks for pending signals between tool calls, skips remaining tools if a steering message is found, and incorporates the user's message into the next LLM call. This is already implemented in agent-server.

### 5. Cancel

```
POST /api/orgs/{orgSlug}/workflow-executions/{id}/cancel
```

The agent checks `ctx.check_cancellation()` at each loop iteration and exits cleanly.

### 6. View History

Past sessions are regular workflow executions filtered by `kind=agent`:

```
GET /api/orgs/{orgSlug}/workflow-executions?kind=agent
```

Full conversation history is stored in workflow state:
```
GET /api/orgs/{orgSlug}/workflow-executions/{id}/state?key=messages
```

## Streaming Protocol

The agent-server streams events through the Flovyn SDK's task streaming API. These arrive at the UI via SSE as `Token` events within the consolidated workflow stream.

### Event Format

All structured events are JSON objects sent via `ctx.stream_data_value()`. Plain text tokens are sent via `ctx.stream_token()`.

| Event | Source | Format | UI Rendering |
|-------|--------|--------|-------------|
| Text token | LlmRequestTask | Raw string via `stream_token()` | Append to assistant message bubble |
| Thinking delta | LlmRequestTask | `{ "type": "thinking_delta", "delta": "..." }` | Show in collapsible thinking block |
| Tool call start | AgentWorkflow | `{ "type": "tool_call_start", "tool_call": { "id", "name", "arguments" } }` | Add tool execution card to timeline |
| Tool call end | AgentWorkflow | `{ "type": "tool_call_end", "tool_call": { "id", "name" }, "result": { "content", "is_error" } }` | Update tool card with result/status |
| Terminal stdout | BashTask / RunSandboxTask | `{ "type": "terminal", "stream": "stdout", "data": "..." }` | Append to terminal view |
| Terminal stderr | BashTask / RunSandboxTask | `{ "type": "terminal", "stream": "stderr", "data": "..." }` | Append to terminal view (red) |
| File artifact | AgentWorkflow | `{ "type": "artifact", "path": "...", "action": "write"\|"edit", "artifact_type": "code"\|"document"\|... }` | Add/update artifact card in workspace panel |
| Status change | AgentWorkflow | State update: `status` key changes | Update UI status indicator |
| Turn count | AgentWorkflow | State update: `currentTurn` key changes | Update turn counter |

### SSE Event Mapping

On the flovyn-server SSE consolidated stream, events arrive as:

```
event: Token
data: {"taskExecutionId":"...","data":"Hello"}     // text token (string)

event: Token
data: {"taskExecutionId":"...","data":{"type":"tool_call_start",...}}  // structured event

event: WorkflowState
data: {"key":"status","value":"waiting_for_input"}  // state change

event: TaskState
data: {"taskExecutionId":"...","status":"COMPLETED"} // task lifecycle
```

The flovyn-app chat adapter parses these and routes them to the appropriate UI components.

## Tool System

### Current Tool (keep as-is)

| Tool | Execution | Description |
|------|-----------|-------------|
| `run-sandbox` | Docker container | Isolated Python/TypeScript execution. No network, 256MB RAM, 30s timeout. |

### New Host Tools (to implement in agent-server)

These run directly on the host OS, scoped to a configurable **working directory** passed in the session input.

| Tool | Parameters | Description |
|------|-----------|-------------|
| `read` | `path: string`, `offset?: number`, `limit?: number` | Read file contents (text or image). Max 2000 lines default. |
| `write` | `path: string`, `content: string` | Create or overwrite a file. |
| `edit` | `path: string`, `old_string: string`, `new_string: string`, `replace_all?: bool` | Find-and-replace edit within a file. |
| `bash` | `command: string`, `timeout?: number` | Execute shell command on host. Streams stdout/stderr. Default 120s timeout. |
| `grep` | `pattern: string`, `path?: string`, `glob?: string`, `type?: string` | Search file contents with regex. |
| `find` | `pattern: string`, `path?: string` | Find files by glob pattern. |

**Inspiration from pi-mono**: The tool architecture follows pi-mono's coding-agent pattern — a small set of composable file/shell tools that give the LLM full coding capabilities. The key tools (read, write, edit, bash, grep, find) are the same ones proven in pi-mono's production agent.

### Tool Implementation

Each host tool is a **Flovyn TaskDefinition** registered in agent-server:

```rust
pub struct ReadFileTask;

#[async_trait]
impl TaskDefinition for ReadFileTask {
    type Input = ReadFileInput;   // { path, offset?, limit? }
    type Output = ReadFileOutput; // { content, lines, truncated }

    fn kind(&self) -> &str { "read-file" }
    fn timeout_seconds(&self) -> Option<u32> { Some(30) }
    fn retry_config(&self) -> RetryConfig { RetryConfig { max_retries: 0, ..default() } }

    async fn execute(&self, input: Self::Input, ctx: &dyn TaskContext) -> Result<Self::Output> {
        // Direct filesystem access within working directory
        // Path validation: must be within working directory (no traversal)
    }
}
```

`BashTask` uses `tokio::process::Command` and streams stdout/stderr via `ctx.stream_data_value()` for real-time terminal output.

### Working Directory

The `AgentWorkflowInput` gains a new field:

```rust
pub struct AgentWorkflowInput {
    pub system_prompt: String,
    pub user_prompt: String,
    pub model: AgentModelConfig,
    pub tools: Vec<String>,
    pub config: AgentConfig,
    pub working_directory: Option<String>,  // NEW: host path, defaults to agent-server cwd
}
```

All host tools resolve paths relative to this directory. Path traversal outside the working directory is rejected.

### Tool JSON Schemas

Each tool's JSON schema is generated from the `Input` type via `schemars::JsonSchema` derive (already the pattern in agent-server). The tool registry maps tool names to schemas for the LLM.

## Frontend Integration

### Chat Adapter

Replace `mock-chat-adapter.ts` with a real adapter that bridges `@assistant-ui/react` and the Flovyn workflow API.

```typescript
// lib/ai/flovyn-chat-adapter.ts

export function createFlovynChatAdapter(options: {
  orgSlug: string;
  sessionId?: string;  // existing session for follow-ups
  model: ModelConfig;
  tools: string[];
  config: AgentConfig;
  workingDirectory?: string;
}): ChatModelAdapter {
  return {
    async *run({ messages, abortSignal }) {
      if (!sessionId) {
        // First message: create workflow execution
        const { id } = await createWorkflowExecution(orgSlug, {
          kind: "agent",
          input: buildAgentInput(messages, options),
        });
        sessionId = id;
      } else {
        // Follow-up: send signal
        await signalWorkflow(orgSlug, sessionId, "userMessage", {
          text: lastUserMessage(messages),
        });
      }

      // Subscribe to SSE consolidated stream
      yield* streamWorkflowEvents(orgSlug, sessionId, abortSignal);
    },
  };
}
```

The adapter yields `@assistant-ui/react` compatible events:
- `TextDelta` for text tokens
- `ToolCallBegin` / `ToolCallDelta` for tool calls
- Status updates trigger UI state changes

### Streaming Connection

Reuse the existing `useWorkflowStream` hook from `/hooks/useWorkflowStream.ts`, which already:
- Creates an EventSource via Effect
- Parses SSE events into typed objects
- Handles reconnection and cleanup

The chat adapter wraps this hook into the `@assistant-ui/react` streaming interface.

### Tool Execution UI

The existing `tool-execution-ui.tsx` component renders a timeline of tool steps. Currently it uses hardcoded tool types (`PlanningToolUI`, `WebSearchToolUI`, etc.).

Replace with a **generic tool renderer** driven by the streaming events:

```typescript
function ToolExecutionCard({ toolCall }: { toolCall: ToolCallEvent }) {
  switch (toolCall.name) {
    case "bash":
    case "run-sandbox":
      return <TerminalToolCard toolCall={toolCall} />;  // Shows terminal output
    case "read":
      return <FileReadCard toolCall={toolCall} />;      // Shows file content
    case "write":
    case "edit":
      return <FileEditCard toolCall={toolCall} />;      // Shows diff
    case "grep":
    case "find":
      return <SearchResultCard toolCall={toolCall} />;  // Shows search results
    default:
      return <GenericToolCard toolCall={toolCall} />;    // JSON view
  }
}
```

### Run Pages

| Page | Current State | Changes Needed |
|------|--------------|----------------|
| `/ai` (home) | Prompt input with mock | Wire "Run Task" button to create workflow execution |
| `/ai/runs` | Mock run list | Fetch from `GET /workflow-executions?kind=agent` |
| `/ai/runs/new` | Mock chat adapter | Use `createFlovynChatAdapter` with real SSE |
| `/ai/runs/[runId]` | Mock historical view | Fetch messages from workflow state, replay events |
| `/ai/agents/*` | Mock data | Keep mock for now (agent definitions are a non-goal) |
| `/ai/workflows/*` | Mock data | Keep mock for now (workflows are a non-goal) |
| `/ai/tools/*` | Mock data | Keep mock for now (tools marketplace is a non-goal) |

## Changes by Component

### agent-server

| Change | Effort | Description |
|--------|--------|-------------|
| Add `ReadFileTask` | Small | Read file, path validation, line limiting |
| Add `WriteFileTask` | Small | Write file, path validation, create parent dirs |
| Add `EditFileTask` | Small | Find-and-replace with uniqueness check |
| Add `BashTask` | Medium | Shell spawn, stdout/stderr streaming, timeout, cleanup |
| Add `GrepTask` | Small | Regex search via `grep` crate or subprocess |
| Add `FindTask` | Small | Glob matching via `globwalk` crate or subprocess |
| Add `working_directory` to input | Small | Pass to all host tools, validate exists |
| Register new tools in tool registry | Small | JSON schemas + tool registry entries |
| Register new tasks in main.rs | Small | FlovynClient builder |
| Stream `tool_call_start` / `tool_call_end` | Medium | Emit structured events from AgentWorkflow before/after each tool |
| Emit `artifact` events | Small | After write/edit tool completion, stream artifact event with file path and type |
| Add MVP models to registry | Small | Register GLM 4.7, Kimi K2 Thinking, Deepseek 3.2 in model registry (OpenRouter-compatible) |

### flovyn-server

| Change | Effort | Description |
|--------|--------|-------------|
| (none expected) | - | Existing workflow execution, SSE, signal, and state APIs should work as-is. |
| Verify consolidated SSE includes task tokens | Small | Test that `stream_token`/`stream_data_value` from tasks appear in consolidated stream. |

### flovyn-app

| Change | Effort | Description |
|--------|--------|-------------|
| `flovyn-chat-adapter.ts` | Medium | Real chat adapter replacing mock. Creates executions, subscribes SSE, sends signals. |
| Wire "New Run" page | Small | Connect prompt input → adapter → navigate to run view |
| Wire run list page | Small | Fetch `GET /workflow-executions?kind=agent`, display with existing UI |
| Wire run detail page | Small | Load messages from workflow state for historical view |
| Generic tool execution cards | Medium | Replace hardcoded tool UI with event-driven rendering |
| Terminal view for bash/sandbox | Small | Connect existing `terminal-view.tsx` to real terminal stream events |
| Model/config selector | Small | Dropdown with GLM 4.7, Kimi K2 Thinking, Deepseek 3.2. Thinking level toggle. |
| Status indicator | Small | Show "running" / "waiting for input" / "completed" from workflow state |
| Artifact panel | Medium | Wire workspace panel to display file artifacts from `tool_call_end` events (write/edit). Persistent storage via host filesystem path references. |
| Concurrent session UI | Small | Session list shows all active sessions. Indicator for other live sessions when viewing one. |
| System prompt editor | Small | Expandable field in run creation UI. Default coding-assistant prompt, user can override. |

### sdk-rust

| Change | Effort | Description |
|--------|--------|-------------|
| (none expected) | - | The worker SDK already supports everything needed. |

## Implementation Phases

### Phase 1: End-to-End Wiring (get text streaming working)

1. **agent-server**: Verify the existing `run-sandbox` tool works end-to-end with flovyn-server. Test: start a workflow execution via REST, verify tokens appear on SSE consolidated stream.
2. **flovyn-app**: Build `flovyn-chat-adapter.ts` with just text streaming (no tool rendering yet). Wire the "New Run" page to create a real workflow execution and display streamed text.
3. **Result**: User types prompt → sees LLM response streaming in real-time.

### Phase 2: Host Tools

4. **agent-server**: Implement `ReadFileTask`, `WriteFileTask`, `EditFileTask`, `BashTask`, `GrepTask`, `FindTask`. Add `working_directory` to input.
5. **agent-server**: Emit `tool_call_start` and `tool_call_end` structured events from `AgentWorkflow` (not just from the LLM stream).
6. **agent-server**: Register all new tools in the tool registry and main.rs.
7. **Result**: Agent can read/write files and run commands on the host OS.

### Phase 3: Tool Execution UI

8. **flovyn-app**: Parse `tool_call_start` / `tool_call_end` events in the chat adapter.
9. **flovyn-app**: Build generic tool execution cards (terminal, file read, file edit, search results).
10. **flovyn-app**: Connect terminal view to real `terminal` stream events.
11. **Result**: User sees each tool execution rendered inline in the chat.

### Phase 4: Follow-ups and Session Management

12. **flovyn-app**: Wire the message composer to send signals when status is `waiting_for_input`.
13. **flovyn-app**: Wire the run list page to fetch real workflow executions.
14. **flovyn-app**: Wire the run detail page to load conversation history from workflow state.
15. **flovyn-app**: Add cancel button wired to the cancel endpoint.
16. **Result**: Full interactive multi-turn sessions with history.

## Patterns Borrowed from pi-mono

The [pi-mono coding-agent](/Users/manhha/Developer/manhha/ediyn/pi-mono/packages) provides proven patterns we adopt:

| Pattern | pi-mono Implementation | Our Adaptation |
|---------|----------------------|----------------|
| **Core tool set** | 7 tools: read, bash, edit, write, grep, find, ls | Same set (minus ls, plus run-sandbox). These are the minimum viable tools for a coding agent. |
| **Streaming tool output** | Bash streams stdout/stderr in real-time | BashTask and RunSandboxTask stream terminal events via Flovyn SDK |
| **Steering** | Interrupt agent during tool execution with user message | Already implemented in agent-server via signal checking between tool calls |
| **Session = conversation loop** | Infinite loop waiting for user input, inner loop for LLM+tools | Same pattern: AgentWorkflow outer loop waits for signals, inner loop executes turns |
| **Path-scoped operations** | Tools resolve paths relative to `cwd` | `working_directory` field in AgentWorkflowInput, tools validate path containment |
| **Tool operations abstraction** | Pluggable `Operations` interface per tool (local, SSH, sandbox) | TaskDefinition per tool. Can swap implementations later (e.g., SSH-based for remote). |

### Patterns deferred (not for MVP)

| Pattern | Why Deferred |
|---------|-------------|
| **Compaction** (summarize old messages to fit context) | Durable workflow persists full history. Compaction needed only for very long sessions. |
| **Branching/forking** (explore alternative paths) | Linear conversation is sufficient for MVP. |
| **Extension system** (user-provided tools, hooks, commands) | Adds significant complexity. Can add post-MVP. |
| **RPC mode** (headless control via JSON protocol) | Only relevant if we build IDE integrations. |
| **Sub-agents** (delegate to specialized agents) | Composability is a future feature. |

## Decisions

1. **System prompt**: Default coding-assistant system prompt, user can override via an expandable "System Prompt" field in the run creation UI.

2. **Model selection**: Curated short list in the UI for MVP. Models:
   - GLM 4.7
   - Kimi K2 Thinking
   - Deepseek 3.2

   Agent-server's model registry and OpenRouter provider already support these via compatible endpoints. The UI presents a dropdown; the selected model maps to `{ provider, modelId }` in the workflow input.

3. **File artifact rendering**: Yes — when the agent writes a file via `write` or `edit`, it appears as an artifact in the workspace panel. The artifact system needs a **storage abstraction** with future modes in mind:
   - **Persistent** (MVP) — files written to the host working directory, referenced by path
   - **Ephemeral** — temporary files that disappear after the session (future)
   - **Workspace** — files in a session-scoped workspace (future)
   - **Shareable** — files that can be shared/exported (future)

   For MVP, artifacts are simply references to files on the host filesystem (path + type). The `tool_call_end` event for `write`/`edit` tools includes the file path, which the UI uses to create artifact cards. No separate artifact storage — the host filesystem is the source of truth.

4. **Authentication**: Current model is sufficient. Agent-server authenticates as a worker via `FLOVYN_WORKER_TOKEN`. User identity flows through the workflow execution's org context. No per-user API keys needed for MVP.

5. **Concurrent sessions**: Yes, supported. Each session is an independent workflow execution. The UI needs:
   - A **session list** showing all active + recent sessions (already planned in the runs page)
   - A **session switcher** or indicator when viewing a specific session, showing other live sessions
   - The ability to open multiple sessions and switch between them

## References

- [UI Migration Design](/Users/manhha/Developer/manhha/flovyn/dev/docs/design/20260207_migrate_ai_ui_to_flovyn_app.md) — PoC route structure, component migration, layout integration
- [UX Rationale](/Users/manhha/Developer/manhha/flovyn/flovyn-ai/.local/idea.txt) — Original product vision: composable primitives, evolution model, Manus-style execution
- [agent-server README](/Users/manhha/Developer/manhha/flovyn/agent-server/README.md) — Durable agent architecture, LLM providers, streaming, tools
- [pi-mono coding-agent](/Users/manhha/Developer/manhha/ediyn/pi-mono/packages) — Inspiration: tool system, session management, streaming, steering
- [flovyn-server CLAUDE.md](/Users/manhha/Developer/manhha/flovyn/flovyn-server/CLAUDE.md) — Server API, gRPC services, auth, database schema
- [flovyn-app CLAUDE.md](/Users/manhha/Developer/manhha/flovyn/flovyn-app/CLAUDE.md) — App architecture, streaming hooks, AI components
