# Content Storage Strategy

## Industry Landscape: Critical Analysis

Before designing Flovyn's approach, let's examine what exists and their limitations.

### Tracing-Based Tools (Langfuse, Phoenix, LangSmith)

**What they do well:**
- Low-friction instrumentation (`@observe()` decorator, `auto_instrument=True`)
- OpenTelemetry compatibility
- Good UIs for trace visualization
- Cost/token tracking

**What they get wrong:**

| Problem | Why It Matters |
|---------|----------------|
| **Tracing ≠ State reconstruction** | You can see what happened, but can't reconstruct exact agent state at step N |
| **External dependency** | Data lives in their cloud. Outage = no debugging. Vendor lock-in. |
| **No durability** | If agent fails, you see the failure. You can't resume from checkpoint. |
| **"Why" is afterthought** | Captures inputs/outputs, not reasoning. Attribution is manual tagging. |
| **Large payloads bloat traces** | Tool results (file contents, search results) make traces huge and slow |

```
Langfuse trace:
  span: "llm_call" { input: "...", output: "...", tokens: 5000 }
  span: "tool_call" { tool: "read_file", result: "[500 lines of code]" }

Problem: The 500 lines are stored IN the span.
Query 100 traces = load 50,000 lines of code you don't need.
```

### Agent-Managed Memory (Letta/MemGPT)

**What they do well:**
- Agent controls its own memory (self-editing)
- Hierarchical memory (core/archival like RAM/disk)
- Persistent across sessions

**What they get wrong:**

| Problem | Why It Matters |
|---------|----------------|
| **LLM must learn memory tools** | Agent wastes tokens deciding when/what to memorize |
| **Inconsistent memory behavior** | LLM might "forget" to save important context |
| **Memory ops can fail** | What if `archival_memory_insert` fails mid-conversation? |
| **Developer loses control** | Can't guarantee what gets stored |
| **Not workflow-native** | Memory is agent-centric, not workflow-centric. Hard to integrate with broader orchestration. |

```python
# Letta approach - agent explicitly manages memory
agent.memory_replace("user_preference", "likes dark mode")  # LLM decides to call this
agent.archival_memory_insert("important fact")              # Or forgets to

# Problem: What if LLM doesn't call memory_insert for something important?
# Problem: Extra LLM calls just to manage memory
```

### AgentOps / Cognitive State Tracing

**What they do well:**
- Recognizes the "why" problem (cognitive state traceability)
- Session replay
- Failure detection

**What they get wrong:**

| Problem | Why It Matters |
|---------|----------------|
| **"Cognitive state" is aspirational** | They identify the need but don't solve it |
| **Still fundamentally tracing** | Better metadata, but same limitations |
| **External service** | Same vendor lock-in issues |
| **No standard for reasoning capture** | Each integration is custom |

### OpenTelemetry / OpenInference

**What they do well:**
- Industry standard semantic conventions
- Vendor-agnostic
- Broad ecosystem support

**What they get wrong:**

| Problem | Why It Matters |
|---------|----------------|
| **Designed for request tracing, not agent state** | Spans are ephemeral observations, not reconstructable state |
| **No content deduplication** | Same system prompt in 1000 traces = stored 1000 times |
| **Large payloads in spans** | Not designed for 50KB tool results |
| **No durability model** | Traces are logs, not checkpoints |

### Why Don't They Solve These Problems?

For each gap, let's ask: is it hard, or did they not think about it?

**1. State Reconstruction (Tracing vs Event Sourcing)**

| Reason | Analysis |
|--------|----------|
| **Origin story** | OpenTelemetry came from distributed request tracing (Dapper, Zipkin). Goal: "follow a request across services". Not: "rebuild state at any point". |
| **Hard to retrofit** | Event sourcing requires designing for it from the start. Adding it to a tracing system means rearchitecting storage, query patterns, and replay logic. |
| **Different customers** | Tracing tools serve DevOps/SRE. Event sourcing serves developers building stateful systems. Different buyer, different product. |

**Verdict:** Mostly architectural origin. They started as observers, not executors. Hard to change now.

**2. Content vs Metadata Separation**

| Reason | Analysis |
|--------|----------|
| **Timing** | Most LLM observability tools started in GPT-3 era (2020-2022). Prompts were small. 100 tokens, not 100,000. |
| **Grew organically** | As context windows grew (4K → 32K → 200K), they kept the same architecture. Spans got bigger. Performance got worse. |
| **Content-addressed storage is infrastructure** | It's not a feature you add easily. It's a fundamental storage pattern. Requires new tables, dedup logic, reference tracking. |

**Verdict:** Didn't anticipate. Now it's a boiling frog problem - each model release makes it worse, but no single release forces a rewrite.

**3. Reasoning as First-Class**

