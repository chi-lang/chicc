-- bootstrap.lua
-- Compiles chicc source files into chicc.lua using an existing chicc.lua compiler.
-- Embeds the compileModules logic directly, bypassing the stdlib.
-- Usage: CHICC_LUA=<path-to-working-chicc.lua> luajit bootstrap.lua

local SCRIPT_DIR = arg[0]:match("(.+)/[^/]+$") or "."
local CHICC = os.getenv("CHICC_LUA") or (SCRIPT_DIR .. "/chicc.lua")
local chi_home = os.getenv("CHI_HOME")
local lib_dir = chi_home .. "/lib/"
local rt_dir = SCRIPT_DIR .. "/runtime/"

-- Load runtime
utf8 = (function()
  local f = assert(io.open(rt_dir .. "utf8.lua", "r"))
  local code = f:read("a"); f:close()
  return load(code)()
end)()

chistr = (function()
  local f = assert(io.open(rt_dir .. "chistr.lua", "r"))
  local code = f:read("a"); f:close()
  return load(code)()
end)()

dofile(rt_dir .. "chi_runtime.lua")

-- Load stdlib
local f = assert(io.open(lib_dir .. "std.chim", "r"))
local stdlib = f:read("a"); f:close()
load(stdlib)()

-- Dynamic lookup across chicc packages
setmetatable(_G, { __index = function(t, k)
    for pkgName, pkgTable in pairs(package.loaded) do
        if type(pkgName) == 'string' and pkgName:match('^chicc/') and type(pkgTable) == 'table' then
            local v = rawget(pkgTable, k)
            if v ~= nil then return v end
        end
    end
    return nil
end })

-- Load chicc compiler (suppress entry point)
local saved_arg = arg
arg = nil

local f2 = assert(io.open(CHICC, "r"))
local chicc_code = f2:read("a"); f2:close()
load(chicc_code)()

-- Set up chi_compile
chi_compile = function(source)
  local ns = newLuaCompilationEnv()
  local ok, result = pcall(compileToLua, source, ns)
  if not ok then
    io.write('\n  EXCEPTION: ' .. tostring(result) .. '\n')
    return nil
  end
  if result and result.luaCode then return result.luaCode end
  if result then
    io.write('\n  COMPILE RESULT KEYS: ')
    for k, v in pairs(result) do io.write(k .. '=' .. type(v) .. ' ') end
    io.write('\n')
    if result.messages then
      for _, e in ipairs(result.messages) do
        if type(e) == 'table' then
          for ek, ev in pairs(e) do io.write('  MSG.' .. ek .. ': ' .. tostring(ev) .. '\n') end
          io.write('  ---\n')
        else
          io.write('  MSG: ' .. tostring(e) .. '\n')
        end
      end
    end
    if result.errors then
      for _, e in ipairs(result.errors) do
        if type(e) == 'table' then
          for ek, ev in pairs(e) do io.write('  ERR.' .. ek .. ': ' .. tostring(ev) .. '\n') end
        else
          io.write('  ERROR: ' .. tostring(e) .. '\n')
        end
      end
    end
  end
  return nil
end

arg = saved_arg

