local fetch = require("plz.dashboard.fetch")
local render = require("plz.dashboard.render")
local ado = require("plz.ado")

local M = {}

local ns = vim.api.nvim_create_namespace("plz_dashboard")
local sel_ns = vim.api.nvim_create_namespace("plz_dashboard_sel")

-- Header: tab bar + border + filter + border + column header + border = 6 lines
local HEADER_LINES = 6

local state = {
  tab_idx = 1,
  prs = {},
  list_buf = nil,
  list_win = nil,
  autocmd_id = nil,
  ado_cache = {}, -- keyed by work item ID
  prev_buf = nil, -- buffer to restore on close
  filter_overrides = {}, -- per-tab session filter overrides
  repo_name = nil, -- "owner/repo" fetched on open
  last_fetched = nil, -- os.time() of last PR list fetch
  editing_filter = false,
  filter_buf = nil, -- 1-line scratch buffer for filter editing
  fetch_gen = 0, -- generation counter to ignore stale fetch callbacks
  current_limit = nil, -- current fetch limit (for load-more)
  has_more = false, -- true when result count == limit (more may exist)
}

--- Compute column layout for the current window width.
local function get_cols()
  local win_w = 90
  if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
    win_w = vim.api.nvim_win_get_width(state.list_win)
  end
  return render.compute_columns(win_w)
end

--- Helper to set buffer lines (full replace).
local function set_buf_lines(buf, lines)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

--- Helper to replace lines from `start_row` (0-indexed) onwards.
local function set_buf_lines_from(buf, start_row, lines)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, start_row, -1, false, lines)
  vim.bo[buf].modifiable = false
end

