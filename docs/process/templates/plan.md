# {Feature Name} Implementation Plan

**Date:** YYYY-MM-DD
**Design:** [design.md](../design/{feature}.md)
**Status:** In Progress | Complete
**Branch:** {feature}

## Commit Strategy

Commit after completing each phase:
```bash
fdev commit {feature} -m "Phase N: description"
```

Push when ready for backup or review:
```bash
cd worktrees/{feature}/{repo} && git push
```

## Progress Summary

<!-- Update status as phases complete: ⬜ Not Started | 🔄 In Progress | ✅ Complete -->

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 1: {name} | ⬜ Not Started | |
| Phase 2: {name} | ⬜ Not Started | |
| Phase 3: {name} | ⬜ Not Started | |

## Pre-Implementation Notes

### Affected Repos (from design doc)

<!-- Copy from design doc's "Affected Repositories" section -->
- [ ] flovyn-server
- [ ] flovyn-app
- [ ] ...

### Codebase Patterns Discovered

<!-- Key patterns to follow based on existing code -->
- Pattern 1: ...

### Key Decisions

1. Decision made during planning

---

## Phase 1: {Phase Name}

### Context
What this phase accomplishes and why it comes first.

### TODO
<!-- Format: - [ ] **N.M** Task description -->
<!--         - File: `{repo}/{path}` -->
- [ ] **1.1** {Task description}
  - File: `{repo}/{path}`
- [ ] **1.2** {Task description}

### Verification
<!-- Commands to verify this phase is complete. Read repo's CLAUDE.md for correct commands. -->
```bash
cd {repo} && {test command from CLAUDE.md}
```
- [ ] Tests pass

---

## Phase 2: {Phase Name}

### Context
{description}

### TODO
- [ ] **2.1** {Task description}
  - File: `{repo}/{path}`

### Verification
```bash
{verification command}
```
- [ ] Verified

---

## Phase 3: {Phase Name}

### Context
{description}

### TODO
- [ ] **3.1** {Task description}

### Verification
- [ ] Verified

---

## Session Notes

<!-- Update this section at the end of each work session -->

### YYYY-MM-DD
- What was accomplished
- What's blocked (if anything)
- Next session should start with...
