# fdev Implementation Plan

**Date:** 2026-01-20
**Design:** [20260120_flovyn_dev_workflow.md](../design/20260120_flovyn_dev_workflow.md)
**Status:** ✅ Complete

## Overview

Incremental implementation of `fdev` CLI tool. Each milestone is independently usable.

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

**Goal:** Replace `worktree.py` with `fdev` in `dev/bin/`, preserving existing functionality.

**Status:** ✅ Complete

### TODO

- [x] **1.1** Create CLI skeleton
  - [x] Create `dev/bin/fdev` (Python)
  - [x] Set up argument parsing (argparse)
  - [x] Add `--help` for all commands
  - [x] Make executable (`chmod +x`)

- [x] **1.2** Port `create` command
  - [x] Create worktrees for all repos (dev, flovyn-server, flovyn-app, sdk-*)
  - [x] Create branches in each repo
  - [x] Handle already-exists errors gracefully
  - [x] **Port allocation**: Generate unique ports in `worktrees/{feature}/dev/.env`
  - [x] Ports derived from offset (base + offset for each port)

- [x] **1.3** Port `delete` command
  - [x] Remove worktrees from all repos
  - [x] Handle not-exists errors gracefully
  - [x] Warning for uncommitted changes (with `--force` to override)
  - [x] Optional `--delete-branches` flag

- [x] **1.4** Port `status` command
  - [x] Show git status for each repo in worktree
  - [x] Summarize: clean/dirty, ahead/behind

- [x] **1.5** Port `commit` command
  - [x] Stage all changes in each repo
  - [x] Commit with same message across repos
  - [x] Show summary of what was committed

- [x] **1.6** Port `list` command
  - [x] List all local worktrees
  - [x] Show port offset for each worktree

- [x] **1.7** Add `env` command
  - [x] Show all allocated ports and URLs for a feature
  - [x] Read ports from worktree's `dev/.env` file

### Implementation Notes

**Simplified port tracking:** Instead of maintaining a separate `~/.flovyn/ports.json` file, the CLI reads ports directly from each worktree's `dev/.env` file. The next available offset is calculated by scanning existing worktrees.

**Port allocation on create:**
```
Offset 1: APP_PORT=3001, SERVER_HTTP_PORT=8001, SERVER_GRPC_PORT=9091, ...
Offset 2: APP_PORT=3002, SERVER_HTTP_PORT=8002, SERVER_GRPC_PORT=9092, ...
```

### Test

```bash
fdev create test-feature
fdev list
fdev status test-feature
fdev env test-feature
fdev delete test-feature
```

### Usable After

Basic worktree management with port isolation from new location.

---

## Milestone 2: Documentation Integration

**Goal:** Auto-create design docs when creating worktrees, manage doc lifecycle.

**Status:** ✅ Complete

### TODO

- [x] **2.1** Auto-create design doc on `create`
  - [x] Copy template from `dev/docs/templates/design.md`
  - [x] Generate filename: `YYYYMMDD_{feature}.md` (standard) or `features/{feature}/design.md` (large)
  - [x] Replace placeholders: `{Feature Title}`, `{feature}`, `{DATE}`
  - [x] Place in `dev/docs/design/` or `dev/docs/features/{feature}/`

- [x] **2.2** Add `--large` flag to `create`
  - [x] Creates subdirectory structure: `dev/docs/features/{feature}/`
  - [x] Design doc placed at `features/{feature}/design.md`
  - [x] Supports multiple plan files for phases

- [x] **2.3** Implement `fdev open <feature> [design|plan]`
  - [x] Find design or plan doc for feature
  - [x] Open in `$EDITOR` (default: vim)
  - [x] Default to design doc, optional `plan` argument for plan doc
  - [x] Interactive selection if multiple docs found

- [x] **2.4** Implement `fdev docs list <feature>`
  - [x] Search all doc directories for files matching feature
  - [x] List design and plan docs with paths
  - [x] Indicate if feature uses large feature structure

- [x] **2.5** Implement `fdev docs promote <feature>`
  - [x] Convert standard feature to large feature structure
  - [x] Move design doc to `features/{feature}/design.md`
  - [x] Move plan docs to `features/{feature}/plan.md` (or `plan_N.md` if multiple)

