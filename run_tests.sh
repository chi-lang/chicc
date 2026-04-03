#!/bin/bash
# Run chicc unit tests using compileModules for proper per-package compilation.
# Usage: ./run_tests.sh [test_file.chi ...]
# If no arguments given, runs all tests/test_*.chi files.
#
# How it works:
#   1. Ensures chicc modules are cached (builds if needed)
#   2. For each test file, prepends a package declaration, then uses
#      compileModules to compile the test together with all chicc modules
#   3. Runs the compiled test via dofile

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CHI_HOME="${CHI_HOME:-$HOME/.chi}"
# The test runner requires compileModules which is only in the bootstrap compiler.
# Override with CHI_BOOTSTRAP env var if the bootstrap compiler is elsewhere.
CHI_BOOTSTRAP="${CHI_BOOTSTRAP:-/home/marad/dev/chi/compiler/chi}"
CACHE_DIR=".cache"

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

# Ensure chicc is built (populates cache)
if [ ! -d "$CACHE_DIR/chicc" ]; then
    echo "Cache not found, building chicc first..."
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

# Create compile-and-run script template
RUNNER=$(mktemp /tmp/chicc_test_runner.XXXXXX.chi)
trap "rm -f '$RUNNER' /tmp/_chicc_test_tmp.chi" EXIT

cat > "$RUNNER" << CHIEOF
import std/lang { compileModules }
compileModules(["/tmp/_chicc_test_tmp.chi",${SOURCES_LIST}], ".cache")
CHIEOF

# Determine which test files to run
if [ $# -gt 0 ]; then
    TEST_FILES=("$@")
else
    TEST_FILES=(tests/test_*.chi)
fi

PASSED=0
FAILED=0
ERRORS=""

for test_file in "${TEST_FILES[@]}"; do
    # Skip test_util.chi — it's a library, not a test
    if [[ "$(basename "$test_file")" == "test_util.chi" ]]; then
        continue
    fi

    printf "%-50s " "$test_file"

    # Prepend a temporary package declaration so compileModules can handle it
    { echo "package chicc/test_runner"; cat "$test_file"; } > /tmp/_chicc_test_tmp.chi

    if OUTPUT=$(timeout 600 "$CHI_BOOTSTRAP" "$RUNNER" 2>&1); then
        echo "PASS"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL"
        FAILED=$((FAILED + 1))
        ERRORS="$ERRORS\n--- $test_file ---\n$OUTPUT\n"
    fi
done

echo ""
echo "Results: $PASSED passed, $FAILED failed out of $((PASSED + FAILED)) tests"

if [ $FAILED -gt 0 ]; then
    echo ""
    echo "=== Failures ==="
    echo -e "$ERRORS"
    exit 1
fi
