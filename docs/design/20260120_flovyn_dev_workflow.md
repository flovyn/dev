# Development Workflow Redesign

**Date:** 2026-01-20
**Status:** Draft / Discussion

## Current State

### Repository Structure
```
flovyn/
├── dev/                    # Dev environment configs
├── flovyn-app/             # Frontend application
├── flovyn-server/          # Rust backend
├── sdk-kotlin/             # Kotlin SDK
├── sdk-python/             # Python SDK
├── sdk-rust/               # Rust SDK
├── dev/
│   └── bin/flovyn-dev      # Development workflow manager
└── worktrees/              # Feature worktrees (e.g., worktrees/schedules/)
```

### Current Documentation Location
Documentation is scattered across repositories:
- `flovyn-server/.dev/docs/` → bugs, design, plans, guides, research
- `flovyn-app/.dev/docs/` → bugs, design, plans
- `sdk-*/.dev/docs/` → minimal

### Current worktree.py Capabilities
- `create <feature>` - Creates worktrees + branches across all repos
- `delete <feature>` - Removes worktrees
- `status <feature>` - Shows git status across repos
- `commit <feature> -m "msg"` - Commits to all repos with same message
- `list` - Lists all feature worktrees

### Pain Points
1. **Scattered docs** - Cross-repo features require hunting through multiple `.dev/docs/` folders
2. **No project tracking integration** - Worktrees exist but aren't linked to GitHub Issues/Projects
3. **Manual workflow** - No structure for progressing through design → plan → implement → review
4. **No visibility** - Hard to see what's in progress, what's blocked, what's waiting for review
5. **One-directional** - Can't pull tasks from GitHub, only push local state

---

## Proposal: Centralized Docs + GitHub Projects Integration

### 1. Documentation Structure

The `dev` repo is one of the repos in the worktree. Feature docs are simply files in the dev repo worktree:

```
worktrees/{feature}/
├── dev/                           # Worktree of dev repo (branch: {feature})
│   └── docs/
│       ├── design/
│       │   └── {feature}.md       # Design doc - just a file in dev repo
│       ├── plans/
│       │   └── {feature}.md       # Implementation plan
│       ├── bugs/                  # Bug investigations
│       ├── research/              # Research docs
│       ├── architecture/          # Architecture docs
│       └── process/               # Process docs (templates, etc.)
├── flovyn-server/                 # Worktree of flovyn-server repo
├── flovyn-app/                    # Worktree of flovyn-app repo
└── ...
```

**Rationale:**
- No special structure - docs are just files in the dev repo
- Version-controlled with the feature branch
- When feature merges, docs merge with the dev repo
- Claude Code access: `dev/docs/design/{feature}.md`

### 2. GitHub Projects Integration

#### Create New Development Project

The existing "Roadmap" project is outdated. Create a new project for active development:

```bash
# Create new project
gh project create --owner flovyn --title "Development" --format json

# After creation, add custom Status field with workflow stages
# (GitHub CLI doesn't support this directly - use web UI or GraphQL)
```

**Status field options to configure:**
1. `Backlog` - Ideas, requests, rough specs
2. `Research` - Investigating feasibility, exploring options (no code)
3. `Design` - Writing design doc, discussing
4. `Planning` - Breaking down tasks, finalizing plan
5. `Implementing` - Code being written, testing
6. `Review` - PRs open, waiting for review
7. `Done` - Merged, deployed

**Custom fields to add:**
- `Branch` (Text) - Feature branch name used for worktrees. Required for Design+, optional for Research.
- `Kind` (Single select) - `Feature` | `Research` | `Bug` (Note: "Type" is reserved by GitHub for issue types)
- `Repos` (Text) - Which repos are affected (optional, can be in design doc instead)

#### Project Structure

```
┌───────────┬───────────┬───────────┬───────────┬───────────┬───────────┬───────────┐
│  Backlog  │ Research  │  Design   │ Planning  │Implementing│  Review   │   Done    │
├───────────┼───────────┼───────────┼───────────┼───────────┼───────────┼───────────┤
│ Ideas,    │ Exploring │ Writing   │ Breaking  │ Code being│ PRs open, │ Merged,   │
│ requests, │ feasibility│ design   │ down tasks│ written,  │ waiting   │ deployed  │
│ specs     │ (no code) │ doc      │ finalizing│ testing   │ for review│           │
└───────────┴───────────┴───────────┴───────────┴───────────┴───────────┴───────────┘
```

**Each card represents a feature/epic** and contains:
- Title + description
- Links to `dev/docs/features/{name}/` docs (in custom field)
- Associated repos (which repos will be touched)
- Branch name (matches worktree name)

#### Workflow Stages

| Stage | Entry Criteria | Exit Criteria | Tooling |
|-------|---------------|---------------|---------|
| **Backlog** | Idea exists | Prioritized for work | Manual |
| **Research** | Need to explore feasibility | Research doc complete with recommendation | Claude Code (lightweight setup) |
| **Design** | Started design doc | Design approved | Claude Code for refinement |
| **Planning** | Design done | Implementation plan complete with TODO list | Claude Code generates plan |
| **Implementing** | Plan approved, worktree created | All TODOs complete, tests pass | Claude Code for implementation |
| **Review** | PRs created | All PRs approved | `gh pr create` |
| **Done** | PRs merged | Docs archived | `gh pr merge` |

### 3. `flovyn-dev` - Development Workflow Manager

