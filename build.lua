-- build.lua
-- Build script for chicc using the existing chicc.lua (self-hosted compiler).
-- Compiles each source file individually in dependency order, loading each
-- into the runtime so subsequent files can import from it.

local chi_home = os.getenv("CHI_HOME")
local lib_dir = chi_home .. "/lib/"

-- Load runtime
utf8 = (function()
  local f = assert(io.open(lib_dir .. "utf8.lua", "r"))
  local code = f:read("a"); f:close()
  return load(code)()
end)()

chistr = (function()
  local f = assert(io.open(lib_dir .. "chistr.lua", "r"))
  local code = f:read("a"); f:close()
  return load(code)()
end)()

dofile(lib_dir .. "chi_runtime.lua")

-- Load std library
local sf = assert(io.open(lib_dir .. "std.chim", "r"))
local stdlib_code = sf:read("a"); sf:close()
load(stdlib_code)()

-- Load the existing chicc.lua (self-hosted compiler)
-- Suppress the entry point by temporarily removing arg
local saved_arg = arg
arg = nil
local cf = assert(io.open("chicc.lua", "r"))
local chicc_code = cf:read("a"); cf:close()
load(chicc_code)()
arg = saved_arg

-- Load stdlib into chicc's compilation environment
chi_load_module(lib_dir .. "std.chim")

-- The loaded chicc.lua puts symbols across package.loaded['chicc/*'] tables.
-- The compiler's embedLua/luaExpr code references names from other modules as
-- bare globals (legacy from single-package build). Set up _G metatable to
-- dynamically search all chicc packages for missing names.
-- This must survive overrides from loaded modules (e.g., messages.chi sets _G metatable).
local function setupChiccGlobalLookup()
    setmetatable(_G, { __index = function(t, k)
        -- Search all chicc/* packages for the name
        for pkgName, pkgTable in pairs(package.loaded) do
            if type(pkgName) == 'string' and pkgName:match('^chicc/') and type(pkgTable) == 'table' then
                local v = rawget(pkgTable, k)
                if v ~= nil then return v end
            end
        end
        return nil
    end })
end
setupChiccGlobalLookup()

print("Building chicc self-hosting compiler...")

local sourceFiles = {
  "chicc/messages.chi", "chicc/source.chi", "chicc/token.chi",
  "chicc/types.chi", "chicc/util.chi", "chicc/ast.chi",
  "chicc/parse_ast.chi", "chicc/type_writer.chi", "chicc/emitter.chi",
  "chicc/lexer.chi", "chicc/parser.chi", "chicc/symbols.chi",
  "chicc/ast_converter.chi", "chicc/unification.chi",
  "chicc/inference_context.chi", "chicc/typer.chi",
  "chicc/checks.chi", "chicc/compiler.chi", "chicc/cli.chi"
}

-- Compile each file individually, load each into runtime for next file
local compiledLua = {}
local totalTime = 0

for i, filePath in ipairs(sourceFiles) do
  local f = io.open(filePath, 'r')
  if not f then error('Cannot open: ' .. filePath) end
  local source = f:read('a')
  f:close()

  local t0 = os.clock()

  -- Check cache
  local cacheDir = '.cache'
  local pkg = source:match('package%s+(%S+)')
  local cachePath = cacheDir .. '/' .. (pkg or 'unknown') .. '.lua'
  local cacheSubdir = cachePath:match('(.+)/[^/]+$')
  if cacheSubdir then os.execute('mkdir -p ' .. cacheSubdir) end

  local cacheValid = false
  local cfi = io.open(cachePath, 'r')
  if cfi then
    cfi:close()
    -- Check if source is newer than cache
    local stat = os.execute('test ' .. filePath .. ' -nt ' .. cachePath)
    cacheValid = (stat ~= 0 and stat ~= true)  -- test returns 0 if newer
  end

  local luaCode
  if cacheValid then
    local f2 = io.open(cachePath, 'r')
    luaCode = f2:read('a')
    f2:close()
    io.write(string.format('[cached] %s (%.1fs)\n', filePath, os.clock() - t0))
  else
    -- Compile using the self-hosted compiler
    local ns = newLuaCompilationEnv()
    local result = compileToLua(source, ns)
    if not result then
      error('compileToLua returned nil for ' .. filePath)
    end

    luaCode = result.luaCode
    local messages = result.messages or {}

    if not luaCode then
      io.write('FAILED: ' .. filePath .. '\n')
      for j, msg in ipairs(messages) do
        if j <= 10 then
          local cp = msg.codePoint or {}
          io.write(string.format('  [%s] %s (line %s)\n',
            msg.code or '?', msg.text or '?',
            cp.line or '?'))
        end
      end
      if #messages > 10 then
        io.write('  ... and ' .. (#messages - 10) .. ' more\n')
      end
      error('Compilation failed for ' .. filePath)
    end

    -- Cache the result
    local wf = io.open(cachePath, 'w')
    wf:write(luaCode)
    wf:close()

    io.write(string.format('[compiled] %s (%.1fs)\n', filePath, os.clock() - t0))
  end

  -- Load the compiled code into runtime so next files can import from it
  local loader = load(luaCode)
  if loader then loader() end
  -- Re-establish global lookup after module load (module may have overridden _G metatable)
  setupChiccGlobalLookup()

  compiledLua[#compiledLua+1] = luaCode
  totalTime = totalTime + (os.clock() - t0)
end

-- Link all compiled packages
io.write(string.format('Linking %d modules...\n', #compiledLua))
local results = {}
for i, code in ipairs(compiledLua) do
  results[#results+1] = 'function m' .. i .. '() '
  results[#results+1] = code
  results[#results+1] = ' end;m' .. i .. '();'
end

-- Add entry point
local entry = [[

-- chicc entry point
local _CLI = package.loaded['chicc/cli']
local _COMPILER = package.loaded['chicc/compiler']
cliMain = _CLI.cliMain
compileFile = _CLI.compileFile
runFile = _CLI.runFile
loadStdlib = _CLI.loadStdlib
compileToLua = _COMPILER.compileToLua
newLuaCompilationEnv = _COMPILER.newLuaCompilationEnv

if arg then
  local exitCode = cliMain(arg)
  if exitCode and exitCode ~= 0 then os.exit(exitCode) end
end
]]

results[#results+1] = entry
local finalCode = table.concat(results)

-- Write output
local of = io.open('chicc.lua', 'w')
of:write(finalCode)
of:close()

io.write(string.format('Built: chicc.lua (%d bytes, %.1fs total)\n', #finalCode, totalTime))
