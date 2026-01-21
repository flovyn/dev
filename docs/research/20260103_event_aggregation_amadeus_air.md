# Event Aggregation for Multi-Part Webhooks (Amadeus AIR)

**Date:** 2026-01-03
**Status:** Research
**Related:** [Eventhook Design](../design/20260103_eventhook_milestone3_advanced_routing.md), [Unified Idempotency](../design/20260101_unified_idempotency.md)

## Problem Statement

When receiving Amadeus AIR files via webhooks:

1. A single PNR change can generate **multiple files** (e.g., 1/3, 2/3, 3/3 for multi-passenger PNR)
2. Each file is pushed as a **separate webhook call**
3. We want **one workflow** to process all related files together, not 3 separate workflows
4. The workflow should **wait until all files are received** before processing

This is a general **event aggregation** or **event batching** pattern applicable beyond Amadeus.

## Key Data Elements in AIR Files

AIR files are **text-based**, not JSON. Example file:

```
AIR-BLK208;7A;;245;0000000000;1A1247886;001001
AMD 2600004503;1/3;
1A1247886;1A1247886;TLNCD2105;AIR
MUC1A Y9WMVX006;0301;TLNCD2105;20288262;...
A-ROYAL AIR MAROC;AT 1470
B-TTP/RT
...
```

Key fields for aggregation (parsed from text):

| Line | Pattern | Example | Meaning |
|------|---------|---------|---------|
| 2 | `AMD {changeId};{seq}/{total};` | `AMD 2600004503;1/3;` | Change ID, sequence info |
| 4 | `MUC1A {pnr}...` | `MUC1A Y9WMVX006;...` | PNR locator (Y9WMVX) |

**Webhook payload structure:**

The webhook sends JSON containing only the file path:

```json
{
  "path": "/path/to/AIR_6259512701_TLNCD2105_01DBE6A85ACF7080_5833E018.AIR"
}
```

This means:
- Eventhook cannot parse AIR content (it only sees the path)
- Eventhook cannot determine sequence number for routing
- **All aggregation logic must happen in the worker (task or workflow)**

**Implication:** We cannot use filter patterns to route based on sequence number. Instead:
- Every webhook triggers the **same task**
- Task reads the file, parses it, and handles aggregation
- When all files collected, task starts the processing workflow

## Solution Options

Since the webhook only contains the file path (not content), the workflow must:
1. Read the file from disk
2. Parse to extract `changeId`, `sequenceNumber`, `totalSequences`
3. Handle aggregation logic

This creates a chicken-and-egg problem: we need `changeId` for idempotency, but it's inside the file.

### Option 1: Workflow-only with Child Workflow Idempotency (Recommended)

**Requires:** Adding `idempotency_key` to `ScheduleChildWorkflowCommand` (enhancement to Flovyn)

**Approach:** Each file triggers a workflow. The workflow reads the file, schedules a child aggregator workflow (with idempotency key), and resolves a promise. The child workflow collects all files via promises.

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Webhook (file path) arrives                      │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Eventhook triggers "handle-air-file" WORKFLOW                       │
│   - idempotencyKey: file path (handles webhook retries)             │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Workflow: handle-air-file                                            │
│   1. Read file (ctx.run_raw)                                        │
│   2. Parse AMD line → changeId, seq, total                          │
│   3. Schedule child "process-pnr-change" with idempotency key       │
│      (first workflow wins, others get existing child)               │
│   4. Resolve promise on child workflow                              │
└─────────────────────────────────────────────────────────────────────┘
                                │
           ┌────────────────────┼────────────────────┐
           │                    │                    │
     (file 1/3)           (file 2/3)           (file 3/3)
     creates child        child exists         child exists
     resolves :1          resolves :2          resolves :3
                                                     │
                                                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Child Workflow: process-pnr-change (aggregator)                     │