Replace `worktree.py` with a comprehensive development workflow tool that integrates GitHub Projects, local worktrees, documentation, and Claude Code sessions.

#### Installation

```bash
# The tool lives in dev/bin/
./dev/bin/flovyn-dev

# Or add to PATH via alias
alias flovyn-dev='/home/ubuntu/workspaces/flovyn/dev/bin/flovyn-dev'
```

#### Command Overview

```bash
# ─────────────────────────────────────────────────────────
# VIEWING (pulls from GitHub Projects)
# ─────────────────────────────────────────────────────────
flovyn-dev list                     # List all tasks from GitHub Project
flovyn-dev list --status Design     # Filter by status
flovyn-dev list --local             # Show only tasks with local state
flovyn-dev show <task>              # Show details of one task

# ─────────────────────────────────────────────────────────
# WORKING (bidirectional sync)
# ─────────────────────────────────────────────────────────
flovyn-dev pick <task>              # Select task from GitHub, set up locally (full worktree)
flovyn-dev research <task>          # Start research task (dev worktree only, no code repos)
flovyn-dev attach <task>            # Attach to tmux session (resume work)
flovyn-dev open <task>              # Open docs in editor

# ─────────────────────────────────────────────────────────
# STATE MANAGEMENT (local ↔ GitHub)
# ─────────────────────────────────────────────────────────
flovyn-dev move <task> <status>     # Move to new status (updates GitHub + local)
flovyn-dev sync                     # Show differences between local and GitHub
flovyn-dev sync --pull              # Trust GitHub, update local
flovyn-dev sync --push              # Trust local, update GitHub

# ─────────────────────────────────────────────────────────
# DOCUMENTATION
# ─────────────────────────────────────────────────────────
flovyn-dev docs <task>              # List all docs for a feature
flovyn-dev docs mv <task> <from> <to>  # Move doc (e.g., research → design)
flovyn-dev docs archive <task>      # Move docs to archive/

# ─────────────────────────────────────────────────────────
# GIT OPERATIONS (from worktree.py)
# ─────────────────────────────────────────────────────────
flovyn-dev git-status <task>        # Git status across repos in worktree
flovyn-dev commit <task> -m "msg"   # Commit across repos with same message
flovyn-dev pr <task>                # Create PRs, link to GitHub Project card

# ─────────────────────────────────────────────────────────
# DOCKER ENVIRONMENT
# ─────────────────────────────────────────────────────────
flovyn-dev build <task>             # Build Docker images tagged with branch name
flovyn-dev init-env <task>          # Allocate ports, generate docker-compose.yml
flovyn-dev start <task>             # Start Docker environment
flovyn-dev stop <task>              # Stop Docker environment
flovyn-dev rebuild <task>           # Rebuild images and restart
flovyn-dev logs <task> [service]    # View logs
flovyn-dev env <task>               # Show environment URLs

# ─────────────────────────────────────────────────────────
# CLEANUP
# ─────────────────────────────────────────────────────────
flovyn-dev archive <task>           # Safety checks, then cleanup (see below)
flovyn-dev delete <task>            # Delete local state only (keeps GitHub, no checks)
```

#### `flovyn-dev list` - View All Tasks

```bash
$ flovyn-dev list

  Status        │ Task                      │ Branch           │ Local
  ──────────────┼───────────────────────────┼──────────────────┼────────────
  Backlog       │ SDK usage metrics         │ -                │ -
  Backlog       │ Rate limiting             │ -                │ -
  Design        │ Webhook retry             │ webhook-retry    │ tmux ●
  Planning      │ Schedule UI               │ schedules-ui     │ tmux ●
  Implementing  │ Python SDK improvements   │ sdk-python       │ worktree
  Review        │ Auth refactor             │ auth-refactor    │ PR #123
  Done          │ Event hooks               │ -                │ archived

# Filter examples
$ flovyn-dev list --status Implementing
$ flovyn-dev list --local              # Only tasks with local setup
```

#### `flovyn-dev pick <task>` - Start Working on a Task

Select a task from GitHub Projects and set up local environment:

```bash
$ flovyn-dev pick "Webhook retry"

Task: Webhook retry
Current status: Backlog
Local state: Nothing set up

What would you like to do?
  1. Start working (move to Design, create worktree + docs + tmux)
  2. Just create local setup (don't change GitHub status)
  3. Cancel

Choice: 1

Setting up...
✓ Updated GitHub status: Ready → Design
✓ Created worktrees/webhook-retry/{dev,flovyn-server,flovyn-app,...}
✓ Copied untracked files:
  - sdk-rust/examples/.env (required for worker examples)
✓ Created dev/docs/design/20260120_webhook_retry.md from template
✓ Created tmux session: webhook-retry (cwd: worktrees/webhook-retry/)
✓ Launched Claude Code with initial prompt

To attach: flovyn-dev attach webhook-retry
```

Or pick by partial match:
```bash
$ flovyn-dev pick webhook      # Matches "Webhook retry"
$ flovyn-dev pick --interactive # Show picker UI
```

#### Untracked Files

Some files are `.gitignore`d but required for development. `flovyn-dev pick` copies these from main branch to the worktree:

| Source | Target | Purpose |
|--------|--------|---------|
| `sdk-rust/examples/.env` | `worktrees/{feature}/sdk-rust/examples/.env` | Worker example configuration |

