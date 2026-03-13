local gh = require("plz.gh")
local comments = require("plz.review.comments")
local files = require("plz.review.files")
local summary = require("plz.review.summary")
local layout = require("plz.review.layout")
local review_detail = require("plz.review.collections.review_detail")
local change_detail = require("plz.review.collections.change_detail")

local M = {}

local ns = vim.api.nvim_create_namespace("plz_review")
local ns_active = vim.api.nvim_create_namespace("plz_review_active")

local state = {
  pr = nil,
  files = {},
  base_sha = nil,
  head_sha = nil,
  -- Active collection (1=info+commits, 2=reviews, 3=files+diff)
  active_collection = 3,
  collections = nil,      -- populated by layout.create_initial()
  top_win = nil,           -- shared top window
  bottom_win = nil,        -- shared bottom window
  -- Flat aliases (synced by layout.sync_aliases)
  summary_buf = nil,
  summary_win = nil,
  commits = nil,           -- fetched commit list (nil = not loaded)
  commit_mode = false,     -- true when viewing a single commit
  commit_sha = nil,        -- full OID of selected commit
  commit_parent_sha = nil,
  pr_files = nil,          -- stashed full PR file list
  -- File list (scrollable) — aliased from C3
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
  diff_gen = 0,            -- generation counter for stale diff callbacks
  ado_item = nil,
  viewed = {},  -- path -> bool, synced with GitHub viewed state
  -- Review comments
  review_comments = {},  -- raw API response
  comments_by_file = {}, -- path -> { line -> { comments } } (RIGHT side)
  comments_by_file_left = {}, -- path -> { line -> { comments } } (LEFT side)
  expanded_comments = {}, -- "side:buf:line" -> bool, tracks which comment indicators are expanded
  -- Reviews (C2)
  reviews = nil,             -- fetched review submissions (nil = not loaded)
  comments_by_review = {},   -- review_id -> [comments]
  selected_review_idx = nil, -- currently selected review in C2
}

comments.setup(state)
files.setup(state)
summary.setup(state)
layout.setup(state)
review_detail.setup(state)
change_detail.setup(state)

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
      layout.create_initial()
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

  -- Fetch review submissions in background
  review_detail.fetch_reviews(owner, repo, pr.number)
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
    local c3 = state.collections and state.collections[3]
    local file_buf = c3 and c3.top_buf or state.buf
    if file_buf and vim.api.nvim_buf_is_valid(file_buf) then
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
  change_detail.toggle_viewed(file_path)
end

--- Enter commit detail mode: show files changed in a single commit.
function M._enter_commit_mode(commit)
  local owner, repo = (state.pr.url or ""):match("github%.com/([^/]+)/([^/]+)")
  if not owner then return end

  -- Close any open diff
  if state.diff_lhs_win and vim.api.nvim_win_is_valid(state.diff_lhs_win) then
    change_detail.close_diff()
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
    -- Guard: review may have been closed while fetching
    if not state.commit_mode or not state.collections then return end

    local parents = data.parents or {}
    state.commit_parent_sha = parents[1] and parents[1].sha or nil
    state.files = data.files or {}
    state.base_sha = state.commit_parent_sha
    state.head_sha = commit.oid
    state.current_file_idx = nil

    -- Switch to C3 (files) if not already there
    if state.active_collection ~= 3 then
      layout.switch_to(3)
    end

    files.render()
    M._highlight_active_commit(commit)

    -- Show commit info in file list winbar
    local top = state.top_win or state.win
    if top and vim.api.nvim_win_is_valid(top) then
      local short = commit.short_oid
      local msg = commit.message
      if #msg > 60 then msg = msg:sub(1, 59) .. "…" end
      vim.wo[top].winbar = "%#PlzAccent#  " .. short .. "%#PlzFaint#  " .. msg:gsub("%%", "%%%%")
    end

    -- Focus file list
    if top and vim.api.nvim_win_is_valid(top) then
      vim.api.nvim_set_current_win(top)
    end
  end)
end

--- Exit commit detail mode, restore full PR file list.
function M._exit_commit_mode()
  if not state.commit_mode then return end

  -- Close any open diff
  if state.diff_lhs_win and vim.api.nvim_win_is_valid(state.diff_lhs_win) then
    change_detail.close_diff()
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
  local top = state.top_win or state.win
  if top and vim.api.nvim_win_is_valid(top) then
    vim.wo[top].winbar = nil
  end

  -- Clear active commit highlight
  local c1 = state.collections and state.collections[1]
  if c1 and c1.bottom_buf and vim.api.nvim_buf_is_valid(c1.bottom_buf) then
    vim.api.nvim_buf_clear_namespace(c1.bottom_buf, ns_active, 0, -1)
  end

  -- Switch to C1 (info + commits)
  layout.switch_to(1)
end

