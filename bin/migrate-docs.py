#!/usr/bin/env python3
"""
migrate-docs.py - Migrate docs from scattered .dev/docs/ to centralized dev/docs/

Usage:
    ./migrate-docs.py --dry-run    # Preview changes without executing
    ./migrate-docs.py              # Execute migration
"""

import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

WORKSPACE = Path("/home/ubuntu/workspaces/flovyn")
TARGET_DIR = WORKSPACE / "dev" / "docs"
MAPPING_FILE = TARGET_DIR / "migration-map.txt"

# Source directories (path, repo_name)
SOURCES = [
    (WORKSPACE / "flovyn-server" / ".dev" / "docs", "flovyn-server"),
    (WORKSPACE / "flovyn-app" / ".dev" / "docs", "flovyn-app"),
    (WORKSPACE / "sdk-rust" / ".dev" / "docs", "sdk-rust"),
    (WORKSPACE / "sdk-kotlin" / ".dev" / "docs", "sdk-kotlin"),
]

# Target directories to create
TARGET_DIRS = ["design", "plans", "research", "bugs", "guides", "architecture", "archive"]

# File extensions for code references
CODE_EXTENSIONS = {".rs", ".ts", ".tsx", ".py", ".kt", ".toml", ".sql", ".md", ".sh", ".json", ".yaml", ".yml"}


@dataclass
class FileMapping:
    old_path: Path
    new_path: Path
    old_filename: str
    new_filename: str
    source_repo: str


def get_git_date(file_path: Path) -> str:
    """Get file creation date from git history."""
    try:
        # Try to get the date when file was added
        result = subprocess.run(
            ["git", "-C", str(file_path.parent), "log", "--follow", "--format=%cs", "--diff-filter=A", "--", str(file_path)],
            capture_output=True, text=True, timeout=10
        )
        dates = result.stdout.strip().split('\n')
        if dates and dates[-1]:
            return dates[-1].replace("-", "")

        # Fallback to last modified date
        result = subprocess.run(
            ["git", "-C", str(file_path.parent), "log", "-1", "--format=%cs", "--", str(file_path)],
            capture_output=True, text=True, timeout=10
        )
        if result.stdout.strip():
            return result.stdout.strip().replace("-", "")
    except Exception:
        pass

    # Fallback to today
    from datetime import date
    return date.today().strftime("%Y%m%d")


def normalize_filename(filename: str, source_file: Path) -> str:
    """Normalize filename to YYYYMMDD_snake_case.md format."""
    result = filename

    # Remove .md extension for processing
    if result.endswith(".md"):
        result = result[:-3]

    # Check if already has YYYYMMDD_ prefix
    if not re.match(r"^\d{8}_", result):
        # Add date prefix
        date = get_git_date(source_file)
        result = f"{date}_{result}"

    # Remove sequence numbers like _001- or _002-
    result = re.sub(r"_\d{3}-", "_", result)

    # Convert kebab-case to snake_case
    result = result.replace("-", "_")

    return f"{result}.md"


def build_filename_mapping(dry_run: bool) -> Tuple[List[FileMapping], Dict[str, str]]:
    """Build mapping of old paths to new paths."""
    mappings: List[FileMapping] = []
    filename_map: Dict[str, str] = {}  # old_filename -> new_filename

    for source_dir, source_repo in SOURCES:
        if not source_dir.exists():
            continue

        for source_file in sorted(source_dir.rglob("*.md")):
            relative_path = source_file.relative_to(source_dir)
            parts = relative_path.parts

            # Get directory type (bugs, design, plans, research, guides)
            dir_type = parts[0]

            # Get filename and normalize
            old_filename = source_file.name
            new_filename = normalize_filename(old_filename, source_file)

            # Handle subdirectories
            if len(parts) > 2:
                subdir = parts[1]
                target_path = TARGET_DIR / dir_type / subdir / new_filename
            else:
                target_path = TARGET_DIR / dir_type / new_filename

            # Check for conflicts
            if target_path.exists() or any(m.new_path == target_path for m in mappings):
                # Add repo suffix to resolve
                base = new_filename[:-3]  # Remove .md
                new_filename = f"{base}_{source_repo}.md"
                if len(parts) > 2:
                    target_path = TARGET_DIR / dir_type / subdir / new_filename
                else:
                    target_path = TARGET_DIR / dir_type / new_filename

            mapping = FileMapping(
                old_path=source_file,
                new_path=target_path,
                old_filename=old_filename,
                new_filename=new_filename,
                source_repo=source_repo
            )
            mappings.append(mapping)
            filename_map[old_filename] = new_filename

    return mappings, filename_map


def normalize_doc_link(link: str, filename_map: Dict[str, str], source_repo: str) -> str:
    """Normalize a documentation link."""
    # Extract just the filename from the path
    filename = os.path.basename(link)

    if filename in filename_map:
        # Replace filename with new name
        new_filename = filename_map[filename]
        return link.replace(filename, new_filename)

    return link


def normalize_code_reference(ref: str, source_repo: str) -> str:
    """Normalize a code reference to {repo}/{path} format."""
    # Already has repo prefix
    for repo in ["flovyn-server", "flovyn-app", "sdk-rust", "sdk-python", "sdk-kotlin", "dev"]:
        if ref.startswith(f"{repo}/"):
            # Just convert kebab to snake if needed in the path part after repo
            return ref

    # Absolute path - strip workspace prefix
    workspace_str = str(WORKSPACE)
    if ref.startswith(workspace_str):
        ref = ref[len(workspace_str):].lstrip("/")
        return ref

    # Relative path like ../../src/foo.rs or ../src/foo.rs
    if ref.startswith(".."):
        # Try to resolve based on source repo
        # Remove leading ../
        clean_ref = re.sub(r"^(\.\./)+", "", ref)
        return f"{source_repo}/{clean_ref}"

    # Path without repo prefix like src/foo.rs
    if "/" in ref and not ref.startswith("."):
        # Check if it looks like a code path
        ext = os.path.splitext(ref)[1]
        if ext in CODE_EXTENSIONS:
            return f"{source_repo}/{ref}"

    return ref


