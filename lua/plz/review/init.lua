local gh = require("plz.gh")
local diff = require("plz.diff")
local icons = require("plz.dashboard.render").icons
local comments = require("plz.review.comments")
local files = require("plz.review.files")
local summary = require("plz.review.summary")

local M = {}

local ns = vim.api.nvim_create_namespace("plz_review")
local ns_active = vim.api.nvim_create_namespace("plz_review_active")
local SUMMARY_LINES = 5

local state = {
  pr = nil,
  files = {},
  base_sha = nil,
  head_sha = nil,
  -- Summary (fixed header)
  summary_buf = nil,
  summary_win = nil,
  summary_view = "info", -- "info" | "commits" | "description"
  commits = nil,         -- fetched commit list (nil = not loaded)
  commit_mode = false,   -- true when viewing a single commit
  commit_sha = nil,      -- full OID of selected commit
  commit_parent_sha = nil,
  pr_files = nil,        -- stashed full PR file list
  -- File list (scrollable)
  buf = nil,
  win = nil,
  -- Diff area
  diff_lhs_win = nil,
  diff_rhs_win = nil,
  diff_lhs_buf = nil,
  diff_rhs_buf = nil,
  diff_status_win = nil,
  diff_status_buf = nil,
  current_file_idx = nil,
  ado_item = nil,
  viewed = {},  -- path -> bool, synced with GitHub viewed state
  -- Review comments
  review_comments = {},  -- raw API response
  comments_by_file = {}, -- path -> { line -> { comments } } (RIGHT side)
  comments_by_file_left = {}, -- path -> { line -> { comments } } (LEFT side)
  expanded_comments = {}, -- "side:buf:line" -> bool, tracks which comment indicators are expanded
}

comments.setup(state)
files.setup(state)
summary.setup(state)

--- Open review for a PR from the dashboard.
function M.open(pr)
  local owner, repo = (pr.url or ""):match("github%.com/([^/]+)/([^/]+)")
  if not owner then
    vim.notify("plz: cannot determine repo from PR URL", vim.log.levels.ERROR)
    return
  end

  state.pr = pr
  state.base_sha = pr.baseRefOid
  state.head_sha = pr.headRefOid

  if not state.base_sha or not state.head_sha then
    vim.notify("plz: missing commit SHAs — try refreshing", vim.log.levels.ERROR)
    return
  end

  vim.notify("plz: loading PR #" .. pr.number .. "…", vim.log.levels.INFO)

  -- Fetch files and commits in parallel
  local pending_open = 2
  local function try_show()
    pending_open = pending_open - 1
    if pending_open > 0 then return end
    if #state.files == 0 then
      vim.notify("plz: no changed files", vim.log.levels.INFO)
      return
    end
    M._ensure_commits(function()
      files.show()
    end)
  end

  gh.run({
    "api", string.format("repos/%s/%s/pulls/%d/files?per_page=100", owner, repo, pr.number),
  }, function(file_list, err)
    if err then
      vim.notify("plz: " .. err, vim.log.levels.ERROR)
      return
    end
    state.files = file_list or {}
    try_show()
  end)

  M._fetch_commits(owner, repo, pr.number, function()
    try_show()
  end)

  -- Fetch viewed states in background (updates file list when ready)
  M._fetch_viewed_states(owner, repo, pr.number)

  -- Fetch review comments in background
  comments.fetch_review_comments(owner, repo, pr.number)
end

--- Ensure the PR commits are available locally.
function M._ensure_commits(callback)
  vim.system({ "git", "cat-file", "-t", state.head_sha }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code == 0 then
        callback()
        return
      end
      local ref = state.pr.headRefName or state.head_sha
      vim.notify("plz: fetching " .. ref .. "…", vim.log.levels.INFO)
      vim.system({ "git", "fetch", "origin", ref }, { text = true }, function(fo)
        vim.schedule(function()
          if fo.code ~= 0 then
            vim.system(
              { "git", "fetch", "origin", "pull/" .. state.pr.number .. "/head" },
              { text = true },
              function() vim.schedule(callback) end
            )
          else
            callback()
          end
        end)
      end)
    end)
  end)
end

