# Durable Agent System Bug Fixes

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix critical bugs discovered during durable agent system testing, specifically entry duplication on resume and empty LLM response handling.

**Related:** See `dev/docs/design/20260210_durable_agent_system.md` and `dev/docs/plans/20260211_durable_agent_system.md` for context.

---

## Critical Issues Discovered

### Issue 1: Entry Duplication on Resume (CRITICAL)

**Symptom:** Execution `5142b5bb-c627-45ba-82f4-9cb0677bf4a3` has 6 LLM requests but 60 assistant entries (10x duplication). Same pattern with tool results: 5 tool tasks but 30 tool_result entries.

**Root Cause:** When an agent suspends (for signal or task) and resumes, the execution flow replays from the beginning. Each call to `append_entry()` creates a new entry without checking if an equivalent entry already exists. Unlike `schedule_task_raw()` which uses idempotency keys, entries have no such protection.

**Impact:**
- Database bloat (10x entry storage)
- Incorrect message history displayed in UI
- Token counting becomes wildly inaccurate
- Replay divergence if entries affect LLM context

**Fix:** Add entry-level idempotency using a deterministic key based on checkpoint sequence and entry index within that checkpoint.

### Issue 2: Empty LLM Response Handling (HIGH)

**Symptom:** deepseek-v3.2 via openrouter returned `content: []` with `usage: {input: 0, output: 0}`. The agent accepted this as a valid "no tool calls" response and moved on, but this is clearly an API error.

**Root Cause:** No validation that LLM responses contain meaningful content. Zero tokens and empty content array should be treated as an error, not a valid response.

**Impact:**
- Agent completes without doing useful work
- Wastes API calls
- Confuses users who see no output

**Fix:** Detect anomalous responses (empty content, zero tokens) and retry with exponential backoff.

### Issue 3: Concurrent Resume Protection (MEDIUM)

**Symptom:** Potential for duplicate workers if scheduler retries resume the same agent execution.

**Root Cause:** No execution-level locking on resume. While `find_lock_and_mark_running()` provides atomic claim for initial poll, resume from WAITING state may not have the same protection.

**Impact:** Could create divergent execution paths if two workers process the same agent.

**Fix:** Ensure atomic state transition when resuming from WAITING state.

---

## Known Limitations (Documented, Not Fixed)

These are fundamental limitations that should be documented but are out of scope for this fix:

1. **LLM Non-Determinism:** Even with identical prompts, LLMs return different responses. The system cannot guarantee identical replay - it reconstructs from stored entries, not by re-executing LLM calls.

2. **External State Changes:** If a tool reads external state (files, APIs) that changes between suspend and resume, results will differ. This is inherent to any durable execution system.

3. **Context Window Overflow:** When conversation exceeds model's token limit, truncation strategy is model-dependent. Currently handled by the agent workflow, not the framework.

4. **Long-Running Agent Memory:** For agents with thousands of entries, loading all entries on resume could cause memory pressure. Pagination is a future enhancement.

5. **Task Timeout During Suspend:** If a scheduled task times out while agent is suspended, behavior is currently undefined. Tasks should complete or fail, triggering agent resume.

---

## Phase 1: Entry Idempotency

**Outcome:** Entries are created with idempotency keys; duplicate appends on resume are ignored.

### Task 1.1: Database Migration — Entry Idempotency

**Files:**
- Create: `flovyn-server/server/migrations/YYYYMMDDHHMMSS_agent_entry_idempotency.sql`

**Steps:**

- [ ] **Step 1.1.1**: Add idempotency key column and unique constraint:
  ```sql
  ALTER TABLE agent_entry
      ADD COLUMN idempotency_key VARCHAR(255);

  -- Unique constraint per execution
  CREATE UNIQUE INDEX idx_agent_entry_idempotency
      ON agent_entry(agent_execution_id, idempotency_key)
      WHERE idempotency_key IS NOT NULL;
  ```

- [ ] **Step 1.1.2**: Run migration
  ```bash
  cd flovyn-server && mise run build
  ```

**Commit:** `feat(server): add entry idempotency key`

### Task 1.2: Repository Update — Idempotent Entry Creation

**Files:**
- Modify: `flovyn-server/server/src/repository/agent_entry_repository.rs`

**Steps:**

