local layout = require("plz.diff.layout")

local M = {}

local ns = vim.api.nvim_create_namespace("plz_diff")

--- Build a mapping from original line number (0-indexed) to padded buffer row (0-indexed).
--- @param padded table[] Array of {text, orig} from align.build
--- @return table<number, number>
function M._build_line_map(padded)
  local map = {}
  for i, entry in ipairs(padded) do
    if entry.orig ~= nil then
      map[entry.orig] = i - 1 -- 0-indexed buffer row
    end
  end
  return map
end

--- Render difftastic results onto two aligned side-by-side buffers.
--- @param lhs_buf number Buffer handle for the old (base) side
--- @param rhs_buf number Buffer handle for the new (head) side
--- @param diff_result table Normalized difftastic output
--- @param padded_lhs table[] Aligned LHS lines from align.build
--- @param padded_rhs table[] Aligned RHS lines from align.build
function M.apply(lhs_buf, rhs_buf, diff_result, padded_lhs, padded_rhs)
  vim.api.nvim_buf_clear_namespace(lhs_buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(rhs_buf, ns, 0, -1)

  local lhs_map = M._build_line_map(padded_lhs)
  local rhs_map = M._build_line_map(padded_rhs)

  for _, hunk in ipairs(diff_result.hunks or {}) do
    for _, entry in ipairs(hunk.entries) do
      if entry.type == "change" then
        M._highlight_changes(lhs_buf, lhs_map[entry.lhs_line], entry.lhs_changes, "PlzDiffRemove")
        M._highlight_changes(rhs_buf, rhs_map[entry.rhs_line], entry.rhs_changes, "PlzDiffAdd")
      elseif entry.type == "add" then
        M._highlight_changes(rhs_buf, rhs_map[entry.rhs_line], entry.rhs_changes, "PlzDiffAdd")
      elseif entry.type == "remove" then
        M._highlight_changes(lhs_buf, lhs_map[entry.lhs_line], entry.lhs_changes, "PlzDiffRemove")
      end
    end
  end
end

--- Highlight specific token positions within a line and color its line number.
--- @param buf number Buffer handle
--- @param row number|nil 0-indexed buffer row in the padded buffer
--- @param changes table[] Array of {start, end_col} positions
--- @param hl_group string Highlight group name
function M._highlight_changes(buf, row, changes, hl_group)
  if not row then return end

  local line_count = vim.api.nvim_buf_line_count(buf)
  if row < 0 or row >= line_count then return end

  local line_text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local line_len = #line_text

  -- Color the line number in the statuscolumn
  layout.set_line_hl(buf, row + 1, hl_group) -- row+1 because statuscolumn uses 1-indexed lnum

  for _, change in ipairs(changes or {}) do
    local start_col = math.min(change.start, line_len)
    local end_col = math.min(change.end_col, line_len)
    if start_col < end_col then
      vim.api.nvim_buf_set_extmark(buf, ns, row, start_col, {
        end_col = end_col,
        hl_group = hl_group,
        priority = 100,
      })
    end
  end
end

return M
