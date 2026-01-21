# Workflow Patterns for LLM Applications

This document covers **workflow patterns** - LLM applications with predefined code paths, as distinct from autonomous agents.

**Related documents:**
- [Developer Experience](./20260103_12_developer_experience.md) - Agent API (autonomous)
- [Content Storage Strategy](./20260103_11_content_storage_strategy.md) - Storage architecture
- [Architecture Patterns](./20260103_01_architecture_patterns.md) - Agent loop patterns

**Source:** [Anthropic - Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)

---

## Workflows vs Agents

Anthropic's distinction:

| Aspect | Workflow | Agent |
|--------|----------|-------|
| **Control flow** | Predefined code paths | LLM decides next step |
| **Developer role** | Designs the flow | Designs the goal |
| **Predictability** | High | Variable |
| **Complexity** | Lower | Higher |
| **Use case** | Well-defined tasks | Open-ended problems |

```
WORKFLOW                              AGENT
━━━━━━━━━━━━━━━━━━━━━━              ━━━━━━━━━━━━━━━━━━━━━━

Developer writes:                    Developer writes:
  input → step1 → step2 → output      input → agent_loop → output
           │        │                              │
           ▼        ▼                              ▼
         [LLM]    [LLM]                   while (!done) {
                                            llm.decide()
                                            execute(decision)
                                          }
```

---

## The Five Workflow Patterns

### 1. Prompt Chaining

Sequential LLM calls where each step processes the previous output.

```
Input → [LLM: Extract] → [LLM: Analyze] → [LLM: Format] → Output
```

**Use when:**
- Task has clear sequential subtasks
- You want to trade latency for accuracy
- Each step can be validated before proceeding

**Example: Document Processing**

```rust
// Raw Flovyn workflow - no special agent features
async fn process_document(ctx: &WorkflowContext, input: DocumentInput) -> Result<Report> {
    // Step 1: Extract key information
    let extracted = ctx.schedule_task("extract", ExtractTask {
        document: input.document,
        schema: extraction_schema(),
    }).await?;

    // Step 2: Analyze extracted data
    let analysis = ctx.schedule_task("analyze", AnalyzeTask {
        data: extracted,
        criteria: input.criteria,
    }).await?;

    // Step 3: Generate report
    let report = ctx.schedule_task("format", FormatTask {
        analysis,
        template: input.template,
    }).await?;

    Ok(report)
}
```

### 2. Routing

Classify input and direct to specialized handlers.

```
Input → [LLM: Classify] → ┬→ Handler A
                          ├→ Handler B
                          └→ Handler C
```

**Use when:**
- Different input types need different processing
- Specialized prompts/tools improve quality
- Categories are well-defined

**Example: Support Ticket Router**

```rust
async fn handle_ticket(ctx: &WorkflowContext, ticket: Ticket) -> Result<Response> {
    // Step 1: Classify
    let category = ctx.schedule_task("classify", ClassifyTask {
        content: ticket.content,
        categories: vec!["billing", "technical", "sales", "other"],
    }).await?;

    // Step 2: Route to specialized handler
    match category.as_str() {
        "billing" => ctx.schedule_task("billing_handler", BillingTask { ticket }).await,
        "technical" => ctx.schedule_task("tech_handler", TechnicalTask { ticket }).await,
        "sales" => ctx.schedule_task("sales_handler", SalesTask { ticket }).await,
        _ => ctx.schedule_task("general_handler", GeneralTask { ticket }).await,
    }
}
```

### 3. Parallelization

Run multiple LLM calls simultaneously.

**Sectioning** - Independent subtasks:
```
Input → ┬→ [LLM: Task A] → ┬→ Combine → Output
        └→ [LLM: Task B] → ┘
```

**Voting** - Same task, multiple attempts:
```
Input → ┬→ [LLM attempt 1] → ┬→ Vote/Select → Output
        ├→ [LLM attempt 2] → ┤
        └→ [LLM attempt 3] → ┘
```

**Use when:**
- Tasks are independent (sectioning)
- You need higher confidence (voting)
- Latency matters more than cost

**Example: Code Review (Sectioning)**

```rust
async fn review_code(ctx: &WorkflowContext, code: Code) -> Result<Review> {
    // Run reviews in parallel
    let (security, performance, style) = tokio::join!(
        ctx.schedule_task("security_review", SecurityTask { code: code.clone() }),
        ctx.schedule_task("performance_review", PerformanceTask { code: code.clone() }),
        ctx.schedule_task("style_review", StyleTask { code: code.clone() }),
    );

    // Combine results
    Ok(Review {
        security: security?,
        performance: performance?,
        style: style?,
    })
}
```

