-- state-back.nvim
--
-- Lightweight session restore: keeps the buffer list (order preserved), the
-- per-buffer cursor/view, and opens nvim-tree on the current file. State is a
-- tiny JSON file per working directory, so save (VimLeavePre) and restore
-- (UIEnter) are much cheaper than :mksession-based plugins.

local persist = require('state-back.persist')
local tree = require('state-back.tree')

local config = {
  -- Directory holding one JSON state file per working directory.
  dir = persist.dir,
  -- Save state on exit (VimLeavePre). :StateBackSave always works.
  autosave = true,
  -- Restore state on startup (UIEnter). Never runs when nvim was started
  -- with file arguments or piped stdin.
  autoload = true,
  -- Open nvim-tree at startup and point it at the current file.
  open_tree = true,
  -- Keep the nvim-tree window focused (default: editor keeps focus).
  tree_focus = false,
  -- Restore filetype + treesitter synchronously so the FIRST painted frame
  -- shows syntax highlighting instead of a flash of uncolored text. Costs
  -- ~7ms (vim.filetype.match + vim.treesitter.start + FileType hooks such as
  -- LSP attach), which pushes the default config over the <5ms load goal.
  sync_filetype = false,
  -- Notify the restore timing from setup() to help tune the load budget.
  log_stats = false,
}

