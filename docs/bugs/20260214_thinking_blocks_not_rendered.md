# Bug: Thinking Content Blocks Not Rendered in UI

## Date
2026-02-14

## Status
**OPEN** - Frontend bug, low priority

## Summary

The flovyn-app frontend does not render `thinking` type content blocks from assistant messages. This causes the UI to show tool calls without any preceding LLM reasoning, making the conversation appear disjointed.

## Observed Behavior

Agent run: `f0a8ac7e-8257-4ced-93d6-f144e6eddaec`

UI shows:
```
Scrape HN and summarize the top stories

Running command run-sandbox import requests...
```

No LLM text appears between the user message and the first tool call.

## Expected Behavior

The LLM's thinking/reasoning should be displayed before the tool call, e.g.:
```
Scrape HN and summarize the top stories

I'll need to scrape Hacker News (news.ycombinator.com) and summarize
the top stories. Let's use Python with requests and BeautifulSoup...

Running command run-sandbox import requests...
```

## Root Cause

Assistant entries contain multiple content block types:

```json
{
  "content": [
    {"type": "thinking", "thinking": "I'll need to scrape Hacker News..."},
    {"type": "toolCall", "name": "run-sandbox", ...}
  ]
}
```

The frontend renders:
- `text` type blocks
- `toolCall` type blocks

But does NOT render:
- `thinking` type blocks

## Evidence

Database query showing content types per assistant entry:

| Time | Content Types | UI Renders |
|------|--------------|------------|
| 10:46:45 | `thinking` + `toolCall` | Only toolCall |
| 10:46:53 | `thinking` + `toolCall` | Only toolCall |
| 10:46:59 | `thinking` + `toolCall` | Only toolCall |
| 10:47:05 | `text` + `toolCall` | Both |
| 10:47:11 | `text` + `toolCall` | Both |

## Affected Components

- `flovyn-app` - Message rendering component

## Suggested Fix

1. Add rendering support for `thinking` type content blocks
2. Consider displaying in a collapsible "Show reasoning" section
3. Style differently from regular text (e.g., lighter color, italic)

## Notes

- This affects models that use `thinking` blocks (e.g., DeepSeek)
- Models that use `text` blocks work correctly
- Backend stores data correctly - this is purely a frontend display issue
