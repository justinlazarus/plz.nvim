# plz.nvim — Design Document

## What Is This

A single Neovim plugin that replaces gh-dash + octo.nvim with a unified PR workflow:

1. **Dashboard** — gh-dash style PR triage without leaving Neovim
2. **Difftastic is the diff engine** — structural, syntax-aware diffs instead of line-level noise
3. **Worktrees are transparent** — the code under review is real files with full LSP, not synthetic buffers
4. **Review history is spatial** — comments live on the code they reference, across revisions

One plugin. Dashboard → diff → review → submit. No context switching.

## What We Like About Existing Tools

### gh-dash
- Left pane mirrors GitHub's PR filter UI — tabs with saved filter groups
- Right icons: comments, approval status, +/-, timestamps
- Right pane shows full PR details
- Slick, fast, well-designed for triage

### octo.nvim
- PR detail as a navigable buffer — good concept
- Review workflow exists but is clunky
- Too many commands, config-heavy, requires personal mapping work
- Uses Neovim's built-in vimdiff — the fatal flaw

### difftastic
- Syntax-aware structural diffs — understands code, not just text
- Shows what semantically changed, ignores formatting noise
- So far superior to line-level diffs that it should be the foundation of any review tool

## The Problem

No tool combines these well:

1. **No structural diffs in review** — octo.nvim and GitHub both use line diffs
2. **No real files during review** — octo shows synthetic buffers, no LSP/go-to-def
3. **Review history is temporal, not spatial** — threads, comments, and their relationship to code changes are scattered and hard to follow across revisions

## GitHub PR Review Data Model

Understanding this is essential. The hierarchy:

```
PullRequest
│
├── comments[]                     # General discussion (bottom of PR page)
│                                  # NOT code-level — we mostly ignore these
│
├── reviews[]                      # PullRequestReview — a submission act
│   ├── state                      # APPROVED | CHANGES_REQUESTED | COMMENTED | PENDING
│   ├── body                       # Review summary text
│   ├── commit                     # SHA this review was made against
│   └── comments[]                 # Code-level comments in this review
│
├── reviewThreads[]                # The primary data structure for plz.nvim
│   ├── path                       # File path
│   ├── line / originalLine        # Current position / position when created
│   ├── startLine / originalStart  # For multi-line selections
│   ├── diffSide                   # LEFT or RIGHT side of diff
│   ├── isResolved                 # Thread marked as resolved
│   ├── isOutdated                 # Code changed since thread was created
│   └── comments[]                 # The conversation chain
│       ├── body                   # Comment text
│       ├── author                 # Who wrote it
│       ├── originalCommit         # SHA when this comment was written
│       ├── originalLine           # Line number when written
│       ├── line                   # Where GitHub thinks it is now (nullable)
│       ├── outdated               # Code changed under this comment
│       └── diffHunk              # Surrounding diff context for re-anchoring
│
└── commits[]                      # All commits in the PR
    └── commit.oid                 # SHA — used for cross-revision tracking
```

**Key insight:** `reviewThreads` is the entry point, not `reviews`. A review is a submission event; a thread is a conversation anchored to code. plz.nvim is thread-centric.

**For cross-revision review:**
- `originalCommit` — exact SHA the comment was written against
- `originalLine` — where the comment was at creation time
- `line` — where GitHub maps it now (null if deleted)
- `outdated` — flag: code changed under this comment
- `diffHunk` — context for re-anchoring when line numbers shift

## Architecture

### Plugin Structure

```
plz.nvim/
  lua/
    plz/
      init.lua                 # setup(), config, health check
      state.lua                # session state (active PR, worktree, review)
      gh.lua                   # async gh CLI wrapper
      dashboard/
        init.lua               # dashboard buffer lifecycle
        fetch.lua              # gh queries per section, JSON parsing
        render.lua             # table layout, extmarks for icons/colors
      diff/
        init.lua               # diff view orchestration
        difftastic.lua         # run difft --display=json, parse output
        render.lua             # map difft JSON → extmarks/highlights
        layout.lua             # side-by-side window management
      worktree/
        init.lua               # wt switch pr:N --no-cd, cleanup
      review/
        init.lua               # review session lifecycle
        threads.lua            # fetch, render, create threads inline
        submit.lua             # approve / request changes / comment
      revision/
        init.lua               # cross-revision diff orchestration
        tracker.lua            # persist last-reviewed SHA per PR
  plugin/
    plz.lua                    # user commands
```