- [x] **2.6** Implement `fdev docs archive <feature>`
  - [x] Create archive folder: `dev/docs/archive/YYYYMMDD_{feature}/`
  - [x] Move design doc → `archive/YYYYMMDD_{feature}/design.md`
  - [x] Move plan doc → `archive/YYYYMMDD_{feature}/plan.md`
  - [x] Handle both standard and large feature structures

### Document Structure

**Standard feature (default):**
```
dev/docs/design/YYYYMMDD_{feature}.md
dev/docs/plans/YYYYMMDD_{feature}.md
```

**Large feature (`--large` or after `promote`):**
```
dev/docs/features/{feature}/
├── design.md
├── plan.md (or plan_phase1.md, plan_phase2.md, etc.)
└── ...
```

### Test

```bash
# Standard feature
fdev create webhook-retry
fdev docs list webhook-retry
fdev open webhook-retry

# Large feature
fdev create auth-system --large
fdev docs list auth-system

# Promote standard to large
fdev docs promote webhook-retry
fdev docs list webhook-retry  # Now shows features/ path

# Archive completed feature
fdev docs archive old-feature
ls dev/docs/archive/  # Should show YYYYMMDD_old-feature/
```

### Usable After

Worktrees with auto-generated design docs and doc lifecycle management.

---

## Milestone 3: Tmux + Claude Code Sessions

**Goal:** Each feature gets its own tmux session with Claude Code.

**Status:** ✅ Complete

### TODO

- [x] **3.1** Create tmux session on `create`
  - [x] Session name: `{feature}`
  - [x] Working directory: `worktrees/{feature}/`
  - [x] Check if session already exists
  - [x] Add `--no-session` flag to skip session creation

- [x] **3.2** Launch Claude Code in session
  - [x] Run `claude` command in tmux session
  - [x] Wait for Claude to initialize (2 second sleep)

- [x] **3.3** Send initial prompt
  - [x] Template with feature name and doc path
  - [x] Customizable via `docs/templates/prompts/initial.md`
  - [x] Sends via tmux send-keys

- [x] **3.4** Implement `fdev attach <feature>`
  - [x] Check if tmux session exists
  - [x] If no session but worktree exists, offer to create session
  - [x] Send resume prompt before attaching (configurable with `--no-resume`)
  - [x] Attach to session

- [x] **3.5** Define resume prompt template
  - [x] Customizable via `docs/templates/prompts/resume.md`
  - [x] Lists design and plan docs
  - [x] Asks Claude to continue from where left off

- [x] **3.6** Update `delete` to cleanup tmux
  - [x] Kill tmux session if exists
  - [x] Handles case where session doesn't exist

- [x] **3.7** Add `fdev sessions`
  - [x] List all flovyn-related tmux sessions
  - [x] Show: feature name, attached/detached, last activity

### Commands

```bash
# Create with tmux session (default)
fdev create webhook-retry

# Create without tmux session
fdev create webhook-retry --no-session

# Attach to session (sends resume prompt)
fdev attach webhook-retry

# Attach without resume prompt
fdev attach webhook-retry --no-resume

# List all flovyn sessions
fdev sessions

# Delete (also kills tmux session)
fdev delete webhook-retry
```

### Prompt Templates

Default prompts are built-in. Override by creating:
- `docs/templates/prompts/initial.md` - Initial prompt for new features
- `docs/templates/prompts/resume.md` - Resume prompt when re-attaching

Placeholders: `{feature}`, `{design_path}`, `{plan_path}`, `{docs_info}`

### Usable After

Full local workflow without GitHub integration.

---

## Milestone 4: GitHub Projects Integration

**Goal:** Pull tasks from GitHub Projects, sync status bidirectionally.

**Status:** ✅ Complete

### Prerequisites

GitHub Project created:
- **Project:** https://github.com/orgs/flovyn/projects/3
- **Fields:**
  - `Phase` (single-select): Backlog, Design, Planning, In Progress, Review, Done
  - `Kind` (single-select): Feature, Bug, Research
  - `Branch` (text): Branch name linking to local worktree

*Note: Used "Phase" instead of "Status" (reserved field), "Kind" instead of "Type" (reserved).*

### TODO

