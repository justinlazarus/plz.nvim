local fetch = require("plz.dashboard.fetch")
local render = require("plz.dashboard.render")
local ado = require("plz.ado")

local M = {}

local ns = vim.api.nvim_create_namespace("plz_dashboard")

-- Header: tab bar + border + column header + border = 4 lines
local HEADER_LINES = 4

local state = {
  tab_idx = 1,
  prs = {},
  list_buf = nil,
  preview_buf = nil,
  list_win = nil,
  preview_win = nil,
  autocmd_id = nil,
  ado_cache = {}, -- keyed by work item ID
  prev_buf = nil, -- buffer to restore on close
}

--- Compute title column width based on window width.
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

  local tab_text, tab_regions = render.tab_line(fetch.sections, state.tab_idx)
  lines[1] = tab_text
  all_regions[1] = tab_regions

  local win_w = state.list_win and vim.api.nvim_win_is_valid(state.list_win)
    and vim.api.nvim_win_get_width(state.list_win) or 90
  lines[2] = string.rep("─", win_w)
  all_regions[2] = { { 0, #lines[2], "PlzBorder" } }

  local header_text, header_regions = render.header_line(cols)
  lines[3] = header_text
  all_regions[3] = header_regions

  lines[4] = string.rep("─", win_w)
  all_regions[4] = { { 0, #lines[4], "PlzBorder" } }

  -- Replace only the first 4 lines
  vim.bo[state.list_buf].modifiable = true
  local total = vim.api.nvim_buf_line_count(state.list_buf)
  if total < HEADER_LINES then
    -- Buffer is fresh/empty — write header + empty body
    vim.api.nvim_buf_set_lines(state.list_buf, 0, -1, false, lines)
  else
    -- Only replace header lines, keep body intact
    vim.api.nvim_buf_set_lines(state.list_buf, 0, HEADER_LINES, false, lines)
  end
  vim.bo[state.list_buf].modifiable = false

  -- Apply header highlights
  render.clear(state.list_buf)
  for i, regions in ipairs(all_regions) do
    render.apply_regions(state.list_buf, i - 1, regions)
  end
end

--- Open the plz dashboard.
function M.open()
  state.prev_buf = vim.api.nvim_get_current_buf()

  state.list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.list_buf].buftype = "nofile"
  vim.bo[state.list_buf].bufhidden = "wipe"
  vim.bo[state.list_buf].filetype = "plz-dashboard"

  state.preview_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.preview_buf].buftype = "nofile"
  vim.bo[state.preview_buf].bufhidden = "wipe"

  -- List window (top)
  state.list_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.list_win, state.list_buf)

  -- Preview window (bottom)
  vim.cmd("botright split")
  state.preview_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.preview_win, state.preview_buf)
  vim.api.nvim_win_set_height(state.preview_win, 12)

  vim.api.nvim_set_current_win(state.list_win)

  for _, win in ipairs({ state.list_win, state.preview_win }) do
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = false
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].statuscolumn = ""
  end
  vim.wo[state.list_win].cursorline = true
  vim.wo[state.preview_win].cursorline = false

  M._setup_keymaps()

  state.autocmd_id = vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = state.list_buf,
    callback = function() M._update_preview() end,
  })

  M._fetch_tab(state.tab_idx)
end

--- Fetch and display PRs for the given tab.
function M._fetch_tab(idx)
  state.tab_idx = idx
  state.prs = {}

  -- Write/update the header (updates active tab highlight)
  M._write_header()

  -- Replace body (lines below header) with "Loading..."
  set_buf_lines_from(state.list_buf, HEADER_LINES, { "", "  Loading..." })
  set_buf_lines(state.preview_buf, {})

  fetch.fetch_section(idx, function(prs, err)
    if err then
      set_buf_lines_from(state.list_buf, HEADER_LINES, { "", "  Error: " .. err })
      return
    end
    state.prs = prs or {}
    M._render_rows()
    M._fetch_ado_batch()
    M._update_preview()
  end)
end

