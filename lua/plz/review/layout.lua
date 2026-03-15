local M = {}

--- Reference to the shared review state table, set via M.setup().
local state

--- Store a reference to shared state.
--- @param state_ref table  The shared review state table
function M.setup(state_ref)
  state = state_ref
end

--- Statusline expression evaluated on every redraw (keeps "Updated" time fresh).
function _G.PlzReviewStatusLine()
  local repo = ""
  if state and state.pr and state.pr.url then
    local owner, name = state.pr.url:match("github%.com/([^/]+)/([^/]+)")
    if owner and name then repo = owner .. "/" .. name end
  end
  local left = "%#PlzStatusPillIcon# \xef\x93\x89 %#PlzStatusPill# plz %#PlzStatusLine#"
  if repo ~= "" then
    left = left .. "%#PlzStatusRepo# \xef\x90\x81 " .. repo:gsub("%%", "%%%%") .. " %#PlzStatusLine#"
  end
  if state then
    local ac = state.active_collection or 0
    if ac == 1 and state.commits and #state.commits > 0 then
      local idx = 1
      if state.top_win and vim.api.nvim_win_is_valid(state.top_win) then
        local row = vim.api.nvim_win_get_cursor(state.top_win)[1]
        if row >= 1 and row <= #state.commits then idx = row end
      end
      local prnum = state.pr and state.pr.number or ""
      left = left .. "%#PlzStatusPill# \xef\x90\x87 " .. prnum .. " %#PlzStatusRepo# commit " .. idx .. " of " .. #state.commits .. " %#PlzStatusLine#"
    elseif ac == 2 and state.c2_items and #state.c2_items > 0 then
      local idx = 1
      if state.top_win and vim.api.nvim_win_is_valid(state.top_win) then
        local row = vim.api.nvim_win_get_cursor(state.top_win)[1]
        if row >= 1 and row <= #state.c2_items then idx = row end
      end
      local prnum = state.pr and state.pr.number or ""
      left = left .. "%#PlzStatusPill# \xef\x90\x87 " .. prnum .. " %#PlzStatusRepo# item " .. idx .. " of " .. #state.c2_items .. " %#PlzStatusLine#"
    elseif ac == 3 and state.files and #state.files > 0 then
      local idx = state.current_file_idx or 1
      if state.top_win and vim.api.nvim_win_is_valid(state.top_win) then
        local row = vim.api.nvim_win_get_cursor(state.top_win)[1]
        if row >= 1 and row <= #state.files then idx = row end
      end
      local prnum = state.pr and state.pr.number or ""
      left = left .. "%#PlzStatusPill# \xef\x90\x87 " .. prnum .. " %#PlzStatusRepo# file " .. idx .. " of " .. #state.files
      -- Viewed count
      local viewed_count = 0
      if state.viewed then
        for _, f in ipairs(state.files) do
          local path = f.filename or f.path or ""
          if state.viewed[path] then viewed_count = viewed_count + 1 end
        end
      end
      left = left .. "  " .. viewed_count .. " viewed"
      -- +/- totals
      local total_adds, total_dels = 0, 0
      for _, f in ipairs(state.files) do
        total_adds = total_adds + (f.additions or 0)
        total_dels = total_dels + (f.deletions or 0)
      end
      left = left .. " %#PlzStatusLine#"
      if total_adds > 0 or total_dels > 0 then
        left = left .. "%#PlzGreen#+" .. total_adds .. " %#PlzRed#-" .. total_dels .. " %#PlzStatusLine#"
      end
    end
  end
  local right = ""
  if state and state.last_fetched then
    local diff = os.difftime(os.time(), state.last_fetched)
    local ago
    if diff < 60 then ago = "just now"
    elseif diff < 3600 then ago = "~" .. math.floor(diff / 60) .. "m ago"
    elseif diff < 86400 then ago = "~" .. math.floor(diff / 3600) .. "h ago"
    else ago = "~" .. math.floor(diff / 86400) .. "d ago"
    end
    right = "%#PlzStatusRepo# Updated " .. ago .. " "
  end
  return left .. "%=" .. right
