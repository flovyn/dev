# Release Process

This document describes the coordinated release process for Flovyn workspace repositories.

## Overview

The workspace release workflow (`dev/.github/workflows/release.yml`) coordinates releases across all Flovyn repositories in the correct order:

1. **sdk-rust** - Core Rust SDK and FFI bindings
2. **Language SDKs** (parallel) - sdk-python, sdk-kotlin, sdk-typescript
3. **flovyn-server** - The server

Each release step creates a git tag (e.g., `v0.2.0`) which triggers the individual repo's release workflow.

## Prerequisites

1. **WORKSPACE_PAT** - A fine-grained PAT with:
   - `contents: write` for all repos (to push tags)
   - `actions: write` for dev repo (to trigger workflows)

2. **All repos on main** - Ensure all repos have merged their changes to main before releasing.

3. **Tests passing** - Run workspace integration to verify all tests pass.

## Release Steps

### 1. Verify Tests Pass

```bash
# Trigger workspace integration manually
gh workflow run integration.yml -R flovyn/dev -f branch=main
```

Wait for the workflow to complete successfully.

### 2. Dry Run Release

Always run a dry run first to verify the release would work:

```bash
gh workflow run release.yml -R flovyn/dev \
  -f version=0.2.0 \
  -f dry_run=true
```

Check the workflow output to verify:
- No tags already exist with the target version
- Version updates in language SDK CI workflows are correct

### 3. Execute Release

Once dry run passes, execute the actual release:

```bash
gh workflow run release.yml -R flovyn/dev \
  -f version=0.2.0 \
  -f dry_run=false
```

### 4. Monitor Release Workflows

After tags are pushed, each repo's release workflow will trigger. Monitor:

- [sdk-rust releases](https://github.com/flovyn/sdk-rust/actions/workflows/release.yml)
- [sdk-python releases](https://github.com/flovyn/sdk-python/actions/workflows/release.yml)
- [sdk-kotlin releases](https://github.com/flovyn/sdk-kotlin/actions/workflows/release.yml)
- [sdk-typescript releases](https://github.com/flovyn/sdk-typescript/actions/workflows/release.yml)
- [flovyn-server releases](https://github.com/flovyn/flovyn-server/actions/workflows/release.yml)

## What the Release Workflow Does

### sdk-rust

1. Creates and pushes tag `v{version}`
2. Triggers sdk-rust release workflow which:
   - Builds FFI libraries for all platforms
   - Creates GitHub release with artifacts
   - Publishes to crates.io

### Language SDKs

For each of sdk-python, sdk-kotlin, sdk-typescript:

1. Updates `FFI_VERSION` or `NAPI_VERSION` in `.github/workflows/ci.yml`
2. Commits and pushes the change
3. Creates and pushes tag `v{version}`
4. Triggers repo's release workflow which:
   - Downloads FFI/NAPI binaries from sdk-rust release
   - Builds and publishes packages (PyPI, Maven, npm)

### flovyn-server

1. Creates and pushes tag `v{version}`
2. Triggers flovyn-server release workflow which:
   - Builds Docker images
   - Pushes to container registry
   - Creates GitHub release

## Rollback

If a release needs to be rolled back:

1. **Delete the tags** in affected repos:
   ```bash
   git push --delete origin v0.2.0
   git tag -d v0.2.0
   ```

2. **Unpublish packages** if already published:
   - PyPI: Yank the version
   - npm: `npm unpublish @flovyn/sdk@0.2.0`
   - Maven Central: Cannot unpublish, must release patch

3. **Revert commits** in language SDK repos that updated FFI_VERSION

## Version Numbering

We use semantic versioning:

- **Major** (1.0.0): Breaking API changes
- **Minor** (0.2.0): New features, backward compatible
- **Patch** (0.1.1): Bug fixes, backward compatible

All repos share the same version number to ensure compatibility.

## Troubleshooting

### Tag already exists

If a tag already exists, the workflow will fail. Either:
- Choose a different version
- Delete the existing tag if it was from a failed release

### Release workflow fails mid-way

If the release fails after some tags are pushed:
1. Check which repos have the tag
2. Delete tags from repos that have them
3. Fix the issue
4. Re-run the release

### Individual repo release workflow fails

The workspace release only creates tags. If the individual repo's release workflow fails:
1. Fix the issue in the repo
2. Re-run the failed release workflow manually
3. No need to re-run workspace release