│   - Creates promises with keys "amadeus:{changeId}:1", :2, :3      │
│   - Waits for all promises (with timeout)                           │
│   - Processes complete PNR change                                   │
└─────────────────────────────────────────────────────────────────────┘
```

**Required Enhancements:**

1. **Add `idempotency_key` to `ScheduleChildWorkflowCommand`:**

```protobuf
message ScheduleChildWorkflowCommand {
  string child_execution_name = 1;
  optional string workflow_kind = 2;
  optional string workflow_definition_id = 3;
  string child_workflow_execution_id = 4;
  bytes input = 5;
  string queue = 6;
  int32 priority_seconds = 7;
  optional string idempotency_key = 8;  // NEW: key-based idempotency
}
```

2. **Add `ResolvePromiseByKeyCommand` to allow workflows to resolve promises by key:**

```protobuf
message ResolvePromiseByKeyCommand {
  string idempotency_key = 1;  // Promise idempotency key
  bytes value = 2;             // Value to resolve with
}
```

**Handler workflow implementation:**

```rust
pub struct HandleAirFileWorkflow;

#[async_trait]
impl DynamicWorkflow for HandleAirFileWorkflow {
    fn kind(&self) -> &str {
        "handle-air-file"
    }

    async fn execute(
        &self,
        ctx: &dyn WorkflowContext,
        input: DynamicInput,
    ) -> Result<DynamicOutput> {
        let file_path = input.get("path").and_then(|v| v.as_str()).unwrap();

        // 1. Read and parse file
        let file_content = ctx.run_raw("read-file", json!({ "path": file_path })).await?;
        let change_id = file_content.get("changeId").and_then(|v| v.as_str()).unwrap();
        let seq = file_content.get("sequenceNumber").and_then(|v| v.as_i64()).unwrap();
        let total = file_content.get("totalSequences").and_then(|v| v.as_i64()).unwrap();

        // 2. Schedule child workflow with idempotency key (NEW)
        //    First workflow creates the child, subsequent ones get existing child
        let _child = ctx
            .schedule_workflow_with_options_raw(
                "aggregator",
                "process-pnr-change",
                json!({ "changeId": change_id, "totalSequences": total }),
                ScheduleWorkflowOptions::new()
                    .with_idempotency_key(&format!("amadeus:{}", change_id)),
            )
            .await?;

        // 3. Resolve promise by key (NEW) - resolves promise on any workflow
        let promise_key = format!("amadeus:{}:{}", change_id, seq);
        ctx.resolve_promise_by_key_raw(&promise_key, file_content.clone()).await?;

        let mut output = DynamicOutput::new();
        output.insert("status".to_string(), json!("collected"));
        Ok(output)
    }
}
```

**Aggregator workflow implementation:**

```rust
pub struct ProcessPnrChangeWorkflow;

#[async_trait]
impl DynamicWorkflow for ProcessPnrChangeWorkflow {
    fn kind(&self) -> &str {
        "process-pnr-change"
    }

    async fn execute(
        &self,
        ctx: &dyn WorkflowContext,
        input: DynamicInput,
    ) -> Result<DynamicOutput> {
        let change_id = input.get("changeId").and_then(|v| v.as_str()).unwrap();
        let total = input.get("totalSequences").and_then(|v| v.as_i64()).unwrap() as i32;

        // Collect all files via promises
        let mut files = Vec::with_capacity(total as usize);

        for seq in 1..=total {
            let promise_key = format!("amadeus:{}:{}", change_id, seq);
            let file_content: Value = ctx
                .promise_with_options_raw(
                    &format!("file-{}", seq),
                    PromiseOptions::with_key(&promise_key),
                )
                .await?;
            files.push(file_content);
        }

        // All files collected - process them
        // ... your processing logic here ...

        let mut output = DynamicOutput::new();
        output.insert("status".to_string(), json!("completed"));
        output.insert("filesProcessed".to_string(), json!(total));
        Ok(output)
    }
}
```

**Route configuration:**

```json
{
  "name": "Amadeus AIR File Handler",
  "eventTypeFilter": "amadeus.air.*",
  "target": {
    "type": "workflow",
    "workflowKind": "handle-air-file",
    "idempotencyKeyPath": "body.path"
  }
}
```

**Pros:**
- **No custom database table** - uses Flovyn's promise system
- **Pure workflow solution** - no task/HTTP client needed
- Clean SDK patterns throughout
- Promise timeout handles missing files

**Cons:**
- Requires enhancements to Flovyn (see below)
- N+1 workflows per change
- **Determinism concerns** (see below)

---

### Determinism Concern with `resolve_promise_by_key`

**Problem:** `resolve_promise_by_key` is a side effect on another workflow, which creates a race condition that breaks determinism.

**Scenario:**

```
First execution:
1. Handler workflow starts
2. Schedules child workflow (idempotency: "amadeus:123")
3. Calls resolve_promise_by_key("amadeus:123:1", value)
   → Child hasn't created promise yet → ERROR (404)
