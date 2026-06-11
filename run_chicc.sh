#!/bin/bash
# run_chicc.sh — run chicc.lua via LuaJIT (no native chi binary needed).
# All logic lives in run_chicc.lua; this wrapper only resolves the path.
#
# Environment variables:
#   CHI_HOME   Chi installation dir containing lib/std.chim (default: ~/.chi)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export CHI_HOME="${CHI_HOME:-$HOME/.chi}"
exec luajit "$SCRIPT_DIR/run_chicc.lua" "$@"
