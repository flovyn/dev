# MCP (Model Context Protocol) Integration

## 9.1 Why MCP Matters

MCP enables **dynamic tool ecosystems**:
- Tools can be added/removed at runtime
- External services exposed as tools
- Standardized protocol across frameworks

## 9.2 MCP Integration Patterns

| Framework | MCP Support | Connection Types |
|-----------|-------------|------------------|
| Dyad | Full | stdio, HTTP |
| OpenManus | Full | SSE, stdio |
| Gemini CLI | Limited | Via custom tools |
| Codex | Full | stdio, HTTP |

## 9.3 Dynamic Tool Refresh

**OpenManus Pattern:**
```python
async def _refresh_tools(self):
    """Check for tool additions/removals/changes"""
    current = await self.mcp_client.list_tools()
    added = current - self.known_tools
    removed = self.known_tools - current
    # Update tool registry dynamically
```

**Source:** `flovyn-server/OpenManus/app/agent/mcp.py`

## 9.4 MCP Server Connection

**Typical connection flow:**
```typescript
// 1. Start MCP server
const server = spawn('mcp-server', ['--stdio']);

// 2. Initialize connection
await client.initialize({
  protocolVersion: '1.0',
  capabilities: { tools: true }
});

// 3. List available tools
const tools = await client.listTools();

// 4. Execute tool
const result = await client.callTool(toolName, args);
```

## 9.5 Connection Types

| Type | Use Case | Pros | Cons |
|------|----------|------|------|
| **stdio** | Local processes | Simple, fast | Process management |
| **HTTP** | Remote services | Language agnostic | Network latency |
| **SSE** | Streaming results | Real-time updates | Complexity |

## 9.6 Tool Schema Format

```json
{
  "name": "read_file",
  "description": "Read contents of a file",
  "inputSchema": {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Path to the file to read"
      }
    },
    "required": ["path"]
  }
}
```

## 9.7 Security Considerations

- **Tool approval:** MCP tools should go through approval system
- **Sandboxing:** MCP servers may need isolation
- **Authentication:** Secure connection to remote MCP servers
- **Rate limiting:** Prevent abuse of external tools
