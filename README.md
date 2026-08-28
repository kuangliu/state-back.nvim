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
  active buffer. nvim-tree opens **synchronously**, so the first painted frame
  already shows the tree and the current file. To keep this inside the load-time
  budget, nvim-tree needs the included `setup.eager_open` prebuild (see below):
  with it, cold-process restore lands at **~4.3ms**, versus ~18ms without.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'kuangliu/state-back.nvim',
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
  -- nvim-tree integration
  open_tree = true,                     -- open nvim-tree at startup (sync, first frame)
  tree_focus = false,                   -- find current file, keep editor focus
  -- First-frame syntax. ~7ms; off by default to keep load under the goal.
  sync_filetype = false,
})
```

Autoload never runs when nvim was started with file arguments or with piped
stdin (`cat file | nvim -`), so it always restores a clean interactive session.


### nvim-tree: required setup

state-back opens the tree synchronously inside `UIEnter`. nvim-tree's cold
first render (~10-15ms of module requires) would blow the load budget, so the
bundled nvim-tree build prebuilds the explorer during `setup()`:

```lua
-- nvim-tree/nvim-tree.lua
{
  'nvim-tree/nvim-tree.lua',
  lazy = false,           -- or event = 'UIEnter' + dependency ordering before state-back
  opts = { setup = { eager_open = true } },   -- default, kept for clarity
}
```

With this, the `tree.open()` inside state-back's restore is warm (~3.6ms), and
the whole cold-process restore measures **~4.3ms**. Re-enable `sync_filetype`
if you prefer first-frame syntax over that budget. (Requires the nvim-tree
lazy-branch patches in this repo; they land as part of state-back.)

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
shows the tree with the current file highlighted. nvim-tree's git status is
suppressed for that one first render (re-enabled right after), which is what
keeps the synchronous open cheap. Startup and exit cost scale with buffer count
instead of file reads.

Terminal, nvim-tree, quickfix and other non-file buffers are never saved.
State files whose buffers no longer exist are skipped on restore.