| Reason | Analysis |
|--------|----------|
| **New capability** | Extended thinking (Claude's thinking blocks) is recent. OpenAI's chain-of-thought is internal. Most tools predated this. |
| **Token cost resistance** | Enabling thinking blocks costs 10-20% more tokens. Users push back. Tools make it optional, then nobody uses it. |
| **No standard** | Each LLM has different reasoning output format. Claude: `thinking` block. OpenAI: (internal). Others: custom. Hard to normalize. |

**Verdict:** Combination. The capability is new, and there's user resistance to the cost. Tools follow users, not lead them.

**4. Workflow Integration**

| Reason | Analysis |
|--------|----------|
| **Company focus** | Langfuse is an observability company. Temporal is a workflow company. Neither does both well. |
| **Integration is hard** | Connecting two systems (workflow engine + observability) requires mapping data models, syncing state, handling failures in both. |
| **Business incentive** | Each tool wants to be the "single pane of glass". Integrating deeply with another reduces their value proposition. |

**Verdict:** Business/organizational, not technical. Everyone wants to own the whole stack but builds only part of it.

**5. Durability / Checkpoint Resume**

| Reason | Analysis |
|--------|----------|
| **Observers can't act** | Observability tools are passive. They watch execution; they don't control it. You can't resume what you don't run. |
| **Stateless assumption** | LLM apps were assumed stateless (API call in, response out). Long-running agents broke this assumption. |
| **Workflow engines don't understand AI** | Temporal, Inngest can checkpoint. But they don't know what "LLM context" or "thinking block" means. |

**Verdict:** Architectural separation. Tools that observe can't resume. Tools that execute don't understand AI semantics.

### Why Flovyn Can Do This

```
┌─────────────────────────────────────────────────────────────┐
│                  FLOVYN'S POSITION                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│ 1. Started as workflow engine                               │
│    → Event sourcing is native, not bolted on                │
│    → State reconstruction is what we already do             │
│                                                             │
│ 2. Adding AI support now (not retrofitting)                 │
│    → Can design content separation from day one             │
│    → Can make reasoning first-class in data model           │
│                                                             │
│ 3. Owns execution                                           │
│    → Not an observer, an executor                           │
│    → Can checkpoint and resume                              │
│    → Can intercept LLM calls and store reasoning            │
│                                                             │
│ 4. Single system                                            │
│    → No integration between workflow and observability      │
│    → Same DB, same events, same API                         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### What We Learn From Them

Despite their gaps, they got some things right:

| Tool | What to Adopt | What to Avoid |
|------|---------------|---------------|
| **Langfuse** | Decorator-style low-friction instrumentation | External storage dependency |
| **Phoenix** | OpenTelemetry semantic conventions (for interop) | Spans-for-everything data model |
| **Letta** | Hierarchical memory concept (core/archival) | LLM-managed memory (unreliable) |
| **AgentOps** | Cognitive state as explicit concept | Aspirational without implementation |
| **OpenTelemetry** | Standardized attribute names | Large payloads in spans |

### Flovyn's Design Principles

Based on this analysis:

```
1. EVENT SOURCING FIRST
   Don't add tracing. Extend event sourcing.
   Every agent action is an event that can rebuild state.

2. CONTENT SEPARATION BY DEFAULT
   Events store metadata + refs.
   Large content (responses, tool results) in content store.
   No configuration needed - it's the architecture.

3. REASONING IS MANDATORY DATA
   Thinking blocks stored by default (opt-out, not opt-in).
   Accept the token cost as investment in debuggability.
   This is Flovyn's opinionated stance.

4. SYSTEM-MANAGED, NOT AGENT-MANAGED
   Developer doesn't call memory APIs.
   System captures everything automatically.
   Agent is stateless; workflow is stateful.

5. ONE SYSTEM
   Execution + storage + debugging in same platform.
   No external dependencies for core functionality.
```

---

## Flovyn's Approach: Event Sourcing + Content Store

Flovyn's unique position: **workflow engine with event sourcing**. We don't need to bolt on tracing. We need to extend what we have.

### Key Insight

```
Tracing tools:     "Record what happened for later viewing"
Event sourcing:    "Record what happened to reconstruct state"

Same data, different purpose.
Flovyn already does the latter. We just need to:
1. Extend events for agent-specific data
2. Separate large content from event metadata
3. Make reasoning capture automatic
```

---

## Current Flovyn Implementation

**Events store all data inline:**

```rust
// domain/workflow_event.rs:139
pub event_data: Option<Vec<u8>>,  // All content inline as BYTEA
```

```sql
-- migrations/20251214220815_init.sql:66-75
CREATE TABLE workflow_event (
    event_data BYTEA,  -- No separation between metadata and content
);
```

```rust
// repository/event_repository.rs:129-145
// Loads ALL events with FULL event_data - no lazy loading
pub async fn get_events(&self, workflow_execution_id: Uuid) -> Result<Vec<WorkflowEvent>> {
    sqlx::query_as::<_, WorkflowEvent>(
        "SELECT id, ..., event_data, ... FROM workflow_event WHERE workflow_execution_id = $1"
    )
    .fetch_all(&self.pool)
    .await
}
```

**This works fine for current use cases** (small workflow events), but will become a problem for AI agents with large LLM context.

---

## The Dual Problem

AI agents face two related challenges that Flovyn must address:

```
┌─────────────────────────────────────────────────────────────┐
│  PROBLEM 1: LLM Context Window                              │
│  - Context grows unbounded (messages, tool results)         │
│  - LLM has fixed limit (8K-200K tokens)                     │
│  - Need compression/summarization                           │
├─────────────────────────────────────────────────────────────┤
│  PROBLEM 2: Event Replay Performance                        │
│  - Events store full conversation history                   │
│  - Large payloads = slow replay                             │
│  - Need efficient storage/retrieval                         │
└─────────────────────────────────────────────────────────────┘

         SAME DATA, DIFFERENT CONSTRAINTS
         ↓
         UNIFIED SOLUTION: Content-Addressed Store
```

## How AI Agents Handle Context

From the research, agents use these strategies:

| Strategy | When | What Happens |
|----------|------|--------------|
| **Full History** | Context < limit | All messages sent to LLM |
| **Compression** | Context ≈ 70% limit | Oldest messages summarized |
| **Checkpoint** | After compression | Summary stored as new "start" |
| **Reconstruction** | On resume | Checkpoint + recent messages |

**Gemini CLI example:**
```
Before compression:
[msg1][msg2][msg3][msg4][msg5][msg6][msg7][msg8][msg9][msg10]
 ←────────── 70% ──────────→←────── 30% ──────→

After compression:
[summary of msg1-7][msg8][msg9][msg10]
 ←─ checkpoint ─→←── recent history ──→
```

## Flovyn's Storage Challenge

**Without optimization:**
```
workflow_event table:
┌────────────────────────────────────────────────────┐
│ id=1: TurnStarted    {context: "..." 50KB}         │
│ id=2: ToolCalled     {args: "..." 10KB}            │
│ id=3: ToolCompleted  {result: "..." 30KB}          │
│ id=4: TurnCompleted  {response: "..." 20KB}        │
│ ... 100 events = 5-10MB per workflow               │
└────────────────────────────────────────────────────┘

Replay: SELECT * FROM workflow_event WHERE workflow_execution_id = ?
        → Loads 5-10MB, most of it unused for state reconstruction
```

## Unified Solution: Content-Addressed Store

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     workflow_event (existing)                │
│                 + content_ref column (new)                   │
├─────────────────────────────────────────────────────────────┤
│ id | workflow_execution_id | sequence_number | event_type   │
│    | event_data (small)    | content_ref     | created_at   │
├─────────────────────────────────────────────────────────────┤
│ 1  | wf-123 | 1 | TASK_SCHEDULED  | {small...} | NULL       │
│ 2  | wf-123 | 2 | TASK_COMPLETED  | NULL       | ref:abc123 │ ← large result
│ 3  | wf-123 | 3 | CONTEXT_COMPRESSED | NULL    | ref:xyz789 │ ← checkpoint
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                     content_store (new table)                │
├─────────────────────────────────────────────────────────────┤
│ id       | hash      | content_type | content        | size │
│ abc123   | sha:a1b2  | tool_result  | {data: [...]}  | 50KB │
│ xyz789   | sha:c3d4  | checkpoint   | <summary>      | 5KB  │
└─────────────────────────────────────────────────────────────┘
```

### How It Serves Both Needs

**1. Fast Event Replay (Flovyn's need):**
```rust
// Replay only loads small event data, skips large content
async fn replay_workflow(&self, workflow_execution_id: &Uuid) -> WorkflowState {
    let events = sqlx::query_as::<_, WorkflowEventMetadata>(
        "SELECT id, workflow_execution_id, sequence_number, event_type,
                content_ref, created_at
         FROM workflow_event
         WHERE workflow_execution_id = $1
         ORDER BY sequence_number"
    )
    .bind(workflow_execution_id)
    .fetch_all(&self.pool).await?;

    // Reconstruct state from event_type + small event_data
    // Large content NOT loaded - just references
    let mut state = WorkflowState::default();
    for event in events {
        state.apply(event);
    }
    state
}
```

**2. Context Reconstruction (Agent's need):**
```rust
// When agent needs to call LLM, load relevant content on-demand
async fn build_llm_context(&self, workflow_execution_id: &Uuid) -> Vec<Message> {
    let state = self.replay_workflow(workflow_execution_id).await?;

    // Find latest checkpoint (compression point)
    let checkpoint_ref = state.latest_checkpoint_ref();

    // Load checkpoint summary from content_store
    let summary = self.content_store.get(&checkpoint_ref).await?;

    // Load recent messages since checkpoint
    let recent_refs = state.messages_since_checkpoint();
    let recent = self.content_store.get_many(&recent_refs).await?;

    // Combine: [summary] + [recent messages]
    vec![Message::system(summary), ...recent]
}
```

**3. Context Compression (Shared operation):**
```rust
// When context too large, compress and checkpoint
async fn compress_context(&self, workflow_execution_id: &Uuid) -> Result<()> {
    let context = self.build_llm_context(workflow_execution_id).await?;
    let token_count = estimate_tokens(&context);

    if token_count < self.config.compression_threshold {
        return Ok(());  // No compression needed
    }

    // Split: oldest 70% to compress, keep 30%
    let (to_compress, to_keep) = split_at_user_boundary(&context, 0.7);

    // Generate summary via LLM
    let summary = self.llm.summarize(&to_compress).await?;

    // Store summary in content_store (returns UUID ref)
    let summary_ref = self.content_store.store(&summary).await?;

    // Emit checkpoint event - event_data is small JSON, large content in content_store
    let event_data = serde_json::to_vec(&json!({
        "tokens_before": token_count,
        "tokens_after": estimate_tokens(&summary) + estimate_tokens(&to_keep),
    }))?;

    self.event_repo.append_with_auto_sequence(
        *workflow_execution_id,
        EventType::ContextCompressed,  // New event type needed
        Some(event_data),
        Some(summary_ref),  // content_ref column
    ).await?;

    Ok(())
}
```

## Content Types and Storage Tiers

```rust
enum ContentType {
    // LLM-related (agent's context)
    SystemPrompt,      // Usually shared across runs → high dedup
    UserMessage,       // Unique per turn
    AssistantMessage,  // LLM response
    ToolArguments,     // Usually small
    ToolResult,        // Can be large (file contents, search results)
    ContextCheckpoint, // Compression summary

    // Workflow-related (Flovyn's state)
    WorkflowInput,
    WorkflowOutput,
    TaskPayload,
}

struct ContentRef {
    id: Uuid,
    hash: String,           // For deduplication
    content_type: ContentType,
    size_bytes: u32,
    token_estimate: Option<u32>,  // For LLM context tracking
    storage_tier: StorageTier,
}

enum StorageTier {
    Inline,       // < 1KB - stored in event itself
    Database,     // 1KB - 1MB - content_store table
    ObjectStore,  // > 1MB - S3/GCS (rare for LLM content)
}
```

## Deduplication Benefits

System prompts and common patterns are stored once:

```
Agent runs 1000 workflows with same system prompt (10KB):

WITHOUT dedup: 1000 × 10KB = 10MB stored
WITH dedup:    1 × 10KB + 1000 refs = ~10KB + ~50KB refs

Savings: 99.4%
```

```rust
impl ContentStore {
    async fn store(&self, content: &[u8], content_type: ContentType) -> ContentRef {
        let hash = sha256(content);

        // Check if already exists
        if let Some(existing) = self.find_by_hash(&hash).await? {
            return existing;  // Return existing ref, no storage
        }

        // New content - store it
        let id = Uuid::new_v4();
        let size = content.len() as u32;
        let tier = Self::select_tier(size);

        match tier {
            StorageTier::Inline => { /* stored in ref itself */ }
            StorageTier::Database => {
                sqlx::query!(
                    "INSERT INTO content_store (id, hash, content_type, content, size_bytes)
                     VALUES ($1, $2, $3, $4, $5)",
                    id, hash, content_type, content, size
                ).execute(&self.pool).await?;
            }
            StorageTier::ObjectStore => {
                self.s3.put_object(&id.to_string(), content).await?;
            }
        }

        ContentRef { id, hash, content_type, size_bytes: size, tier, .. }
    }
}
```

## Lifecycle and Cleanup

```rust
// Content lifecycle aligned with workflow lifecycle
struct ContentLifecycle {
    // Hot: Active workflows - all content available
    hot_retention: Duration,      // e.g., 7 days

    // Warm: Recent workflows - checkpoints + recent content
    warm_retention: Duration,     // e.g., 30 days

    // Cold: Old workflows - checkpoints only
    cold_retention: Duration,     // e.g., 1 year

    // Archive: Compliance - minimal metadata
    archive_retention: Duration,  // e.g., 7 years
}

impl ContentStore {
    async fn cleanup(&self, policy: &ContentLifecycle) -> Result<CleanupStats> {
        // Move old content to cheaper storage
        // Delete unreferenced content
        // Keep checkpoints longer (they're summaries)
    }
}
```

## Integration with Context Management Strategies

| Strategy (from research) | Content Store Role |
|--------------------------|-------------------|
| **Gemini: LLM compression** | Store summary as checkpoint content |
| **Temporal: continue-as-new** | Pass checkpoint ref to new workflow |
| **Dyad: raw SDK messages** | Store full SDK format in content store |
| **OpenManus: FIFO drop** | No storage needed for dropped messages |

### Example: Gemini-style Compression with Content Store

```rust
impl AgentWorkflow {
    async fn maybe_compress(&mut self) -> Result<()> {
        let token_count = self.context_token_count();

        if token_count < self.model_limit * 0.7 {
            return Ok(());
        }

        // 1. Load content for compression (on-demand)
        let messages = self.load_messages_for_compression().await?;

        // 2. Split at 70%
        let split = find_compress_split_point(&messages, 0.7);
        let to_compress = &messages[..split];
        let to_keep = &messages[split..];

        // 3. Generate summary
        let summary = self.llm.generate_summary(to_compress).await?;

        // 4. Store summary in content store (returns small ref)
        let summary_ref = self.content_store.store(
            &summary,
            ContentType::ContextCheckpoint
        ).await?;

        // 5. Store refs to kept messages
        let kept_refs: Vec<ContentRef> = to_keep.iter()
            .map(|m| m.content_ref.clone())
            .collect();

        // 6. Emit small event (just refs, no content)
        self.emit(AgentEvent::ContextCompressed {
            checkpoint_ref: summary_ref,
            preserved_refs: kept_refs,
            tokens_before: token_count,
            tokens_after: estimate_tokens(&summary) + estimate_tokens(to_keep),
        });

        // 7. Update working context (in memory)
        self.working_context = WorkingContext {
            checkpoint: Some(summary_ref),
            recent_messages: kept_refs,
        };

        Ok(())
    }
}
```

## Migration Path from Current Implementation

### Option A: Add Content Store (Backward Compatible)

Keep existing `event_data` column, add optional content references:

```sql
-- Migration: Add content store table
CREATE TABLE content_store (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    hash VARCHAR(64) NOT NULL,
    content_type VARCHAR(50) NOT NULL,
    content BYTEA NOT NULL,
    size_bytes INTEGER NOT NULL,
    token_estimate INTEGER,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_accessed_at TIMESTAMPTZ,
    UNIQUE (hash)
);

-- Add content_ref column to workflow_event (nullable for backward compat)
ALTER TABLE workflow_event ADD COLUMN content_ref UUID REFERENCES content_store(id);

-- Index for cleanup
CREATE INDEX idx_content_store_hash ON content_store(hash);
CREATE INDEX idx_content_store_created_at ON content_store(created_at);
```

**Changes to event_repository.rs:**

```rust
// Current: loads all data
pub async fn get_events(&self, id: Uuid) -> Result<Vec<WorkflowEvent>> {
    sqlx::query_as("SELECT * FROM workflow_event WHERE workflow_execution_id = $1")
        .fetch_all(&self.pool).await
}

// New: option to skip large content
pub async fn get_events_metadata(&self, id: Uuid) -> Result<Vec<WorkflowEventMetadata>> {
    sqlx::query_as(
        "SELECT id, workflow_execution_id, sequence_number, event_type,
                content_ref, created_at  -- Skip event_data
         FROM workflow_event WHERE workflow_execution_id = $1"
    )
    .fetch_all(&self.pool).await
}

// Load content on-demand
pub async fn get_content(&self, content_ref: Uuid) -> Result<Vec<u8>> {
    sqlx::query_scalar("SELECT content FROM content_store WHERE id = $1")
        .bind(content_ref)
        .fetch_one(&self.pool).await
}
```

### Option B: Threshold-Based Storage

Store small data inline, large data in content store:

```rust
const INLINE_THRESHOLD: usize = 4096;  // 4KB

impl EventRepository {
    pub async fn append_with_content(&self, event: &WorkflowEvent) -> Result<()> {
        let (event_data, content_ref) = match &event.event_data {
            Some(data) if data.len() > INLINE_THRESHOLD => {
                // Store in content_store, reference in event
                let ref_id = self.store_content(data).await?;
                (None, Some(ref_id))
            }
            data => (data.clone(), None),  // Keep inline
        };

        sqlx::query(
            "INSERT INTO workflow_event (..., event_data, content_ref) VALUES (...)"
        )
        .bind(&event_data)
        .bind(&content_ref)
        .execute(&self.pool).await
    }
}
```

### Option C: Lazy Loading via View

Create a view that excludes large data by default:

```sql
-- View for fast replay (metadata only)
CREATE VIEW workflow_event_metadata AS
SELECT id, workflow_execution_id, sequence_number, event_type,
       content_ref, created_at,
       CASE WHEN octet_length(event_data) > 4096 THEN NULL ELSE event_data END as event_data
FROM workflow_event;
```

## Developer Experience

The content store should be **invisible** to agent developers. They work with messages; the system handles storage.

### Current SDK Pattern (for reference)

```rust
// Current WorkflowContext - works with raw values
async fn execute(&self, ctx: &dyn WorkflowContext, input: DynamicInput) -> Result<DynamicOutput> {
    // Schedule task, get result
    let result = ctx.schedule_raw("my-task", json!({"foo": "bar"})).await?;

    // Store state
    ctx.set_raw("my-key", json!({"state": "value"})).await?;

    // Get state
    let state = ctx.get_raw("my-key").await?;

    Ok(output)
}
```

### Proposed Agent Context API

Agent developers should work with a higher-level API that handles context automatically:

```rust
// Agent workflow - context management is automatic
async fn execute(&self, ctx: &dyn AgentContext, input: AgentInput) -> Result<AgentOutput> {
    // Get conversation history (automatically loads from checkpoint + recent)
    let messages = ctx.messages().await?;

    // Add user message
    ctx.add_message(Role::User, "What files are in this directory?").await?;

    // Call LLM (context automatically prepared)
    let response = ctx.call_llm(&self.model_config).await?;

    // Add assistant response
    ctx.add_message(Role::Assistant, &response.content).await?;

    // Execute tool if needed
    if let Some(tool_call) = response.tool_call {
        let result = ctx.execute_tool(&tool_call).await?;
        ctx.add_tool_result(&tool_call.id, &result).await?;
    }

    // Context compression happens automatically when needed
    // Developer doesn't think about content_store, checkpoints, etc.

    Ok(AgentOutput { response })
}
```

### Key DX Principles

**1. Messages API (not raw bytes)**

```rust
// Developer sees this:
trait AgentContext {
    /// Add a message to the conversation
    async fn add_message(&self, role: Role, content: &str) -> Result<()>;

    /// Get conversation history (checkpoint + recent messages)
    async fn messages(&self) -> Result<Vec<Message>>;

    /// Get messages formatted for LLM API
    async fn llm_messages(&self) -> Result<Vec<LlmMessage>>;
}

// System handles this internally:
// - Token counting
// - Compression threshold checking
// - Content store writes for large messages
// - Checkpoint creation/loading
```

**2. Automatic Compression**

```rust
// Developer configures once:
let config = AgentConfig {
    model: "claude-sonnet-4-20250514".to_string(),
    context_limit: 200_000,
    compression_threshold: 0.7,  // Compress at 70%
    compression_strategy: CompressionStrategy::LlmSummary {
        model: "claude-haiku".to_string(),
        preserve_recent: 0.3,
    },
};

// Then just writes normal code - compression is automatic:
async fn agent_loop(&self, ctx: &dyn AgentContext) -> Result<()> {
    loop {
        let user_input = ctx.wait_for_input().await?;
        ctx.add_message(Role::User, &user_input).await?;

        // System checks: do we need to compress?
        // If yes, it happens transparently before the LLM call

        let response = ctx.call_llm(&self.config).await?;
        ctx.add_message(Role::Assistant, &response).await?;

        if response.is_done() {
            break;
        }
    }
    Ok(())
}
```

**3. Tool Execution with Approval**

```rust
// Developer writes:
let result = ctx.execute_tool(&tool_call).await?;

// System handles:
// - Checking approval policy
// - Suspending workflow if approval needed (durable promise)
// - Storing tool call + result (small metadata in event, large result in content_store)
// - Resuming when approved
```

**4. Debugging / Observability**

```rust
// Developer can inspect context state for debugging:
let stats = ctx.context_stats().await?;
println!("Tokens: {}/{}", stats.current_tokens, stats.limit);
println!("Messages: {} (checkpoint: {})", stats.message_count, stats.checkpoint_count);
println!("Compressions: {}", stats.compression_count);

// Full history available via separate API (loads from content_store):
let full_history = ctx.full_history().await?;  // Expensive, for debugging only
```

### What Developers DON'T See

```rust
// These are internal implementation details:

// ❌ Developer doesn't write this:
let content_ref = content_store.store(&large_message).await?;
event_repo.append_with_auto_sequence(
    workflow_id,
    EventType::MessageAdded,
    Some(small_metadata),
    Some(content_ref),
).await?;

// ❌ Developer doesn't manage checkpoints:
if token_count > threshold {
    let summary = llm.summarize(&old_messages).await?;
    let checkpoint_ref = content_store.store(&summary).await?;
    // ...
}

// ❌ Developer doesn't reconstruct context:
let checkpoint = content_store.get(&checkpoint_ref).await?;
let recent = content_store.get_many(&recent_refs).await?;
let messages = vec![checkpoint, ...recent];
```

### API Layers

```
┌─────────────────────────────────────────────────────────────┐
│  Agent Developer Code                                        │
│  ctx.add_message(), ctx.messages(), ctx.call_llm()          │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│  AgentContext (high-level API)                               │
│  - Token counting                                            │
│  - Automatic compression                                     │
│  - Message formatting                                        │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│  WorkflowContext (existing SDK)                              │
│  - ctx.schedule_raw(), ctx.set_raw(), ctx.promise_raw()     │
└────────────────────────┬────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────┐
│  EventRepository + ContentStore (internal)                   │
│  - Event metadata in workflow_event                          │
│  - Large payloads in content_store                           │
└─────────────────────────────────────────────────────────────┘
```

### Example: Complete Agent Workflow

```rust
#[derive(Default)]
struct CodeAssistantAgent;

#[async_trait]
impl AgentDefinition for CodeAssistantAgent {
    fn kind(&self) -> &str { "code-assistant" }

    fn config(&self) -> AgentConfig {
        AgentConfig {
            model: "claude-sonnet-4-20250514".to_string(),
            max_turns: 50,
            tools: vec![
                Tool::ReadFile,
                Tool::WriteFile,
                Tool::Search,
                Tool::Bash,
            ],
            approval_policy: ApprovalPolicy::RequireForWrites,
            compression: CompressionConfig {
                threshold: 0.7,
                strategy: CompressionStrategy::LlmSummary {
                    preserve_recent: 0.3
                },
            },
        }
    }

    async fn execute(&self, ctx: &dyn AgentContext) -> Result<AgentOutput> {
        let input: AgentInput = ctx.input()?;

        // Set system prompt (stored efficiently - deduplicated if same across runs)
        ctx.set_system_prompt(&self.system_prompt()).await?;

        // Add initial user message
        ctx.add_message(Role::User, &input.prompt).await?;

        // Agent loop
        for turn in 0..self.config().max_turns {
            // Call LLM (context automatically managed)
            let response = ctx.call_llm().await?;

            // Add response
            ctx.add_message(Role::Assistant, &response.content).await?;

            // Handle tool calls
            for tool_call in response.tool_calls {
                // Approval handled automatically based on policy
                let result = ctx.execute_tool(&tool_call).await?;
                ctx.add_tool_result(&tool_call.id, &result).await?;
            }

            // Check if done
            if response.stop_reason == StopReason::EndTurn {
                break;
            }
        }

        Ok(AgentOutput {
            final_response: ctx.last_assistant_message()?,
        })
    }
}
```

### Customizing Compression Strategy

When defaults don't work, developers can customize at multiple levels:

**1. Configuration-Level Customization**

```rust
AgentConfig {
    compression: CompressionConfig {
        // When to compress (default: 0.7 = 70% of context)
        threshold: 0.8,

        // What to keep unchanged (default: 0.3 = 30% of recent messages)
        preserve_recent: 0.5,

        // Strategy selection
        strategy: CompressionStrategy::LlmSummary {
            model: "claude-haiku".to_string(),
            prompt_template: Some(CUSTOM_PROMPT.to_string()),
        },

        // Or use algorithmic (no LLM cost)
        // strategy: CompressionStrategy::SlidingWindow { max_messages: 50 },

        // Or hybrid
        // strategy: CompressionStrategy::Hybrid {
        //     window_size: 30,
        //     summarize_every_n_turns: 20,
        // },
    },
}
```

**2. Custom Compression Prompt**

```rust
const CUSTOM_PROMPT: &str = r#"
Summarize this conversation for a coding assistant. Focus on:
1. What files were modified
2. What the user's current goal is
3. Any errors encountered and their status

Format as structured markdown, not prose.
"#;

AgentConfig {
    compression: CompressionConfig {
        strategy: CompressionStrategy::LlmSummary {
            model: "claude-haiku".to_string(),
            prompt_template: Some(CUSTOM_PROMPT.to_string()),
        },
        ..Default::default()
    },
}
```

**3. Custom Token Counter**

```rust
// For models with non-standard tokenization
AgentConfig {
    token_counter: TokenCounter::Custom(Box::new(|content: &str| {
        // Your tokenization logic
        tiktoken::count_tokens(content, "cl100k_base")
    })),
    ..Default::default()
}
```

**4. Manual Compression Control**

```rust
// Disable automatic compression
AgentConfig {
    compression: CompressionConfig {
        auto_compress: false,  // Developer controls when
        ..Default::default()
    },
}

// Then manually trigger when needed
async fn execute(&self, ctx: &dyn AgentContext) -> Result<AgentOutput> {
    // ... agent loop ...

    // Manual check and compress
    if ctx.context_stats().await?.token_usage_ratio > 0.8 {
        ctx.compress_now().await?;
    }

    // Or compress at specific points (e.g., after completing a subtask)
    if subtask_complete {
        ctx.compress_with_note("Completed file refactoring subtask").await?;
    }
}
```

**5. Preserve Specific Messages**

```rust
// Mark important messages to never compress
ctx.add_message(Role::User, &important_instruction)
    .preserve(true)  // Never include in compression
    .await?;

// Or use tags
ctx.add_message(Role::Assistant, &key_decision)
    .tag("decision")  // Can filter by tag later
    .await?;

// Custom preservation logic
AgentConfig {
    compression: CompressionConfig {
        preserve_filter: Box::new(|msg: &Message| {
            // Keep all messages with code blocks
            msg.content.contains("```") ||
            // Keep tool results
            msg.role == Role::ToolResult ||
            // Keep messages tagged as important
            msg.tags.contains(&"important")
        }),
        ..Default::default()
    },
}
```

**6. Hooks for Compression Events**

```rust
AgentConfig {
    compression: CompressionConfig {
        on_before_compress: Some(Box::new(|ctx, stats| {
            tracing::info!(
                "Compressing: {} tokens -> target {}",
                stats.current_tokens,
                stats.target_tokens
            );
        })),

        on_after_compress: Some(Box::new(|ctx, result| {
            // Log what was preserved
            tracing::info!(
                "Compressed: {} messages -> {} checkpoint + {} recent",
                result.messages_before,
                1,
                result.messages_after
            );

            // Could emit custom event for observability
            ctx.emit_metric("compression_ratio", result.ratio);
        })),

        ..Default::default()
    },
}
```

**7. Strategy Override per-Turn**

```rust
// For specific situations, override the default strategy
async fn execute(&self, ctx: &dyn AgentContext) -> Result<AgentOutput> {
    // Complex debugging session - want full history
    if self.is_debugging_mode() {
        ctx.set_compression_strategy(CompressionStrategy::None).await?;
    }

    // High-stakes operation - use best summarization
    if self.is_critical_operation() {
        ctx.set_compression_strategy(CompressionStrategy::LlmSummary {
            model: "claude-sonnet-4-20250514".to_string(),  // Better model for summary
            prompt_template: Some(DETAILED_SUMMARY_PROMPT.to_string()),
        }).await?;
    }

    // ... rest of agent loop ...
}
```

**8. Access Raw Context (Escape Hatch)**

```rust
// When you need full control
async fn execute(&self, ctx: &dyn AgentContext) -> Result<AgentOutput> {
    // Get underlying workflow context for low-level operations
    let workflow_ctx = ctx.workflow_context();

    // Access raw message storage
    let raw_messages = ctx.raw_messages().await?;  // All messages, no compression

    // Build custom LLM context
    let custom_context = self.build_custom_context(&raw_messages);
    let response = self.call_llm_directly(&custom_context).await?;

    // Store result back
    ctx.add_message_raw(Role::Assistant, response.into()).await?;
}
```

**9. Completely Custom Implementation**

```rust
// Implement your own context manager
struct MyCustomContextManager {
    // Your state
}

