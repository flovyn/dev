# {Feature Name} Design

**Date:** YYYY-MM-DD
**Status:** Draft | Review | Approved
**Branch:** {feature}

## Overview

Brief description of what this feature does and why it's needed.

## Goals

1. Primary goal
2. Secondary goal
3. ...

## Non-Goals

- What this feature explicitly won't do
- Scope boundaries

## Current State

How does the system work today? What's the gap?

## Proposed Solution

### Architecture

High-level description and component interactions.

```
┌──────────┐     ┌──────────┐
│ Component│────>│ Component│
└──────────┘     └──────────┘
```

### Domain Model

Key data structures (if applicable):

```rust
pub struct Example {
    pub id: Uuid,
    pub name: String,
}
```

### API Changes

REST/gRPC changes with examples:

```
POST /api/orgs/{org_slug}/examples
{
    "name": "example"
}
```

### Database Changes

New tables, columns, or migrations needed.

### Affected Repositories

<!-- REQUIRED: Check all repos that need changes. Unchecked repos won't be included in the plan. -->

- [ ] flovyn-server - {describe changes, or delete this line if not affected}
- [ ] flovyn-app - {describe changes, or delete this line if not affected}
- [ ] sdk-python - {describe changes, or delete this line if not affected}
- [ ] sdk-rust - {describe changes, or delete this line if not affected}
- [ ] sdk-kotlin - {describe changes, or delete this line if not affected}

### Key Files

<!-- Reference files using `{repo}/{path}` format -->

- `flovyn-server/src/domain/example.rs` - Domain model
- `flovyn-server/server/src/api/rest/example.rs` - REST handlers

## Alternatives Considered

| Alternative | Pros | Cons | Why Not |
|-------------|------|------|---------|
| Option A | ... | ... | ... |
| Option B | ... | ... | Chosen |

## Open Questions

- [ ] Question that needs resolution before implementation
- [ ] Another question

## Security Considerations

Any auth, validation, or security implications.

## References

- Links to related designs
- External documentation
- Relevant issues/PRs