### Data Flow

```
:Plz
  │
  └─ dashboard/ ── gh pr list --json ... ── PR table with icons/status
                    │
                    └─ <CR> on PR row
                        │
                        ├─ gh.lua ──── gh api graphql ──── threads, reviews
                        │
                        ├─ worktree/ ── wt switch pr:42 --no-cd ── real files
                        │
                        ├─ diff/ ───── difft --display=json base head
                        │              parse JSON → extmarks on buffers
                        │
                        └─ review/ ─── threads as virtual text
                                        add comment → pending review
                                        submit → graphql mutation
```

## Navigation Model — File List + Diff, Not Timeline

The central design choice: **the file list is the entry point, the diff is the primary view**. Not a timeline of review events. Not a list of threads. Files and their diffs.

This is what makes the review manageable across multiple rounds:

```
:Plz review 42

┌─────────────────┬──────────────────────────────────────────────┐
│ Changed files    │  utils.ts (difftastic side-by-side)         │
│                  │                                              │
│ > utils.ts  +5-2 │  function calculateTotal(items) {           │
│   api.ts    +12  │    return items.reduce((sum, i) =>          │
│   index.ts  -3   │-     sum + i.cost,                          │
│                  │+     sum + i.price,                          │
│                  │      0)                                      │
│                  │  }                                           │
│                  │  ┊ @you: rename cost→price everywhere (1 reply)│
│                  │                                              │
│ [2 orphaned]     │                                              │
└─────────────────┴──────────────────────────────────────────────┘
```

**Why this works across multiple review rounds:**

Each file is a self-contained view. When you open a file's diff, you see:
- The structural diff (difftastic)
- All threads anchored to lines in that file
- Thread state: unresolved, resolved, outdated

You never see "all 47 threads across all files across all revisions" at once. The file scopes the noise.

**Threads follow the file, not the timeline.** A thread on `utils.ts:42` shows up when you're looking at `utils.ts`, regardless of which review round created it or how many commits have passed since.

### Orphaned Threads

When code with threads gets deleted or a file is renamed/moved, those threads lose their anchor. Instead of silently dropping them:

- The file list shows an `[N orphaned]` indicator at the bottom
- Selecting it opens a buffer listing orphaned threads with their original `diffHunk` context — the surrounding code at the time the comment was made
- Each orphaned thread shows: file path, original code context, the conversation, and why it's orphaned (file deleted, lines removed, file renamed)

This handles the edge case without polluting the normal file+diff workflow. 99% of reviews never see it. When it appears, the information is there.

### Cross-Revision Mode Within the File Model

When you toggle cross-revision mode (`d`), the file list updates to show only files changed since your last review. The diff switches from base→head to last-reviewed-sha→head. Threads overlay the same way — they're still anchored to file+line. The file list stays the entry point.

```
Changed since your last review:
  helpers.ts   +8 -2     ← author modified code you commented on
  utils.ts     -22       ← file deleted (had 2 threads → orphaned)

[2 orphaned threads]
```

Same navigation, same mental model. Just a different diff range.

## Detailed Design

### 1. Diff View — Difftastic at the Center

The diff view is two side-by-side buffers (base and head) with treesitter highlighting and difftastic extmarks on top.

**How difftastic JSON maps to Neovim:**

`difft --display=json` outputs chunks with sub-line change positions:
```json
{
  "lhs": { "line_number": 6, "changes": [{"start": 9, "end": 12}] },
  "rhs": { "line_number": 6, "changes": [{"start": 9, "end": 17}] }
}
```

Each change becomes an extmark: `nvim_buf_set_extmark(buf, ns, line, start, {end_col=end, hl_group="PlzDiffAdd"})`. This highlights the specific tokens that changed, not the whole line. A line like `return a + b` → `return a - b` only highlights `+` vs `-`.

**Layout:**
- Two vertical splits, scroll-synced via `scrollbind` + `cursorbind`
- Left = base (file at merge-base), right = head (file in worktree)
- Both are real file buffers from the worktree — treesitter, LSP, go-to-def all work on the right side
- File list panel (narrow left split) for navigating between changed files
- `]h` / `[h` to jump between difftastic chunks

