# Async Agents: A Formalized Definition for Agentic Execution Platforms

## 1. Core Definition

An **async agent** is an autonomous computational entity that:

1. **Accepts a goal or task specification** from a caller (human or system),
2. **Returns control immediately** to the caller via a durable handle (task ID, interaction ID, continuation token),
3. **Executes autonomously** through a multi-step reasoning and action loop,
4. **Persists state independently** of the caller's session or connection, and
5. **Communicates results and status** through a non-blocking interface (polling, webhooks, notifications, or event streams).

The defining property is **caller non-blocking**: the caller's process is never suspended waiting for the agent's completion. This distinguishes async agents from synchronous agents (where the caller blocks until completion) and from simple background jobs (which lack autonomous reasoning and replanning).

---

## 2. Formal Properties (Axioms)

Any system claiming to be an async agent platform MUST satisfy these properties:

### P1 — Non-Blocking Invocation
```
invoke(task_spec) → handle  // returns immediately
```
The caller receives a durable reference (handle) without waiting for task completion. The handle is sufficient to later retrieve status, results, or cancel the task.

### P2 — Execution Independence
The agent's execution is **decoupled** from the caller's lifecycle. The caller may:
- Disconnect, sleep, or terminate,
- Resume from a different session, device, or process,
- Never reconnect (the agent still completes or times out gracefully).

### P3 — Autonomous Reasoning Loop
The agent operates an internal loop of **plan → act → observe → replan**. This is what distinguishes an async *agent* from an async *job*. The agent:
- Makes decisions based on intermediate results,
- Selects and composes tools dynamically,
- Adapts when the environment deviates from expectations.

### P4 — Durable State
The agent's execution state survives:
- Network disconnections,
- Caller session expiry,
- Transient infrastructure failures (crash recovery).

State is persisted to a durable store, not held only in memory or on a single connection.

### P5 — Observable Lifecycle
The agent exposes a well-defined lifecycle that the caller (or a supervisor) can observe without interrupting execution.

### P6 — Bounded Execution
The agent has explicit termination conditions:
- Completion (goal achieved),
- Failure (unrecoverable error),
- Timeout (TTL expiry),
- Cancellation (caller or supervisor intervention),
- Escalation (agent determines it needs human input).

---

## 3. Lifecycle State Machine

Derived from convergent patterns across MCP Tasks, OpenAI Background Mode, Google Interactions API, and Microsoft Agent Framework:

```
                    ┌─────────────────────────────────┐
                    │                                 │
                    ▼                                 │
┌──────────┐  ┌──────────┐  ┌───────────────┐  ┌─────┴─────┐
│ SUBMITTED│─▶│ WORKING  │─▶│   COMPLETED   │  │ CANCELLED │
└──────────┘  └────┬─────┘  └───────────────┘  └───────────┘
                   │    ▲                            ▲
                   │    │                            │
                   ▼    │                            │
              ┌─────────┴────┐                       │
              │INPUT_REQUIRED│───────────────────────┘
              └─────────┬────┘      (if no response
                   │    ▲            within timeout)
                   │    │
                   ▼    │
              (caller provides input)
                        │
                   ┌────┴─────┐
                   │  FAILED  │
                   └──────────┘
```

### State Definitions

| State | Description | Caller Action |
|-------|-------------|---------------|
| `SUBMITTED` | Task accepted, queued for execution | Poll or subscribe |
| `WORKING` | Agent is actively reasoning/acting | Poll for progress; optionally stream logs |
| `INPUT_REQUIRED` | Agent is blocked and needs caller input | Provide input or cancel |
| `COMPLETED` | Goal achieved; results available | Retrieve results |
| `FAILED` | Unrecoverable error; partial results may exist | Inspect error; retry or abandon |
| `CANCELLED` | Terminated by caller or supervisor | Acknowledge; clean up |

### Transitions

- `SUBMITTED → WORKING`: Agent begins execution.
- `WORKING → WORKING`: Agent completes a step and begins the next (internal loop). Progress metadata (step count, percentage, status message) MAY be emitted.
- `WORKING → INPUT_REQUIRED`: Agent encounters an ambiguity, permission gate, or missing information it cannot resolve autonomously.
- `INPUT_REQUIRED → WORKING`: Caller provides the requested input; agent resumes.
- `INPUT_REQUIRED → CANCELLED`: Input not provided within TTL; agent terminates.
- `WORKING → COMPLETED`: Goal achieved.
- `WORKING → FAILED`: Unrecoverable error after retry/fallback exhaustion.
- `ANY → CANCELLED`: Caller or supervisor issues a cancel signal.

