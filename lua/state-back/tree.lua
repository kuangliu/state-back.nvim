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

local function find(path, keep_focus)
  local ok, api = pcall(require, 'nvim-tree.api')
  if not ok then
    return
  end
  pcall(function()
    api.tree.find_file({ buf = path or 0 })
    restore_focus(keep_focus)
  end)
end

--- Open the tree (if needed) already expanded to {path} and select the file.
-- api.tree.open({find_file=true}) does the open and select in one pass, which
-- is several ms faster than toggle()+find_file() on the cold first render.
-- The open stays synchronous so the first paint is already final.
---@param path? string absolute path of the file to select
---@param keep_focus? boolean keep the tree window focused
function M.open(path, keep_focus)
  local ok, api = pcall(require, 'nvim-tree.api')
  if not ok then
    return
  end
  if api.tree.is_visible() then
    if path then
      find(path, keep_focus)
    end
    return
  end
  -- First paint must already contain the tree. Do the cold first render with
  -- git status suppressed to stay inside the load budget; git is re-enabled
  -- right after the open, before any later renders pick it up.
  local ok2, conf = pcall(require, 'nvim-tree.config')
  local git_enable = ok2 and conf.g and conf.g.git and conf.g.git.enable
  if ok2 and conf.g and conf.g.git then
    conf.g.git.enable = false
  end
  -- find_file=true selects the current buffer in one pass.
  pcall(api.tree.open, { find_file = true })
  if ok2 and conf.g and conf.g.git then
    conf.g.git.enable = git_enable
  end

  -- open({find_file=true}) already selected the current buffer; only move the
  -- selection again when the requested path differs from what got selected.
  if path and path ~= vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()) then
    find(path, keep_focus)
  end
  -- api.tree.open() leaves focus in the tree window; move back unless the
  -- caller wants the tree focused.
  restore_focus(keep_focus)
end

return M