**Example: Translation (Voting)**

```rust
async fn translate_with_voting(ctx: &WorkflowContext, text: String) -> Result<String> {
    // Multiple translation attempts
    let translations = tokio::join!(
        ctx.schedule_task("translate_1", TranslateTask { text: text.clone(), model: "sonnet" }),
        ctx.schedule_task("translate_2", TranslateTask { text: text.clone(), model: "opus" }),
        ctx.schedule_task("translate_3", TranslateTask { text: text.clone(), model: "haiku" }),
    );

    // Vote on best translation
    let best = ctx.schedule_task("vote", VoteTask {
        candidates: vec![translations.0?, translations.1?, translations.2?],
        criteria: "accuracy and fluency",
    }).await?;

    Ok(best)
}
```

### 4. Orchestrator-Workers

Central LLM dynamically breaks down tasks and delegates.

```
Input → [LLM: Plan] → ┬→ [Worker 1] → ┬→ [LLM: Synthesize] → Output
                      ├→ [Worker 2] → ┤
                      └→ [Worker 3] → ┘
```

**Use when:**
- Task complexity is unpredictable
- Subtasks can be parallelized
- You need dynamic decomposition

**Example: Research Task**

```rust
async fn research(ctx: &WorkflowContext, query: String) -> Result<Report> {
    // Step 1: Plan research (LLM decides subtasks)
    let plan = ctx.schedule_task("plan", PlanTask {
        query: query.clone(),
        available_sources: vec!["web", "database", "documents"],
    }).await?;

    // Step 2: Execute subtasks in parallel
    let mut results = Vec::new();
    let mut handles = Vec::new();

    for subtask in plan.subtasks {
        let handle = ctx.schedule_task(&subtask.name, ResearchSubtask {
            query: subtask.query,
            source: subtask.source,
        });
        handles.push(handle);
    }

    for handle in handles {
        results.push(handle.await?);
    }

    // Step 3: Synthesize results
    let report = ctx.schedule_task("synthesize", SynthesizeTask {
        query,
        results,
    }).await?;

    Ok(report)
}
```

### 5. Evaluator-Optimizer

One LLM generates, another evaluates and provides feedback.

```
Input → [LLM: Generate] → [LLM: Evaluate] → Pass? → Output
              ▲                   │
              └───── Feedback ────┘
```

**Use when:**
- Clear evaluation criteria exist
- Iterative refinement improves quality
- You can afford multiple LLM calls

**Example: Content Generation**

```rust
async fn generate_content(ctx: &WorkflowContext, brief: Brief) -> Result<Content> {
    let max_iterations = 3;
    let mut content = ctx.schedule_task("generate", GenerateTask {
        brief: brief.clone(),
        previous_feedback: None,
    }).await?;

    for i in 0..max_iterations {
        // Evaluate
        let evaluation = ctx.schedule_task("evaluate", EvaluateTask {
            content: content.clone(),
            criteria: brief.criteria.clone(),
        }).await?;

        if evaluation.passes {
            return Ok(content);
        }

        // Refine based on feedback
        content = ctx.schedule_task("refine", RefineTask {
            content,
            feedback: evaluation.feedback,
        }).await?;
    }

    Ok(content)  // Return best effort after max iterations
}
```

---

## The Problem: Raw Workflows Miss Observability

When developers write raw Flovyn workflows, they lose agent-specific features:

| Feature | Agent API | Raw Workflow |
|---------|-----------|--------------|
| LLM call tracking | Automatic | Manual |
| Reasoning capture | ThinkingBlock stored | Lost |
| Token counting | Automatic | Manual |
| Context management | AgentContext | Manual |
| Attribution | Inferred | None |
| Time travel debug | Full support | Events only |

**The issue:** A developer writing prompt chaining shouldn't have to use the full Agent API just to get observability.

---

## Solution: `LlmTask` - A Built-in Task Type

Instead of choosing between "raw workflow" and "full agent", Flovyn provides `LlmTask` as a **built-in task type** with automatic observability.

### How It Works

```rust
// LlmTask is a task type - Flovyn handles it internally
let result = ctx.schedule_task(LlmTask {
    name: "extract",
    model: "claude-sonnet-4-20250514",
    system: Some("You are a data extraction expert..."),
    messages: vec![Message::user(&document)],
    output_schema: Some(schema_for!(ExtractedData)),
    capture_reasoning: true,  // Default: true
}).await?;

// result.output: ExtractedData (parsed)
// result.reasoning: Option<String> (thinking block)
// result.usage: TokenUsage
```

**No worker code needed.** Flovyn's built-in executor handles `LlmTask`:

