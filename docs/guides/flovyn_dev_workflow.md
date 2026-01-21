# flovyn-dev Workflow Guide

This guide describes the complete development workflow using `flovyn-dev` for managing features across the Flovyn multi-repo workspace.

## Overview

`flovyn-dev` manages the full lifecycle of a feature:

```
Backlog → Design → Planning → In Progress → Review → Done
```

Each feature gets:
- Isolated worktrees across all repos (with unique ports)
- Auto-generated documentation (design/plan docs)
- Dedicated tmux session with Claude Code
- GitHub Project tracking with automatic status updates

## Quick Reference

| Command | Description |
|---------|-------------|
| `flovyn-dev pick` | Pick from GitHub Backlog and create worktree |
| `flovyn-dev create <feature>` | Create worktree manually |
| `flovyn-dev research <topic>` | Create research-only worktree |
| `flovyn-dev attach <feature>` | Attach to tmux session |
| `flovyn-dev move <feature> <phase>` | Move to new phase |
| `flovyn-dev pr <feature>` | Create PRs across repos |
| `flovyn-dev archive <feature>` | Cleanup after merge |
| `flovyn-dev list` | List local worktrees |
| `flovyn-dev list --remote` | List GitHub Project items |
| `flovyn-dev sync` | Compare local vs GitHub |

---

## Workflow: Starting a New Feature

### Option A: Pick from GitHub Backlog

If the feature is already in the GitHub Project backlog:

```bash
# List available items in Backlog
flovyn-dev list --remote --phase Backlog

# Pick interactively and create worktree
flovyn-dev pick
```

This will:
1. Show available Backlog items
2. Create worktrees for all repos
3. Allocate unique ports
4. Create design doc from template
5. Create tmux session with Claude Code
6. Update GitHub: Backlog → Design
7. Post comment to linked issue

### Option B: Create Manually

For features not yet in GitHub:

```bash
# Standard feature
flovyn-dev create webhook-retry

# Large feature (uses subdirectory for docs)
flovyn-dev create auth-system --large

# Without tmux session
flovyn-dev create webhook-retry --no-session
```

---

## Workflow: Research Tasks

For exploration tasks that don't need full multi-repo worktrees:

```bash
# Create research worktree (dev/ only)
flovyn-dev research retry-strategies

# Or pick Research items from GitHub
flovyn-dev pick --research
```

Research worktrees:
- Only create `dev/` worktree (no flovyn-server, flovyn-app, etc.)
- Create research doc with Objective, Findings, Options, Recommendation
- Focused prompt for exploration, not implementation

When research leads to implementation:

```bash
# Convert research doc to design doc
flovyn-dev docs mv retry-strategies research design

# Create full worktree
flovyn-dev create retry-strategies
```

---

## Workflow: Working on a Feature

### Attach to Session

```bash
# Attach with resume prompt (default)
flovyn-dev attach webhook-retry

# Attach without resume prompt
flovyn-dev attach webhook-retry --no-resume
```

### Check Status

```bash
# Git status across all repos
flovyn-dev status webhook-retry

# Show allocated ports
flovyn-dev env webhook-retry

# List all sessions
flovyn-dev sessions
```

### Work with Docs

```bash
# Open design doc in $EDITOR
flovyn-dev open webhook-retry

# Open plan doc
flovyn-dev open webhook-retry plan

# List all docs for feature
flovyn-dev docs list webhook-retry
```

### Commit Changes

```bash
# Commit across all repos with same message
flovyn-dev commit webhook-retry -m "feat: implement retry logic"
```

---

## Workflow: Moving Between Phases

Update the GitHub Project status and post summaries:

```bash
# Design complete, ready for planning
flovyn-dev move webhook-retry Planning
# Posts: Problem Statement + Solution from design doc

# Planning complete, start implementation
flovyn-dev move webhook-retry "In Progress"
# Posts: TODO list from plan doc

# Implementation complete, ready for review
flovyn-dev move webhook-retry Review
# Posts: Progress percentage

# Feature complete
flovyn-dev move webhook-retry Done
# Posts: Completion marker
```

---

## Workflow: Creating PRs

When implementation is complete:

```bash
flovyn-dev pr webhook-retry
```

This will:
1. Check for uncommitted changes (warn)
2. Identify repos with commits not on main
3. Push branches to origin
4. Create PRs with:
   - Summary from design doc
   - Link to design doc
   - Test plan checklist
5. Post PR links to GitHub issue

---

## Workflow: Archiving a Feature

After PRs are merged:

```bash
flovyn-dev archive webhook-retry
```

Pre-flight checks:
- No uncommitted changes
- No open PRs