impl ContextManager for MyCustomContextManager {
    async fn add_message(&mut self, msg: Message) -> Result<()> {
        // Your logic
    }

    async fn get_llm_context(&self) -> Result<Vec<LlmMessage>> {
        // Your context building logic
    }

    async fn maybe_compress(&mut self) -> Result<bool> {
        // Your compression logic
    }
}

// Use it
AgentConfig {
    context_manager: ContextManagerConfig::Custom(
        Box::new(MyCustomContextManager::new())
    ),
}
```

**10. Dynamic Model Selection**

`AgentConfig` provides defaults, but model can change per-call:

```rust
// Config sets defaults
AgentConfig {
    default_model: "claude-haiku".to_string(),  // Default for simple tasks
    ..Default::default()
}

// Override per-call based on task complexity
async fn execute(&self, ctx: &dyn AgentContext) -> Result<AgentOutput> {
    loop {
        // Analyze what we need to do
        let task_complexity = self.assess_complexity(ctx).await?;

        // Select model dynamically
        let model = match task_complexity {
            Complexity::Simple => "claude-haiku",           // Quick, cheap
            Complexity::Medium => "claude-sonnet-4-20250514",         // Balanced
            Complexity::Complex => "claude-opus-4-20250514",           // Best reasoning
            Complexity::CodeGen => "claude-sonnet-4-20250514",         // Good at code
        };

        // Call with selected model
        let response = ctx.call_llm_with_model(model).await?;

        // Or use builder pattern
        let response = ctx.call_llm()
            .model(model)
            .temperature(0.7)
            .max_tokens(4096)
            .await?;

        // ...
    }
}
```

**Model Selection Strategies:**

```rust
// Strategy 1: Task-based selection
impl AgentContext {
    async fn call_llm_for_task(&self, task: TaskType) -> Result<LlmResponse> {
        let model = match task {
            TaskType::Planning => "claude-opus-4-20250514",      // Complex reasoning
            TaskType::CodeGeneration => "claude-sonnet-4-20250514",  // Good code, fast
            TaskType::SimpleQuery => "claude-haiku",   // Quick answers
            TaskType::Summarization => "claude-haiku", // Compression
        };
        self.call_llm_with_model(model).await
    }
}

