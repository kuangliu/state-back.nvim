-- state-back: persistence for per-working-directory state files.

local M = {}

-- Directory holding one JSON state file per working directory.
M.dir = vim.fn.stdpath('state') .. '/state-back'

-- Pure-Lua directory hash. vim.fn.sha256 costs ~3 ms on its first call in a
-- process (JIT/allocator warmup), and this runs inside the plugin's load span,
-- so keep state file naming cheap and deterministic instead. Same 16-hex shape
-- as the sha256 prefix it replaces.
local function hash_dir(cwd)
  local h = 5381
  for i = 1, #cwd do
    h = (h * 33) % 4294967295 + cwd:byte(i)
  end
  return string.format('%016x', h % 4294967296)
end

local function file_for(cwd)
  return M.dir .. '/' .. hash_dir(cwd) .. '.json'
end

--- Read the saved state for {cwd}; nil when missing or corrupt.
function M.read(cwd)
  local file = file_for(cwd)
  if vim.uv.fs_stat(file) == nil then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, file)
  if not ok or not lines or #lines == 0 then
    return nil
  end
  local ok2, state = pcall(vim.json.decode, table.concat(lines, '\n'))
  if not ok2 or type(state) ~= 'table' then
    return nil
  end
  return state
end

--- Atomically write {data} for {cwd}; a crash never leaves a partial file.
function M.write(cwd, data)
  vim.fn.mkdir(M.dir, 'p')
  local file = file_for(cwd)
  local tmp = file .. '.tmp'
  local ok, err = pcall(vim.fn.writefile, { vim.json.encode(data) }, tmp)
  if not ok then
    return false, err
  end
  local renamed = pcall(vim.rename, tmp, file)
  if not renamed then
    pcall(vim.fn.rename, tmp, file)
  end
  return true
end

--- Delete the saved state for {cwd}.
function M.delete(cwd)
  local file = file_for(cwd)
  if vim.uv.fs_stat(file) then
    pcall(vim.fn.delete, file)
    return true
  end
  return false
end

return M