---

## 4. Architectural Components

Based on the common architecture across production systems:

```
┌─────────────────────────────────────────────────────────┐
│                    CALLER (Human / System)               │
│  invoke() ──▶ handle    poll(handle) ──▶ status/result  │
└──────┬──────────────────────────┬────────────────────────┘
       │                          │
       ▼                          ▼
┌──────────────────────────────────────────────────────────┐
│                     API GATEWAY                          │
│  • Accepts task specs           • Serves status/results  │
│  • Returns handles immediately  • Manages webhooks/SSE   │
│  • Validates input              • Rate limiting          │
└──────┬──────────────────────────┬────────────────────────┘
       │                          │
       ▼                          ▼
┌──────────────┐          ┌───────────────┐
│  TASK QUEUE  │          │  STATE STORE  │
│  (durable)   │◀────────▶│  (durable)    │
└──────┬───────┘          └───────┬───────┘
       │                          │
       ▼                          ▼
┌──────────────────────────────────────────────────────────┐
│                    AGENT WORKER POOL                      │
│  ┌────────────────────────────────────┐                  │
│  │         AGENT RUNTIME              │                  │
│  │  ┌──────┐  ┌─────┐  ┌──────────┐  │                  │
│  │  │Planner│─▶│Actor│─▶│Observer  │  │                  │
│  │  └───▲──┘  └──┬──┘  └────┬─────┘  │                  │
│  │      │        │          │         │                  │
│  │      └────────┴──────────┘         │                  │
│  │         (reason-act-observe)       │                  │
│  │                                    │                  │
│  │  ┌─────────┐  ┌──────────────┐    │                  │
│  │  │ Toolbox │  │  Sandbox/Env │    │                  │
│  │  └─────────┘  └──────────────┘    │                  │
│  └────────────────────────────────────┘                  │
│                                                          │
│  ┌────────────────────────────────────┐                  │
│  │       SUPERVISION LAYER            │                  │
│  │  • Policy guardrails               │                  │
│  │  • Timeout enforcement             │                  │
│  │  • Escalation routing              │                  │
│  │  • Audit logging                   │                  │
│  └────────────────────────────────────┘                  │
└──────────────────────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────────────────┐
│                 NOTIFICATION LAYER                        │
│  • Webhooks       • Slack/Email      • SSE/WebSocket     │
│  • Push notifications                • Event bus         │
└──────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility |
|-----------|---------------|
| **API Gateway** | Accept task submissions, return handles, serve status. Stateless and horizontally scalable. |
| **Task Queue** | Durable, ordered delivery of task specs to workers. Survives restarts. |
| **State Store** | Persist task execution state (status, progress, intermediate results, audit log). Source of truth for lifecycle. |
| **Agent Runtime** | The autonomous reasoning loop. Contains the planner, actor (tool executor), and observer (result evaluator). |
| **Toolbox** | Registry of available tools/capabilities. Dynamic selection and composition by the agent. |
| **Sandbox** | Isolated execution environment (container, VM, or cloud sandbox). Prevents side-effects leaking across tasks. |
| **Supervision Layer** | Policy enforcement, timeout management, escalation routing, anomaly detection. The "adult in the room." |
| **Notification Layer** | Async delivery of status changes, completion events, and escalation requests to callers and observers. |

---

## 5. Taxonomy of Async Agent Patterns

The systems studied reveal three distinct patterns of increasing autonomy:

### Level 1 — Fire-and-Forget Task Agent
**Examples**: OpenAI Background Mode, basic MCP Tasks

The caller submits a well-defined task. The agent executes it without further interaction. Results are retrieved via polling.

```
Caller: "Summarize this 500-page PDF" → handle
Agent: [works for 5 minutes]
Caller: poll(handle) → {status: "completed", result: "..."}
```

**Characteristics**:
- No mid-task interaction.
- Agent has no mechanism to ask for clarification.
- Bounded, predictable execution time.
- Closest to a "smart background job."

### Level 2 — Supervised Autonomous Agent
**Examples**: Gemini Deep Research, OpenAI Codex, Devin

The caller submits a goal. The agent plans and executes autonomously but CAN pause to request input, emit progress, or escalate.

```
Caller: "Research competitor landscape and write a report" → handle
Agent: [creates plan, shows plan to caller]
Caller: [approves/edits plan]
Agent: [executes for 10 minutes, browsing 200+ pages]
Agent: → notification("Research complete, report ready")
Caller: retrieve(handle) → {report: "..."}
```

**Characteristics**:
- Agent may transition to `INPUT_REQUIRED`.
- Progress is observable (thinking summaries, step counts).
- Caller can intervene mid-task but doesn't have to.
- Plans are often presented for approval before execution.

### Level 3 — Persistent Daemon Agent
**Examples**: Event-driven enterprise agents, monitoring agents, some Devin workflows

The agent runs indefinitely, monitoring for conditions and acting proactively. It is not invoked per-task but per-mission.

```
Caller: "Monitor our CI pipeline. When builds fail, diagnose the issue,
         attempt a fix, and open a PR. Notify me on Slack."
