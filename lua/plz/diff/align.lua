local M = {}

--- Build aligned line arrays for side-by-side display with filler lines.
--- Uses diff anchors (change entries with both lhs and rhs) to synchronize
--- line positions, inserting blank filler lines where one side has no match.
--- @param old_lines string[] 1-indexed array of old file lines
--- @param new_lines string[] 1-indexed array of new file lines
--- @param diff_result table Normalized difftastic output
--- @return table[] padded_lhs Array of {text: string, orig: number|nil} (orig is 0-indexed)
--- @return table[] padded_rhs Array of {text: string, orig: number|nil}
function M.build(old_lines, new_lines, diff_result)
  local anchors = {}
  local add_set = {}
  local rem_set = {}

  for _, hunk in ipairs(diff_result.hunks or {}) do
    for _, entry in ipairs(hunk.entries) do
      if entry.type == "change" then
        table.insert(anchors, { lhs = entry.lhs_line, rhs = entry.rhs_line })
      elseif entry.type == "add" then
        add_set[entry.rhs_line] = true
      elseif entry.type == "remove" then
        rem_set[entry.lhs_line] = true
      end
    end
  end

  table.sort(anchors, function(a, b) return a.lhs < b.lhs end)

  local padded_lhs = {}
  local padded_rhs = {}
  local lhs_pos = 0
  local rhs_pos = 0

  for _, anchor in ipairs(anchors) do
    M._fill_gap(padded_lhs, padded_rhs, old_lines, new_lines,
      lhs_pos, anchor.lhs - 1, rhs_pos, anchor.rhs - 1,
      rem_set, add_set)

    -- Emit the anchor pair
    table.insert(padded_lhs, { text = old_lines[anchor.lhs + 1] or "", orig = anchor.lhs })
    table.insert(padded_rhs, { text = new_lines[anchor.rhs + 1] or "", orig = anchor.rhs })

    lhs_pos = anchor.lhs + 1
    rhs_pos = anchor.rhs + 1
  end

  -- Fill remaining lines after last anchor
  M._fill_gap(padded_lhs, padded_rhs, old_lines, new_lines,
    lhs_pos, #old_lines - 1, rhs_pos, #new_lines - 1,
    rem_set, add_set)

  return padded_lhs, padded_rhs
end

--- Fill a gap between two anchors, interleaving unchanged pairs with
--- additions (rhs-only) and removals (lhs-only).
function M._fill_gap(p_lhs, p_rhs, old_lines, new_lines,
                     lhs_start, lhs_end, rhs_start, rhs_end,
                     rem_set, add_set)
  local li = lhs_start
  local ri = rhs_start

  while li <= lhs_end and ri <= rhs_end do
    if rem_set[li] then
      table.insert(p_lhs, { text = old_lines[li + 1] or "", orig = li })
      table.insert(p_rhs, { text = "", orig = nil })
      li = li + 1
    elseif add_set[ri] then
      table.insert(p_lhs, { text = "", orig = nil })
      table.insert(p_rhs, { text = new_lines[ri + 1] or "", orig = ri })
      ri = ri + 1
    else
      -- Unchanged pair
      table.insert(p_lhs, { text = old_lines[li + 1] or "", orig = li })
      table.insert(p_rhs, { text = new_lines[ri + 1] or "", orig = ri })
      li = li + 1
      ri = ri + 1
    end
  end

  while li <= lhs_end do
    table.insert(p_lhs, { text = old_lines[li + 1] or "", orig = li })
    table.insert(p_rhs, { text = "", orig = nil })
    li = li + 1
  end

  while ri <= rhs_end do
    table.insert(p_lhs, { text = "", orig = nil })
    table.insert(p_rhs, { text = new_lines[ri + 1] or "", orig = ri })
    ri = ri + 1
  end
end

return M
