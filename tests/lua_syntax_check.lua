-- Usage: fengari tests/lua_syntax_check.lua <file.lua> [...]
for index = 1, #arg do
    local chunk, err = loadfile(arg[index])
    assert(chunk, err)
end

print(string.format("lua syntax: %d files ok", #arg))
