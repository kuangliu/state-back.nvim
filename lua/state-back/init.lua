-- state-back.nvim
--
-- Lightweight replacement for session-manager: restores the buffer list
-- (order preserved), the per-buffer cursor/view, and opens nvim-tree on the
-- current buffer's file. State is a tiny JSON file per working directory, so
-- both save (VimLeavePre) and restore (UIEnter) are much cheaper than
-- :mksession-based plugins.

local M = {}

local config = {
  -- Directory holding one JSON state file per working directory.
  dir = vim.fn.stdpath('state') .. '/state-back',
  -- Save state on exit (VimLeavePre).
  autosave = true,
  -- Restore state on startup (UIEnter).
  autoload = true,
  -- Only auto-restore when nvim was started without file arguments.
  restore_only_without_args = true,
  -- Open nvim-tree after a restore.
  open_tree = true,
  -- Move the nvim-tree cursor onto the current file, keeping editor focus
  -- (same behavior as the previous session-manager SessionLoadPost handler).
  tree_focus = false,
}

local augroup = vim.api.nvim_create_augroup('state_back', { clear = true })

-- Live tracking for the current session: views/path and the last active file.
local live = {
  views = {}, -- path -> { cursor = {lnum, col}, view = winsaveview() }
  applied = {}, -- paths whose stored view was already applied
  current = nil, -- absolute path of the last active file buffer
}

local function is_restorable(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local bo = vim.bo[bufnr]
  if not bo.buflisted or bo.buftype ~= '' then
    return false
  end
  if bo.filetype == 'NvimTree' or bo.filetype == 'qf' then
    return false
  end
  return vim.api.nvim_buf_get_name(bufnr) ~= ''
end

local function record_view(path)
  local view = vim.fn.winsaveview()
  local entry = live.views[path] or {}
  entry.view = view
  entry.cursor = { view.lnum, view.col }
  live.views[path] = entry
end

local function record_cursor(path)
  local entry = live.views[path] or {}
  entry.cursor = vim.api.nvim_win_get_cursor(0)
  live.views[path] = entry
end

local function state_file(cwd)
  return config.dir .. '/' .. vim.fn.sha256(cwd):sub(1, 16) .. '.json'
end

local function read_state()
  local cwd = vim.uv.cwd()
  if not cwd then
    return nil
  end
  local file = state_file(cwd)
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
  if not current or not vim.tbl_contains(buffers, current) then
    current = vim.api.nvim_buf_get_name(current_buf)
  end
  if not current or not vim.tbl_contains(buffers, current) then
    current = buffers[1]
  end

  local data = {
    cwd = cwd,
    current = current or '',
    buffers = buffers,
    views = live.views,
  }

  vim.fn.mkdir(config.dir, 'p')
  local file = state_file(cwd)
  local tmp = file .. '.tmp'
  local ok, err = pcall(vim.fn.writefile, { vim.json.encode(data) }, tmp)
  if not ok then
    return false, err
  end
  -- Atomic rename so a crash can never leave a half-written state file.
  local renamed = pcall(vim.rename, tmp, file)
  if not renamed then
    pcall(vim.fn.rename, tmp, file)
  end
  vim.api.nvim_exec_autocmds('User', { pattern = 'StateBackSavePost' })
  return true
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

-- Open nvim-tree positioned on {path} (a file path, or nil for a plain open).
-- Runs synchronously during UIEnter so the first paint already shows any
-- parent directories expanded with the file selected - no visible expansion.
local function open_tree_at(path)
  local ok, api = pcall(require, 'nvim-tree.api')
  if not ok then
    return
  end
  pcall(function()
    if not api.tree.is_visible() then
      api.tree.toggle({ focus = config.tree_focus })
    end
    if path then
      api.tree.find_file({ buf = path })
      -- find_file() moves the tree window's cursor, which steals window
      -- focus; return to the editor unless the tree should stay focused.
      if
        not config.tree_focus
        and vim.bo[vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())].filetype == 'NvimTree'
      then
        vim.cmd('noautocmd wincmd p')
      end
    end
  end)
end

-- Re-position nvim-tree on {target_buf} after the buffer restore. The buffer
-- is passed explicitly because find_file() otherwise uses the current buffer,
-- which may be the tree itself once the tree window has focus. Retried once
-- after async re-renders (git status etc.) so the selection sticks.
local function position_tree(target_buf)
  local ok, api = pcall(require, 'nvim-tree.api')
  if not ok then
    return
  end
  vim.schedule(function()
    local function position()
      pcall(function()
        api.tree.find_file({ buf = target_buf })
        -- find_file() moves the tree window's cursor, which steals window
        -- focus; return to the editor unless the tree should stay focused.
        if
          not config.tree_focus
          and vim.bo[vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())].filetype == 'NvimTree'
        then
          vim.cmd('noautocmd wincmd p')
        end
      end)
    end
    -- Position immediately, then again once async re-renders (git status,
    -- expanded dirs) have settled so the selection sticks on the file.
    position()
    vim.defer_fn(position, 400)
  end)