To add more files, update the `UNTRACKED_FILES` list in `flovyn-dev`.

#### `flovyn-dev research <task>` - Start Research Task

For exploring feasibility without committing to a full feature. Creates a lightweight setup:

```bash
$ flovyn-dev research "Retry strategies"

Task: Retry strategies
Kind: Research
Current status: Backlog

Setting up...
✓ Updated GitHub status: Backlog → Research
✓ Created worktrees/retry-strategies/dev/ (dev repo only)
✓ Created dev/docs/research/20260120_retry_strategies.md from template
✓ Created tmux session: retry-strategies (cwd: worktrees/retry-strategies/)
✓ Launched Claude Code with research prompt

To attach: flovyn-dev attach retry-strategies
```

**Key differences from `pick`:**
- Only creates `dev/` worktree (not flovyn-server, flovyn-app, etc.)
- No Docker environment needed
- Output is a research doc, not design doc
- Can transition to `Design` if research recommends proceeding

**Research doc output:** `dev/docs/research/YYYYMMDD_topic.md`

**Outcomes:**
1. **Proceed** → Move to Design, run `flovyn-dev pick` to create full worktree
2. **Don't proceed** → Move to Done with "Won't Do" note
3. **Need more info** → Stay in Research

#### `flovyn-dev move <task> <status>` - Change Task Status

Move task through workflow stages (updates both GitHub and local):

```bash
$ flovyn-dev move webhook-retry Planning

Current: Design → Target: Planning

Pre-flight checks:
  ✓ Design doc exists
  ✓ Design doc status: Approved
  ✓ Worktree exists
  ✓ tmux session running

Proceed? [Y/n]: y

✓ Updated GitHub: Design → Planning
✓ Local state unchanged

Suggested next action:
  Attach and ask Claude to create implementation plan:
  "Create an implementation plan at dev/docs/features/webhook-retry/plan.md"
```

Status transitions and what they trigger:

| Transition | Local Action |
|------------|--------------|
| → Design | Create docs folder, worktree, tmux, launch Claude |
| → Planning | (none, just status update) |
| → Implementing | (none, just status update) |
| → Review | Prompt to run `flovyn-dev pr` |
| → Done | Prompt to run `flovyn-dev archive` |

#### `flovyn-dev pr <task>` - Create Pull Requests

```bash
$ flovyn-dev pr webhook-retry

Checking for repos with changes...
  dev/: 2 files changed (design doc, plan)
  flovyn-server/: 8 files changed

Creating PRs...

flovyn-server:
  $ git push -u origin webhook-retry
  $ gh pr create \
      --title "feat: Webhook retry with exponential backoff" \
      --body "## Summary
  Implements webhook retry with exponential backoff.

  ## Design Doc
  https://github.com/flovyn/dev/blob/webhook-retry/docs/design/webhook-retry.md

  ## Test Plan
  - [x] Unit tests
  - [x] Integration tests

  Closes #42"

  ✓ Created: https://github.com/flovyn/flovyn-server/pull/43

dev/:
  $ git push -u origin webhook-retry
  $ gh pr create --title "docs: Webhook retry design and plan" ...

  ✓ Created: https://github.com/flovyn/dev/pull/12

Linking to GitHub Project...
  $ gh project item-edit ...

✓ Created 2 PRs
```

**PR body template used:**
```markdown
## Summary
{First paragraph from design doc's Overview section}

## Design Doc
https://github.com/flovyn/dev/blob/{branch}/docs/design/{feature}.md

## Test Plan
- [ ] Unit tests pass
- [ ] Integration tests pass

{Closes #issue if linked}
```

#### `flovyn-dev sync` - Reconcile Local ↔ GitHub

```bash
$ flovyn-dev sync

Comparing local state with GitHub...

  Task              │ GitHub       │ Local           │ Action Needed
  ──────────────────┼──────────────┼─────────────────┼──────────────────
  webhook-retry     │ Design       │ tmux running    │ ✓ In sync
  schedules-ui      │ Done         │ tmux running    │ ⚠ Should archive
  old-feature       │ (not found)  │ worktree exists │ ⚠ Orphaned local

Options:
  1. Archive schedules-ui (match GitHub)
  2. Delete old-feature local state
  3. Do nothing

Choice: 1,2

✓ Archived schedules-ui
✓ Deleted old-feature worktree
```

#### `flovyn-dev archive <task>` - Cleanup with Safety Checks

```bash
$ flovyn-dev archive webhook-retry

Pre-flight checks...
  Checking Docker environment:
    ✓ Containers stopped (or will stop)
  Checking for uncommitted changes:
    ✓ dev/ - clean
    ✓ flovyn-server/ - clean
  Checking PRs are merged:
    ✓ flovyn/dev#12 - MERGED
    ✓ flovyn/flovyn-server#43 - MERGED

Archiving...
  Stopping Docker environment...
    $ docker compose -f worktrees/webhook-retry/dev/docker-compose.yml down -v
  Removing Docker images...
    $ docker rmi flovyn-server:webhook-retry flovyn-app:webhook-retry
  Removing worktrees...
    $ git worktree remove worktrees/webhook-retry/dev
    $ git worktree remove worktrees/webhook-retry/flovyn-server
    ...
  Cleaning up...
    $ tmux kill-session -t webhook-retry
    $ gh project item-edit ... --field Status --value "Done"
  Releasing port allocation...
    Removed webhook-retry from ~/.flovyn/ports.json

✓ Archived webhook-retry
```

