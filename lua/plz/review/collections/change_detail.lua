local gh = require("plz.gh")
local diff = require("plz.diff")
local comments = require("plz.review.comments")
local files = require("plz.review.files")
local layout = require("plz.review.layout")

local M = {}

local ns_active = vim.api.nvim_create_namespace("plz_review_active")

--- Reference to the shared review state table, set via M.setup().
local state

--- Store a reference to shared state.
--- @param state_ref table  The shared review state table
function M.setup(state_ref)
  state = state_ref
end

--- Toggle viewed state for a file via GitHub GraphQL mutation.
--- @param file_path string
function M.toggle_viewed(file_path)
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

--- Create the vsplit diff area in the C3 bottom region.
function M.create_diff_split()
  -- Close the placeholder bottom window if it exists
  if state.bottom_win and vim.api.nvim_win_is_valid(state.bottom_win) then
    pcall(vim.api.nvim_win_close, state.bottom_win, true)
    state.bottom_win = nil
  end

  -- Focus file list (top window), split below
  vim.api.nvim_set_current_win(state.top_win or state.win)
  vim.cmd("botright split")
  state.diff_lhs_win = vim.api.nvim_get_current_win()

  -- Vsplit for RHS
  vim.cmd("vsplit")
  state.diff_rhs_win = vim.api.nvim_get_current_win()

  -- Even split between top and diff area
  vim.cmd("wincmd =")
end

--- Clean up old diff buffers after new ones are already displayed.
--- @param old_lhs number|nil Old LHS buffer handle
--- @param old_rhs number|nil Old RHS buffer handle
function M.cleanup_old_bufs(old_lhs, old_rhs)
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
function M.populate_diff(data)
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
  vim.bo[lhs_buf].filetype = "plz-diff"
  layout_mod._line_nums[lhs_buf] = lhs_nums

  -- Create RHS buffer
  local rhs_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(rhs_buf, 0, -1, false, rhs_texts)
  vim.bo[rhs_buf].modifiable = false
  vim.bo[rhs_buf].buftype = "nofile"
  vim.bo[rhs_buf].bufhidden = "wipe"
  vim.bo[rhs_buf].filetype = "plz-diff"
  layout_mod._line_nums[rhs_buf] = rhs_nums

  -- Set NEW buffers in windows FIRST (keeps windows alive)
  vim.api.nvim_win_set_buf(state.diff_lhs_win, lhs_buf)
  vim.api.nvim_win_set_buf(state.diff_rhs_win, rhs_buf)

  -- NOW safe to delete old buffers
  M.cleanup_old_bufs(old_lhs, old_rhs)

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
    vim.wo[win].statusline = layout.plz_statusline()
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

  -- Collect comment lines so they are not folded away
  local path = state.files[state.current_file_idx]
  path = path and (path.filename or path.path) or ""
  local rhs_comments = state.comments_by_file and state.comments_by_file[path] or {}
  local lhs_comments = state.comments_by_file_left and state.comments_by_file_left[path] or {}
  local comment_lines = { lhs = {}, rhs = {} }
  for orig_line in pairs(rhs_comments) do comment_lines.rhs[orig_line] = true end
  for orig_line in pairs(lhs_comments) do comment_lines.lhs[orig_line] = true end

  -- Native vim folds over unchanged regions
  diff_mod._setup_folds(diff_state, data.padded_lhs, data.padded_rhs, data.result, 3, comment_lines)

  -- Hunk navigation
  diff_mod._setup_hunk_navigation(diff_state, data.result, data.padded_lhs, data.padded_rhs)

  -- File navigation and q keymap on diff buffers
  M.setup_diff_keymaps(diff_state)

  -- Show file position (sets winbar) then resize top to fit content
  files.update_diff_status()
  layout.resize_top_to_content()

  -- Show comment indicators
  state.expanded_comments = {}
  comments.show_comment_indicators()

  -- Focus the RHS (new code) window, unless suppressed
  if not state._suppress_diff_focus then
    vim.api.nvim_set_current_win(state.diff_rhs_win)
  end
  state._suppress_diff_focus = nil
end

--- Clear the file list winbar.
function M.clear_diff_status()
  local top = state.top_win or state.win
  if top and vim.api.nvim_win_is_valid(top) then
    vim.wo[top].winbar = nil
  end
end

