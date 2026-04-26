#!/bin/bash
# Run chicc unit tests using compileModules for proper per-package compilation.
# Usage: ./run_tests.sh [test_file.chi ...]
# If no arguments given, runs all tests/test_*.chi files.
#
# Parallel execution:
#   Set JOBS environment variable to run tests in parallel:
#     JOBS=4 ./run_tests.sh
#     make test JOBS=4
#
# How it works:
#   1. Ensures chicc.lua is built
#   2. For each test file, prepends a package declaration, then uses
#      compileModules to compile the test together with all chicc modules
#   3. Runs the compiled test via the bootstrap compiler
#
# Environment variables:
#   CHI_BOOTSTRAP  Bootstrap compiler to use (default: chi)
#   JOBS           Number of parallel test jobs (default: 1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CHI_HOME="${CHI_HOME:-$HOME/.chi}"
# The test runner requires compileModules which is only in the bootstrap compiler.
# Override with CHI_BOOTSTRAP env var if the bootstrap compiler is elsewhere.
CHI_BOOTSTRAP="${CHI_BOOTSTRAP:-chi}"
# Number of parallel jobs
JOBS="${JOBS:-1}"

# All chicc source modules (order matches compile.chi)
CHICC_SOURCES=(
    "chicc/messages.chi"
    "chicc/source.chi"
    "chicc/token.chi"
    "chicc/types.chi"
    "chicc/util.chi"
    "chicc/ast.chi"
    "chicc/parse_ast.chi"
    "chicc/type_writer.chi"
    "chicc/emitter.chi"
    "chicc/lexer.chi"
    "chicc/parser.chi"
    "chicc/symbols.chi"
    "chicc/ast_converter.chi"
    "chicc/unification.chi"
    "chicc/inference_context.chi"
    "chicc/typer.chi"
    "chicc/checks.chi"
    "chicc/compiler.chi"
    "chicc/cli.chi"
    "tests/test_util.chi"
)

# Ensure chicc is built
if [ ! -f "chicc.lua" ]; then
    echo "chicc.lua not found, building first..."
    "$CHI_BOOTSTRAP" compile.chi
fi

# Build the compileModules source list for the compile script
SOURCES_LIST=""
for src in "${CHICC_SOURCES[@]}"; do
    if [ -n "$SOURCES_LIST" ]; then
        SOURCES_LIST="$SOURCES_LIST,"
    fi
    SOURCES_LIST="$SOURCES_LIST\"$src\""
done

# Determine which test files to run
if [ $# -gt 0 ]; then
    TEST_FILES=("$@")
else
    TEST_FILES=(tests/test_*.chi)
fi

# Run a single test, writing PASS/FAIL to results_dir/<basename>.result
# and captured output to results_dir/<basename>.output.
run_single_test() {
    local test_file="$1"
    local results_dir="$2"
    local base
    base=$(basename "$test_file" .chi)

    local tmpdir
    tmpdir=$(mktemp -d /tmp/chicc_test.XXXXXX)
    local tmpchi="$tmpdir/test_tmp.chi"
    local runner="$tmpdir/runner.chi"

    cat > "$runner" << CHIEOF
import std/lang { compileModules }
compileModules(["$tmpchi",${SOURCES_LIST}])
CHIEOF

    { echo "package chicc/test_runner"; cat "$test_file"; } > "$tmpchi"

    local TIMEOUT_CMD=""
    if command -v timeout &> /dev/null; then
        TIMEOUT_CMD="timeout 600"
    fi

    local result_file="$results_dir/$base.result"
    local output_file="$results_dir/$base.output"

    if $TIMEOUT_CMD "$CHI_BOOTSTRAP" "$runner" > "$output_file" 2>&1; then
        echo "PASS" > "$result_file"
    else
        echo "FAIL" > "$result_file"
    fi

    rm -rf "$tmpdir"
}

PASSED=0
FAILED=0
ERRORS=""

if [ "$JOBS" -le 1 ]; then
    # Sequential execution (original behaviour)
    for test_file in "${TEST_FILES[@]}"; do
        # Skip test_util.chi — it's a library, not a test
        if [[ "$(basename "$test_file")" == "test_util.chi" ]]; then
            continue
        fi

        printf "%-50s " "$test_file"

        results_dir=$(mktemp -d /tmp/chicc_test_results.XXXXXX)
        run_single_test "$test_file" "$results_dir"

        base=$(basename "$test_file" .chi)
        result_file="$results_dir/$base.result"
        output_file="$results_dir/$base.output"

        result=$(cat "$result_file")
        echo "$result"
        if [ "$result" = "PASS" ]; then
            PASSED=$((PASSED + 1))
        else
            FAILED=$((FAILED + 1))
            ERRORS="$ERRORS\n--- $test_file ---\n$(cat "$output_file")\n"
        fi

        rm -rf "$results_dir"
    done
else
    # Parallel execution
    RESULTS_DIR=$(mktemp -d /tmp/chicc_test_results.XXXXXX)

    pids=()

    for test_file in "${TEST_FILES[@]}"; do
        if [[ "$(basename "$test_file")" == "test_util.chi" ]]; then
            continue
        fi

        # Wait if we are at capacity
        while [ ${#pids[@]} -ge "$JOBS" ]; do
            wait -n
            new_pids=()
            for pid in "${pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    new_pids+=("$pid")
                fi
            done
            pids=("${new_pids[@]}")
        done

        run_single_test "$test_file" "$RESULTS_DIR" &
        pids+=($!)
    done

    # Wait for remaining jobs
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done

    # Collect results in original order
    for test_file in "${TEST_FILES[@]}"; do
        if [[ "$(basename "$test_file")" == "test_util.chi" ]]; then
            continue
        fi

        base=$(basename "$test_file" .chi)
        result_file="$RESULTS_DIR/$base.result"
        output_file="$RESULTS_DIR/$base.output"

        printf "%-50s " "$test_file"
        if [ -f "$result_file" ]; then
            result=$(cat "$result_file")
            echo "$result"
            if [ "$result" = "PASS" ]; then
                PASSED=$((PASSED + 1))
            else
                FAILED=$((FAILED + 1))
                ERRORS="$ERRORS\n--- $test_file ---\n$(cat "$output_file")\n"
            fi
        else
            echo "MISSING"
            FAILED=$((FAILED + 1))
        fi
    done

    rm -rf "$RESULTS_DIR"
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed out of $((PASSED + FAILED)) tests"

if [ $FAILED -gt 0 ]; then
    echo ""
    echo "=== Failures ==="
    echo -e "$ERRORS"
    exit 1
fi
