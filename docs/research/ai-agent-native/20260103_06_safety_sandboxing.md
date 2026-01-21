# Safety and Sandboxing

## 6.1 Multi-Layer Defense Strategy

**Codex (most comprehensive):**

```
┌─────────────────────────────────────────────────┐
│           SAFETY LAYERS                          │
├─────────────────────────────────────────────────┤
│ Layer 1: Command Safety Analysis                 │
│   - Whitelist known-safe commands (ls, cat)     │
│   - Detect dangerous patterns (rm -rf, dd)      │
│                                                  │
│ Layer 2: Approval System                         │
│   - Policy-based: Skip/Ask/Forbid               │
│   - Cached decisions per session                │
│                                                  │
│ Layer 3: Platform Sandboxing                     │
│   - macOS: Seatbelt (sandbox-exec)              │
│   - Linux: Landlock + Seccomp                   │
│   - Windows: Restricted Token                    │
│                                                  │
│ Layer 4: Retry Without Sandbox                   │
│   - On sandbox denial, retry with user approval │
└─────────────────────────────────────────────────┘
```

**Source:** `flovyn-server/codex/codex-rs/core/src/tools/orchestrator.rs`

## 6.2 Sandbox Implementations

| Platform | Technology | Scope |
|----------|------------|-------|
| macOS | Seatbelt (sandbox-exec) | File paths, network |
| Linux | Landlock + Seccomp | File system, syscalls |
| Windows | Restricted Token | Capability drops |
| Docker | Container isolation | Full isolation |
| E2B/Daytona | Cloud sandbox | Full isolation + VNC |

## 6.3 Output Truncation (Critical for Token Management)

**All frameworks implement output limits:**

| Framework | Max Output | Strategy |
|-----------|------------|----------|
| Gemini CLI | 10K tokens | First 20% + Last 80% of lines |
| Open Interpreter | 2800 tokens | Head truncation |
| Dyad | 10K chars | Truncation |
| OpenManus | 10K-15K chars | Per-agent limits |

**Gemini CLI Pattern:**
```typescript
// Save full output, return summary
saveToTempFile(fullOutput);
return `${first20Percent}\n...\n${last80Percent}\n[Full output: ${path}]`;
```

## 6.4 Command Safety Analysis

**Categories:**
- **Safe (auto-approve):** `ls`, `cat`, `pwd`, `echo`, `grep`
- **Dangerous (require approval):** `rm`, `mv`, `chmod`, `chown`
- **Forbidden:** `rm -rf /`, `dd if=/dev/zero`, `:(){ :|:& };:`

**Pattern Matching:**
```typescript
const DANGEROUS_PATTERNS = [
  /rm\s+(-[rf]+\s+)*\//,  // rm with root path
  /dd\s+.*(of|if)=\/dev/,  // dd to devices
  />\s*\/dev\/sd[a-z]/,    // write to disk devices
];
```

## Source Code References

- Codex macOS: `flovyn-server/codex/codex-rs/core/src/seatbelt.rs`
- Codex Linux: `flovyn-server/codex/codex-rs/core/src/landlock.rs`
- OpenManus: `OpenManus/app/sandbox/`