4. Workflow fails

Replay (later, after child has started):
1. Handler workflow replays
2. Schedules child workflow → already exists, OK
3. Calls resolve_promise_by_key("amadeus:123:1", value)
   → Child has created promise → SUCCESS
4. Workflow continues differently!
```

**This is non-deterministic** - behavior differs between first execution and replay.

**Root cause:** Race condition between:
- Handler scheduling child and immediately resolving promise
- Child workflow creating the promise

**Solutions for determinism:**

| Solution | Description | Complexity |
|----------|-------------|------------|
| A. Wrap in `ctx.run_raw()` | Record result, replay uses recorded value | Medium - needs task handler |
| B. Retry until exists | `resolve_promise_by_key` blocks until promise exists | Medium - adds latency |
| C. Create-or-resolve | Create promise if not exists, then resolve | Low - semantic change |
| D. Use tasks instead | Tasks run once, no replay determinism issue | Low - current SDK works |

**Recommendation:** Given the complexity, **Option D (Task-based)** is safest until we design proper determinism handling for cross-workflow promise resolution.

---

### Option 1b: Task + Workflow (Recommended - Current SDK)

**No Flovyn enhancements required.** Tasks run once (no replay), avoiding determinism issues.

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Webhook (file path) arrives                      │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Eventhook triggers "collect-air-file" TASK                          │
│   - idempotencyKey: file path (handles webhook retries)             │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Task: collect-air-file (runs ONCE, no replay)                       │
│   1. Read file from path                                            │
│   2. Parse AMD line → changeId, seq, total                          │
│   3. HTTP: Start workflow with idempotency key                      │
│   4. HTTP: Resolve promise by key                                   │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Workflow: process-pnr-change (aggregator)                           │
│   - Creates promises with idempotency keys                          │
│   - Waits for all promises (tasks resolve them via HTTP)            │
│   - Processes complete PNR change                                   │
└─────────────────────────────────────────────────────────────────────┘
```

**Task implementation:**

```rust
pub struct CollectAirFileTask;

#[async_trait]
impl DynamicTask for CollectAirFileTask {
    fn kind(&self) -> &str {
        "collect-air-file"
    }

    async fn execute(
        &self,
        input: Map<String, Value>,
        _ctx: &dyn TaskContext,
    ) -> Result<Map<String, Value>> {
        let file_path = input.get("path").and_then(|v| v.as_str()).unwrap();

        // 1. Read and parse file
        let content = std::fs::read_to_string(file_path)?;
        let parsed = parse_air_file(&content)?;

        // 2. Start aggregator workflow via HTTP (idempotency ensures one instance)
        let http_client = reqwest::Client::new();
        http_client
            .post(&format!(
                "{}/api/orgs/{}/workflows",
                FLOVYN_URL, ORG_SLUG
            ))
            .json(&json!({
                "workflowKind": "process-pnr-change",
                "input": { "changeId": parsed.change_id, "totalSequences": parsed.total_sequences },
                "idempotencyKey": format!("amadeus:{}", parsed.change_id)
            }))
            .send()
            .await?;

        // 3. Resolve this file's promise via HTTP
        let promise_key = format!("amadeus:{}:{}", parsed.change_id, parsed.sequence_number);
        http_client
            .post(&format!(
                "{}/api/orgs/{}/promises/key:{}/resolve",
                FLOVYN_URL, ORG_SLUG, promise_key
            ))
            .json(&json!({
                "value": {
                    "sequenceNumber": parsed.sequence_number,
                    "pnrLocator": parsed.pnr_locator,
                    "content": content
                }
            }))
            .send()
            .await?;

        let mut output = Map::new();
        output.insert("status".to_string(), json!("collected"));
        Ok(output)
    }
}
```

**Aggregator workflow implementation:**

