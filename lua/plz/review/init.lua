local gh = require("plz.gh")
local diff = require("plz.diff")

local M = {}

local ns = vim.api.nvim_create_namespace("plz_review")
local ns_active = vim.api.nvim_create_namespace("plz_review_active")
local SUMMARY_LINES = 3

local state = {
  pr = nil,
  files = {},
  base_sha = nil,
  head_sha = nil,
  -- Summary (fixed header)
  summary_buf = nil,
  summary_win = nil,
  -- File list (scrollable)
  buf = nil,
  win = nil,
  -- Diff area
  diff_lhs_win = nil,
  diff_rhs_win = nil,
  diff_lhs_buf = nil,
  diff_rhs_buf = nil,
  current_file_idx = nil,
}

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

  gh.run({
    "api", string.format("repos/%s/%s/pulls/%d/files?per_page=100", owner, repo, pr.number),
  }, function(files, err)
    if err then
      vim.notify("plz: " .. err, vim.log.levels.ERROR)
      return
    end

    state.files = files or {}
    if #state.files == 0 then
      vim.notify("plz: no changed files", vim.log.levels.INFO)
      return
    end

    M._ensure_commits(function()
      M._show_file_list()
    end)
  end)
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

--- Show the summary + file list in a new tab.
function M._show_file_list()
  vim.cmd("tabnew")

  -- File list buffer first (gets full height)
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = "plz-review"

  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)

  local file_opts = { number = false, relativenumber = false, signcolumn = "no",
    wrap = false, foldcolumn = "0", statuscolumn = "", cursorline = true }
  for k, v in pairs(file_opts) do vim.wo[state.win][k] = v end

  -- Summary buffer above (split from full-height file list)
  vim.cmd("aboveleft split")
  state.summary_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.summary_buf].buftype = "nofile"
  vim.bo[state.summary_buf].bufhidden = "wipe"

  state.summary_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.summary_win, state.summary_buf)

  local no_interact = { number = false, relativenumber = false, signcolumn = "no",
    wrap = false, foldcolumn = "0", statuscolumn = "", cursorline = false }
  for k, v in pairs(no_interact) do vim.wo[state.summary_win][k] = v end
  vim.api.nvim_win_set_height(state.summary_win, SUMMARY_LINES)
  vim.wo[state.summary_win].winfixheight = true

  -- Focus back on file list
  vim.api.nvim_set_current_win(state.win)

  M._render()
  M._setup_keymaps()

  if #state.files > 0 then
    pcall(vim.api.nvim_win_set_cursor, state.win, { 1, 0 })
  end
end

