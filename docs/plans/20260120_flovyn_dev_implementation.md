# flovyn-dev Implementation Plan

**Date:** 2026-01-20
**Design:** [20260120_flovyn_dev_workflow.md](../design/20260120_flovyn_dev_workflow.md)
**Status:** In Progress

## Overview

Incremental implementation of `flovyn-dev` CLI tool. Each milestone is independently usable.

## Conventions

### Docker Images

All Docker images must be prefixed with the Scaleway container registry and tagged with the branch name:
```
rg.fr-par.scw.cloud/flovyn/<image-name>:<branch>
```

**Branch-specific tags prevent conflicts** when multiple worktrees run E2E tests simultaneously.

Examples:
- `rg.fr-par.scw.cloud/flovyn/flovyn-server:main`
- `rg.fr-par.scw.cloud/flovyn/flovyn-app:webhook-retry`
- `rg.fr-par.scw.cloud/flovyn/rust-examples-worker:schedules`

**Environment variables for E2E tests:**
- `FLOVYN_SERVER_IMAGE` - Full image name with tag
- `FLOVYN_APP_IMAGE` - Full image name with tag
- `FLOVYN_WORKER_IMAGE` - Full image name with tag

---

## Milestone 0: Migrate Existing Documentation

**Goal:** Move existing docs from scattered `.dev/docs/` folders to centralized `dev/docs/`.

### TODO

- [x] **0.1** Inventory existing docs
  - [x] List all files in `flovyn-server/.dev/docs/` (119 files)
  - [x] List all files in `flovyn-app/.dev/docs/` (4 files)
  - [x] List all files in `sdk-rust/.dev/docs/` (45 files)
  - [x] List all files in `sdk-kotlin/.dev/docs/` (3 files)
  - [x] Total: 171 files migrated

- [x] **0.2** Create migration script `dev/bin/migrate-docs.py`
  - [x] Parse source directories
  - [x] Normalize filenames:
    - [x] Add date prefix from git log if missing
    - [x] Remove sequence numbers (e.g., `_001-`)
    - [x] Convert kebab-case to snake_case
  - [x] Handle filename conflicts (same name from different repos)
  - [x] Generate `migration-map.txt` with old → new mappings

- [x] **0.3** Implement link normalization in migration script
  - [x] Update doc-to-doc links using filename mapping
  - [x] Update old repo paths (`flovyn-server/.dev/docs/` → `dev/docs/`)
  - [x] Normalize code references to `{repo}/{path}` format:
    - [x] Convert absolute paths
    - [x] Convert relative paths (infer repo from source)
    - [x] Add repo prefix where missing
  - [x] Generate warnings for broken/ambiguous links

- [x] **0.4** Create target directory structure
  - [x] `dev/docs/design/`
  - [x] `dev/docs/plans/`
  - [x] `dev/docs/research/`
  - [x] `dev/docs/bugs/`
  - [x] `dev/docs/guides/`
  - [x] `dev/docs/architecture/`
  - [x] `dev/docs/archive/`

- [x] **0.5** Run migration
  - [x] Dry run: `python3 dev/bin/migrate-docs.py --dry-run`
  - [x] Review output and mapping file
  - [x] Execute migration (177 files migrated)
  - [x] Verify file counts match

- [x] **0.6** Cleanup old locations
  - [x] Delete `.dev/docs/` from flovyn-server
  - [x] Delete `.dev/docs/` from flovyn-app
  - [x] Delete `.dev/docs/` from sdk-rust
  - [x] Delete `.dev/docs/` from sdk-kotlin
  - [x] Delete empty `.dev/` directories
  - [x] Update `.claude/rules/` files to reference centralized `dev/docs/`

### Reference

**Filename normalization rules:**
| Before | After | Rule |
|--------|-------|------|
| `webhook-retry.md` | `20251220_webhook_retry.md` | Add date from git log |
| `20251215_001-workflow-notification.md` | `20251215_workflow_notification.md` | Remove sequence number |
| `my-feature-design.md` | `20260101_my_feature_design.md` | kebab → snake, add date |
| `20251225_flovyn-server.md` | `20251225_flovyn_server.md` | kebab → snake |

**Link normalization rules:**
| Before | After |
|--------|-------|
| `[design](../design/webhook-retry.md)` | `[design](../design/20251220_webhook_retry.md)` |
| `flovyn-server/.dev/docs/design/foo.md` | `dev/docs/design/20251220_foo.md` |

