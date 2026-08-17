-- state-back.nvim
--
-- Lightweight session restore: keeps the buffer list (order preserved), the
-- per-buffer cursor/view, and opens nvim-tree on the current file. State is a
-- tiny JSON file per working directory, so save (VimLeavePre) and restore
-- (UIEnter) are much cheaper than :mksession-based plugins.

local M = {}

local persist = require('state-back.persist')
local tree = require('state-back.tree')

local config = {
  -- Directory holding one JSON state file per working directory.
  dir = persist.dir,
  -- Save state on exit (VimLeavePre).
  autosave = true,
  -- Restore state on startup (UIEnter).
  autoload = true,
  -- Only auto-restore when nvim was started without file arguments.
  restore_only_without_args = true,
  -- Open nvim-tree at startup and point it at the current file.
  open_tree = true,
  -- Keep the nvim-tree window focused (default: editor keeps focus).
  tree_focus = false,
}

local augroup = vim.api.nvim_create_augroup('state_back', { clear = true })

-- Live tracking for this session.
local live = {
  views = {}, -- path -> { cursor = {lnum, col}, view = winsaveview() }
  applied = {}, -- paths whose stored view was already applied
  current = nil, -- path of the last active file buffer
}

local function is_restorable(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr)
    and vim.bo[bufnr].buflisted
    and vim.bo[bufnr].buftype == ''
    and vim.api.nvim_buf_get_name(bufnr) ~= ''
end

local function record_view(path)
  local view = vim.fn.winsaveview()
  live.views[path] = { cursor = { view.lnum, view.col }, view = view }
end

local function record_cursor(path)
  local entry = live.views[path] or {}
  entry.cursor = vim.api.nvim_win_get_cursor(0)
  live.views[path] = entry
end

-- :badd + :edit (and nvim-tree opening during UIEnter) can skip filetype
-- detection, which would leave buffers without treesitter highlighting.
-- Match and set it explicitly; setting 'filetype' fires FileType.
local function ensure_filetype(bufnr)
  if vim.bo[bufnr].filetype ~= '' then
    return
  end
  local ok, ft = pcall(vim.filetype.match, { filename = vim.api.nvim_buf_get_name(bufnr) })
  if ok and ft and ft ~= '' then
    pcall(vim.api.nvim_set_option_value, 'filetype', ft, { buf = bufnr })
  end
end

local function apply_entry(path, force)
  local entry = live.views[path]
  if not entry or (not force and live.applied[path]) then
    return
  end
  live.applied[path] = true
  local view = entry.view
  if view and view.lnum then
    pcall(vim.fn.winrestview, view)
  elseif entry.cursor then
    local last = math.max(vim.fn.line('$'), 1)
    local row = math.min(entry.cursor[1] or 1, last)
    pcall(vim.api.nvim_win_set_cursor, 0, { row, entry.cursor[2] or 0 })
  end
end

-- Remove the empty [No Name] startup buffer (it is not current anymore, so
-- deleting it cannot jump focus to the tree window).
local function wipe_empty_buffers(current_buf)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      bufnr ~= current_buf
      and vim.fn.bufname(bufnr) == ''
      and not vim.bo[bufnr].modified
    then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

--- Save the current buffer list, order and views to disk.
function M.save()
  if not config.autosave then
    return false
  end
  local cwd = vim.uv.cwd()
  if not cwd then
    return false
  end

  -- Capture the final view of the buffer about to be left behind.
  local current_buf = vim.api.nvim_get_current_buf()
  if is_restorable(current_buf) then
    record_view(vim.api.nvim_buf_get_name(current_buf))
  end

  -- nvim_list_bufs() is ordered exactly like the buffer list (:ls).
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if is_restorable(bufnr) then
      table.insert(buffers, vim.api.nvim_buf_get_name(bufnr))
    end
  end

  local current = live.current
  if not vim.tbl_contains(buffers, current) then
    current = vim.api.nvim_buf_get_name(current_buf)
  end
  if not vim.tbl_contains(buffers, current) then
    current = buffers[1]
  end

  local ok, err = persist.write(cwd, {
    cwd = cwd,
    current = current or '',
    buffers = buffers,
    views = live.views,
  })
  if not ok then
    return false, err
  end
  vim.api.nvim_exec_autocmds('User', { pattern = 'StateBackSavePost' })
  return true
end