```
┌─────────────────────────────────────────────────────────────┐
│                     FLOVYN SERVER                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Workflow: ctx.schedule_task(LlmTask { ... })               │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │            Built-in LlmTask Executor                 │   │
│  │                                                      │   │
│  │  1. Call LLM API (thinking enabled by default)      │   │
│  │  2. Store response → content_store                  │   │
│  │  3. Store thinking block → content_store            │   │
│  │  4. Emit event: LlmTaskCompleted { refs, tokens }   │   │
│  │  5. Return typed result to workflow                 │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### LlmTask Definition

```rust
/// Built-in task type for LLM calls with automatic observability
struct LlmTask<T> {
    // === Required ===
    name: String,                        // Task name for debugging
    model: String,                       // LLM model to use
    messages: Vec<Message>,              // Conversation messages

    // === Optional ===
    system: Option<String>,              // System prompt
    output_schema: Option<JsonSchema>,   // For structured output (T)
    capture_reasoning: bool,             // Default: true
    model_settings: ModelSettings,       // Temperature, max_tokens, etc.
}

/// Result includes output + observability data
struct LlmTaskResult<T> {
    output: T,                           // Parsed output (or String if no schema)
    reasoning: Option<String>,           // Thinking block if captured
    usage: TokenUsage,                   // Token counts
    model: String,                       // Model used
    latency_ms: u64,                     // Call duration
}
```

### Why Built-in?

| Aspect | Custom Task | Built-in LlmTask |
|--------|-------------|------------------|
| Developer writes | Task executor + worker | Just task config |
| Worker deployment | Required | Not needed |
| Observability | Must use SDK correctly | Guaranteed |
| Content storage | Manual | Automatic |
| Reasoning capture | Opt-in | Default on |

### When LlmTask Is Not Enough

`LlmTask` handles the five workflow patterns. If you need more:

| Need | Solution |
|------|----------|
| External API before LLM | Fetch in workflow, pass to `LlmTask` |
| Complex tool execution | Use Agent API |
| LLM decides next step | Use Agent API |
| Custom retry/error handling | Use Agent API |

**Example: External API + LLM (still works with LlmTask)**

```rust
async fn analyze_with_external_data(ctx: &WorkflowContext, query: String) -> Result<Analysis> {
    // Step 1: Fetch external data (regular task)
    let external_data = ctx.schedule_task(FetchTask {
        url: "https://api.example.com/data",
        query: query.clone(),
    }).await?;

    // Step 2: LLM analysis (LlmTask)
    let analysis = ctx.schedule_task(LlmTask {
        name: "analyze",
        model: "claude-sonnet-4-20250514",
        messages: vec![
            Message::user(&format!(
                "Analyze this data:\n{}\n\nQuery: {}",
                external_data, query
            )),
        ],
        ..Default::default()
    }).await?;

    Ok(analysis.output)
}
```

**When to switch to Agent API:**

```
LlmTask (workflow)              Agent API
━━━━━━━━━━━━━━━━━━━━━━         ━━━━━━━━━━━━━━━━━━━━━━