**Code reference normalization:**
| Before | After |
|--------|-------|
| `/home/ubuntu/workspaces/flovyn/flovyn-server/src/foo.rs` | `flovyn-server/src/foo.rs` |
| `../../src/domain/foo.rs` | `flovyn-server/src/domain/foo.rs` |
| `src/api/rest/bar.rs` | `flovyn-server/src/api/rest/bar.rs` |

### Test

```bash
dev/bin/migrate-docs.sh --dry-run
dev/bin/migrate-docs.sh
ls dev/docs/design/ | wc -l  # Should show combined count
```

### Usable After

All docs in one place, ready for new workflow.

---

## Milestone 0.5: Standardize on Mise

**Goal:** Use mise for all dev tasks across all repos.

**Status:** ✅ Complete

### TODO

- [x] **0.5.1** Rename `dev/mise.toml` to `.mise.toml`
- [x] **0.5.2** Create `flovyn-server/.mise.toml`
  - [x] Add tools: `rust = "stable"`
  - [x] Add tasks: build, test, test:integration, test:loop, e2e, lint, db:connect, etc.
- [x] **0.5.3** Create `sdk-rust/.mise.toml`
  - [x] Add tools: `rust = "stable"`
  - [x] Add tasks: build, test, test:unit, test:tck, test:e2e, test:model, lint, examples
- [x] **0.5.4** Update `sdk-kotlin/.mise.toml`
  - [x] Add tasks: build, test, test:e2e, examples
- [x] **0.5.5** Update all CLAUDE.md files
  - [x] `flovyn-server/CLAUDE.md` - reference mise commands
  - [x] `flovyn-app/CLAUDE.md` - reference mise commands
  - [x] `sdk-rust/CLAUDE.md` - reference mise commands, update doc paths
  - [x] `sdk-kotlin/CLAUDE.md` - reference mise commands
- [x] **0.5.6** Commit and push all repos

### Result

| Repo | Config | Tools | Tasks |
|------|--------|-------|-------|
| `dev/` | `.mise.toml` | - | start, stop, server, app, db, etc. |
| `flovyn-server/` | `.mise.toml` | rust=stable | build, test, e2e, lint, db:connect, etc. |
| `flovyn-app/` | `.mise.toml` | node=22, pnpm | dev, build, lint, e2e, etc. |
| `sdk-rust/` | `.mise.toml` | rust=stable | build, test, lint, examples, etc. |
| `sdk-kotlin/` | `.mise.toml` | java=temurin-17 | build, test, examples, etc. |
| `sdk-python/` | `.mise.toml` | - | test, lint, format, typecheck |

---

## Milestone 0.6: Centralized APP_URL Configuration

**Goal:** Configure flovyn-app and flovyn-server to use centralized `APP_URL` for OIDC integration (remote access via Tailscale, etc.).

**Status:** ✅ Complete

### TODO

- [x] **0.6.1** Add `APP_URL` to `dev/.env`
  - [x] Default: `http://localhost:3000`
  - [x] Used as OIDC issuer in flovyn-app tokens
- [x] **0.6.2** Update `dev/dev.sh` for flovyn-app
  - [x] `start_app()` exports `NEXT_PUBLIC_APP_URL` from `APP_URL`
  - [x] `print_services()` shows configured `APP_URL`
- [x] **0.6.3** Update `dev/dev.sh` for flovyn-server
  - [x] `start_server()` sets Better Auth env vars from `APP_URL`:
    - `AUTH__BETTER_AUTH__VALIDATION_URL`
    - `AUTH__BETTER_AUTH__JWT__JWKS_URI`
    - `AUTH__BETTER_AUTH__JWT__ISSUER`
  - [x] Display OIDC provider URL on startup
- [x] **0.6.4** Document in `dev/CLAUDE.md`
  - [x] Add Key Environment Variables table
  - [x] Add "Remote Access" section explaining APP_URL effects

### Usage

```bash
# In dev/.env
APP_URL=https://your-host.ts.net

# Start services (both use APP_URL)
mise run server  # Trusts APP_URL as OIDC provider
mise run app     # Issues tokens with APP_URL as issuer
```

---

## Milestone 0.7: Configurable Ports and SDK Worker URL

