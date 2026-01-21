# flovyn-dev Implementation Plan

**Date:** 2026-01-20
**Design:** [20260120_flovyn_dev_workflow.md](../design/20260120_flovyn_dev_workflow.md)
**Status:** In Progress

## Overview

Incremental implementation of `flovyn-dev` CLI tool. Each milestone is independently usable.

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

GitHub-driven workflow, manual Docker setup.

---

## Milestone 5: Per-Worktree Docker Environment

**Goal:** Each worktree gets its own isolated Docker stack with unique ports.

### TODO

- [ ] **5.1** Implement port allocation
  - [ ] Create `~/.flovyn/ports.json` schema
  - [ ] Allocate ports on `init-env` (find next available offset)
  - [ ] Release ports on `archive`/`delete`
  - [ ] Base ports: server=8000, app=3000, pg-server=5435, etc.

- [ ] **5.2** Create docker-compose template
  - [ ] Template with placeholders for ports and feature name
  - [ ] Services: postgres-server, postgres-app, nats, jaeger, server, app
  - [ ] Network: `flovyn-{feature}`
  - [ ] Volumes with feature-specific names

- [ ] **5.3** Implement `flovyn-dev init-env <feature>`
  - [ ] Allocate ports
  - [ ] Generate `worktrees/{feature}/dev/docker-compose.yml`
  - [ ] Generate `worktrees/{feature}/dev/.env`
  - [ ] Show allocated ports

- [ ] **5.4** Implement `flovyn-dev build <feature>`
  - [ ] Build `flovyn-server:{feature}` from worktree
  - [ ] Build `flovyn-app:{feature}` from worktree
  - [ ] Show build progress/errors

- [ ] **5.5** Implement `flovyn-dev start <feature>`
  - [ ] Check if images exist (prompt to build if not)
  - [ ] Run `docker compose up -d`
  - [ ] Wait for health checks
  - [ ] Show access URLs

- [ ] **5.6** Implement `flovyn-dev stop <feature>`
  - [ ] Run `docker compose down`
  - [ ] Optionally remove volumes (`--volumes` flag)

- [ ] **5.7** Implement `flovyn-dev logs <feature> [service]`
  - [ ] Run `docker compose logs -f [service]`
  - [ ] Default: all services

- [ ] **5.8** Implement `flovyn-dev env <feature>`
  - [ ] Show allocated ports and URLs
  - [ ] Show container status (running/stopped)

- [ ] **5.9** Implement `flovyn-dev rebuild <feature>`
  - [ ] Stop containers
  - [ ] Rebuild images
  - [ ] Start containers
  - [ ] Single command for code changes

### Test

```bash
flovyn-dev create webhook-retry
flovyn-dev init-env webhook-retry
cat ~/.flovyn/ports.json  # Should show allocation

flovyn-dev build webhook-retry
docker images | grep webhook-retry  # Should show images

flovyn-dev start webhook-retry
flovyn-dev env webhook-retry
curl http://localhost:3001/health  # Should respond

flovyn-dev logs webhook-retry server
flovyn-dev stop webhook-retry
```

### Usable After

Full isolated dev environments per feature.

---

## Milestone 6: Research Workflow

**Goal:** Lightweight research tasks without full worktree.

### TODO

- [ ] **6.1** Implement `flovyn-dev research <task>`
  - [ ] Create `worktrees/{topic}/dev/` only (single repo)
  - [ ] Create research doc from template
  - [ ] Create tmux session
  - [ ] Send research-specific initial prompt

- [ ] **6.2** Create research initial prompt template
  - [ ] Focus on exploration, not implementation
  - [ ] Include GitHub issue content
  - [ ] Ask for findings and recommendation

- [ ] **6.3** Integrate with GitHub Projects
  - [ ] Update status: Backlog → Research
  - [ ] Support `pick --research` to filter Research-type items

- [ ] **6.4** Handle research → design transition
  - [ ] `flovyn-dev docs mv {topic} research design`
  - [ ] `flovyn-dev pick {topic}` to create full worktree
  - [ ] Update GitHub status: Research → Design

- [ ] **6.5** Update `delete` for research worktrees
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

## Milestone 7: PR Creation + Archive

**Goal:** Streamlined PR creation and safe cleanup.

### TODO

- [ ] **7.1** Implement `flovyn-dev pr <feature>`
  - [ ] Detect repos with uncommitted changes (warn)
  - [ ] Detect repos with unpushed commits
  - [ ] Push branches to origin

- [ ] **7.2** Create PRs with template
  - [ ] Extract summary from design doc
  - [ ] Generate PR body with:
    - Summary
    - Link to design doc
    - Test plan checklist
  - [ ] Create PR via `gh pr create`
  - [ ] Link PR to GitHub Project item

- [ ] **7.3** Implement `flovyn-dev archive <feature>` pre-flight checks
  - [ ] Check for uncommitted changes (block if dirty)
  - [ ] Check all PRs are merged (block if open)
  - [ ] Show clear error messages

- [ ] **7.4** Implement archive cleanup
  - [ ] Stop Docker environment (if running)
  - [ ] Remove Docker images
  - [ ] Remove Docker volumes
  - [ ] Release port allocation
  - [ ] Archive docs (`flovyn-dev docs archive`)
  - [ ] Remove worktrees
  - [ ] Kill tmux session
  - [ ] Update GitHub status: → Done

- [ ] **7.5** Add `--force` flag for archive
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
docker images | grep webhook-retry  # Should not exist
cat ~/.flovyn/ports.json  # Should not have webhook-retry
```

### Usable After

Complete end-to-end workflow.

---

## Summary

| Milestone | Key Feature | Dependencies | Effort |
|-----------|-------------|--------------|--------|
| 0 | Migrate existing docs | None | Low |
| 1 | CLI + Worktrees | M0 | Low |
| 2 | Doc templates + lifecycle | M1 | Low |
| 3 | Tmux + Claude | M1, M2 | Medium |
| 4 | GitHub Projects | M1, M2, M3 | Medium |
| 5 | Docker per-worktree | M1 | High |
| 6 | Research workflow | M1, M2, M3, M4 | Low |
| 7 | PR + Archive | M1, M4, M5 | Medium |

**Recommended order:** 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7

Each milestone can be tested independently before proceeding.