```rust
pub struct ProcessPnrChangeWorkflow;

#[async_trait]
impl DynamicWorkflow for ProcessPnrChangeWorkflow {
    fn kind(&self) -> &str {
        "process-pnr-change"
    }

    async fn execute(
        &self,
        ctx: &dyn WorkflowContext,
        input: DynamicInput,
    ) -> Result<DynamicOutput> {
        let change_id = input.get("changeId").and_then(|v| v.as_str()).unwrap();
        let total = input.get("totalSequences").and_then(|v| v.as_i64()).unwrap() as i32;

        // Collect all files via promises
        let mut files = Vec::with_capacity(total as usize);

        for seq in 1..=total {
            let promise_key = format!("amadeus:{}:{}", change_id, seq);
            let file_content: Value = ctx
                .promise_with_options_raw(
                    &format!("file-{}", seq),
                    PromiseOptions::with_key(&promise_key),
                )
                .await?;
            files.push(file_content);
        }

        // All files collected - process them
        // ... your processing logic here ...

        let mut output = DynamicOutput::new();
        output.insert("status".to_string(), json!("completed"));
        output.insert("filesProcessed".to_string(), json!(total));
        Ok(output)
    }
}
```

**Route configuration:**

```json
{
  "name": "Amadeus AIR File Collector",
  "eventTypeFilter": "amadeus.air.*",
  "target": {
    "type": "task",
    "taskKind": "collect-air-file",
    "idempotencyKeyPath": "body.path"
  }
}
```

**Pros:**
- **Works with current SDK** - no Flovyn changes needed
- **No determinism issues** - tasks run once
- **No custom database table** - uses promises
- Handles all edge cases

**Cons:**
- Task needs HTTP client to call Flovyn REST API
- N tasks + 1 workflow per change

---

### Option 2: Single Workflow with Internal State

**Approach:** Each file triggers the same workflow (with idempotency), workflow manages collection internally.

**Challenge:** How to get idempotency key before reading file?

**Solution:** Extract changeId from filename if possible.

Looking at filename: `AIR_6259512701_TLNCD2105_01DBE6A85ACF7080_5833E018.AIR`

If `6259512701` or `01DBE6A85ACF7080` correlates to changeId, we can use it.

```json
{
  "name": "Amadeus AIR Handler",
  "eventTypeFilter": "amadeus.air.*",
  "inputTransform": {
    "type": "javascript",
    "function": "function transform(event) { const parts = event.body.split('/').pop().split('_'); return { filePath: event.body, correlationId: parts[1] }; }"
  },
  "target": {
    "type": "workflow",
    "workflowKind": "process-pnr-change",
    "idempotencyKeyPath": "correlationId",
    "idempotencyKeyPrefix": "amadeus:"
  }
}
```

**Workflow with promise-based collection:**

```rust
#[workflow("process-pnr-change")]
async fn process_pnr_change(ctx: WorkflowContext, input: FilePathInput) -> WorkflowResult<()> {
    // Read first file
    let first_file = ctx.run("read-file", || read_air_file(&input.file_path)).await?;
    let change_id = &first_file.change_id;
    let total = first_file.total_sequences;

    let mut files = vec![first_file];

    // Create promises for remaining files
    for seq in 2..=total {
        let promise_key = format!("amadeus:{}:{}", change_id, seq);
        let file_path: String = ctx.create_promise("file")
            .with_idempotency_key(&promise_key)
            .with_timeout(Duration::from_secs(3600))
            .await?;

        let file = ctx.run(&format!("read-file-{}", seq), || read_air_file(&file_path)).await?;
        files.push(file);
    }

    // Process all files
    process_complete_change(&files).await
}
```

**Problem:** Subsequent webhooks need to resolve promises, but:
1. They don't know which promise to resolve (no changeId in path)
2. Eventhook can't read the file to find out

This approach only works if the filename contains the changeId AND sequence number.

---

### Option 3: Aggregation Buffer at Ingest Level (Future)

**Approach:** Eventhook buffers related events and starts workflow only when complete.

```
┌─────────────────────────────────────────────────────────────────────┐
│                     New Route Type: Aggregation                      │
└─────────────────────────────────────────────────────────────────────┘

{
  "name": "Amadeus AIR Aggregator",
  "eventTypeFilter": "amadeus.air.*",
  "aggregation": {
    "correlationKeyPath": "body.changeId",
    "completionCondition": {
      "type": "count_from_field",
      "countPath": "body.totalSequences"
    },
    "timeout": "PT1H",  // ISO 8601 duration
    "target": {
      "type": "workflow",
      "workflowKind": "process-pnr-change"
    }
  }
}
```

