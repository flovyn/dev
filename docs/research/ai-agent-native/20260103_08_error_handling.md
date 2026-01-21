# Error Handling Patterns

## 8.1 Retry Strategies

| Error Type | Strategy | Example |
|------------|----------|---------|
| Rate limit (429) | Exponential backoff | 1s → 2s → 4s → ... → 60s |
| Server error (5xx) | Retry with limit | Max 3-6 attempts |
| Auth error (401) | Fail fast, re-auth | No retry |
| Token limit | Compress context | Summarize history |
| Invalid response | Inject continuation | "Please continue" |

## 8.2 Graceful Degradation

**Gemini CLI's fallback pattern:**
```typescript
// On quota exceeded, switch to cheaper model
if (error.status === 429 && model === 'pro') {
  isInFallbackMode = true;
  return retry(withModel: 'flash');
}
```

## 8.3 Tool Error Categories

**Codex's error classification:**
```rust
enum ToolErrorType {
    // Recoverable (LLM can self-correct)
    FileNotFound, EditNoOccurrence, InvalidParams,

    // Fatal (stop execution)
    NoSpaceLeft, PermissionDenied (sometimes),
}
```

## 8.4 LLM-Specific Error Handling

**Context overflow:**
```typescript
if (error.code === 'context_length_exceeded') {
  await compressContext();
  return retry();
}
```

**Invalid tool call:**
```typescript
if (error.type === 'invalid_tool_call') {
  // Feed error back to LLM
  messages.push({
    role: 'tool_result',
    content: `Error: ${error.message}. Please fix and try again.`
  });
  return continueLoop();
}
```

**Incomplete response:**
```typescript
if (response.finish_reason === 'length') {
  // Response was cut off
  messages.push({ role: 'user', content: 'Please continue.' });
  return continueLoop();
}
```

## 8.5 Recovery Strategies

| Scenario | Recovery |
|----------|----------|
| Network timeout | Retry with backoff |
| Rate limited | Wait, retry with backoff |
| Context overflow | Compress history, retry |
| Invalid response | Feed error to LLM |
| Tool failure | Report to LLM, let it adapt |
| Sandbox blocked | Request user approval, retry |

## 8.6 Circuit Breaker Pattern

```typescript
class CircuitBreaker {
  private failures = 0;
  private lastFailure: Date | null = null;
  private readonly threshold = 5;
  private readonly resetTime = 60000; // 1 minute

  async call<T>(fn: () => Promise<T>): Promise<T> {
    if (this.isOpen()) {
      throw new Error('Circuit breaker is open');
    }

    try {
      const result = await fn();
      this.reset();
      return result;
    } catch (error) {
      this.recordFailure();
      throw error;
    }
  }

  private isOpen(): boolean {
    if (this.failures < this.threshold) return false;
    if (Date.now() - this.lastFailure!.getTime() > this.resetTime) {
      this.reset();
      return false;
    }
    return true;
  }
}
```
