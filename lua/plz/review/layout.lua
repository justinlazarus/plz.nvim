local M = {}

--- Reference to the shared review state table, set via M.setup().
local state

--- Store a reference to shared state.
--- @param state_ref table  The shared review state table
function M.setup(state_ref)
  state = state_ref
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
  -- C1 top: info
  local c1_top = vim.api.nvim_create_buf(false, true)
  vim.bo[c1_top].buftype = "nofile"
  vim.bo[c1_top].bufhidden = "hide"

  -- C1 bottom: commits
  local c1_bot = vim.api.nvim_create_buf(false, true)
  vim.bo[c1_bot].buftype = "nofile"
  vim.bo[c1_bot].bufhidden = "hide"

  -- C2 top: placeholder
  local c2_top = vim.api.nvim_create_buf(false, true)
  vim.bo[c2_top].buftype = "nofile"
  vim.bo[c2_top].bufhidden = "hide"
  vim.bo[c2_top].modifiable = true
  vim.api.nvim_buf_set_lines(c2_top, 0, -1, false, { "  Collection 2 — coming soon" })
  vim.bo[c2_top].modifiable = false

  -- C3 top: file list
  local c3_top = files.create_buf()

  state.collections = {
    [1] = { top_buf = c1_top, bottom_buf = c1_bot, cursor = nil },
    [2] = { top_buf = c2_top, bottom_buf = nil, cursor = nil },
    [3] = { top_buf = c3_top, bottom_buf = nil, cursor = nil },
  }

  -- Start with Collection 3 (file list) — matches current UX
  state.active_collection = 3
  vim.api.nvim_win_set_buf(state.top_win, c3_top)
  set_win_opts(state.top_win, interactive)

  -- Create bottom window (empty for C3 initially — diff fills it on demand)
  vim.cmd("botright split")
  state.bottom_win = vim.api.nvim_get_current_win()
  -- Create a scratch buffer to hold the bottom window open
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = "nofile"
  vim.bo[scratch].bufhidden = "wipe"
  vim.api.nvim_win_set_buf(state.bottom_win, scratch)
  set_win_opts(state.bottom_win, no_interact)

  -- Even split
  vim.cmd("wincmd =")

  -- Focus top window (file list)
  vim.api.nvim_set_current_win(state.top_win)

  M.sync_aliases()

  -- Set keymaps on all collection buffers
  M.set_collection_keymaps(c1_top)
  M.set_collection_keymaps(c1_bot)
  M.set_collection_keymaps(c2_top)
  M.set_collection_keymaps(c3_top)

  -- Render
  review._render()
  review._setup_keymaps()

  if #state.files > 0 then
    pcall(vim.api.nvim_win_set_cursor, state.top_win, { 1, 0 })
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
    -- C1: bottom shows commits
    vim.cmd("botright split")
    state.bottom_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.bottom_win, c.bottom_buf)
    set_win_opts(state.bottom_win, interactive)
  else
    -- C2: single pane, no bottom needed — but create one for consistency
    vim.cmd("botright split")
    state.bottom_win = vim.api.nvim_get_current_win()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].buftype = "nofile"
    vim.bo[scratch].bufhidden = "wipe"
    vim.api.nvim_win_set_buf(state.bottom_win, scratch)
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
    if id == 3 then
      set_win_opts(state.top_win, interactive)
    else
      set_win_opts(state.top_win, no_interact)
    end
  end

  -- Recreate bottom
  create_bottom_for(id)

  M.sync_aliases()

  -- Render appropriate content
  if id == 1 then
    summary.render_info_to(c.top_buf, state.top_win)
    summary.render_commits_to(c.bottom_buf, state.bottom_win)
    -- Focus bottom (commits) for interactivity
    if state.bottom_win and vim.api.nvim_win_is_valid(state.bottom_win) then
      vim.api.nvim_set_current_win(state.bottom_win)
    end
  elseif id == 3 then
    -- File list is already the buf; just re-render
    local files = require("plz.review.files")
    files.render()
  end
  -- C2: placeholder already set

  restore_cursor(id)

  -- Focus top window for C3
  if id == 3 and state.top_win and vim.api.nvim_win_is_valid(state.top_win) then
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
