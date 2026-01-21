# Context Window Management (Deep Dive)

Context management is **critical** for production AI agents. LLM context windows are finite (8K-200K tokens), and agent conversations grow unbounded. Each framework handles this differently.

## 2.1 Gemini CLI - LLM-Based Semantic Compression

**The most sophisticated approach.** Automatically compresses when reaching 70% of context window.

**Trigger Condition:**
```typescript
const COMPRESSION_TOKEN_THRESHOLD = 0.7;  // 70% of context
const COMPRESSION_PRESERVE_THRESHOLD = 0.3;  // Keep latest 30%

if (tokenCount >= COMPRESSION_TOKEN_THRESHOLD * tokenLimit(model)) {
  await tryCompressChat();
}
```

**Split Point Algorithm** (`findCompressSplitPoint`):
```typescript
// Find where to split - ONLY at user message boundaries
function findCompressSplitPoint(contents: Content[], fraction: number): number {
  const totalCharCount = contents.reduce((sum, c) => sum + JSON.stringify(c).length, 0);
  const targetCharCount = totalCharCount * fraction;  // 70%

  let cumulativeCharCount = 0;
  for (let i = 0; i < contents.length; i++) {
    // Only split at user messages (not mid-turn)
    if (content.role === 'user' && !hasFunctionResponse(content)) {
      if (cumulativeCharCount >= targetCharCount) {
        return i;  // Split here
      }
    }
    cumulativeCharCount += charCounts[i];
  }
}
```

**Compression Process:**
```typescript
// 1. Split history
const historyToCompress = curatedHistory.slice(0, splitPoint);  // Oldest 70%
const historyToKeep = curatedHistory.slice(splitPoint);          // Latest 30%

// 2. Generate structured XML summary via separate LLM call
const summaryResponse = await generateContent({
  contents: [
    ...historyToCompress,
    { role: 'user', parts: [{ text: 'Generate the <state_snapshot>.' }] }
  ],
  config: { systemInstruction: getCompressionPrompt() }
});

// 3. Create new chat: [summary] + [ack] + [kept history]
this.chat = await startChat([
  { role: 'user', parts: [{ text: summary }] },
  { role: 'model', parts: [{ text: 'Got it. Thanks for the context!' }] },
  ...historyToKeep
]);
```

**Compression Prompt Output Format:**
```xml
<state_snapshot>
  <overall_goal>
    Refactor the authentication service to use JWT library v2.0
  </overall_goal>

  <key_facts>
    <fact>User prefers functional React components</fact>
    <fact>File src/auth/jwt.ts was created with token validation</fact>
    <fact>Tests in __tests__/auth.test.ts are failing</fact>
  </key_facts>

  <current_plan>
    1. [DONE] Install @auth/jwt-v2 library
    2. [DONE] Create token generation in src/auth/jwt.ts
    3. [IN PROGRESS] Refactor UserProfile.tsx to use new API
    4. [TODO] Fix failing tests
    5. [TODO] Update documentation
  </current_plan>
</state_snapshot>
```

**Source:** `gemini-cli/packages/core/src/core/client.ts:73-113, 731-851`

## 2.2 Temporal AI Agent - Workflow Continue-as-New

**Uses Temporal's `continue_as_new` to reset workflow history while preserving agent memory.**

**Trigger:** Fixed message count (default 250)
```python
MAX_TURNS = 250

async def continue_as_new_if_needed(conversation_history, prompt_queue, agent_goal):
    if len(conversation_history["messages"]) >= MAX_TURNS:
        # Generate 2-sentence summary
        summary_prompt = (
            "Please produce a two sentence summary of this conversation. "
            'Put the summary in the format { "summary": "<plain text>" }'
        )

        summary = await workflow.execute_activity(
            "agent_toolPlanner",
            ToolPromptInput(prompt=summary_prompt, context=history_string)
        )

        # Restart workflow with clean history but preserved summary
        workflow.continue_as_new(args=[{
            "tool_params": {
                "conversation_summary": summary,
                "prompt_queue": prompt_queue
            },
            "agent_goal": agent_goal
        }])
```

**Key Insight:** The **Temporal workflow event history resets** (solving the unbounded history problem), but the **agent's semantic memory continues** via the summary.

**Source:** `temporal-ai-agent/workflows/workflow_helpers.py:145-191`

## 2.3 Dyad - Raw SDK Message Preservation

**Stores complete AI SDK messages for multi-turn tool call fidelity.**

