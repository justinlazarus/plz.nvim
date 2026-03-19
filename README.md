# plz.nvim

PR review workflow for Neovim. Dashboard, structural diffs, and code review without leaving your editor.

- **Dashboard** — gh-dash style PR triage
- **Structural diffs** — Neovim's built-in diff mode, enhanced with token-level highlights when [treediff.nvim](https://github.com/justinlazarus/treediff.nvim) is installed
- **Review** — file list, inline threads, commit-by-commit view
- **ADO integration** — Azure DevOps work item context in the PR view

## Requirements

- Neovim >= 0.10
- [`gh`](https://cli.github.com/) CLI (authenticated)

Optional:
- [treediff.nvim](https://github.com/justinlazarus/treediff.nvim) for token-level structural diff highlighting
- `ADO_PAT` env var for Azure DevOps work items

## Install

**vim.pack**
```lua
vim.pack.add({
  'https://github.com/justinlazarus/plz.nvim',
  'https://github.com/justinlazarus/treediff.nvim',  -- optional, for structural diffs
})
```

**lazy.nvim**
```lua
{ 'justinlazarus/plz.nvim' }
{ 'justinlazarus/treediff.nvim' }  -- optional
```

**Manual**
```bash
git clone https://github.com/justinlazarus/plz.nvim.git \
  ~/.local/share/nvim/site/pack/plugins/start/plz.nvim
```

## Setup

```lua
-- All defaults, setup() is optional
require('plz').setup()

-- Optional: enable treediff for token-level diff highlights
require('treediff').setup()
```

## Usage

| Command | Description |
|---------|-------------|
| `:Plz` | Open the dashboard |
| `:PlzDiff <old> <new>` | Diff two local files side-by-side |

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

Three collections accessible via `1`/`2`/`3` or `<Tab>`/`<S-Tab>`:

**C1 — PR Detail**: Info, description, and commits. `<CR>` on a commit enters commit mode.

**C2 — Reviews**: Review threads with resolution status. `<CR>` jumps to the comment in the diff.

**C3 — Changes**: File list + side-by-side diff.

| Key | Action |
|-----|--------|
| `<CR>` | Open diff / select item |
| `]f` / `[f` | Next / prev file |
| `]h` / `[h` | Next / prev hunk |
| `]c` / `[c` | Next / prev comment (cross-file) |
| `c` | Toggle comment at cursor |
| `cc` | Add inline comment at cursor |
| `v` | Toggle file viewed |
| `A` | Approve PR |
| `X` | Request changes |
| `C` | Submit comment review |
| `gc` | Add PR comment |
| `o` | Open in browser |
| `q` | Close |
| `?` | Help |

## License

MIT
