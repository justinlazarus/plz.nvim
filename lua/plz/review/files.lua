local icons = require("plz.dashboard.render").icons
local comments = require("plz.review.comments")

local M = {}

local ns = vim.api.nvim_create_namespace("plz_review")
local ns_active = vim.api.nvim_create_namespace("plz_review_active")

--- Reference to the shared review state table, set via M.setup().
local state

--- Store a reference to shared state.
--- @param state_ref table  The shared review state table
function M.setup(state_ref)
  state = state_ref
end

--- Create the file list buffer (no window/tab management).
--- @return number buf  Buffer handle
function M.create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "plz-review"
  state.buf = buf
  return buf
end

--- Render the file list buffer.
function M.render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  local lines = {}
  local hl_regions = {}

  local file_win = state.top_win or state.win
  local win_w = file_win and vim.api.nvim_win_is_valid(file_win)
    and vim.api.nvim_win_get_width(file_win) or 90

  local max_path = 0
  for _, file in ipairs(state.files) do
    local path = file.filename or file.path or ""
    if #path > max_path then max_path = #path end
  end
  -- prefix: 2 + check(4) + cmt(6) + icon(4) + add(6) + del(6) = 28
  max_path = math.min(max_path, win_w - 28)

  for _, file in ipairs(state.files) do
    local path = file.filename or file.path or "?"
    local status = file.status or "modified"
    local adds = file.additions or 0
    local dels = file.deletions or 0

    local viewed = state.viewed[path]
    local check = viewed and icons.ci_pass or "○"
    local check_hl = viewed and "PlzSuccess" or "PlzFaint"

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

    local adds_str = adds > 0 and string.format("+%d", adds) or ""
    local dels_str = dels > 0 and string.format("-%d", dels) or ""

    local comment_count = comments.file_comment_count(path)
    local comment_str = comment_count > 0 and (icons.comment .. " " .. comment_count) or ""

    -- Fixed column widths
    local check_w  = 4   -- "○ " or "✓ " + padding
    local cmt_w    = 6   -- "💬 3" or blank
    local icon_w   = 4   -- "M  "
    local add_w    = 6   -- "+123  "
    local del_w    = 6   -- "-123  "
    -- path fills remainder

    local function fit(s, w)
      local dw = vim.fn.strdisplaywidth(s)
      if dw >= w then return s end
      return s .. string.rep(" ", w - dw)
    end

    local c_check   = fit(check, check_w)
    local c_cmt     = fit(comment_str, cmt_w)
    local c_icon    = fit(icon, icon_w)
    local c_add     = fit(adds_str, add_w)
    local c_del     = fit(dels_str, del_w)

    local row = "  " .. c_check .. c_cmt .. c_icon .. c_add .. c_del .. display_path
    table.insert(lines, row)

    -- Highlights
    local row_regions = {}
    local p = 2
    -- check
    table.insert(row_regions, { p, p + #check, check_hl })
    p = p + #c_check
    -- comment
    if comment_count > 0 then
      table.insert(row_regions, { p, p + #comment_str, "PlzFaint" })
    end
    p = p + #c_cmt
    -- icon
    table.insert(row_regions, { p, p + #icon, icon_hl })
    p = p + #c_icon
    -- adds
    if adds > 0 then
      table.insert(row_regions, { p, p + #adds_str, "PlzGreen" })
    end
    p = p + #c_add
    -- dels
    if dels > 0 then
      table.insert(row_regions, { p, p + #dels_str, "PlzRed" })
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

--- Highlight the active file row in the file list.
function M.highlight_active()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then return end
  vim.api.nvim_buf_clear_namespace(state.buf, ns_active, 0, -1)
  if state.current_file_idx then
    local row = state.current_file_idx - 1  -- 0-indexed, no header offset
    pcall(vim.api.nvim_buf_set_extmark, state.buf, ns_active, row, 0, {
      line_hl_group = "CursorLine",
    })
  end
end

--- Update the file list winbar with file position and viewed checkbox.
function M.update_diff_status()
  if not state.current_file_idx then return end
  local top = state.top_win or state.win
  if not top or not vim.api.nvim_win_is_valid(top) then return end
  local file = state.files[state.current_file_idx]
  if not file then return end

  local path = file.filename or file.path or "?"
  local viewed = state.viewed[path]
  local check_icon = viewed and icons.ci_pass or "○"
  local check_hl = viewed and "PlzSuccess" or "PlzFaint"

  local pos = string.format("%d of %d", state.current_file_idx, #state.files)
  local bar = "%#PlzAccent#  " .. pos:gsub("%%", "%%%%")
    .. "  %#" .. check_hl .. "#" .. check_icon
  vim.wo[top].winbar = bar
end

return M
