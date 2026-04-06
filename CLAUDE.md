This is a Chi language compiler written in Chi itself. 
Chi compiles to Lua internally and uses the native executable with LuaJIT as host runtime environment.
Load chi-language skill.

To compile the compiler:
- `make` or `make chicc.lua` — builds `chicc.lua` (automatically cleans .cache)
- `make test` — run test suite
- `make native` — build native chi binary (requires CHI_HOME set)
- `make verify` — verify fixed-point compilation

The native version is a LuaJIT wrapper with embedded `chicc.lua`.

Rules:

- always use the chi-language skill when working with \*.chi files

To run the compiler after building:

- `./run_chicc.sh` — runs chicc.lua via LuaJIT
- `chi` — runs native binary (if installed with `make install`) 

Use `spec` program with markdown backend for specifications. Run `spec prime` in bash to learn using spec.
Specification is the 'WHAT' and 'WHY'. It also describes how the feature works. It does NOT describe how to build the feature.

After you finish change implementation run `make verify` to verify the self-hosted compiler fixed point before finishing.
(The .cache folder is automatically cleaned by the build target.)