- [ ] **Step 1.2.1**: Update `AgentEntryRepository::create()` to accept optional `idempotency_key`:
  - If key provided and exists, return existing entry (no insert)
  - If key provided and not exists, create with key
  - If no key, create without key (backwards compatible)

- [ ] **Step 1.2.2**: Add `find_by_idempotency_key()` method for lookups

- [ ] **Step 1.2.3**: Write tests for idempotent creation:
  - Test: create with key, create again with same key → returns same entry
  - Test: create with different keys → creates separate entries
  - Test: create without key → creates entry (no idempotency)

**Commit:** `feat(server): implement idempotent entry creation`

### Task 1.3: gRPC Update — Idempotency Key in AppendEntry

**Files:**
- Modify: `flovyn-server/server/proto/agent.proto`
- Modify: `flovyn-server/server/src/api/grpc/agent_dispatch.rs`

**Steps:**

- [ ] **Step 1.3.1**: Add `idempotency_key` field to `AppendEntryRequest`:
  ```protobuf
  message AppendEntryRequest {
      // ... existing fields ...
      optional string idempotency_key = 10;
  }
  ```

- [ ] **Step 1.3.2**: Update `AppendEntry` implementation to pass key to repository

- [ ] **Step 1.3.3**: Update `AppendEntryResponse` to indicate if entry was created or existing:
  ```protobuf
  message AppendEntryResponse {
      string entry_id = 1;
      bool already_existed = 2;  // True if idempotency key matched existing entry
  }
  ```

**Commit:** `feat(server): add idempotency key to AppendEntry gRPC`

### Task 1.4: SDK Update — Generate Entry Idempotency Keys

**Files:**
- Modify: `sdk-rust/worker-sdk/src/agent/context_impl.rs`

**Steps:**

- [ ] **Step 1.4.1**: Track entry index within current checkpoint in `AgentContextImpl`:
  ```rust
  struct AgentContextImpl {
      // ... existing fields ...
      entry_index: AtomicU32,  // Reset on checkpoint
      current_checkpoint_seq: AtomicU64,
  }
  ```

- [ ] **Step 1.4.2**: Generate idempotency key on `append_entry()`:
  ```rust
  fn generate_entry_idempotency_key(&self) -> String {
      let seq = self.current_checkpoint_seq.load(Ordering::SeqCst);
      let idx = self.entry_index.fetch_add(1, Ordering::SeqCst);
      format!("cp{}:e{}", seq, idx)
  }
  ```

- [ ] **Step 1.4.3**: Reset entry index on `checkpoint()`:
  ```rust
  async fn checkpoint(&self, state: &Value) -> Result<()> {
      // ... submit checkpoint ...
      self.current_checkpoint_seq.fetch_add(1, Ordering::SeqCst);
      self.entry_index.store(0, Ordering::SeqCst);
      Ok(())
  }
  ```

- [ ] **Step 1.4.4**: Pass idempotency key in `append_entry()` gRPC call

**Commit:** `feat(sdk): generate entry idempotency keys`

### Task 1.5: Integration Tests — Entry Idempotency

**Files:**
- Modify: `flovyn-server/tests/integration/agent_repository_test.rs`

**Steps:**

- [ ] **Step 1.5.1**: Write test for entry idempotency on resume:
  - Create agent execution
  - Append entry with idempotency key
  - Simulate suspend (checkpoint, status → WAITING)
  - Simulate resume (status → RUNNING)
  - Append same entry with same idempotency key
  - Verify only one entry exists

- [ ] **Step 1.5.2**: Run tests
  ```bash
  mise run test:integration -- agent
  ```

**Commit:** `test(server): add entry idempotency integration tests`

---

## Phase 2: Empty LLM Response Handling

**Outcome:** Empty or zero-token LLM responses are detected and retried.

### Task 2.1: LLM Response Validation

**Files:**
- Modify: `agent-worker/src/workflows/agent.rs`

**Steps:**

- [ ] **Step 2.1.1**: Add validation function for LLM responses:
  ```rust
  fn is_valid_llm_response(response: &LlmResponse) -> bool {
      // Invalid if:
      // - content is empty array
      // - usage.input == 0 AND usage.output == 0 (unless it's a valid refusal)
      // - response has error field
      if response.content.is_empty() {
          return false;
      }
      if response.usage.input_tokens == 0 && response.usage.output_tokens == 0 {
          return false;
      }
      true
  }
  ```