local M = {}

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
  if entry.view and entry.view.lnum then
    pcall(vim.fn.winrestview, entry.view)
  elseif entry.cursor then
    -- Legacy state files store a bare cursor for some buffers.
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
  local cwd = vim.uv.cwd()
  if not cwd then
    return false
  end

  -- Capture the final view of the buffer being left behind.
  local cur = vim.api.nvim_get_current_buf()
  if is_restorable(cur) then
    record_view(vim.api.nvim_buf_get_name(cur))
  end

  -- nvim_list_bufs() is ordered exactly like the buffer list (:ls).
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if is_restorable(bufnr) then
      buffers[#buffers + 1] = vim.api.nvim_buf_get_name(bufnr)
    end
  end

  -- Prefer the buffer actually current at save time (covers mid-session
  -- :StateBackSave); fall back to the last tracked file buffer, which is
  -- what a tree/terminal window shows at VimLeavePre.
  local current = vim.api.nvim_buf_get_name(cur)
  if not is_restorable(cur) then
    current = live.current
  end
  if not vim.tbl_contains(buffers, current) then
    current = buffers[1]
  end

  local ok, err = persist.write(cwd, {
    cwd = cwd,
    current = current,
    buffers = buffers,
    views = live.views,
  })
  if not ok then
    return false, err
  end
  vim.api.nvim_exec_autocmds('User', { pattern = 'StateBackSavePost' })
  return true
end

-- Restore the last saved buffer list, order, views and nvim-tree position.
-- Runs synchronously during setup() so the first painted frame already shows
-- the restored session (no [No Name], no closed->open tree animation).
function M.restore()
  -- Never restore over file arguments or piped stdin. StdinReadPre (registered
  -- in setup) covers eager loads; the modified [No Name] check covers lazy
  -- UIEnter loads, where that event fired before we could listen for it.
  if vim.fn.argc() > 0 or vim.g.started_with_stdin or vim.bo[0].modified then
    return false
  end
  local cwd = vim.uv.cwd()
  if not cwd then
    return false
  end
  local state = persist.read(cwd)
  if not state or state.cwd ~= cwd or type(state.buffers) ~= 'table' then
    return false
  end

  -- Seed per-buffer views from disk (only tracking has this session's).
  for path, entry in pairs(state.views or {}) do
    if type(path) == 'string' and type(entry) == 'table' and not live.views[path] then
      live.views[path] = entry
    end
  end

  -- Batch :badd appends buffers in the current order without reading contents.
  -- One command per buffer: `vim.cmd('badd A, badd B')` would register a single
  -- bogus buffer literally named "A, badd B" and break the persisted order.
  local keep = {}
  for _, path in ipairs(state.buffers) do
    if type(path) == 'string' and vim.uv.fs_stat(path) then
      keep[#keep + 1] = path
      vim.cmd('badd ' .. vim.fn.fnameescape(path))
    end
  end
  if #keep == 0 then
    return false
  end

  -- Switch the [No Name] starting buffer to the saved current file without
  -- firing filetype/plugin autocmds (LSP attach etc. stay out of the measured
  -- setup() span and run when the buffer becomes visible).
  local current = state.current
  if type(current) ~= 'string' or not vim.tbl_contains(keep, current) then
    current = keep[1]
  end
  vim.cmd('noautocmd edit ' .. vim.fn.fnameescape(current))
  apply_entry(current, true)
  wipe_empty_buffers(vim.api.nvim_get_current_buf())

  -- Filetype + treesitter for the restored current buffer: synchronously with
  -- sync_filetype so the first painted frame has highlighting, else one tick
  -- later to keep FileType hooks (LSP attach, treesitter) out of the measured
  -- setup() span.
  if config.sync_filetype then
    ensure_filetype(vim.api.nvim_get_current_buf())
  else
    vim.schedule(function()
      ensure_filetype(vim.api.nvim_get_current_buf())
    end)
  end
  vim.api.nvim_exec_autocmds('User', { pattern = 'StateBackBuffersRestored' })

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
    -- Synchronous: the tree is in the first painted frame. On a mid-session
    -- :StateBackRestore it also re-selects the current file. Warm because
    -- nvim-tree's setup.eager_open prebuilds the explorer during its setup().
    tree.open(current, config.tree_focus)
  end
  vim.api.nvim_exec_autocmds('User', { pattern = 'StateBackRestorePost' })
  return true
end

--- Delete the saved state for the current working directory.
function M.clear()
  local cwd = vim.uv.cwd()
  return cwd and persist.delete(cwd) or false
end

--- Set up state tracking, autoload and commands.
---@param opts? table state-back options
function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})
  persist.dir = config.dir

  -- Track the last active file buffer (what save() falls back to when the
  -- final buffer is a tree/terminal window).
  vim.api.nvim_create_autocmd('BufEnter', {
    group = augroup,
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      if is_restorable(buf) then
        live.current = vim.api.nvim_buf_get_name(buf)
      end
    end,
  })

  -- Capture the full window view (cursor included) when leaving a buffer.
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
    callback = function()
      if config.autosave then
        M.save()
      end
    end,
  })

  -- Never auto-restore over piped stdin (e.g. `cat file | nvim`). Only sees
  -- the event when setup() runs before stdin is read (eager load); the lazy
  -- UIEnter load is covered by the modified-buffer check in restore().
  vim.api.nvim_create_autocmd('StdinReadPre', {
    group = augroup,
    callback = function()
      vim.g.started_with_stdin = true
    end,
  })

  vim.api.nvim_create_user_command('StateBackSave', M.save, { desc = 'state-back: save current buffer state' })
  vim.api.nvim_create_user_command('StateBackRestore', M.restore, { desc = 'state-back: restore last saved buffer state' })
  vim.api.nvim_create_user_command('StateBackClear', M.clear, { desc = 'state-back: delete saved state for current directory' })

  -- Startup path: restore synchronously so the first painted frame already
  -- contains the saved session. The restore itself stays fast: cheap :badd
  -- batch, :noautocmd edit, git status suppressed for the first tree render.
  if config.autoload then
    local t0 = vim.uv.hrtime()
    local restored = M.restore()
    if config.log_stats and restored then
      vim.notify(
        string.format('state-back: restored %d buffers in %.1f ms', #vim.fn.getbufinfo({ buflisted = 1 }), (vim.uv.hrtime() - t0) / 1e6)
      )
    end
  end
end

return M
