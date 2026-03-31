-- chi_build.lua
-- Implements 'chi build FILE [-o OUTPUT]'
--
-- Compiles a Chi source file to a standalone executable by:
-- 1. Compiling Chi -> Lua using compileFile (from chicc)
-- 2. Converting to LuaJIT bytecode via string.dump
-- 3. Copying the chi binary and appending a payload trailer
--
-- Payload format: [bytecode][size: 8 bytes LE uint64]["CHIEXE"]
-- The native chi launcher detects this trailer and runs the payload.

local function build_main(args)
    -- Parse arguments: chi build FILE [-o OUTPUT]
    local input_file = nil
    local output_file = nil

    local i = 2  -- skip "build"
    while i <= #args do
        if args[i] == "-o" and i + 1 <= #args then
            output_file = args[i + 1]
            i = i + 2
        else
            input_file = args[i]
            i = i + 1
        end
    end

    if not input_file then
        io.stderr:write("Usage: chi build FILE [-o OUTPUT]\n")
        return 1
    end

    if not output_file then
        -- Default: strip .chi extension
        output_file = input_file:gsub("%.chi$", "")
        if output_file == input_file then
            output_file = input_file .. ".out"
        end
    end

    -- Step 1: Compile Chi source to Lua (using chicc's compileFile)
    local tmp_lua = os.tmpname()
    local rc = compileFile(input_file, tmp_lua)
    if rc ~= 0 then
        os.remove(tmp_lua)
        return rc
    end

    -- Step 2: Read compiled Lua
    local f = io.open(tmp_lua, "r")
    if not f then
        io.stderr:write("Error: failed to read compiled output\n")
        os.remove(tmp_lua)
        return 1
    end
    local lua_code = f:read("*a")
    f:close()
    os.remove(tmp_lua)

    -- Step 3: Convert to bytecode
    local chunk, err = load(lua_code, "@" .. input_file)
    if not chunk then
        io.stderr:write("Error: failed to load compiled Lua: "
                        .. tostring(err) .. "\n")
        return 1
    end
    local bytecode = string.dump(chunk)

    -- Step 4: Copy chi executable
    local exe_path = _CHI_EXE_PATH
    if not exe_path then
        io.stderr:write("Error: _CHI_EXE_PATH not set "
                        .. "(not running from native chi)\n")
        return 1
    end

    local src = io.open(exe_path, "rb")
    if not src then
        io.stderr:write("Error: cannot read " .. exe_path .. "\n")
        return 1
    end
    local exe_data = src:read("*a")
    src:close()

    -- Step 5: Write output: [exe][bytecode][size: 8 LE]["CHIEXE"]
    local dst = io.open(output_file, "wb")
    if not dst then
        io.stderr:write("Error: cannot write " .. output_file .. "\n")
        return 1
    end

    dst:write(exe_data)
    dst:write(bytecode)

    -- Write bytecode size as 8-byte little-endian uint64
    local size = #bytecode
    for _ = 1, 8 do
        dst:write(string.char(size % 256))
        size = math.floor(size / 256)
    end

    dst:write("CHIEXE")
    dst:close()

    -- Make executable
    os.execute("chmod +x '" .. output_file .. "'")

    io.write("Built: " .. output_file
             .. " (" .. #bytecode .. " bytes payload)\n")
    return 0
end

-- Export as global (called from C launcher)
chi_build = build_main