Developer controls flow    →    LLM controls flow
Fixed number of LLM calls  →    Variable LLM calls
Predictable execution      →    Dynamic execution
Simple patterns            →    Complex interactions
```

---

## Workflow Patterns with LlmTask

### Prompt Chaining with Observability

```rust
async fn process_document(ctx: &WorkflowContext, input: DocumentInput) -> Result<Report> {
    // Each LLM call is automatically tracked with full observability
    let extracted = ctx.schedule_task(LlmTask {
        name: "extract",
        model: "claude-sonnet-4-20250514",
        system: Some("Extract structured data from documents."),
        messages: vec![Message::user(&input.document)],
        output_schema: Some(schema_for!(ExtractedData)),
        ..Default::default()
    }).await?;

    // Reasoning is available for debugging
    if let Some(reasoning) = &extracted.reasoning {
        log::debug!("Extraction reasoning: {}", reasoning);
    }

    let analysis = ctx.schedule_task(LlmTask {
        name: "analyze",
        model: "claude-sonnet-4-20250514",
        messages: vec![
            Message::user(&format!(
                "Analyze this data: {:?}\nCriteria: {}",
                extracted.output, input.criteria
            )),
        ],
        ..Default::default()
    }).await?;

    let report = ctx.schedule_task(LlmTask {
        name: "format",
        model: "claude-haiku",  // Cheaper model for formatting
        messages: vec![Message::user(&format!("Format as report: {:?}", analysis.output))],
        output_schema: Some(schema_for!(Report)),
        capture_reasoning: false,  // Skip reasoning for simple formatting
        ..Default::default()
    }).await?;

    Ok(report.output)
}
```

### Routing with Observability

```rust
async fn handle_ticket(ctx: &WorkflowContext, ticket: Ticket) -> Result<Response> {
    // Classification with reasoning
    let classification = ctx.schedule_task(LlmTask {
        name: "classify",
        model: "claude-haiku",  // Fast model for classification
        system: Some("Classify support tickets into categories."),
        messages: vec![Message::user(&ticket.content)],
        output_schema: Some(schema_for!(Classification)),
        ..Default::default()  // capture_reasoning: true by default
    }).await?;

    // Route based on classification
    let response = match classification.output.category.as_str() {
        "billing" => ctx.schedule_task(LlmTask {
            name: "billing_response",
            model: "claude-sonnet-4-20250514",
            system: Some("You are a billing support specialist..."),
            messages: vec![Message::user(&ticket.content)],
            ..Default::default()
        }).await?,
        // ... other handlers
        _ => unimplemented!(),
    };

    Ok(response.output)
}
```

### Parallel with Aggregated Observability

```rust
async fn review_code(ctx: &WorkflowContext, code: Code) -> Result<Review> {
    let (security, performance, style) = tokio::join!(
        ctx.schedule_task(LlmTask {
            name: "security_review",
            model: "claude-sonnet-4-20250514",
            system: Some("You are a security expert..."),
            messages: vec![Message::user(&code.content)],
            ..Default::default()
        }),
        ctx.schedule_task(LlmTask {
            name: "performance_review",
            model: "claude-sonnet-4-20250514",
            system: Some("You are a performance expert..."),
            messages: vec![Message::user(&code.content)],
            ..Default::default()
        }),
        ctx.schedule_task(LlmTask {
            name: "style_review",
            model: "claude-haiku",  // Cheaper for style
            system: Some("You are a code style reviewer..."),
            messages: vec![Message::user(&code.content)],
            capture_reasoning: false,
            ..Default::default()
        }),
    );

    // All three reviews are captured in the event log
    // with their reasoning, token usage, and latency

    Ok(Review {
        security: security?.output,
        performance: performance?.output,
        style: style?.output,
        // Observability: total tokens, individual reasoning
        total_tokens: security?.usage.total()
            + performance?.usage.total()
            + style?.usage.total(),
    })
}
```

---

## Debugging Workflows

With `LlmTask`, workflows get similar debugging capabilities to agents:

### CLI Commands

```bash
# View workflow execution
flovyn workflow inspect <workflow-id>

# See all LLM calls in the workflow
flovyn workflow llm-calls <workflow-id>

# Output:
# seq=2: extract (sonnet, 1200 tokens, 850ms)
#   Reasoning: "The document contains a table with..."
# seq=4: analyze (sonnet, 2100 tokens, 1200ms)
#   Reasoning: "Based on the extracted data, I notice..."
# seq=6: format (haiku, 500 tokens, 200ms)
#   No reasoning captured

# View specific LLM call reasoning
flovyn workflow reasoning <workflow-id> --task extract

# Token usage breakdown
flovyn workflow tokens <workflow-id>
# Total: 3800 tokens ($0.023)
# - extract: 1200 tokens (31.6%)
# - analyze: 2100 tokens (55.3%)
# - format: 500 tokens (13.2%)
```

### Debug API

```rust
// Get all LLM calls in a workflow
let llm_calls = debug_client.get_llm_calls(workflow_id).await?;

for call in llm_calls {
    println!("Task: {}", call.task_name);
    println!("  Model: {}", call.model);
    println!("  Tokens: {} in, {} out", call.input_tokens, call.output_tokens);
    if let Some(reasoning) = call.reasoning {
        println!("  Reasoning: {}", reasoning);
    }
}

// Reconstruct LLM context at any call
let context = debug_client.get_llm_context(workflow_id, task: "analyze").await?;
println!("Messages sent to LLM: {:?}", context.messages);
```

---

## Comparison: Raw Task vs LlmTask vs Agent

| Aspect | Raw Task | LlmTask | Agent |
|--------|----------|---------|-------|
| **Control flow** | Developer | Developer | LLM decides |
| **Worker code** | Required | Not needed | Not needed |
| **LLM tracking** | Manual | Automatic | Automatic |
| **Reasoning capture** | None | Default on | Automatic |
| **Token tracking** | Manual | Automatic | Automatic |
| **Content storage** | Manual | Automatic | Automatic |
| **Time travel debug** | Events only | Full LLM context | Full agent state |
| **Complexity** | Lowest | Low | Higher |
| **Use case** | Non-LLM tasks | LLM workflows | Autonomous agents |

### When to Use What

```
Decision Tree:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Is it an LLM-powered application?
│
├─ No → Use raw Flovyn tasks
│
└─ Yes → Does the LLM decide the control flow?
         │
         ├─ No (developer controls) → Use LlmTask
         │   ✓ Prompt chaining
         │   ✓ Classification/routing
         │   ✓ Parallel analysis
         │   ✓ Generate-evaluate loops
         │   ✓ Orchestrator-workers
         │
         └─ Yes (LLM decides) → Use Agent API
             ✓ Code assistant
             ✓ Research agent
             ✓ Autonomous task solver
             ✓ Multi-turn conversations with tools