- [x] **4.1** Implement GitHub Project API helpers
  - [x] `gh_api()` - Execute GraphQL queries with proper variable handling
  - [x] `gh_get_project_id()` - Get project node ID
  - [x] `gh_get_field_ids()` - Get field IDs for Phase, Kind, Branch
  - [x] `gh_list_project_items()` - List all project items with fields
  - [x] `gh_update_item_field()` - Update text or single-select field
  - [x] `gh_add_issue_comment()` - Post comment to linked issue
  - [x] `gh_find_item_by_branch()` - Find item by branch name

- [x] **4.2** Implement `fdev list --remote`
  - [x] Fetch items from GitHub Project
  - [x] Group by phase with color coding
  - [x] Show local worktree indicator (●)
  - [x] Support filters: `--phase`, `--kind`

- [x] **4.3** Implement `fdev pick`
  - [x] Interactive selection (default: `Phase = Backlog`)
  - [x] Get Branch field from item (or generate from title)
  - [x] Run `create` with branch name
  - [x] Update Branch field in GitHub
  - [x] Update Phase: Backlog → Design
  - [x] Post comment to linked issue

- [x] **4.4** Implement `fdev move <feature> <phase>`
  - [x] Map feature to GitHub item (by branch name)
  - [x] Update GitHub Project item phase
  - [x] Post phase transition comment with doc summaries:
    - [x] Design → Planning: Extract Problem Statement, Solution from design doc
    - [x] Planning → In Progress: Extract TODO list from plan doc
    - [x] In Progress → Review: Show progress percentage
    - [x] → Done: Mark complete

- [x] **4.5** Implement `fdev sync`
  - [x] Compare local worktrees with GitHub items
  - [x] Show in-sync items with phase
  - [x] Show local-only (no GitHub item)
  - [x] Show remote-only (GitHub item with branch, no local worktree)
  - [x] Optional `--update-progress` to post progress updates

### Commands

```bash
# List remote items
fdev list --remote
fdev list -r --phase Backlog
fdev list -r --kind Feature

# Pick from backlog and create worktree
fdev pick
fdev pick --phase Design

# Move between phases (updates GitHub and posts summary)
fdev move webhook-retry Planning
fdev move webhook-retry "In Progress"
fdev move webhook-retry Review

# Sync local vs remote
fdev sync
fdev sync --update-progress
```

### Usable After

GitHub-driven workflow with bidirectional sync and automatic issue updates.

---

## ~~Milestone 5: Per-Worktree Docker Environment~~ → Integrated into Milestone 1

**Status:** ✅ Complete (integrated into Milestone 1)

**Reason:** With Milestone 0.7 (configurable ports in `dev/.env`), we can run multiple fully isolated instances by allocating different ports for ALL services per worktree. Port allocation was integrated directly into the `fdev create` command.

**Implementation:**
- Each worktree gets its own `dev/.env` with unique ports for ALL services
- Ports are derived from offset (scanned from existing worktrees)
- No separate tracking file needed - ports are read directly from `.env` files
- Each worktree runs its own infrastructure (postgres, nats, jaeger) on unique ports
- Complete isolation - no shared infrastructure between worktrees

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

**Status:** ✅ Complete

### TODO

- [x] **5.1** Implement `fdev research <topic>`
  - [x] Create `worktrees/{topic}/dev/` only (single repo)
  - [x] Create research doc from template (built-in default)
  - [x] Create tmux session
  - [x] Send research-specific initial prompt

- [x] **5.2** Create research initial prompt template
  - [x] Focus on exploration, not implementation
  - [x] Customizable via `docs/templates/prompts/research.md`
  - [x] Ask for findings and recommendation

- [x] **5.3** Integrate with GitHub Projects
  - [x] Support `pick --research` to filter Kind=Research items
  - [x] Post research start comment to GitHub issue

- [x] **5.4** Handle research → design transition
  - [x] `fdev docs mv {topic} research design`
  - [x] Transforms research doc structure to design doc format
  - [x] Can then create full worktree with `fdev create`

- [x] **5.5** Detect research worktrees
  - [x] `is_research_worktree()` helper (only dev/ exists)
  - [x] `list` command shows `[research]` indicator
  - [x] `delete` works correctly for research worktrees

### Commands