end

--- Return the plz statusline expression string for review windows.
function M.plz_statusline()
  return "%{%v:lua.PlzReviewStatusLine()%}"
end

--- Standard window options for non-interactive panels.
local no_interact = {
  number = false, relativenumber = false, signcolumn = "no",
  wrap = false, foldcolumn = "0", statuscolumn = "", cursorline = false,
}

--- Standard window options for interactive panels.
local interactive = {
  number = false, relativenumber = false, signcolumn = "no",
  wrap = false, foldcolumn = "0", statuscolumn = "", cursorline = true,
}

--- Apply a table of window options to a window.
local function set_win_opts(win, opts)
  for k, v in pairs(opts) do vim.wo[win][k] = v end
  vim.wo[win].statusline = M.plz_statusline()
end

--- Set collection-switching keymaps on a buffer.
function M.set_collection_keymaps(buf)
  local opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "<Tab>", function() M.cycle(1) end,
    vim.tbl_extend("force", opts, { desc = "Next collection" }))
  vim.keymap.set("n", "<S-Tab>", function() M.cycle(-1) end,
    vim.tbl_extend("force", opts, { desc = "Previous collection" }))
  for i = 1, 3 do
    vim.keymap.set("n", tostring(i), function() M.switch_to(i) end,
      vim.tbl_extend("force", opts, { desc = "Collection " .. i }))
  end
end

--- Sync collection handles to flat state aliases.
function M.sync_aliases()
  local ac = state.active_collection
  local c = state.collections[ac]
  if not c then return end

  -- Top window/buf: always the shared top_win, showing active collection's top_buf
  state.summary_buf = c.top_buf
  state.summary_win = state.top_win

  -- File list buffer is always C3's top_buf (for render/highlight calls)
  local c3 = state.collections[3]
  if c3 then
    state.buf = c3.top_buf
  end

  -- win alias: only set when C3 is active (file list is visible in top_win)
  if ac == 3 then
    state.win = state.top_win
  else
    state.win = nil
  end
end

--- Create initial layout: tabnew, top/bottom windows, all persistent buffers.
function M.create_initial()
  local review = require("plz.review")
  local files = require("plz.review.files")
  local summary = require("plz.review.summary")

  vim.cmd("tabnew")

  -- Top window (will hold whichever collection's top_buf is active)
  state.top_win = vim.api.nvim_get_current_win()

  -- Create all persistent buffers
  -- C1 top: commits
  local c1_top = vim.api.nvim_create_buf(false, true)
  vim.bo[c1_top].buftype = "nofile"
  vim.bo[c1_top].bufhidden = "hide"
  vim.bo[c1_top].filetype = "plz-review"

  -- C1 bottom: PR detail/info
  local c1_bot = vim.api.nvim_create_buf(false, true)
  vim.bo[c1_bot].buftype = "nofile"
  vim.bo[c1_bot].bufhidden = "hide"
  vim.bo[c1_bot].filetype = "plz-review"

  -- C2 top: review list
  local c2_top = vim.api.nvim_create_buf(false, true)
  vim.bo[c2_top].buftype = "nofile"
  vim.bo[c2_top].bufhidden = "hide"
  vim.bo[c2_top].filetype = "plz-review"

  -- C2 bottom: review threads
  local c2_bot = vim.api.nvim_create_buf(false, true)
  vim.bo[c2_bot].buftype = "nofile"
  vim.bo[c2_bot].bufhidden = "hide"
  vim.bo[c2_bot].filetype = "plz-review"

  -- C3 top: file list
  local c3_top = files.create_buf()

  state.collections = {
    [1] = { top_buf = c1_top, bottom_buf = c1_bot, cursor = nil },
    [2] = { top_buf = c2_top, bottom_buf = c2_bot, cursor = nil },
    [3] = { top_buf = c3_top, bottom_buf = nil, cursor = nil },
  }

  -- Start with Collection 1 (PR summary / commits)
  state.active_collection = 1
  vim.api.nvim_win_set_buf(state.top_win, c1_top)
  set_win_opts(state.top_win, no_interact)

  -- Create bottom window for C1 (commits)
  vim.cmd("botright split")
  state.bottom_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.bottom_win, c1_bot)
  set_win_opts(state.bottom_win, interactive)

  -- Even split
  vim.cmd("wincmd =")

  -- Focus top window (PR detail) on initial load
  vim.api.nvim_set_current_win(state.top_win)

  M.sync_aliases()

  -- Set keymaps on all collection buffers
  M.set_collection_keymaps(c1_top)
  M.set_collection_keymaps(c1_bot)
  M.set_collection_keymaps(c2_top)
  M.set_collection_keymaps(c2_bot)
  M.set_collection_keymaps(c3_top)

  -- Render
  review._render()
  review._setup_keymaps()
  M.resize_top_to_content()