**How it works:**
1. First event creates an "aggregation session" keyed by `changeId`
2. Subsequent events with same `changeId` are added to session
3. When `count == totalSequences` OR timeout, trigger workflow with all events
4. Workflow receives array of all collected payloads

**Pros:**
- Single route configuration
- Clean separation: eventhook handles buffering, workflow handles processing
- Works even if files arrive out of order

**Cons:**
- Requires new database table for aggregation sessions
- More complex eventhook implementation
- Need to handle partial completion (timeout with n-1 files)

---

### Option 3: Dedicated Aggregator Workflow

**Approach:** Lightweight aggregator workflow that collects and forwards.

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Two-Stage Workflow                               │
└─────────────────────────────────────────────────────────────────────┘

Route 1: Start aggregator on first event
Route 2: Forward to aggregator via task

       ┌──────────┐     ┌──────────┐     ┌──────────┐
       │  1/3     │     │  2/3     │     │  3/3     │
       └────┬─────┘     └────┬─────┘     └────┬─────┘
            │                │                │
            ▼                ▼                ▼
       ┌─────────────────────────────────────────────┐
       │          Aggregator Workflow                 │
       │  - Collects files in workflow state         │
       │  - Waits for completion or timeout          │
       │  - Starts processing workflow when ready    │
       └─────────────────────────────────────────────┘
                            │
                            ▼
       ┌─────────────────────────────────────────────┐
       │          Processing Workflow                 │
       │  - Receives all files as input              │
       │  - Processes the complete change            │
       └─────────────────────────────────────────────┘
```

**Pros:**
- Separation of concerns (aggregation vs processing)
- Reusable aggregator pattern

**Cons:**
- Two workflows per change
- More moving parts
- Aggregator state management complexity

---

### Option 4: Hybrid - Smart First Event Detection

**Approach:** Route decides based on sequence number which action to take.

Using M3's filter pattern and multi-target:

```json
// Route 1: First file starts workflow
{
  "name": "AIR First File",
  "eventTypeFilter": "amadeus.air.*",
  "filterPattern": {
    "fields": {
      "sequenceNumber": 1
    }
  },
  "target": {
    "type": "workflow",
    "workflowKind": "process-pnr-change",
    "idempotencyKeyPath": "body.changeId"
  }
}