Then:
1. Archive docs to `dev/docs/archive/YYYYMMDD_webhook-retry/`
2. Kill tmux session
3. Update GitHub Project → Done
4. Remove worktrees

For abandoned features:

```bash
flovyn-dev archive webhook-retry --force
```

---

## Port Allocation

Each worktree gets unique ports (offset from base):

| Service | Base | Offset 1 | Offset 2 |
|---------|------|----------|----------|
| App | 3000 | 3001 | 3002 |
| Server HTTP | 8000 | 8001 | 8002 |
| Server gRPC | 9090 | 9091 | 9092 |
| Postgres (Server) | 5435 | 5436 | 5437 |
| Postgres (App) | 5433 | 5434 | 5435 |
| NATS | 4222 | 4223 | 4224 |
| Jaeger UI | 16686 | 16687 | 16688 |

View allocated ports:

```bash
flovyn-dev env webhook-retry
```

---

## GitHub Projects Integration

### Listing Items

```bash
# All items grouped by phase
flovyn-dev list --remote

# Filter by phase
flovyn-dev list -r --phase Backlog
flovyn-dev list -r --phase "In Progress"

# Filter by kind
flovyn-dev list -r --kind Feature
flovyn-dev list -r --kind Research
```

### Syncing

```bash
# Compare local vs GitHub
flovyn-dev sync

# Post progress updates for In Progress items
flovyn-dev sync --update-progress
```

---

## Document Structure

### Standard Feature

```
dev/docs/design/YYYYMMDD_feature_name.md
dev/docs/plans/YYYYMMDD_feature_name.md
```

### Large Feature (`--large`)

```
dev/docs/features/feature-name/
├── design.md
├── plan.md
└── plan_phase2.md (optional)
```

### Research

```
dev/docs/research/YYYYMMDD_topic_name.md
```

### Archived

```
dev/docs/archive/YYYYMMDD_feature-name/
├── design.md
└── plan.md
```

---

## Directory Structure

```
flovyn/
├── worktrees/
│   └── webhook-retry/          # Feature worktree
│       ├── dev/
│       │   ├── .env            # Unique ports
│       │   └── docs/           # Shared docs
│       ├── flovyn-server/
│       ├── flovyn-app/
│       └── sdk-*/
├── dev/                        # Main dev repo
│   ├── bin/flovyn-dev          # CLI tool
│   └── docs/
│       ├── design/
│       ├── plans/
│       ├── research/
│       ├── features/           # Large features
│       └── archive/
└── flovyn-server/              # Main repos
```

---

## Prompt Templates

Customize Claude prompts by creating:

- `dev/docs/templates/prompts/initial.md` - New feature prompt
- `dev/docs/templates/prompts/resume.md` - Resume session prompt
- `dev/docs/templates/prompts/research.md` - Research task prompt

Placeholders: `{feature}`, `{design_path}`, `{plan_path}`, `{docs_info}`, `{topic}`, `{research_path}`

---

## Typical Workflow Example

```bash
# 1. Start new feature from GitHub Backlog
flovyn-dev pick
# Select "Add webhook retry logic"
# → Creates worktrees, design doc, tmux session

# 2. Work on design
flovyn-dev attach webhook-retry
# Claude reads design doc, asks clarifying questions
# Update design doc with requirements

# 3. Move to planning
flovyn-dev move webhook-retry Planning
# → Posts design summary to GitHub issue

# 4. Create implementation plan
flovyn-dev open webhook-retry plan
# Define TODO items

# 5. Start implementation
flovyn-dev move webhook-retry "In Progress"
# → Posts TODO list to GitHub issue

# 6. Implement (Claude works through TODOs)
# ...coding...

# 7. Commit changes
flovyn-dev commit webhook-retry -m "feat: add webhook retry with exponential backoff"

# 8. Ready for review
flovyn-dev move webhook-retry Review
# → Posts progress to GitHub issue

# 9. Create PRs
flovyn-dev pr webhook-retry
# → Pushes branches, creates PRs, posts links to issue

# 10. After PRs merged
flovyn-dev archive webhook-retry
# → Archives docs, kills session, removes worktrees, marks Done
```

---

## Troubleshooting

### Worktree already exists

```bash
flovyn-dev delete feature-name
# Then create again
```

### No tmux session

```bash
flovyn-dev attach feature-name
# Will offer to create session if worktree exists
```

### GitHub API errors

Ensure `gh` CLI is authenticated:

```bash
gh auth status
gh auth login
```

### Port conflicts

Check what's using ports:

```bash
flovyn-dev env feature-name
lsof -i :3001
```