--- Set up keymaps on diff buffers (file nav, q).
function M.setup_diff_keymaps(diff_state)
  for _, buf in ipairs({ diff_state.lhs_buf, diff_state.rhs_buf }) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.keymap.set("n", "]f", function()
        if state.current_file_idx and state.current_file_idx < #state.files then
          M.open_diff(state.current_file_idx + 1)
        else
          vim.notify("plz: last file", vim.log.levels.INFO)
        end
      end, { buffer = buf, desc = "Next file" })

      vim.keymap.set("n", "[f", function()
        if state.current_file_idx and state.current_file_idx > 1 then
          M.open_diff(state.current_file_idx - 1)
        else
          vim.notify("plz: first file", vim.log.levels.INFO)
        end
      end, { buffer = buf, desc = "Previous file" })

      vim.keymap.set("n", "q", function()
        M.close_diff()
      end, { buffer = buf, desc = "Close diff" })

      vim.keymap.set("n", "v", function()
        if state.current_file_idx then
          local file = state.files[state.current_file_idx]
          if file then
            M.toggle_viewed(file.filename or file.path)
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

      layout.set_collection_keymaps(buf)
    end
  end
end

--- Build synthetic diff data for a fully added file.
--- @param content string Raw file content
--- @param filename string Filename (for filetype detection)
--- @return table|nil
function M.synthetic_added(content, filename)
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
function M.synthetic_removed(content, filename)
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
function M.open_diff(file_idx)
  local file = state.files[file_idx]
  local path = file.filename or file.path
  local prev_path = file.previous_filename or path
  state.current_file_idx = file_idx

  -- Generation counter: ignore stale callbacks from prior open_diff calls
  state.diff_gen = (state.diff_gen or 0) + 1
  local gen = state.diff_gen

  -- Update active file indicator
  files.highlight_active()

  -- Move file list cursor to match and ensure no trailing blank lines
  local file_win = state.top_win or state.win
  if file_win and vim.api.nvim_win_is_valid(file_win) then
    pcall(vim.api.nvim_win_set_cursor, file_win, { file_idx, 0 })
    vim.api.nvim_win_call(file_win, function()
      local win_h = vim.api.nvim_win_get_height(file_win)
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

  --- Guard: abort if generation changed or no longer in C3.
  local function is_stale()
    return state.diff_gen ~= gen or state.active_collection ~= 3
  end

  local function show_diff(data)
    if is_stale() then return end
    if not state.diff_lhs_win or not vim.api.nvim_win_is_valid(state.diff_lhs_win) then
      M.create_diff_split()
    end
    M.populate_diff(data)
  end

  local function on_ready()
    pending = pending - 1
    if pending > 0 then return end
    if is_stale() then return end

    local file_status = file.status or "modified"

    -- Added files: bypass difftastic, all RHS lines are new
    if file_status == "added" then
      local data = M.synthetic_added(head_content, path)
      if not data then
        vim.notify("plz: empty file", vim.log.levels.INFO)
        return
      end
      show_diff(data)
      return
    end

    -- Removed files: bypass difftastic, all LHS lines are deleted
    if file_status == "removed" then
      local data = M.synthetic_removed(base_content, path)
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
      if is_stale() then return end
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
    M.git_show(state.base_sha, prev_path, function(content)
      if is_stale() then return end
      base_content = content
      on_ready()
    end)
  else
    base_content = ""
    on_ready()
  end

  -- Fetch head version
  M.git_show(state.head_sha, path, function(content)
    if is_stale() then return end
    head_content = content
    on_ready()
  end)
end

--- Get file content at a specific commit.
function M.git_show(sha, path, callback)
  vim.system({ "git", "show", sha .. ":" .. path }, { text = true }, function(obj)
    vim.schedule(function()
      callback(obj.code == 0 and obj.stdout or "")
    end)
  end)
end

--- Close the diff area, return focus to file list.
function M.close_diff()
  -- Safe to delete buffers here — we're closing the windows right after
  M.cleanup_old_bufs(state.diff_lhs_buf, state.diff_rhs_buf)
  state.diff_lhs_buf = nil
  state.diff_rhs_buf = nil

  if state.diff_lhs_win and vim.api.nvim_win_is_valid(state.diff_lhs_win) then
    pcall(vim.api.nvim_win_close, state.diff_lhs_win, true)
  end
  if state.diff_rhs_win and vim.api.nvim_win_is_valid(state.diff_rhs_win) then
    pcall(vim.api.nvim_win_close, state.diff_rhs_win, true)
  end

  M.clear_diff_status()

  state.diff_lhs_win = nil
  state.diff_rhs_win = nil
  state.current_file_idx = nil

  -- Remove active file highlight
  local c3 = state.collections and state.collections[3]
  local file_buf = c3 and c3.top_buf or state.buf
  if file_buf and vim.api.nvim_buf_is_valid(file_buf) then
    vim.api.nvim_buf_clear_namespace(file_buf, ns_active, 0, -1)
  end

  -- Recreate placeholder bottom window and focus top
  local top = state.top_win or state.win
  if top and vim.api.nvim_win_is_valid(top) then
    vim.api.nvim_set_current_win(top)
    vim.cmd("botright split")
    state.bottom_win = vim.api.nvim_get_current_win()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].buftype = "nofile"
    vim.bo[scratch].bufhidden = "wipe"
    vim.api.nvim_win_set_buf(state.bottom_win, scratch)
    vim.cmd("wincmd =")
    vim.api.nvim_set_current_win(top)
  end
end

--- Set up C3 file list keymaps.
--- @param review table  The plz.review module (to avoid circular require at load time)
function M.setup_file_keymaps(review)
  local c3 = state.collections and state.collections[3]
  local buf = c3 and c3.top_buf or state.buf
  local opts = { buffer = buf, nowait = true }

  vim.keymap.set("n", "<CR>", function()
    local top = state.top_win or state.win
    if not top or not vim.api.nvim_win_is_valid(top) then return end
    local idx = vim.api.nvim_win_get_cursor(top)[1]
    if idx >= 1 and idx <= #state.files then
      M.open_diff(idx)
    end
  end, vim.tbl_extend("force", opts, { desc = "Open file diff" }))

  vim.keymap.set("n", "o", function()
    if state.pr and state.pr.url then
      vim.ui.open(state.pr.url .. "/files")
    end
  end, vim.tbl_extend("force", opts, { desc = "Open PR files in browser" }))

  vim.keymap.set("n", "q", function()
    if state.commit_mode then
      review._exit_commit_mode()
    else
      review.close()
    end
  end, vim.tbl_extend("force", opts, { desc = "Close review / exit commit mode" }))

  vim.keymap.set("n", "<BS>", function()
    if state.commit_mode then
      review._exit_commit_mode()
    end
  end, vim.tbl_extend("force", opts, { desc = "Back to full PR view" }))

  vim.keymap.set("n", "v", function()
    local top = state.top_win or state.win
    if not top or not vim.api.nvim_win_is_valid(top) then return end
    local idx = vim.api.nvim_win_get_cursor(top)[1]
    local file = state.files[idx]
    if file then
      M.toggle_viewed(file.filename or file.path)
    end
  end, vim.tbl_extend("force", opts, { desc = "Toggle viewed" }))

  local help_lines = {
    "plz review",
    "",
    "Navigation",
    "  <Tab>/<S-Tab>   cycle collections",
    "  1/2/3           jump to collection",
    "  <C-w><C-w>      switch focus between top/bottom panes",
    "",
    "C1 — PR Detail (info + description / commits)",
    "  <CR>            select commit → enter commit mode (in commits)",
    "  <BS>            exit commit mode → return to PR",
    "  o               open PR in browser",
    "",
    "C2 — Reviews (review list / threads)",
    "  <CR>            select review → show threads below",
    "  o               open review in browser",
    "",
    "C3 — Changes (file list / diff)",
    "  <CR>            open diff for selected file",
    "  ]f / [f         next/prev file (in diff)",
    "  ]h / [h         next/prev hunk (in diff)",
    "  ]c / [c         next/prev comment (in diff)",
    "  c               toggle comment at cursor (in diff)",
    "  v               toggle file viewed",
    "  o               open PR files in browser",
    "",
    "General",
    "  q               close (diff → file list → exit review)",
    "  <BS>            back (commit mode → PR view)",
    "  ?               toggle this help",
  }
  vim.keymap.set("n", "?", function()
    require("plz.help").toggle(help_lines)
  end, vim.tbl_extend("force", opts, { desc = "Toggle help" }))

  -- Store help_lines so other collections can reuse
  M._help_lines = help_lines
end

return M
