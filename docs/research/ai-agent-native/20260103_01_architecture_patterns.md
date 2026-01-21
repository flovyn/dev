# Architecture Patterns

## 1.1 Agent Loop Structure

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

## 1.2 Tool System Architecture

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

## 1.3 State Management Patterns

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

## Source Code References

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