**If checks fail:**
```bash
$ flovyn-dev archive webhook-retry

Pre-flight checks...
  Checking for uncommitted changes:
    ✗ flovyn-server/ has uncommitted changes:
        modified: src/service/webhook.rs

Error: Cannot archive - uncommitted changes exist.
Run 'flovyn-dev commit webhook-retry -m "..."' first.
```

```bash
$ flovyn-dev archive webhook-retry

Pre-flight checks...
  Checking PRs are merged:
    ✗ flovyn/flovyn-server#43 - OPEN

Error: Cannot archive - PR not merged.
Merge the PR first, or use 'flovyn-dev delete webhook-retry' to force delete.
```

#### Tmux Session Management

Each task gets its own tmux session with Claude Code:

```bash
# Attach to a task's Claude session
$ flovyn-dev attach webhook-retry

# If session doesn't exist, creates it:
#   tmux new-session -d -s webhook-retry -c /home/ubuntu/workspaces/flovyn
#   tmux send-keys -t webhook-retry 'claude' Enter
#   tmux attach -t webhook-retry

# List all active sessions
$ flovyn-dev list --local

  Task              │ tmux Status    │ Last Activity
  ──────────────────┼────────────────┼──────────────────
  webhook-retry     │ attached       │ now
  schedules-ui      │ detached       │ 2 hours ago

# Detach from current session: Ctrl+B, then D
# Switch sessions inside tmux: Ctrl+B, then S
```

#### Claude Code Session Initialization

#### Initial Prompt (on `pick`)

When creating a new tmux session, `flovyn-dev`:
1. Fetches the GitHub issue content
2. Starts Claude Code from the worktree
3. Sends initial prompt with issue content

```bash
# What happens under the hood:
WORKTREE_DIR="/home/ubuntu/workspaces/flovyn/worktrees/webhook-retry"
ISSUE_BODY=$(gh issue view 42 --repo flovyn/flovyn-server --json body -q '.body')
ISSUE_TITLE=$(gh issue view 42 --repo flovyn/flovyn-server --json title -q '.title')

tmux new-session -d -s webhook-retry -c "$WORKTREE_DIR"
tmux send-keys -t webhook-retry 'claude' Enter
sleep 2
tmux send-keys -t webhook-retry "I'm working on feature 'webhook-retry'.

## GitHub Issue
Title: $ISSUE_TITLE
Body:
$ISSUE_BODY

## Task
1. Read the design doc template: dev/docs/design/20260120_webhook_retry.md
2. Explore the relevant code in the codebase to understand current architecture
3. Write the design doc, using the GitHub issue as requirements input
4. Before running any build/test commands, read the repo's CLAUDE.md first

Start by exploring the codebase to understand what exists, then write the design." Enter
```

#### Resume Prompt (on `attach`)

When attaching to an existing session, `flovyn-dev attach` sends a resume prompt:

```bash
# If session already exists and Claude is running:
tmux send-keys -t webhook-retry "
Resuming work on 'webhook-retry'.

Please read dev/docs/plans/20260120_webhook_retry.md (if it exists) and report:
1. Which phase are we in?
2. Which TODOs are complete ([x]) vs pending ([ ])?
3. What's the next TODO to work on?

If no plan exists yet, read dev/docs/design/20260120_webhook_retry.md for context.
" Enter
```

#### Session Working Directory

**cwd:** `/home/ubuntu/workspaces/flovyn/worktrees/{feature}/`

- `flovyn-server/src/foo.rs` just works
- `cd flovyn-server && ./bin/dev/build.sh` just works
- Each repo's `CLAUDE.md` is at `{repo}/CLAUDE.md`
- Docs are at `dev/docs/design/{feature}.md`

#### Multi-Task Parallel Work

```
┌─────────────────────────────────────────────────────────┐
│ Active Development Sessions                             │
├─────────────────────────────────────────────────────────┤
│ ● webhook-retry  (Design)      - Claude refining design │
│ ○ schedules-ui   (Implementing) - Claude on TODO 3.2    │
│ ○ sdk-python     (Planning)     - Waiting for review    │
└─────────────────────────────────────────────────────────┘

$ flovyn-dev attach schedules-ui   # Switch to different task
```

### 4. Document Naming Convention

All documents follow the `YYYYMMDD_description.md` format:

| Type | Pattern | Example |
|------|---------|---------|
| Design | `YYYYMMDD_feature_name.md` | `20260120_webhook_retry.md` |
| Plan | `YYYYMMDD_feature_name.md` | `20260120_webhook_retry.md` |
| Bug | `YYYYMMDD_short_description.md` | `20260120_webhook_timeout_race_condition.md` |
| Research | `YYYYMMDD_topic.md` | `20260120_retry_strategies.md` |

**Rules:**
- Date prefix is creation date
- Use `snake_case` for the description (not kebab-case)
- Keep descriptions concise but descriptive
- Design and plan docs for the same feature share the same name

**Examples:**
```
dev/docs/design/20260120_webhook_retry.md
dev/docs/plans/20260120_webhook_retry.md
dev/docs/bugs/20260120_webhook_timeout_race_condition.md
dev/docs/research/20260120_exponential_backoff_strategies.md
```

### 5. Path Convention for Documentation

Claude Code starts from the worktree root, so paths work naturally.

#### Convention: `{repo}/{path}` Format

