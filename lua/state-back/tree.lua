-- state-back: nvim-tree integration (open, expand and select a file).

local M = {}

-- nvim-tree's first render computes git status for every node, which adds
-- 5-10 ms to the cold open. Keep the startup open (which must be synchronous
-- to be in the first painted frame) fast by suppressing git for that first
-- render. Git is re-enabled right after; note that because requiring
-- 'nvim-tree.api' triggers lazy to also run nvim-tree's own setup() (which may
-- turn git back on), we set git=false just before the open and restore after.
local function with_git_fast(fn)
  local ok, conf = pcall(require, 'nvim-tree.config')
  if not ok or not conf.g then
    return fn()
  end
  local git = conf.g.git
  if not git then
    git = {}
    conf.g.git = git
  end
  local prev = git.enable
  git.enable = false
  local ok2, ret = pcall(fn)
  git.enable = prev
  return ok2, ret
end

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
    if path and path ~= '' then
      api.tree.find_file({ buf = path })
    else
      local buf = vim.api.nvim_get_current_buf()
      if vim.api.nvim_buf_get_name(buf) ~= '' then
        api.tree.find_file({ buf = buf })
      end
    end
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
      restore_focus(keep_focus)
    end
    return
  end
  -- First paint must already contain the tree. Do the cold first render with
  -- git status suppressed to stay inside the <10 ms config() call.
  with_git_fast(function()
    -- find_file=true selects the current buffer in one pass.
    api.tree.open({ find_file = true })
  end)
  -- open({find_file=true}) already selected the current buffer; only move the
  -- selection again when the requested path differs from what got selected.
  if path and path ~= vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()) then
    find(path, keep_focus)
  end
  -- api.tree.open() leaves focus in the tree window; move back unless the
  -- caller wants the tree focused.
  restore_focus(keep_focus)
end

--- Re-position the tree on the current file (used by :StateBackRestore).
-- No-op when the tree is not open, so it is safe to call right after startup
-- without pulling nvim-tree into the measured load. Retried once after async
-- re-renders settle so the selection sticks.
function M.position(keep_focus)
  vim.schedule(function()
    local ok, api = pcall(require, 'nvim-tree.api')
    if not ok or not api.tree.is_visible() then
      return
    end
    local function once()
      find(nil, keep_focus)
    end
    once()
    vim.defer_fn(once, 400)
  end)
end

return M
