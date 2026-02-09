# Agent Session Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Connect flovyn-app's mock AI chat UI to the real agent-server backend, enabling end-to-end AI agent sessions with LLM streaming, host OS tools, and multi-turn conversations.

**Architecture:** A session is a workflow execution of kind `"react-agent"`. flovyn-app creates workflow executions via REST, subscribes to SSE consolidated stream for real-time events, and sends follow-up messages via signals. agent-server gains host OS tools (read, write, edit, bash, grep, find) that run directly on the host filesystem, scoped to a configurable working directory.

**Important distinction:** An agent session runs as a workflow, but not all workflows are agent sessions. The AI UI pages (`/org/{orgSlug}/ai/...`) must always filter with `kind = "react-agent"` when listing or querying workflow executions. The existing general workflow pages remain untouched and continue showing all workflow kinds.

**Tech Stack:** Rust (agent-server), Next.js 15 + @assistant-ui/react + Effect (flovyn-app), Flovyn SDK (workflow execution, SSE streaming, signals)

**Design doc:** `dev/docs/design/20260802_agent-session-integration.md`

**Status:** All 21 tasks COMPLETE. Bugs discovered during smoke testing (Task 21) have been fixed.

### Bugs Found During Smoke Testing

1. **Infinite WORKFLOW_SUSPENDED loop** — Bug #005's auto-resume logic unconditionally resumed workflows when all tasks completed, even for signal waits. Fixed by adding typesafe `SuspendType` enum to proto and SDK. Server now only auto-resumes for `SuspendType::Task`. Branches: `fix/suspend-type-infinite-loop` in both `sdk-rust` and `flovyn-server`.
2. **No session ID in URL** — Fixed: URL now updates with workflow execution ID after session creation.
3. **Fake Research Report artifact** — Fixed: Removed hardcoded mock artifact from the UI.

---

## Phase 1: Agent-Server Host Tools

### Task 1: Add `working_directory` to `AgentWorkflowInput` ✅

**Files:**
- Modify: `agent-server/src/workflows/types.rs:5-39`

**Step 1: Write the failing test**

In `agent-server/src/workflows/agent.rs`, add a test that deserializes an `AgentWorkflowInput` with a `working_directory` field:

```rust
#[tokio::test]
async fn test_workflow_input_with_working_directory() {
    let json = serde_json::json!({
        "systemPrompt": "You are helpful.",
        "userPrompt": "Hello",
        "model": { "provider": "anthropic", "modelId": "claude-sonnet-4-20250514" },
        "tools": ["read", "bash"],
        "config": {},
        "workingDirectory": "/tmp/test-workspace"
    });
    let input: AgentWorkflowInput = serde_json::from_value(json).unwrap();
    assert_eq!(input.working_directory, Some("/tmp/test-workspace".to_string()));
}

#[tokio::test]
async fn test_workflow_input_without_working_directory() {
    let json = serde_json::json!({
        "systemPrompt": "You are helpful.",
        "userPrompt": "Hello",
        "model": { "provider": "anthropic", "modelId": "claude-sonnet-4-20250514" },
        "tools": [],
        "config": {}
    });
    let input: AgentWorkflowInput = serde_json::from_value(json).unwrap();
    assert_eq!(input.working_directory, None);
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test test_workflow_input_with_working_directory -- --nocapture`
Expected: FAIL — field `working_directory` does not exist on `AgentWorkflowInput`

**Step 3: Add the field**

In `agent-server/src/workflows/types.rs`, add to `AgentWorkflowInput`:

```rust
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AgentWorkflowInput {
    pub system_prompt: String,
    pub user_prompt: String,
    pub model: AgentModelConfig,
    #[serde(default)]
    pub tools: Vec<String>,
    #[serde(default)]
    pub config: AgentConfig,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test test_workflow_input_with -- --nocapture`
Expected: PASS (both tests)

**Step 5: Commit**

```bash
git add agent-server/src/workflows/types.rs agent-server/src/workflows/agent.rs
git commit -m "feat(agent-server): add working_directory to AgentWorkflowInput"
```

---

### Task 2: Add path validation utility ✅

**Files:**
- Create: `agent-server/src/tools/mod.rs`
- Create: `agent-server/src/tools/path_utils.rs`
- Modify: `agent-server/src/main.rs` (add `mod tools;`)

**Step 1: Write the failing test**

Create `agent-server/src/tools/path_utils.rs` with tests:

```rust
use std::path::{Path, PathBuf};

/// Resolve a path relative to the working directory.
/// Returns an error if the resolved path escapes the working directory.
pub fn resolve_path(path: &str, working_dir: &Path) -> Result<PathBuf, String> {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_resolve_relative_path() {
        let wd = Path::new("/tmp/workspace");
        let result = resolve_path("src/main.rs", wd).unwrap();
        assert_eq!(result, PathBuf::from("/tmp/workspace/src/main.rs"));
    }

    #[test]
    fn test_resolve_absolute_path_within() {
        let wd = Path::new("/tmp/workspace");
        let result = resolve_path("/tmp/workspace/src/main.rs", wd).unwrap();
        assert_eq!(result, PathBuf::from("/tmp/workspace/src/main.rs"));
    }

    #[test]
    fn test_reject_path_traversal() {
        let wd = Path::new("/tmp/workspace");
        let result = resolve_path("../../../etc/passwd", wd);
        assert!(result.is_err());
    }

    #[test]
    fn test_reject_absolute_path_outside() {
        let wd = Path::new("/tmp/workspace");
        let result = resolve_path("/etc/passwd", wd);
        assert!(result.is_err());
    }

    #[test]
    fn test_resolve_dot_path() {
        let wd = Path::new("/tmp/workspace");
        let result = resolve_path(".", wd).unwrap();
        assert_eq!(result, PathBuf::from("/tmp/workspace"));
    }

    #[test]
    fn test_resolve_nested_with_dotdot() {
        let wd = Path::new("/tmp/workspace");
        let result = resolve_path("src/../lib/foo.rs", wd).unwrap();
        assert_eq!(result, PathBuf::from("/tmp/workspace/lib/foo.rs"));
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test tools::path_utils -- --nocapture`
Expected: FAIL — `todo!()` panic

**Step 3: Implement resolve_path**

```rust
use std::path::{Path, PathBuf, Component};

/// Resolve a path relative to the working directory.
/// Returns an error if the resolved path escapes the working directory.
pub fn resolve_path(path: &str, working_dir: &Path) -> Result<PathBuf, String> {
    let raw = if Path::new(path).is_absolute() {
        PathBuf::from(path)
    } else {
        working_dir.join(path)
    };

    // Normalize: resolve `.` and `..` without touching the filesystem
    let mut normalized = PathBuf::new();
    for component in raw.components() {
        match component {
            Component::ParentDir => {
                normalized.pop();
            }
            Component::CurDir => {}
            other => normalized.push(other),
        }
    }

    // Check containment
    if !normalized.starts_with(working_dir) {
        return Err(format!(
            "Path '{}' resolves to '{}' which is outside working directory '{}'",
            path,
            normalized.display(),
            working_dir.display()
        ));
    }

    Ok(normalized)
}
```

Create `agent-server/src/tools/mod.rs`:

```rust
pub mod path_utils;
```

Add `mod tools;` to `agent-server/src/main.rs`.

