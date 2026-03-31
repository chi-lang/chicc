#!/bin/bash
# run_tests.sh — Run Chi test files with the test_util framework
#
# Usage: ./run_tests.sh [test_file.chi ...]
#   If no files given, runs all tests/test_*.chi files.
#
# How it works:
#   The Chi compiler currently doesn't support cross-file user module imports.
#   This script works around that by:
#   1. Stripping the package declaration and import lines from test_util.chi
#   2. Auto-discovering all source modules in chicc/chicc/*.chi and inlining
#      them (stripping package decls and cross-user imports)
#   3. Stripping the import of user/* from each test file
#   4. Concatenating them into a single file and running with chi
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$SCRIPT_DIR/tests"
SRC_DIR="$SCRIPT_DIR/chicc"
UTIL_FILE="$TESTS_DIR/test_util.chi"

if [ ! -f "$UTIL_FILE" ]; then
    echo "ERROR: $UTIL_FILE not found"
    exit 1
fi

# Determine test files to run
if [ $# -gt 0 ]; then
    TEST_FILES=("$@")
else
    TEST_FILES=()
    for f in "$TESTS_DIR"/test_*.chi; do
        [ "$f" = "$UTIL_FILE" ] && continue
        [ -f "$f" ] && TEST_FILES+=("$f")
    done
fi

if [ ${#TEST_FILES[@]} -eq 0 ]; then
    echo "No test files found."
    exit 0
fi

PASS=0
FAIL=0

for test_file in "${TEST_FILES[@]}"; do
    # Resolve relative paths from tests/ dir
    if [ ! -f "$test_file" ] && [ -f "$TESTS_DIR/$test_file" ]; then
        test_file="$TESTS_DIR/$test_file"
    fi

    rel=$(basename "$test_file")
    tmp=$(mktemp /tmp/chi_test_XXXXXX.chi)
    tmp_imports=$(mktemp /tmp/chi_imports_XXXXXX.txt)
    tmp_code=$(mktemp /tmp/chi_code_XXXXXX.chi)

    # Collect imports and code separately, then merge:
    #   - All unique std imports go first
    #   - Then all code (with imports/package lines stripped)

    # From test_util.chi
    grep '^import ' "$UTIL_FILE" >> "$tmp_imports"
    grep -v '^import ' "$UTIL_FILE" | grep -v '^package ' >> "$tmp_code"

    # From source modules in chicc/chicc/
    # If .build_order exists, use it for explicit ordering; remaining files go alphabetically after
    if [ -d "$SRC_DIR" ]; then
        src_files=()
        if [ -f "$SRC_DIR/.build_order" ]; then
            # Read ordered files first
            while IFS= read -r line || [ -n "$line" ]; do
                line=$(echo "$line" | sed 's/#.*//' | xargs)
                [ -z "$line" ] && continue
                [ -f "$SRC_DIR/$line" ] && src_files+=("$SRC_DIR/$line")
            done < "$SRC_DIR/.build_order"
            # Then add remaining .chi files not listed, in alphabetical order
            for src_file in "$SRC_DIR"/*.chi; do
                [ -f "$src_file" ] || continue
                already_listed=false
                for listed in "${src_files[@]}"; do
                    if [ "$src_file" = "$listed" ]; then
                        already_listed=true
                        break
                    fi
                done
                if [ "$already_listed" = false ]; then
                    src_files+=("$src_file")
                fi
            done
        else
            for src_file in "$SRC_DIR"/*.chi; do
                [ -f "$src_file" ] || continue
                src_files+=("$src_file")
            done
        fi
        for src_file in "${src_files[@]}"; do
            # Skip cli.chi — it has a top-level entry point that would run instead of tests
            [ "$(basename "$src_file")" = "cli.chi" ] && continue
            grep '^import std/' "$src_file" >> "$tmp_imports" 2>/dev/null || true
            echo "" >> "$tmp_code"
            echo "// --- inlined: $(basename "$src_file") ---" >> "$tmp_code"
            grep -v '^package ' "$src_file" | grep -v '^import ' >> "$tmp_code"
        done
    fi

    # From the test file
    grep '^import std/' "$test_file" >> "$tmp_imports" 2>/dev/null || true
    echo "" >> "$tmp_code"
    grep -v '^import ' "$test_file" >> "$tmp_code"

    # Assemble: deduplicated imports first, then all code
    sort -u "$tmp_imports" > "$tmp"
    echo "" >> "$tmp"
    cat "$tmp_code" >> "$tmp"

    rm -f "$tmp_imports" "$tmp_code"

    printf "  Running %-40s " "$rel"
    if output=$(chi "$tmp" 2>&1); then
        printf "\033[32mOK\033[0m\n"
        echo "$output"
        PASS=$((PASS + 1))
    else
        printf "\033[31mFAIL\033[0m\n"
        echo "$output"
        FAIL=$((FAIL + 1))
    fi

    rm -f "$tmp"
done

echo ""
echo "Test files: $((PASS + FAIL)) total, $PASS passed, $FAIL failed"
[ $FAIL -gt 0 ] && exit 1
exit 0
