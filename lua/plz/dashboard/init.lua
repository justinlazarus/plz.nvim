local fetch = require("plz.dashboard.fetch")
local render = require("plz.dashboard.render")

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
}

--- Compute title column width based on window width.
local function title_width()
  if not state.list_win or not vim.api.nvim_win_is_valid(state.list_win) then
    return 40
  end
  local win_w = vim.api.nvim_win_get_width(state.list_win)
  -- Reserve space for: state(3) + number(7) + author(22) + review(4) + ci(3) + lines(13) + age(6) + padding(~5)
  local reserved = 3 + 7 + 22 + 4 + 3 + 13 + 6 + 5
  return math.max(20, win_w - reserved)
end

--- Open the plz dashboard.
function M.open()
  vim.cmd("tabnew")

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
  M._set_buf_lines(state.list_buf, { "", "  Loading..." })
  M._set_buf_lines(state.preview_buf, {})

  fetch.fetch_section(idx, function(prs, err)
    if err then
      M._set_buf_lines(state.list_buf, { "", "  Error: " .. err })
      return
    end
    state.prs = prs or {}
    M._render_list()
    M._update_preview()
  end)
end

--- Render the full PR list buffer with highlights.
function M._render_list()
  if not state.list_buf or not vim.api.nvim_buf_is_valid(state.list_buf) then return end

  local tw = title_width()
  local lines = {}
  local all_regions = {} -- regions per line

  -- Line 1: Tab bar
  local tab_text, tab_regions = render.tab_line(fetch.sections, state.tab_idx)
  lines[1] = tab_text
  all_regions[1] = tab_regions

  -- Line 2: Border
  local win_w = state.list_win and vim.api.nvim_win_is_valid(state.list_win)
    and vim.api.nvim_win_get_width(state.list_win) or 90
  lines[2] = string.rep("─", win_w)
  all_regions[2] = { { 0, #lines[2], "PlzBorder" } }

  -- Line 3: Column headers
  local header_text, header_regions = render.header_line(tw)
  lines[3] = header_text
  all_regions[3] = header_regions

  -- Line 4: Border
  lines[4] = string.rep("─", win_w)
  all_regions[4] = { { 0, #lines[4], "PlzBorder" } }

  -- PR rows
  if #state.prs == 0 then
    lines[5] = ""
    lines[6] = "  No PRs found"
    all_regions[5] = {}
    all_regions[6] = { { 0, #lines[6], "PlzFaint" } }
  else
    for _, pr in ipairs(state.prs) do
      local row_text, row_regions = render.format_row(pr, tw)
      table.insert(lines, row_text)
      table.insert(all_regions, row_regions)
    end
  end

  M._set_buf_lines(state.list_buf, lines)

  -- Apply all highlights
  render.clear(state.list_buf)
  for i, regions in ipairs(all_regions) do
    render.apply_regions(state.list_buf, i - 1, regions)
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

  local preview_lines, line_regions = render.format_preview(pr)
  M._set_buf_lines(state.preview_buf, preview_lines)

  -- Apply preview highlights
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

  -- Tab switching
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
    M._set_buf_lines(state.preview_buf, help)
  end, vim.tbl_extend("force", opts, { desc = "Show help" }))
end

--- Get the PR under the cursor.
function M._get_selected_pr()
  if not state.list_win or not vim.api.nvim_win_is_valid(state.list_win) then return nil end
  local pr_idx = vim.api.nvim_win_get_cursor(state.list_win)[1] - HEADER_LINES
  return state.prs[pr_idx]
end

--- Helper to set buffer lines.
function M._set_buf_lines(buf, lines)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

--- Close the dashboard.
function M.close()
  if state.autocmd_id then
    pcall(vim.api.nvim_del_autocmd, state.autocmd_id)
    state.autocmd_id = nil
  end
  pcall(vim.cmd, "tabclose")
  for _, buf in ipairs({ state.list_buf, state.preview_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  state.list_buf = nil
  state.preview_buf = nil
  state.list_win = nil
  state.preview_win = nil
  state.prs = {}
end

return M