**Goal:** Allow running multiple dev instances with custom ports, and have SDK examples automatically use the correct gRPC port.

**Status:** ✅ Complete

### TODO

- [x] **0.7.1** Add configurable application ports to `dev/.env`
  - [x] `APP_PORT` (default: 3000)
  - [x] `SERVER_HTTP_PORT` (default: 8000)
  - [x] `SERVER_GRPC_PORT` (default: 9090)
- [x] **0.7.2** Update `dev/dev.sh` to use port variables
  - [x] `start_server()` uses `SERVER_HTTP_PORT` and `SERVER_GRPC_PORT`
  - [x] `start_app()` uses `APP_PORT`
  - [x] Respect existing `PORT`, `SERVER_PORT`, `GRPC_SERVER_PORT` env vars (for backwards compatibility)
- [x] **0.7.3** Compute `FLOVYN_GRPC_SERVER_URL` from `SERVER_GRPC_PORT` in mise tasks
  - [x] SDK example tasks in `dev/.mise.toml` source `.env` and compute URL dynamically
  - [x] Workers automatically connect to the correct gRPC port
- [x] **0.7.4** Update `dev/README.md` with port configuration docs
- [x] **0.7.5** Update `dev/CLAUDE.md` with port configuration docs

### Usage

```bash
# In dev/.env - change ports to run multiple instances
APP_PORT=3001
SERVER_HTTP_PORT=8001
SERVER_GRPC_PORT=9091

# SDK examples automatically use SERVER_GRPC_PORT
mise run example:hello  # Connects to http://localhost:9091
```

---

## Milestone 1: CLI Foundation + Worktree Management

**Goal:** Replace `worktree.py` with `flovyn-dev` in `dev/bin/`, preserving existing functionality.

### TODO

- [ ] **1.1** Create CLI skeleton
  - [ ] Create `dev/bin/flovyn-dev` (Python)
  - [ ] Set up argument parsing (argparse or click)
  - [ ] Add `--help` for all commands
  - [ ] Make executable (`chmod +x`)

- [ ] **1.2** Port `create` command
  - [ ] Create worktrees for all repos (dev, flovyn-server, flovyn-app, sdk-*)
  - [ ] Create branches in each repo
  - [ ] Handle already-exists errors gracefully

- [ ] **1.3** Port `delete` command
  - [ ] Remove worktrees from all repos
  - [ ] Handle not-exists errors gracefully

- [ ] **1.4** Port `status` command
  - [ ] Show git status for each repo in worktree
  - [ ] Summarize: clean/dirty, ahead/behind

- [ ] **1.5** Port `commit` command
  - [ ] Stage all changes in each repo
  - [ ] Commit with same message across repos
  - [ ] Show summary of what was committed

- [ ] **1.6** Port `list` command
  - [ ] List all local worktrees
  - [ ] Show which repos each worktree contains

- [ ] **1.7** Add untracked file copying
  - [ ] Define `UNTRACKED_FILES` list (e.g., `sdk-rust/examples/.env`)
  - [ ] Copy from main to worktree on `create`

- [ ] **1.8** Deprecate old script
  - [ ] Add deprecation warning to `bin/worktree.py`
  - [ ] Point users to `dev/bin/flovyn-dev`

### Test

```bash
flovyn-dev create test-feature
flovyn-dev list
flovyn-dev status test-feature
flovyn-dev delete test-feature
```

### Usable After

Basic worktree management from new location.

---

## Milestone 2: Documentation Integration

**Goal:** Auto-create design docs when creating worktrees, manage doc lifecycle.

### TODO

- [ ] **2.1** Auto-create design doc on `create`
  - [ ] Copy template from `dev/docs/process/templates/design.md`
  - [ ] Generate filename: `YYYYMMDD_{feature}.md`
  - [ ] Replace placeholders: `{Feature Name}`, `{feature}`, `YYYY-MM-DD`
  - [ ] Place in `dev/docs/design/`

- [ ] **2.2** Implement `flovyn-dev open <feature>`
  - [ ] Find design doc for feature
  - [ ] Open in `$EDITOR` (default: vim)
  - [ ] Support `--plan` flag to open plan doc instead