--- Batch-fetch ADO work items for all PRs that have AB# references.
function M._fetch_ado_batch()
  for _, pr in ipairs(state.prs) do
    local ab_id = ((pr.title or ""):match("AB#(%d+)") or (pr.body or ""):match("AB#(%d+)"))
    if ab_id and not state.ado_cache[ab_id] then
      ado.fetch_work_item(ab_id, function(item, _err)
        if item then
          state.ado_cache[ab_id] = item
          -- Re-render rows to show fetched ADO data
          M._render_rows()
        end
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
      local ab_id = ((pr.title or ""):match("AB#(%d+)") or (pr.body or ""):match("AB#(%d+)"))
      local ado_item = ab_id and state.ado_cache[ab_id] or nil
      local row_text, row_regions = render.format_row(pr, cols, ado_item)
      table.insert(lines, row_text)
      table.insert(all_regions, row_regions)
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
end

--- Update the preview pane for the currently selected PR.
function M._update_preview()
  if not state.preview_buf or not vim.api.nvim_buf_is_valid(state.preview_buf) then return end
  if not state.list_win or not vim.api.nvim_win_is_valid(state.list_win) then return end

  local cursor = vim.api.nvim_win_get_cursor(state.list_win)
  local pr_idx = cursor[1] - HEADER_LINES
  local pr = state.prs[pr_idx]

  -- Check for ADO work item and fetch if needed
  local ado_item = nil
  if pr then
    local ado_id = ado.extract_id(pr.title or "") or ado.extract_id(pr.body or "")
    if ado_id then
      if state.ado_cache[ado_id] then
        ado_item = state.ado_cache[ado_id]
      else
        ado.fetch_work_item(ado_id, function(item, _err)
          if item then
            state.ado_cache[ado_id] = item
            M._update_preview()
          end
        end)
      end
    end
  end

  local preview_lines, line_regions = render.format_preview(pr, ado_item)
  set_buf_lines(state.preview_buf, preview_lines)

  local preview_ns = vim.api.nvim_create_namespace("plz_dashboard_preview")
  vim.api.nvim_buf_clear_namespace(state.preview_buf, preview_ns, 0, -1)
  for i, regions in ipairs(line_regions) do
    for _, r in ipairs(regions) do
      if r[3] then
        pcall(vim.api.nvim_buf_set_extmark, state.preview_buf, preview_ns, i - 1, r[1], {
          end_col = r[2],
          hl_group = r[3],
          priority = 100,
        })
      end
    end
  end
end

--- Set up dashboard keybindings.
function M._setup_keymaps()
  local buf = state.list_buf
  local opts = { buffer = buf, nowait = true }

  for i = 1, #fetch.sections do
    vim.keymap.set("n", tostring(i), function()
      M._fetch_tab(i)
    end, vim.tbl_extend("force", opts, { desc = fetch.sections[i].name }))
  end

  vim.keymap.set("n", "<Tab>", function()
    M._fetch_tab((state.tab_idx % #fetch.sections) + 1)
  end, vim.tbl_extend("force", opts, { desc = "Next tab" }))

  vim.keymap.set("n", "<S-Tab>", function()
    M._fetch_tab(((state.tab_idx - 2) % #fetch.sections) + 1)
  end, vim.tbl_extend("force", opts, { desc = "Previous tab" }))

  vim.keymap.set("n", "o", function()
    local pr = M._get_selected_pr()
    if pr and pr.url then
      vim.ui.open(pr.url)
    end
  end, vim.tbl_extend("force", opts, { desc = "Open in browser" }))

  vim.keymap.set("n", "r", function()
    M._fetch_tab(state.tab_idx)
  end, vim.tbl_extend("force", opts, { desc = "Refresh" }))

  vim.keymap.set("n", "q", function()
    M.close()
  end, vim.tbl_extend("force", opts, { desc = "Close dashboard" }))

  vim.keymap.set("n", "<CR>", function()
    local pr = M._get_selected_pr()
    if pr then
      vim.notify("plz: PR #" .. pr.number .. " review — not yet implemented", vim.log.levels.INFO)
    end
  end, vim.tbl_extend("force", opts, { desc = "Open PR review" }))

  vim.keymap.set("n", "?", function()
    local help = {
      "  plz dashboard",
      "",
      "  j/k       navigate",
      "  <CR>      open PR for review",
      "  o         open in browser",
      "  r         refresh",
      "  1-" .. #fetch.sections .. "       switch tab",
      "  <Tab>     next tab",
      "  <S-Tab>   previous tab",
      "  q         close",
      "  ?         this help",
    }
    set_buf_lines(state.preview_buf, help)
  end, vim.tbl_extend("force", opts, { desc = "Show help" }))
end

--- Get the PR under the cursor.
function M._get_selected_pr()
  if not state.list_win or not vim.api.nvim_win_is_valid(state.list_win) then return nil end
  local pr_idx = vim.api.nvim_win_get_cursor(state.list_win)[1] - HEADER_LINES
  return state.prs[pr_idx]
end

--- Close the dashboard.
function M.close()
  if state.autocmd_id then
    pcall(vim.api.nvim_del_autocmd, state.autocmd_id)
    state.autocmd_id = nil
  end

  if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
    pcall(vim.api.nvim_win_close, state.preview_win, true)
  end

  if state.prev_buf and vim.api.nvim_buf_is_valid(state.prev_buf) then
    if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
      vim.api.nvim_win_set_buf(state.list_win, state.prev_buf)
    end
  end

  for _, buf in ipairs({ state.list_buf, state.preview_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  state.list_buf = nil
  state.preview_buf = nil
  state.list_win = nil
  state.preview_win = nil
  state.prev_buf = nil
  state.prs = {}
end

return M