--- Render the header into the buffer (tab bar + borders + column headers).
--- Only called once on open and when tab changes (to update active tab highlight).
function M._write_header()
  if not state.list_buf or not vim.api.nvim_buf_is_valid(state.list_buf) then return end

  local cols = get_cols()
  local lines = {}
  local all_regions = {}

  local win_w = state.list_win and vim.api.nvim_win_is_valid(state.list_win)
    and vim.api.nvim_win_get_width(state.list_win) or 90
  local border = string.rep("─", win_w)

  local tab_text, tab_regions = render.tab_line(fetch.get_sections(), state.tab_idx)
  lines[1] = tab_text
  all_regions[1] = tab_regions

  lines[2] = border
  all_regions[2] = { { 0, #border, "PlzBorder" } }

  -- Filter line
  local filter_text, filter_regions = render.filter_line(M._get_filter())
  lines[3] = filter_text
  all_regions[3] = filter_regions

  lines[4] = border
  all_regions[4] = { { 0, #border, "PlzBorder" } }

  local header_text, header_regions = render.header_line(cols)
  lines[5] = header_text
  all_regions[5] = header_regions

  lines[6] = border
  all_regions[6] = { { 0, #border, "PlzBorder" } }

  vim.bo[state.list_buf].modifiable = true
  local total = vim.api.nvim_buf_line_count(state.list_buf)
  if total < HEADER_LINES then
    vim.api.nvim_buf_set_lines(state.list_buf, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(state.list_buf, 0, HEADER_LINES, false, lines)
  end
  vim.bo[state.list_buf].modifiable = false

  -- Apply header highlights
  render.clear(state.list_buf)
  for i, regions in ipairs(all_regions) do
    render.apply_regions(state.list_buf, i - 1, regions)
  end
end

--- Format a relative time string from an os.time() timestamp.
local function relative_ago(ts)
  if not ts then return "" end
  local diff = os.difftime(os.time(), ts)
  if diff < 60 then return "Updated just now"
  elseif diff < 3600 then return "Updated ~" .. math.floor(diff / 60) .. "m ago"
  elseif diff < 86400 then return "Updated ~" .. math.floor(diff / 3600) .. "h ago"
  else return "Updated ~" .. math.floor(diff / 86400) .. "d ago"
  end
end

--- Statusline expression evaluated on every redraw (keeps "Updated" time fresh).
function _G.PlzDashboardStatusLine()
  local repo = state.repo_name or ""
  local left = "%#PlzStatusPillIcon# \xef\x93\x89 %#PlzStatusPill# plz %#PlzStatusLine#"
  if repo ~= "" then
    left = left .. "%#PlzStatusRepo# \xef\x90\x81 " .. repo:gsub("%%", "%%%%") .. " %#PlzStatusLine#"
  end
  if #state.prs > 0 and state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
    local row = vim.api.nvim_win_get_cursor(state.list_win)[1]
    local idx = math.ceil((row - HEADER_LINES) / 3)
    if idx >= 1 and idx <= #state.prs then
      local pr = state.prs[idx]
      local num = pr and pr.number or ""
      left = left .. "%#PlzStatusPill# \xef\x90\x87 " .. num .. " %#PlzStatusRepo# " .. idx .. " of " .. #state.prs .. " %#PlzStatusLine#"
    end
  end
  local right = relative_ago(state.last_fetched)
  if right ~= "" then
    right = "%#PlzStatusRepo# " .. right .. " "
  end
  return left .. "%=" .. right
end

--- Update the statusline on the dashboard window.
function M._update_statusline()
  if not state.list_win or not vim.api.nvim_win_is_valid(state.list_win) then return end
  vim.wo[state.list_win].statusline = "%{%v:lua.PlzDashboardStatusLine()%}"
end

--- Open the plz dashboard.
function M.open()
  state.prev_buf = vim.api.nvim_get_current_buf()

  state.list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.list_buf].buftype = "nofile"
  vim.bo[state.list_buf].bufhidden = "wipe"
  vim.bo[state.list_buf].filetype = "plz-dashboard"

  -- Take over current window
  state.list_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.list_win, state.list_buf)

  vim.wo[state.list_win].number = false
  vim.wo[state.list_win].relativenumber = false
  vim.wo[state.list_win].signcolumn = "no"
  vim.wo[state.list_win].wrap = false
  vim.wo[state.list_win].foldcolumn = "0"
  vim.wo[state.list_win].statuscolumn = ""
  vim.wo[state.list_win].cursorline = false
  M._update_statusline()

  -- Highlight both rows of the selected PR on cursor movement
  state.autocmd_id = vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = state.list_buf,
    callback = function() M._update_selection() end,
  })

  M._setup_keymaps()

  M._fetch_tab(state.tab_idx)
  M._fetch_repo_name()
end

--- Fetch the repository name for the statusline.
function M._fetch_repo_name()
  if state.repo_name then
    M._update_statusline()
    return
  end
  -- Use git remote to avoid extra gh API call
  vim.system({ "git", "remote", "get-url", "origin" }, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code == 0 and obj.stdout then
        -- Parse owner/repo from remote URL
        local owner, repo = obj.stdout:match("github%.com[:/]([^/]+)/([^/%.%s]+)")
        if owner and repo then
          state.repo_name = owner .. "/" .. repo
        end
      end
      M._update_statusline()
    end)
  end)
end

--- Fetch and display PRs for the given tab, respecting any filter override.
function M._fetch_tab(idx)
  M._fetch_tab_with_filter(idx)
end

--- Batch-fetch ADO work items for all PRs that have AB# references.
function M._fetch_ado_batch()
  for _, pr in ipairs(state.prs) do
    local body = (pr.body or ""):gsub("<!%-%-.-%-%->", "")
    local ab_id = ((pr.title or ""):match("AB#(%d+)") or body:match("AB#(%d+)"))
    if ab_id and not state.ado_cache[ab_id] then
      ado.fetch_work_item(ab_id, function(item, _err)
        if item then
          state.ado_cache[ab_id] = item
        else
          state.ado_cache[ab_id] = { not_found = true }
        end
        M._render_rows()
      end)
    end
  end
end

--- Render PR rows below the header.
function M._render_rows()
  if not state.list_buf or not vim.api.nvim_buf_is_valid(state.list_buf) then return end

  local cols = get_cols()
  local lines = {}
  local all_regions = {}

  if #state.prs == 0 then
    lines[1] = ""
    lines[2] = "  No PRs found"
    all_regions[1] = {}
    all_regions[2] = { { 0, #lines[2], "PlzFaint" } }
  else
    for _, pr in ipairs(state.prs) do
      local body = (pr.body or ""):gsub("<!%-%-.-%-%->", "")
      local ab_id = ((pr.title or ""):match("AB#(%d+)") or body:match("AB#(%d+)"))
      local ado_item = ab_id and state.ado_cache[ab_id] or nil
      local row_text, row_regions = render.format_row(pr, cols, ado_item)
      table.insert(lines, row_text)
      table.insert(all_regions, row_regions)
      local detail_text, detail_regions = render.format_detail_row(pr, ado_item)
      table.insert(lines, detail_text)
      table.insert(all_regions, detail_regions)
      local branch_text, branch_regions = render.format_branch_row(pr)
      table.insert(lines, branch_text)
      table.insert(all_regions, branch_regions)
    end
    if state.has_more then
      local more = "  ── Load more (L) ──"
      table.insert(lines, "")
      table.insert(all_regions, {})
      table.insert(lines, more)
      table.insert(all_regions, { { 0, #more, "PlzFaint" } })
    end
  end

  -- Replace only lines after header
  set_buf_lines_from(state.list_buf, HEADER_LINES, lines)

  -- Re-apply all highlights (header + rows)
  M._write_header()
  for i, regions in ipairs(all_regions) do
    render.apply_regions(state.list_buf, HEADER_LINES + i - 1, regions)
  end

  -- Position cursor on first PR
  if #state.prs > 0 then
    pcall(vim.api.nvim_win_set_cursor, state.list_win, { HEADER_LINES + 1, 0 })
  end
  M._update_selection()
end

--- Highlight all rows of the currently selected PR.
function M._update_selection()
  if not state.list_buf or not vim.api.nvim_buf_is_valid(state.list_buf) then return end
  vim.api.nvim_buf_clear_namespace(state.list_buf, sel_ns, 0, -1)
  if not state.list_win or not vim.api.nvim_win_is_valid(state.list_win) then return end
  local row = vim.api.nvim_win_get_cursor(state.list_win)[1]
  local pr_idx = math.ceil((row - HEADER_LINES) / 3)
  if pr_idx < 1 or pr_idx > #state.prs then return end
  -- All 3 rows for this PR (0-indexed)
  local base = HEADER_LINES + (pr_idx - 1) * 3
  for i = 0, 2 do
    vim.api.nvim_buf_set_extmark(state.list_buf, sel_ns, base + i, 0, {
      end_row = base + i + 1,
      hl_group = "CursorLine",
      hl_eol = true,
      priority = 50,
    })
  end
end

--- Set up dashboard keybindings.
function M._setup_keymaps()
  local buf = state.list_buf
  local opts = { buffer = buf, nowait = true }

  for i = 1, #fetch.get_sections() do
    vim.keymap.set("n", tostring(i), function()
      M._fetch_tab(i)
    end, vim.tbl_extend("force", opts, { desc = fetch.get_sections()[i].name }))
  end

  vim.keymap.set("n", "<Tab>", function()
    M._fetch_tab((state.tab_idx % #fetch.get_sections()) + 1)
  end, vim.tbl_extend("force", opts, { desc = "Next tab" }))

  vim.keymap.set("n", "<S-Tab>", function()
    M._fetch_tab(((state.tab_idx - 2) % #fetch.get_sections()) + 1)
  end, vim.tbl_extend("force", opts, { desc = "Previous tab" }))

  vim.keymap.set("n", "j", function()
    local row = vim.api.nvim_win_get_cursor(state.list_win)[1]
    local max_row = HEADER_LINES + #state.prs * 3
    local new_row = math.min(row + 3, max_row - 2)
    -- Clamp to primary rows (first of each 3-line group)
    local offset = (new_row - HEADER_LINES - 1) % 3
    if offset ~= 0 then new_row = new_row - offset end
    pcall(vim.api.nvim_win_set_cursor, state.list_win, { new_row, 0 })
  end, vim.tbl_extend("force", opts, { desc = "Next PR" }))

  vim.keymap.set("n", "k", function()
    local row = vim.api.nvim_win_get_cursor(state.list_win)[1]
    local new_row = math.max(row - 3, HEADER_LINES + 1)
    -- Clamp to primary rows (first of each 3-line group)
    local offset = (new_row - HEADER_LINES - 1) % 3
    if offset ~= 0 then new_row = new_row - offset end
    pcall(vim.api.nvim_win_set_cursor, state.list_win, { new_row, 0 })
  end, vim.tbl_extend("force", opts, { desc = "Previous PR" }))

  vim.keymap.set("n", "o", function()
    local pr = M._get_selected_pr()
    if pr and pr.url then
      vim.ui.open(pr.url)
    end
  end, vim.tbl_extend("force", opts, { desc = "Open in browser" }))

  vim.keymap.set("n", "r", function()
    M._fetch_tab(state.tab_idx)
  end, vim.tbl_extend("force", opts, { desc = "Refresh" }))

  vim.keymap.set("n", "L", function()
    if state.has_more then
      local new_limit = state.current_limit + fetch.PAGE_SIZE
      M._fetch_tab_with_filter(state.tab_idx, new_limit)
    end
  end, vim.tbl_extend("force", opts, { desc = "Load more" }))

  vim.keymap.set("n", "/", function()
    M._edit_filter()
  end, vim.tbl_extend("force", opts, { desc = "Edit filter" }))

  vim.keymap.set("n", "q", function()
    M.close()
  end, vim.tbl_extend("force", opts, { desc = "Close dashboard" }))

  vim.keymap.set("n", "<CR>", function()
    local pr = M._get_selected_pr()
    if pr then
      local review = require("plz.review")
      review.open(pr)
    end
  end, vim.tbl_extend("force", opts, { desc = "Open PR review" }))

  local help_lines = {
    "plz dashboard",
    "",
    "j/k       navigate PRs",
    "<CR>      open PR for review",
    "o         open in browser",
    "r         refresh",
    "L         load more",
    "/         edit filter",
    "1-" .. #fetch.get_sections() .. "       switch tab",
    "<Tab>     next tab",
    "<S-Tab>   previous tab",
    "q         close",
    "?         toggle this help",
  }
  vim.keymap.set("n", "?", function()
    require("plz.help").toggle(help_lines)
  end, vim.tbl_extend("force", opts, { desc = "Toggle help" }))
end

--- Get the active filter string for the current tab.
function M._get_filter()
  return state.filter_overrides[state.tab_idx] or fetch.get_sections()[state.tab_idx].filter
end

--- Enter filter editing mode.
function M._edit_filter()
  if state.editing_filter then return end
  state.editing_filter = true

  local current = M._get_filter()
  local win_w = state.list_win and vim.api.nvim_win_is_valid(state.list_win)
    and vim.api.nvim_win_get_width(state.list_win) or 90

  -- Create a 1-line scratch buffer for editing
  state.filter_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.filter_buf].buftype = "nofile"
  vim.bo[state.filter_buf].bufhidden = "wipe"

  -- Open as a floating window over the filter line (row 2, 0-indexed)
  local filter_win = vim.api.nvim_open_win(state.filter_buf, true, {
    relative = "win",
    win = state.list_win,
    row = 2,
    col = 0,
    width = win_w,
    height = 1,
    style = "minimal",
    border = "none",
  })
  vim.wo[filter_win].winhl = "Normal:PlzFaint"

  -- Pre-fill with current filter
  vim.api.nvim_buf_set_lines(state.filter_buf, 0, -1, false, { " " .. current })
  vim.cmd("startinsert!")

  -- Enter confirms, Esc cancels
  local function close_filter(apply)
    if not state.editing_filter then return end
    state.editing_filter = false
    vim.cmd("stopinsert")

    if apply then
      local new_filter = vim.trim(vim.api.nvim_buf_get_lines(state.filter_buf, 0, 1, false)[1] or "")
      if new_filter ~= "" then
        state.filter_overrides[state.tab_idx] = new_filter
      end
    end

    if vim.api.nvim_win_is_valid(filter_win) then
      pcall(vim.api.nvim_win_close, filter_win, true)
    end
    state.filter_buf = nil

    if apply then
      M._fetch_tab_with_filter(state.tab_idx)
    else
      M._write_header()
    end
  end

  vim.keymap.set("i", "<CR>", function() close_filter(true) end, { buffer = state.filter_buf })
  vim.keymap.set("i", "<Esc>", function() close_filter(false) end, { buffer = state.filter_buf })
  vim.keymap.set("n", "<Esc>", function() close_filter(false) end, { buffer = state.filter_buf })
end

--- Fetch using the current (possibly overridden) filter.
--- @param idx number Tab index
--- @param limit? number Override fetch limit (for load-more)
function M._fetch_tab_with_filter(idx, limit)
  state.tab_idx = idx
  state.current_limit = limit or fetch.PAGE_SIZE
  state.has_more = false

  if limit then
    -- Load-more: replace the "Load more" footer with loading indicator, keep existing rows
    local total = vim.api.nvim_buf_line_count(state.list_buf)
    if total > HEADER_LINES + #state.prs * 3 then
      vim.bo[state.list_buf].modifiable = true
      vim.api.nvim_buf_set_lines(state.list_buf, HEADER_LINES + #state.prs * 3, -1, false, { "", "  Loading more..." })
      vim.bo[state.list_buf].modifiable = false
    end
  else
    state.prs = {}
    M._write_header()
    set_buf_lines_from(state.list_buf, HEADER_LINES, { "", "  Loading..." })
  end

  state.fetch_gen = state.fetch_gen + 1
  local gen = state.fetch_gen
  local filter = M._get_filter()
  local args = fetch.args_from_filter(filter, state.current_limit)
  local gh = require("plz.gh")
  gh.run(args, function(prs, err)
    if gen ~= state.fetch_gen then return end -- stale callback
    if err then
      local err_msg = err:gsub("\n", " ")
      set_buf_lines_from(state.list_buf, HEADER_LINES, { "", "  Error: " .. err_msg })
      return
    end
    state.prs = prs or {}
    state.has_more = #state.prs >= state.current_limit
    state.last_fetched = os.time()
    M._render_rows()
    M._fetch_ado_batch()
    M._update_statusline()
  end)
end

--- Get the PR under the cursor.
function M._get_selected_pr()
  if not state.list_win or not vim.api.nvim_win_is_valid(state.list_win) then return nil end
  local row = vim.api.nvim_win_get_cursor(state.list_win)[1]
  local pr_idx = math.ceil((row - HEADER_LINES) / 3)
  return state.prs[pr_idx]
end

--- Close the dashboard.
function M.close()
  if state.autocmd_id then
    pcall(vim.api.nvim_del_autocmd, state.autocmd_id)
    state.autocmd_id = nil
  end

  if state.prev_buf and vim.api.nvim_buf_is_valid(state.prev_buf) then
    if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
      vim.api.nvim_win_set_buf(state.list_win, state.prev_buf)
    end
  end

  if state.list_buf and vim.api.nvim_buf_is_valid(state.list_buf) then
    pcall(vim.api.nvim_buf_delete, state.list_buf, { force = true })
  end

  state.list_buf = nil
  state.list_win = nil
  state.prev_buf = nil
  state.prs = {}
end

return M