--- Fetch PR commits via GraphQL (mirrors gh-dash's allCommits query).
--- @param owner string
--- @param repo string
--- @param pr_number number
--- @param callback function
function M._fetch_commits(owner, repo, pr_number, callback)
  local query = string.format([[
query {
  repository(owner: "%s", name: "%s") {
    pullRequest(number: %d) {
      commits(last: 100) {
        nodes {
          commit {
            oid
            abbreviatedOid
            messageHeadline
            committedDate
            additions
            deletions
            author {
              name
              user { login }
            }
            statusCheckRollup {
              state
              contexts(last: 100) {
                totalCount
                nodes {
                  ... on CheckRun { conclusion }
                  ... on StatusContext { state }
                }
              }
            }
          }
        }
      }
    }
  }
}]], owner, repo, pr_number)

  gh.run({ "api", "graphql", "-f", "query=" .. query }, function(data, err)
    if err then
      vim.notify("plz: commits: " .. err, vim.log.levels.WARN)
      state.commits = {}
      callback()
      return
    end
    local nodes = (((data or {}).data or {}).repository or {}).pullRequest
    nodes = nodes and nodes.commits and nodes.commits.nodes or {}
    local commits = {}
    for _, node in ipairs(nodes) do
      local c = node.commit
      if c then
        local succeeded = 0
        local total = 0
        local check_state = nil
        if c.statusCheckRollup and type(c.statusCheckRollup) == "table" then
          check_state = c.statusCheckRollup.state
          if type(check_state) ~= "string" then check_state = nil end
          local ctx = c.statusCheckRollup.contexts
          if type(ctx) == "table" then
            total = type(ctx.totalCount) == "number" and ctx.totalCount or 0
            for _, n in ipairs(type(ctx.nodes) == "table" and ctx.nodes or {}) do
              if type(n) == "table" and (n.conclusion == "SUCCESS" or n.state == "SUCCESS") then
                succeeded = succeeded + 1
              end
            end
          end
        end
        table.insert(commits, {
          oid = c.oid or "",
          short_oid = c.abbreviatedOid or "",
          message = c.messageHeadline or "",
          date = c.committedDate or "",
          author = (c.author and c.author.user and c.author.user.login)
            or (c.author and c.author.name) or "",
          additions = type(c.additions) == "number" and c.additions or 0,
          deletions = type(c.deletions) == "number" and c.deletions or 0,
          check_state = check_state,
          checks_passed = succeeded,
          checks_total = total,
        })
      end
    end
    -- Reverse so newest commit is first
    local reversed = {}
    for i = #commits, 1, -1 do reversed[#reversed + 1] = commits[i] end
    state.commits = reversed
    callback()
  end)
end

--- Fetch viewed state for all PR files via GraphQL.
--- @param owner string
--- @param repo string
--- @param pr_number number
function M._fetch_viewed_states(owner, repo, pr_number)
  local query = string.format([[
query {
  repository(owner: "%s", name: "%s") {
    pullRequest(number: %d) {
      files(first: 100) {
        nodes {
          path
          viewerViewedState
        }
      }
    }
  }
}]], owner, repo, pr_number)

  gh.run({ "api", "graphql", "-f", "query=" .. query }, function(data, err)
    if err then return end
    local viewed_data = (((data or {}).data or {}).repository or {}).pullRequest
    viewed_data = viewed_data and viewed_data.files and viewed_data.files.nodes or {}
    for _, f in ipairs(viewed_data) do
      if type(f) == "table" and f.path then
        state.viewed[f.path] = (f.viewerViewedState == "VIEWED")
      end
    end
    -- Re-render file list to show checkboxes
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      files.render()
      if state.current_file_idx then
        files.highlight_active()
        files.update_diff_status()
      end
    end
  end)
end

--- Toggle viewed state for a file via GitHub GraphQL mutation.
--- @param file_path string
function M._toggle_viewed(file_path)
  local pr = state.pr
  if not pr or not pr.id then return end

  local is_viewed = state.viewed[file_path]
  local mutation_name = is_viewed and "unmarkFileAsViewed" or "markFileAsViewed"

  local query = string.format([[
mutation {
  %s(input: { pullRequestId: "%s", path: "%s" }) {
    clientMutationId
  }
}]], mutation_name, pr.id, file_path:gsub('"', '\\"'))

  -- Optimistic update
  state.viewed[file_path] = not is_viewed
  files.render()
  if state.current_file_idx then
    files.highlight_active()
    files.update_diff_status()
  end

  gh.run({ "api", "graphql", "-f", "query=" .. query }, function(_data, err)
    if err then
      -- Revert on failure
      state.viewed[file_path] = is_viewed
      files.render()
      vim.notify("plz: failed to update viewed state", vim.log.levels.WARN)
    end
  end)
end

--- Enter commit detail mode: show files changed in a single commit.
function M._enter_commit_mode(commit)
  local owner, repo = (state.pr.url or ""):match("github%.com/([^/]+)/([^/]+)")
  if not owner then return end

  -- Close any open diff
  if state.diff_lhs_win and vim.api.nvim_win_is_valid(state.diff_lhs_win) then
    M._close_diff()
  end

  -- Stash full PR files on first entry
  if not state.commit_mode then
    state.pr_files = state.files
  end

  state.commit_mode = true
  state.commit_sha = commit.oid

  vim.notify("plz: loading commit " .. commit.short_oid .. "…", vim.log.levels.INFO)

  gh.run({
    "api", string.format("repos/%s/%s/commits/%s", owner, repo, commit.oid),
  }, function(data, err)
    if err then
      vim.notify("plz: " .. err, vim.log.levels.ERROR)
      return
    end

    local parents = data.parents or {}
    state.commit_parent_sha = parents[1] and parents[1].sha or nil
    state.files = data.files or {}
    state.base_sha = state.commit_parent_sha
    state.head_sha = commit.oid
    state.current_file_idx = nil

    files.render()
    M._highlight_active_commit(commit)

    -- Show commit info in file list winbar
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      local short = commit.short_oid
      local msg = commit.message
      if #msg > 60 then msg = msg:sub(1, 59) .. "…" end
      vim.wo[state.win].winbar = "%#PlzAccent#  " .. short .. "%#PlzFaint#  " .. msg:gsub("%%", "%%%%")
    end

    -- Focus file list
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_set_current_win(state.win)
    end
  end)
end

--- Exit commit detail mode, restore full PR file list.
function M._exit_commit_mode()
  if not state.commit_mode then return end

  -- Close any open diff
  if state.diff_lhs_win and vim.api.nvim_win_is_valid(state.diff_lhs_win) then
    M._close_diff()
  end

  state.commit_mode = false
  state.files = state.pr_files or {}
  state.pr_files = nil
  state.commit_sha = nil
  state.commit_parent_sha = nil
  state.base_sha = state.pr.baseRefOid
  state.head_sha = state.pr.headRefOid
  state.current_file_idx = nil

  files.render()

  -- Clear file list winbar
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.wo[state.win].winbar = nil
  end

  -- Clear active commit highlight
  if state.summary_buf and vim.api.nvim_buf_is_valid(state.summary_buf) then
    vim.api.nvim_buf_clear_namespace(state.summary_buf, ns_active, 0, -1)
  end

  -- Focus summary (commits view)
  if state.summary_win and vim.api.nvim_win_is_valid(state.summary_win) then
    vim.api.nvim_set_current_win(state.summary_win)
  end
end

--- Highlight the active commit row in the commits view.
function M._highlight_active_commit(commit)
  if not state.summary_buf or not vim.api.nvim_buf_is_valid(state.summary_buf) then return end
  vim.api.nvim_buf_clear_namespace(state.summary_buf, ns_active, 0, -1)
  if state.commits then
    for i, c in ipairs(state.commits) do
      if c.oid == commit.oid then
        pcall(vim.api.nvim_buf_set_extmark, state.summary_buf, ns_active, i - 1, 0, {
          line_hl_group = "CursorLine",
        })
        break
      end
    end
  end
end

--- Render both summary and file list.
function M._render()
  summary.render()
  files.render()
end

--- Set up keymaps for the file list.
function M._setup_keymaps()
  local buf = state.buf
  local opts = { buffer = buf, nowait = true }

  vim.keymap.set("n", "<CR>", function()
    local idx = vim.api.nvim_win_get_cursor(state.win)[1]
    if idx >= 1 and idx <= #state.files then
      M._open_diff(idx)
    end
  end, vim.tbl_extend("force", opts, { desc = "Open file diff" }))

  vim.keymap.set("n", "o", function()
    if state.pr and state.pr.url then
      vim.ui.open(state.pr.url .. "/files")
    end
  end, vim.tbl_extend("force", opts, { desc = "Open PR files in browser" }))

  vim.keymap.set("n", "q", function()
    if state.commit_mode then
      M._exit_commit_mode()
    else
      M.close()
    end
  end, vim.tbl_extend("force", opts, { desc = "Close review / exit commit mode" }))

  vim.keymap.set("n", "<BS>", function()
    if state.commit_mode then
      M._exit_commit_mode()
    end
  end, vim.tbl_extend("force", opts, { desc = "Back to full PR view" }))

  vim.keymap.set("n", "<Tab>", function()
    summary.cycle_view()
  end, vim.tbl_extend("force", opts, { desc = "Cycle summary view" }))

  vim.keymap.set("n", "v", function()
    local idx = vim.api.nvim_win_get_cursor(state.win)[1]
    local file = state.files[idx]
    if file then
      M._toggle_viewed(file.filename or file.path)
    end
  end, vim.tbl_extend("force", opts, { desc = "Toggle viewed" }))

  local help_lines = {
    "plz review",
    "",
    "<Tab>     cycle summary: Info → Commits → Description",
    "<CR>      open diff / select commit (in commits view)",
    "j/k       navigate files",
    "v         toggle file viewed",
    "c         toggle comment at cursor (in diff view)",
    "]c / [c   next/prev comment (in diff view)",
    "]f / [f   next/prev file (in diff view)",
    "]h / [h   next/prev hunk (in diff view)",
    "<BS>/q    back (commit mode → PR, diff → files, files → close)",
    "o         open PR files in browser",
    "?         toggle this help",
  }
  vim.keymap.set("n", "?", function()
    require("plz.help").toggle(help_lines)
  end, vim.tbl_extend("force", opts, { desc = "Toggle help" }))

  -- Summary buffer keymaps
  local s_opts = { buffer = state.summary_buf, nowait = true }
  vim.keymap.set("n", "q", function()
    if state.commit_mode then
      M._exit_commit_mode()
    else
      M.close()
    end
  end, vim.tbl_extend("force", s_opts, { desc = "Close review / exit commit mode" }))

  vim.keymap.set("n", "<BS>", function()
    if state.commit_mode then
      M._exit_commit_mode()
    end
  end, vim.tbl_extend("force", s_opts, { desc = "Back to full PR view" }))

  vim.keymap.set("n", "<CR>", function()
    if state.summary_view == "commits" and state.commits then
      local row = vim.api.nvim_win_get_cursor(state.summary_win)[1]
      if row >= 1 and row <= #state.commits then
        M._enter_commit_mode(state.commits[row])
      end
    end
  end, vim.tbl_extend("force", s_opts, { desc = "View commit files" }))

  vim.keymap.set("n", "<Tab>", function()
    summary.cycle_view()
  end, vim.tbl_extend("force", s_opts, { desc = "Cycle summary view" }))
end

--- Create the split: summary + file list on top, diff area below.
function M._create_diff_split()
  -- Focus file list, split below
  vim.api.nvim_set_current_win(state.win)
  vim.cmd("botright split")
  state.diff_lhs_win = vim.api.nvim_get_current_win()

  -- Vsplit for RHS
  vim.cmd("vsplit")
  state.diff_rhs_win = vim.api.nvim_get_current_win()

  -- Calculate explicit heights
  local total_h = vim.o.lines - vim.o.cmdheight - 2 -- tabline + statusline
  local seps = 2 -- statuslines between summary/files and files/diff
  local avail = total_h - SUMMARY_LINES - seps
  local file_h = SUMMARY_LINES
  local diff_h = avail - file_h

  -- Size file list and fix it
  vim.api.nvim_win_set_height(state.win, file_h)
  vim.wo[state.win].winfixheight = true

  -- Give remaining space to diff
  vim.api.nvim_win_set_height(state.diff_lhs_win, diff_h)
end

--- Clean up old diff buffers after new ones are already displayed.
--- @param old_lhs number|nil Old LHS buffer handle
--- @param old_rhs number|nil Old RHS buffer handle
function M._cleanup_old_bufs(old_lhs, old_rhs)
  local layout_mod = require("plz.diff.layout")
  for _, buf in ipairs({ old_lhs, old_rhs }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      layout_mod._line_nums[buf] = nil
      layout_mod._line_hls[buf] = nil
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

--- Populate diff windows with computed diff data.
function M._populate_diff(data)
  local layout_mod = require("plz.diff.layout")
  local render_mod = require("plz.diff.render")
  local diff_mod = require("plz.diff")

  -- Remember old buffers so we can clean them up AFTER swapping
  local old_lhs = state.diff_lhs_buf
  local old_rhs = state.diff_rhs_buf

  -- Extract texts and line number maps
  local lhs_texts, lhs_nums = {}, {}
  for i, entry in ipairs(data.padded_lhs) do
    lhs_texts[i] = entry.text
    if entry.orig ~= nil then lhs_nums[i] = entry.orig + 1 end
  end

  local rhs_texts, rhs_nums = {}, {}
  for i, entry in ipairs(data.padded_rhs) do
    rhs_texts[i] = entry.text
    if entry.orig ~= nil then rhs_nums[i] = entry.orig + 1 end
  end

  -- Create LHS buffer
  local lhs_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(lhs_buf, 0, -1, false, lhs_texts)
  vim.bo[lhs_buf].modifiable = false
  vim.bo[lhs_buf].buftype = "nofile"
  vim.bo[lhs_buf].bufhidden = "wipe"
  layout_mod._line_nums[lhs_buf] = lhs_nums

  -- Create RHS buffer
  local rhs_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(rhs_buf, 0, -1, false, rhs_texts)
  vim.bo[rhs_buf].modifiable = false
  vim.bo[rhs_buf].buftype = "nofile"
  vim.bo[rhs_buf].bufhidden = "wipe"
  layout_mod._line_nums[rhs_buf] = rhs_nums

  -- Set NEW buffers in windows FIRST (keeps windows alive)
  vim.api.nvim_win_set_buf(state.diff_lhs_win, lhs_buf)
  vim.api.nvim_win_set_buf(state.diff_rhs_win, rhs_buf)

  -- NOW safe to delete old buffers
  M._cleanup_old_bufs(old_lhs, old_rhs)

  -- Window options
  for _, win in ipairs({ state.diff_lhs_win, state.diff_rhs_win }) do
    vim.wo[win].scrollbind = true
    vim.wo[win].cursorbind = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = false
    vim.wo[win].foldcolumn = "1"
    vim.wo[win].statuscolumn = "%{%v:lua.PlzDiffLineNr()%}"
  end
  vim.cmd("syncbind")

  state.diff_lhs_buf = lhs_buf
  state.diff_rhs_buf = rhs_buf

  local diff_state = {
    lhs_buf = lhs_buf,
    rhs_buf = rhs_buf,
    lhs_win = state.diff_lhs_win,
    rhs_win = state.diff_rhs_win,
  }

  -- Apply highlights
  render_mod.apply(lhs_buf, rhs_buf, data.result, data.padded_lhs, data.padded_rhs)

  -- Native vim folds over unchanged regions
  diff_mod._setup_folds(diff_state, data.padded_lhs, data.padded_rhs, data.result, 3)

  -- Hunk navigation
  diff_mod._setup_hunk_navigation(diff_state, data.result, data.padded_lhs, data.padded_rhs)

  -- File navigation and q keymap on diff buffers
  M._setup_diff_keymaps(diff_state)

  -- Show file position
  files.update_diff_status()

  -- Show comment indicators
  state.expanded_comments = {}
  comments.show_comment_indicators()

  -- Focus the RHS (new code) window
  vim.api.nvim_set_current_win(state.diff_rhs_win)
end

--- Clear the file list winbar.
function M._clear_diff_status()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.wo[state.win].winbar = nil
  end
end

--- Set up keymaps on diff buffers (file nav, q).
function M._setup_diff_keymaps(diff_state)
  for _, buf in ipairs({ diff_state.lhs_buf, diff_state.rhs_buf }) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.keymap.set("n", "]f", function()
        if state.current_file_idx and state.current_file_idx < #state.files then
          M._open_diff(state.current_file_idx + 1)
        else
          vim.notify("plz: last file", vim.log.levels.INFO)
        end
      end, { buffer = buf, desc = "Next file" })

      vim.keymap.set("n", "[f", function()
        if state.current_file_idx and state.current_file_idx > 1 then
          M._open_diff(state.current_file_idx - 1)
        else
          vim.notify("plz: first file", vim.log.levels.INFO)
        end
      end, { buffer = buf, desc = "Previous file" })

      vim.keymap.set("n", "q", function()
        M._close_diff()
      end, { buffer = buf, desc = "Close diff" })

      vim.keymap.set("n", "v", function()
        if state.current_file_idx then
          local file = state.files[state.current_file_idx]
          if file then
            M._toggle_viewed(file.filename or file.path)
          end
        end
      end, { buffer = buf, desc = "Toggle viewed" })

      vim.keymap.set("n", "c", function()
        comments.toggle_comment_at_cursor()
      end, { buffer = buf, desc = "Toggle comment" })

      vim.keymap.set("n", "]c", function()
        comments.jump_comment(1)
      end, { buffer = buf, desc = "Next comment" })

      vim.keymap.set("n", "[c", function()
        comments.jump_comment(-1)
      end, { buffer = buf, desc = "Previous comment" })

      vim.keymap.set("n", "<Tab>", function()
        summary.cycle_view()
      end, { buffer = buf, desc = "Cycle summary view" })
    end
  end
end

--- Build synthetic diff data for a fully added file.
--- @param content string Raw file content
--- @param filename string Filename (for filetype detection)
--- @return table|nil
function M._synthetic_added(content, filename)
  local lines = vim.split(content, "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
  if #lines == 0 then return nil end

  local padded_lhs, padded_rhs = {}, {}
  local entries = {}
  for i, line in ipairs(lines) do
    table.insert(padded_lhs, { text = "", orig = nil })
    table.insert(padded_rhs, { text = line, orig = i - 1 })
    table.insert(entries, { type = "add", rhs_line = i - 1, rhs_changes = {} })
  end

  return {
    padded_lhs = padded_lhs,
    padded_rhs = padded_rhs,
    result = { hunks = { { entries = entries } }, status = "changed" },
    ft = vim.filetype.match({ filename = filename }),
  }
end

--- Build synthetic diff data for a fully removed file.
--- @param content string Raw file content
--- @param filename string Filename (for filetype detection)
--- @return table|nil
function M._synthetic_removed(content, filename)
  local lines = vim.split(content, "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then table.remove(lines) end
  if #lines == 0 then return nil end

  local padded_lhs, padded_rhs = {}, {}
  local entries = {}
  for i, line in ipairs(lines) do
    table.insert(padded_lhs, { text = line, orig = i - 1 })
    table.insert(padded_rhs, { text = "", orig = nil })
    table.insert(entries, { type = "remove", lhs_line = i - 1, lhs_changes = {} })
  end

  return {
    padded_lhs = padded_lhs,
    padded_rhs = padded_rhs,
    result = { hunks = { { entries = entries } }, status = "changed" },
    ft = vim.filetype.match({ filename = filename }),
  }
end

--- Open difftastic diff for a file below the file list.
function M._open_diff(file_idx)
  local file = state.files[file_idx]
  local path = file.filename or file.path
  local prev_path = file.previous_filename or path
  state.current_file_idx = file_idx

  -- Update active file indicator
  files.highlight_active()

  -- Move file list cursor to match and ensure no trailing blank lines
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_set_cursor, state.win, { file_idx, 0 })
    vim.api.nvim_win_call(state.win, function()
      local win_h = vim.api.nvim_win_get_height(state.win)
      local total = #state.files
      if total > 0 and total <= win_h then
        vim.fn.winrestview({ topline = 1 })
      elseif file_idx > total - win_h + 1 then
        vim.fn.winrestview({ topline = math.max(1, total - win_h + 1) })
      end
    end)
  end

  -- Create temp files
  local tmp_dir = vim.fn.tempname()
  vim.fn.mkdir(tmp_dir .. "/base", "p")
  vim.fn.mkdir(tmp_dir .. "/head", "p")

  local basename = vim.fn.fnamemodify(path, ":t")
  local base_path = tmp_dir .. "/base/" .. basename
  local head_path = tmp_dir .. "/head/" .. basename

  local pending = 2
  local base_content = ""
  local head_content = ""

  local function show_diff(data)
    if not state.diff_lhs_win or not vim.api.nvim_win_is_valid(state.diff_lhs_win) then
      M._create_diff_split()
    end
    M._populate_diff(data)
  end

  local function on_ready()
    pending = pending - 1
    if pending > 0 then return end

    local file_status = file.status or "modified"

    -- Added files: bypass difftastic, all RHS lines are new
    if file_status == "added" then
      local data = M._synthetic_added(head_content, path)
      if not data then
        vim.notify("plz: empty file", vim.log.levels.INFO)
        return
      end
      show_diff(data)
      return
    end

    -- Removed files: bypass difftastic, all LHS lines are deleted
    if file_status == "removed" then
      local data = M._synthetic_removed(base_content, path)
      if not data then
        vim.notify("plz: empty file", vim.log.levels.INFO)
        return
      end
      show_diff(data)
      return
    end

    -- Write temp files
    local f = io.open(base_path, "w")
    if f then f:write(base_content); f:close() end
    f = io.open(head_path, "w")
    if f then f:write(head_content); f:close() end

    -- Compute diff (async — difftastic runs in background)
    diff.compute(base_path, head_path, function(data, err, unchanged)
      if unchanged then
        vim.notify("plz: " .. vim.fn.fnamemodify(path, ":t") .. " — files are identical", vim.log.levels.INFO)
        return
      end
      if err then
        vim.notify("plz: " .. err, vim.log.levels.ERROR)
        return
      end

      show_diff(data)
    end)
  end

  -- Fetch base version
  if state.base_sha then
    M._git_show(state.base_sha, prev_path, function(content)
      base_content = content
      on_ready()
    end)
  else
    base_content = ""
    on_ready()
  end

  -- Fetch head version
  M._git_show(state.head_sha, path, function(content)
    head_content = content
    on_ready()
  end)
end

--- Get file content at a specific commit.
function M._git_show(sha, path, callback)
  vim.system({ "git", "show", sha .. ":" .. path }, { text = true }, function(obj)
    vim.schedule(function()
      callback(obj.code == 0 and obj.stdout or "")
    end)
  end)
end

--- Close the diff area, return focus to file list.
function M._close_diff()
  -- Safe to delete buffers here — we're closing the windows right after
  M._cleanup_old_bufs(state.diff_lhs_buf, state.diff_rhs_buf)
  state.diff_lhs_buf = nil
  state.diff_rhs_buf = nil

  if state.diff_lhs_win and vim.api.nvim_win_is_valid(state.diff_lhs_win) then
    pcall(vim.api.nvim_win_close, state.diff_lhs_win, true)
  end
  if state.diff_rhs_win and vim.api.nvim_win_is_valid(state.diff_rhs_win) then
    pcall(vim.api.nvim_win_close, state.diff_rhs_win, true)
  end

  M._clear_diff_status()


  state.diff_lhs_win = nil
  state.diff_rhs_win = nil
  state.current_file_idx = nil

  -- Remove active file highlight
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, ns_active, 0, -1)
  end

  -- Unfixheight so file list expands to fill remaining space
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.wo[state.win].winfixheight = false
    vim.api.nvim_set_current_win(state.win)
  end
end

--- Close the entire review.
function M.close()
  M._close_diff()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose")
    end
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  if state.summary_buf and vim.api.nvim_buf_is_valid(state.summary_buf) then
    pcall(vim.api.nvim_buf_delete, state.summary_buf, { force = true })
  end
  state.summary_buf = nil
  state.summary_win = nil
  state.buf = nil
  state.win = nil
  state.files = {}
  state.viewed = {}
  state.review_comments = {}
  state.comments_by_file = {}
  state.comments_by_file_left = {}
  state.expanded_comments = {}
  state.pr = nil
  state.current_file_idx = nil
  state.ado_item = nil
  state.commits = nil
  state.summary_view = "info"
  state.commit_mode = false
  state.commit_sha = nil
  state.commit_parent_sha = nil
  state.pr_files = nil
end

return M
