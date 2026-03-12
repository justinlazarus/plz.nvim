# plz.nvim

PR review workflow for Neovim. Dashboard, difftastic diffs, and code review without leaving your editor.

- **Dashboard** — gh-dash style PR triage
- **Difftastic diffs** — syntax-aware, token-level structural diffs
- **Review** — file list, inline threads, commit-by-commit view
- **ADO integration** — Azure DevOps work item context in the PR view

Zero plugin dependencies.

## Requirements

- Neovim >= 0.10
- [`gh`](https://cli.github.com/) CLI (authenticated)
- [`difft`](https://difftastic.wilfred.me.uk/) (difftastic)

Optional:
- `wt` (worktrunk) for worktree-based file exploration with LSP
- `ADO_PAT` env var for Azure DevOps work items

## Install

**vim.pack**
```lua
require('vim.pack').add('justinlazarus/plz.nvim')
```

**lazy.nvim**
```lua
{ 'justinlazarus/plz.nvim' }
```

**Manual**
```bash
git clone https://github.com/justinlazarus/plz.nvim.git \
  ~/.local/share/nvim/site/pack/plugins/start/plz.nvim
```

## Setup

```lua
-- All defaults, setup() is optional
require('plz').setup({
  diff = {
    layout = "side-by-side",
    context = 3,
  },
  worktree = {
    auto_create = true,
    auto_cleanup = true,
  },
  -- Azure DevOps (optional)
  ado = {
    org = "your-org",
    project = "Your Project",
    pat_env = "ADO_PAT",
  },
})
```

## Usage

| Command | Description |
|---------|-------------|
| `:Plz` | Open the dashboard |
| `:PlzDiff <old> <new>` | Diff two local files with difftastic |

### Dashboard

| Key | Action |
|-----|--------|
| `j/k` | Navigate |
| `<CR>` | Open PR for review |
| `o` | Open in browser |
| `r` | Refresh |
| `1`-`3` | Switch tab |
| `<Tab>` / `<S-Tab>` | Next / prev tab |
| `/` | Edit filter |
| `q` | Close |
| `?` | Help |

### Review

| Key | Action |
|-----|--------|
| `j/k` | Navigate files |
| `<CR>` | Open diff / select commit |
| `<Tab>` | Cycle summary (Info / Commits / Description) |
| `]f` / `[f` | Next / prev file |
| `]h` / `[h` | Next / prev hunk |
| `o` | Open in browser |
| `<BS>` / `q` | Back |
| `?` | Help |

## License

MIT