// Strategy 2: Cost-aware selection
struct CostAwareModelSelector {
    budget_remaining: f64,
    token_costs: HashMap<String, f64>,
}

impl ModelSelector for CostAwareModelSelector {
    fn select(&self, context_size: usize, task: &TaskType) -> String {
        let estimated_cost = self.estimate_cost(context_size);

        if self.budget_remaining < estimated_cost * 2.0 {
            // Low budget - use cheapest
            "claude-haiku".to_string()
        } else if task.requires_complex_reasoning() {
            "claude-opus-4-20250514".to_string()
        } else {
            "claude-sonnet-4-20250514".to_string()
        }
    }
}

// Strategy 3: Fallback chain
async fn call_with_fallback(&self, ctx: &dyn AgentContext) -> Result<LlmResponse> {
    // Try best model first
    match ctx.call_llm_with_model("claude-opus-4-20250514").await {
        Ok(response) => Ok(response),
        Err(e) if e.is_rate_limited() => {
            // Fallback to sonnet
            ctx.call_llm_with_model("claude-sonnet-4-20250514").await
        }
        Err(e) if e.is_overloaded() => {
            // Fallback to haiku
            ctx.call_llm_with_model("claude-haiku").await
        }
        Err(e) => Err(e),
    }
}

// Strategy 4: Router model
async fn routed_call(&self, ctx: &dyn AgentContext, prompt: &str) -> Result<LlmResponse> {
    // Use cheap model to decide which model to use
    let routing_response = ctx.call_llm()
        .model("claude-haiku")
        .system_prompt("Classify this task: SIMPLE, MEDIUM, or COMPLEX")
        .user_message(prompt)
        .await?;

    let target_model = match routing_response.content.trim() {
        "SIMPLE" => "claude-haiku",
        "MEDIUM" => "claude-sonnet-4-20250514",
        "COMPLEX" => "claude-opus-4-20250514",
        _ => "claude-sonnet-4-20250514",
    };

    ctx.call_llm_with_model(target_model).await
}
```

**Per-Phase Model Configuration:**

```rust
// Different phases of agent work use different models
async fn execute(&self, ctx: &dyn AgentContext) -> Result<AgentOutput> {
    // Phase 1: Planning (needs best reasoning)
    ctx.set_model("claude-opus-4-20250514").await?;
    let plan = ctx.call_llm()
        .system_prompt("Create a detailed plan...")
        .await?;

    // Phase 2: Execution (needs speed + good code)
    ctx.set_model("claude-sonnet-4-20250514").await?;
    for step in plan.steps {
        let result = ctx.call_llm()
            .user_message(&format!("Execute step: {}", step))
            .await?;
        // ...
    }

    // Phase 3: Review (needs careful analysis)
    ctx.set_model("claude-opus-4-20250514").await?;
    let review = ctx.call_llm()
        .system_prompt("Review the changes for issues...")
        .await?;

    Ok(output)
}
```

**Tool-Specific Model Selection:**

```rust
// Different tools might need different models
AgentConfig {
    tool_models: HashMap::from([
        ("complex_analysis", "claude-opus-4-20250514"),
        ("code_generation", "claude-sonnet-4-20250514"),
        ("simple_search", "claude-haiku"),
    ]),
    default_model: "claude-sonnet-4-20250514".to_string(),
}

