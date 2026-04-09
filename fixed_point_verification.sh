#!/bin/bash
# fixed_point_verification.sh — Verify the self-hosting compiler reached fixed point
# After compiler changes, run this to ensure generated chicc.lua is stable

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔄 Fixed Point Verification"
echo "=========================================="

# Back up original chicc.lua so we can restore on failure
cp chicc.lua chicc.lua.bak

cleanup() {
  local exit_code=$?
  if [ -f chicc.lua.bak ]; then
    echo ""
    echo "  ⚠️  Restoring original chicc.lua from backup"
    cp chicc.lua.bak chicc.lua
    rm -f chicc.lua.bak
  fi
  rm -f chicc-gen1.lua chicc-gen2.lua
  rm -rf .cache
  exit $exit_code
}
trap cleanup EXIT

# Validate that generated chicc.lua can be loaded by LuaJIT
validate_lua() {
  local file=$1
  local err
  err=$(luajit -e "
    local f=io.open('$file','r')
    local c=f:read('a'); f:close()
    local fn, e = load(c)
    if e then io.stderr:write(e .. '\n'); os.exit(1) end
  " 2>&1)
  if [ $? -ne 0 ]; then
    echo "  ❌ Generated $file has Lua syntax errors:"
    echo "  $err"
    return 1
  fi
  return 0
}

# Function to clean and compile
compile_generation() {
  local gen=$1
  echo ""
  echo "Generation $gen:"

  # Clean cache for fresh compilation
  rm -rf .cache

  # Compile (show errors!)
  if ! ./run_chicc.sh compile.chi; then
    echo "  ❌ Compilation failed for generation $gen"
    exit 1
  fi

  # Validate generated Lua
  if ! validate_lua chicc.lua; then
    echo "  ❌ Generation $gen produced invalid Lua"
    exit 1
  fi

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
  # Success: update chicc.lua with verified output, disarm restore
  cp chicc-gen1.lua chicc.lua
  rm -f chicc.lua.bak chicc-gen1.lua chicc-gen2.lua
  rm -rf .cache
  trap - EXIT
  exit 0
else
  echo "  ❌ FIXED POINT NOT REACHED"
  echo ""
  echo "Differences found between gen1 and gen2:"
  diff chicc-gen1.lua chicc-gen2.lua | head -20
  echo ""
  echo "Use: diff chicc-gen1.lua chicc-gen2.lua"
  # cleanup trap will restore original chicc.lua and remove gen files
  exit 1
fi