--- Restore the last saved buffer list, order, views and nvim-tree position.
function M.restore()
  if vim.fn.argc() > 0 or vim.g.started_with_stdin then
    return false
  end
  local cwd = vim.uv.cwd()
  local state = cwd and persist.read(cwd)
  if not state or type(state.buffers) ~= 'table' or #state.buffers == 0 then
    return false
  end
  if state.cwd ~= cwd then
    return false
  end

  -- Seed per-buffer views from disk (live tracking only has this session's).
  for path, entry in pairs(state.views or {}) do
    if type(path) == 'string' and type(entry) == 'table' and not live.views[path] then
      live.views[path] = entry
    end
  end

  -- Batch :badd appends buffers in saved order without reading file contents.
  local keep, add = {}, {}
  for _, path in ipairs(state.buffers) do
    if type(path) == 'string' and vim.uv.fs_stat(path) then
      table.insert(keep, path)
      table.insert(add, 'badd ' .. vim.fn.fnameescape(path))
    end
  end
  if #keep == 0 then
    return false
  end
  vim.cmd(table.concat(add, '\n'))

  -- Open the last active buffer and restore its view.
  local current = state.current
  if type(current) ~= 'string' or not vim.tbl_contains(keep, current) then
    current = keep[1]
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(current))
  ensure_filetype(vim.api.nvim_get_current_buf())
  apply_entry(current, true)
  vim.api.nvim_exec_autocmds('User', { pattern = 'StateBackBuffersRestored' })

  wipe_empty_buffers(vim.api.nvim_get_current_buf())

  -- Restore views (and filetypes) for the remaining buffers when shown.
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = augroup,
    callback = function(args)
      if is_restorable(args.buf) then
        ensure_filetype(args.buf)
        apply_entry(vim.api.nvim_buf_get_name(args.buf), false)
      end
    end,
  })

  if config.open_tree then
    tree.position(vim.api.nvim_get_current_buf(), config.tree_focus)
  end
  vim.api.nvim_exec_autocmds('User', { pattern = 'StateBackRestorePost' })
  return true
end

--- Delete the saved state for the current working directory.
function M.clear()
  local cwd = vim.uv.cwd()
  return cwd and persist.delete(cwd) or false
end

-- Path the tree should be positioned on at startup: the file that will be
-- restored, or the buffer nvim was started with.
local function startup_target()
  if vim.fn.argc() == 0 and not vim.g.started_with_stdin then
    local cwd = vim.uv.cwd()
    local state = cwd and persist.read(cwd)
    if state and type(state.current) == 'string' then
      return state.current
    end
  end
  local cur = vim.fn.expand('%:p')
  return cur ~= '' and cur or nil
end

--- Set up state tracking, autoload and commands.
---@param opts? table state-back options
function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})
  persist.dir = config.dir

  -- Track the last active file buffer.
  vim.api.nvim_create_autocmd('BufEnter', {
    group = augroup,
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      if is_restorable(buf) then
        live.current = vim.api.nvim_buf_get_name(buf)
      end
    end,
  })

  -- Track cursor position cheaply on every move.
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = augroup,
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      if is_restorable(buf) then
        record_cursor(vim.api.nvim_buf_get_name(buf))
      end
    end,
  })

  -- Capture the full window view when leaving a buffer.
  vim.api.nvim_create_autocmd('BufLeave', {
    group = augroup,
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      if is_restorable(buf) then
        record_view(vim.api.nvim_buf_get_name(buf))
      end
    end,
  })

  -- Save on exit.
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    callback = M.save,
  })

  -- Never auto-restore over piped stdin (e.g. `cat file | nvim -`).
  vim.api.nvim_create_autocmd('StdinReadPre', {
    group = augroup,
    callback = function()
      vim.g.started_with_stdin = true
    end,
  })

  vim.api.nvim_create_user_command('StateBackSave', M.save, { desc = 'state-back: save current buffer state' })
  vim.api.nvim_create_user_command('StateBackRestore', M.restore, { desc = 'state-back: restore last saved buffer state' })
  vim.api.nvim_create_user_command('StateBackClear', M.clear, { desc = 'state-back: delete saved state for current directory' })

  -- Everything runs during UIEnter, before the first paint: open the tree
  -- already expanded to the restored file, then restore the buffers, so the
  -- first frame shows the session directly (no [No Name] flash). Editing
  -- during UIEnter skips filetype detection; ensure_filetype() fixes that.
  if config.autoload then
    if config.open_tree then
      tree.open(startup_target(), config.tree_focus)
    end
    M.restore()
  end
end

return M
