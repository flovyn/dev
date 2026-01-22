# Implementation Plan: Fix Failed Build in GHA

**Date:** 2026-01-22
**Design Doc:** [20260122_fix_failed_build_in_gha.md](../design/20260122_fix_failed_build_in_gha.md)

## Overview

Fix the sdk-python CI build failure (ruff format + mypy errors) and add pre-commit hooks.

## Decisions

- **Pre-commit includes mypy**: Yes — catches type errors locally before push
- **Pin ruff version**: Yes — pin to match pyproject.toml dev deps for reproducibility

---

## Phase 1: Fix Immediate CI Failure (Ruff Format)

- [x] Run `uv run ruff format flovyn tests` to auto-fix 2 files:
  - `tests/e2e/test_comprehensive.py`
  - `tests/e2e/test_concurrency.py`
- [x] Verify with `uv run ruff format --check flovyn tests`

## Phase 2: Fix Mypy Type Errors

Add `cast()` imports and wrap FFI return values. All 16 errors are `[no-any-return]` from FFI calls.

**`flovyn/worker.py`** (2 casts):
- [x] Line 198: `return cast(str, self._core_worker.get_status())`
- [x] Line 370: `return cast(str, self._core_worker.get_status())`

**`flovyn/client.py`** (14 casts):
- [x] Line 571: `return cast(str, promise_id)` — promise_id from `payload.get()`
- [x] Line 627: `return cast(str, self._core_worker.get_status())`
- [x] Line 638: `return cast(int, self._core_worker.get_uptime_ms())`
- [x] Line 649: `return cast(int, self._core_worker.get_started_at_ms())`
- [x] Line 660: `return cast(str, self._core_worker.get_worker_id())`
- [x] Line 733: `return cast(bool, self._core_worker.is_paused())`
- [x] Line 744: `return cast(bool, self._core_worker.is_running())`
- [x] Line 754: `return cast(str, self._core_worker.get_pause_reason())`
- [x] Line 769: `return cast(int, self._core_worker.get_max_concurrent_workflows())`
- [x] Line 780: `return cast(int, self._core_worker.get_max_concurrent_tasks())`
- [x] Line 791: `return cast(str, self._core_worker.get_queue())`
- [x] Line 802: `return cast(str, self._core_worker.get_org_id())`
- [x] Line 819: `return cast(list[Any], self._core_worker.poll_lifecycle_events())`
- [x] Line 830: `return cast(int, self._core_worker.pending_lifecycle_event_count())`

- [x] Add `from typing import cast` import if not present
- [x] Verify with `uv run mypy flovyn`

## Phase 3: Add Pre-commit Hooks

- [x] Create `.pre-commit-config.yaml` with:
  - ruff lint hook (pinned to v0.14.13)
  - ruff format hook (pinned to v0.14.13)
  - mypy hook (using local installation via `uv run`)
- [x] Add `pre-commit` to dev dependencies in `pyproject.toml`
- [x] Verify with `pre-commit run --all-files`

## Phase 4: Verification

- [x] Run full CI pipeline locally:
  ```bash
  cd sdk-python
  uv run ruff check flovyn tests
  uv run ruff format --check flovyn tests
  uv run mypy flovyn
  uv run pytest tests/unit -v
  ```
- [x] Verify pre-commit hooks work:
  ```bash
  pre-commit install
  pre-commit run --all-files
  ```

## Test Plan

1. **Ruff format**: No files should require reformatting after Phase 1
2. **Mypy**: Zero errors after Phase 2 casts are applied
3. **Unit tests**: All existing unit tests should pass (no behavioral changes)
4. **Pre-commit**: `pre-commit run --all-files` should pass

## Rollout Considerations

- This is a pure fix + tooling change with no behavioral impact
- Developers will need to run `pre-commit install` once after merging to enable local hooks
- Consider adding a note to README.md about pre-commit setup (or document in CLAUDE.md)

## Additional Fixes

- [x] Added `httpx` to mypy ignore_missing_imports in pyproject.toml (httpx is an optional runtime dependency in flovyn/testing/environment.py)
- [x] Fixed CI workflow e2e test command: added `-m e2e` to override default `addopts = "-m 'not e2e'"` in pyproject.toml
