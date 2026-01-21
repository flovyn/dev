# MVP Implementation Research

This document explores how to build an MVP for the AI agent features described in docs 11-13, with a focus on testability using mock LLM systems and integration tests.

**Related documents:**
- [Content Storage Strategy](./20260103_11_content_storage_strategy.md) - Storage architecture
- [Developer Experience](./20260103_12_developer_experience.md) - Agent API
- [Workflow Patterns](./20260103_13_workflow_patterns.md) - LlmTask built-in type

---

## Goals

1. **Testable without real LLM** - Mock LLM that simulates responses
2. **Integration tests** - Full end-to-end tests with testcontainers
3. **Simplified storage** - In-memory or PostgreSQL-based (no S3 for MVP)
4. **Core features only** - LlmTask, basic content storage, reasoning capture

---

## What We're Building

```
┌─────────────────────────────────────────────────────────────────┐
│                         MVP SCOPE                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. LlmTask - Built-in task type                               │
│     ├── LlmTaskInput struct                                    │
│     ├── LlmTaskOutput struct                                   │
│     ├── Built-in executor (no worker needed)                   │
│     └── Mock LLM backend for testing                           │
│                                                                 │
│  2. Content Store - Simplified                                  │
│     ├── PostgreSQL table (no S3)                               │
│     ├── Hash-based deduplication                               │
│     └── Reference from events                                  │
│                                                                 │
│  3. Reasoning Capture                                           │
│     ├── ThinkingBlock storage                                  │
│     ├── Event with content_ref                                 │
│     └── Debug API to retrieve                                  │
│                                                                 │
│  4. SDK Extensions                                              │
│     ├── LlmTask scheduling from workflows                      │
│     └── Result with reasoning + tokens                         │
│                                                                 │
│  5. Agent API (Autonomous Agents)                               │
│     ├── Agent trait with execute() method                      │
│     ├── AgentContext for LLM calls + tool execution            │
│     ├── Tool definition with #[tool] macro                     │
│     └── Agent loop with durable execution                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Component 1: Mock LLM System

### Why Mock?

- Real LLM calls are slow (1-5 seconds)
- Real LLM calls cost money
- Real LLM responses are non-deterministic
- Tests need predictable, fast responses

### Options for Mocking

#### Option A: In-Code Mock (Trait-based)

Implement `LlmProvider` trait with mock responses. Simple, no external dependencies.

**Pros:** Fast, no network, full control
**Cons:** Must define all responses upfront

#### Option B: Mock Server (HTTP-based)

Run a mock HTTP server that simulates the LLM API.

**Libraries/Tools:**
- **[llm-mock-server](https://github.com/anthropics/anthropic-quickstarts)** - Anthropic's test utilities
- **[WireMock](https://wiremock.org/)** - Generic HTTP mock server (Java/Docker)
- **[mockall](https://docs.rs/mockall)** - Rust mocking library
- **Custom Axum server** - Simple to build, full control

```rust
// Example: Simple mock server using Axum
async fn start_mock_llm_server(scenarios: Vec<MockScenario>) -> String {
    let app = Router::new()
        .route("/v1/messages", post(handle_messages))
        .with_state(Arc::new(scenarios));

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });

    format!("http://{}", addr)
}
```

**Pros:** Tests real HTTP path, can test timeouts/errors
**Cons:** More setup, slower than in-memory

#### Option C: Hybrid Approach (Recommended)

Use in-code mock for unit tests, mock server for integration tests.

```rust
// Unit tests: Fast, in-memory
#[cfg(test)]
let provider: Arc<dyn LlmProvider> = Arc::new(MockLlmProvider::new());

// Integration tests: Full HTTP path
#[cfg(test)]
let provider: Arc<dyn LlmProvider> = Arc::new(
    HttpLlmProvider::new(&mock_server_url)
);
```

### Mock LLM Trait

```rust
// crates/llm/src/lib.rs

/// Trait for LLM providers (real or mock)
#[async_trait]
pub trait LlmProvider: Send + Sync {
    /// Generate a completion
    async fn complete(&self, request: LlmRequest) -> Result<LlmResponse>;

    /// Check if provider supports thinking blocks
    fn supports_thinking(&self) -> bool;
}

#[derive(Debug, Clone)]
pub struct LlmRequest {
    pub model: String,
    pub system: Option<String>,
    pub messages: Vec<Message>,
    pub tools: Vec<ToolDefinition>,
    pub output_schema: Option<JsonSchema>,
    pub thinking_enabled: bool,
    pub max_tokens: Option<u32>,
    pub temperature: Option<f32>,
}

#[derive(Debug, Clone)]
pub struct LlmResponse {
    pub content: String,
    pub thinking: Option<String>,
    pub tool_calls: Vec<ToolCall>,
    pub usage: TokenUsage,
    pub model: String,
    pub stop_reason: StopReason,
}

#[derive(Debug, Clone)]
pub struct TokenUsage {
    pub input_tokens: u32,
    pub output_tokens: u32,
    pub thinking_tokens: Option<u32>,
}

#[derive(Debug, Clone)]
pub enum StopReason {
    EndTurn,
    ToolUse,
    MaxTokens,
    StopSequence,
}
```

### Mock Provider Implementation

```rust
// crates/llm/src/mock.rs

/// Mock LLM for testing - deterministic responses
pub struct MockLlmProvider {
    /// Predefined responses keyed by trigger patterns
    responses: Arc<RwLock<Vec<MockResponse>>>,
    /// Default response if no pattern matches
    default_response: String,
    /// Simulate thinking blocks
    simulate_thinking: bool,
    /// Simulated latency (for timeout testing)
    latency: Option<Duration>,
}

pub struct MockResponse {
    /// Pattern to match in user message
    pub trigger: MockTrigger,
    /// Response to return
    pub response: MockResponseData,
}

pub enum MockTrigger {
    /// Match exact text in last user message
    Contains(String),
    /// Match regex pattern
    Regex(String),
    /// Match any message (catch-all)
    Any,
    /// Match specific tool call request
    ToolCall(String),
}

pub struct MockResponseData {
    pub content: String,
    pub thinking: Option<String>,
    pub tool_calls: Vec<ToolCall>,
    pub stop_reason: StopReason,
}

impl MockLlmProvider {
    pub fn new() -> Self {
        Self {
            responses: Arc::new(RwLock::new(Vec::new())),
            default_response: "I understand. How can I help?".to_string(),
            simulate_thinking: true,
            latency: None,
        }
    }

    /// Add a response pattern
    pub fn when(mut self, trigger: MockTrigger, response: MockResponseData) -> Self {
        self.responses.write().unwrap().push(MockResponse { trigger, response });
        self
    }