**Step 4: Run test to verify it passes**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test tools::path_utils -- --nocapture`
Expected: PASS (all 6 tests)

**Step 5: Commit**

```bash
git add agent-server/src/tools/ agent-server/src/main.rs
git commit -m "feat(agent-server): add path validation utility for host tools"
```

---

### Task 3: Implement `ReadFileTask` ✅

**Files:**
- Create: `agent-server/src/tools/read_file.rs`
- Modify: `agent-server/src/tools/mod.rs`

**Step 1: Write the failing test**

In `agent-server/src/tools/read_file.rs`:

```rust
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ReadFileInput {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub offset: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ReadFileOutput {
    pub content: String,
    pub lines: usize,
    pub truncated: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn test_read_file_basic() {
        let dir = TempDir::new().unwrap();
        let file_path = dir.path().join("test.txt");
        fs::write(&file_path, "line1\nline2\nline3\n").unwrap();

        let result = read_file_impl(&file_path, None, None).unwrap();
        assert_eq!(result.lines, 3);
        assert!(!result.truncated);
        assert!(result.content.contains("line1"));
    }

    #[test]
    fn test_read_file_with_offset_and_limit() {
        let dir = TempDir::new().unwrap();
        let file_path = dir.path().join("test.txt");
        fs::write(&file_path, "line1\nline2\nline3\nline4\nline5\n").unwrap();

        let result = read_file_impl(&file_path, Some(2), Some(2)).unwrap();
        assert_eq!(result.lines, 2);
        assert!(result.content.contains("line3"));
        assert!(result.content.contains("line4"));
        assert!(!result.content.contains("line1"));
    }

    #[test]
    fn test_read_file_not_found() {
        let result = read_file_impl(&PathBuf::from("/nonexistent/file.txt"), None, None);
        assert!(result.is_err());
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test tools::read_file -- --nocapture`
Expected: FAIL — `read_file_impl` not defined

**Step 3: Implement read_file_impl and ReadFileTask**

```rust
use async_trait::async_trait;
use flovyn_worker_sdk::{TaskContext, TaskDefinition, RetryConfig};
use super::path_utils::resolve_path;

const DEFAULT_LINE_LIMIT: usize = 2000;

fn read_file_impl(
    path: &PathBuf,
    offset: Option<usize>,
    limit: Option<usize>,
) -> Result<ReadFileOutput, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("Failed to read '{}': {}", path.display(), e))?;

    let all_lines: Vec<&str> = content.lines().collect();
    let total = all_lines.len();
    let start = offset.unwrap_or(0);
    let max = limit.unwrap_or(DEFAULT_LINE_LIMIT);

    if start >= total {
        return Ok(ReadFileOutput {
            content: String::new(),
            lines: 0,
            truncated: false,
        });
    }

    let end = (start + max).min(total);
    let selected: Vec<String> = all_lines[start..end]
        .iter()
        .enumerate()
        .map(|(i, line)| format!("{:>6}\t{}", start + i + 1, line))
        .collect();

    Ok(ReadFileOutput {
        content: selected.join("\n"),
        lines: end - start,
        truncated: end < total,
    })
}

pub struct ReadFileTask {
    pub working_directory: PathBuf,
}

#[async_trait]
impl TaskDefinition for ReadFileTask {
    type Input = ReadFileInput;
    type Output = ReadFileOutput;

    fn kind(&self) -> &str { "read-file" }
    fn timeout_seconds(&self) -> Option<u32> { Some(30) }
    fn retry_config(&self) -> RetryConfig { RetryConfig { max_retries: 0, ..Default::default() } }

    async fn execute(
        &self,
        input: Self::Input,
        _ctx: &dyn TaskContext,
    ) -> flovyn_worker_sdk::Result<Self::Output> {
        let path = resolve_path(&input.path, &self.working_directory)
            .map_err(|e| flovyn_worker_sdk::FlovynError::TaskFailed(e))?;
        read_file_impl(&path, input.offset, input.limit)
            .map_err(|e| flovyn_worker_sdk::FlovynError::TaskFailed(e))
    }
}
```

Add `tempfile` to dev-dependencies in `Cargo.toml`.
Add `pub mod read_file;` to `agent-server/src/tools/mod.rs`.

**Step 4: Run test to verify it passes**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test tools::read_file -- --nocapture`
Expected: PASS

**Step 5: Commit**

```bash
git add agent-server/src/tools/read_file.rs agent-server/src/tools/mod.rs agent-server/Cargo.toml
git commit -m "feat(agent-server): implement ReadFileTask for host file reading"
```

---

### Task 4: Implement `WriteFileTask` ✅

**Files:**
- Create: `agent-server/src/tools/write_file.rs`
- Modify: `agent-server/src/tools/mod.rs`

**Step 1: Write the failing test**

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn test_write_file_new() {
        let dir = TempDir::new().unwrap();
        let file_path = dir.path().join("new_file.txt");
        let result = write_file_impl(&file_path, "hello world").unwrap();
        assert_eq!(result.bytes_written, 11);
        assert_eq!(fs::read_to_string(&file_path).unwrap(), "hello world");
    }

    #[test]
    fn test_write_file_creates_parent_dirs() {
        let dir = TempDir::new().unwrap();
        let file_path = dir.path().join("deep/nested/dir/file.txt");
        let result = write_file_impl(&file_path, "content").unwrap();
        assert_eq!(result.bytes_written, 7);
        assert!(file_path.exists());
    }

    #[test]
    fn test_write_file_overwrites() {
        let dir = TempDir::new().unwrap();
        let file_path = dir.path().join("existing.txt");
        fs::write(&file_path, "old content").unwrap();
        write_file_impl(&file_path, "new content").unwrap();
        assert_eq!(fs::read_to_string(&file_path).unwrap(), "new content");
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test tools::write_file -- --nocapture`
Expected: FAIL

**Step 3: Implement**

```rust
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use async_trait::async_trait;
use flovyn_worker_sdk::{TaskContext, TaskDefinition, RetryConfig};
use super::path_utils::resolve_path;

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct WriteFileInput {
    pub path: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct WriteFileOutput {
    pub bytes_written: usize,
}

fn write_file_impl(path: &PathBuf, content: &str) -> Result<WriteFileOutput, String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create directories for '{}': {}", path.display(), e))?;
    }
    std::fs::write(path, content)
        .map_err(|e| format!("Failed to write '{}': {}", path.display(), e))?;
    Ok(WriteFileOutput {
        bytes_written: content.len(),
    })
}

pub struct WriteFileTask {
    pub working_directory: PathBuf,
}

#[async_trait]
impl TaskDefinition for WriteFileTask {
    type Input = WriteFileInput;
    type Output = WriteFileOutput;

    fn kind(&self) -> &str { "write-file" }
    fn timeout_seconds(&self) -> Option<u32> { Some(30) }
    fn retry_config(&self) -> RetryConfig { RetryConfig { max_retries: 0, ..Default::default() } }

    async fn execute(
        &self,
        input: Self::Input,
        _ctx: &dyn TaskContext,
    ) -> flovyn_worker_sdk::Result<Self::Output> {
        let path = resolve_path(&input.path, &self.working_directory)
            .map_err(|e| flovyn_worker_sdk::FlovynError::TaskFailed(e))?;
        write_file_impl(&path, &input.content)
            .map_err(|e| flovyn_worker_sdk::FlovynError::TaskFailed(e))
    }
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test tools::write_file -- --nocapture`
Expected: PASS

**Step 5: Commit**

```bash
git add agent-server/src/tools/write_file.rs agent-server/src/tools/mod.rs
git commit -m "feat(agent-server): implement WriteFileTask for host file writing"
```

---

### Task 5: Implement `EditFileTask` ✅

**Files:**
- Create: `agent-server/src/tools/edit_file.rs`
- Modify: `agent-server/src/tools/mod.rs`

**Step 1: Write the failing test**

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[test]
    fn test_edit_unique_match() {
        let dir = TempDir::new().unwrap();
        let file_path = dir.path().join("test.rs");
        fs::write(&file_path, "fn foo() {\n    old_code();\n}\n").unwrap();

        let result = edit_file_impl(&file_path, "old_code()", "new_code()", false).unwrap();
        assert_eq!(result.replacements, 1);
        let content = fs::read_to_string(&file_path).unwrap();
        assert!(content.contains("new_code()"));
        assert!(!content.contains("old_code()"));
    }

    #[test]
    fn test_edit_non_unique_match_fails() {
        let dir = TempDir::new().unwrap();
        let file_path = dir.path().join("test.rs");
        fs::write(&file_path, "let x = 1;\nlet x = 1;\n").unwrap();

        let result = edit_file_impl(&file_path, "let x = 1;", "let x = 2;", false);
        assert!(result.is_err()); // Not unique
    }

    #[test]
    fn test_edit_replace_all() {
        let dir = TempDir::new().unwrap();
        let file_path = dir.path().join("test.rs");
        fs::write(&file_path, "let x = 1;\nlet x = 1;\n").unwrap();

        let result = edit_file_impl(&file_path, "let x = 1;", "let x = 2;", true).unwrap();
        assert_eq!(result.replacements, 2);
    }

    #[test]
    fn test_edit_no_match() {
        let dir = TempDir::new().unwrap();
        let file_path = dir.path().join("test.rs");
        fs::write(&file_path, "fn foo() {}\n").unwrap();

        let result = edit_file_impl(&file_path, "nonexistent", "replacement", false);
        assert!(result.is_err());
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test tools::edit_file -- --nocapture`
Expected: FAIL

**Step 3: Implement**

```rust
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use async_trait::async_trait;
use flovyn_worker_sdk::{TaskContext, TaskDefinition, RetryConfig};
use super::path_utils::resolve_path;

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct EditFileInput {
    pub path: String,
    pub old_string: String,
    pub new_string: String,
    #[serde(default)]
    pub replace_all: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct EditFileOutput {
    pub replacements: usize,
}

fn edit_file_impl(
    path: &PathBuf,
    old_string: &str,
    new_string: &str,
    replace_all: bool,
) -> Result<EditFileOutput, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("Failed to read '{}': {}", path.display(), e))?;

    let count = content.matches(old_string).count();
    if count == 0 {
        return Err(format!(
            "No matches found for the specified old_string in '{}'",
            path.display()
        ));
    }
    if count > 1 && !replace_all {
        return Err(format!(
            "Found {} matches for old_string in '{}'. Use replace_all=true to replace all, or provide more context to make the match unique.",
            count,
            path.display()
        ));
    }

    let new_content = if replace_all {
        content.replace(old_string, new_string)
    } else {
        content.replacen(old_string, new_string, 1)
    };

    std::fs::write(path, &new_content)
        .map_err(|e| format!("Failed to write '{}': {}", path.display(), e))?;

    Ok(EditFileOutput {
        replacements: if replace_all { count } else { 1 },
    })
}

pub struct EditFileTask {
    pub working_directory: PathBuf,
}

#[async_trait]
impl TaskDefinition for EditFileTask {
    type Input = EditFileInput;
    type Output = EditFileOutput;

    fn kind(&self) -> &str { "edit-file" }
    fn timeout_seconds(&self) -> Option<u32> { Some(30) }
    fn retry_config(&self) -> RetryConfig { RetryConfig { max_retries: 0, ..Default::default() } }

    async fn execute(
        &self,
        input: Self::Input,
        _ctx: &dyn TaskContext,
    ) -> flovyn_worker_sdk::Result<Self::Output> {
        let path = resolve_path(&input.path, &self.working_directory)
            .map_err(|e| flovyn_worker_sdk::FlovynError::TaskFailed(e))?;
        edit_file_impl(&path, &input.old_string, &input.new_string, input.replace_all)
            .map_err(|e| flovyn_worker_sdk::FlovynError::TaskFailed(e))
    }
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test tools::edit_file -- --nocapture`
Expected: PASS

**Step 5: Commit**

```bash
git add agent-server/src/tools/edit_file.rs agent-server/src/tools/mod.rs
git commit -m "feat(agent-server): implement EditFileTask with uniqueness checking"
```

---

### Task 6: Implement `BashTask` with streaming ✅

**Files:**
- Create: `agent-server/src/tools/bash.rs`
- Modify: `agent-server/src/tools/mod.rs`

**Step 1: Write the failing test**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_bash_simple_command() {
        let dir = tempfile::TempDir::new().unwrap();
        let result = bash_impl("echo hello", dir.path(), 10).await.unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(result.stdout.contains("hello"));
    }

    #[tokio::test]
    async fn test_bash_stderr() {
        let dir = tempfile::TempDir::new().unwrap();
        let result = bash_impl("echo error >&2", dir.path(), 10).await.unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(result.stderr.contains("error"));
    }

    #[tokio::test]
    async fn test_bash_nonzero_exit() {
        let dir = tempfile::TempDir::new().unwrap();
        let result = bash_impl("exit 42", dir.path(), 10).await.unwrap();
        assert_eq!(result.exit_code, 42);
    }

    #[tokio::test]
    async fn test_bash_timeout() {
        let dir = tempfile::TempDir::new().unwrap();
        let result = bash_impl("sleep 60", dir.path(), 1).await.unwrap();
        assert_eq!(result.timed_out, true);
    }

    #[tokio::test]
    async fn test_bash_working_directory() {
        let dir = tempfile::TempDir::new().unwrap();
        let result = bash_impl("pwd", dir.path(), 10).await.unwrap();
        assert!(result.stdout.trim().ends_with(dir.path().file_name().unwrap().to_str().unwrap()));
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test tools::bash -- --nocapture`
Expected: FAIL

**Step 3: Implement**

```rust
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use async_trait::async_trait;
use flovyn_worker_sdk::{TaskContext, TaskDefinition, RetryConfig};
use tokio::process::Command;
use tokio::io::{AsyncBufReadExt, BufReader};

const DEFAULT_TIMEOUT_SECS: u64 = 120;

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct BashInput {
    pub command: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct BashOutput {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
}

async fn bash_impl(
    command: &str,
    working_dir: &Path,
    timeout_secs: u64,
) -> Result<BashOutput, String> {
    let mut child = Command::new("bash")
        .arg("-c")
        .arg(command)
        .current_dir(working_dir)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to spawn bash: {}", e))?;

    let timeout = tokio::time::Duration::from_secs(timeout_secs);

    match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(Ok(output)) => {
            Ok(BashOutput {
                exit_code: output.status.code().unwrap_or(-1),
                stdout: String::from_utf8_lossy(&output.stdout).to_string(),
                stderr: String::from_utf8_lossy(&output.stderr).to_string(),
                timed_out: false,
            })
        }
        Ok(Err(e)) => Err(format!("Command failed: {}", e)),
        Err(_) => {
            // Timeout — kill the process
            let _ = child.kill().await;
            Ok(BashOutput {
                exit_code: -1,
                stdout: String::new(),
                stderr: format!("Command timed out after {}s", timeout_secs),
                timed_out: true,
            })
        }
    }
}

pub struct BashTask {
    pub working_directory: PathBuf,
}

#[async_trait]
impl TaskDefinition for BashTask {
    type Input = BashInput;
    type Output = BashOutput;

    fn kind(&self) -> &str { "bash" }
    fn uses_streaming(&self) -> bool { true }
    fn timeout_seconds(&self) -> Option<u32> { Some(300) }
    fn retry_config(&self) -> RetryConfig { RetryConfig { max_retries: 0, ..Default::default() } }

    async fn execute(
        &self,
        input: Self::Input,
        ctx: &dyn TaskContext,
    ) -> flovyn_worker_sdk::Result<Self::Output> {
        let timeout_secs = input.timeout.unwrap_or(DEFAULT_TIMEOUT_SECS);

        // For the TaskDefinition version, we stream stdout/stderr via ctx
        let mut child = Command::new("bash")
            .arg("-c")
            .arg(&input.command)
            .current_dir(&self.working_directory)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| flovyn_worker_sdk::FlovynError::TaskFailed(format!("Failed to spawn bash: {}", e)))?;

        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();

        let mut stdout_reader = BufReader::new(stdout).lines();
        let mut stderr_reader = BufReader::new(stderr).lines();

        let mut stdout_buf = String::new();
        let mut stderr_buf = String::new();

        let timeout = tokio::time::Duration::from_secs(timeout_secs);
        let deadline = tokio::time::Instant::now() + timeout;

        loop {
            tokio::select! {
                line = stdout_reader.next_line() => {
                    match line {
                        Ok(Some(l)) => {
                            let _ = ctx.stream_data_value(serde_json::json!({
                                "type": "terminal",
                                "stream": "stdout",
                                "data": format!("{}\n", l),
                            })).await;
                            stdout_buf.push_str(&l);
                            stdout_buf.push('\n');
                        }
                        Ok(None) => {}
                        Err(_) => {}
                    }
                }
                line = stderr_reader.next_line() => {
                    match line {
                        Ok(Some(l)) => {
                            let _ = ctx.stream_data_value(serde_json::json!({
                                "type": "terminal",
                                "stream": "stderr",
                                "data": format!("{}\n", l),
                            })).await;
                            stderr_buf.push_str(&l);
                            stderr_buf.push('\n');
                        }
                        Ok(None) => {}
                        Err(_) => {}
                    }
                }
                _ = tokio::time::sleep_until(deadline) => {
                    let _ = child.kill().await;
                    return Ok(BashOutput {
                        exit_code: -1,
                        stdout: stdout_buf,
                        stderr: format!("Command timed out after {}s", timeout_secs),
                        timed_out: true,
                    });
                }
                status = child.wait() => {
                    match status {
                        Ok(s) => {
                            return Ok(BashOutput {
                                exit_code: s.code().unwrap_or(-1),
                                stdout: stdout_buf,
                                stderr: stderr_buf,
                                timed_out: false,
                            });
                        }
                        Err(e) => {
                            return Err(flovyn_worker_sdk::FlovynError::TaskFailed(
                                format!("Command failed: {}", e)
                            ));
                        }
                    }
                }
            }
        }
    }
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test tools::bash -- --nocapture`
Expected: PASS

**Step 5: Commit**

```bash
git add agent-server/src/tools/bash.rs agent-server/src/tools/mod.rs
git commit -m "feat(agent-server): implement BashTask with stdout/stderr streaming"
```

---

### Task 7: Implement `GrepTask` and `FindTask` ✅

**Files:**
- Create: `agent-server/src/tools/grep.rs`
- Create: `agent-server/src/tools/find.rs`
- Modify: `agent-server/src/tools/mod.rs`

**Step 1: Write the failing tests**

For grep — use `bash` subprocess with `grep -rn`:

```rust
// agent-server/src/tools/grep.rs
#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[tokio::test]
    async fn test_grep_basic() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("test.rs"), "fn main() {\n    println!(\"hello\");\n}\n").unwrap();
        let result = grep_impl("println", dir.path(), None, None).await.unwrap();
        assert!(result.matches.iter().any(|m| m.line.contains("println")));
    }

    #[tokio::test]
    async fn test_grep_no_match() {
        let dir = TempDir::new().unwrap();
        fs::write(dir.path().join("test.rs"), "fn main() {}\n").unwrap();
        let result = grep_impl("nonexistent", dir.path(), None, None).await.unwrap();
        assert!(result.matches.is_empty());
    }
}
```

For find — use `bash` subprocess with `find`:

```rust
// agent-server/src/tools/find.rs
#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    #[tokio::test]
    async fn test_find_by_glob() {
        let dir = TempDir::new().unwrap();
        fs::create_dir_all(dir.path().join("src")).unwrap();
        fs::write(dir.path().join("src/main.rs"), "").unwrap();
        fs::write(dir.path().join("src/lib.rs"), "").unwrap();
        fs::write(dir.path().join("README.md"), "").unwrap();

        let result = find_impl("*.rs", dir.path()).await.unwrap();
        assert_eq!(result.files.len(), 2);
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test tools::grep tools::find -- --nocapture`
Expected: FAIL

**Step 3: Implement both**

`grep.rs` — shell out to `grep -rn --include=<glob>`:

```rust
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct GrepInput {
    pub pattern: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub glob: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct GrepOutput {
    pub matches: Vec<GrepMatch>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct GrepMatch {
    pub file: String,
    pub line_number: usize,
    pub line: String,
}

async fn grep_impl(
    pattern: &str,
    working_dir: &Path,
    search_path: Option<&str>,
    glob_filter: Option<&str>,
) -> Result<GrepOutput, String> {
    let mut cmd = tokio::process::Command::new("grep");
    cmd.arg("-rn").arg("--color=never");

    if let Some(g) = glob_filter {
        cmd.arg(format!("--include={}", g));
    }

    cmd.arg(pattern);
    cmd.arg(search_path.unwrap_or("."));
    cmd.current_dir(working_dir);

    let output = cmd.output().await
        .map_err(|e| format!("grep failed: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let matches: Vec<GrepMatch> = stdout
        .lines()
        .filter(|l| !l.is_empty())
        .take(200)  // Limit results
        .filter_map(|line| {
            // Format: file:line_number:content
            let mut parts = line.splitn(3, ':');
            let file = parts.next()?;
            let line_num: usize = parts.next()?.parse().ok()?;
            let content = parts.next()?.to_string();
            Some(GrepMatch {
                file: file.to_string(),
                line_number: line_num,
                line: content,
            })
        })
        .collect();

    Ok(GrepOutput { matches })
}
```

`find.rs` — shell out to `find . -name <pattern>`:

```rust
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct FindInput {
    pub pattern: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct FindOutput {
    pub files: Vec<String>,
}

async fn find_impl(pattern: &str, working_dir: &Path) -> Result<FindOutput, String> {
    let output = tokio::process::Command::new("find")
        .arg(".")
        .arg("-name")
        .arg(pattern)
        .arg("-type")
        .arg("f")
        .current_dir(working_dir)
        .output()
        .await
        .map_err(|e| format!("find failed: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let files: Vec<String> = stdout
        .lines()
        .filter(|l| !l.is_empty())
        .take(500)
        .map(|l| l.strip_prefix("./").unwrap_or(l).to_string())
        .collect();

    Ok(FindOutput { files })
}
```

Add `TaskDefinition` impls similar to ReadFileTask pattern. Add `pub mod grep;` and `pub mod find;` to `mod.rs`.

**Step 4: Run tests to verify they pass**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test tools::grep tools::find -- --nocapture`
Expected: PASS

**Step 5: Commit**

```bash
git add agent-server/src/tools/grep.rs agent-server/src/tools/find.rs agent-server/src/tools/mod.rs
git commit -m "feat(agent-server): implement GrepTask and FindTask"
```

---

### Task 8: Register new tools in tool registry and main.rs ✅

**Files:**
- Modify: `agent-server/src/tools.rs` (the existing `TOOL_REGISTRY`)
- Modify: `agent-server/src/main.rs`

**Step 1: Write the failing test**

Add to existing tests in `agent-server/src/tools.rs`:

```rust
#[test]
fn test_host_tools_registered() {
    let tools = available_tools();
    assert!(tools.contains(&"read".to_string()));
    assert!(tools.contains(&"write".to_string()));
    assert!(tools.contains(&"edit".to_string()));
    assert!(tools.contains(&"bash".to_string()));
    assert!(tools.contains(&"grep".to_string()));
    assert!(tools.contains(&"find".to_string()));
    assert!(tools.contains(&"run-sandbox".to_string()));
}
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test test_host_tools_registered -- --nocapture`
Expected: FAIL — new tools not in registry

**Step 3: Add tool schemas to TOOL_REGISTRY**

In `agent-server/src/tools.rs`, add entries for each new tool with their JSON schemas (derived from the Input types via `schemars::schema_for!`). Also add to `main.rs`:

```rust
// In main.rs — determine working directory
let working_dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/tmp"));

let client = FlovynClient::builder()
    .server_url(&server_url)
    .worker_token(&worker_token)
    .org_id(org_id)
    .queue(&queue)
    .register_workflow(AgentWorkflow)
    .register_task(LlmRequestTask { registry: registry.clone() })
    .register_task(RunSandboxTask)
    .register_task(ReadFileTask { working_directory: working_dir.clone() })
    .register_task(WriteFileTask { working_directory: working_dir.clone() })
    .register_task(EditFileTask { working_directory: working_dir.clone() })
    .register_task(BashTask { working_directory: working_dir.clone() })
    .register_task(GrepTask { working_directory: working_dir.clone() })
    .register_task(FindTask { working_directory: working_dir.clone() })
    .build()
    .await?;
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test test_host_tools_registered -- --nocapture`
Expected: PASS

**Step 5: Run full test suite**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add agent-server/src/tools.rs agent-server/src/main.rs
git commit -m "feat(agent-server): register all host tools in registry and main.rs"
```

---

### Task 9: Emit `tool_call_start` / `tool_call_end` from AgentWorkflow ✅

**Files:**
- Modify: `agent-server/src/workflows/agent.rs:114-148` (tool execution section)

**Step 1: Write the failing test**

Add to agent workflow tests:

```rust
#[tokio::test]
async fn test_tool_call_events_streamed() {
    // Use the existing test harness pattern from agent.rs
    // Verify that when a tool call is executed, tool_call_start and
    // tool_call_end events are streamed via ctx.stream_data_value()
    // Check the mock context captures these calls
}
```

Note: The exact test depends on how the test harness mock context is structured. Check existing tests in `agent.rs:184-403` for the pattern.

**Step 2: Run test to verify it fails**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test test_tool_call_events -- --nocapture`
Expected: FAIL

**Step 3: Add streaming events around tool execution**

In `agent-server/src/workflows/agent.rs`, in the tool execution loop (around line 114-148), add:

```rust
// Before tool execution
let _ = ctx.stream_data_value(serde_json::json!({
    "type": "tool_call_start",
    "tool_call": {
        "id": tool_call.id,
        "name": tool_call.name,
        "arguments": tool_call.arguments,
    }
})).await;

// Execute tool
let tool_result_value = ctx.schedule_raw(&tool_call.name, tool_call.arguments.clone()).await?;

// After tool execution
let _ = ctx.stream_data_value(serde_json::json!({
    "type": "tool_call_end",
    "tool_call": {
        "id": tool_call.id,
        "name": tool_call.name,
    },
    "result": tool_result_value,
})).await;

// Emit artifact event for write/edit tools
if tool_call.name == "write-file" || tool_call.name == "edit-file" {
    if let Some(path) = tool_call.arguments.get("path").and_then(|v| v.as_str()) {
        let _ = ctx.stream_data_value(serde_json::json!({
            "type": "artifact",
            "path": path,
            "action": if tool_call.name == "write-file" { "write" } else { "edit" },
            "artifact_type": "code",
        })).await;
    }
}
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/manhha/Developer/manhha/flovyn/agent-server && cargo test -- --nocapture`
Expected: PASS

**Step 5: Commit**

```bash
git add agent-server/src/workflows/agent.rs
git commit -m "feat(agent-server): emit tool_call_start/end and artifact events from workflow"
```

---

## Phase 2: Frontend Chat Adapter

> **Important:** flovyn-app has an auto-generated API client package at `packages/api/` (generated from OpenAPI spec).
> It provides React Query hooks (`useTriggerWorkflow`, `useSignalWorkflow`, `useCancelWorkflow`, `useListWorkflows`, etc.)
> and lower-level `fetch*` functions (`fetchTriggerWorkflow`, `fetchSignalWorkflow`, `fetchCancelWorkflow`).
> The server-side client is at `packages/api/src/server.ts` (`createServerClient`).
> **All API calls MUST use `@workspace/api` — never raw `fetch`.**

### Task 10: Create `flovyn-chat-adapter.ts` ✅

**Files:**
- Create: `flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts`

**Step 1: Write the adapter**

This adapter bridges `@assistant-ui/react` and the Flovyn workflow API. It uses `fetchTriggerWorkflow` and `fetchSignalWorkflow` from `@workspace/api` (the auto-generated OpenAPI client).

```typescript
// flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts

import type { ChatModelAdapter, ChatModelRunOptions } from "@assistant-ui/react";
import { fetchTriggerWorkflow, fetchSignalWorkflow } from "@workspace/api";

export interface FlovynChatAdapterOptions {
  orgSlug: string;
  model: { provider: string; modelId: string };
  tools: string[];
  config: {
    maxTurns?: number;
    maxTokens?: number;
    temperature?: number;
    thinking?: string;
  };
  systemPrompt?: string;
  workingDirectory?: string;
}

interface FlovynChatAdapterState {
  sessionId: string | null;
}

export function createFlovynChatAdapter(
  options: FlovynChatAdapterOptions
): ChatModelAdapter {
  const state: FlovynChatAdapterState = { sessionId: null };

  return {
    async *run({ messages, abortSignal }: ChatModelRunOptions) {
      const lastMessage = messages[messages.length - 1];
      const userText =
        lastMessage?.role === "user"
          ? lastMessage.content
              .filter((c): c is { type: "text"; text: string } => c.type === "text")
              .map((c) => c.text)
              .join("\n")
          : "";

      if (!state.sessionId) {
        // First message: create workflow execution via @workspace/api
        const data = await fetchTriggerWorkflow({
          pathParams: { orgSlug: options.orgSlug },
          body: {
            kind: "react-agent",
            input: {
              systemPrompt:
                options.systemPrompt ||
                "You are a helpful coding assistant. You have access to tools for reading, writing, and editing files, running shell commands, and searching codebases.",
              userPrompt: userText,
              model: options.model,
              tools: options.tools,
              config: options.config,
              workingDirectory: options.workingDirectory,
            },
          },
        });
        state.sessionId = data.workflowExecutionId;
      } else {
        // Follow-up: send signal via @workspace/api
        await fetchSignalWorkflow({
          pathParams: {
            orgSlug: options.orgSlug,
            workflowExecutionId: state.sessionId,
          },
          body: {
            signalName: "userMessage",
            signalValue: { text: userText },
          },
        });
      }

      // Subscribe to SSE consolidated stream
      yield* streamWorkflowSSE(
        options.orgSlug,
        state.sessionId!,
        abortSignal
      );
    },
  };
}
```

The `streamWorkflowSSE` generator function connects to the consolidated SSE stream and yields `@assistant-ui/react` compatible events. This needs to parse the SSE events from the design doc's streaming protocol.

Note: Check `fetchTriggerWorkflow` and `fetchSignalWorkflow` signatures in `packages/api/src/flovynServerApiComponents.ts` — the exact param shape may differ slightly from above. Adjust the pathParams/body shape to match.

**Step 2: Verify it compiles**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm tsc --noEmit --filter web`
Expected: PASS (or fix any type errors)

**Step 3: Commit**

```bash
git add flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts
git commit -m "feat(flovyn-app): create flovyn-chat-adapter for real backend integration"
```

---

### Task 11: Implement `streamWorkflowSSE` generator ✅

**Files:**
- Modify: `flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts` (add the SSE streaming function)

**Step 1: Implement the SSE event parser and generator**

Add to `flovyn-chat-adapter.ts`:

```typescript
async function* streamWorkflowSSE(
  orgSlug: string,
  sessionId: string,
  abortSignal?: AbortSignal
): AsyncGenerator</* @assistant-ui/react event types */> {
  const url = `/api/orgs/${orgSlug}/workflow-executions/${sessionId}/stream/consolidated`;

  const eventSource = new EventSource(url);

  try {
    // Create a queue for events
    const queue: Array<MessageEvent | { type: "error"; error: Event } | null> = [];
    let resolve: (() => void) | null = null;

    const push = (item: typeof queue[0]) => {
      queue.push(item);
      if (resolve) {
        resolve();
        resolve = null;
      }
    };

    eventSource.addEventListener("token", (e) => push(e));
    eventSource.addEventListener("data", (e) => push(e));
    eventSource.addEventListener("error", (e) => push({ type: "error", error: e }));

    abortSignal?.addEventListener("abort", () => {
      push(null); // Signal end
      eventSource.close();
    });

    while (true) {
      if (queue.length === 0) {
        await new Promise<void>((r) => { resolve = r; });
      }

      const event = queue.shift();
      if (event === null || event === undefined) break;

      if ("type" in event && event.type === "error") continue;

      const msgEvent = event as MessageEvent;
      const eventType = msgEvent.type; // "token" or "data"

      if (eventType === "token") {
        // Plain text token
        yield { type: "text-delta" as const, textDelta: msgEvent.data };
      } else if (eventType === "data") {
        // Structured event — parse JSON
        try {
          const parsed = JSON.parse(msgEvent.data);
          const innerData = parsed.data ?? parsed;

          if (typeof innerData === "object" && innerData.type) {
            switch (innerData.type) {
              case "thinking_delta":
                // Yield as reasoning delta if supported
                break;
              case "tool_call_start":
                yield {
                  type: "tool-call-begin" as const,
                  toolCallId: innerData.tool_call.id,
                  toolName: innerData.tool_call.name,
                };
                yield {
                  type: "tool-call-delta" as const,
                  toolCallId: innerData.tool_call.id,
                  argsTextDelta: JSON.stringify(innerData.tool_call.arguments),
                };
                break;
              case "tool_call_end":
                yield {
                  type: "tool-result" as const,
                  toolCallId: innerData.tool_call.id,
                  result: innerData.result,
                };
                break;
              case "terminal":
                // Terminal output — route to tool card via custom event
                break;
              case "artifact":
                // Artifact — route to workspace panel
                break;
            }
          }
        } catch {
          // Non-JSON data event, skip
        }
      }
    }
  } finally {
    eventSource.close();
  }
}
```

Note: The exact yield types depend on `@assistant-ui/react`'s `ChatModelAdapter` return type. Check the library's types to confirm the event shape. The mock adapter at `flovyn-app/apps/web/lib/ai/mock-chat-adapter.ts:1-96` shows the pattern.

**Step 2: Verify it compiles**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm tsc --noEmit --filter web`
Expected: PASS

**Step 3: Commit**

```bash
git add flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts
git commit -m "feat(flovyn-app): implement SSE streaming in chat adapter"
```

---

### Task 12: Wire "New Run" page to real adapter ✅

**Files:**
- Modify: `flovyn-app/apps/web/components/ai/run/unified-run-view.tsx:164` (swap mock adapter)
- Modify: `flovyn-app/apps/web/app/org/[orgSlug]/ai/page.tsx` (pass orgSlug)
- Modify: `flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/new/page.tsx`

**Step 1: Replace mock adapter with real adapter in `unified-run-view.tsx`**

Find the line that creates the mock adapter (around line 164 where `AssistantRuntimeProvider` is set up) and replace with:

```typescript
import { createFlovynChatAdapter } from "@/lib/ai/flovyn-chat-adapter";

// Inside the component:
const adapter = useMemo(
  () =>
    createFlovynChatAdapter({
      orgSlug: params.orgSlug, // Pass from page props
      model: { provider: "openrouter", modelId: "deepseek/deepseek-chat-v3-0324" },
      tools: ["read", "write", "edit", "bash", "grep", "find", "run-sandbox"],
      config: { maxTurns: 25 },
    }),
  [params.orgSlug]
);
```

**Step 2: Verify it compiles and renders**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm dev --filter web`
Navigate to http://localhost:3000/org/dev/ai and type a prompt.

Expected: The page submits a real POST to `/api/orgs/dev/workflow-executions` and subscribes to SSE. May need the backend running to work end-to-end.

**Step 3: Commit**

```bash
git add flovyn-app/apps/web/components/ai/run/unified-run-view.tsx flovyn-app/apps/web/app/org/[orgSlug]/ai/page.tsx flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/new/page.tsx
git commit -m "feat(flovyn-app): wire new run page to real flovyn chat adapter"
```

---

## Phase 3: Tool Execution UI

### Task 13: Build generic tool execution cards ✅

**Files:**
- Modify: `flovyn-app/apps/web/components/ai/chat/tool-execution-ui.tsx`

**Step 1: Replace hardcoded tool UIs with event-driven rendering**

Replace the existing `PlanningToolUI`, `WebSearchToolUI`, etc. with generic renderers driven by tool name from the SSE stream:

```typescript
// Replace existing makeAssistantToolUI calls with:

export function ToolExecutionCard({ toolCall }: { toolCall: { name: string; args: any; result?: any; status: string } }) {
  switch (toolCall.name) {
    case "bash":
    case "run-sandbox":
      return (
        <TimelineStep
          label={`Running: ${toolCall.name}`}
          detail={truncate(toolCall.args?.command || toolCall.args?.code || "", 80)}
          statusType={toolCall.status}
          type="tool"
        />
      );
    case "read":
    case "read-file":
      return (
        <TimelineStep
          label="Reading file"
          detail={toolCall.args?.path}
          statusType={toolCall.status}
          type="tool"
        />
      );
    case "write":
    case "write-file":
      return (
        <TimelineStep
          label="Writing file"
          detail={toolCall.args?.path}
          statusType={toolCall.status}
          type="tool"
        />
      );
    case "edit":
    case "edit-file":
      return (
        <TimelineStep
          label="Editing file"
          detail={toolCall.args?.path}
          statusType={toolCall.status}
          type="tool"
        />
      );
    case "grep":
      return (
        <TimelineStep
          label="Searching files"
          detail={`Pattern: ${toolCall.args?.pattern}`}
          statusType={toolCall.status}
          type="tool"
        />
      );
    case "find":
      return (
        <TimelineStep
          label="Finding files"
          detail={`Pattern: ${toolCall.args?.pattern}`}
          statusType={toolCall.status}
          type="tool"
        />
      );
    default:
      return (
        <TimelineStep
          label={toolCall.name}
          detail={JSON.stringify(toolCall.args).slice(0, 80)}
          statusType={toolCall.status}
        />
      );
  }
}

function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max) + "..." : s;
}
```

Register a catch-all tool UI with `makeAssistantToolUI` that renders `ToolExecutionCard`.

**Step 2: Verify it compiles**

Run: `cd /Users/manhha/Developer/manhha/flovyn/flovyn-app && pnpm tsc --noEmit --filter web`
Expected: PASS

**Step 3: Commit**

```bash
git add flovyn-app/apps/web/components/ai/chat/tool-execution-ui.tsx
git commit -m "feat(flovyn-app): replace hardcoded tool UIs with generic event-driven cards"
```

---

### Task 14: Connect terminal view to real terminal stream events ✅

**Files:**
- Modify: `flovyn-app/apps/web/components/ai/chat/terminal-view.tsx`
- Modify: `flovyn-app/apps/web/components/ai/run/run-panel-content.tsx`

**Step 1: Add live terminal streaming support**

Update `TerminalView` to accept a stream of terminal events in addition to static `initialContent`:

```typescript
interface TerminalViewProps {
  initialContent?: string;
  onReady?: (terminal: Terminal) => void; // Expose terminal for live writes
}
```

In the chat adapter or unified-run-view, when `terminal` events arrive from SSE, write them to the terminal instance:

```typescript
// In the streaming handler:
if (event.type === "terminal") {
  terminalRef.current?.write(event.data);
}
```

**Step 2: Verify it renders**

Run the app, trigger a bash command, and verify terminal output appears in the sandbox tab.

**Step 3: Commit**

```bash
git add flovyn-app/apps/web/components/ai/chat/terminal-view.tsx flovyn-app/apps/web/components/ai/run/run-panel-content.tsx
git commit -m "feat(flovyn-app): connect terminal view to real-time SSE terminal events"
```

---

## Phase 4: Follow-ups and Session Management

### Task 15: Wire message composer for follow-up signals ✅

**Files:**
- Modify: `flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts`
- Modify: `flovyn-app/apps/web/components/ai/assistant-ui/thread.tsx`

**Step 1: Handle `waiting_for_input` status**

The chat adapter already handles follow-ups (sends signal instead of creating new execution). The UI needs to:

1. Listen for `WorkflowState` SSE events where `key=status` and `value=waiting_for_input`
2. Enable the composer input when status is `waiting_for_input`
3. Disable composer while agent is running

Update the adapter's SSE handler to detect status changes and update the thread state.

**Step 2: Verify follow-ups work**

Start a session, wait for `waiting_for_input`, type a follow-up message, verify the signal is sent and agent resumes.

**Step 3: Commit**

```bash
git add flovyn-app/apps/web/lib/ai/flovyn-chat-adapter.ts flovyn-app/apps/web/components/ai/assistant-ui/thread.tsx
git commit -m "feat(flovyn-app): enable follow-up messages via workflow signals"
```

---

### Task 16: Wire run list page to real workflow executions ✅

**Files:**
- Modify: `flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/page.tsx`

**Step 1: Replace mock data with API call**

Replace `RUNS_DATA` import with `fetchListWorkflows` from `@workspace/api`:

```typescript
import { fetchListWorkflows } from "@workspace/api";

export default async function RunsPage({ params }: { params: Promise<{ orgSlug: string }> }) {
  const { orgSlug } = await params;
  const data = await fetchListWorkflows({
    pathParams: { orgSlug },
    queryParams: { query: 'kind = "react-agent" ORDER BY createdAt DESC', limit: 50 },
  });
  // Map data.workflowExecutions to the Run interface shape
  // ...
}
```

**Step 2: Verify the page loads runs from the API**

Navigate to `/org/dev/ai/runs` and verify it shows real workflow executions (or empty state if none exist).

**Step 3: Commit**

```bash
git add flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/page.tsx
git commit -m "feat(flovyn-app): wire runs page to real workflow execution API"
```

---

### Task 17: Wire run detail page to load conversation history ✅

**Files:**
- Modify: `flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/[runId]/page.tsx`

**Step 1: Fetch messages from workflow state**

Use `fetchGetWorkflow` from `@workspace/api`:

```typescript
import { fetchGetWorkflow } from "@workspace/api";

async function getRunData(orgSlug: string, runId: string) {
  return fetchGetWorkflow({
    pathParams: { orgSlug, workflowExecutionId: runId },
  });
}
```

The messages are stored in workflow state via `ctx.set_raw("messages", ...)` in agent-server. The state endpoint provides them.

**Step 2: Render the historical view**

Pass the fetched messages to `UnifiedRunView` as `historicalRun` data, mapping the agent-server message format to the UI's expected format.

**Step 3: Commit**

```bash
git add flovyn-app/apps/web/app/org/[orgSlug]/ai/runs/[runId]/page.tsx
git commit -m "feat(flovyn-app): wire run detail page to real conversation history"
```

---

### Task 18: Add cancel button ✅

**Files:**
- Modify: `flovyn-app/apps/web/components/ai/run/unified-run-view.tsx`

**Step 1: Add cancel button to the UI**

Add a cancel button that appears when the session is running. Use `useCancelWorkflow` mutation hook from `@workspace/api`:

```typescript
import { useCancelWorkflow } from "@workspace/api";

// Inside the component:
const cancelMutation = useCancelWorkflow();

const handleCancel = () => {
  if (!sessionId) return;
  cancelMutation.mutate({
    pathParams: { orgSlug, workflowExecutionId: sessionId },
    body: {},
  });
};
```

Wire it into the header or status indicator area of the unified run view. Disable the button while `cancelMutation.isPending`.

**Step 2: Verify cancel works**

Start a long-running session, click cancel, verify the agent stops cleanly.

**Step 3: Commit**

```bash
git add flovyn-app/apps/web/components/ai/run/unified-run-view.tsx
git commit -m "feat(flovyn-app): add cancel button for running sessions"
```

---

### Task 19: Add model/config selector ✅

**Files:**
- Modify: `flovyn-app/apps/web/components/ai/run/unified-run-view.tsx`
- Modify: `flovyn-app/apps/web/app/org/[orgSlug]/ai/page.tsx` (the home/launcher page)

**Step 1: Add model dropdown and config options**

In the launcher page and/or unified run view, add:

```typescript
const MODELS = [
  { label: "GLM 4.7", provider: "openrouter", modelId: "thudm/glm-4" },
  { label: "Kimi K2 Thinking", provider: "openrouter", modelId: "moonshot/kimi-k2" },
  { label: "Deepseek 3.2", provider: "openrouter", modelId: "deepseek/deepseek-chat-v3-0324" },
];
```

Add a select dropdown and pass the chosen model to `createFlovynChatAdapter`. Add a thinking level toggle (minimal/medium/high).

**Step 2: Verify selector works**

Change the model, submit a prompt, verify the workflow is created with the selected model.

**Step 3: Commit**

```bash
git add flovyn-app/apps/web/components/ai/run/unified-run-view.tsx flovyn-app/apps/web/app/org/[orgSlug]/ai/page.tsx
git commit -m "feat(flovyn-app): add model/config selector with GLM, Kimi K2, Deepseek 3.2"
```

---

### Task 20: Add system prompt editor ✅

**Files:**
- Modify: `flovyn-app/apps/web/app/org/[orgSlug]/ai/page.tsx`

**Step 1: Add collapsible system prompt field**

Below the main prompt textarea, add an expandable "System Prompt" section with a default coding assistant prompt. User can override it. Pass the value to `createFlovynChatAdapter`.

**Step 2: Verify it works**

Expand the system prompt field, modify it, submit a prompt, verify the custom system prompt is sent in the workflow input.

**Step 3: Commit**

```bash
git add flovyn-app/apps/web/app/org/[orgSlug]/ai/page.tsx
git commit -m "feat(flovyn-app): add system prompt editor to run creation"
```

---

## Phase 5: End-to-End Verification

### Task 21: End-to-end smoke test ✅

**Files:** None (manual testing)

**Step 1: Start all services**

```bash
cd /Users/manhha/Developer/manhha/flovyn/dev
mise run start        # Docker infrastructure
mise run server       # flovyn-server
mise run app          # flovyn-app
```

Start agent-server:
```bash
cd /Users/manhha/Developer/manhha/flovyn/agent-server
DOTENV_PATH=../dev/.env cargo run
```

**Step 2: Test one-shot execution**

1. Navigate to http://localhost:3000/org/dev/ai
2. Type: "Read the README.md file in the current directory"
3. Verify: LLM response streams, read tool call appears in timeline, file content shown

**Step 3: Test multi-turn conversation**

1. After the first response completes, type: "Now list all .rs files"
2. Verify: Signal sent, agent resumes, find/grep tool executes, results stream back

**Step 4: Test bash with terminal output**

1. Type: "Run 'echo hello world' in the terminal"
2. Verify: Terminal tab shows "hello world" streaming output

**Step 5: Test cancel**

1. Type a long-running prompt
2. Click cancel
3. Verify: Agent stops, status shows cancelled

**Step 6: Test run history**

1. Navigate to /org/dev/ai/runs
2. Verify completed/cancelled runs appear
3. Click a run to view its conversation history

**Step 7: Document results and commit any fixes**

```bash
git add -A
git commit -m "fix: end-to-end integration fixes from smoke testing"
```

---

## Appendix: Key File Reference

### agent-server

| File | Purpose |
|------|---------|
| `src/main.rs` | Worker entry point, task/workflow registration |
| `src/tools.rs` | Tool registry (JSON schemas) |
| `src/tools/mod.rs` | Tool module exports |
| `src/tools/path_utils.rs` | Path validation (NEW) |
| `src/tools/read_file.rs` | ReadFileTask (NEW) |
| `src/tools/write_file.rs` | WriteFileTask (NEW) |
| `src/tools/edit_file.rs` | EditFileTask (NEW) |
| `src/tools/bash.rs` | BashTask with streaming (NEW) |
| `src/tools/grep.rs` | GrepTask (NEW) |
| `src/tools/find.rs` | FindTask (NEW) |
| `src/workflows/types.rs` | AgentWorkflowInput (MODIFIED) |
| `src/workflows/agent.rs` | AgentWorkflow loop (MODIFIED) |
| `src/tasks/llm_request.rs` | LLM streaming (existing, unchanged) |
| `src/tasks/run_sandbox.rs` | Docker sandbox (existing, unchanged) |

### flovyn-app

| File | Purpose |
|------|---------|
| `apps/web/lib/ai/flovyn-chat-adapter.ts` | Real chat adapter (NEW) |
| `apps/web/lib/ai/mock-chat-adapter.ts` | Mock adapter (existing, kept for dev) |
| `apps/web/components/ai/chat/tool-execution-ui.tsx` | Tool cards (MODIFIED) |
| `apps/web/components/ai/chat/terminal-view.tsx` | Terminal view (MODIFIED) |
| `apps/web/components/ai/run/unified-run-view.tsx` | Main run view (MODIFIED) |
| `apps/web/app/org/[orgSlug]/ai/page.tsx` | Home page (MODIFIED) |
| `apps/web/app/org/[orgSlug]/ai/runs/page.tsx` | Runs list (MODIFIED) |
| `apps/web/app/org/[orgSlug]/ai/runs/[runId]/page.tsx` | Run detail (MODIFIED) |
| `apps/web/app/org/[orgSlug]/ai/runs/new/page.tsx` | New run (MODIFIED) |

### flovyn-server

Changes made to fix the infinite WORKFLOW_SUSPENDED loop (branch: `fix/suspend-type-infinite-loop`):

| File | Purpose |
|------|---------|
| `server/proto/flovyn.proto` | Added `SuspendType` enum and `suspend_type` field to `SuspendWorkflowCommand` |
| `server/src/api/grpc/workflow_dispatch.rs` | Bug #005 fix: only auto-resume for `SuspendType::Task`, store suspend info in events |
| `server/tests/integration/streaming_tests.rs` | Updated `FlovynError::Suspended` with `suspend_type` field |
| `server/tests/integration/suspend_type_tests.rs` | NEW: Regression test for infinite suspend loop |
| `server/tests/integration_tests.rs` | Register new test module |

### sdk-rust

Changes made to support typesafe `SuspendType` (branch: `fix/suspend-type-infinite-loop`):

| File | Purpose |
|------|---------|
| `proto/flovyn.proto` | Added `SuspendType` enum |
| `worker-core/proto/flovyn.proto` | Added `SuspendType` enum |
| `worker-core/src/workflow/command.rs` | Added `SuspendType` Rust enum, `suspend_type` field on `SuspendWorkflow` |
| `worker-sdk/src/workflow/future.rs` | All futures produce correct `SuspendType` |
| `worker-sdk/src/workflow/context_impl.rs` | `SuspensionCell` carries `(String, SuspendType)` tuple |
| `worker-sdk/src/worker/workflow_worker.rs` | Maps Rust `SuspendType` to proto `SuspendType` in gRPC |
| + 12 more files | Mechanical updates across worker-sdk, worker-ffi, worker-napi |

**Follow-up:** Other SDKs that depend on sdk-rust's proto changes (see follow-up tasks below).

Existing APIs (unchanged):
- `POST /api/orgs/{org}/workflow-executions` — create execution
- `GET /api/orgs/{org}/workflow-executions/{id}/stream/consolidated` — SSE stream
- `POST /api/orgs/{org}/workflow-executions/{id}/signal` — send signal
- `POST /api/orgs/{org}/workflow-executions/{id}/cancel` — cancel
- `GET /api/orgs/{org}/workflow-executions` — list executions

---

## Follow-up: Update Dependent SDKs for SuspendType

The `SuspendType` enum was added to the proto and sdk-rust. Other SDKs that depend on sdk-rust via FFI/NAPI need to be updated to propagate the new `suspend_type` field through to gRPC commands.

**Context:** sdk-rust's `worker-ffi` (UniFFI for Kotlin/Swift/Python) and `worker-napi` (NAPI-RS for TypeScript) currently default `suspend_type` to `SuspendType::Task` since their own command enums don't carry it yet. This means the server will auto-resume correctly for task waits but won't distinguish other suspension types from these SDKs.

### Follow-up Task A: Update sdk-kotlin for SuspendType

**Repo:** `sdk-kotlin`
**Dependency:** Via UniFFI from `sdk-rust/worker-ffi`

Steps:
1. Rebuild sdk-rust FFI bindings (`cargo build -p flovyn-worker-ffi`) to regenerate the UniFFI scaffolding with the new `SuspendType` enum
2. Regenerate `worker-native/src/main/kotlin/uniffi/flovyn_worker_ffi/flovyn_worker_ffi.kt`
3. Update `worker-sdk/src/main/kotlin/ai/flovyn/sdk/worker/WorkflowWorker.kt` to propagate `suspend_type` from workflow futures to the FFI command
4. Update `worker-sdk/src/main/kotlin/ai/flovyn/sdk/workflow/WorkflowContextImpl.kt` to carry suspension type info
5. Add E2E test: workflow that schedules a task then waits for a signal — verify no infinite suspend loop

### Follow-up Task B: Update sdk-typescript for SuspendType

**Repo:** `sdk-typescript`
**Dependency:** Via NAPI-RS from `sdk-rust/worker-napi`

Steps:
1. Rebuild sdk-rust NAPI bindings (`cargo build -p flovyn-worker-napi`) to regenerate TypeScript types with the new `SuspendType` enum
2. Update `packages/native/src/index.ts` to re-export `SuspendType` if needed
3. Update `packages/sdk/src/worker/` to propagate `suspend_type` from workflow futures to NAPI commands
4. Add E2E test: workflow that schedules a task then waits for a signal — verify no infinite suspend loop

### Follow-up Task C: Fix FFI/NAPI default SuspendType

**Repo:** `sdk-rust`
**Files:** `worker-ffi/src/command.rs`, `worker-napi/src/command.rs`

Currently these files default to `SuspendType::Task` (FFI) or `SuspendType::Unspecified` (NAPI) when converting from their local command types. Once the downstream SDKs carry `SuspendType`, update these converters to use the actual value instead of a hardcoded default.