// Or configure per tool call
let result = ctx.execute_tool(&tool_call)
    .with_model("claude-opus-4-20250514")  // For tool result interpretation
    .await?;
```

### Summary: Customization Levels

| Level | Use Case | Complexity |
|-------|----------|------------|
| **Config params** | Adjust thresholds, choose strategy | Low |
| **Custom prompt** | Domain-specific summarization | Low |
| **Dynamic model** | `ctx.call_llm_with_model("opus")` | Low |
| **Preserve filters** | Keep important messages | Medium |
| **Hooks** | Logging, metrics, side effects | Medium |
| **Manual control** | Compress at specific points | Medium |
| **Strategy override** | Different strategies for different phases | Medium |
| **Model selector** | Cost-aware, task-based, fallback chain | Medium |
| **Raw access** | Escape hatch for edge cases | High |
| **Custom impl** | Complete control | High |

---

## Observability and Debugging

With event sourcing + content store, we can reconstruct **everything** about an agent's execution.

### What We Can Reconstruct

```
Events (workflow_event)          Content Store
━━━━━━━━━━━━━━━━━━━━━━━━━━━━    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
seq=1  MessageAdded (user)   →   "Help me refactor auth.rs"
seq=2  LlmCalled             →   {model: "sonnet", tokens: 5000}
seq=3  MessageAdded (asst)   →   "I'll analyze the file..."
seq=4  ToolCalled (read)     →   {path: "src/auth.rs"}
seq=5  ToolResult            →   [500 lines of code]
seq=6  LlmCalled             →   {model: "sonnet", tokens: 12000}
seq=7  MessageAdded (asst)   →   "I found 3 issues..."
seq=8  ToolCalled (edit)     →   {path: "src/auth.rs", changes: ...}
seq=9  ApprovalRequested     →   {action: "edit file", risk: "medium"}
seq=10 ApprovalReceived      →   {decision: "approved", latency: 5000ms}
seq=11 ToolResult            →   "File edited successfully"
seq=12 ContextCompressed     →   [checkpoint summary]
...
```

### 1. Full Conversation Replay

```rust
// Load complete conversation history for debugging
async fn replay_conversation(workflow_id: &Uuid) -> ConversationReplay {
    // Get all events (fast - just metadata)
    let events = event_repo.get_events(workflow_id).await?;

    // Load all content (on-demand)
    let mut messages = Vec::new();
    for event in events {
        match event.event_type {
            EventType::MessageAdded => {
                let content = content_store.get(&event.content_ref).await?;
                messages.push(Message::from(content));
            }
            EventType::ToolCalled => {
                let args = content_store.get(&event.content_ref).await?;
                messages.push(ToolCall::from(args));
            }
            EventType::ToolResult => {
                let result = content_store.get(&event.content_ref).await?;
                messages.push(ToolResult::from(result));
            }
            // ...
        }
    }

    ConversationReplay { events, messages }
}
```

### 2. Decision Point Analysis

See where the agent made choices and why:

```rust
struct DecisionPoint {
    sequence: i32,
    timestamp: DateTime<Utc>,
    decision_type: DecisionType,
    context_before: ContextSnapshot,  // What the agent "saw"
    options_considered: Vec<Option>,  // If available from LLM response
    choice_made: Choice,
    reasoning: Option<String>,        // If agent provided reasoning
}

enum DecisionType {
    ToolSelection,      // Which tool to call
    ToolArguments,      // What arguments to pass
    BranchTaken,        // Conditional logic
    StopDecision,       // When to stop
    ApprovalRequest,    // What needed approval
}

// Extract decision points from events
async fn extract_decisions(workflow_id: &Uuid) -> Vec<DecisionPoint> {
    let events = event_repo.get_events(workflow_id).await?;

    let mut decisions = Vec::new();
    let mut context_so_far = Vec::new();

    for (i, event) in events.iter().enumerate() {
        match event.event_type {
            EventType::ToolCalled => {
                // Reconstruct what context the agent had when making this decision
                let context_snapshot = build_context_snapshot(&context_so_far).await?;

                decisions.push(DecisionPoint {
                    sequence: event.sequence_number,
                    timestamp: event.created_at,
                    decision_type: DecisionType::ToolSelection,
                    context_before: context_snapshot,
                    choice_made: Choice::ToolCall(load_tool_call(event).await?),
                    reasoning: extract_reasoning(&events, i),
                });
            }
            // ... other decision types
        }
        context_so_far.push(event);
    }

    decisions
}
```

### 3. Counterfactual Exploration ("What If?")

Replay from any point with different choices:

```rust
// Fork from a specific point and try different path
async fn explore_alternative(
    workflow_id: &Uuid,
    fork_at_sequence: i32,
    alternative_action: Action,
) -> AlternativeExploration {
    // Load events up to fork point
    let events = event_repo.get_events_up_to(workflow_id, fork_at_sequence).await?;

    // Reconstruct context at that point
    let context = reconstruct_context_at(&events).await?;

    // Execute alternative action
    let alternative_result = execute_in_sandbox(context, alternative_action).await?;

    AlternativeExploration {
        original_path: load_events_after(workflow_id, fork_at_sequence).await?,
        alternative_path: alternative_result,
        divergence_point: fork_at_sequence,
    }
}