    /// Fluent builder for common patterns
    pub fn when_contains(self, text: &str, response: &str) -> Self {
        self.when(
            MockTrigger::Contains(text.to_string()),
            MockResponseData {
                content: response.to_string(),
                thinking: Some(format!("Thinking about: {}", text)),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
    }

    /// Configure tool call response
    pub fn when_tool_requested(self, tool_name: &str, tool_call: ToolCall) -> Self {
        self.when(
            MockTrigger::ToolCall(tool_name.to_string()),
            MockResponseData {
                content: String::new(),
                thinking: Some(format!("I should use the {} tool", tool_name)),
                tool_calls: vec![tool_call],
                stop_reason: StopReason::ToolUse,
            }
        )
    }
}

#[async_trait]
impl LlmProvider for MockLlmProvider {
    async fn complete(&self, request: LlmRequest) -> Result<LlmResponse> {
        // Simulate latency if configured
        if let Some(latency) = self.latency {
            tokio::time::sleep(latency).await;
        }

        // Find matching response
        let responses = self.responses.read().unwrap();
        let last_user_msg = request.messages.iter()
            .rev()
            .find(|m| m.role == Role::User)
            .map(|m| &m.content)
            .unwrap_or(&String::new());

        let matched = responses.iter().find(|r| match &r.trigger {
            MockTrigger::Contains(text) => last_user_msg.contains(text),
            MockTrigger::Regex(pattern) => {
                regex::Regex::new(pattern)
                    .map(|re| re.is_match(last_user_msg))
                    .unwrap_or(false)
            }
            MockTrigger::Any => true,
            MockTrigger::ToolCall(name) => {
                request.tools.iter().any(|t| t.name == *name)
            }
        });

        let response_data = matched
            .map(|r| r.response.clone())
            .unwrap_or_else(|| MockResponseData {
                content: self.default_response.clone(),
                thinking: if self.simulate_thinking {
                    Some("Processing the request...".to_string())
                } else {
                    None
                },
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            });

        // Calculate mock token usage
        let input_tokens = estimate_tokens(&request);
        let output_tokens = estimate_tokens_str(&response_data.content);
        let thinking_tokens = response_data.thinking.as_ref()
            .map(|t| estimate_tokens_str(t));

        Ok(LlmResponse {
            content: response_data.content,
            thinking: if request.thinking_enabled { response_data.thinking } else { None },
            tool_calls: response_data.tool_calls,
            usage: TokenUsage {
                input_tokens,
                output_tokens,
                thinking_tokens,
            },
            model: request.model,
            stop_reason: response_data.stop_reason,
        })
    }

    fn supports_thinking(&self) -> bool {
        self.simulate_thinking
    }
}

/// Simple token estimation (4 chars ≈ 1 token)
fn estimate_tokens_str(s: &str) -> u32 {
    (s.len() / 4).max(1) as u32
}
```

---

## Test Scenarios & Mock Messages

Based on the workflow patterns from docs 12 and 13, here are concrete test scenarios with predefined mock responses.

### Scenario 1: Prompt Chaining (Document Processing)

From doc 13 - Sequential LLM calls where each step processes the previous output.

```rust
/// Mock responses for document processing workflow
pub fn document_processing_scenario() -> MockLlmProvider {
    MockLlmProvider::new()
        // Step 1: Extract key information
        .when(
            MockTrigger::Contains("extract"),
            MockResponseData {
                content: r#"{
                    "title": "Q3 Financial Report",
                    "date": "2025-09-30",
                    "key_figures": {
                        "revenue": 15000000,
                        "profit": 2500000,
                        "growth": 0.12
                    },
                    "highlights": [
                        "Record quarterly revenue",
                        "Expansion into APAC market",
                        "New product line launched"
                    ]
                }"#.to_string(),
                thinking: Some(
                    "I need to extract structured data from this document. \
                    Looking for: title, date, financial figures, and key highlights. \
                    The document appears to be a quarterly financial report."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
        // Step 2: Analyze extracted data
        .when(
            MockTrigger::Contains("analyze"),
            MockResponseData {
                content: r#"{
                    "sentiment": "positive",
                    "risk_factors": ["market_volatility", "supply_chain"],
                    "opportunities": ["apac_expansion", "new_products"],
                    "recommendation": "buy",
                    "confidence": 0.78
                }"#.to_string(),
                thinking: Some(
                    "Analyzing the extracted financial data. \
                    Revenue growth of 12% is strong. \
                    APAC expansion suggests growth strategy. \
                    However, need to consider market risks."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
        // Step 3: Generate report
        .when(
            MockTrigger::Contains("format") | MockTrigger::Contains("report"),
            MockResponseData {
                content: r#"# Q3 Financial Analysis Report

## Executive Summary
Strong quarterly performance with 12% revenue growth.

## Key Findings
- **Revenue**: $15M (record high)
- **Profit**: $2.5M
- **Growth**: 12% YoY

## Recommendation
**BUY** with 78% confidence.

## Risk Factors
- Market volatility
- Supply chain concerns"#.to_string(),
                thinking: Some(
                    "Formatting the analysis into a readable report. \
                    Using markdown for structure. \
                    Highlighting key metrics and recommendation."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
}
```

### Scenario 2: Routing (Support Ticket Classification)

From doc 13 - Classify input and direct to specialized handlers.

```rust
/// Mock responses for support ticket routing
pub fn support_routing_scenario() -> MockLlmProvider {
    MockLlmProvider::new()
        // Classification step
        .when(
            MockTrigger::Contains("classify"),
            MockResponseData {
                content: r#"{"category": "billing", "confidence": 0.92}"#.to_string(),
                thinking: Some(
                    "The ticket mentions 'invoice' and 'charge'. \
                    This is clearly a billing-related issue. \
                    High confidence in classification."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
        // Technical ticket classification
        .when(
            MockTrigger::Contains("error") | MockTrigger::Contains("bug"),
            MockResponseData {
                content: r#"{"category": "technical", "confidence": 0.88}"#.to_string(),
                thinking: Some(
                    "Keywords 'error', 'crash', 'not working' indicate technical issue."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
        // Billing handler response
        .when(
            MockTrigger::Contains("billing_response"),
            MockResponseData {
                content: "I understand you have a billing concern. I've reviewed your account \
                         and can see the charge in question. Let me explain the breakdown and \
                         help resolve this for you.".to_string(),
                thinking: Some(
                    "Customer has billing inquiry. Need to be empathetic and clear. \
                    Should offer to explain charges and provide resolution options."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
        // Technical handler response
        .when(
            MockTrigger::Contains("tech_response"),
            MockResponseData {
                content: "I see you're experiencing a technical issue. Based on your description, \
                         this appears to be related to our authentication service. Let me gather \
                         some diagnostic information to help resolve this.".to_string(),
                thinking: Some(
                    "Technical issue reported. Need to diagnose and provide solution. \
                    Should ask for logs or reproduction steps if needed."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
}
```

### Scenario 3: Parallelization (Code Review)

From doc 13 - Multiple LLM calls run simultaneously.

```rust
/// Mock responses for parallel code review
pub fn code_review_scenario() -> MockLlmProvider {
    MockLlmProvider::new()
        // Security review
        .when(
            MockTrigger::Contains("security"),
            MockResponseData {
                content: r#"{
                    "issues": [
                        {
                            "severity": "high",
                            "type": "sql_injection",
                            "line": 42,
                            "description": "User input directly concatenated into SQL query",
                            "fix": "Use parameterized queries"
                        },
                        {
                            "severity": "medium",
                            "type": "xss",
                            "line": 78,
                            "description": "Unescaped user input in HTML output",
                            "fix": "Sanitize output with proper escaping"
                        }
                    ],
                    "score": 3
                }"#.to_string(),
                thinking: Some(
                    "Scanning for OWASP top 10 vulnerabilities. \
                    Found SQL injection at line 42 - critical. \
                    Found potential XSS at line 78. \
                    No authentication bypasses detected."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
        // Performance review
        .when(
            MockTrigger::Contains("performance"),
            MockResponseData {
                content: r#"{
                    "issues": [
                        {
                            "severity": "medium",
                            "type": "n_plus_one",
                            "line": 55,
                            "description": "Database query inside loop",
                            "fix": "Use batch query or JOIN"
                        },
                        {
                            "severity": "low",
                            "type": "unnecessary_clone",
                            "line": 23,
                            "description": "Cloning data that could be borrowed",
                            "fix": "Use reference instead of clone"
                        }
                    ],
                    "score": 7
                }"#.to_string(),
                thinking: Some(
                    "Analyzing performance patterns. \
                    N+1 query detected in user loading loop. \
                    Minor clone optimization opportunity. \
                    Overall performance acceptable with fixes."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
        // Style review
        .when(
            MockTrigger::Contains("style"),
            MockResponseData {
                content: r#"{
                    "issues": [
                        {
                            "severity": "low",
                            "type": "naming",
                            "line": 15,
                            "description": "Function name 'doThing' is not descriptive",
                            "fix": "Rename to 'processUserAuthentication'"
                        }
                    ],
                    "score": 9
                }"#.to_string(),
                thinking: Some(
                    "Checking code style and naming conventions. \
                    Most code follows guidelines. \
                    One naming issue found."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
}
```

### Scenario 4: Tool Calling

Testing LLM requesting tool execution.

```rust
/// Mock responses for tool-calling scenarios
pub fn tool_calling_scenario() -> MockLlmProvider {
    MockLlmProvider::new()
        // Request file read
        .when(
            MockTrigger::Contains("read the file") | MockTrigger::Contains("show me"),
            MockResponseData {
                content: "".to_string(),
                thinking: Some(
                    "User wants to see file contents. I should use the read_file tool."
                    .to_string()
                ),
                tool_calls: vec![ToolCall {
                    id: "call_read_1".to_string(),
                    name: "read_file".to_string(),
                    arguments: json!({"path": "src/main.rs"}),
                }],
                stop_reason: StopReason::ToolUse,
            }
        )
        // Request file edit
        .when(
            MockTrigger::Contains("fix the bug") | MockTrigger::Contains("update the code"),
            MockResponseData {
                content: "".to_string(),
                thinking: Some(
                    "User wants me to modify code. I need to use the edit_file tool. \
                    First, I should identify the exact change needed."
                    .to_string()
                ),
                tool_calls: vec![ToolCall {
                    id: "call_edit_1".to_string(),
                    name: "edit_file".to_string(),
                    arguments: json!({
                        "path": "src/main.rs",
                        "old_content": "fn broken() {}",
                        "new_content": "fn fixed() { /* implementation */ }"
                    }),
                }],
                stop_reason: StopReason::ToolUse,
            }
        )
        // Request search
        .when(
            MockTrigger::Contains("find") | MockTrigger::Contains("search"),
            MockResponseData {
                content: "".to_string(),
                thinking: Some(
                    "User is looking for something in the codebase. \
                    I'll use the search tool to find relevant files."
                    .to_string()
                ),
                tool_calls: vec![ToolCall {
                    id: "call_search_1".to_string(),
                    name: "search".to_string(),
                    arguments: json!({"query": "authentication", "file_pattern": "*.rs"}),
                }],
                stop_reason: StopReason::ToolUse,
            }
        )
        // After tool result - continue with response
        .when(
            MockTrigger::ToolResultReceived,
            MockResponseData {
                content: "I found the information you requested. Here's what I discovered...".to_string(),
                thinking: Some(
                    "Tool execution completed. Now I should summarize the results for the user."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
}
```

### Scenario 5: Evaluator-Optimizer (Content Generation)

From doc 13 - Generate-evaluate-refine loop.

```rust
/// Mock responses for evaluator-optimizer pattern
pub fn evaluator_optimizer_scenario() -> MockLlmProvider {
    MockLlmProvider::new()
        // Initial generation
        .when(
            MockTrigger::Contains("generate") & !MockTrigger::Contains("feedback"),
            MockResponseData {
                content: "Here is a blog post about Rust:\n\n\
                         Rust is a programming language. It is fast. \
                         You should use it for systems programming.".to_string(),
                thinking: Some(
                    "Generating initial draft. Keeping it simple for first iteration."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
        // Evaluation (first iteration - fails)
        .when(
            MockTrigger::Sequence(1) & MockTrigger::Contains("evaluate"),
            MockResponseData {
                content: r#"{
                    "passes": false,
                    "score": 4,
                    "feedback": "Content is too brief and lacks depth. \
                                 Missing: code examples, specific use cases, \
                                 comparison with alternatives. \
                                 Tone is too simplistic."
                }"#.to_string(),
                thinking: Some(
                    "Evaluating against criteria: depth, examples, engagement. \
                    Current draft is too superficial. Needs significant improvement."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
        // Refinement with feedback
        .when(
            MockTrigger::Contains("feedback"),
            MockResponseData {
                content: "# Why Rust is Revolutionizing Systems Programming\n\n\
                         Rust has taken the programming world by storm, and for good reason.\n\n\
                         ## Memory Safety Without Garbage Collection\n\
                         Unlike C++, Rust guarantees memory safety at compile time:\n\
                         ```rust\n\
                         let data = vec![1, 2, 3];\n\
                         // Rust prevents use-after-free automatically\n\
                         ```\n\n\
                         ## Real-World Impact\n\
                         Companies like Discord and Cloudflare have seen 10x performance \
                         improvements after adopting Rust.\n\n\
                         ## Getting Started\n\
                         The best way to learn Rust is through the official book...".to_string(),
                thinking: Some(
                    "Incorporating feedback: adding code examples, depth, and real-world cases. \
                    Making the tone more engaging and professional."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
        // Evaluation (second iteration - passes)
        .when(
            MockTrigger::Sequence(2) & MockTrigger::Contains("evaluate"),
            MockResponseData {
                content: r#"{
                    "passes": true,
                    "score": 8,
                    "feedback": "Much improved. Good depth, includes code examples, \
                                 mentions real companies. Could add more about learning resources."
                }"#.to_string(),
                thinking: Some(
                    "Re-evaluating the refined content. \
                    Now meets quality threshold. Passing."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
}
```

### Scenario 6: Error Handling

Testing error conditions and recovery.

```rust
/// Mock responses for error scenarios
pub fn error_handling_scenario() -> MockLlmProvider {
    MockLlmProvider::new()
        // Rate limit simulation
        .when(
            MockTrigger::Contains("rate_limit_test"),
            MockResponseData::error(LlmError::RateLimited {
                retry_after: Duration::from_secs(5),
            })
        )
        // Context too long
        .when(
            MockTrigger::ContextExceedsTokens(200_000),
            MockResponseData::error(LlmError::ContextTooLong {
                max_tokens: 200_000,
                requested_tokens: 250_000,
            })
        )
        // Invalid tool call (malformed arguments)
        .when(
            MockTrigger::Contains("malformed_tool"),
            MockResponseData {
                content: "".to_string(),
                thinking: Some("Attempting tool call".to_string()),
                tool_calls: vec![ToolCall {
                    id: "call_bad".to_string(),
                    name: "read_file".to_string(),
                    arguments: json!("not_an_object"),  // Invalid - should be object
                }],
                stop_reason: StopReason::ToolUse,
            }
        )
        // Timeout simulation
        .when(
            MockTrigger::Contains("timeout_test"),
            MockResponseData::delayed(Duration::from_secs(120))  // Exceed typical timeout
        )
}
```

### Combining Scenarios for Tests

```rust
// server/tests/integration/scenarios.rs

/// All scenarios combined for comprehensive testing
pub fn all_scenarios() -> MockLlmProvider {
    MockLlmProvider::new()
        .merge(document_processing_scenario())
        .merge(support_routing_scenario())
        .merge(code_review_scenario())
        .merge(tool_calling_scenario())
        .merge(evaluator_optimizer_scenario())
        .merge(error_handling_scenario())
}

/// Scenario selector for specific tests
pub enum TestScenario {
    DocumentProcessing,
    SupportRouting,
    CodeReview,
    ToolCalling,
    EvaluatorOptimizer,
    ErrorHandling,
}

impl TestScenario {
    pub fn provider(&self) -> MockLlmProvider {
        match self {
            Self::DocumentProcessing => document_processing_scenario(),
            Self::SupportRouting => support_routing_scenario(),
            Self::CodeReview => code_review_scenario(),
            Self::ToolCalling => tool_calling_scenario(),
            Self::EvaluatorOptimizer => evaluator_optimizer_scenario(),
            Self::ErrorHandling => error_handling_scenario(),
        }
    }
}
```

### Test Usage

```rust
#[tokio::test]
async fn test_document_processing_workflow() {
    with_timeout!(async {
        let harness = get_harness()
            .with_mock_llm(TestScenario::DocumentProcessing.provider())
            .await;

        let result = harness.run_workflow("document-processing", json!({
            "document": "Q3 Financial Report content here..."
        })).await.unwrap();

        // Verify all 3 steps executed
        let events = harness.get_workflow_events(result.workflow_id).await;
        let llm_calls: Vec<_> = events.iter()
            .filter(|e| e.event_type == "LlmTaskCompleted")
            .collect();

        assert_eq!(llm_calls.len(), 3);  // extract, analyze, format

        // Verify final output is formatted report
        assert!(result.output.contains("Executive Summary"));
        assert!(result.output.contains("BUY"));
    });
}

#[tokio::test]
async fn test_parallel_code_review() {
    with_timeout!(async {
        let harness = get_harness()
            .with_mock_llm(TestScenario::CodeReview.provider())
            .await;

        let result = harness.run_workflow("code-review", json!({
            "code": "fn main() { /* code to review */ }"
        })).await.unwrap();

        let output: CodeReviewOutput = serde_json::from_value(result.output).unwrap();

        // All three reviews completed
        assert!(output.security.issues.len() > 0);
        assert!(output.performance.issues.len() > 0);
        assert!(output.style.score >= 0);

        // Verify thinking was captured for each
        let events = harness.get_workflow_events(result.workflow_id).await;
        for event in events.iter().filter(|e| e.event_type == "LlmTaskCompleted") {
            let data: serde_json::Value = serde_json::from_slice(&event.event_data).unwrap();
            assert!(data["thinking_ref"].is_string());  // Thinking was stored
        }
    });
}
```

---

## Component 2: Content Store (Simplified)

### PostgreSQL-Based Storage

For MVP, store content in PostgreSQL instead of external object storage.

```sql
-- Migration: YYYYMMDDHHMMSS_content_store.sql

CREATE TABLE content_store (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Content-addressing
    hash VARCHAR(64) NOT NULL,

    -- Metadata
    content_type VARCHAR(50) NOT NULL,
    size_bytes INTEGER NOT NULL,
    token_estimate INTEGER,

    -- The actual content
    content BYTEA NOT NULL,

    -- Lifecycle
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_accessed_at TIMESTAMPTZ,

    -- Reference counting (for cleanup)
    reference_count INTEGER NOT NULL DEFAULT 1,

    CONSTRAINT unique_hash UNIQUE (hash)
);

CREATE INDEX idx_content_store_hash ON content_store(hash);
CREATE INDEX idx_content_store_created_at ON content_store(created_at);

-- Add content_ref to workflow_event
ALTER TABLE workflow_event
ADD COLUMN content_ref UUID REFERENCES content_store(id);
```

### Content Store Repository

```rust
// server/src/repository/content_store_repository.rs

use sha2::{Sha256, Digest};

pub struct ContentStoreRepository {
    pool: PgPool,
}

#[derive(Debug, Clone, sqlx::Type)]
#[sqlx(type_name = "VARCHAR", rename_all = "snake_case")]
pub enum ContentType {
    SystemPrompt,
    UserMessage,
    AssistantMessage,
    ThinkingBlock,
    ToolArguments,
    ToolResult,
    ContextCheckpoint,
    LlmRequest,
    LlmResponse,
}

#[derive(Debug, Clone)]
pub struct ContentRef {
    pub id: Uuid,
    pub hash: String,
    pub content_type: ContentType,
    pub size_bytes: i32,
    pub token_estimate: Option<i32>,
}

impl ContentStoreRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Store content, returning existing ref if already stored (deduplication)
    pub async fn store(
        &self,
        content: &[u8],
        content_type: ContentType,
    ) -> Result<ContentRef> {
        let hash = Self::compute_hash(content);
        let size_bytes = content.len() as i32;
        let token_estimate = Self::estimate_tokens(content);

        // Try to find existing content by hash
        if let Some(existing) = self.find_by_hash(&hash).await? {
            // Increment reference count
            sqlx::query!(
                "UPDATE content_store SET reference_count = reference_count + 1 WHERE id = $1",
                existing.id
            )
            .execute(&self.pool)
            .await?;

            return Ok(existing);
        }

        // Store new content
        let id = Uuid::new_v4();
        sqlx::query!(
            r#"
            INSERT INTO content_store (id, hash, content_type, size_bytes, token_estimate, content)
            VALUES ($1, $2, $3, $4, $5, $6)
            "#,
            id,
            hash,
            content_type as ContentType,
            size_bytes,
            token_estimate,
            content
        )
        .execute(&self.pool)
        .await?;

        Ok(ContentRef {
            id,
            hash,
            content_type,
            size_bytes,
            token_estimate,
        })
    }

    /// Retrieve content by reference
    pub async fn get(&self, id: Uuid) -> Result<Option<Vec<u8>>> {
        let result = sqlx::query_scalar!(
            "SELECT content FROM content_store WHERE id = $1",
            id
        )
        .fetch_optional(&self.pool)
        .await?;

        // Update last_accessed_at
        if result.is_some() {
            sqlx::query!(
                "UPDATE content_store SET last_accessed_at = NOW() WHERE id = $1",
                id
            )
            .execute(&self.pool)
            .await?;
        }

        Ok(result)
    }

    /// Find by hash (for deduplication)
    async fn find_by_hash(&self, hash: &str) -> Result<Option<ContentRef>> {
        sqlx::query_as!(
            ContentRef,
            r#"
            SELECT id, hash, content_type as "content_type: ContentType",
                   size_bytes, token_estimate
            FROM content_store WHERE hash = $1
            "#,
            hash
        )
        .fetch_optional(&self.pool)
        .await
        .map_err(Into::into)
    }

    fn compute_hash(content: &[u8]) -> String {
        let mut hasher = Sha256::new();
        hasher.update(content);
        format!("{:x}", hasher.finalize())
    }

    fn estimate_tokens(content: &[u8]) -> Option<i32> {
        // Simple estimation: ~4 bytes per token for text
        if let Ok(text) = std::str::from_utf8(content) {
            Some((text.len() / 4).max(1) as i32)
        } else {
            None
        }
    }
}
```

---

## Component 3: LlmTask Built-in Type

### Domain Model

```rust
// server/src/domain/llm_task.rs

/// Input for LlmTask - what the workflow provides
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct LlmTaskInput {
    /// Task name for debugging/observability
    pub name: String,

    /// Model to use (e.g., "claude-sonnet-4-20250514")
    pub model: String,

    /// System prompt
    #[serde(default)]
    pub system: Option<String>,

    /// Conversation messages
    pub messages: Vec<LlmMessage>,

    /// Available tools (optional)
    #[serde(default)]
    pub tools: Vec<ToolDefinition>,

    /// Expected output schema for structured output
    #[serde(default)]
    pub output_schema: Option<serde_json::Value>,

    /// Whether to capture reasoning (default: true)
    #[serde(default = "default_true")]
    pub capture_reasoning: bool,

    /// Model settings
    #[serde(default)]
    pub settings: LlmSettings,
}

fn default_true() -> bool { true }

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
pub struct LlmSettings {
    pub temperature: Option<f32>,
    pub max_tokens: Option<u32>,
    pub top_p: Option<f32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct LlmMessage {
    pub role: LlmRole,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum LlmRole {
    User,
    Assistant,
    System,
}

/// Output from LlmTask
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct LlmTaskOutput {
    /// The LLM's response content
    pub content: String,

    /// Reasoning/thinking (if captured)
    pub reasoning: Option<String>,

    /// Tool calls requested by LLM
    pub tool_calls: Vec<ToolCall>,

    /// Token usage
    pub usage: TokenUsage,

    /// Model used
    pub model: String,

    /// Stop reason
    pub stop_reason: String,

    /// Latency in milliseconds
    pub latency_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct TokenUsage {
    pub input_tokens: u32,
    pub output_tokens: u32,
    pub thinking_tokens: Option<u32>,
}

impl TokenUsage {
    pub fn total(&self) -> u32 {
        self.input_tokens + self.output_tokens + self.thinking_tokens.unwrap_or(0)
    }
}
```

### Built-in Executor

```rust
// server/src/executor/llm_task_executor.rs

/// Executes LlmTask internally (no worker needed)
pub struct LlmTaskExecutor {
    llm_provider: Arc<dyn LlmProvider>,
    content_store: ContentStoreRepository,
    event_repo: EventRepository,
}

impl LlmTaskExecutor {
    pub fn new(
        llm_provider: Arc<dyn LlmProvider>,
        content_store: ContentStoreRepository,
        event_repo: EventRepository,
    ) -> Self {
        Self { llm_provider, content_store, event_repo }
    }

    /// Execute an LlmTask
    pub async fn execute(
        &self,
        workflow_execution_id: Uuid,
        task_execution_id: Uuid,
        input: LlmTaskInput,
    ) -> Result<LlmTaskOutput> {
        let start = Instant::now();

        // 1. Build LLM request
        let request = LlmRequest {
            model: input.model.clone(),
            system: input.system.clone(),
            messages: input.messages.iter().map(|m| Message {
                role: match m.role {
                    LlmRole::User => Role::User,
                    LlmRole::Assistant => Role::Assistant,
                    LlmRole::System => Role::System,
                },
                content: m.content.clone(),
            }).collect(),
            tools: input.tools.clone(),
            output_schema: input.output_schema.clone(),
            thinking_enabled: input.capture_reasoning,
            max_tokens: input.settings.max_tokens,
            temperature: input.settings.temperature,
        };

        // 2. Store request in content store
        let request_bytes = serde_json::to_vec(&request)?;
        let request_ref = self.content_store
            .store(&request_bytes, ContentType::LlmRequest)
            .await?;

        // 3. Call LLM
        let response = self.llm_provider.complete(request).await?;

        let latency_ms = start.elapsed().as_millis() as u64;

        // 4. Store response in content store
        let response_bytes = serde_json::to_vec(&response)?;
        let response_ref = self.content_store
            .store(&response_bytes, ContentType::LlmResponse)
            .await?;

        // 5. Store thinking block separately (if present)
        let thinking_ref = if let Some(thinking) = &response.thinking {
            let thinking_bytes = thinking.as_bytes();
            Some(self.content_store
                .store(thinking_bytes, ContentType::ThinkingBlock)
                .await?)
        } else {
            None
        };

        // 6. Emit event for observability
        let event_data = serde_json::to_vec(&json!({
            "task_name": input.name,
            "model": response.model,
            "input_tokens": response.usage.input_tokens,
            "output_tokens": response.usage.output_tokens,
            "thinking_tokens": response.usage.thinking_tokens,
            "latency_ms": latency_ms,
            "stop_reason": format!("{:?}", response.stop_reason),
            "request_ref": request_ref.id,
            "response_ref": response_ref.id,
            "thinking_ref": thinking_ref.as_ref().map(|r| r.id),
        }))?;

        self.event_repo.append_with_auto_sequence(
            workflow_execution_id,
            EventType::LlmTaskCompleted,
            Some(event_data),
            Some(response_ref.id),  // content_ref points to full response
        ).await?;

        // 7. Return output
        Ok(LlmTaskOutput {
            content: response.content,
            reasoning: response.thinking,
            tool_calls: response.tool_calls.into_iter().map(|tc| ToolCall {
                id: tc.id,
                name: tc.name,
                arguments: tc.arguments,
            }).collect(),
            usage: TokenUsage {
                input_tokens: response.usage.input_tokens,
                output_tokens: response.usage.output_tokens,
                thinking_tokens: response.usage.thinking_tokens,
            },
            model: response.model,
            stop_reason: format!("{:?}", response.stop_reason),
            latency_ms,
        })
    }
}
```

### New Event Type

```rust
// Add to server/src/domain/workflow_event.rs

pub enum EventType {
    // ... existing types ...

    /// LLM task completed (built-in task type)
    LlmTaskCompleted,

    /// Context was compressed
    ContextCompressed,
}
```

---

## Component 4: SDK Extensions

### Workflow Context - LlmTask as Built-in Type

`LlmTask` is scheduled using the existing `schedule_task()` method. The server detects the `__llm` task kind and executes it internally.

```rust
// sdk-rust/sdk/src/workflow/context.rs

// No new method needed - use existing schedule_task()
// LlmTask implements TaskDefinition with kind = "__llm"

impl TaskDefinition for LlmTask {
    type Input = LlmTaskInput;
    type Output = LlmTaskOutput;

    fn kind(&self) -> &str { "__llm" }
}

// Usage in workflow:
let result = ctx.schedule_task(LlmTask {
    name: "extract".to_string(),
    model: "claude-sonnet-4-20250514".to_string(),
    messages: vec![...],
    ..Default::default()
}).await?;
}
```

### Server-Side Detection

```rust
// server/src/service/task_service.rs

impl TaskService {
    pub async fn submit_task(&self, request: SubmitTaskRequest) -> Result<SubmitTaskResponse> {
        // Check if this is a built-in LlmTask
        if request.task_kind == "__llm" {
            return self.handle_llm_task(request).await;
        }

        // Normal task handling...
    }

    async fn handle_llm_task(&self, request: SubmitTaskRequest) -> Result<SubmitTaskResponse> {
        let input: LlmTaskInput = serde_json::from_slice(&request.task_input)?;

        // Execute immediately (no worker polling)
        let output = self.llm_executor.execute(
            request.workflow_execution_id,
            Uuid::new_v4(),  // Generate task_execution_id
            input,
        ).await?;

        let output_bytes = serde_json::to_vec(&output)?;

        Ok(SubmitTaskResponse {
            task_execution_id: /* ... */,
            output: Some(output_bytes),
        })
    }
}
```

---

## Component 5: Debug API

### REST Endpoints

```rust
// server/src/api/rest/debug.rs

/// Get LLM calls for a workflow
#[utoipa::path(
    get,
    path = "/api/orgs/{org_slug}/workflows/{workflow_id}/llm-calls",
    responses(
        (status = 200, body = Vec<LlmCallInfo>)
    ),
    tag = "Debug"
)]
pub async fn get_llm_calls(
    State(state): State<AppState>,
    Path((org_slug, workflow_id)): Path<(String, Uuid)>,
) -> Result<Json<Vec<LlmCallInfo>>, ApiError> {
    let events = state.event_repo
        .get_events_by_type(workflow_id, EventType::LlmTaskCompleted)
        .await?;

    let mut calls = Vec::new();
    for event in events {
        let data: LlmCallEventData = serde_json::from_slice(&event.event_data.unwrap_or_default())?;

        // Load thinking if requested
        let thinking = if let Some(thinking_ref) = data.thinking_ref {
            state.content_store.get(thinking_ref).await?
                .map(|bytes| String::from_utf8_lossy(&bytes).to_string())
        } else {
            None
        };

        calls.push(LlmCallInfo {
            sequence: event.sequence_number,
            timestamp: event.created_at,
            task_name: data.task_name,
            model: data.model,
            input_tokens: data.input_tokens,
            output_tokens: data.output_tokens,
            thinking_tokens: data.thinking_tokens,
            latency_ms: data.latency_ms,
            thinking,
        });
    }

    Ok(Json(calls))
}

/// Get reasoning/thinking for a specific LLM call
#[utoipa::path(
    get,
    path = "/api/orgs/{org_slug}/workflows/{workflow_id}/reasoning/{sequence}",
    responses(
        (status = 200, body = ReasoningInfo)
    ),
    tag = "Debug"
)]
pub async fn get_reasoning(
    State(state): State<AppState>,
    Path((org_slug, workflow_id, sequence)): Path<(String, Uuid, i32)>,
) -> Result<Json<ReasoningInfo>, ApiError> {
    let event = state.event_repo
        .get_event_at_sequence(workflow_id, sequence)
        .await?
        .ok_or(ApiError::NotFound)?;

    let data: LlmCallEventData = serde_json::from_slice(&event.event_data.unwrap_or_default())?;

    // Load full response from content store
    let response = if let Some(response_ref) = data.response_ref {
        state.content_store.get(response_ref).await?
            .and_then(|bytes| serde_json::from_slice::<LlmResponse>(&bytes).ok())
    } else {
        None
    };

    Ok(Json(ReasoningInfo {
        sequence,
        task_name: data.task_name,
        thinking: response.as_ref().and_then(|r| r.thinking.clone()),
        content: response.as_ref().map(|r| r.content.clone()),
        model: data.model,
    }))
}

#[derive(Debug, Serialize, ToSchema)]
pub struct LlmCallInfo {
    pub sequence: i32,
    pub timestamp: DateTime<Utc>,
    pub task_name: String,
    pub model: String,
    pub input_tokens: u32,
    pub output_tokens: u32,
    pub thinking_tokens: Option<u32>,
    pub latency_ms: u64,
    pub thinking: Option<String>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct ReasoningInfo {
    pub sequence: i32,
    pub task_name: String,
    pub thinking: Option<String>,
    pub content: Option<String>,
    pub model: String,
}
```

---

## Component 5: Agent API

The Agent API is for **autonomous agents** where the LLM controls the flow (vs. LlmTask where developer controls flow).

### Agent Trait

```rust
// sdk-rust/sdk/src/agent/mod.rs

use async_trait::async_trait;

/// Trait for defining autonomous agents
#[async_trait]
pub trait Agent: Send + Sync {
    /// Agent name/kind for registration
    fn name(&self) -> &str;

    /// Agent configuration
    fn config(&self) -> AgentConfig;

    /// Execute the agent - developer writes the agent loop
    async fn execute(&self, ctx: &AgentContext) -> Result<AgentOutput>;
}

#[derive(Debug, Clone)]
pub struct AgentConfig {
    /// System prompt / instructions
    pub instructions: String,

    /// Default model for LLM calls
    pub model: String,

    /// Tools available to this agent
    pub tools: Vec<ToolDefinition>,

    /// Approval policy for tool execution
    pub approval: ApprovalPolicy,

    /// Capture reasoning/thinking blocks (default: true)
    pub capture_reasoning: bool,

    /// Maximum turns before stopping
    pub max_turns: Option<u32>,
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self {
            instructions: String::new(),
            model: "claude-sonnet-4-20250514".to_string(),
            tools: vec![],
            approval: ApprovalPolicy::None,
            capture_reasoning: true,
            max_turns: Some(50),
        }
    }
}

#[derive(Debug, Clone)]
pub enum ApprovalPolicy {
    /// Never require approval
    None,
    /// Require for specific tools
    RequireFor(Vec<String>),
    /// Require for all tools
    RequireAll,
}

#[derive(Debug, Clone)]
pub struct AgentOutput {
    pub response: String,
    pub tool_calls_made: u32,
    pub turns_used: u32,
}
```

### AgentContext

```rust
// sdk-rust/sdk/src/agent/context.rs

/// Context provided to agent's execute() method
pub struct AgentContext {
    workflow_ctx: Arc<dyn WorkflowContext>,
    llm_provider: Arc<dyn LlmProvider>,
    content_store: Arc<ContentStoreRepository>,
    config: AgentConfig,
    messages: Vec<Message>,
    turn_count: u32,
}

impl AgentContext {
    // === Messages ===

    /// Add a message to the conversation
    pub async fn add_message(&mut self, role: Role, content: &str) -> Result<()> {
        self.messages.push(Message { role, content: content.to_string() });

        // Store in content store
        let content_ref = self.content_store
            .store(content.as_bytes(), ContentType::from_role(&role))
            .await?;

        // Emit event
        self.workflow_ctx.emit_event(AgentEvent::MessageAdded {
            role,
            content_ref: content_ref.id,
            token_estimate: content_ref.token_estimate,
        }).await?;

        Ok(())
    }

    /// Get conversation messages
    pub fn messages(&self) -> &[Message] {
        &self.messages
    }

    // === LLM Calls ===

    /// Call the LLM with current context
    pub async fn call_llm(&mut self) -> Result<LlmResponse> {
        self.turn_count += 1;

        if let Some(max) = self.config.max_turns {
            if self.turn_count > max {
                return Err(AgentError::MaxTurnsExceeded(max));
            }
        }

        let request = LlmRequest {
            model: self.config.model.clone(),
            system: Some(self.config.instructions.clone()),
            messages: self.messages.clone(),
            tools: self.config.tools.clone(),
            thinking_enabled: self.config.capture_reasoning,
            ..Default::default()
        };

        let response = self.llm_provider.complete(request).await?;

        // Store response and thinking in content store
        let response_ref = self.content_store
            .store(&serde_json::to_vec(&response)?, ContentType::LlmResponse)
            .await?;

        let thinking_ref = if let Some(thinking) = &response.thinking {
            Some(self.content_store
                .store(thinking.as_bytes(), ContentType::ThinkingBlock)
                .await?)
        } else {
            None
        };

        // Emit event
        self.workflow_ctx.emit_event(AgentEvent::LlmCalled {
            model: response.model.clone(),
            input_tokens: response.usage.input_tokens,
            output_tokens: response.usage.output_tokens,
            thinking_ref: thinking_ref.map(|r| r.id),
            response_ref: response_ref.id,
            turn: self.turn_count,
        }).await?;

        Ok(response)
    }

    // === Tool Execution ===

    /// Execute a tool call (handles approval if needed)
    pub async fn execute_tool(&self, tool_call: &ToolCall) -> Result<String> {
        // Check approval policy
        let needs_approval = match &self.config.approval {
            ApprovalPolicy::None => false,
            ApprovalPolicy::RequireAll => true,
            ApprovalPolicy::RequireFor(tools) => tools.contains(&tool_call.name),
        };

        if needs_approval {
            // Create promise and wait for approval
            let approved = self.workflow_ctx
                .promise::<bool>(&format!("approve_tool_{}", tool_call.id))
                .await?;

            if !approved {
                return Err(AgentError::ToolDenied(tool_call.name.clone()));
            }
        }

        // Execute tool as a task
        let result = self.workflow_ctx
            .schedule_raw(&tool_call.name, tool_call.arguments.clone())
            .await?;

        // Store result in content store
        let result_str = serde_json::to_string(&result)?;
        let result_ref = self.content_store
            .store(result_str.as_bytes(), ContentType::ToolResult)
            .await?;

        // Emit event
        self.workflow_ctx.emit_event(AgentEvent::ToolExecuted {
            tool_name: tool_call.name.clone(),
            tool_call_id: tool_call.id.clone(),
            result_ref: result_ref.id,
        }).await?;

        Ok(result_str)
    }

    /// Add tool result to conversation
    pub async fn add_tool_result(&mut self, tool_id: &str, result: &str) -> Result<()> {
        self.messages.push(Message {
            role: Role::ToolResult { tool_id: tool_id.to_string() },
            content: result.to_string(),
        });
        Ok(())
    }

    // === State ===

    /// Get typed input
    pub fn input<T: DeserializeOwned>(&self) -> Result<T> {
        self.workflow_ctx.input()
    }

    /// Get context statistics
    pub fn stats(&self) -> ContextStats {
        ContextStats {
            message_count: self.messages.len(),
            turn_count: self.turn_count,
            token_estimate: self.messages.iter()
                .map(|m| estimate_tokens(&m.content))
                .sum(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ContextStats {
    pub message_count: usize,
    pub turn_count: u32,
    pub token_estimate: u32,
}
```

### Tool Definition

```rust
// sdk-rust/sdk/src/agent/tool.rs

/// Tool definition for agents
#[derive(Debug, Clone)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    pub parameters: JsonSchema,
}

/// Macro for defining tools (simplified version for MVP)
/// Full proc-macro implementation in later phase
#[macro_export]
macro_rules! define_tool {
    ($name:ident, $desc:expr, $handler:expr) => {
        ToolDefinition {
            name: stringify!($name).to_string(),
            description: $desc.to_string(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {}
            }),
        }
    };
}

// Example tools for testing
pub fn read_file_tool() -> ToolDefinition {
    ToolDefinition {
        name: "read_file".to_string(),
        description: "Read contents of a file".to_string(),
        parameters: serde_json::json!({
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Path to the file"
                }
            },
            "required": ["path"]
        }),
    }
}

pub fn search_tool() -> ToolDefinition {
    ToolDefinition {
        name: "search".to_string(),
        description: "Search for content in the codebase".to_string(),
        parameters: serde_json::json!({
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query"
                },
                "file_pattern": {
                    "type": "string",
                    "description": "File pattern to search (e.g., *.rs)"
                }
            },
            "required": ["query"]
        }),
    }
}
```

### Example Agent Implementation

```rust
// Example: Code Assistant Agent

struct CodeAssistant;

#[async_trait]
impl Agent for CodeAssistant {
    fn name(&self) -> &str { "code-assistant" }

    fn config(&self) -> AgentConfig {
        AgentConfig {
            instructions: "You are a code assistant. Help users understand and modify code. \
                          Use tools to read files and search the codebase.".to_string(),
            model: "claude-sonnet-4-20250514".to_string(),
            tools: vec![
                read_file_tool(),
                search_tool(),
            ],
            approval: ApprovalPolicy::None,  // Read-only tools don't need approval
            capture_reasoning: true,
            max_turns: Some(20),
        }
    }

    async fn execute(&self, ctx: &mut AgentContext) -> Result<AgentOutput> {
        let input: AgentInput = ctx.input()?;

        // Add user message
        ctx.add_message(Role::User, &input.prompt).await?;

        let mut tool_calls_made = 0;

        // Agent loop - LLM controls the flow
        loop {
            let response = ctx.call_llm().await?;

            // Add assistant response
            if !response.content.is_empty() {
                ctx.add_message(Role::Assistant, &response.content).await?;
            }

            // Handle tool calls
            for tool_call in &response.tool_calls {
                tool_calls_made += 1;

                let result = ctx.execute_tool(tool_call).await?;
                ctx.add_tool_result(&tool_call.id, &result).await?;
            }

            // Check if done
            match response.stop_reason {
                StopReason::EndTurn => break,
                StopReason::ToolUse => continue,  // More tool calls needed
                StopReason::MaxTokens => break,   // Hit limit
                StopReason::StopSequence => break,
            }
        }

        Ok(AgentOutput {
            response: ctx.messages().last()
                .map(|m| m.content.clone())
                .unwrap_or_default(),
            tool_calls_made,
            turns_used: ctx.stats().turn_count,
        })
    }
}

#[derive(Debug, Deserialize)]
struct AgentInput {
    prompt: String,
}
```

### Agent Events

```rust
// Add to server/src/domain/workflow_event.rs

pub enum EventType {
    // ... existing types ...

    // Agent-specific events
    AgentStarted,
    AgentCompleted,
    AgentFailed,
    MessageAdded,
    LlmCalled,          // Reuse for both LlmTask and Agent
    ToolExecuted,
    ApprovalRequested,
    ApprovalReceived,
}

/// Agent event payloads
#[derive(Debug, Serialize, Deserialize)]
pub enum AgentEvent {
    MessageAdded {
        role: Role,
        content_ref: Uuid,
        token_estimate: Option<i32>,
    },
    LlmCalled {
        model: String,
        input_tokens: u32,
        output_tokens: u32,
        thinking_ref: Option<Uuid>,
        response_ref: Uuid,
        turn: u32,
    },
    ToolExecuted {
        tool_name: String,
        tool_call_id: String,
        result_ref: Uuid,
    },
}
```

### Agent Test Scenario

```rust
/// Mock responses for agent test
pub fn code_assistant_agent_scenario() -> MockLlmProvider {
    MockLlmProvider::new()
        // First turn: Agent decides to search
        .when(
            MockTrigger::Sequence(1),
            MockResponseData {
                content: "".to_string(),
                thinking: Some(
                    "User wants help with authentication code. \
                    I should first search for auth-related files."
                    .to_string()
                ),
                tool_calls: vec![ToolCall {
                    id: "call_1".to_string(),
                    name: "search".to_string(),
                    arguments: json!({"query": "authentication", "file_pattern": "*.rs"}),
                }],
                stop_reason: StopReason::ToolUse,
            }
        )
        // Second turn: After search, read specific file
        .when(
            MockTrigger::Sequence(2),
            MockResponseData {
                content: "".to_string(),
                thinking: Some(
                    "Found auth.rs. Let me read it to understand the implementation."
                    .to_string()
                ),
                tool_calls: vec![ToolCall {
                    id: "call_2".to_string(),
                    name: "read_file".to_string(),
                    arguments: json!({"path": "src/auth.rs"}),
                }],
                stop_reason: StopReason::ToolUse,
            }
        )
        // Third turn: Provide answer
        .when(
            MockTrigger::Sequence(3),
            MockResponseData {
                content: "I've analyzed your authentication code. Here's what I found:\n\n\
                         1. The `authenticate()` function in `flovyn-server/src/auth.rs` handles JWT validation\n\
                         2. There's a potential issue on line 45 where the token expiry isn't checked\n\
                         3. I recommend adding an expiry check before returning the user.\n\n\
                         Would you like me to show you the fix?".to_string(),
                thinking: Some(
                    "I've gathered enough information. The auth code has a bug with token expiry. \
                    I should explain the issue clearly and offer to help fix it."
                    .to_string()
                ),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            }
        )
}
```

### Agent Integration Test

```rust
#[tokio::test]
async fn test_agent_multi_turn_with_tools() {
    with_timeout!(async {
        let harness = get_harness()
            .with_mock_llm(code_assistant_agent_scenario())
            .await;

        // Register mock tool handlers
        harness.register_tool_handler("search", |args| {
            json!({"files": ["src/auth.rs", "src/middleware/auth.rs"]})
        });
        harness.register_tool_handler("read_file", |args| {
            json!({"content": "fn authenticate(token: &str) -> Result<User> { ... }"})
        });

        // Start agent workflow
        let result = harness.start_agent("code-assistant", json!({
            "prompt": "Help me understand the authentication code"
        })).await.unwrap();

        // Wait for completion
        let output = harness.wait_for_workflow(result.workflow_id).await.unwrap();

        // Verify agent behavior
        let events = harness.get_workflow_events(result.workflow_id).await;

        // Should have 3 LLM calls (3 turns)
        let llm_calls: Vec<_> = events.iter()
            .filter(|e| e.event_type == "LlmCalled")
            .collect();
        assert_eq!(llm_calls.len(), 3);

        // Should have 2 tool executions
        let tool_calls: Vec<_> = events.iter()
            .filter(|e| e.event_type == "ToolExecuted")
            .collect();
        assert_eq!(tool_calls.len(), 2);

        // Verify final response
        let agent_output: AgentOutput = serde_json::from_value(output.output).unwrap();
        assert!(agent_output.response.contains("authentication"));
        assert_eq!(agent_output.tool_calls_made, 2);
        assert_eq!(agent_output.turns_used, 3);

        // Verify reasoning was captured for each turn
        for llm_event in &llm_calls {
            let data: serde_json::Value = serde_json::from_slice(&llm_event.event_data).unwrap();
            assert!(data["thinking_ref"].is_string());
        }
    });
}
```

---

## Integration Tests

### Test Harness Extension

Integration tests use testcontainers with **PostgreSQL 18-alpine** (consistent with existing tests).

```rust
// server/tests/integration/harness.rs

impl TestHarness {
    /// Create harness with mock LLM provider
    /// Uses postgres:18-alpine via testcontainers
    pub fn with_mock_llm(mut self, provider: MockLlmProvider) -> Self {
        self.llm_provider = Some(Arc::new(provider));
        self
    }

    /// Get content from content store (for assertions)
    pub async fn get_content(&self, content_ref: Uuid) -> Option<Vec<u8>> {
        let pool = self.get_db_pool();
        ContentStoreRepository::new(pool)
            .get(content_ref)
            .await
            .ok()
            .flatten()
    }
}
```

### LlmTask Integration Test

```rust
// server/tests/integration/llm_task_tests.rs

use crate::harness::{get_harness, with_timeout};

#[tokio::test]
async fn test_llm_task_basic() {
    with_timeout!(async {
        let mock_llm = MockLlmProvider::new()
            .when_contains("extract", "Extracted: {\"name\": \"John\", \"age\": 30}");

        let harness = get_harness()
            .with_mock_llm(mock_llm)
            .await;

        // Create workflow that uses LlmTask
        let workflow_id = harness.start_workflow("llm-test", json!({
            "prompt": "Please extract the data"
        })).await.unwrap();

        // Wait for completion
        let result = harness.wait_for_workflow(workflow_id).await.unwrap();

        // Verify result
        let output: LlmTaskOutput = serde_json::from_value(result.output).unwrap();
        assert!(output.content.contains("Extracted"));
        assert!(output.reasoning.is_some());
        assert!(output.usage.input_tokens > 0);
    });
}

#[tokio::test]
async fn test_llm_task_thinking_stored() {
    with_timeout!(async {
        let mock_llm = MockLlmProvider::new()
            .when(MockTrigger::Any, MockResponseData {
                content: "Here is the answer".to_string(),
                thinking: Some("Let me think about this carefully...".to_string()),
                tool_calls: vec![],
                stop_reason: StopReason::EndTurn,
            });

        let harness = get_harness()
            .with_mock_llm(mock_llm)
            .await;

        let workflow_id = harness.start_workflow("llm-test", json!({
            "prompt": "Think about this"
        })).await.unwrap();

        harness.wait_for_workflow(workflow_id).await.unwrap();

        // Verify thinking was stored in content store
        let events = harness.get_workflow_events(workflow_id).await;
        let llm_event = events.iter()
            .find(|e| e.event_type == "LlmTaskCompleted")
            .unwrap();

        let event_data: serde_json::Value = serde_json::from_slice(&llm_event.event_data).unwrap();
        let thinking_ref: Uuid = serde_json::from_value(event_data["thinking_ref"].clone()).unwrap();

        let thinking_content = harness.get_content(thinking_ref).await.unwrap();
        let thinking_str = String::from_utf8(thinking_content).unwrap();

        assert_eq!(thinking_str, "Let me think about this carefully...");
    });
}

#[tokio::test]
async fn test_llm_task_deduplication() {
    with_timeout!(async {
        let mock_llm = MockLlmProvider::new()
            .when_contains("same prompt", "Same response");

        let harness = get_harness()
            .with_mock_llm(mock_llm)
            .await;

        // Run two workflows with same system prompt
        let system_prompt = "You are a helpful assistant";

        let wf1 = harness.start_workflow("llm-test", json!({
            "system": system_prompt,
            "prompt": "same prompt"
        })).await.unwrap();

        let wf2 = harness.start_workflow("llm-test", json!({
            "system": system_prompt,
            "prompt": "same prompt"
        })).await.unwrap();

        harness.wait_for_workflow(wf1).await.unwrap();
        harness.wait_for_workflow(wf2).await.unwrap();

        // Check content store only has one copy of system prompt
        let count: i64 = sqlx::query_scalar!(
            "SELECT COUNT(*) FROM content_store WHERE content_type = 'system_prompt'"
        )
        .fetch_one(harness.db_pool())
        .await
        .unwrap()
        .unwrap_or(0);

        // Should be deduplicated to 1
        assert_eq!(count, 1);
    });
}

#[tokio::test]
async fn test_llm_task_with_tools() {
    with_timeout!(async {
        let mock_llm = MockLlmProvider::new()
            .when_tool_requested("search", ToolCall {
                id: "call_1".to_string(),
                name: "search".to_string(),
                arguments: json!({"query": "rust programming"}),
            });

        let harness = get_harness()
            .with_mock_llm(mock_llm)
            .await;

        let workflow_id = harness.start_workflow("llm-test", json!({
            "prompt": "Search for rust programming",
            "tools": [{
                "name": "search",
                "description": "Search the web",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string"}
                    }
                }
            }]
        })).await.unwrap();

        let result = harness.wait_for_workflow(workflow_id).await.unwrap();
        let output: LlmTaskOutput = serde_json::from_value(result.output).unwrap();

        assert_eq!(output.tool_calls.len(), 1);
        assert_eq!(output.tool_calls[0].name, "search");
        assert_eq!(output.stop_reason, "ToolUse");
    });
}

#[tokio::test]
async fn test_debug_api_llm_calls() {
    with_timeout!(async {
        let mock_llm = MockLlmProvider::new()
            .when_contains("step1", "Result 1")
            .when_contains("step2", "Result 2");

        let harness = get_harness()
            .with_mock_llm(mock_llm)
            .await;

        // Workflow that makes multiple LLM calls
        let workflow_id = harness.start_workflow("multi-llm-test", json!({
            "steps": ["step1", "step2"]
        })).await.unwrap();

        harness.wait_for_workflow(workflow_id).await.unwrap();

        // Query debug API
        let resp = harness.rest_client()
            .get(&format!("/api/orgs/test/workflows/{}/llm-calls", workflow_id))
            .send()
            .await
            .unwrap();

        assert_eq!(resp.status(), 200);

        let calls: Vec<LlmCallInfo> = resp.json().await.unwrap();
        assert_eq!(calls.len(), 2);
        assert!(calls[0].thinking.is_some());
        assert!(calls[1].thinking.is_some());
    });
}
```

### Workflow Definition for Tests

```rust
// server/tests/integration/fixtures/llm_test_workflow.rs

/// Test workflow that uses LlmTask
pub struct LlmTestWorkflow;

#[async_trait]
impl WorkflowDefinition<LlmTestInput, LlmTestOutput> for LlmTestWorkflow {
    fn kind(&self) -> &str { "llm-test" }

    async fn execute(
        &self,
        ctx: &dyn WorkflowContext,
        input: LlmTestInput,
    ) -> Result<LlmTestOutput> {
        let result = ctx.schedule_task(LlmTask {
            name: "test-llm-call".to_string(),
            model: "mock-model".to_string(),
            system: input.system,
            messages: vec![LlmMessage {
                role: LlmRole::User,
                content: input.prompt,
            }],
            tools: input.tools.unwrap_or_default(),
            output_schema: None,
            capture_reasoning: true,
            settings: Default::default(),
        }).await?;

        Ok(LlmTestOutput {
            content: result.content,
            reasoning: result.reasoning,
            tokens: result.usage.total(),
        })
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct LlmTestInput {
    pub prompt: String,
    pub system: Option<String>,
    pub tools: Option<Vec<ToolDefinition>>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct LlmTestOutput {
    pub content: String,
    pub reasoning: Option<String>,
    pub tokens: u32,
}
```

---

## Simplified Scope for MVP

### In Scope

| Component | Simplification |
|-----------|----------------|
| **LlmTask** | Single model support, no streaming |
| **Content Store** | PostgreSQL only (no S3) |
| **Deduplication** | SHA256 hash-based |
| **Reasoning** | Store thinking blocks, basic retrieval |
| **Debug API** | List LLM calls, get reasoning |
| **Mock LLM** | Pattern-based responses |

### Out of Scope (Future)

| Component | Why Deferred |
|-----------|--------------|
| **Agent API** | Requires more complex state machine |
| **Context Compression** | Requires full context management |
| **Multi-model routing** | Complexity |
| **S3/Object Storage** | PostgreSQL sufficient for MVP |
| **Real LLM Integration** | Start with mock for testing |
| **Streaming tokens** | MVP uses complete responses |

---

## File Structure

```
server/
├── src/
│   ├── domain/
│   │   ├── llm_task.rs              # LlmTaskInput, LlmTaskOutput
│   │   └── agent_event.rs           # Agent-specific events
│   ├── repository/
│   │   └── content_store_repository.rs
│   ├── executor/
│   │   └── llm_task_executor.rs     # Built-in executor
│   └── api/rest/
│       └── debug.rs                 # Debug endpoints
├── migrations/
│   └── YYYYMMDDHHMMSS_content_store.sql
└── tests/integration/
    ├── llm_task_tests.rs
    ├── agent_tests.rs               # Agent API tests
    ├── scenarios.rs                 # Mock scenarios
    └── fixtures/
        ├── llm_test_workflow.rs
        └── code_assistant_agent.rs  # Example agent

crates/
└── llm/
    ├── src/
    │   ├── lib.rs                   # LlmProvider trait
    │   ├── mock.rs                  # MockLlmProvider
    │   └── types.rs                 # LlmRequest, LlmResponse
    └── Cargo.toml

sdk-rust/sdk/
└── src/
    ├── workflow/
    │   └── context.rs               # LlmTask implements TaskDefinition
    └── agent/
        ├── mod.rs                   # Agent trait, AgentConfig
        ├── context.rs               # AgentContext
        └── tool.rs                  # ToolDefinition, example tools
```

---

---

## Implementation Phases & Findings Log

Track progress and learnings after each phase. Update this section during implementation.

### Phase 1: Mock LLM System

**Status:** Not started

**Goals:**
- [ ] Create `crates/llm` with `LlmProvider` trait
- [ ] Implement `MockLlmProvider` with pattern matching
- [ ] Add test scenarios from this document
- [ ] Verify mock works in isolation (unit tests)

**Findings:**
<!-- Update after implementation -->
- What worked:
- What didn't work:
- Changes from original design:
- Open questions:

---

### Phase 2: Content Store

**Status:** Not started

**Goals:**
- [ ] Create migration for `content_store` table
- [ ] Implement `ContentStoreRepository`
- [ ] Add `content_ref` column to `workflow_event`
- [ ] Test deduplication with same content
- [ ] Test retrieval performance

**Findings:**
<!-- Update after implementation -->
- What worked:
- What didn't work:
- Changes from original design:
- Open questions:

---

### Phase 3: LlmTask Built-in Type

**Status:** Not started

**Goals:**
- [ ] Define `LlmTaskInput` and `LlmTaskOutput` in domain
- [ ] Add `LlmTaskCompleted` event type
- [ ] Implement `LlmTaskExecutor`
- [ ] Detect `__llm` task kind in task service
- [ ] Store request/response/thinking in content store
- [ ] Integration test with mock LLM

**Findings:**
<!-- Update after implementation -->
- What worked:
- What didn't work:
- Changes from original design:
- Open questions:

---

### Phase 4: SDK Extension

**Status:** Not started

**Goals:**
- [ ] Implement `TaskDefinition` for `LlmTask` (kind = "__llm")
- [ ] Test from SDK workflow definition
- [ ] Verify result includes reasoning and tokens

**Findings:**
<!-- Update after implementation -->
- What worked:
- What didn't work:
- Changes from original design:
- Open questions:

---

### Phase 5: Debug API

**Status:** Not started

**Goals:**
- [ ] Add `/workflows/{id}/llm-calls` endpoint
- [ ] Add `/workflows/{id}/reasoning/{seq}` endpoint
- [ ] Register in OpenAPI
- [ ] Integration test for debug queries

**Findings:**
<!-- Update after implementation -->
- What worked:
- What didn't work:
- Changes from original design:
- Open questions:

---

### Phase 6: Agent API

**Status:** Not started

**Goals:**
- [ ] Create `Agent` trait in SDK
- [ ] Implement `AgentContext` with message/LLM/tool methods
- [ ] Add agent-specific events (AgentStarted, MessageAdded, ToolExecuted)
- [ ] Create `ToolDefinition` struct and example tools
- [ ] Implement approval policy with workflow promises
- [ ] Agent test scenario with multi-turn conversation

**Findings:**
<!-- Update after implementation -->
- What worked:
- What didn't work:
- Changes from original design:
- Open questions:

---

### Phase 7: End-to-End Scenarios

**Status:** Not started

**Goals:**
- [ ] Test prompt chaining (document processing) - LlmTask
- [ ] Test routing (support tickets) - LlmTask
- [ ] Test parallelization (code review) - LlmTask
- [ ] Test tool calling - LlmTask
- [ ] Test evaluator-optimizer loop - LlmTask
- [ ] Test agent multi-turn with tools - Agent API
- [ ] Test error handling scenarios

**Findings:**
<!-- Update after implementation -->
- What worked:
- What didn't work:
- Changes from original design:
- Open questions:

---

### Post-MVP: Research Document Updates

After completing MVP, update research documents based on findings:

| Document | Updates Needed |
|----------|----------------|
| **11-content-storage-strategy.md** | Actual dedup rates, performance numbers, schema changes |
| **12-developer-experience.md** | API adjustments based on SDK usage |
| **13-workflow-patterns.md** | LlmTask API changes, missing features |
| **14-mvp-implementation.md** | Consolidate all findings into lessons learned |

---

## Summary

This MVP provides:

1. **Testable LLM integration** - Mock provider allows deterministic, fast tests
2. **Content storage foundation** - PostgreSQL-based with deduplication
3. **Reasoning capture** - ThinkingBlock stored and retrievable
4. **LlmTask built-in type** - For developer-controlled LLM workflows
5. **Agent API** - For autonomous agents with LLM-controlled flow
6. **Debug API** - Query LLM calls and reasoning
7. **SDK integration** - `LlmTask` as `TaskDefinition` and `Agent` trait

The design is intentionally minimal to validate the core concepts before adding complexity like context compression or external storage.