**In documentation, use paths relative to worktree root:**

```markdown
# Code paths (relative to worktree root)
- `flovyn-server/src/domain/schedule.rs`
- `flovyn-server/server/src/api/rest/schedules.rs:45`
- `flovyn-app/apps/web/src/components/ScheduleList.tsx`
- `sdk-python/flovyn/client.py`

# Doc paths
- `dev/docs/design/webhook-retry.md`
- `dev/docs/plans/webhook-retry.md`
```

**With line numbers:** `{repo}/{path}:{line}` (e.g., `flovyn-server/src/scheduler.rs:123`)

Since Claude Code runs from `worktrees/{feature}/`, these paths just work - no translation needed.

#### Repository Names

| Repo | Path Prefix |
|------|-------------|
| Rust server | `flovyn-server/` |
| Web app | `flovyn-app/` |
| Python SDK | `sdk-python/` |
| Rust SDK | `sdk-rust/` |
| Kotlin SDK | `sdk-kotlin/` |
| Dev environment + docs | `dev/` |

### 6. Claude Code Integration Points

#### CLAUDE.md for Workspace Root

Add/update `/home/ubuntu/workspaces/flovyn/CLAUDE.md` (workspace-level) to guide Claude Code:

```markdown
## Workspace Structure

This is a multi-repo workspace for Flovyn development.

### Repositories
- `flovyn-server/` - Rust backend (REST + gRPC)
- `flovyn-app/` - Next.js frontend
- `sdk-python/`, `sdk-rust/`, `sdk-kotlin/` - Client SDKs
- `dev/` - Development environment and centralized docs

### Path Convention

Documentation uses `{repo}/{path}` format. Resolve paths as:
- Main branch: `/home/ubuntu/workspaces/flovyn/{repo}/{path}`
- Worktree: `/home/ubuntu/workspaces/flovyn/worktrees/{feature}/{repo}/{path}`

### Current Feature Detection

To determine if working on a feature:
1. Check if inside a worktree: `git rev-parse --show-toplevel` contains `/worktrees/`
2. Extract feature name from path
3. Look for docs at `dev/docs/features/{feature}/`

### Feature Development Workflow

When working on a feature:
1. Design doc: `dev/docs/features/{feature}/design.md`
2. Implementation plan: `dev/docs/features/{feature}/plan.md`
3. Code changes: `worktrees/{feature}/{repo}/...`
```

#### Design Phase

**Starting a design session:**
```bash
cd /home/ubuntu/workspaces/flovyn
claude

# User: "I want to work on a new feature: webhook retry with exponential backoff.
#        Create a design doc at dev/docs/features/webhook-retry/design.md
#        First, explore the current webhook implementation in flovyn-server to understand
#        the existing architecture."
```

Claude Code will:
1. Search the codebase for webhook-related code
2. Understand current implementation
3. Create design doc with context-aware recommendations
4. Ask clarifying questions

**Refining a design:**
```bash
# User: "Review the design at dev/docs/features/webhook-retry/design.md
#        - Are there any edge cases I'm missing?
#        - How does this compare to how Temporal handles retries?
#        - Update the design with your recommendations."
```

#### Planning Phase

**Generating implementation plan:**
```bash
# User: "Based on the design at dev/docs/features/webhook-retry/design.md,
#        create an implementation plan at dev/docs/features/webhook-retry/plan.md.
#
#        Requirements:
#        - Test-first approach
#        - Phased delivery (database, domain, API, tests)
#        - Each phase should be independently verifiable"
```

Claude Code generates structured plan with:
- Phased breakdown (each phase shippable)
- Concrete TODO items with checkboxes (`- [ ]`)
- File paths for each change
- Test strategy per phase
- Verification steps

**Example plan structure generated:**
```markdown
## Phase 1: Database & Domain
- [ ] **1.1** Add migration for `webhook_retry` table
- [ ] **1.2** Create `WebhookRetry` domain model
- [ ] **1.3** Create `WebhookRetryRepository`
- [ ] **1.4** Unit tests for domain model

### Verification
- `cargo test domain::webhook_retry` passes
- Migration runs successfully
```

#### Implementation Phase

**Working through the plan:**
```bash
# Session start
# User: "Continue implementing webhook-retry. Read the plan at
#        dev/docs/features/webhook-retry/plan.md and work on the next TODO."
```

Claude Code behavior:
1. Reads plan.md to understand full context
2. Finds first unchecked TODO
3. Marks it as in-progress (optional: `- [~]` or just starts working)
4. Implements the item
5. Runs relevant tests
6. Marks TODO as complete (`- [x]`)
7. Commits if appropriate
8. Reports status and suggests next item

**Mid-session handoff:**
```bash
# When stopping work, user can ask:
# User: "Update the plan with current status and add any notes for next session."
```

This creates continuity across Claude Code sessions.

#### Bug Investigation Phase

For bugs, use hypothesis-driven investigation (per existing `.claude/rules/bug-fixing.md`):
```bash
# User: "Investigate the bug described at dev/docs/bugs/20260120_webhook_timeout.md
#        Follow the hypothesis-driven approach."
```

Claude Code will:
1. Read the bug report
2. Form hypotheses
3. Run controlled experiments
4. Document findings in the bug report
5. Propose fix

### 7. Templates

#### Research Template (`dev/docs/process/templates/research.md`)

