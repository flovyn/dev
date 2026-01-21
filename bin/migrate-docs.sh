#!/bin/bash
#
# migrate-docs.sh - Migrate docs from scattered .dev/docs/ to centralized dev/docs/
#
# Usage:
#   ./migrate-docs.sh --dry-run    # Preview changes without executing
#   ./migrate-docs.sh              # Execute migration
#

set -euo pipefail

WORKSPACE="/home/ubuntu/workspaces/flovyn"
TARGET_DIR="$WORKSPACE/dev/docs"
MAPPING_FILE="$WORKSPACE/dev/docs/migration-map.txt"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "=== DRY RUN MODE ==="
    echo ""
fi

# Source directories (path:repo_name)
SOURCES=(
    "$WORKSPACE/flovyn-server/.dev/docs:flovyn-server"
    "$WORKSPACE/flovyn-app/.dev/docs:flovyn-app"
    "$WORKSPACE/sdk-rust/.dev/docs:sdk-rust"
    "$WORKSPACE/sdk-kotlin/.dev/docs:sdk-kotlin"
)

# Target directories to create
TARGET_DIRS=(
    "$TARGET_DIR/design"
    "$TARGET_DIR/plans"
    "$TARGET_DIR/research"
    "$TARGET_DIR/bugs"
    "$TARGET_DIR/guides"
    "$TARGET_DIR/architecture"
    "$TARGET_DIR/archive"
)

# Initialize mapping file
init_mapping() {
    if [[ "$DRY_RUN" == false ]]; then
        echo "# Doc Migration Mapping" > "$MAPPING_FILE"
        echo "# Generated: $(date)" >> "$MAPPING_FILE"
        echo "# Format: old_path -> new_path" >> "$MAPPING_FILE"
        echo "" >> "$MAPPING_FILE"
    fi
}

# Log to mapping file
log_mapping() {
    local old_path="$1"
    local new_path="$2"
    if [[ "$DRY_RUN" == false ]]; then
        echo "$old_path -> $new_path" >> "$MAPPING_FILE"
    fi
    echo "  $old_path"
    echo "    -> $new_path"
}

# Get file creation date from git
get_git_date() {
    local file="$1"
    local date
    date=$(git -C "$(dirname "$file")" log --follow --format=%cs --diff-filter=A -- "$file" 2>/dev/null | tail -1)
    if [[ -z "$date" ]]; then
        # Fallback to last modified date
        date=$(git -C "$(dirname "$file")" log -1 --format=%cs -- "$file" 2>/dev/null)
    fi
    if [[ -z "$date" ]]; then
        # Fallback to today
        date=$(date +%Y-%m-%d)
    fi
    # Convert YYYY-MM-DD to YYYYMMDD
    echo "${date//-/}"
}

# Normalize filename to YYYYMMDD_snake_case.md
normalize_filename() {
    local filename="$1"
    local source_file="$2"
    local result="$filename"

    # Remove .md extension for processing
    result="${result%.md}"

    # Check if already has YYYYMMDD_ prefix
    if [[ ! "$result" =~ ^[0-9]{8}_ ]]; then
        # Add date prefix
        local date
        date=$(get_git_date "$source_file")
        result="${date}_${result}"
    fi

    # Remove sequence numbers like _001- or _002-
    result=$(echo "$result" | sed -E 's/_[0-9]{3}-/_/')

    # Convert kebab-case to snake_case (hyphens to underscores)
    result="${result//-/_}"

    # Add .md back
    result="${result}.md"

    echo "$result"
}

# Create target directories
create_dirs() {
    echo "Creating target directories..."
    for dir in "${TARGET_DIRS[@]}"; do
        if [[ "$DRY_RUN" == false ]]; then
            mkdir -p "$dir"
        fi
        echo "  $dir"
    done
    echo ""
}

# Process a single file
process_file() {
    local source_file="$1"
    local source_repo="$2"
    local relative_path="$3"

    # Get directory type (bugs, design, plans, research, guides)
    local dir_type
    dir_type=$(echo "$relative_path" | cut -d'/' -f1)

    # Get filename
    local filename
    filename=$(basename "$source_file")

    # Handle subdirectories (e.g., research/ai-agent-native/)
    local subdir=""
    local depth
    depth=$(echo "$relative_path" | tr '/' '\n' | wc -l)
    if [[ $depth -gt 2 ]]; then
        # Has subdirectory - extract it
        subdir=$(echo "$relative_path" | cut -d'/' -f2)
    fi

    # Normalize filename
    local new_filename
    new_filename=$(normalize_filename "$filename" "$source_file")

    # Determine target path
    local target_path
    if [[ -n "$subdir" ]]; then
        # Keep subdirectory structure
        target_path="$TARGET_DIR/$dir_type/$subdir/$new_filename"
        if [[ "$DRY_RUN" == false ]]; then
            mkdir -p "$TARGET_DIR/$dir_type/$subdir"
        fi
    else
        target_path="$TARGET_DIR/$dir_type/$new_filename"
    fi

    # Check for conflicts
    if [[ -f "$target_path" ]]; then
        echo "  WARNING: Conflict - $target_path already exists!"
        # Add repo suffix to resolve
        new_filename="${new_filename%.md}_${source_repo}.md"
        if [[ -n "$subdir" ]]; then
            target_path="$TARGET_DIR/$dir_type/$subdir/$new_filename"
        else
            target_path="$TARGET_DIR/$dir_type/$new_filename"
        fi
    fi

    # Log mapping
    log_mapping "$source_file" "$target_path"

    # Copy file
    if [[ "$DRY_RUN" == false ]]; then
        cp "$source_file" "$target_path"
    fi
}

# Process all files from a source
process_source() {
    local source_info="$1"
    local source_dir="${source_info%%:*}"
    local source_repo="${source_info##*:}"

    if [[ ! -d "$source_dir" ]]; then
        echo "Skipping $source_dir (does not exist)"
        return
    fi

    echo "Processing $source_dir..."
    echo ""

    # Find all .md files
    while IFS= read -r -d '' file; do
        local relative_path="${file#$source_dir/}"
        process_file "$file" "$source_repo" "$relative_path"
    done < <(find "$source_dir" -name "*.md" -type f -print0 | sort -z)

    echo ""
}

# Main
main() {
    echo "=== Doc Migration Script ==="
    echo ""

    init_mapping
    create_dirs

    for source in "${SOURCES[@]}"; do
        process_source "$source"
    done

    echo "=== Summary ==="
    local total
    if [[ "$DRY_RUN" == false ]]; then
        total=$(find "$TARGET_DIR" -name "*.md" -type f | wc -l)
        echo "Migrated files: $total"
        echo "Mapping file: $MAPPING_FILE"
    else
        echo "Dry run complete. No files were modified."
        echo "Run without --dry-run to execute migration."
    fi
}

main