--- Highlight the active commit row in the commits view.
function M._highlight_active_commit(commit)
  local c1 = state.collections and state.collections[1]
  local buf = c1 and c1.bottom_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns_active, 0, -1)
  if state.commits then
    for i, c in ipairs(state.commits) do
      if c.oid == commit.oid then
        pcall(vim.api.nvim_buf_set_extmark, buf, ns_active, i - 1, 0, {
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

--- Set up keymaps for all collection buffers.
function M._setup_keymaps()
  -- C3 file list keymaps (delegated to change_detail)
  change_detail.setup_file_keymaps(M)

  -- C1 bottom (commits) buffer keymaps
  local c1 = state.collections and state.collections[1]
  if c1 and c1.bottom_buf then
    local s_opts = { buffer = c1.bottom_buf, nowait = true }
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
      if state.active_collection == 1 and state.commits then
        local win = state.bottom_win
        if win and vim.api.nvim_win_is_valid(win) then
          local row = vim.api.nvim_win_get_cursor(win)[1]
          if row >= 1 and row <= #state.commits then
            M._enter_commit_mode(state.commits[row])
          end
        end
      end
    end, vim.tbl_extend("force", s_opts, { desc = "View commit files" }))
  end

  -- C1 top (info+description) buffer keymaps
  if c1 and c1.top_buf then
    local i_opts = { buffer = c1.top_buf, nowait = true }
    vim.keymap.set("n", "q", function()
      M.close()
    end, vim.tbl_extend("force", i_opts, { desc = "Close review" }))

    vim.keymap.set("n", "o", function()
      if state.pr and state.pr.url then
        vim.ui.open(state.pr.url)
      end
    end, vim.tbl_extend("force", i_opts, { desc = "Open PR in browser" }))
  end

  -- C2 top (review list) buffer keymaps
  local c2 = state.collections and state.collections[2]
  if c2 and c2.top_buf then
    local r_opts = { buffer = c2.top_buf, nowait = true }

    vim.keymap.set("n", "<CR>", function()
      if state.active_collection ~= 2 then return end
      local reviews = state.reviews or {}
      if #reviews == 0 then return end
      local win = state.top_win
      if not win or not vim.api.nvim_win_is_valid(win) then return end
      local row = vim.api.nvim_win_get_cursor(win)[1]
      if row >= 1 and row <= #reviews then
        state.selected_review_idx = row
        review_detail.render_threads(c2.bottom_buf, state.bottom_win, row)
      end
    end, vim.tbl_extend("force", r_opts, { desc = "Select review" }))

    vim.keymap.set("n", "o", function()
      if state.active_collection ~= 2 then return end
      local reviews = state.reviews or {}
      if #reviews == 0 then return end
      local win = state.top_win
      if not win or not vim.api.nvim_win_is_valid(win) then return end
      local row = vim.api.nvim_win_get_cursor(win)[1]
      local review = reviews[row]
      if review and review.html_url then
        vim.ui.open(review.html_url)
      elseif state.pr and state.pr.url then
        vim.ui.open(state.pr.url)
      end
    end, vim.tbl_extend("force", r_opts, { desc = "Open review in browser" }))

    vim.keymap.set("n", "q", function()
      M.close()
    end, vim.tbl_extend("force", r_opts, { desc = "Close review" }))
  end

  -- C2 bottom (review threads) buffer keymaps
  if c2 and c2.bottom_buf then
    local rt_opts = { buffer = c2.bottom_buf, nowait = true }
    vim.keymap.set("n", "q", function()
      M.close()
    end, vim.tbl_extend("force", rt_opts, { desc = "Close review" }))
  end

  -- Help keymap on all collection buffers (C3 is set in change_detail)
  local help_bufs = {}
  if c1 then
    if c1.top_buf then table.insert(help_bufs, c1.top_buf) end
    if c1.bottom_buf then table.insert(help_bufs, c1.bottom_buf) end
  end
  if c2 then
    if c2.top_buf then table.insert(help_bufs, c2.top_buf) end
    if c2.bottom_buf then table.insert(help_bufs, c2.bottom_buf) end
  end
  for _, buf in ipairs(help_bufs) do
    vim.keymap.set("n", "?", function()
      local help = change_detail._help_lines
      if help then require("plz.help").toggle(help) end
    end, { buffer = buf, nowait = true, desc = "Toggle help" })
  end
end

--- Delegate: create diff split.
function M._create_diff_split() change_detail.create_diff_split() end
--- Delegate: clean up old diff buffers.
function M._cleanup_old_bufs(old_lhs, old_rhs) change_detail.cleanup_old_bufs(old_lhs, old_rhs) end
--- Delegate: clear diff status winbar.
function M._clear_diff_status() change_detail.clear_diff_status() end
--- Delegate: open diff for a file.
function M._open_diff(file_idx) change_detail.open_diff(file_idx) end
--- Delegate: close diff area.
function M._close_diff() change_detail.close_diff() end

--- Close the entire review.
function M.close()
  -- Clean up diff buffers (without recreating bottom window)
  M._cleanup_old_bufs(state.diff_lhs_buf, state.diff_rhs_buf)
  state.diff_lhs_buf = nil
  state.diff_rhs_buf = nil

  -- Close all windows
  for _, key in ipairs({ "diff_lhs_win", "diff_rhs_win", "bottom_win" }) do
    if state[key] and vim.api.nvim_win_is_valid(state[key]) then
      pcall(vim.api.nvim_win_close, state[key], true)
    end
  end

  -- Close tab
  if #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd("tabclose")
  end

  -- Delete all collection buffers
  if state.collections then
    for _, c in pairs(state.collections) do
      for _, key in ipairs({ "top_buf", "bottom_buf" }) do
        if c[key] and vim.api.nvim_buf_is_valid(c[key]) then
          pcall(vim.api.nvim_buf_delete, c[key], { force = true })
        end
      end
    end
  end

  state.summary_buf = nil
  state.summary_win = nil
  state.buf = nil
  state.win = nil
  state.top_win = nil
  state.bottom_win = nil
  state.collections = nil
  state.active_collection = 3
  state.files = {}
  state.viewed = {}
  state.review_comments = {}
  state.comments_by_file = {}
  state.comments_by_file_left = {}
  state.expanded_comments = {}
  state.pr = nil
  state.current_file_idx = nil
  state.diff_gen = 0
  state.ado_item = nil
  state.commits = nil
  state.commit_mode = false
  state.commit_sha = nil
  state.commit_parent_sha = nil
  state.pr_files = nil
  state.reviews = nil
  state.comments_by_review = {}
  state.selected_review_idx = nil
end

return M