```markdown
# Research: {Topic}

**Date:** YYYY-MM-DD
**Status:** In Progress | Complete
**GitHub Issue:** {link}

## Question

What are we trying to understand or decide?

## Context

Why is this research needed? What triggered it?

## Scope

- What's in scope for this research
- What's explicitly out of scope

---

## Findings

### Option 1: {Name}

**Description:** How this approach works.

**Pros / Cons / Effort estimate / References**

### Option 2: {Name}
...

---

## Comparison

| Criteria | Option 1 | Option 2 | Option 3 |
|----------|----------|----------|----------|
| Complexity | ... | ... | ... |
| Performance | ... | ... | ... |

---

## Recommendation

**Recommended approach:** Option X

**Rationale:** Why this is the best choice.

**Next steps:**
1. If proceeding: Create design doc, move to Design status
2. If not proceeding: Close with rationale
```

#### Design Template (`dev/docs/process/templates/design.md`)

```markdown
# {Feature Name} Design

**Date:** YYYY-MM-DD
**Status:** Draft | Review | Approved
**GitHub Card:** {link}

## Problem Statement

What problem are we solving? Why now?

## Goals

1. ...
2. ...

## Non-Goals

- ...

## Current State

How does it work today? What's missing?

## Proposed Solution

### Overview

High-level description.

### Architecture

Diagrams, component interactions.

### API Changes

REST/gRPC changes with examples.

### Database Changes

Migrations, new tables/columns.

### Cross-Repo Impact

Which repos need changes and why.

## Alternatives Considered

| Alternative | Pros | Cons | Why Not |
|-------------|------|------|---------|
| ... | ... | ... | ... |

## Open Questions

- [ ] Question 1
- [ ] Question 2

## References

- Links to related designs, external docs
```

#### Plan Template (`dev/docs/process/templates/plan.md`)

```markdown
# {Feature Name} Implementation Plan

**Date:** YYYY-MM-DD
**Design:** [link to design.md]
**Status:** In Progress | Complete

## Progress Summary

**Phase 1**: ⬜ Not Started / 🔄 In Progress / ✅ Complete
**Phase 2**: ⬜ Not Started

## Phase 1: {Name}

### Context
What this phase accomplishes.

### TODO
- [ ] **1.1** Task description
- [ ] **1.2** Another task
  - Sub-detail if needed

### Verification
How to verify this phase is complete.

## Phase 2: {Name}

...
```

### 8. Per-Worktree Docker Environment

Each worktree runs its own **fully isolated Docker environment**. No sharing between worktrees.

#### Architecture

```
worktrees/webhook-retry/
├── dev/
│   ├── docker-compose.yml      # Generated: full stack for this feature
│   ├── .env                    # Generated: unique ports
│   └── configs/
│       └── server.toml         # Generated: points to local containers
├── flovyn-server/              # Source → built as flovyn-server:webhook-retry
└── flovyn-app/                 # Source → built as flovyn-app:webhook-retry
```

#### Docker Images

Images are built from worktree source and tagged with the branch name:

```bash
# Built by: flovyn-dev build webhook-retry
flovyn-server:webhook-retry
flovyn-app:webhook-retry
```

#### Container Naming

Each worktree's containers are prefixed with the feature name to avoid conflicts:

| Service | Container Name | Network |
|---------|----------------|---------|
| Server Postgres | `webhook-retry-postgres-server` | `flovyn-webhook-retry` |
| App Postgres | `webhook-retry-postgres-app` | `flovyn-webhook-retry` |
| NATS | `webhook-retry-nats` | `flovyn-webhook-retry` |
| Jaeger | `webhook-retry-jaeger` | `flovyn-webhook-retry` |
| Server | `webhook-retry-server` | `flovyn-webhook-retry` |
| App | `webhook-retry-app` | `flovyn-webhook-retry` |

Internal communication uses container names (e.g., server connects to `webhook-retry-postgres-server:5432`).

#### Port Allocation

Host ports are allocated per feature to allow parallel environments:

| Feature | Server HTTP | Server gRPC | App | Server PG | App PG | NATS | Jaeger UI |
|---------|-------------|-------------|-----|-----------|--------|------|-----------|
| (main) | 8000 | 9090 | 3000 | 5435 | 5433 | 4222 | 16686 |
| webhook-retry | 8001 | 9091 | 3001 | 5436 | 5434 | 4223 | 16687 |
| schedules | 8002 | 9092 | 3002 | 5437 | 5435 | 4224 | 16688 |

Port allocation is stored in `~/.flovyn/ports.json`:

```json
{
  "allocations": {
    "webhook-retry": {
      "base_offset": 1,
      "server_http": 8001,
      "server_grpc": 9091,
      "app": 3001,
      "postgres_server": 5436,
      "postgres_app": 5434,
      "nats": 4223,
      "jaeger_ui": 16687
    }
  },
  "next_offset": 2
}
```

#### Generated docker-compose.yml

`flovyn-dev init-env` generates a complete docker-compose.yml for each worktree:

```yaml
# worktrees/webhook-retry/dev/docker-compose.yml (generated)
services:
  postgres-server:
    image: postgres:18-alpine
    container_name: webhook-retry-postgres-server
    environment:
      POSTGRES_USER: flovyn
      POSTGRES_PASSWORD: flovyn
      POSTGRES_DB: flovyn
    ports:
      - "5436:5432"
    volumes:
      - postgres-server-data:/var/lib/postgresql/data
    networks:
      - flovyn-webhook-retry

  postgres-app:
    image: postgres:18-alpine
    container_name: webhook-retry-postgres-app
    environment:
      POSTGRES_USER: flovyn-app
      POSTGRES_PASSWORD: flovyn-app
      POSTGRES_DB: flovyn-app
    ports:
      - "5434:5432"
    volumes:
      - postgres-app-data:/var/lib/postgresql/data
    networks:
      - flovyn-webhook-retry

  nats:
    image: nats:2.10-alpine
    container_name: webhook-retry-nats
    ports:
      - "4223:4222"
      - "8223:8222"
    command: ["--http_port", "8222", "-js"]
    networks:
      - flovyn-webhook-retry

  jaeger:
    image: jaegertracing/all-in-one:1.54
    container_name: webhook-retry-jaeger
    environment:
      COLLECTOR_OTLP_ENABLED: "true"
    ports:
      - "16687:16686"
      - "4318:4318"
    networks:
      - flovyn-webhook-retry

  server:
    image: flovyn-server:webhook-retry
    container_name: webhook-retry-server
    depends_on:
      postgres-server:
        condition: service_healthy
      nats:
        condition: service_started
    environment:
      DATABASE_URL: postgres://flovyn:flovyn@postgres-server:5432/flovyn
      NATS_URL: nats://nats:4222
      OTEL_EXPORTER_OTLP_ENDPOINT: http://jaeger:4318
    ports:
      - "8001:8000"
      - "9091:9090"
    networks:
      - flovyn-webhook-retry

  app:
    image: flovyn-app:webhook-retry
    container_name: webhook-retry-app
    depends_on:
      postgres-app:
        condition: service_healthy
      server:
        condition: service_started
    environment:
      DATABASE_URL: postgres://flovyn-app:flovyn-app@postgres-app:5432/flovyn-app
      BACKEND_URL: http://server:8000
      NEXT_PUBLIC_APP_URL: http://localhost:3001
    ports:
      - "3001:3000"
    networks:
      - flovyn-webhook-retry

networks:
  flovyn-webhook-retry:
    driver: bridge

volumes:
  postgres-server-data:
  postgres-app-data:
```

#### Docker Commands in flovyn-dev

```bash
# ─────────────────────────────────────────────────────────
# DOCKER ENVIRONMENT
# ─────────────────────────────────────────────────────────

# Build Docker images from worktree source
flovyn-dev build <feature>
# → docker build -t flovyn-server:webhook-retry worktrees/webhook-retry/flovyn-server
# → docker build -t flovyn-app:webhook-retry worktrees/webhook-retry/flovyn-app

# Initialize environment (allocate ports, generate docker-compose.yml)
flovyn-dev init-env <feature>
# → Allocates ports (stores in ~/.flovyn/ports.json)
# → Generates worktrees/<feature>/dev/docker-compose.yml
# → Generates worktrees/<feature>/dev/.env

# Start the Docker environment
flovyn-dev start <feature>
# → cd worktrees/<feature>/dev && docker compose up -d

# Stop the environment
flovyn-dev stop <feature>
# → cd worktrees/<feature>/dev && docker compose down

# View logs
flovyn-dev logs <feature> [service]
# → docker compose -f worktrees/<feature>/dev/docker-compose.yml logs -f [service]

# Rebuild and restart (after code changes)
flovyn-dev rebuild <feature>
# → flovyn-dev build <feature>
# → flovyn-dev stop <feature>
# → flovyn-dev start <feature>

# Open in browser
flovyn-dev open <feature>
# → Opens http://localhost:3001 (uses allocated port)

# Show environment info
flovyn-dev env <feature>
# → Server HTTP: http://localhost:8001
# → Server gRPC: localhost:9091
# → App: http://localhost:3001
# → Jaeger: http://localhost:16687
```

#### Example Workflow

```bash
# 1. Pick a task (creates worktree, docs, tmux)
$ flovyn-dev pick webhook-retry

# 2. Initialize Docker environment (allocate ports, generate configs)
$ flovyn-dev init-env webhook-retry
✓ Allocated ports (base offset: 1)
✓ Generated worktrees/webhook-retry/dev/docker-compose.yml
✓ Generated worktrees/webhook-retry/dev/.env

# 3. Build Docker images from worktree source
$ flovyn-dev build webhook-retry
Building flovyn-server:webhook-retry...
  → docker build -t flovyn-server:webhook-retry worktrees/webhook-retry/flovyn-server
Building flovyn-app:webhook-retry...
  → docker build -t flovyn-app:webhook-retry worktrees/webhook-retry/flovyn-app
✓ Built 2 images

# 4. Start the environment
$ flovyn-dev start webhook-retry
Starting webhook-retry environment...
  → docker compose -f worktrees/webhook-retry/dev/docker-compose.yml up -d
✓ All services running

# 5. Show access URLs
$ flovyn-dev env webhook-retry
webhook-retry environment:
  App:         http://localhost:3001
  Server HTTP: http://localhost:8001
  Server gRPC: localhost:9091
  Jaeger:      http://localhost:16687

# 6. After code changes, rebuild
$ flovyn-dev rebuild webhook-retry

# 7. When done, stop
$ flovyn-dev stop webhook-retry
```

#### Running Multiple Features in Parallel

