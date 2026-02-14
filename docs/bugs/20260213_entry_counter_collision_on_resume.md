# Bug: Entry Counter Collision on Agent Resume

## Date
2026-02-13

## Status
**FIXED**

## Summary
User messages sent via signals after the first turn are silently dropped due to idempotency key collision.

## Symptoms
- Second user message in UI disappears after sending
- Agent responds but ignores the user's follow-up question
- Database shows signal was consumed but user entry is missing
- Checkpoint shows correct `messageCount` but entry count is wrong

## Root Cause

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

## Migration Notes

- No database migration required
- Existing agents work but may create duplicate entries on resume until updated to use resume check
- Server's task idempotency continues to work (just uses content-based key format instead of counter)
