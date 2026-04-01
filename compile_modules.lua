-- compile_modules.lua
-- Compiles all chicc modules by concatenating them into a single source
-- and compiling the combined source as one unit.
-- This is necessary because the native chi binary's chi_compile() cannot
-- compile individual modules with cross-module imports (packages need to
-- be loaded in the runtime for imports to resolve, but the _G metatable
-- and chi_compile interactions make this unreliable).

function __compile_modules(sourceFiles, cacheDir)
  -- Read all source files
  local parts = {}
  for i, filePath in ipairs(sourceFiles) do
    local f = io.open(filePath, 'r')
    if not f then error('compileModules: cannot open file: ' .. filePath) end
    local content = f:read('*a')
    f:close()
    parts[#parts+1] = content
    io.write('[read] ' .. filePath .. '\n')
  end

  -- Concatenate all source files
  local combined = table.concat(parts, '\n')
  io.write('[compiling] all modules (' .. #combined .. ' bytes, ' .. #sourceFiles .. ' files)\n')
  io.flush()

  -- Compile the combined source as a single unit
  local luaCode = chi_compile(combined)
  if not luaCode then
    -- Try to get error info
    local info = compileToLua and compileToLua(combined) or nil
    if info and info.messages then
      for i, msg in ipairs(info.messages) do
        if i <= 20 then
          io.write('[error] ' .. (msg.text or tostring(msg)) .. '\n')
        end
      end
      if #info.messages > 20 then
        io.write('[error] ... and ' .. (#info.messages - 20) .. ' more errors\n')
      end
    end
    error('compileModules: compilation failed')
  end

  io.write('[compiled] ' .. #luaCode .. ' bytes of Lua code\n')

  -- Wrap in module function pattern (single module since it's concatenated)
  return 'function m1() ' .. luaCode .. ' end;m1();'
end