```bash
# Create research worktree
fdev research retry-strategies
fdev research retry-strategies --no-session

# Pick research tasks from GitHub
fdev pick --research

# Convert research to design
fdev docs mv retry-strategies research design

# List shows research worktrees
fdev list  # Shows [research] indicator
```

### Research Document Template

Default template includes:
- Objective
- Background
- Findings
- Options Considered (with pros/cons)
- Recommendation
- Next Steps
- References

### Usable After

Research workflow for exploration tasks without full multi-repo worktree overhead.

---

## Milestone 6: PR Creation + Archive

**Goal:** Streamlined PR creation and safe cleanup.

**Status:** ✅ Complete

### TODO

- [x] **6.1** Implement `fdev pr <feature>`
  - [x] Detect repos with uncommitted changes (warn)
  - [x] Detect repos with commits not on main
  - [x] Push branches to origin

- [x] **6.2** Create PRs with template
  - [x] Extract summary from design doc (Problem Statement, Solution)
  - [x] Generate PR body with:
    - Summary from design doc
    - Link to design doc
    - Test plan checklist
    - Claude Code attribution
  - [x] Create PR via `gh pr create`
  - [x] Post PR links to GitHub Project issue

- [x] **6.3** Implement `fdev archive <feature>` pre-flight checks
  - [x] Check for uncommitted changes (block if dirty)
  - [x] Check all PRs are merged (block if OPEN state)
  - [x] Show clear error messages
  - [x] Confirmation prompt before archiving

- [x] **6.4** Implement archive cleanup
  - [x] Archive docs (`fdev docs archive`)
  - [x] Kill tmux session
  - [x] Update GitHub Project status: → Done
  - [x] Post completion comment to issue
  - [x] Remove worktrees (reuses `delete` command)

- [x] **6.5** Add `--force` flag for archive
  - [x] Skip pre-flight checks
  - [x] Use for abandoned features

### Commands

```bash
# Create PRs for all repos with changes
fdev pr webhook-retry

# Archive after PRs merged (with checks)
fdev archive webhook-retry

# Force archive without checks (for abandoned features)
fdev archive webhook-retry --force
```

### PR Template

Generated PR body includes:
- Summary extracted from design doc
- Link to design doc
- Test plan checklist
- Claude Code attribution footer

### Usable After

Complete end-to-end workflow from feature creation to archive.

---

## Summary

| Milestone | Key Feature | Dependencies | Effort | Status |
|-----------|-------------|--------------|--------|--------|
| 0 | Migrate existing docs | None | Low | ✅ Done |
| 0.5 | Standardize on Mise | M0 | Low | ✅ Done |
| 0.6 | Centralized APP_URL | M0.5 | Low | ✅ Done |
| 0.7 | Configurable Ports | M0.6 | Low | ✅ Done |
| 1 | CLI + Worktrees + Port Allocation | M0 | Low | ✅ Done |
| 2 | Doc templates + lifecycle | M1 | Low | ✅ Done |
| 3 | Tmux + Claude | M1, M2 | Medium | ✅ Done |
| 4 | GitHub Projects | M1, M2, M3 | Medium | ✅ Done |
| ~~5~~ | ~~Docker per-worktree~~ → Port allocation | M1 | Low | ✅ Integrated into M1 |
| 5 | Research workflow | M1, M2, M3, M4 | Low | ✅ Done |
| 6 | PR + Archive | M1, M4 | Medium | ✅ Done |

**Recommended order:** 0 → 0.5 → 0.6 → 0.7 → 1 → 2 → 3 → 4 → 5 → 6

Port allocation (formerly M5) was integrated into M1 (worktree create).

---

## Completion Notes

**Completed:** 2026-01-21

All milestones implemented. The `fdev` CLI now provides a complete end-to-end workflow:

1. **Create feature** (`create` or `pick` from GitHub Backlog)
2. **Research** (`research` for exploration-only tasks)
3. **Design & Plan** (auto-generated docs, phase transitions via `move`)
4. **Implement** (isolated worktrees with unique ports, tmux + Claude integration)
5. **PR Creation** (`pr` command pushes and creates PRs across repos)
6. **Archive** (`archive` cleans up after merge)

All commands integrate with GitHub Projects for status tracking and automatic issue updates.

Each milestone can be tested independently before proceeding.