// UI could show:
// "At turn 7, agent called `edit_file`. What if it had called `read_file` first?"
```

### 4. Decision Tree Visualization

```
                    [Start: "Refactor auth.rs"]
                              │
                              ▼
                    [read_file: auth.rs] ← Decision 1
                              │
                    ┌─────────┴─────────┐
                    ▼                   ▼
            [Found 3 issues]    [Could have: run tests first]
                    │                   (unexplored)
                    ▼
            [edit_file: fix #1] ← Decision 2 (required approval)
                    │
                    ▼
            [Approval: 5s wait]
                    │
                    ▼
            [edit_file: fix #2] ← Decision 3
                    │
                    ▼
            [Context compressed] ← Checkpoint created
                    │
                    ▼
                  [Done]
```

```rust
// Build decision tree from events
async fn build_decision_tree(workflow_id: &Uuid) -> DecisionTree {
    let decisions = extract_decisions(workflow_id).await?;

    let mut tree = DecisionTree::new();
    let mut current_node = tree.root();

    for decision in decisions {
        // Add the actual path taken
        let node = current_node.add_child(DecisionNode {
            decision: decision.clone(),
            was_taken: true,
        });

        // Add unexplored alternatives (if we can infer them)
        if let Some(alternatives) = infer_alternatives(&decision) {
            for alt in alternatives {
                current_node.add_child(DecisionNode {
                    decision: alt,
                    was_taken: false,
                });
            }
        }

        current_node = node;
    }

    tree
}
```

### 5. Checkpoint Diff (Before/After Compression)

```rust
// Compare what was lost during compression
async fn analyze_compression(
    workflow_id: &Uuid,
    checkpoint_sequence: i32,
) -> CompressionAnalysis {
    // Get checkpoint event
    let checkpoint_event = event_repo.get_event(workflow_id, checkpoint_sequence).await?;
    let checkpoint_summary = content_store.get(&checkpoint_event.content_ref).await?;

    // Get all events that were compressed
    let compressed_events = event_repo.get_events_before(
        workflow_id,
        checkpoint_sequence
    ).await?;

    // Load full content of compressed messages
    let original_messages = load_full_messages(&compressed_events).await?;

    CompressionAnalysis {
        original_message_count: original_messages.len(),
        original_token_count: count_tokens(&original_messages),
        summary: checkpoint_summary,
        summary_token_count: count_tokens(&checkpoint_summary),

        // What was preserved vs lost
        preserved: extract_preserved_info(&checkpoint_summary),
        potentially_lost: diff_content(&original_messages, &checkpoint_summary),
    }
}

// Example output:
// CompressionAnalysis {
//   original_message_count: 45,
//   original_token_count: 35000,
//   summary_token_count: 2000,
//   preserved: ["goal: refactor auth", "files modified: auth.rs, user.rs"],
//   potentially_lost: ["detailed error message from line 127", "user's preference for naming"],
// }
```

### 6. Token Usage Timeline

```rust
struct TokenTimeline {
    points: Vec<TokenTimelinePoint>,
}

struct TokenTimelinePoint {
    sequence: i32,
    timestamp: DateTime<Utc>,
    event_type: String,
    tokens_added: u32,
    tokens_total: u32,
    context_limit: u32,
    usage_ratio: f32,
    compression_triggered: bool,
}

// Visualize how context grew and when compression happened
async fn build_token_timeline(workflow_id: &Uuid) -> TokenTimeline {
    let events = event_repo.get_events(workflow_id).await?;

    let mut timeline = Vec::new();
    let mut running_total = 0u32;
    let context_limit = 200_000u32;

    for event in events {
        let tokens_added = match event.event_type {
            EventType::MessageAdded | EventType::ToolResult => {
                let content = content_store.get(&event.content_ref).await?;
                estimate_tokens(&content)
            }
            EventType::ContextCompressed => {
                // Negative - tokens removed
                let meta: CompressionMeta = parse_event_data(&event)?;
                -(meta.tokens_before as i32 - meta.tokens_after as i32) as u32
            }
            _ => 0,
        };

        running_total = (running_total as i32 + tokens_added as i32).max(0) as u32;

        timeline.push(TokenTimelinePoint {
            sequence: event.sequence_number,
            timestamp: event.created_at,
            event_type: event.event_type.clone(),
            tokens_added,
            tokens_total: running_total,
            context_limit,
            usage_ratio: running_total as f32 / context_limit as f32,
            compression_triggered: event.event_type == EventType::ContextCompressed,
        });
    }

    TokenTimeline { points: timeline }
}
```

### 7. Time Travel Debugging

Go back to any point and inspect state:

```rust
// Reconstruct exact agent state at any sequence number
async fn time_travel(workflow_id: &Uuid, to_sequence: i32) -> AgentStateSnapshot {
    let events = event_repo.get_events_up_to(workflow_id, to_sequence).await?;

    // Reconstruct conversation at that point
    let messages = reconstruct_messages(&events).await?;

    // Find applicable checkpoint (if any)
    let checkpoint = find_checkpoint_before(&events);

    // Reconstruct what context the LLM would have seen
    let llm_context = if let Some(cp) = checkpoint {
        let summary = content_store.get(&cp.content_ref).await?;
        let recent = messages_after_checkpoint(&messages, cp.sequence);
        vec![summary].into_iter().chain(recent).collect()
    } else {
        messages.clone()
    };

    AgentStateSnapshot {
        sequence: to_sequence,
        timestamp: events.last().map(|e| e.created_at),
        full_history: messages,
        llm_context,  // What the agent actually "saw"
        token_count: count_tokens(&llm_context),
        pending_approvals: find_pending_approvals(&events),
        workflow_state: reconstruct_workflow_state(&events),
    }
}

// Debug UI usage:
// "Show me exactly what the agent saw at turn 15"
let snapshot = time_travel(workflow_id, 15).await?;
println!("Context size: {} tokens", snapshot.token_count);
println!("Messages in context: {}", snapshot.llm_context.len());
for msg in &snapshot.llm_context {
    println!("[{}]: {}", msg.role, truncate(&msg.content, 100));
}
```

### 8. Debugging API

```rust
// gRPC service for debugging
service AgentDebugService {
    // Full conversation replay
    rpc ReplayConversation(ReplayRequest) returns (ConversationReplay);

    // Decision analysis
    rpc GetDecisionPoints(DecisionRequest) returns (DecisionPointList);
    rpc GetDecisionTree(TreeRequest) returns (DecisionTree);

    // Counterfactual exploration
    rpc ExploreAlternative(AlternativeRequest) returns (AlternativeExploration);

    // Compression analysis
    rpc AnalyzeCompression(CompressionRequest) returns (CompressionAnalysis);

    // Time travel
    rpc GetStateAt(TimeravelRequest) returns (AgentStateSnapshot);

    // Token timeline
    rpc GetTokenTimeline(TimelineRequest) returns (TokenTimeline);

    // Search across runs
    rpc SearchDecisions(SearchRequest) returns (SearchResults);
    // e.g., "Find all runs where agent called dangerous_tool"
}
```

### 9. Cross-Run Analysis

Compare decisions across multiple runs:

```rust
// Find patterns across runs
async fn analyze_across_runs(
    workflow_kind: &str,
    filter: RunFilter,
) -> CrossRunAnalysis {
    let runs = find_runs(workflow_kind, filter).await?;

    CrossRunAnalysis {
        // "Agent chooses tool X 80% of the time when context contains Y"
        decision_patterns: extract_decision_patterns(&runs).await?,

        // "Runs that compressed early had 20% higher success rate"
        compression_correlation: analyze_compression_impact(&runs).await?,

        // "Average 12 turns to completion, 3 tool calls"
        statistics: compute_statistics(&runs).await?,

        // "These 5 runs failed at similar decision points"
        failure_clusters: cluster_failures(&runs).await?,
    }
}
```

### 10. Natural Language Debugging

Use LLM to analyze agent behavior:

```rust
async fn explain_run(workflow_id: &Uuid) -> Explanation {
    let replay = replay_conversation(workflow_id).await?;
    let decisions = extract_decisions(workflow_id).await?;

    let prompt = format!(r#"
        Analyze this AI agent's execution and explain:
        1. What was the agent trying to accomplish?
        2. What key decisions did it make?
        3. Were there any mistakes or suboptimal choices?
        4. What could have been done differently?

        Conversation:
        {}

        Decision points:
        {}
    "#, format_conversation(&replay), format_decisions(&decisions));

    llm.generate(prompt).await
}

// Example output:
// "The agent was tasked with refactoring auth.rs. It made 3 key decisions:
//  1. Read the file first (good - gathered context)
//  2. Edited without running tests (risky - could break things)
//  3. Requested approval for destructive edit (appropriate caution)
//
//  Suboptimal: At turn 7, the agent could have run tests before editing.
//  This would have caught the null pointer issue earlier."
```

### 11. Capturing "Why" - Agent Reasoning

The hardest part: we see **what** the agent did, but **why** requires explicit capture.

**The Problem:**
```
Event: ToolCalled { tool: "edit_file", args: {...} }

We know WHAT: Agent edited the file
We DON'T know WHY: Was it because of user request? Error fix? Refactoring?
```

**The Honest Reality:**

| Capture Method | Developer Effort | Token Cost | Accuracy |
|----------------|------------------|------------|----------|
| Inference from context | Zero | Zero | ~60-70% |
| Extended thinking | Config flag (default ON) | 10-20% | ~90% |
| Structured reasoning prompt | Custom system prompt | 20-30% | ~95% |

There is no magic. "Why" capture requires one of:
1. **Token overhead** - LLM explains itself (thinking blocks)
2. **Developer effort** - Custom prompts that force explanation
3. **Accuracy loss** - Infer from context (imperfect)

**Flovyn's Stance: Default to thinking blocks.**

The 10-20% token overhead is worth it for production debuggability. Developers who disagree can opt out. But the default should be "capture reasoning".

**Approaches to Capture Reasoning:**

**A. Extended Thinking (Claude's `thinking` blocks) - DEFAULT**

```rust
// Flovyn enables this BY DEFAULT
// Developer doesn't write this - system does
let response = ctx.call_llm()
    .model("claude-sonnet-4-20250514")
    .extended_thinking(true)  // Enabled by default in Flovyn
    .await?;

// Response contains both thinking and output
struct LlmResponse {
    thinking: Option<String>,  // Internal reasoning (if enabled)
    content: String,           // Final response
    tool_calls: Vec<ToolCall>,
}

// Store thinking alongside the decision
ctx.add_message(Role::Assistant, &response.content)
    .with_thinking(&response.thinking)  // Stored in content_store
    .await?;
```

**Event with reasoning:**
```
seq=7  LlmResponse {
         thinking: "The user wants to refactor auth.rs. I should:
                    1. First read the file to understand structure
                    2. Look for the duplicate code they mentioned
                    3. Extract into helper function
                    I'll start by reading the file.",
         content: "I'll analyze the auth.rs file first.",
         tool_calls: [{ tool: "read_file", args: {path: "auth.rs"} }]
       }
```

**B. Structured Reasoning Output**

Force agent to explain before acting:

```rust
// System prompt that requires reasoning
const SYSTEM_PROMPT: &str = r#"
Before taking any action, you must explain your reasoning in <reasoning> tags.

Format:
<reasoning>
- Current goal: [what you're trying to achieve]
- Observation: [what you noticed that triggered this action]
- Options considered: [alternatives you thought about]
- Decision: [what you chose and why]
</reasoning>

Then provide your action.
"#;

// Parse reasoning from response
fn extract_reasoning(content: &str) -> Option<Reasoning> {
    let re = Regex::new(r"<reasoning>(.*?)</reasoning>").unwrap();
    re.captures(content).map(|c| parse_reasoning(&c[1]))
}

struct Reasoning {
    current_goal: String,
    observation: String,
    options_considered: Vec<String>,
    decision: String,
    decision_rationale: String,
}
```

**C. Post-Hoc Explanation**

Ask the LLM to explain a decision after the fact:

```rust
async fn explain_decision(
    workflow_id: &Uuid,
    decision_sequence: i32,
) -> DecisionExplanation {
    // Reconstruct context at decision point
    let context_before = time_travel(workflow_id, decision_sequence - 1).await?;
    let decision_event = get_event(workflow_id, decision_sequence).await?;

    // Ask LLM to explain
    let prompt = format!(r#"
        Given this conversation context:
        {}

        The agent made this decision:
        {}

        Explain:
        1. What information in the context likely triggered this decision?
        2. What alternatives could have been considered?
        3. Was this a reasonable choice given the context?
    "#, format_context(&context_before), format_decision(&decision_event));

    let explanation = llm.generate(prompt).await?;

    DecisionExplanation {
        decision: decision_event,
        context_at_decision: context_before,
        explanation,
        confidence: assess_explanation_confidence(&explanation),
    }
}
```

**D. Reasoning Diff - What Changed?**

Infer reasoning by comparing consecutive turns:

```rust
async fn infer_reasoning(
    workflow_id: &Uuid,
    decision_sequence: i32,
) -> InferredReasoning {
    let before = time_travel(workflow_id, decision_sequence - 1).await?;
    let after = time_travel(workflow_id, decision_sequence).await?;

    // What new information appeared?
    let new_info = diff_contexts(&before, &after);

    // Correlate with decision
    let decision = get_decision_at(workflow_id, decision_sequence).await?;

    InferredReasoning {
        // "Agent read file X, then edited it → likely acting on file contents"
        trigger: identify_trigger(&new_info, &decision),

        // "User mentioned 'fix bug' 2 turns ago → responding to user request"
        goal_source: trace_goal_origin(&before, &decision),

        // "3 similar patterns in context → following established pattern"
        pattern_following: detect_pattern_following(&before, &decision),
    }
}
```

**E. Tool Choice Attribution**

Track why specific tools were selected:

```rust
// Store attribution with tool calls
struct ToolCallWithAttribution {
    tool: String,
    args: Value,

    // Attribution
    triggered_by: Attribution,
}

enum Attribution {
    // Direct user request: "please read file X"
    UserRequest { message_seq: i32, quote: String },

    // Following previous tool result
    FollowUp { previous_tool_seq: i32, reason: String },

    // Error recovery
    ErrorRecovery { error_seq: i32, error_type: String },

    // Agent initiative
    AgentInitiative { reasoning: String },

    // Unknown (no clear trigger)
    Unknown,
}

// Automatically infer attribution
fn infer_attribution(context: &Context, tool_call: &ToolCall) -> Attribution {
    // Check if user explicitly requested this
    if let Some(request) = find_user_request(context, tool_call) {
        return Attribution::UserRequest {
            message_seq: request.seq,
            quote: request.quote,
        };
    }

    // Check if following up on error
    if let Some(error) = find_recent_error(context) {
        if tool_call_addresses_error(tool_call, &error) {
            return Attribution::ErrorRecovery {
                error_seq: error.seq,
                error_type: error.error_type,
            };
        }
    }

    // Check if following previous tool result
    if let Some(follow_up) = detect_follow_up_pattern(context, tool_call) {
        return Attribution::FollowUp {
            previous_tool_seq: follow_up.seq,
            reason: follow_up.reason,
        };
    }

    Attribution::Unknown
}
```

**F. Reasoning Chain Visualization**

```
User: "Fix the authentication bug"
       │
       ▼
   ┌─────────────────────────────────────────────────────────┐
   │ REASONING (from thinking block):                        │
   │ "User wants to fix auth bug. I should:                 │
   │  1. Find where auth is implemented                      │
   │  2. Look for common auth bugs                           │
   │  3. Check error logs if available"                      │
   └─────────────────────────────────────────────────────────┘
       │
       ▼
   Decision: search_codebase("authentication")
       │
       ├── WHY: User mentioned "authentication bug"
       ├── TRIGGER: User request (seq=1)
       └── ALTERNATIVES: [grep for "auth", read known files]
       │
       ▼
   Tool Result: Found auth.rs, auth_middleware.rs
       │
       ▼
   ┌─────────────────────────────────────────────────────────┐
   │ REASONING:                                              │
   │ "Found 2 auth files. auth_middleware.rs likely has     │
   │  the request handling. Will read that first."          │
   └─────────────────────────────────────────────────────────┘
       │
       ▼
   Decision: read_file("auth_middleware.rs")
       │
       ├── WHY: Follow-up on search results
       ├── TRIGGER: Previous tool result (seq=3)
       └── ALTERNATIVES: [read auth.rs first, read both in parallel]
```

**G. Reasoning Storage Schema**

```rust
// Extended event for decisions with reasoning
struct DecisionEvent {
    sequence: i32,
    decision_type: DecisionType,
    choice: Choice,

    // Reasoning capture
    reasoning: Option<ReasoningCapture>,
}

struct ReasoningCapture {
    // Raw thinking from LLM (if extended thinking enabled)
    thinking_block: Option<ContentRef>,

    // Structured reasoning (if agent provided)
    structured: Option<StructuredReasoning>,

    // Inferred attribution
    attribution: Attribution,

    // Post-hoc explanation (generated on-demand, cached)
    explanation_cache: Option<ContentRef>,
}

struct StructuredReasoning {
    goal: String,
    observations: Vec<String>,
    options_considered: Vec<ConsideredOption>,
    selected_option: String,
    rationale: String,
}

struct ConsideredOption {
    option: String,
    pros: Vec<String>,
    cons: Vec<String>,
    rejected_because: Option<String>,
}
```

**H. Debugging UI for Reasoning**

```rust
// Query for decisions with reasoning
async fn get_decision_with_reasoning(
    workflow_id: &Uuid,
    sequence: i32,
) -> DecisionWithReasoning {
    let event = get_event(workflow_id, sequence).await?;
    let context = time_travel(workflow_id, sequence - 1).await?;

    DecisionWithReasoning {
        // What happened
        decision: event.into(),

        // What the agent saw
        context_snapshot: context,

        // Why (multiple sources)
        reasoning: ReasoningSources {
            // Direct from LLM (if captured)
            thinking_block: load_thinking_block(&event).await?,

            // Structured (if provided)
            structured: extract_structured_reasoning(&event),

            // Inferred
            attribution: infer_attribution(&context, &event),

            // On-demand explanation
            post_hoc: None,  // Call explain_decision() if needed
        },

        // Counterfactual
        alternatives: infer_alternatives(&context, &event),
    }
}
```

**Summary: Capturing "Why"**

| Method | When Available | Fidelity | Cost |
|--------|----------------|----------|------|
| **Extended thinking** | If model supports & enabled | High | Included in API call |
| **Structured reasoning** | If system prompt requires | High | Token overhead |
| **Post-hoc explanation** | Always (on-demand) | Medium | Extra API call |
| **Attribution inference** | Always | Low-Medium | Computation only |
| **Reasoning diff** | Always | Low | Computation only |

**Recommendation:**
1. Enable extended thinking for important decisions
2. Use structured reasoning prompts for high-stakes agents
3. Store all thinking blocks in content_store
4. Generate post-hoc explanations on-demand for debugging
5. Always compute attribution as baseline

**Langfuse vs Flovyn: Where We Add Value**

```
┌─────────────────────────────────────────────────────────────────┐
│                    WHAT LANGFUSE SOLVES                         │
│                   (Observability - "What")                      │
├─────────────────────────────────────────────────────────────────┤
│ ✓ LLM call tracing (input/output)                              │
│ ✓ Token usage tracking                                          │
│ ✓ Latency metrics                                               │
│ ✓ Cost tracking                                                 │
│ ✓ Session grouping                                              │
│ ✓ Manual scoring/feedback                                       │
│                                                                 │
│ → "Agent called Claude at 10:05, used 5000 tokens, cost $0.02" │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    WHERE FLOVYN ADDS VALUE                      │
│              (Causal Understanding - "Why")                     │
├─────────────────────────────────────────────────────────────────┤
│ ✓ Reasoning capture (thinking blocks, structured reasoning)    │
│ ✓ Decision attribution (what triggered this action?)           │
│ ✓ Causal chain reconstruction (A led to B led to C)            │
│ ✓ Context at decision point (what did agent "see"?)            │
│ ✓ Counterfactual exploration (what if different choice?)       │
│ ✓ Cross-run pattern analysis (why do similar inputs diverge?)  │
│ ✓ Compression impact (what reasoning was "forgotten"?)         │
│                                                                 │
│ → "Agent edited file BECAUSE user said 'fix bug' (seq=1),      │
│    AFTER reading file (seq=3) which revealed null pointer,     │
│    CONSIDERING but rejecting 'add test first' approach"        │
└─────────────────────────────────────────────────────────────────┘
```

| Question | Langfuse | Flovyn |
|----------|----------|--------|
| "What LLM calls were made?" | ✓ Full trace | ✓ (from events) |
| "How many tokens used?" | ✓ Detailed metrics | ✓ (from events) |
| "What was the prompt?" | ✓ Raw I/O | ✓ (from content store) |
| "**Why** did agent call this tool?" | ✗ | ✓ Attribution + reasoning |
| "What alternatives were considered?" | ✗ | ✓ From thinking blocks |
| "What context triggered this decision?" | ✗ | ✓ Time travel + diff |
| "What if agent chose differently?" | ✗ | ✓ Counterfactual replay |
| "What info was lost to compression?" | ✗ | ✓ Checkpoint diff |
| "Why do 20% of runs fail at step X?" | ✗ | ✓ Cross-run causal analysis |

**Flovyn's Unique Position:**
- Event sourcing provides **causal structure** (not just logs)
- Content store enables **full reconstruction** (not just samples)
- Workflow context enables **decision attribution** (not just tracing)
- Durable execution enables **counterfactual replay** (not just viewing)

**Integration Strategy:**
```
Flovyn (causal "why")  ←──exports──→  Langfuse (operational "what")
         │                                      │
         │ Unique value:                        │ Unique value:
         │ - Reasoning capture                  │ - Beautiful UI
         │ - Attribution                        │ - Cost dashboards
         │ - Counterfactual                     │ - Team collaboration
         │ - Cross-run analysis                 │ - Manual scoring
         │                                      │
         └──────────────┬───────────────────────┘
                        │
                        ▼
              Developer gets both:
              "What happened" + "Why it happened"
```

### Summary: What Event Sourcing + Content Store Enables

| Capability | How |
|------------|-----|
| **Full replay** | Events = structure, Content = payloads |
| **Decision analysis** | Extract ToolCalled, ApprovalRequested events |
| **Counterfactual** | Fork from any sequence, replay with changes |
| **Compression audit** | Compare checkpoint content vs original |
| **Token timeline** | Sum content sizes over event sequence |
| **Time travel** | Reconstruct state at any sequence |
| **Cross-run patterns** | Query events across workflows |
| **LLM-powered analysis** | Feed replay to another LLM for explanation |

---

## Migration Options Comparison

| Option | Backward Compat | Complexity | Deduplication | Recommended For |
|--------|-----------------|------------|---------------|-----------------|
| **A: Content Store** | Yes | Medium | Yes (hash) | Full solution |
| **B: Threshold-Based** | Yes | Low | Optional | Quick win |
| **C: Lazy View** | Yes | Low | No | Read optimization only |

**Recommendation:** Start with **Option B** (threshold-based) for immediate relief, then migrate to **Option A** (full content store) when AI agent support is added.

---

## Developer Experience

For the complete developer experience guide, including:
- Agent API design
- Tool definition patterns
- Configuration options
- Multi-agent patterns
- Debugging tools

See **[12-developer-experience.md](./20260103_12_developer_experience.md)**

### Quick Summary

| What | Developer Effort | System Handles |
|------|------------------|----------------|
| Write agent code | Normal async code | Storage, compression, durability |
| Define tools | `#[tool]` decorator | Schema generation, execution |
| Configure | `AgentConfig` struct | Defaults for most cases |
| Debug | CLI/API tools | Time travel, decision analysis |

### What Developers CAN Do (Optional Control)

When defaults don't work, developers can opt-in to more control:

| Level | API | Use Case |
|-------|-----|----------|
| **Check stats** | `ctx.context_stats().await?` | Monitor token usage |
| **Force compression** | `ctx.compress_now().await?` | Compress at specific point |
| **Change model** | `ctx.call_llm_with_model("opus")` | Use different model |
| **Preserve messages** | `ctx.add_message().preserve(true)` | Never compress this |
| **View full history** | `ctx.full_history().await?` | Debugging (expensive) |

```rust
// Optional: only if defaults aren't working
if ctx.context_stats().await?.token_usage_ratio > 0.9 {
    ctx.compress_now().await?;  // Manual trigger
}
```

### Debugging Tools for Developers

After execution, developers get tools to understand what happened:

**1. Time Travel (inspect any point)**
```rust
// "Show me exactly what the agent saw at turn 15"
let snapshot = debug_api.time_travel(workflow_id, sequence: 15).await?;

// Returns:
AgentStateSnapshot {
    llm_context: [...],        // Exact messages agent saw
    token_count: 45000,        // How full context was
    pending_approvals: [...],   // Any pending approvals
}
```

**2. Decision Points (why did agent act?)**
```rust
// "What decisions did the agent make?"
let decisions = debug_api.get_decisions(workflow_id).await?;

// Returns:
vec![
    Decision { seq: 5, action: "read_file", triggered_by: "user request" },
    Decision { seq: 9, action: "edit_file", triggered_by: "found bug at line 42" },
    Decision { seq: 12, action: "approved", wait_time: "5s" },
]
```

**3. Reasoning Viewer (if thinking enabled)**
```rust
// "Why did agent choose X?"
let reasoning = debug_api.get_reasoning(workflow_id, sequence: 9).await?;

// Returns:
Reasoning {
    thinking_block: "User wants to fix auth bug. I should...",
    attribution: Attribution::FollowUp { from: seq 7 },
    alternatives_considered: ["run tests first", "ask for clarification"],
}
```

**4. Compression Audit**
```rust
// "What info was lost when context was compressed?"
let audit = debug_api.compression_audit(workflow_id, checkpoint_seq: 20).await?;

// Returns:
CompressionAudit {
    messages_before: 45,
    tokens_before: 85000,
    summary: "Agent was refactoring auth.rs, found 3 issues...",
    preserved: ["goal", "files modified", "current error"],
    potentially_lost: ["user preference for naming", "detailed stack trace"],
}
```

**5. Counterfactual ("What If?")**
```rust
// "What if agent had chosen differently at turn 9?"
let exploration = debug_api.explore_alternative(
    workflow_id,
    fork_at: 9,
    alternative: Action::RunTests,  // Instead of edit_file
).await?;

// Runs in sandbox, shows what would have happened
```

**6. Token Timeline**
```rust
// "How did context grow over time?"
let timeline = debug_api.token_timeline(workflow_id).await?;

// Returns chart data:
// seq=1: 1000 tokens (5%)
// seq=5: 15000 tokens (7.5%)
// seq=10: 45000 tokens (22.5%)
// seq=15: 120000 tokens (60%)
// seq=16: COMPRESSION → 35000 tokens (17.5%)
```

### Developer Workflow

```
DEVELOPMENT                         PRODUCTION
━━━━━━━━━━━━━━━━━━━━━━             ━━━━━━━━━━━━━━━━━━━━━━

1. Write agent code                Agent runs automatically
   └─ ctx.add_message()            └─ Content stored efficiently
   └─ ctx.call_llm()               └─ Context compressed when needed
   └─ ctx.execute_tool()           └─ Events capture everything

                                        │
                                        ▼

DEBUGGING (when needed)
━━━━━━━━━━━━━━━━━━━━━━

2. Something goes wrong?
   └─ Time travel to see context
   └─ View decision points
   └─ Check reasoning blocks
   └─ Audit compression
   └─ Explore alternatives
```

### Summary: Effort Required

| Task | Developer Effort | System Handles |
|------|------------------|----------------|
| **Write agent** | Normal code | Context, storage, compression |
| **Run agent** | Start workflow | Everything |
| **Monitor** | Optional stats check | Automatic |
| **Debug** | Use debug tools | Provides time travel, reasoning, audit |
| **Customize** | Only if needed | Sensible defaults |

**The goal: Writing an AI agent should feel like writing normal code. The infrastructure complexity is invisible until you need to debug.**

---

## Summary

| Concern | Current State | Solution |
|---------|---------------|----------|
| Slow event replay | All data inline | Events store refs, not content |
| LLM context limits | N/A | Compression with checkpoint refs |
| Storage costs | No dedup | Deduplication via content-addressing |
| Observability | Full data always | Content available on-demand |
| Data lifecycle | No policy | Tiered retention, checkpoints kept longer |

The content-addressed store serves as the **shared foundation** for both Flovyn's operational needs (fast replay) and AI agent needs (context management), with the same data model supporting both use cases.
