# Entry Duplication on Agent Resume

**Date:** 2026-02-12
**Status:** Identified, Fix Planned
**Severity:** Critical
**Related Plan:** `dev/docs/plans/20260212_durable_agent_bugfixes.md`

## Summary

When an agent execution suspends (waiting for signal or task completion) and resumes, the `append_entry()` calls during replay create duplicate entries because there is no idempotency mechanism for entries.

## Reproduction

1. Create agent execution with `react-agent` kind
2. Send initial user message
3. Agent processes and makes LLM call
4. Agent schedules a tool task and suspends
5. Tool task completes, agent resumes
6. Agent makes another LLM call
7. Observe: entries from steps 3-4 are duplicated

**Example execution:** `5142b5bb-c627-45ba-82f4-9cb0677bf4a3`
- Expected: 6 assistant entries (one per LLM request)
- Actual: 60 assistant entries (10x duplication due to multiple suspend/resume cycles)

## Root Cause Analysis

### Investigation Steps

1. **Checked checkpoint state:** Checkpoint only stores `messageCount`, `totalUsage`, `waitingForInput` - NOT the entries themselves. Entries are stored separately in `agent_entry` table.

2. **Compared with task scheduling:** `schedule_task_raw()` uses idempotency keys:
   ```rust
   fn generate_task_idempotency_key(&self) -> String {
       format!(
           "{}:{}:{}",
           self.agent_execution_id,
           self.current_checkpoint_seq,
           self.task_index
       )
   }
   ```
   This prevents duplicate task creation on resume.

3. **Verified entry append has no idempotency:**
   ```rust
   async fn append_entry(&self, ...) -> Result<Uuid> {
       // Directly creates entry - no idempotency check
       let request = AppendEntryRequest { ... };
       let response = self.client.append_entry(request).await?;
       Ok(Uuid::parse_str(&response.entry_id)?)
   }
   ```

### Why Tasks Have Idempotency But Entries Don't

The original design (`20260210_durable_agent_system.md`) specifies:
- **Tasks:** "For tasks, generate deterministic idempotency key from `{agent_execution_id}:{checkpoint_seq}:{task_index}`"
- **Entries:** "Entries are persisted immediately via `append_entry()`" - no mention of idempotency

This was an oversight - the design assumed entries would be naturally idempotent because the agent logic is deterministic. However, on resume, the entire agent loop replays from the beginning, re-executing `append_entry()` calls for entries that already exist.

## Impact

1. **Database bloat:** 10x storage for entries
2. **UI confusion:** Duplicate messages displayed to user
3. **Token counting:** Total usage appears 10x higher than reality
4. **Potential replay divergence:** If LLM context is affected by duplicate entries

## Fix Approach

See `dev/docs/plans/20260212_durable_agent_bugfixes.md` Phase 1 for detailed implementation plan.

Key changes:
1. Add `idempotency_key` column to `agent_entry` table
2. Generate deterministic key: `cp{checkpoint_seq}:e{entry_index}`
3. On `append_entry()`, return existing entry if key matches

## Workaround (Temporary)

If needed before fix is deployed:
1. Manual deduplication query:
   ```sql
   DELETE FROM agent_entry a
   USING agent_entry b
   WHERE a.id > b.id
     AND a.agent_execution_id = b.agent_execution_id
     AND a.entry_type = b.entry_type
     AND a.content::text = b.content::text
     AND a.parent_id IS NOT DISTINCT FROM b.parent_id;
   ```
   **Warning:** This is destructive and may not handle all cases correctly.

2. Restart agent worker after each completion to prevent accumulation across executions.

## Related Issues

- **Empty LLM responses:** Separate issue where deepseek model returns `content: []` with `usage: {input: 0, output: 0}`. See same plan document Phase 2.

## Test Case for Verification

```rust
#[tokio::test]
async fn test_entry_idempotency_on_resume() {
    // Setup: Create agent, append entry with idempotency key
    let agent_id = create_test_agent().await;
    let key = "cp1:e0";

    let entry1 = append_entry(agent_id, "user", "Hello", key).await;

    // Simulate resume: append same entry again
    let entry2 = append_entry(agent_id, "user", "Hello", key).await;

    // Verify: same entry returned, no duplicate created
    assert_eq!(entry1.id, entry2.id);

    let all_entries = list_entries(agent_id).await;
    assert_eq!(all_entries.len(), 1);
}
```
