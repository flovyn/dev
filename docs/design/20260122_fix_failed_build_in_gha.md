# Design: Fix Failed Build in GHA

**Date:** 2026-01-22
**Status:** Draft
**GitHub Issue:** https://github.com/flovyn/sdk-python/issues/1

## Problem Statement

The sdk-python CI build is failing on the `ruff format --check` step. Additionally, there are mypy type errors that may cause follow-up failures. The issue also requests adding pre-commit checks to catch these issues before code is pushed.

### Current Failures

**1. Ruff Format Check (Immediate Failure)**

Two files have formatting inconsistencies:
- `tests/e2e/test_comprehensive.py`
- `tests/e2e/test_concurrency.py`

The issues are minor line-break differences where ruff prefers collapsing multi-line function calls onto single lines when they fit within the configured line length (100 chars).

**2. Mypy Type Errors (Potential Follow-up)**

16 type errors in `flovyn/worker.py` and `flovyn/client.py`:
- All errors are `[no-any-return]` - functions returning `Any` when a specific type is declared

Example:
```
flovyn/worker.py:198: error: Returning Any from function declared to return "str"
flovyn/client.py:571: error: Returning Any from function declared to return "str"
```

**3. No Pre-commit Hooks**

There is currently no `.pre-commit-config.yaml` in the repository. Developers can commit code that fails CI checks without any local warning.

## Proposed Solution

### Phase 1: Fix Immediate CI Failure

1. Run `ruff format flovyn tests` to auto-fix the 2 formatting issues
2. Verify CI passes with `ruff check` and `ruff format --check`

### Phase 2: Fix Type Errors

Add explicit type casts or refine return types in `flovyn/worker.py` and `flovyn/client.py` to satisfy mypy's `no-any-return` rule.

The pattern appears consistent - these are likely FFI return values being passed through without type narrowing.

### Phase 3: Add Pre-commit Hooks

Add `.pre-commit-config.yaml` with hooks for:
- **ruff** - lint and format checks
- **mypy** - type checking

This ensures developers catch issues locally before pushing.

## Architecture Decisions

### AD-1: Use ruff for both linting and formatting

**Decision:** Continue using ruff (already configured in `pyproject.toml`)

**Rationale:**
- Already adopted in the project
- Single tool for lint + format reduces complexity
- Fast execution (Rust-based)

### AD-2: Pre-commit over custom scripts

**Decision:** Use the pre-commit framework rather than custom git hooks

**Rationale:**
- Industry standard tool
- Easy to install (`pre-commit install`)
- Manages tool versions automatically
- CI can also run `pre-commit run --all-files` for consistency

### AD-3: Type cast approach for mypy errors

**Decision:** Use explicit casts (`cast(T, value)`) rather than suppressing errors

**Rationale:**
- Maintains type safety information
- Clearly documents expected types at FFI boundary
- Preferable to `# type: ignore` comments

## Files to Modify

| File | Change |
|------|--------|
| `tests/e2e/test_comprehensive.py` | Auto-format with ruff |
| `tests/e2e/test_concurrency.py` | Auto-format with ruff |
| `flovyn/worker.py` | Add type casts for 2 return statements |
| `flovyn/client.py` | Add type casts for 14 return statements |
| `.pre-commit-config.yaml` | New file with ruff + mypy hooks |
| `pyproject.toml` | Possibly add pre-commit to dev dependencies |

## Open Questions (Resolved)

1. **Should pre-commit include mypy?**
   - **Decision: Yes** — Include mypy to catch type errors locally before push

2. **Should we add the examples/ directory to CI checks?**
   - Out of scope for this fix

3. **Pin ruff version in pre-commit config?**
   - **Decision: Yes** — Pin to `v0.14.13` to match installed version for reproducibility

## Testing Plan

1. Run full CI pipeline locally:
   ```bash
   uv run ruff check flovyn tests
   uv run ruff format --check flovyn tests
   uv run mypy flovyn
   uv run pytest tests/unit -v
   ```

2. Test pre-commit hooks:
   ```bash
   pre-commit install
   pre-commit run --all-files
   ```

3. Verify GitHub Actions CI passes on PR

## Out of Scope

- E2E test fixes (separate concern)
- CI workflow refactoring
- Python version matrix testing changes
