-- state-back: nvim-tree integration (open, expand and select a file).

local M = {}

-- find_file() moves the tree window's cursor, which steals window focus.
-- Return to the editor unless the tree should keep focus.
local function restore_focus(keep_focus)
  if
    not keep_focus
    and vim.bo[vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())].filetype == 'NvimTree'
  then
    vim.cmd('noautocmd wincmd p')
  end
end

local function find(path_or_buf, keep_focus)
  local ok, api = pcall(require, 'nvim-tree.api')
  if not ok then
    return
  end
  pcall(function()
    api.tree.find_file({ buf = path_or_buf })
    restore_focus(keep_focus)
  end)
end

--- Open the tree (if needed) with {path}'s parent directories expanded and
--- the file selected. Synchronous, so the first paint is already final.
function M.open(path, keep_focus)
  local ok, api = pcall(require, 'nvim-tree.api')
  if not ok then
    return
  end
  pcall(function()
    if not api.tree.is_visible() then
      api.tree.toggle({ focus = keep_focus })
    end
  end)
  if path then
    find(path, keep_focus)
  end
end

--- Re-position the tree on {bufnr} after restore. Retried once after async
--- re-renders (git status etc.) settle so the selection sticks.
function M.position(bufnr, keep_focus)
  vim.schedule(function()
    local function once()
      find(bufnr, keep_focus)
    end
    once()
    vim.defer_fn(once, 400)
  end)
end

return M