// Route 2: Subsequent files resolve promises
{
  "name": "AIR Subsequent Files",
  "eventTypeFilter": "amadeus.air.*",
  "filterPattern": {
    "fields": {
      "sequenceNumber": { "$gt": 1 }
    }
  },
  "target": {
    "type": "promise",
    "mode": "resolve",
    "idempotencyKeyPath": "...",  // Composite key needed
  }
}
```

**Challenge:** Composite idempotency key construction (`changeId:sequenceNumber`)

---

## Recommended Approach: Option 1 with Enhancements

Option 1 (Promise-Based Aggregation) aligns best with Flovyn's architecture and requires minimal new features.

### Required Enhancements

#### 1. Composite Idempotency Key Construction

Current `idempotencyKeyPath` extracts a single value. For aggregation, we need:
- `idempotencyKeyPrefix`: Static prefix (e.g., "amadeus:")
- `idempotencyKeyPath`: Main correlation field (e.g., "body.changeId")
- **NEW** `idempotencyKeySuffix`: Additional field to append (e.g., "body.sequenceNumber")

Result: `amadeus:CHG-12345:2`

Alternative: JMESPath expression for key construction:
```json
{
  "idempotencyKeyExpression": "concat('amadeus:', body.changeId, ':', to_string(body.sequenceNumber))"
}
```

#### 2. Promise Resolution Route Enhancement

The Promise target needs to pass the full payload to the promise, not just resolve it. Currently works - the `value` passed to `resolve_by_key` is the full payload.

#### 3. Workflow Receives All Files

The workflow's `create_promise().await` returns the payload from the resolving webhook. This already works.

### Implementation Steps

1. **Add `idempotencyKeySuffix` to route target configs** (small change)
2. **Create two routes:**
   - Route 1: Start workflow on `sequenceNumber == 1`
   - Route 2: Resolve promise on `sequenceNumber > 1`
3. **Write aggregator workflow** that creates promises and waits

### Workflow Example

```rust
#[workflow("process-pnr-change")]
async fn process_pnr_change(ctx: WorkflowContext, input: AirFile) -> WorkflowResult<()> {
    let change_id = &input.change_id;
    let total = input.total_sequences as usize;

    // Collect all files (first one is in input)
    let mut files = Vec::with_capacity(total);
    files.push(input);

    // Wait for remaining files via promises
    if total > 1 {
        // Create all promises first
        let futures: Vec<_> = (2..=total)
            .map(|seq| {
                let key = format!("amadeus:{}:{}", change_id, seq);
                ctx.wait_for_promise::<AirFile>(&key)
            })
            .collect();

        // Await all in parallel with timeout
        let results = ctx.race(
            ctx.all(futures),
            ctx.sleep(Duration::from_secs(3600)), // 1 hour timeout
        ).await;

        match results {
            Either::Left(collected) => {
                for file in collected? {
                    files.push(file);
                }
            }
            Either::Right(_) => {
                // Timeout - process what we have or fail
                return Err(WorkflowError::Timeout(
                    format!("Only received {}/{} files", files.len(), total)
                ));
            }
        }
    }

    // Sort files by sequence number
    files.sort_by_key(|f| f.sequence_number);

    // Process complete PNR change
    process_complete_change(&files).await?;

    Ok(())
}
```

### Route Configuration

Since AIR files are text-based, we need M3's JavaScript transform to parse them:

```json
// Route 1: First file (sequence = 1) starts workflow
{
  "name": "Amadeus AIR - Start Processing",
  "eventTypeFilter": "amadeus.air.*",
  "filterFunction": "function filter(event) { const match = event.body.match(/AMD \\d+;(\\d+)\\/(\\d+);/); return match && match[1] === '1'; }",
  "inputTransform": {
    "type": "javascript",
    "function": "function transform(event) { const lines = event.body.split('\\n'); const amdMatch = lines[1].match(/AMD (\\d+);(\\d+)\\/(\\d+);/); const mucLine = lines.find(l => l.startsWith('MUC1A ')); const pnr = mucLine ? mucLine.split(';')[0].replace('MUC1A ', '').replace(/\\d+$/, '') : null; return { changeId: amdMatch[1], sequenceNumber: parseInt(amdMatch[2]), totalSequences: parseInt(amdMatch[3]), pnrLocator: pnr, rawContent: event.body }; }"
  },
  "target": {
    "type": "workflow",
    "workflowKind": "process-pnr-change",
    "idempotencyKeyPath": "changeId",
    "idempotencyKeyPrefix": "amadeus:"
  },
  "priority": 10
}

