-- run_chicc.lua — LuaJIT bootstrap for chicc.lua (no native chi needed).
-- Mirrors the native launcher (native/chi_main.c): loads the runtime and
-- stdlib, suppresses chicc.lua's auto-entry, sets up chi_compile, then
-- forwards CLI args to cliMain. Invoked via run_chicc.sh.
local CHICC_DIR = arg[0]:match("(.+)/[^/]+$") or "."
local rt = CHICC_DIR .. "/runtime/"

utf8 = dofile(rt .. "utf8.lua")
chistr = dofile(rt .. "chistr.lua")
dofile(rt .. "chi_runtime.lua")

local chi_home = os.getenv("CHI_HOME") or (os.getenv("HOME") .. "/.chi")
local sf = assert(io.open(chi_home .. "/lib/std.chim", "r"),
    "std.chim not found — set CHI_HOME to a Chi installation")
local stdlib = sf:read("a"); sf:close()
assert(load(stdlib, "@std.chim"))()

-- Note: cliMain will call its package-local loadStdlib() and reload
-- std.chim from CHI_HOME — harmless, it happens before any compilation.

-- Load chicc.lua with its entry point suppressed (it fires on `arg`)
local saved_arg = arg
arg = nil
local f = assert(io.open(CHICC_DIR .. "/chicc.lua", "r"))
local code = f:read("a"); f:close()
assert(load(code, "@chicc.lua"))()
arg = saved_arg

-- The entry point was suppressed, so the convenience globals it would
-- define (cliMain, compileToLua, ...) are absent; reach into the packages.
local _CLI = package.loaded['chicc/cli']
local _COMPILER = package.loaded['chicc/compiler']

-- chi_compile(source) -> luaCode on success, nil + formatted messages on failure
chi_compile = function(source)
  local ns = _COMPILER.newLuaCompilationEnv()
  local result = _COMPILER.compileToLua(source, ns)
  if result and result.luaCode then return result.luaCode end
  local parts = {}
  for i, m in ipairs(result and result.messages or {}) do
    parts[i] = _COMPILER.formatMessage(m)
  end
  if #parts == 0 then return nil, "unknown compilation error" end
  return nil, table.concat(parts, "; ")
end

local args = {}
for i = 1, #arg do args[i] = arg[i] end
local exitCode = _CLI.cliMain(args)
if exitCode and exitCode ~= 0 then os.exit(exitCode) end
