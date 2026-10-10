-- chi_build.lua
-- Implements the build steps of 'chi build'; cli.chi parses the arguments
-- and compiles the source, then calls chi_build(input_file, lua_code, output_file).
--
-- Turns the compiled Lua code into a standalone executable by:
-- 1. Converting it to LuaJIT bytecode via string.dump
-- 2. Copying the chi binary and appending a payload trailer
--
-- Payload format: [bytecode][size: 8 bytes LE uint64]["CHIEXE"]
-- The native chi launcher detects this trailer and runs the payload.

local function build_main(input_file, lua_code, output_file)
    -- Step 1: Convert to bytecode
    local chunk, err = load(lua_code, "@" .. input_file)
    if not chunk then
        io.stderr:write("Error: failed to load compiled Lua: "
                        .. tostring(err) .. "\n")
        return 1
    end
    local bytecode = string.dump(chunk)

    -- Step 2: Copy chi executable
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

    -- Step 3: Write output: [exe][bytecode][size: 8 LE]["CHIEXE"]
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

-- Export as global (loaded by the C launcher, called from cli.chi)
chi_build = build_main