**Fallback:** If difft is not installed, fall back to `git diff` with standard highlighting. Show a one-time notification.

### 2. Worktree — Lazy, Transparent, Silent

Worktree creation is **lazy**. Most reviews don't need one.

**Default (no worktree):**
- Diffs render from `git show base_sha:path` and `git show head_sha:path` into scratch buffers
- Fast to open, no disk overhead
- Sufficient for reviewing diffs, leaving comments, approving

**On-demand (worktree created):**
- User presses `o` to open a file for real exploration (LSP, go-to-def, test running)
- First `o` triggers `wt switch pr:N --no-cd --no-verify` — creates worktree silently
- Subsequent file opens reuse the same worktree
- `state.lua` tracks the worktree path

**Cleanup:**
- Close review → if a worktree was created, `wt remove` cleans it up
- No worktree was created → nothing to clean
- Safety net: `VimLeavePre` autocmd cleans up any worktrees plz created

**Multiple concurrent reviews:** Each PR gets its own worktree. `state.lua` tracks all active ones.

**Edge case:** If the user is already on the PR branch, skip worktree creation — use the current working directory directly.

### 3. Review — Threads Are First Class

**Viewing threads:**

Threads render as virtual text below the relevant line in the diff buffer:

```
  function calculateTotal(items) {
    return items.reduce((sum, item) => sum + item.price, 0)
  }
  ┊ @reviewer: should this handle empty arrays? (2 replies, resolved ✓)
```

- Unresolved threads: full visibility, `PlzThread` highlight
- Resolved threads: collapsed to one line, dimmed `PlzThreadResolved`
- Outdated threads: marked with `PlzThreadOutdated`, show what the code looked like

### Context Panel — Threads and LSP Without Disruption

The diff view never changes context. A persistent bottom pane (like quickfix) shows contextual information for the current cursor line. It updates on `CursorMoved` — no keypress needed, no view popping.

Lines with threads get a gutter marker (`◆`) so you know something is there before landing on it. When the cursor lands on a marked line, the context panel shows the full thread conversation. When the cursor moves away, the panel clears.

```
┌─────────────┬────────────────────────────────────────────┐
│ Changed files│  utils.ts (difftastic side-by-side)        │
│              │                                            │
│ > utils.ts   │  function calculateTotal(items) {          │
│   api.ts     │    return items.reduce((sum, i) =>         │
│              │      sum + i.price,  ◆                     │
│              │      0)                                    │
│              │  }                                         │
├──────────────┴────────────────────────────────────────────┤
│ ◆ utils.ts:5                                              │
│   @reviewer (2d ago): should this handle empty arrays?    │
│   @author (1d ago): good catch, added a guard clause      │
│   @reviewer (1d ago): looks good                          │
│                                                 ✓ resolved│
└───────────────────────────────────────────────────────────┘
```

LSP hover is already handled by `K` — no need to duplicate it. The context panel is purely for review threads.

This same panel works during worktree exploration — navigating real source files with `gd`/`grr` still shows threads when landing on commented lines.

### Thread Time Travel

A thread is tied to a commit that may no longer reflect the current code. Three snapshots matter for any thread:

