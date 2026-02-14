# Bug: Entry Counter Collision on Agent Resume

## Date
2026-02-13

## Status
**FIXED** - All issues resolved. Entry collision fixed with random UUIDs. Timestamp preservation fixed by storing/restoring timestamps. Phase tracking fixed by saving pending tool calls in checkpoint state.

## Summary

This document covers three related bugs in agent resume, all now fixed:

1. **Entry counter collision** (FIXED) - Counter-based entry IDs collided when code paths diverged → fixed with random UUIDs
2. **Timestamp serialization** (FIXED) - Messages got new timestamps on resume, causing different task IDs → fixed by storing/restoring timestamps in entry content
3. **Agent restarts loop on resume** (FIXED) - agent-worker's ReactAgent didn't track phase, always restarted from beginning → fixed by saving pending tool calls in checkpoint state and resuming from saved state

## Bug 1: Entry Counter Collision (FIXED)

### Root Cause

**Counter-based idempotency is fundamentally wrong for agents.**

Agents interact with LLMs, user signals, external APIs. They are NOT deterministic. That's why agents use checkpoint-based recovery, not deterministic replay.

### What Happens (The Bug)

**Turn 1:**
- `append_entry(User, input)` → counter=0 → entry:0 (user)
- `append_entry(Assistant, response)` → counter=1 → entry:1 (assistant)
- Suspend

**Turn 2 (resume with counter=0):**
- `append_entry(User, input)` → counter=0 → entry:0 DUPLICATE (OK)
- Steering loop sees signal: `append_entry(User, signal)` → counter=1 → entry:1
- **COLLISION**: key `entry:1` matches existing ASSISTANT entry!
- User message from signal is silently lost
- `append_entry(Assistant, response2)` → counter=2 → entry:2 (assistant)

**Result:** entry:2 should be user (from signal), but is assistant.

---

## Solution

Two separate strategies for entries and tasks:

### 1. Entries: Random UUIDs + Resume Check

**Problem:** Counter-based entry IDs collide when conditional code paths exist.

**Solution:**
- Use random UUIDs for entry IDs (no counter)
- Agent code checks if resuming (via `load_messages().len() > 0`) to avoid re-creating entries