- [ ] **2.3** Implement `flovyn-dev docs <feature>`
  - [ ] Search all doc directories for files matching feature
  - [ ] List: type, path, last modified
  - [ ] Example output:
    ```
    design  dev/docs/design/20260120_webhook_retry.md
    plan    dev/docs/plans/20260120_webhook_retry.md
    ```

- [ ] **2.4** Implement `flovyn-dev docs mv <feature> <from> <to>`
  - [ ] Move doc between directories (e.g., research → design)
  - [ ] Update filename if needed (keep date, update description)
  - [ ] Update internal links in the moved doc
  - [ ] Warn if target already exists

- [ ] **2.5** Implement `flovyn-dev docs archive <feature>`
  - [ ] Create archive folder: `dev/docs/archive/YYYYMMDD_{feature}/`
  - [ ] Move design doc → `archive/{feature}/design.md`
  - [ ] Move plan doc → `archive/{feature}/plan.md`
  - [ ] Move any bug docs related to feature

### Test

```bash
flovyn-dev create webhook-retry
cat dev/docs/design/20260120_webhook_retry.md  # Should exist

flovyn-dev docs webhook-retry
flovyn-dev open webhook-retry

flovyn-dev docs mv retry-strategies research design
flovyn-dev docs archive old-feature
ls dev/docs/archive/  # Should show old-feature/
```

### Usable After

Worktrees with auto-generated design docs and doc lifecycle management.

---

## Milestone 3: Tmux + Claude Code Sessions

**Goal:** Each feature gets its own tmux session with Claude Code.

### TODO

- [ ] **3.1** Create tmux session on `create`
  - [ ] Session name: `{feature}`
  - [ ] Working directory: `worktrees/{feature}/`
  - [ ] Check if session already exists

- [ ] **3.2** Launch Claude Code in session
  - [ ] Run `claude` command in tmux session
  - [ ] Wait for Claude to initialize (sleep or detect prompt)

- [ ] **3.3** Send initial prompt
  - [ ] Template with feature name and doc path
  - [ ] Include GitHub issue content (if available, placeholder for M4)
  - [ ] Escape special characters for tmux send-keys

- [ ] **3.4** Implement `flovyn-dev attach <feature>`
  - [ ] Check if tmux session exists
  - [ ] If no session, offer to create
  - [ ] Attach to session
  - [ ] Send resume prompt before attaching

- [ ] **3.5** Define resume prompt template
  - [ ] Ask Claude to read plan doc
  - [ ] Report current phase and TODO status
  - [ ] Identify next task

- [ ] **3.6** Update `delete` to cleanup tmux
  - [ ] Kill tmux session if exists
  - [ ] Don't error if session doesn't exist

- [ ] **3.7** Add `flovyn-dev sessions`
  - [ ] List all flovyn-related tmux sessions
  - [ ] Show: feature name, attached/detached, last activity

### Test

```bash
flovyn-dev create webhook-retry
tmux list-sessions | grep webhook-retry  # Should exist

flovyn-dev attach webhook-retry
# Verify: Claude received initial prompt

# Detach (Ctrl+B D), then:
flovyn-dev attach webhook-retry
# Verify: Claude received resume prompt

flovyn-dev delete webhook-retry
tmux list-sessions | grep webhook-retry  # Should not exist
```

### Usable After

Full local workflow without GitHub integration.

---

## Milestone 4: GitHub Projects Integration

**Goal:** Pull tasks from GitHub Projects, sync status bidirectionally.

### Prerequisites

Create GitHub Project manually:
```bash
gh project create --owner flovyn --title "Development"
# Via web UI: add Status, Type, Branch fields
```

### TODO

- [ ] **4.1** Implement GitHub Project API helpers
  - [ ] Get project ID by name
  - [ ] Get field IDs (Status, Type, Branch)
  - [ ] List project items with fields
  - [ ] Update item field value

- [ ] **4.2** Implement `flovyn-dev list --remote`
  - [ ] Fetch items from GitHub Project
  - [ ] Display table: Status, Title, Branch, Type
  - [ ] Support filters: `--status`, `--type`
  - [ ] Merge with local state (show which have worktrees)

- [ ] **4.3** Implement `flovyn-dev pick`
  - [ ] Interactive selection (default: `Status = Backlog`)
  - [ ] Get Branch field from item (or generate from title)
  - [ ] Fetch linked issue body for initial prompt
  - [ ] Run `create` with branch name
  - [ ] Update GitHub status: Backlog → Design