end

--- Restore the last saved buffer list, order, views and nvim-tree position.
function M.restore()
  if not config.autoload then
    return false
  end
  local state = read_state()
  if not state or type(state.buffers) ~= 'table' or #state.buffers == 0 then
    return false
  end
  if state.cwd ~= vim.uv.cwd() then
    return false
  end
  if config.restore_only_without_args and vim.fn.argc() > 0 then
    return false
  end
  if vim.g.started_with_stdin then
    return false
  end

  -- Only restore buffers whose files still exist.
  local keep = {}
  for _, path in ipairs(state.buffers) do
    if type(path) == 'string' and vim.uv.fs_stat(path) then
      table.insert(keep, path)
    end
  end
  if #keep == 0 then
    return false
  end

  -- Seed per-buffer views from disk (live tracking only has this session's).
  if type(state.views) == 'table' then
    for path, entry in pairs(state.views) do
      if type(path) == 'string' and type(entry) == 'table' and not live.views[path] then
        live.views[path] = entry
      end
    end
  end

  -- Batch :badd appends buffers in order without reading file contents and
  -- marks them listed (unlike bufadd()).
  local add = {}
  for _, path in ipairs(keep) do
    add[#add + 1] = 'badd ' .. vim.fn.fnameescape(path)
  end
  vim.cmd(table.concat(add, '\n'))

  -- Open the last active buffer and restore its view.
  local current = state.current
  if type(current) ~= 'string' or not vim.tbl_contains(keep, current) then
    current = keep[1]
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(current))
  -- :badd + :edit (and nvim-tree opening during UIEnter) can skip filetype
  -- detection, which would leave the restored file without treesitter syntax
  -- highlighting. Match and set it explicitly when that happens (setting
  -- 'filetype' fires FileType, which starts treesitter highlighting).
  if vim.bo.filetype == '' then
    local buf = vim.api.nvim_get_current_buf()
    local ok, ft = pcall(vim.filetype.match, { filename = vim.api.nvim_buf_get_name(buf) })
    if ok and ft and ft ~= '' then
      pcall(vim.api.nvim_set_option_value, 'filetype', ft, { buf = buf })
    end
  end
  local restored_buf = vim.api.nvim_get_current_buf()
  apply_entry(current, true)
  vim.api.nvim_exec_autocmds('User', { pattern = 'StateBackBuffersRestored' })

  -- Wipe the empty [No Name] startup buffer now that it is no longer current
  -- (deleting the *current* buffer would jump focus to the tree window), so
  -- it does not sit at the front of the buffer list.
  local current_buf = vim.api.nvim_get_current_buf()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      bufnr ~= current_buf
      and vim.fn.bufname(bufnr) == ''
      and not vim.bo[bufnr].modified
    then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end

  -- Restore views for the remaining buffers the first time they are shown.
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = augroup,
    callback = function(args)
      if is_restorable(args.buf) then
        if vim.bo[args.buf].filetype == '' then
          local ok, ft = pcall(vim.filetype.match, { filename = vim.api.nvim_buf_get_name(args.buf) })
          if ok and ft and ft ~= '' then
            pcall(vim.api.nvim_set_option_value, 'filetype', ft, { buf = args.buf })
          end
        end
        apply_entry(vim.api.nvim_buf_get_name(args.buf), false)
      end
    end,
  })

  -- Point nvim-tree at the restored file in the same pass (no intermediate
  -- redraws), then signal completion.
  if config.open_tree then
    position_tree(restored_buf)
  end
  vim.api.nvim_exec_autocmds('User', { pattern = 'StateBackRestorePost' })
  return true
end

--- Delete the saved state for the current working directory.
function M.clear()
  local cwd = vim.uv.cwd()
  if not cwd then
    return false
  end
  local file = state_file(cwd)
  if vim.uv.fs_stat(file) then
    pcall(vim.fn.delete, file)
  end
  return true
end

--- Set up state tracking, autoload and commands.
---@param opts? table state-back options
function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})

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
    callback = function()
      M.save()
    end,
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
  -- during UIEnter skips filetype detection, which the restore() fallback
  -- fixes explicitly so treesitter highlighting still starts.
  if config.autoload then
    local target
    if vim.fn.argc() == 0 and not vim.g.started_with_stdin then
      local state = read_state()
      if state and type(state.current) == 'string' then
        target = state.current
      end
    end
    if not target then
      local cur = vim.fn.expand('%:p')
      target = cur ~= '' and cur or nil
    end
    if config.open_tree then
      open_tree_at(target)
    end
    M.restore()
  end
end

return M