// Route 2: Subsequent files (sequence > 1) resolve promises
{
  "name": "Amadeus AIR - Collect Files",
  "eventTypeFilter": "amadeus.air.*",
  "filterFunction": "function filter(event) { const match = event.body.match(/AMD \\d+;(\\d+)\\/(\\d+);/); return match && parseInt(match[1]) > 1; }",
  "inputTransform": {
    "type": "javascript",
    "function": "function transform(event) { const lines = event.body.split('\\n'); const amdMatch = lines[1].match(/AMD (\\d+);(\\d+)\\/(\\d+);/); const mucLine = lines.find(l => l.startsWith('MUC1A ')); const pnr = mucLine ? mucLine.split(';')[0].replace('MUC1A ', '').replace(/\\d+$/, '') : null; return { changeId: amdMatch[1], sequenceNumber: parseInt(amdMatch[2]), totalSequences: parseInt(amdMatch[3]), pnrLocator: pnr, rawContent: event.body }; }"
  },
  "target": {
    "type": "promise",
    "mode": "resolve",
    "idempotencyKeyPath": "changeId",
    "idempotencyKeyPrefix": "amadeus:",
    "idempotencyKeySuffix": "sequenceNumber"
  },
  "priority": 20
}
```

**Note:** The `inputTransform` parses the raw AIR text and extracts structured data. The transformed payload is then passed to the workflow/promise target.

---

## Edge Cases

### 1. Out-of-Order Arrival

**Scenario:** File 2/3 arrives before file 1/3

**Current behavior:**
- Route 1 doesn't match (sequenceNumber != 1)
- Route 2 matches but promise doesn't exist yet → promise resolution fails

**Solution A:** Create promises on first file, accept failure for early arrivals
- Amadeus will retry the webhook
- Eventually file 1/3 arrives and creates promises
- Retried files 2/3, 3/3 then succeed

**Solution B:** Route both to workflow with idempotency
- Workflow always starts (first one wins)
- Input contains sequence info
- Workflow creates promises and waits regardless of which file started it

**Recommendation:** Solution B is more robust but requires workflow to handle any file as the "starter".

### 2. Missing Files

**Scenario:** File 3/3 never arrives

**Solution:** Timeout in workflow
- Promise has timeout
- Workflow decides: process partial or fail

### 3. Duplicate Files

**Scenario:** File 2/3 is sent twice by Amadeus

**Solution:** Promise idempotency
- First resolution succeeds
- Second resolution is no-op (promise already resolved)

### 4. Varying Sequence Counts

**Scenario:** First file says 3 total, but only 2 actually sent

**Solution:** Timeout handles this case
- Workflow waits for file 3/3 that never comes
- Times out after configured duration
- Can choose to process 2/3 files or fail

### 5. Single-File Changes

**Scenario:** PNR change with only 1 file (totalSequences = 1)

**Solution:** Workflow handles gracefully
- No promises created
- Immediate processing

---

## Alternative: Aggregation at Eventhook Level (Future)

For future consideration, native aggregation support in eventhook:

```json
{
  "name": "Amadeus AIR Aggregator",
  "eventTypeFilter": "amadeus.air.*",
  "aggregation": {
    "enabled": true,
    "correlationKey": "body.changeId",
    "completeness": {
      "type": "field_count",
      "totalField": "body.totalSequences",
      "sequenceField": "body.sequenceNumber"
    },
    "timeout": "PT1H",
    "onComplete": {
      "type": "workflow",
      "workflowKind": "process-pnr-change"
    },
    "onTimeout": {
      "type": "workflow",
      "workflowKind": "process-pnr-change-partial",
      "includePartialData": true
    }
  }
}
```

This would require:
- New `p_eventhook__aggregation_session` table
- Background job to check timeouts
- Modified event processor to check aggregation state

**Decision:** Defer to future milestone. Promise-based approach works now.

---

## Summary

Given that the webhook only contains file paths (not content), the options are:

| Approach | Complexity | Custom DB Table | Flovyn Enhancements |
|----------|------------|-----------------|---------------------|
| **Option 1: Workflow + Child Idempotency** | Medium | No | 2 new features |
| Option 1b: Task + HTTP calls | Medium | No | None |
| Option 2: Single Workflow | Medium | No | None (needs filename pattern) |
| Option 3: Ingest buffer (future) | High | Yes | New aggregation system |

**Recommendation:** Proceed with **Option 1 (Workflow-only with Child Workflow Idempotency)**

**Required Flovyn Enhancements:**

1. **`idempotency_key` on `ScheduleChildWorkflowCommand`** - allows multiple workflows to schedule the same child (first wins)
2. **`ResolvePromiseByKeyCommand`** - allows a workflow to resolve promises by idempotency key (on any workflow)

**Implementation:**

1. **Implement `handle-air-file` workflow:**
   - Read file from path (`ctx.run_raw`)
   - Parse AMD line for changeId, seq, total
   - Schedule child `process-pnr-change` with idempotency key (NEW)
   - Resolve promise by key `amadeus:{changeId}:{seq}` (NEW)

2. **Implement `process-pnr-change` workflow (aggregator):**
   - Create promises with idempotency keys for all sequences 1..total
   - Wait for all promises (handler workflows resolve them)
   - Process complete PNR change when all files collected

3. **Configure eventhook route:**
   - Trigger `handle-air-file` workflow
   - Use file path as idempotency key (handles webhook retries)

**This approach:**
- Uses Flovyn primitives only (workflows, promises)
- **No custom database table** - promises act as the collection mechanism
- **No external HTTP calls** - pure workflow orchestration
- Handles all edge cases: out-of-order arrival, duplicates, missing files (timeout)
- Natural timeout via promise timeout configuration