Agent: [runs continuously]
Agent: → slack("Build #4521 failed. Root cause: type error in auth.ts.
              Fix PR opened: #892")
```

**Characteristics**:
- No single completion event; the agent's lifecycle is unbounded.
- Triggered by external events, not caller prompts.
- Requires robust stop conditions, risk triggers, and resource budgets.
- Most closely matches the HN commenter's "daemon process" concept.

---

## 6. Interface Contract (API Surface)

A minimal API surface for an async agent platform, synthesized from OpenAI, Google, MCP, and Microsoft patterns:

### Task Submission
```
POST /tasks
{
  "agent": "code-reviewer",         // agent type or ID
  "input": { ... },                 // task specification
  "config": {
    "ttl": 3600000,                 // max execution time (ms)
    "notify": ["webhook", "slack"], // notification channels
    "sandbox": "isolated",          // execution environment
    "approval_required": true       // require plan approval
  }
}

→ 202 Accepted
{
  "task_id": "task_abc123",
  "status": "submitted",
  "created_at": "2026-02-12T10:00:00Z",
  "poll_interval": 5000
}
```

### Status Polling
```
GET /tasks/{task_id}

→ 200 OK
{
  "task_id": "task_abc123",
  "status": "working",
  "progress": {
    "step": 3,
    "total_steps": 7,
    "message": "Analyzing test coverage..."
  },
  "started_at": "2026-02-12T10:00:01Z",
  "updated_at": "2026-02-12T10:02:15Z"
}
```

### Input Provision (when agent requests it)
```
POST /tasks/{task_id}/input
{
  "response_to": "clarification_req_001",
  "input": {
    "approved": true,
    "notes": "Proceed with option B"
  }
}
```

### Result Retrieval
```
GET /tasks/{task_id}/result

→ 200 OK
{
  "task_id": "task_abc123",
  "status": "completed",
  "output": { ... },
  "artifacts": [
    {"type": "pull_request", "url": "https://..."},
    {"type": "report", "content": "..."}
  ],
  "audit_log": [ ... ],
  "usage": {
    "duration_ms": 134000,
    "llm_calls": 23,
    "tool_invocations": 15,
    "tokens_consumed": 85400
  }
}
```

### Cancellation
```
POST /tasks/{task_id}/cancel
{
  "reason": "No longer needed"
}
```

### Event Stream (optional, for real-time observation)
```
GET /tasks/{task_id}/events
Accept: text/event-stream

data: {"type": "step_started", "step": 4, "description": "Running tests"}
data: {"type": "tool_called", "tool": "bash", "args": "npm test"}
data: {"type": "progress", "message": "12/45 tests passing"}
data: {"type": "step_completed", "step": 4, "result": "tests_failed"}
data: {"type": "replanning", "reason": "3 test failures detected"}
```

---

## 7. Critical Design Considerations

### 7.1 Task Specification Quality

Async agents demand higher-quality task specifications than interactive agents. The caller cannot course-correct in real time. Systems should support:
- **Structured task schemas** (not just free-text prompts),
- **Acceptance criteria** (how the agent knows it succeeded),
- **Constraints and guardrails** (what the agent must NOT do),
- **Context bundles** (relevant files, history, environment info).

### 7.2 Supervision and Safety

| Concern | Mechanism |
|---------|-----------|
| Runaway execution | TTL, step limits, token budgets |
| Unsafe actions | Policy engine with allow/deny lists |
| Scope creep | Task boundary enforcement |
| Resource exhaustion | Compute/cost budgets per task |
| Unintended side-effects | Sandboxed execution; dry-run mode |
| Audit and compliance | Immutable execution logs |

### 7.3 Failure Modes Unique to Async Agents

- **Stale context**: The world changed while the agent was working. Results may be based on outdated assumptions.
- **Orphaned tasks**: Caller never retrieves results. Tasks must auto-expire.
- **Zombie loops**: Agent is "working" but stuck in an unproductive cycle. Requires loop detection and circuit breakers.
- **Partial completion**: Agent made real changes (opened PRs, sent emails) before failing. Rollback may be impossible.
- **Escalation storms**: Agent repeatedly requests input on trivial decisions. Requires escalation budgets.

### 7.4 Observability

Async agents are harder to debug than synchronous ones because the caller isn't watching. Essential observability:
- **Execution traces**: Full record of plan → act → observe → replan cycles.
- **Decision logs**: Why the agent chose tool X over tool Y.
- **Thinking summaries**: Human-readable reasoning at each step (as in Google's Deep Research and OpenAI's reasoning summaries).
- **Cost tracking**: Token usage, API calls, wall-clock time per step.
- **Replay capability**: Ability to re-run a task from a checkpoint with modified inputs.

---

## 8. Differentiation from Related Concepts

| Concept | How It Differs from Async Agent |
|---------|-------------------------------|
| **Background job** | No autonomous reasoning. Executes a fixed procedure. Cannot replan. |
| **Workflow engine** | Pre-defined DAG of steps. No dynamic tool selection or replanning. |
| **Synchronous agent** | Caller blocks until completion. Cannot disconnect. |
| **Chatbot** | Reactive (responds to each message). No persistent goal pursuit. |
| **Copilot** | Suggests actions for human approval at each step. Human drives the loop. |
| **Cron job / scheduler** | Time-triggered, not goal-driven. No reasoning. |
| **Microservice** | Stateless request-response. No multi-step planning. |

---

## 9. Reference Implementations

| System | Level | Key Async Mechanism | Notable Design Choice |
|--------|-------|--------------------|-----------------------|
| MCP Tasks (2025-11-25) | Protocol | `task` field in any request; `taskId` + polling | Protocol-level; any MCP server can opt in |
| OpenAI Background Mode | L1-L2 | `background: true`; poll response object | Streams can be resumed after disconnect |
| OpenAI Codex | L2 | Cloud sandbox per task; PR as artifact | Each task gets its own isolated environment |
| Gemini Deep Research | L2 | `background=True` in Interactions API | Async task manager with shared planner/executor state |
| Devin (Cognition) | L2-L3 | Slack-native interface; GitHub PRs | Sync/Async hybrid with Windsurf IDE |
| Cursor Background Agents | L2 | Background execution in IDE | Blurs desktop/cloud boundary |
| AG2/AutoGen | L2 | Event-driven async messaging between agents | Multi-agent conversation as the execution model |
| Azure Agent Framework | L1-L2 | 202 Accepted + continuation token + Cosmos DB | Enterprise durable state with Service Bus |

---

## 10. Summary: The Minimum Viable Async Agent

To build an async agent platform, you need at minimum:

1. **Non-blocking invocation** that returns a handle.
2. **Durable state store** that survives disconnects and crashes.
3. **An autonomous reasoning loop** (plan-act-observe-replan), not just a script.
4. **A lifecycle state machine** with at least: submitted, working, completed, failed, cancelled.
5. **An observation interface** (polling at minimum; streaming and webhooks recommended).
6. **Bounded execution** (TTL, step limits, cost caps).
7. **A notification mechanism** to reach the caller when the agent finishes or needs help.

Everything else — sandboxing, multi-agent orchestration, mid-task interaction, sophisticated guardrails — is a matter of maturity level and use case, but the seven properties above are the non-negotiable foundation.