--- Render the summary buffer (fixed header).
function M._render_summary()
  local pr = state.pr
  local lines = {}
  local hl_regions = {}

  local title_line = string.format("  PR #%d: %s", pr.number, pr.title or "")
  table.insert(lines, title_line)
  table.insert(hl_regions, {
    { 0, #("  PR #" .. tostring(pr.number)), "PlzAccent" },
  })

  local ref_line = string.format("  %s  %s  │  %d files changed",
    pr.baseRefName or "?", pr.headRefName or "?", #state.files)
  table.insert(lines, ref_line)
  table.insert(hl_regions, {
    { 0, #ref_line, "PlzFaint" },
  })

  local win_w = state.summary_win and vim.api.nvim_win_is_valid(state.summary_win)
    and vim.api.nvim_win_get_width(state.summary_win) or 90
  local border = string.rep("─", win_w)
  table.insert(lines, border)
  table.insert(hl_regions, {
    { 0, #border, "PlzBorder" },
  })

  vim.bo[state.summary_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.summary_buf, 0, -1, false, lines)
  vim.bo[state.summary_buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.summary_buf, ns, 0, -1)
  for i, regions in ipairs(hl_regions) do
    for _, r in ipairs(regions) do
      if r[1] < r[2] then
        pcall(vim.api.nvim_buf_set_extmark, state.summary_buf, ns, i - 1, r[1], {
          end_col = math.min(r[2], #lines[i]),
          hl_group = r[3],
        })
      end
    end
  end
end

--- Render the file list buffer.
function M._render_files()
  local lines = {}
  local hl_regions = {}

  local win_w = state.win and vim.api.nvim_win_is_valid(state.win)
    and vim.api.nvim_win_get_width(state.win) or 90

  local max_path = 0
  for _, file in ipairs(state.files) do
    local path = file.filename or file.path or ""
    if #path > max_path then max_path = #path end
  end
  max_path = math.min(max_path, win_w - 20)

  for _, file in ipairs(state.files) do
    local path = file.filename or file.path or "?"
    local status = file.status or "modified"
    local adds = file.additions or 0
    local dels = file.deletions or 0

    local icon, icon_hl
    if status == "added" then
      icon, icon_hl = "A", "PlzGreen"
    elseif status == "removed" then
      icon, icon_hl = "D", "PlzRed"
    elseif status == "renamed" then
      icon, icon_hl = "R", "PlzYellow"
    elseif status == "copied" then
      icon, icon_hl = "C", "PlzYellow"
    else
      icon, icon_hl = "M", "PlzYellow"
    end

    local display_path = path
    if #path > max_path then
      display_path = "…" .. path:sub(-(max_path - 1))
    end

    local adds_str = adds > 0 and ("+" .. adds) or ""
    local dels_str = dels > 0 and ("-" .. dels) or ""

    local padded_path = display_path .. string.rep(" ", max_path - vim.fn.strdisplaywidth(display_path))
    local row = string.format("  %s  %s  %7s %7s", icon, padded_path, adds_str, dels_str):gsub("%s+$", "")
    table.insert(lines, row)

    local row_regions = {}
    table.insert(row_regions, { 2, 3, icon_hl })
    if adds > 0 then
      local p = row:find("+" .. tostring(adds), 5 + #display_path)
      if p then
        table.insert(row_regions, { p - 1, p - 1 + #adds_str, "PlzGreen" })
      end
    end
    if dels > 0 then
      local p = row:find("-" .. tostring(dels), 5 + #display_path)
      if p then
        table.insert(row_regions, { p - 1, p - 1 + #dels_str, "PlzRed" })
      end
    end
    table.insert(hl_regions, row_regions)
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for i, regions in ipairs(hl_regions) do
    for _, r in ipairs(regions) do
      if r[1] < r[2] then
        pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, i - 1, r[1], {
          end_col = math.min(r[2], #lines[i]),
          hl_group = r[3],
        })
      end
    end
  end
end

--- Render both summary and file list.
function M._render()
  M._render_summary()
  M._render_files()
end

--- Highlight the active file row in the file list.
function M._highlight_active_file()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  vim.api.nvim_buf_clear_namespace(state.buf, ns_active, 0, -1)
  if state.current_file_idx then
    local row = state.current_file_idx - 1  -- 0-indexed, no header offset
    pcall(vim.api.nvim_buf_set_extmark, state.buf, ns_active, row, 0, {
      line_hl_group = "CursorLine",
    })
  end
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
    M.close()
  end, vim.tbl_extend("force", opts, { desc = "Close review" }))

  vim.keymap.set("n", "?", function()
    vim.notify(table.concat({
      "plz review",
      "",
      "j/k       navigate files",
      "<CR>      open file diff below",
      "]f / [f   next/prev file (in diff view)",
      "]h / [h   next/prev hunk (in diff view)",
      "o         open PR files in browser",
      "q         close (diff or review)",
      "?         this help",
    }, "\n"), vim.log.levels.INFO)
  end, vim.tbl_extend("force", opts, { desc = "Show help" }))
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

  -- Calculate explicit heights for all three rows
  local total_h = vim.o.lines - vim.o.cmdheight - 2 -- tabline + statusline
  local seps = 2 -- statuslines between summary/files and files/diff
  local avail = total_h - SUMMARY_LINES - seps
  local file_h = math.max(3, math.min(#state.files + 1, math.floor(avail * 0.25)))
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

  -- Focus the RHS (new code) window
  vim.api.nvim_set_current_win(state.diff_rhs_win)
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
  M._highlight_active_file()

  -- Move file list cursor to match
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_set_cursor, state.win, { file_idx, 0 })
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
  M._git_show(state.base_sha, prev_path, function(content)
    base_content = content
    on_ready()
  end)

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
  state.pr = nil
  state.current_file_idx = nil
end

return M
