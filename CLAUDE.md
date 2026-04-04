This is a Chi language compiler written in Chi itself.
Chi compiles to Lua internally and uses the native executable with LuaJIT as host runtime environment.

To compile the compiler you need to run `compile.chi` which builds `chicc.lua`.
The `.cache` folder contains partial compilation results.

To build the native compiler run `make clean && make` in `native` directory.
The native version is just a luajit wrapper with embedded `chicc.lua`.

Rules:

- always use the chi-language skill when working with \*.chi files

Two ways to run compiler:

- `run_chicc.sh` sets up the environment and uses LuaJIT directly to run chicc.lua which is the compiled compiler
- use the native `chi` 