end

--- Resize the top window to fit its content, capped at 50% of total height.
function M.resize_top_to_content()
  if not state.top_win or not vim.api.nvim_win_is_valid(state.top_win) then return end
  -- Find a bottom window to compute total available height
  local bottom_win = state.bottom_win
  if not bottom_win or not vim.api.nvim_win_is_valid(bottom_win) then
    bottom_win = state.diff_lhs_win
  end
  if not bottom_win or not vim.api.nvim_win_is_valid(bottom_win) then return end

  local top_h = vim.api.nvim_win_get_height(state.top_win)
  local bot_h = vim.api.nvim_win_get_height(bottom_win)
  local total = top_h + bot_h
  local ratio = (state.active_collection == 3) and 0.2 or 0.5
  local max_top = math.floor(total * ratio)
  local content_lines = vim.api.nvim_buf_line_count(
    vim.api.nvim_win_get_buf(state.top_win))
  -- Winbar occupies 1 row of window height, add it if present
  local winbar = vim.wo[state.top_win].winbar
  local needed = content_lines + ((winbar and winbar ~= "") and 1 or 0)
  local target = math.min(max_top, needed)
  if target < 1 then target = 1 end
  if target ~= top_h then
    vim.api.nvim_win_set_height(state.top_win, target)
  end
end

--- Save cursor position for the current collection.
local function save_cursor()
  local ac = state.active_collection
  local c = state.collections[ac]
  if not c then return end
  if state.top_win and vim.api.nvim_win_is_valid(state.top_win) then
    c.cursor = vim.api.nvim_win_get_cursor(state.top_win)
  end
end

--- Restore cursor position for a collection.
local function restore_cursor(id)
  local c = state.collections[id]
  if not c or not c.cursor then return end
  if state.top_win and vim.api.nvim_win_is_valid(state.top_win) then
    pcall(vim.api.nvim_win_set_cursor, state.top_win, c.cursor)
  end
end

--- Close all bottom-area windows (diff splits, single bottom).
local function close_bottom_windows()
  -- Close diff windows if open
  for _, key in ipairs({ "diff_lhs_win", "diff_rhs_win" }) do
    if state[key] and vim.api.nvim_win_is_valid(state[key]) then
      pcall(vim.api.nvim_win_close, state[key], true)
      state[key] = nil
    end
  end
  -- Close the generic bottom window
  if state.bottom_win and vim.api.nvim_win_is_valid(state.bottom_win) then
    pcall(vim.api.nvim_win_close, state.bottom_win, true)
    state.bottom_win = nil
  end
end