```

---

## Shared Infrastructure

Both `LlmTask` and `Agent` share the same underlying infrastructure:

```
┌─────────────────────────────────────────────────────────────┐
│                    APPLICATION LAYER                         │
├──────────────────────┬──────────────────────────────────────┤
│      LlmTask         │              Agent                   │
│  (workflow pattern)  │         (autonomous loop)            │
│                      │                                      │
│  ctx.schedule_task(  │  impl Agent for MyAgent {            │
│    LlmTask { ... }   │    async fn execute(&self, ctx)      │
│  )                   │  }                                   │
├──────────────────────┴──────────────────────────────────────┤
│                    SHARED SERVICES                           │
├─────────────────────────────────────────────────────────────┤
│  LLM Client          - Unified API for LLM calls            │
│  Content Store       - Large payload storage                │
│  Reasoning Capture   - ThinkingBlock storage                │
│  Event Sourcing      - All actions as events                │
│  Debug API           - Time travel, context reconstruction  │
└─────────────────────────────────────────────────────────────┘
```

### What's Shared

| Component | LlmTask Uses | Agent Uses |
|-----------|--------------|------------|
| **LLM Client** | Built-in executor calls it | AgentContext calls it |
| **Content Store** | Stores response + thinking | Stores messages + thinking |
| **Event Sourcing** | `LlmTaskCompleted` event | `LlmCalled` event |
| **Debug API** | `get_llm_context(workflow, task)` | `get_state_at(workflow, seq)` |
| **Token Tracking** | In task result | In context stats |

### Debug Commands Work for Both

```bash
# Workflow with LlmTask
flovyn workflow inspect <workflow-id>
flovyn workflow llm-calls <workflow-id>
flovyn workflow reasoning <workflow-id> --task extract

# Agent
flovyn agent inspect <workflow-id>
flovyn agent decisions <workflow-id>
flovyn agent state-at <workflow-id> --sequence 15
```

---

## Migration Path

### From Raw Tasks to LlmTask

```rust
// Before: Raw task (no observability)
let result = ctx.schedule_task("process", ProcessTask {
    prompt: "Analyze this data",
    data: input,
}).await?;

// After: LlmTask (full observability)
let result = ctx.schedule_task(LlmTask {
    name: "process",
    model: "claude-sonnet-4-20250514",
    messages: vec![Message::user(&format!("Analyze: {:?}", input))],
    capture_reasoning: true,
    ..Default::default()
}).await?;
```

### From LlmTask to Agent

When workflow complexity grows and you need LLM-driven control flow:

```rust
// Before: Developer-controlled workflow with LlmTask
async fn research(ctx: &WorkflowContext, query: String) -> Result<Report> {
    let search = ctx.schedule_task(LlmTask { name: "search", ... }).await?;
    let analyze = ctx.schedule_task(LlmTask { name: "analyze", ... }).await?;
    let report = ctx.schedule_task(LlmTask { name: "report", ... }).await?;
    Ok(report.output)
}

// After: Agent decides the flow
impl Agent for ResearchAgent {
    async fn execute(&self, ctx: &AgentContext) -> Result<AgentOutput> {
        ctx.add_message(Role::User, &query).await?;

        loop {
            let response = ctx.call_llm().await?;
            // LLM decides: search more? analyze? write report?
            for tool in response.tool_calls {
                ctx.execute_tool(&tool).await?;
            }
            if response.is_done() { break; }
        }

        Ok(AgentOutput::done(ctx.last_message()?))
    }
}
```

---

## Summary

| Pattern | API | Observability | Control |
|---------|-----|---------------|---------|
| **Non-LLM tasks** | Raw Flovyn task | Events only | Developer |
| **LLM workflows** | `LlmTask` | Full (reasoning, tokens, context) | Developer |
| **Autonomous agents** | `Agent` trait | Full + attribution | LLM |

**Key insight:** Workflows and agents share infrastructure. You don't lose observability by choosing simplicity.