**Why this works:**
- Random UUIDs never collide
- Resume check prevents duplicate entries
- Works with compaction (entry indices don't matter)
- Works with branching (each entry gets unique ID)

### 2. Tasks: Content-based Hashing

**Problem:** Random task IDs break resume (can't find existing task).

**Solution:**
- Generate task idempotency key from `hash(agent_id + kind + canonical_json(input))`
- Derive task_id from idempotency_key using `Uuid::new_v5`
- Same task + same input → same key → server returns existing task

**Why this works:**
- Resume: same code schedules same task → same key → existing result
- Branching: different tasks → different keys → no collision
- Local mode: same formula works
- Transparent to agent code

---

## Implementation

### `sdk-rust/worker-sdk/src/agent/context_impl.rs`

**Canonical JSON serialization for consistent hashing:**
```rust
fn canonical_json_string(value: &Value) -> String {
    match value {
        Value::Object(map) => {
            let mut pairs: Vec<_> = map.iter().collect();
            pairs.sort_by(|a, b| a.0.cmp(b.0));
            let inner: Vec<String> = pairs
                .iter()
                .map(|(k, v)| format!("\"{}\":{}", k, canonical_json_string(v)))
                .collect();
            format!("{{{}}}", inner.join(","))
        }
        Value::Array(arr) => {
            let inner: Vec<String> = arr.iter().map(canonical_json_string).collect();
            format!("[{}]", inner.join(","))
        }
        _ => value.to_string(),
    }
}
```

**Content-based task idempotency key generation:**
```rust
fn generate_task_idempotency_key(&self, kind: &str, input: &Value) -> String {
    use sha2::{Digest, Sha256};
    let canonical = canonical_json_string(input);
    let mut hasher = Sha256::new();
    hasher.update(self.agent_execution_id.as_bytes());
    hasher.update(b":");
    hasher.update(kind.as_bytes());
    hasher.update(b":");
    hasher.update(canonical.as_bytes());
    let hash = hasher.finalize();
    format!("task:{}", hex::encode(&hash[..16]))
}

fn task_id_from_idempotency_key(&self, idempotency_key: &str) -> Uuid {
    Uuid::new_v5(&Uuid::NAMESPACE_OID, idempotency_key.as_bytes())
}
```

**Entry creation uses random UUIDs:**
```rust
async fn append_entry(&self, role: EntryRole, content: &Value) -> Result<Uuid> {
    let parent_id = *self.leaf_entry_id.read();
    let entry_id = Uuid::new_v4();  // Random UUID, no counter

    self.add_pending_command(AgentCommand::AppendEntry {
        entry_id,
        parent_id,
        role: role.as_str().to_string(),
        content: content.clone(),
    });

    *self.leaf_entry_id.write() = Some(entry_id);
    Ok(entry_id)
}
```

**Task scheduling uses content-based hashing:**
```rust
fn schedule_with_options_raw(&self, task_kind: &str, input: Value, options: ScheduleAgentTaskOptions) -> AgentTaskFutureRaw {
    let idempotency_key = self.generate_task_idempotency_key(task_kind, &input);
    let task_id = self.task_id_from_idempotency_key(&idempotency_key);

    self.add_pending_command(AgentCommand::ScheduleTask {
        task_id,
        kind: task_kind.to_string(),
        input: input.clone(),
        options: TaskOptions { ... },
        idempotency_key,
    });

    AgentTaskFutureRaw::new(task_id, task_kind.to_string(), input)
}
```

### `flovyn-server/server/src/api/grpc/agent_dispatch.rs`

**Server derives task_id from idempotency_key:**
```rust
let task_id = idempotency_key
    .as_ref()
    .map(|key| Uuid::new_v5(&Uuid::NAMESPACE_OID, key.as_bytes()))
    .unwrap_or_else(Uuid::new_v4);
```

### Agent Code Pattern

Agents must check for resume to avoid duplicate entries:

```rust
async fn execute(&self, ctx: &dyn AgentContext, input: DynamicAgentInput) -> Result<DynamicAgentOutput> {
    // Check if resuming (have existing entries)
    let existing_entries = ctx.load_messages();
    let is_resuming = !existing_entries.is_empty();

    // Only create entries on first run
    if !is_resuming {
        ctx.append_entry(EntryRole::User, &json!({"text": "Hello"})).await?;
    }

    // Task scheduling is idempotent - no resume check needed
    let future = ctx.schedule_raw("task", json!({"key": "value"}));
    let result = ctx.join_all(vec![future]).await?;

    // ... rest of agent
}
```

For multi-phase agents, use checkpoint state:

```rust
let state = ctx.state();
let phase = state.as_ref()
    .and_then(|s| s.get("phase"))
    .and_then(|v| v.as_str())
    .unwrap_or("init");

match phase {
    "init" => {
        if ctx.load_messages().is_empty() {
            ctx.append_entry(EntryRole::User, &content).await?;
        }
        // ... do work
        ctx.checkpoint(&json!({"phase": "phase2"})).await?;
    }
    "phase2" => {
        // Skip entries already created in previous phases
        // ...
    }
    _ => {}
}
```

---

## Test Coverage

Tests in `flovyn-server/server/tests/integration/agent_execution_tests.rs`:

1. **`test_entry_counter_collision_fix`** - Verifies entry roles after multi-turn with signals
   - Creates agent with 2 entries before suspend (production pattern)
   - Sends signal with user message
   - Verifies 4 entries with correct roles: user, assistant, user (from signal), assistant

2. **`test_entry_idempotency_on_resume`** - Verifies entries not duplicated on resume

3. **`test_task_idempotency_on_resume`** - Same task returns same result after resume

4. **`test_react_style_agent_no_duplicate_entries`** - Multi-phase agent doesn't duplicate entries

5. **`test_tool_suspension_does_not_create_error_entry`** - Suspension doesn't create error entries

---

## Analysis: Why Content-Based Hashing for Tasks

### Problem with Counter-Based Task IDs

Counter-based task IDs fail with:
- **Branching:** Different branches, same counter → collision
- **Conditional scheduling:** If task scheduled conditionally, counters shift

### Why Content-Based Hashing Works

| Scenario | Counter-Based | Content-Based |
|----------|---------------|---------------|
| Resume | Works | Works |
| Local mode | Works | Works |
| Branching | FAILS | Works |
| Conditional | FAILS | Works |

Content-based key: `hash(agent_id + kind + canonical_json(input))`

Ensures:
- Same task + same input → same key → idempotent
- Different tasks → different keys → no collision
- JSON ordering normalized via canonical serialization

### Edge Case: Intentional Duplicates

If agent intentionally schedules the same task twice with same input, they get the same result. To differentiate, add a distinguishing field:

```rust
ctx.schedule_raw("task", json!({"data": data, "instance": 1}));
ctx.schedule_raw("task", json!({"data": data, "instance": 2}));
```

---

## Bug 2: Timestamp Serialization (FIXED)

### Observed Symptoms

Production agents after deploying the entry collision fix:
- Agent stuck in WAITING status
- Multiple LLM tasks (11+) but agent never progresses
- Only 1 entry visible (initial user message)
- All checkpoints have same `leaf_entry_id`

Initially misdiagnosed as "entries not being created" or "deployment mismatch".

### ACTUAL ROOT CAUSE: Timestamps Break Content-Based Hashing

The "Entries Not Created After Task Resume" issue was misdiagnosed. The actual root cause is **different task IDs on resume due to timestamp fields in Message serialization**.

### The Real Problem

Content-based task idempotency relies on hashing the task input to generate a stable task ID:

```rust
fn generate_task_idempotency_key(&self, kind: &str, input: &Value) -> String {
    let canonical = canonical_json_string(input);
    let mut hasher = Sha256::new();
    hasher.update(self.agent_execution_id.as_bytes());
    hasher.update(b":");
    hasher.update(kind.as_bytes());
    hasher.update(b":");
    hasher.update(canonical.as_bytes());  // <-- Problem: input contains timestamp
    // ...
}
```

For LLM tasks, the `input` is the serialized `Vec<Message>`. The `Message` enum has timestamp fields:

```rust
pub enum Message {
    User {
        content: UserContent,
        timestamp: u64,  // <-- This gets serialized to JSON
    },
    // ...
    ToolResult {
        // ...
        timestamp: u64,  // <-- This too
    },
}
```

### How Timestamps Break Idempotency

**First Run:**
1. Agent creates `Message::user_text("Hello")` which calls `now_millis()` → timestamp = 1707900000000
2. LLM task input is serialized: `{"messages": [{"role": "user", "content": "Hello", "timestamp": 1707900000000}]}`
3. Hash computed → task_id = `1eff653a-...`
4. Task scheduled, agent suspends

**Resume (seconds later):**
1. Agent reconstructs messages from entries
2. `Message::user_text("Hello")` is called again → `now_millis()` → timestamp = 1707900003000 (DIFFERENT!)
3. LLM task input serialized: `{"messages": [{"role": "user", "content": "Hello", "timestamp": 1707900003000}]}`
4. Hash computed → task_id = `c83de527-...` (DIFFERENT!)
5. **NEW task scheduled instead of finding existing one**
6. Agent suspends again, waiting for the NEW task
7. Meanwhile, original task completes but agent is waiting for wrong task ID
8. **Loop repeats forever**: each resume creates new task, never sees completed results

### Evidence

Debug logs showed different task IDs between runs:

```
[FIRST RUN] generate_task_idempotency_key: task_id=1eff653a-...
[RESUME]    generate_task_idempotency_key: task_id=c83de527-...  // DIFFERENT!
```

### Why This Wasn't Caught by Tests

Integration tests use `EchoTask` which has simple JSON input (no timestamps). The bug only manifests when:
1. Task input contains `Message` objects
2. Messages are reconstructed from entries on resume (calling `now_millis()` again)

### Why `now_millis()` Gets Called Each Time

The `Message::user_text()` constructor always calls `now_millis()`:

```rust
impl Message {
    pub fn user_text(text: &str) -> Self {
        Message::User {
            content: UserContent::Text(text.to_string()),
            timestamp: now_millis(),  // <-- Called EVERY time Message is created
        }
    }
}
```

When agent resumes, it reconstructs messages from entries:
```rust
let messages = ctx.load_messages();  // Reconstructs from entries
// Each message reconstruction calls Message::user_text() → now_millis()
```

### Analysis of Fix Options

#### Option 1: Skip Serializing Timestamps (Quick Fix)

```rust
#[serde(skip_serializing, default)]
timestamp: u64,
```

**Pros:**
- Simple, one-line change
- Messages with different timestamps serialize identically
- Fixes the idempotency problem

**Cons:**
- Timestamps are never persisted anywhere
- Timestamps are never sent to frontend
- Information loss - we can't track when messages were created
- Band-aid that masks a design issue

#### Option 2: Preserve Timestamps Through Round-Trip (Proper Fix)

Store timestamps in entries and restore them when loading:

```rust
// When saving entry
let entry_content = json!({
    "text": text,
    "timestamp": message.timestamp(),  // <-- Persist timestamp
});

// When loading entry
let timestamp = entry["timestamp"].as_u64().unwrap_or_else(now_millis);
Message::user_with_timestamp(text, timestamp)
```

**Pros:**
- Timestamps are preserved across restarts
- No information loss
- Clean round-trip semantics

**Cons:**
- Requires changes to entry storage format
- May require migration for existing entries
- More code changes

#### Option 3: Don't Use Messages in Task Input

Pass only the content to LLM tasks, not full Message objects:

```rust
// Instead of:
let input = json!({"messages": messages});

// Use:
let input = json!({"contents": messages.iter().map(|m| m.content_only()).collect()});
```

**Pros:**
- Task input never contains timestamps
- Clean separation between message metadata and content

**Cons:**
- Requires refactoring task input format
- LLM task handler needs adjustment

### Recommended Solution

**Option 2 (Preserve Timestamps)** is the only proper fix:

1. Timestamps reflect when messages were actually created
2. Enables features that need timing information
3. No information loss
4. Clean round-trip semantics

**Option 1 (Skip Serializing) is NOT acceptable** - it's a band-aid that loses data.

### Current State of Code

**Bug is FIXED.** Timestamps are now stored in entry content and restored on load.

### Fix Applied

**Message types - all now preserve timestamps:**

| Type | Store | Load | Status |
|------|-------|------|--------|
| User | `json!({"text", "timestamp"})` | `entry_to_message` extracts timestamp | **FIXED** |
| Assistant | `serde_json::to_value(&assistant_message)` | `serde_json::from_value::<AssistantMessage>` | **OK** (was already working) |
| ToolResult | `ctx.append_entry` with `json!({"toolCallId", "tool_name", "output", "timestamp"})` | `Message::tool_result_with_timestamp()` | **FIXED** |

**Changes made:**

**agent-worker/src/workflows/agent.rs:**
- Line 346: Added timestamp to User entry content
- Lines 241-254: Changed ToolResult to use `append_entry` with timestamp instead of `append_tool_result_with_id`
- Lines 291-310: Same for tool execution results
- `entry_to_message` for ToolResult: Now uses `Message::tool_result_with_timestamp()` to restore timestamp from entry

**agent-worker/src/llm/types.rs:**
- Added `Message::tool_result_with_timestamp()` method for reconstruction from entries

**sdk-rust:**
- No changes needed - agent-worker uses `append_entry` directly for full control

**flovyn-server:**
- No changes needed - just stores/retrieves JSON content

### Test Coverage

Tests in `agent-worker/src/workflows/agent.rs`:

- `test_user_entry_timestamp_preserved` - User message timestamp restored from entry
- `test_tool_result_entry_timestamp_preserved` - ToolResult message timestamp restored from entry
- `test_messages_serialize_identically_after_roundtrip` - Messages serialize identically before/after entry round-trip

---

## Summary of All Issues in This Bug Report

| Issue | Root Cause | Status |
|-------|------------|--------|
| Entry counter collision | Counter-based IDs collide when code paths diverge | FIXED (random UUIDs) |
| Task ID collision | Counter-based IDs fail on branching/conditional | FIXED (content-based hash) |
| Duplicate LLM tasks on resume | Timestamp in Message serialization changes on each construction | FIXED (timestamps stored in entries, restored on load) |
| Agent restarts loop on resume | agent-worker ReactAgent doesn't track phase, always restarts | FIXED (saves pending tools in checkpoint, resumes from saved state) |

---

## Bug 3: Agent Restarts Loop on Resume (FIXED)

### Observed Symptoms

Production agent shows:
- 3 assistant entries but 0 tool_result entries
- 5 completed tasks (3 llm-request, 2 bash)
- Agent in WAITING status

### Root Cause

The agent-worker's `ReactAgent` does NOT track execution phase. On resume, it always restarts the main loop from the beginning.

### How This Causes Missing tool_result Entries

**First run:**
1. `messages = [user]` (from input)
2. Schedule LLM with `messages = [user]` → task_id_1
3. LLM completes, assistant message with tool_calls
4. Create assistant entry
5. `messages = [user, assistant]`
6. Schedule tool → SUSPENDS

**Resume:**
1. Load entries = [user, assistant]
2. Reconstruct `messages = [user, assistant]` ← DIFFERENT from first run!
3. Loop starts from beginning
4. Schedule LLM with `messages = [user, assistant]` → task_id_2 ← DIFFERENT TASK!
5. New LLM call, new assistant message
6. Create NEW assistant entry (duplicate!)
7. Schedule new tool → SUSPENDS
8. Original tool's result is NEVER processed

The agent never reaches the code that creates tool_result entries because it restarts the loop on every resume.

### Evidence

Server integration test `test_react_style_agent_no_duplicate_entries` PASSES because its test agent `ReactStyleAgent` tracks phases using `ctx.state()`:

```rust
// ReactStyleAgent (test agent) - CORRECT
let state = ctx.state();
let after_llm = state.as_ref().and_then(|s| s.get("after_llm")).and_then(|v| v.as_bool()).unwrap_or(false);

if !after_llm {
    // Only run LLM on first run
    // ...
    ctx.checkpoint(&json!({"after_llm": true})).await?;
}

// Always process tool (idempotent)
let tool_result = ctx.join_all(vec![tool_future]).await;
```

But agent-worker's `ReactAgent` does NOT track phases:

```rust
// ReactAgent (production) - BUGGY
let is_resuming = !ctx.load_messages().is_empty();
// Only skips USER entry creation, NOT LLM call!

loop {
    // Always schedules LLM from beginning
    let llm_future = ctx.schedule_raw("llm-request", serde_json::to_value(&llm_input)?);
    // ...
}
```

### Why Content-Based Idempotency Doesn't Help

Content-based task idempotency uses `hash(agent_id + kind + canonical_json(input))`.

On first run: `hash(agent_id + "llm-request" + [user])`
On resume: `hash(agent_id + "llm-request" + [user, assistant])` ← DIFFERENT!

Because `messages` includes the previously created assistant entry, the hash is different, so a NEW task is scheduled.

### Fix Applied

The agent-worker's `ReactAgent` now saves pending tool calls in checkpoint state before suspending:

**agent-worker/src/workflows/agent.rs:**

1. **At start of execute()**: Check for pending tool calls from checkpoint:
```rust
let pending_tool_calls: Option<Vec<(String, String, Value)>> = checkpoint_state
    .as_ref()
    .and_then(|s| s.get("pendingToolCalls"))
    .and_then(|v| v.as_array().map(|arr| {
        // Parse tool calls from JSON
    }));
let pending_tool_index: usize = checkpoint_state
    .as_ref()
    .and_then(|s| s.get("pendingToolIndex"))
    .and_then(|v| v.as_u64())
    .unwrap_or(0) as usize;
```

2. **Before suspending**: Save pending tool calls:
```rust
if let Err(FlovynError::AgentSuspended(msg)) = &result {
    let tool_calls_json: Vec<Value> = tool_calls
        .iter()
        .map(|(id, name, args)| json!({"id": id, "name": name, "args": args}))
        .collect();
    ctx.checkpoint(&json!({
        "messageCount": messages.len(),
        "totalUsage": total_usage,
        "pendingToolCalls": tool_calls_json,
        "pendingToolIndex": i
    }))
    .await?;
    return Err(FlovynError::AgentSuspended(msg.clone()));
}
```

3. **On resume**: Process pending tools directly, skipping LLM:
```rust
if let Some(tool_calls) = pending_tool_calls {
    for (i, (id, name, args)) in tool_calls.iter().enumerate().skip(pending_tool_index) {
        // Process remaining tools from where we left off
        let tool_future = ctx.schedule_raw(name, args.clone());
        let result = ctx.join_all(vec![tool_future]).await;
        // Create tool_result entry...
    }
    // Clear pending state after completing
    ctx.checkpoint(&json!({"messageCount": messages.len()})).await?;
}
```

### Test Coverage

**Integration test:**
- `test_tool_result_entry_with_timestamp_persisted` in `flovyn-server/server/tests/integration/agent_execution_tests.rs` verifies that `append_entry(EntryRole::ToolResult, ...)` with timestamps works correctly.

**Unit tests in `agent-worker/src/workflows/agent.rs`:**

1. `test_tool_result_entry_created_after_tool_execution` - Verifies tool_result entries are created after tool execution.

2. `test_resume_with_pending_tools_processes_them_directly` - Verifies that resuming with pending tools in checkpoint state processes them directly instead of calling LLM again. This is the core Bug 3 fix test.

3. `test_resume_with_pending_tools_resuspends_if_task_still_pending` - Verifies that if the task is still pending on resume, the agent re-suspends with updated checkpoint state.

4. `test_resume_with_multiple_pending_tools_processes_all` - Verifies that when multiple tools are pending, all are processed in order.

5. `test_resume_with_partial_pending_tools_continues_from_index` - Verifies that resuming mid-way through tool execution (e.g., at index 1 of 2) continues from that index, not from 0.

---

## Migration Notes

- No database migration required
- Existing agents work but may create duplicate entries on resume until updated to use resume check
- Server's task idempotency continues to work (just uses content-based key format instead of counter)
