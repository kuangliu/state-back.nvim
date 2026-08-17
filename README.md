# state-back.nvim

Lightweight session restore for Neovim, designed as a faster replacement for
[neovim-session-manager](https://github.com/Shatur/neovim-session-manager).

## Features

- Restores the buffer list from the last session, **preserving buffer order**.
- Restores the **cursor position (and window view)** for every buffer, applied
  when each buffer is shown.
- Reopens the last active buffer; **nvim-tree is open by default** and its
  cursor is placed on the current buffer's file.
- **Fast**: state is a small JSON file per working directory. Restore only runs
  `:badd` (no file contents are read) for the buffer list and `:edit` for the
  active buffer, with nvim-tree opened in the same pass — so the first paint
  already shows everything (no closed→open pop-in).

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  dir = vim.fn.stdpath('config') .. '/state-back.nvim',
  event = 'UIEnter',
  config = function()
    require('state-back').setup()
  end,
}
```

## Options

```lua
require('state-back').setup({
  -- Directory holding one JSON state file per working directory.
  dir = vim.fn.stdpath('state') .. '/state-back',
  autosave = true,                      -- save on exit (VimLeavePre)
  autoload = true,                      -- restore on startup (UIEnter)
  restore_only_without_args = true,     -- skip restore when nvim got file args
  open_tree = true,                     -- open nvim-tree at startup by default
  tree_focus = false,                   -- find current file, keep editor focus
})
```

## Commands

- `:StateBackSave` — save state for the current directory
- `:StateBackRestore` — restore state for the current directory
- `:StateBackClear` — delete saved state for the current directory

User autocmd events:

- `StateBackSavePost` — state was written to disk
- `StateBackBuffersRestored` — buffer list and views restored
- `StateBackRestorePost` — full restore finished (nvim-tree opened)

## How it differs from session-manager

session-manager writes and executes `:mksession`-style Vimscript, which on load
re-opens every buffer with `:edit` (reading each file), sets up folds and
windows, and depends on plenary.nvim. `state-back` saves only what is needed:

- buffer paths in buffer-list order;
- the last active buffer;
- per-buffer cursor/view;
- the working directory.

On restore it registers buffers with `:badd` (no I/O per buffer), opens only the
active file, and opens nvim-tree during `UIEnter` so the initial layout already
shows the tree with the current file highlighted. Startup and exit cost scale
with buffer count instead of file reads.

Terminal, nvim-tree, quickfix and other non-file buffers are never saved.
State files whose buffers no longer exist are skipped on restore.