1. **Original** — the code when the comment was written (`originalCommit`)
2. **Resolution** — the code when the thread was resolved (last comment's `commit` before `isResolved` flipped)
3. **Current** — the code at HEAD

The context panel lets you cycle through these views with `h`/`l` or tab when a thread is active:

```
├──────────────────────────────────────────────────────────┤
│ ◆ utils.ts:5  [thread]  [original]  [resolution]        │
│                                                          │
│   @reviewer (2d ago): should this handle empty arrays?   │
│   @author (1d ago): good catch, added a guard clause     │
│                                               ✓ resolved │
└──────────────────────────────────────────────────────────┘
```

**[thread]** — the default: shows the conversation.

**[original]** — shows the code at the time the comment was written, rendered via `git show originalCommit:path`. Gives you the exact context the reviewer was looking at.

**[resolution]** — shows a difftastic diff between `originalCommit` and the resolution commit, scoped to the lines around the comment. Multiple commits may have landed between the comment and its resolution, so the full file diff could be noisy. Scoping to the relevant lines (using the comment's line range + a few lines of context) keeps the view focused on what actually changed to address the comment.

```
├─ original → resolved (difftastic) ── lines 3-8 ─────────┤
│   function calculateTotal(items) {                       │
│-    return items.reduce((sum, i) => sum + i.price, 0)    │
│+    if (!items.length) return 0                          │
│+    return items.reduce((sum, i) => sum + i.price, 0)    │
└──────────────────────────────────────────────────────────┘
```

This is especially valuable for threads where the resolution happened several commits ago and the code has since changed further. You can see exactly what was done to resolve the comment, independent of later changes.

**Data source:** All from git — `git show sha:path` for snapshots, `difft` for the structural diff between them. No extra API calls needed.

**Creating comments:**

1. Cursor on a line (or visual select for multi-line)
2. `c` — opens a small floating window
3. Write comment, `<C-s>` to save as pending
4. Pending comments show as virtual text with `PlzCommentPending` highlight
5. Comments accumulate in the review session until submitted

**Submitting review:**

`<leader>vs` opens a float with:
- List of pending comments
- Text area for review summary
- Three actions: Approve / Request Changes / Comment

Submits via `addPullRequestReview` + `submitPullRequestReview` GraphQL mutations.

### 4. Cross-Revision Review — The Differentiator

**The workflow:**

```
Day 1: Review PR #42 at commit abc123, leave comments
Day 2: Author pushes changes (HEAD now def456)
Day 3: :Plz review 42 —— shows "changes since your last review"
        Your previous comments overlay on the new diff
        Instantly see which comments were addressed
```

**Implementation:**

`revision/tracker.lua` persists `~/.local/share/nvim/plz/reviewed.json`:
```json
{
  "owner/repo#42": { "sha": "abc123", "reviewed_at": "2026-03-09T..." }
}
```

Updated when you submit a review or run `:Plz mark-reviewed`.

**Cross-revision diff mode:**

1. Read last-reviewed SHA from tracker
2. Get current HEAD from `gh pr view`
3. For each changed file between those SHAs, run difftastic
4. Overlay previous thread comments using `originalCommit` + `originalLine`
5. Color-code threads:
   - Thread on unchanged code → "still relevant, not addressed" (blue)
   - Thread on modified code → "code changed — verify" (yellow)
   - Thread marked resolved → dimmed
   - New code with no threads → normal diff highlighting

This gives instant visual feedback on which comments the author addressed.

### 5. Navigation & Keybindings

Opinionated. Minimal. No config needed to make it work.

**Opening:**
| Key | Action |
|-----|--------|
| `:Plz review N` | Open PR #N for review |
| `:Plz review` | Pick from pending review requests |

**Diff view:**
| Key | Action |
|-----|--------|
| `]q` / `[q` | Next/prev file |
| `]h` / `[h` | Next/prev hunk |
| `]t` / `[t` | Next/prev thread |
| `c` | Add comment (normal or visual mode) |
| `<CR>` | Expand thread under cursor |
| `R` | Resolve/unresolve thread |
| `i` | Toggle inline/side-by-side layout |
| `d` | Toggle cross-revision diff mode |
| `o` | Open file in worktree (full buffer, LSP) |
| `q` | Close review, cleanup worktree |

**Review submission:**
| Key | Action |
|-----|--------|
| `<leader>vs` | Submit review (opens submit float) |
| `<leader>va` | Quick approve |

### 6. Dashboard — gh-dash in Neovim

The dashboard is opened with `:Plz` and replaces gh-dash entirely. Same visual language, same data, but inside Neovim — so `<CR>` on a PR goes straight into the diff/review view with no context switch.

**Layout:**

```
┌─ plz ──────────────────────────────────────────────────────────────────┐
│  [My PRs]  [Pending]  [Involved]                            ← tabs    │
├────────────────────────────────────────────────────────────────────────┤
│  #  Title                          Repo         Author   CI  +/-  Age │
│ ──────────────────────────────────────────────────────────────────────│
│  1888  Fix NaN in audit log        az-global..  daiha    ●   +20  2h │
│> 1887  Update floating inventory   az-global..  tdong    ◐  +436  4h │
│  1885  Fix license data handling   az-global..  ntrung   ●   +69  8h │
├────────────────────────────────────────────────────────────────────────┤
│  PR #1887 · Update floating inventory                                  │
│  Author: tdong · Branch: feature/1469182-buyin · REVIEW_REQUIRED       │
│                                                                        │
│  CI: 19/20 passed, 1 in progress                                       │
│  Files: +436 -7 across 12 files                                        │
│  Threads: 3 unresolved, 1 resolved                                     │
└────────────────────────────────────────────────────────────────────────┘
```

Top half: PR table with the same columns and icons as gh-dash.
Bottom half: preview pane showing details of the selected PR.

**Columns** (matching gh-dash):
| Column | Source | Display |
|--------|--------|---------|
| Number | `number` | `#1887` |
| Title | `title` | Truncated to fit |
| Repo | `repository` | Short name |
| Author | `author.login` | With nerd font icon |
| Review | `reviewDecision` | Icon: `✓` approved, `±` changes requested, `○` pending |
| CI | `statusCheckRollup` | Aggregate: `●` all pass, `◐` running, `✗` failed |
| Lines | `additions`, `deletions` | `+436 -7` colored green/red |
| Age | `updatedAt` | Relative: `2h`, `3d`, `1w` |
| Comments | `comments` | Count with icon |

**Tabs** are the section filters — same concept as gh-dash sections. Navigate with `1`, `2`, `3` or `Tab`/`S-Tab`.

**PR table keybindings:**
| Key | Action |
|-----|--------|
| `j/k` | Navigate rows |
| `<CR>` | Open PR diff/review view |
| `o` | Open PR in browser |
| `r` | Refresh |
| `1-9` | Switch tab/section |
| `/` | Filter PRs |
| `q` | Close dashboard |

**Data source:** `gh pr list --json` for single-repo, `gh search prs --json` for cross-repo sections. Queries run async via `vim.system()`. Results cache for 60s (configurable), manual refresh with `r`.

### 7. Actions

Every action you can take on a PR, organized by context.

**Dashboard actions (PR list):**
| Action | Notes |
|--------|-------|
| Open PR for review | `<CR>` → diff view |
| Open in browser | `o` |
| Quick approve | Without opening diff |
| Request/assign review | Pick person or team |
| Merge PR | |
| Close PR | |
| Enable auto-merge | Squash/merge/rebase strategy |
| Disable auto-merge | |

**Diff view actions:**
| Action | Notes |
|--------|-------|
| Add comment | Single line or visual selection |
| Add suggestion | Code block the author can apply with one click |
| Reply to thread | From context panel |
| Resolve thread | |
| Unresolve thread | |
| Edit pending comment | Not yet submitted |
| Delete pending comment | Not yet submitted |
| React to comment | Emoji |

**Review submission:**
| Action | Notes |
|--------|-------|
| Submit as Approve | |
| Submit as Request Changes | |
| Submit as Comment | Neutral — no approval/rejection |
| Add review summary | Body text for the review |
| Cancel review | Discard all pending comments |

**PR-level actions (accessible from diff view):**
| Action | Notes |
|--------|-------|
| Assign/unassign reviewer | |
| Request review | Specific person or team |
| Add/remove labels | |
| Mark as draft / ready | |
| Dismiss a review | If you have permission |
| Enable/disable auto-merge | With strategy selection |

**Interaction pattern:**

The context panel doubles as an action hint bar. Its bottom line always shows the available actions for the current cursor context, updating on `CursorMoved`. No extra bar, no screen sandwich with tmux/statusline.

On a thread:
```
│   r reply  R resolve  ? all actions                       │
```

On plain code:
```
│   c comment  v select+comment  ? all actions              │
```

On the dashboard:
```
│   ⏎ review  o browser  a assign  ? all actions            │
```

A handful of single-key actions cover 90% of usage. `?` opens a fuzzy command palette with every available action, filtered to the current context. Discoverable without memorization, scales without clutter.

### 8. ADO Work Item Integration

Most PRs reference an Azure DevOps work item (e.g., `AB#1470925` in the title). The PR detail view (dashboard preview pane or diff view) extracts the work item ID and shows a read-only summary:

```
├─ ADO Work Item AB#1470925 ───────────────────────────────┤
│ Title: [Buy-In Redesign] Audit Log NaN fix               │
│ State: Active → Resolved                                  │
│ Assigned: daiha                                           │
│ Iteration: Sprint 42                                      │
│ Description: System shows "NaN" in the screen for...      │
└──────────────────────────────────────────────────────────┘
```

**Data source:** ADO REST API (`dev.azure.com/{org}/{project}/_apis/wit/workitems/{id}`). View-only — no mutations. PAT stored as an environment variable (e.g., `$ADO_PAT` in `~/.zshrc.local`), referenced in config via `pat_env`.

This gives the reviewer context on *why* the change is being made without leaving Neovim or opening ADO in a browser.

### 9. What We Don't Build

- **PR creation/editing** — out of scope. Use `gh pr create`.
- **Issue management** — out of scope.
- **Merge controls** — out of scope. Use the web UI or `gh pr merge`.

## Configuration

Everything in one place. One Lua table. Replaces gh-dash's yaml config, octo.nvim's config, and all the glue between them.

```lua
require('plz').setup({
  -- Dashboard sections (replaces gh-dash config.yml)
  sections = {
    { title = "My Pull Requests", filters = "is:open author:@me" },
    { title = "Pending",          filters = "is:open base:main draft:false sort:created-asc" },
    { title = "Involved",         filters = "is:open involves:@me -author:@me" },
  },

  -- Dashboard behavior
  dashboard = {
    preview = true,          -- show PR detail pane
    preview_width = 0.45,    -- as ratio of window
    refetch_interval = 60,   -- seconds (0 to disable auto-refresh)
    limit = 20,              -- PRs per section
  },

  -- Diff display
  diff = {
    layout = "side-by-side",  -- or "inline"
    context = 3,              -- context lines around changes
  },

  -- Worktree management
  worktree = {
    auto_create = true,       -- create worktree on review open
    auto_cleanup = true,      -- remove worktree on review close
  },

  -- Azure DevOps work item integration (optional)
  ado = {
    org = "nxt-costco-com",
    project = "Global Depot",
    pat_env = "ADO_PAT",      -- env var name containing the PAT
  },
})
```

That's it. No keybinding config — the plugin is opinionated.

## Error Handling & Health Check

Degrade gracefully. Never block, never nag repeatedly.

**Hard requirements** — plugin won't function without these:
| Dependency | Detection | Behavior |
|-----------|-----------|----------|
| Neovim >= 0.10 | `setup()` | Error in `:checkhealth`, commands don't register |
| `gh` CLI (authenticated) | First API call | Single `vim.notify` ERROR, commands show install hint |
| `difft` | First diff render | Single `vim.notify` ERROR, commands show install hint |

**Soft requirements** — features degrade, no error:
| Dependency | Without it |
|-----------|------------|
| `wt` | No worktree exploration (`o` key not shown in action hints) |
| ADO PAT | No work item panel (section simply absent) |

**Runtime failures:**
| Failure | Behavior |
|---------|----------|
| Network down (cold start) | Empty dashboard with "offline" indicator |
| Network down (mid-review) | Keep showing current data, `vim.notify` WARN on refresh |
| API rate limit | `vim.notify` WARN, use cached data, back off |
| Auth expired | `vim.notify` WARN with `gh auth login` hint |
| PR not found / no permission | Inline message in dashboard, not a modal |
| ADO API fails | Work item section shows "unavailable", rest of review unaffected |

## Highlights

All highlight groups link to existing Neovim semantic groups — inherits the user's colorscheme automatically. Users can override any `Plz*` group.

| Group | Links to | Used for |
|-------|----------|----------|
| `PlzDiffAdd` | `DiffAdd` | Changed tokens (head side) |
| `PlzDiffRemove` | `DiffDelete` | Changed tokens (base side) |
| `PlzThread` | `Comment` | Thread virtual text |
| `PlzThreadResolved` | `NonText` | Resolved thread (dimmed) |
| `PlzThreadOutdated` | `DiagnosticWarn` | Outdated thread |
| `PlzCommentPending` | `DiagnosticInfo` | Pending comment (not yet submitted) |
| `PlzGutterMark` | `DiagnosticHint` | `◆` gutter marker on lines with threads |
| `PlzCIPass` | `DiagnosticOk` | CI passed |
| `PlzCIFail` | `DiagnosticError` | CI failed |
| `PlzCIPending` | `DiagnosticWarn` | CI running |
| `PlzSectionTitle` | `Title` | Dashboard section headers |

**Note:** Difftastic highlights are sub-line (token-level), not whole-line like traditional diffs. If a theme's `DiffAdd`/`DiffDelete` looks odd on inline tokens, users can override with something better suited (e.g., linking to `DiagnosticInfo`/`DiagnosticError` instead).

## Performance

Diffs are rendered one file at a time (not all upfront), difftastic is fast (Rust), and API calls are async. No anticipated bottlenecks for typical PRs. Large PRs (200+ files) paginate the file list.

## Testing

Busted with `nlua` adapter — the current Neovim plugin standard.

- Tests in `spec/` as `*_spec.lua` files
- Runs via `nvim -l` in headless child processes (clean isolation)
- CI via GitHub Actions with `nvim-busted-action`

**What to test:**
- `gh.lua` — JSON parsing, error handling
- `difftastic.lua` — JSON → extmark position mapping
- `review/threads.lua` — thread anchoring, orphan detection
- `revision/tracker.lua` — SHA persistence, cross-revision logic

**What not to test early:** Buffer rendering, window layout, UI interactions. Hard to automate, low ROI until the plugin stabilizes.

**`:checkhealth plz`** verifies:
- `gh` installed and authenticated (`gh auth status`)
- `difft` installed and supports `--display=json`
- `wt` installed (optional)
- Neovim version
- ADO PAT configured (optional)

## Dependencies

**Required:**
- Neovim >= 0.10 (for `vim.system`)
- `gh` CLI (authenticated)
- `difft` (difftastic)

**Optional:**
- `wt` (worktrunk) — without it, diffs use `git show` into temp buffers (no LSP)

**Neovim plugins:** None. Zero plugin dependencies.

## Implementation Phases

1. **Phase 1: Dashboard** — `gh.lua` async wrapper + dashboard buffer with PR table, sections/tabs, preview pane. Immediately useful as a gh-dash replacement.

2. **Phase 2: Difftastic rendering** — Parse `difft --display=json`, render extmarks in side-by-side buffers. Test with local files. This is the diff foundation.

3. **Phase 3: PR diff + worktree** — Wire up `gh` for file list and base/head SHAs. `wt switch pr:N --no-cd` for real files. Dashboard `<CR>` opens difftastic diff view with LSP on head-side buffer.

4. **Phase 4: Review threads** — Fetch and render threads inline on diff buffers. Add/submit comments via GraphQL.

5. **Phase 5: Cross-revision review** — Persist reviewed SHAs, compute revision diffs, overlay previous comments with status indicators.

6. **Phase 6: Polish** — Thread exploration from worktree buffers, orphaned thread handling, auto-refresh, edge cases.

## Implementation Status

### Phase 2: Difftastic rendering — DONE
- `difft --display=json` parsing and normalization (`difftastic.lua`)
- Side-by-side aligned layout with filler lines (`align.lua`, `layout.lua`)
- Token-level green/red highlights matching difftastic output (`render.lua`)
- Colored line numbers via custom `statuscolumn` (real numbers or `·` for fillers)
- Scroll sync (`scrollbind` + `cursorbind`) and `]h`/`[h` hunk navigation
- `:PlzDiff <old> <new>` command for local file comparison
- Design choice: no treesitter/syntax highlighting in diff buffers — plain text with diff highlights only, matching difftastic's terminal style

### Phase 1: Dashboard — IN PROGRESS
- `gh.lua` async wrapper around `gh` CLI with JSON parsing
- Dashboard opens via `:Plz` in a new tab with top/bottom split (PR list + preview)
- Three sections: Review Requested, My PRs, All Open (tab switching with `1`/`2`/`3` or `Tab`)
- PR table columns matching gh-dash compact mode: state icon, #number, title, author, review, CI, +/-, age
- Nerd font icons matching gh-dash: `` open, `` draft, `󰄬` approved, `` CI pass, `󰅙` CI fail, `` pending
- Color scheme matching gh-dash: `#42A0FA` open, `#A371F7` merged, `#3DF294` success, `#E06C75` error, `#E5C07B` warning
- Column alignment via shared `build_row` with display-width-aware padding
- Preview pane: branch/author, status, CI summary, ADO work item placeholder, reviewer/thread placeholders
- ADO work item extraction from PR title or body (`AB#NNNN` pattern)
- `ado.lua` module for ADO REST API integration (type, state, assignee, tags — single line in preview)
- Keybindings: `j/k` nav, `<CR>` open, `o` browser, `r` refresh, `q` close, `?` help
- Preview updates on `CursorMoved`