def normalize_links_in_content(content: str, filename_map: Dict[str, str], source_repo: str) -> Tuple[str, List[str]]:
    """Normalize all links in file content. Returns (new_content, warnings)."""
    warnings = []
    new_content = content

    # Pattern for markdown links: [text](path)
    md_link_pattern = r'\[([^\]]*)\]\(([^)]+)\)'

    def replace_md_link(match):
        text = match.group(1)
        path = match.group(2)

        # Skip URLs
        if path.startswith(("http://", "https://", "#")):
            return match.group(0)

        # Check if it's a doc link
        if path.endswith(".md") or "/.dev/docs/" in path:
            new_path = normalize_doc_link(path, filename_map, source_repo)
            # Also update .dev/docs paths
            new_path = re.sub(r"[^/]+/\.dev/docs/", "dev/docs/", new_path)
            return f"[{text}]({new_path})"

        # Check if it's a code reference
        ext = os.path.splitext(path)[1]
        if ext in CODE_EXTENSIONS:
            new_path = normalize_code_reference(path, source_repo)
            return f"[{text}]({new_path})"

        return match.group(0)

    new_content = re.sub(md_link_pattern, replace_md_link, new_content)

    # Pattern for inline code paths in backticks: `path/to/file.rs`
    code_ref_pattern = r'`([^`]+\.[a-z]{1,4}(?::\d+)?)`'

    def replace_code_ref(match):
        ref = match.group(1)
        ext = os.path.splitext(ref.split(":")[0])[1]  # Handle :line_number
        if ext in CODE_EXTENSIONS:
            new_ref = normalize_code_reference(ref, source_repo)
            return f"`{new_ref}`"
        return match.group(0)

    new_content = re.sub(code_ref_pattern, replace_code_ref, new_content)

    # Pattern for Design/Plan references: **Design:** [link] or **Design:** path
    meta_pattern = r'\*\*(Design|Plan|Bug):\*\*\s*\[?([^\]\n]+)\]?'

    def replace_meta(match):
        label = match.group(1)
        path = match.group(2).strip()
        if path.endswith(".md"):
            new_path = normalize_doc_link(path, filename_map, source_repo)
            new_path = re.sub(r"[^/]+/\.dev/docs/", "dev/docs/", new_path)
            return f"**{label}:** {new_path}"
        return match.group(0)

    new_content = re.sub(meta_pattern, replace_meta, new_content)

    return new_content, warnings


def migrate_file(mapping: FileMapping, filename_map: Dict[str, str], dry_run: bool) -> List[str]:
    """Migrate a single file. Returns warnings."""
    warnings = []

    # Read content
    content = mapping.old_path.read_text()

    # Normalize links
    new_content, link_warnings = normalize_links_in_content(content, filename_map, mapping.source_repo)
    warnings.extend(link_warnings)

    if not dry_run:
        # Create parent directory
        mapping.new_path.parent.mkdir(parents=True, exist_ok=True)

        # Write file
        mapping.new_path.write_text(new_content)

    return warnings


def write_mapping_file(mappings: List[FileMapping], dry_run: bool):
    """Write the mapping file."""
    if dry_run:
        return

    with open(MAPPING_FILE, "w") as f:
        f.write("# Doc Migration Mapping\n")
        f.write(f"# Generated: {subprocess.run(['date'], capture_output=True, text=True).stdout.strip()}\n")
        f.write("# Format: old_path -> new_path\n\n")

        for m in mappings:
            f.write(f"{m.old_path} -> {m.new_path}\n")


def main():
    dry_run = "--dry-run" in sys.argv

    if dry_run:
        print("=== DRY RUN MODE ===\n")

    print("=== Doc Migration Script ===\n")

    # Create target directories
    print("Creating target directories...")
    for dir_name in TARGET_DIRS:
        target = TARGET_DIR / dir_name
        print(f"  {target}")
        if not dry_run:
            target.mkdir(parents=True, exist_ok=True)
    print()

    # Build mapping
    print("Building file mapping...")
    mappings, filename_map = build_filename_mapping(dry_run)
    print(f"  Found {len(mappings)} files to migrate\n")

    # Migrate files
    all_warnings = []
    for mapping in mappings:
        print(f"  {mapping.old_path}")
        print(f"    -> {mapping.new_path}")

        warnings = migrate_file(mapping, filename_map, dry_run)
        all_warnings.extend(warnings)

    # Write mapping file
    write_mapping_file(mappings, dry_run)

    # Summary
    print("\n=== Summary ===")
    if dry_run:
        print("Dry run complete. No files were modified.")
        print("Run without --dry-run to execute migration.")
    else:
        migrated = len(list(TARGET_DIR.rglob("*.md")))
        print(f"Migrated files: {migrated}")
        print(f"Mapping file: {MAPPING_FILE}")

    if all_warnings:
        print(f"\nWarnings ({len(all_warnings)}):")
        for w in all_warnings:
            print(f"  - {w}")


if __name__ == "__main__":
    main()
