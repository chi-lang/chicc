#!/bin/bash
# fixed_point_verification.sh — Verify the self-hosting compiler reached fixed point
# After compiler changes, run this to ensure generated chicc.lua is stable

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔄 Fixed Point Verification"
echo "=========================================="

# Function to clean and compile
compile_generation() {
  local gen=$1
  echo ""
  echo "Generation $gen:"

  # Clean cache for fresh compilation
  rm -rf .cache

  # Compile
  ./run_chicc.sh compile.chi > /dev/null 2>&1

  # Save result
  cp chicc.lua "chicc-gen$gen.lua"
  echo "  ✓ Compiled to chicc-gen$gen.lua"
}

# Generation 1: compile with current chicc.lua
compile_generation 1

# Generation 2: compile with generated gen1
compile_generation 2

# Compare
echo ""
echo "Comparing generations:"
if diff -q chicc-gen1.lua chicc-gen2.lua > /dev/null 2>&1; then
  echo "  ✅ FIXED POINT REACHED"
  echo ""
  echo "Generations are identical. Compiler is self-hosting stable."
  rm -f chicc-gen1.lua chicc-gen2.lua
  rm -rf .cache
  exit 0
else
  echo "  ❌ FIXED POINT NOT REACHED"
  echo ""
  echo "Differences found between gen1 and gen2:"
  diff chicc-gen1.lua chicc-gen2.lua | head -20
  echo ""
  echo "Full diffs saved to:"
  echo "  - chicc-gen1.lua"
  echo "  - chicc-gen2.lua"
  echo ""
  echo "Use: diff chicc-gen1.lua chicc-gen2.lua"
  exit 1
fi