--- Recreate the bottom window area for a given collection.
local function create_bottom_for(id)
  local c = state.collections[id]
  if not c then return end

  -- Focus top window, split below
  vim.api.nvim_set_current_win(state.top_win)

  if id == 3 then
    -- C3: bottom is vsplit diff area — created on demand by _create_diff_split
    -- Just create a placeholder bottom window
    vim.cmd("botright split")
    state.bottom_win = vim.api.nvim_get_current_win()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].buftype = "nofile"
    vim.bo[scratch].bufhidden = "wipe"
    vim.api.nvim_win_set_buf(state.bottom_win, scratch)
    set_win_opts(state.bottom_win, no_interact)
  elseif id == 1 then
    -- C1: bottom shows PR detail
    vim.cmd("botright split")
    state.bottom_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.bottom_win, c.bottom_buf)
    set_win_opts(state.bottom_win, no_interact)
  elseif id == 2 then
    -- C2: bottom shows review threads
    vim.cmd("botright split")
    state.bottom_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.bottom_win, c.bottom_buf)
    set_win_opts(state.bottom_win, no_interact)
  end

  -- Even split
  vim.cmd("wincmd =")
end

--- Switch to a specific collection by id.
--- @param id number  Collection id (1, 2, or 3)
function M.switch_to(id)
  if not state.collections or not state.collections[id] then return end
  if id == state.active_collection then return end

  local summary = require("plz.review.summary")
  local review = require("plz.review")

  save_cursor()

  -- Close bottom windows
  close_bottom_windows()

  -- Clean up diff buffers if leaving C3
  if state.active_collection == 3 then
    -- Bump generation to invalidate any in-flight diff callbacks
    state.diff_gen = (state.diff_gen or 0) + 1
    review._cleanup_old_bufs(state.diff_lhs_buf, state.diff_rhs_buf)
    state.diff_lhs_buf = nil
    state.diff_rhs_buf = nil
    state.diff_lhs_win = nil
    state.diff_rhs_win = nil
    review._clear_diff_status()
    state.current_file_idx = nil
    -- Remove active file highlight
    local c3 = state.collections[3]
    if c3 and c3.top_buf and vim.api.nvim_buf_is_valid(c3.top_buf) then
      local ns_active = vim.api.nvim_create_namespace("plz_review_active")
      vim.api.nvim_buf_clear_namespace(c3.top_buf, ns_active, 0, -1)
    end
  end

  state.active_collection = id
  local c = state.collections[id]

  -- Swap top buffer
  if state.top_win and vim.api.nvim_win_is_valid(state.top_win) then
    vim.api.nvim_win_set_buf(state.top_win, c.top_buf)
    set_win_opts(state.top_win, interactive)
  end

  -- Recreate bottom
  create_bottom_for(id)

  M.sync_aliases()

  -- Render appropriate content
  if id == 1 then
    summary.render_commits_to(c.top_buf, state.top_win)
    summary.render_detail_to(c.bottom_buf, state.bottom_win)
  elseif id == 3 then
    -- File list is already the buf; just re-render
    local files = require("plz.review.files")
    files.render()
    -- Auto-open first diff if none selected yet, keep focus on file list
    if not state.current_file_idx and #state.files > 0 then
      state._suppress_diff_focus = true
      local change_detail = require("plz.review.collections.change_detail")
      change_detail.open_diff(1)
    end
  elseif id == 2 then
    local review_detail = require("plz.review.collections.review_detail")
    review_detail.render_reviews(c.top_buf, state.top_win)
    -- Show first item's detail if available
    if state.c2_items and #state.c2_items > 0 then
      state.selected_review_idx = state.selected_review_idx or 1
      review_detail.render_threads(c.bottom_buf, state.bottom_win, state.selected_review_idx)
    end
    -- Focus top (review list) for interactivity
    if state.top_win and vim.api.nvim_win_is_valid(state.top_win) then
      vim.api.nvim_set_current_win(state.top_win)
    end
  end

  M.resize_top_to_content()

  restore_cursor(id)

  -- Always focus top window
  if state.top_win and vim.api.nvim_win_is_valid(state.top_win) then
    vim.api.nvim_set_current_win(state.top_win)
  end
end

--- Cycle collections with wraparound.
--- @param dir number  1 for forward, -1 for backward
function M.cycle(dir)
  local next_id = ((state.active_collection - 1 + dir) % 3) + 1
  M.switch_to(next_id)
end

return M