```bash
# Terminal 1: Working on webhook-retry
$ flovyn-dev start webhook-retry
$ flovyn-dev attach webhook-retry
# App at http://localhost:3001, Server at http://localhost:8001

# Terminal 2: Working on schedules
$ flovyn-dev start schedules
$ flovyn-dev attach schedules
# App at http://localhost:3002, Server at http://localhost:8002

# Both running simultaneously with full isolation
```

### 9. Complexity-Based Workflow

Not every change needs full ceremony. Guidelines:

| Complexity | Design Doc | Plan Doc | GitHub Card | Worktree |
|------------|------------|----------|-------------|----------|
| **Trivial** (typo fix) | No | No | No | No |
| **Small** (single-file bug) | Bug report | No | Optional | No |
| **Medium** (multi-file feature) | Yes | Yes | Yes | Yes |
| **Large** (cross-repo epic) | Yes + ADR | Phased | Yes + sub-tasks | Yes |

### 10. GitHub CLI Commands Reference

Useful `gh` commands for the workflow:

```bash
# Project management
gh project list --owner flovyn
gh project view <number> --owner flovyn
gh project item-list <number> --owner flovyn

# Create draft issue and add to project
gh issue create --repo flovyn/flovyn-server \
  --title "Feature: Webhook retry" \
  --body "Design: dev/docs/features/webhook-retry/design.md" \
  --project "Development"

# Update project item status (requires item ID from GraphQL)
gh api graphql -f query='
mutation {
  updateProjectV2ItemFieldValue(
    input: {
      projectId: "PROJECT_ID"
      itemId: "ITEM_ID"
      fieldId: "STATUS_FIELD_ID"
      value: { singleSelectOptionId: "OPTION_ID" }
    }
  ) { projectV2Item { id } }
}'

# Create PRs for feature
gh pr create --repo flovyn/flovyn-server \
  --title "feat: Webhook retry with exponential backoff" \
  --body "Closes #123\n\nDesign: dev/docs/features/webhook-retry/design.md" \
  --head webhook-retry

# Link PR to project item
gh pr edit <number> --repo flovyn/flovyn-server --add-project "Development"
```

### 11. Migration Path

**Phase 1: Foundation** ✅ Done
1. ✅ Created directory structure: `dev/docs/{features,bugs,research,architecture,archive,process/templates}`
2. ✅ Created templates (design.md, plan.md, bug.md)
3. ✅ Documented workflow design (this document)

**Phase 2: GitHub Project Setup**
1. Create "Development" project:
   ```bash
   gh project create --owner flovyn --title "Development"
   ```
2. Configure via web UI:
   - Add Status options: Backlog, Design, Planning, Implementing, Review, Done
   - Add custom fields: Branch (text), Docs (text)
3. Migrate relevant items from old "Roadmap" project

**Phase 3: `flovyn-dev` Implementation**
1. Create `bin/flovyn-dev` (Python, builds on worktree.py patterns)
2. Core commands first:
   - `list` - fetch from GitHub Projects via `gh` CLI
   - `pick` - select task, create local setup (docs, worktree, tmux)
   - `attach` - tmux session management
   - `move` - update status (local + GitHub)
3. Git commands (port from worktree.py):
   - `git-status`, `commit`, `pr`
4. Cleanup commands:
   - `sync`, `archive`, `delete`

**Phase 4: Test & Iterate**
1. Use `flovyn-dev` for next real feature
2. Document friction points
3. Iterate on UX

**Phase 5: Deprecate worktree.py**
1. Ensure all worktree.py functionality is in flovyn-dev
2. Add deprecation notice to worktree.py
3. Remove after transition period

---

## Open Questions

1. **GitHub Projects vs Issues:** Should each card also be a GitHub Issue for better cross-referencing?

2. **Multi-repo PRs:** How to handle coordinated PRs? Create them together? Use a meta-PR?

3. **Claude Code Session Continuity:** How to help Claude Code pick up context across sessions? Should docs include a "current state" section that gets updated?

4. **Automation Level:** How much should move cards automatically (e.g., PR merged → Done)?

5. **Doc Ownership:** Should docs live in `dev` repo or in a separate `flovyn-docs` repo for cleaner history?

---

## Alternatives Considered

### Keep Docs in Each Repo
**Why not:** Cross-repo features are common. Having docs in one repo but changes in another creates confusion.

### Use Linear/Jira Instead of GitHub Projects
**Why not:** Already in GitHub ecosystem. Adding another tool increases context switching. GitHub Projects v2 is capable enough.

### Full Monorepo
**Why not:** SDKs have different release cycles. Server and frontend are already large. Git history would be massive.

---

## Next Steps

### Done ✅
1. ✅ Created directory structure: `dev/docs/{features,bugs,research,architecture,archive,process/templates}`
2. ✅ Created templates: design.md, plan.md, bug.md

### Immediate
3. Review this document and decide on key questions:
   - Should we use GitHub Issues or just Project draft items?
   - Single "Development" project or project-per-quarter?

4. Create "Development" project on GitHub:
   ```bash
   gh project create --owner flovyn --title "Development"
   ```
   Then configure via web UI: add Status options (Backlog, Design, Planning, Implementing, Review, Done)

### Next
5. Implement `flovyn-dev` MVP:
   - Start with `list` and `pick` commands
   - Add tmux integration
   - Test with real feature

### Later
6. Add remaining commands: `move`, `sync`, `pr`, `archive`
7. Port worktree.py git operations to flovyn-dev
8. Deprecate worktree.py
