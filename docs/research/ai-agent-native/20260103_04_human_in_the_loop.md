# Human-in-the-Loop Patterns

## 4.1 Approval Flow Architecture

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

## 4.2 Approval Modes Comparison

| Framework | Modes | Caching | Modification |
|-----------|-------|---------|--------------|
| Gemini CLI | YOLO, EXPLICIT, TRUSTED_FILES | Per-session | Editor-based |
| Codex | Skip, OnFailure, OnRequest, UnlessTrusted | Per-session | Policy amendments |
| Dyad | ask, always, never (per-tool) | Persistent | Accept-always option |
| Open Interpreter | auto_run, safe_mode | None | Code editing |
| Temporal AI Agent | confirm signal | None | None |

## 4.3 Durable Approval Waits

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

## 4.4 Key Design Considerations

**Policy Granularity:**
- Per-tool (most flexible)
- Per-category (readers vs writers)
- Per-session (YOLO mode)
- Per-org (enterprise)

**Timeout Behavior:**
- Auto-deny after timeout
- Auto-approve after timeout (dangerous)
- Keep waiting indefinitely (durable)

**Approval Context:**
- What tool is being called
- With what arguments
- In what context (file paths, commands)
- Estimated risk level