- [ ] **4.4** Implement `flovyn-dev move <feature> <status>`
  - [ ] Map feature to GitHub item (by branch name)
  - [ ] Validate transition (define allowed transitions)
  - [ ] Update GitHub Project item status
  - [ ] Show confirmation

- [ ] **4.5** Implement `flovyn-dev sync`
  - [ ] Compare local worktrees with GitHub items
  - [ ] Show orphaned local (no GitHub item)
  - [ ] Show orphaned remote (GitHub item with branch, no local worktree)
  - [ ] Offer to reconcile

### Test

```bash
# Create GitHub card with Branch = "webhook-retry"
flovyn-dev list --remote
flovyn-dev list --remote --status Backlog

flovyn-dev pick  # Interactive selection
# Verify: worktree created, GitHub status = Design

flovyn-dev move webhook-retry Planning
# Verify: GitHub status updated

flovyn-dev sync
```

### Usable After

GitHub-driven workflow.

---

## ~~Milestone 5: Per-Worktree Docker Environment~~ → Simplified to Port Allocation

**Status:** 🔄 Simplified - Full isolation via port allocation (no per-worktree Docker images)

**Reason:** With Milestone 0.7 (configurable ports in `dev/.env`), we can run multiple fully isolated instances by allocating different ports for ALL services per worktree.

**New approach:**
- Each worktree gets its own `dev/.env` with unique ports for ALL services
- Each worktree runs its own infrastructure (postgres, nats, jaeger) on unique ports
- Services run via `mise run start`, `mise run server`, `mise run app` from each worktree
- Complete isolation - no shared infrastructure between worktrees

### TODO (Simplified)

- [ ] **Port allocation on worktree create**
  - [ ] Track allocated ports in `~/.flovyn/ports.json`
  - [ ] Allocate unique ports for ALL services (offset from base ports)
  - [ ] Generate `worktrees/{feature}/dev/.env` with all allocated ports
  - [ ] Release ports on worktree delete

- [ ] **Implement `flovyn-dev env <feature>`**
  - [ ] Show all allocated ports and URLs for the feature

### Port Allocation Schema

All services get unique ports per worktree:

```json
{
  "allocations": {
    "webhook-retry": {
      "offset": 1,
      "APP_PORT": 3001,
      "SERVER_HTTP_PORT": 8001,
      "SERVER_GRPC_PORT": 9091,
      "SERVER_POSTGRES_PORT": 5436,
      "APP_POSTGRES_PORT": 5434,
      "NATS_PORT": 4223,
      "NATS_MONITOR_PORT": 8223,
      "JAEGER_UI_PORT": 16687,
      "JAEGER_OTLP_GRPC_PORT": 4318,
      "JAEGER_OTLP_HTTP_PORT": 4319
    },
    "schedules": {
      "offset": 2,
      "APP_PORT": 3002,
      "SERVER_HTTP_PORT": 8002,
      "SERVER_GRPC_PORT": 9092,
      "SERVER_POSTGRES_PORT": 5437,
      "APP_POSTGRES_PORT": 5435,
      "NATS_PORT": 4224,
      "NATS_MONITOR_PORT": 8224,
      "JAEGER_UI_PORT": 16688,
      "JAEGER_OTLP_GRPC_PORT": 4319,
      "JAEGER_OTLP_HTTP_PORT": 4320
    }
  },
  "next_offset": 3
}
```

### Running Multiple Features in Parallel

```bash
# Feature 1: webhook-retry (all ports offset by 1)
cd worktrees/webhook-retry/dev
mise run start   # Starts postgres:5436, nats:4223, jaeger:16687
mise run server  # HTTP:8001, gRPC:9091
mise run app     # App:3001

# Feature 2: schedules (all ports offset by 2)
cd worktrees/schedules/dev
mise run start   # Starts postgres:5437, nats:4224, jaeger:16688
mise run server  # HTTP:8002, gRPC:9092
mise run app     # App:3002

# Fully isolated - each has its own databases, message broker, tracing
```

---

## Milestone 5: Research Workflow

**Goal:** Lightweight research tasks without full worktree.

### TODO

- [ ] **5.1** Implement `flovyn-dev research <task>`
  - [ ] Create `worktrees/{topic}/dev/` only (single repo)
  - [ ] Create research doc from template
  - [ ] Create tmux session
  - [ ] Send research-specific initial prompt