**Strategy:** Persist `aiMessagesJson` alongside human-readable content
```typescript
// After each LLM response, save raw SDK messages
const response = await streamResult.response;
const aiMessagesJson = getAiMessagesJsonIfWithinLimit(response.messages);

await db.update(messages)
  .set({ aiMessagesJson })  // Full tool call chain preserved
  .where(eq(messages.id, messageId));
```

**Message Reconstruction on Resume:**
```typescript
// Reconstruct full history including tool calls
const messageHistory: ModelMessage[] = chat.messages
  .filter(msg => msg.content || msg.aiMessagesJson)
  .flatMap(msg => parseAiMessagesJson(msg));

// Send to LLM with full tool call context
await streamText({ messages: messageHistory, tools: allTools });
```

**Stored Format:**
```json
{
  "messages": [
    { "role": "user", "content": "Create a login form" },
    { "role": "assistant", "content": "", "toolUses": [
      { "toolUseId": "abc123", "toolName": "write_file", "args": {...} }
    ]},
    { "role": "user", "toolResults": [
      { "toolUseId": "abc123", "result": "File created" }
    ]}
  ],
  "sdkVersion": "ai@v5"
}
```

**Cleanup:** Old entries purged after 7 days to manage storage
```typescript
// Cleanup job
await db.update(messages)
  .set({ aiMessagesJson: null })
  .where(lt(messages.createdAt, cutoffDate));
```

**Source:** `dyad/src/pro/main/ipc/handlers/local_agent/local_agent_handler.ts:188-370`

## 2.4 OpenManus - Simple FIFO Trimming

**Fixed-size sliding window with no semantic preservation.**

```python
class Memory(BaseModel):
    messages: list[Message] = Field(default_factory=list)
    max_messages: int = 100

    def add_message(self, message: Message) -> None:
        self.messages.append(message)
        # Drop oldest messages when limit exceeded
        while len(self.messages) > self.max_messages:
            self.messages.pop(0)
```

**Trade-off:** Simple but loses context. Suitable for short tasks, not long-running agents.

## 2.5 Open Interpreter - No Compression, Output Truncation Only

**Full history preserved, only tool outputs are truncated.**

```python
# No history compression - full persistence
with open(conversation_history_path, 'w') as f:
    json.dump(self.messages, f)

# Only tool OUTPUT is truncated (not history)
max_output = 2800  # tokens per tool result
```

**Relies on:** User managing context manually or starting new sessions.

## 2.6 Context Management Comparison

| Framework | Trigger | Strategy | Tool Call Fidelity | Semantic Preservation |
|-----------|---------|----------|-------------------|----------------------|
| **Gemini CLI** | 70% context | LLM → XML summary | Lost (summarized) | High (structured) |
| **Temporal** | 250 messages | LLM → 2 sentences | Lost | Medium |
| **Dyad** | None | Store raw SDK msgs | Full | N/A (no compression) |
| **OpenManus** | 100 messages | FIFO drop | Lost | None |
| **Open Interpreter** | None | Full history | Full | N/A |
| **Codex** | Configurable | Truncation | Partial | Low |

## 2.7 Key Design Decisions

**When to compress:**
- **Token-based** (Gemini): Most accurate, requires token counting
- **Message-count** (Temporal, OpenManus): Simple, predictable
- **Never** (Dyad, Open Interpreter): Full fidelity, risks context overflow

**What to preserve:**
- **Semantic summary** (Gemini, Temporal): Captures intent, loses details
- **Raw messages** (Dyad): Full tool call chains, expensive storage
- **Nothing** (OpenManus FIFO): Loses context, simple implementation

**How to compress:**
- **LLM-generated summary**: Best quality, adds latency and cost
- **Algorithmic truncation**: Fast, loses semantic meaning
- **Checkpoint/restart**: Clean slate with minimal carryover

## Source Code References

- Gemini CLI compression: `gemini-cli/packages/core/src/core/client.ts:73-113, 731-851`
- Gemini CLI prompts: `gemini-cli/packages/core/src/core/prompts.ts:419-481`
- Temporal continue-as-new: `temporal-ai-agent/workflows/workflow_helpers.py:145-191`
- Dyad SDK messages: `dyad/src/pro/main/ipc/handlers/local_agent/local_agent_handler.ts:188-370`
- OpenManus Memory: `flovyn-server/OpenManus/app/schema.py` (Memory class)