-- Embedded compileModules logic (from std/lang.chi embedLua)
function __compile_modules(sourceFiles, cacheDir)
  local pkgOfFile = {}
  local importsOfFile = {}
  for _, filePath in ipairs(sourceFiles) do
    local f = io.open(filePath, 'r')
    if not f then error('compileModules: cannot open file: ' .. filePath) end
    local content = f:read('*a'); f:close()
    local pkg = nil
    local imports = {}
    for line in content:gmatch('[^\n]+') do
      if not pkg then
        local p = line:match('^%s*package%s+(%S+)')
        if p then pkg = p end
      end
      local imp = line:match('^%s*import%s+(%S+)')
      if imp and not imp:match('^std/') then
        imports[#imports+1] = imp
      end
    end
    if not pkg then error('compileModules: no package declaration found in: ' .. filePath) end
    pkgOfFile[filePath] = pkg
    importsOfFile[filePath] = imports
  end

  local filesOfPkg = {}
  local allPkgs = {}
  local pkgSeen = {}
  for _, filePath in ipairs(sourceFiles) do
    local pkg = pkgOfFile[filePath]
    if not pkgSeen[pkg] then
      pkgSeen[pkg] = true
      allPkgs[#allPkgs+1] = pkg
      filesOfPkg[pkg] = {}
    end
    filesOfPkg[pkg][#filesOfPkg[pkg]+1] = filePath
  end

  -- Topological sort by dependencies
  local depsOf = {}
  for _, pkg in ipairs(allPkgs) do
    depsOf[pkg] = {}
    local seen = {}
    for _, filePath in ipairs(filesOfPkg[pkg]) do
      for _, imp in ipairs(importsOfFile[filePath]) do
        if pkgSeen[imp] and not seen[imp] then
          seen[imp] = true
          depsOf[pkg][#depsOf[pkg]+1] = imp
        end
      end
    end
  end

  local inDegree = {}
  local dependents = {}
  for _, pkg in ipairs(allPkgs) do
    inDegree[pkg] = 0
    dependents[pkg] = {}
  end
  for _, pkg in ipairs(allPkgs) do
    for _, dep in ipairs(depsOf[pkg]) do
      inDegree[pkg] = inDegree[pkg] + 1
      dependents[dep][#dependents[dep]+1] = pkg
    end
  end

  local queue = {}
  for _, pkg in ipairs(allPkgs) do
    if inDegree[pkg] == 0 then queue[#queue+1] = pkg end
  end

  local sorted = {}
  local qi = 1
  while qi <= #queue do
    local pkg = queue[qi]; qi = qi + 1
    sorted[#sorted+1] = pkg
    for _, dep in ipairs(dependents[pkg]) do
      inDegree[dep] = inDegree[dep] - 1
      if inDegree[dep] == 0 then queue[#queue+1] = dep end
    end
  end

  if #sorted ~= #allPkgs then
    local missing = {}
    for _, pkg in ipairs(allPkgs) do
      local found = false
      for _, s in ipairs(sorted) do
        if s == pkg then found = true; break end
      end
      if not found then missing[#missing+1] = pkg end
    end
    error('compileModules: dependency cycle detected involving: ' .. table.concat(missing, ', '))
  end

  -- Compile each package (don't load results — keep the intermediate compiler active)
  local compiledLua = {}
  os.execute('mkdir -p ' .. cacheDir)
  for _, pkg in ipairs(sorted) do
    io.write('  Compiling package: ' .. pkg .. ' ...')
    io.flush()
    local cachePath = cacheDir .. '/' .. pkg .. '.lua'
    local cacheSubdir = cachePath:match('(.+)/[^/]+$')
    if cacheSubdir then os.execute('mkdir -p ' .. cacheSubdir) end

    local cacheValid = false
    local cf = io.open(cachePath, 'r')
    if cf then
      cf:close()
      cacheValid = true
      for _, filePath in ipairs(filesOfPkg[pkg]) do
        if os.execute('test ' .. filePath .. ' -nt ' .. cachePath) == 0 then
          cacheValid = false; break
        end
      end
    end

    if cacheValid then
      local f = io.open(cachePath, 'r')
      local code = f:read('*a'); f:close()
      compiledLua[pkg] = code
      io.write(' (cached)\n')
    else
      local parts = {}
      local firstFile = true
      for _, filePath in ipairs(filesOfPkg[pkg]) do
        local f = io.open(filePath, 'r')
        local src = f:read('*a'); f:close()
        if not firstFile then
          src = src:gsub('^%s*package%s+%S+[^\n]*\n?', '', 1)
        end
        firstFile = false
        parts[#parts+1] = src
      end
      local combined = table.concat(parts, '\n')
      local luaCode = chi_compile(combined)
      if not luaCode then
        error('compileModules: compilation failed for package: ' .. pkg)
      end
      local f = io.open(cachePath, 'w')
      f:write(luaCode); f:close()
      compiledLua[pkg] = luaCode
      io.write(' OK\n')
    end
  end

  local results = {}
  for i, pkg in ipairs(sorted) do
    results[#results+1] = 'function m' .. i .. '() '
    results[#results+1] = compiledLua[pkg]
    results[#results+1] = ' end;m' .. i .. '();'
  end
  return table.concat(results)
end

-- Source files (same as compile.chi)
local sourceFiles = {
  "chicc/messages.chi", "chicc/source.chi", "chicc/token.chi",
  "chicc/types.chi", "chicc/util.chi", "chicc/ast.chi",
  "chicc/parse_ast.chi", "chicc/type_writer.chi", "chicc/emitter.chi",
  "chicc/lexer.chi", "chicc/parser.chi", "chicc/symbols.chi",
  "chicc/ast_converter.chi", "chicc/unification.chi",
  "chicc/inference_context.chi", "chicc/typer.chi",
  "chicc/checks.chi", "chicc/compiler.chi", "chicc/cli.chi"
}

print("Building chicc self-hosting compiler...")
local luaCode = __compile_modules(sourceFiles, ".cache")

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

local finalCode = luaCode .. entry
local out = io.open("chicc.lua", "w")
out:write(finalCode)
out:close()
print("Built: chicc.lua")