- [ ] **5.2** Create research initial prompt template
  - [ ] Focus on exploration, not implementation
  - [ ] Include GitHub issue content
  - [ ] Ask for findings and recommendation

- [ ] **5.3** Integrate with GitHub Projects
  - [ ] Update status: Backlog → Research
  - [ ] Support `pick --research` to filter Research-type items

- [ ] **5.4** Handle research → design transition
  - [ ] `flovyn-dev docs mv {topic} research design`
  - [ ] `flovyn-dev pick {topic}` to create full worktree
  - [ ] Update GitHub status: Research → Design

- [ ] **5.5** Update `delete` for research worktrees
  - [ ] Detect research-only worktrees (only dev/ exists)
  - [ ] Clean up appropriately

### Test

```bash
flovyn-dev research "retry-strategies"
ls worktrees/retry-strategies/  # Should only have dev/
cat dev/docs/research/20260120_retry_strategies.md  # Should exist

flovyn-dev attach retry-strategies
# Verify: research-focused prompt

# When ready to proceed:
flovyn-dev docs mv retry-strategies research design
flovyn-dev pick retry-strategies  # Creates full worktree
```

### Usable After

Research workflow for exploration tasks.

---

## Milestone 6: PR Creation + Archive

**Goal:** Streamlined PR creation and safe cleanup.

### TODO

- [ ] **6.1** Implement `flovyn-dev pr <feature>`
  - [ ] Detect repos with uncommitted changes (warn)
  - [ ] Detect repos with unpushed commits
  - [ ] Push branches to origin

- [ ] **6.2** Create PRs with template
  - [ ] Extract summary from design doc
  - [ ] Generate PR body with:
    - Summary
    - Link to design doc
    - Test plan checklist
  - [ ] Create PR via `gh pr create`
  - [ ] Link PR to GitHub Project item

- [ ] **6.3** Implement `flovyn-dev archive <feature>` pre-flight checks
  - [ ] Check for uncommitted changes (block if dirty)
  - [ ] Check all PRs are merged (block if open)
  - [ ] Show clear error messages

- [ ] **6.4** Implement archive cleanup
  - [ ] Release port allocation (update `~/.flovyn/ports.json`)
  - [ ] Archive docs (`flovyn-dev docs archive`)
  - [ ] Remove worktrees
  - [ ] Kill tmux session
  - [ ] Update GitHub status: → Done

- [ ] **6.5** Add `--force` flag for archive
  - [ ] Skip pre-flight checks
  - [ ] Require confirmation
  - [ ] Use for abandoned features

### Test

```bash
# After completing implementation:
flovyn-dev pr webhook-retry
# Verify: PRs created, linked to project

# After PRs merged:
flovyn-dev archive webhook-retry
# Verify: all cleanup performed

# Check cleanup:
ls worktrees/ | grep webhook-retry  # Should not exist
tmux list-sessions | grep webhook-retry  # Should not exist
cat ~/.flovyn/ports.json  # Should not have webhook-retry
```

### Usable After

Complete end-to-end workflow.

---

## Summary

| Milestone | Key Feature | Dependencies | Effort | Status |
|-----------|-------------|--------------|--------|--------|
| 0 | Migrate existing docs | None | Low | ✅ Done |
| 0.5 | Standardize on Mise | M0 | Low | ✅ Done |
| 0.6 | Centralized APP_URL | M0.5 | Low | ✅ Done |
| 0.7 | Configurable Ports | M0.6 | Low | ✅ Done |
| 1 | CLI + Worktrees | M0 | Low | |
| 2 | Doc templates + lifecycle | M1 | Low | |
| 3 | Tmux + Claude | M1, M2 | Medium | |
| 4 | GitHub Projects | M1, M2, M3 | Medium | |
| ~~5~~ | ~~Docker per-worktree~~ → Port allocation | M1 | Low | Simplified |
| 5 | Research workflow | M1, M2, M3, M4 | Low | |
| 6 | PR + Archive | M1, M4 | Medium | |

**Recommended order:** 0 → 0.5 → 0.6 → 0.7 → 1 → 2 → 3 → 4 → 5 → 6

Port allocation (formerly M5) is now integrated into M1 (worktree create).

Each milestone can be tested independently before proceeding.