- [ ] **Step 2.1.2**: Wrap LLM call in retry loop:
  ```rust
  const MAX_EMPTY_RETRIES: u32 = 3;
  const EMPTY_RETRY_DELAY_MS: u64 = 1000;

  let mut attempts = 0;
  let response = loop {
      attempts += 1;
      let resp = self.call_llm(ctx, messages).await?;

      if is_valid_llm_response(&resp) {
          break resp;
      }

      if attempts >= MAX_EMPTY_RETRIES {
          return Err(AgentError::EmptyLlmResponse {
              attempts,
              last_response: resp,
          });
      }

      tracing::warn!(
          attempt = attempts,
          "LLM returned empty response, retrying"
      );
      tokio::time::sleep(Duration::from_millis(EMPTY_RETRY_DELAY_MS * attempts as u64)).await;
  };
  ```

- [ ] **Step 2.1.3**: Add error variant for empty responses:
  ```rust
  #[derive(Debug, Error)]
  pub enum AgentError {
      // ... existing variants ...
      #[error("LLM returned empty response after {attempts} attempts")]
      EmptyLlmResponse {
          attempts: u32,
          last_response: LlmResponse,
      },
  }
  ```

**Commit:** `fix(agent-worker): detect and retry empty LLM responses`

### Task 2.2: Logging and Metrics

**Files:**
- Modify: `agent-worker/src/workflows/agent.rs`

**Steps:**

- [ ] **Step 2.2.1**: Add structured logging for empty response detection:
  ```rust
  tracing::warn!(
      agent_execution_id = %ctx.agent_execution_id(),
      model = %request.model,
      attempt = attempts,
      content_length = response.content.len(),
      input_tokens = response.usage.input_tokens,
      output_tokens = response.usage.output_tokens,
      "Empty LLM response detected"
  );
  ```

- [ ] **Step 2.2.2**: Stream error event for visibility:
  ```rust
  ctx.stream_error(&format!(
      "Empty response from model (attempt {}/{}), retrying...",
      attempts, MAX_EMPTY_RETRIES
  )).await?;
  ```

**Commit:** `feat(agent-worker): add logging for empty LLM response retries`

---

## Phase 3: Concurrent Resume Protection

**Outcome:** Only one worker can resume a suspended agent execution.

### Task 3.1: Atomic Resume Transition

**Files:**
- Modify: `flovyn-server/server/src/repository/agent_repository.rs`

**Steps:**

- [ ] **Step 3.1.1**: Add `find_lock_and_resume()` method for atomic WAITING → RUNNING transition:
  ```rust
  /// Atomically claim a WAITING agent for resume.
  /// Returns None if agent is not WAITING or already claimed.
  pub async fn find_lock_and_resume(
      &self,
      pool: &PgPool,
      agent_execution_id: Uuid,
      worker_id: &str,
  ) -> Result<Option<AgentExecution>> {
      sqlx::query_as!(
          AgentExecution,
          r#"
          UPDATE agent_execution
          SET status = 'running',
              worker_id = $2,
              updated_at = NOW()
          WHERE id = $1
            AND status = 'waiting'
            AND (worker_id IS NULL OR worker_id = $2)
          RETURNING *
          "#,
          agent_execution_id,
          worker_id
      )
      .fetch_optional(pool)
      .await
  }
  ```

- [ ] **Step 3.1.2**: Use in signal handling - when signal received, use atomic transition instead of separate update

**Commit:** `feat(server): add atomic resume transition`

### Task 3.2: gRPC Update — Use Atomic Resume

**Files:**
- Modify: `flovyn-server/server/src/api/grpc/agent_dispatch.rs`

**Steps:**

- [ ] **Step 3.2.1**: Update `SignalAgent` to use atomic resume:
  - When signaling a WAITING agent, use `find_lock_and_resume()`
  - Return whether agent was successfully resumed (in case another worker got it)

- [ ] **Step 3.2.2**: Add `ResumeAgentRequest` RPC for explicit resume (if needed by worker polling):
  ```protobuf
  rpc ResumeAgent(ResumeAgentRequest) returns (ResumeAgentResponse);

  message ResumeAgentRequest {
      string agent_execution_id = 1;
      string worker_id = 2;
  }

  message ResumeAgentResponse {
      bool success = 1;
      AgentExecutionInfo agent = 2;
  }
  ```

**Commit:** `feat(server): atomic resume in SignalAgent`

---

## TODO Checklist

### Phase 1: Entry/Task Idempotency ✅
- [x] 1.1.1: Add idempotency_key column migration
- [x] 1.1.2: Run migration
- [x] 1.2.1: Update repository create() with idempotency
- [x] 1.2.2: Add find_by_idempotency_key()
- [x] 1.2.3: Write repository tests
- [x] 1.3.1: Add idempotency_key to proto
- [x] 1.3.2: Update gRPC implementation
- [x] 1.3.3: Update response with already_existed flag
- [x] 1.4.1: Track entry index in SDK context
- [x] 1.4.2: Generate idempotency key
- [x] 1.4.3: Reset entry index on checkpoint
- [x] 1.4.4: Pass key in gRPC call
- [x] 1.5.1: Write integration test for resume scenario
- [x] 1.5.2: Run tests

### Phase 1.X: Task Idempotency Counter Fix (Critical Bug) ✅

**Bug discovered:** Agent scheduling tasks would get stuck in infinite loop because `scheduled_task_counter` was initialized to the current task count instead of 0.

**Root cause:** `sdk-rust/worker-sdk/src/agent/context_impl.rs` initialized `scheduled_task_counter` to `get_agent_task_count()` on resume. This meant:
1. First execution: counter=0, task key=`:task:0`
2. Agent suspends waiting for task
3. Task completes
4. Agent resumes with counter=1 (existing task count)
5. Same `schedule_task_raw` call generates key=`:task:1` instead of `:task:0`
6. NEW task created, agent suspends again
7. Infinite loop - agent never progresses

**Fix:**
- [x] Initialize `scheduled_task_counter` to 0, like `entry_counter`
- [x] Agents MUST replay ALL `schedule_task_raw` calls from beginning on resume
- [x] Server uses idempotency keys to return existing tasks
- [x] Remove `get_agent_task_count` RPC call (no longer needed)
- [x] Add `test_task_idempotency_on_resume` integration test
  - Without fix: Agent stuck in WAITING forever (timeout)
  - With fix: Agent completes with correct entries

### Phase 2: Empty LLM Response Handling ✅
- [x] 2.1.1: Add response validation function (in `agent-worker/src/llm/providers/openai.rs`)
- [x] 2.1.2: Add retry loop with exponential backoff (provider level)
- [x] 2.1.3: Error propagates via Error event
- [x] 2.2.1: Add structured logging (tracing::warn in provider)
- [x] 2.2.2: Simplified task layer in `llm_request.rs` - safety check only, provider handles retry

### Phase 3: Concurrent Resume Protection ✅
- [x] 3.1.1: Add find_lock_and_resume() repository method (`flovyn-server/server/src/repository/agent_repository.rs`)
- [x] 3.1.2: Signal handling keeps using resume() (sets to PENDING) - appropriate since signals don't have worker_id
- [x] 3.2.1: Task completion uses resume() (server-side, no worker_id) - atomic claim happens on next poll
- [x] 3.2.2: Add ResumeAgent RPC - allows workers to atomically claim WAITING agents directly
  - Added to proto: `sdk-rust/proto/agent.proto` and `flovyn-server/server/proto/agent.proto`
  - Implemented handler in `flovyn-server/server/src/api/grpc/agent_dispatch.rs`
  - Added `agent_resumed` event in `flovyn-server/server/src/streaming/event.rs`

---

## Test Plan

| Phase | Test Type | Description |
|-------|-----------|-------------|
| Phase 1 | Integration | Entry idempotency on resume - duplicate appends ignored |
| Phase 1 | Integration | Entry without key - backwards compatible |
| Phase 2 | Unit | Empty response detection |
| Phase 2 | Integration | Retry logic triggers on empty response |
| Phase 3 | Integration | Race condition - two workers try to resume same agent |

---

## Rollout Notes

1. **Database Migration:** Phase 1 migration is additive (new nullable column). Safe to deploy without downtime.

2. **Backwards Compatibility:**
   - Old agents without idempotency keys continue to work (null key = no idempotency)
   - New agents with idempotency keys get duplicate protection

3. **Monitoring:** Add metrics for:
   - `agent_entry_duplicates_prevented` - count of idempotent appends that returned existing
   - `agent_llm_empty_responses` - count of empty response retries
   - `agent_resume_conflicts` - count of failed resume due to concurrent claim
