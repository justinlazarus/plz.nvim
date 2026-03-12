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

--- Collapse unchanged regions, keeping only lines near changes.
--- Replaces gaps with fold separator entries.
--- @param padded_lhs table[] Aligned LHS from build()
--- @param padded_rhs table[] Aligned RHS from build()
--- @param diff_result table Normalized difftastic output
--- @param context number Lines of context around each change (default 3)
--- @return table[] collapsed_lhs
--- @return table[] collapsed_rhs
function M.collapse(padded_lhs, padded_rhs, diff_result, context)
  context = context or 3
  local n = #padded_lhs

  if n == 0 then return padded_lhs, padded_rhs end

  -- Build orig → padded-index maps
  local lhs_map = {}
  for i, entry in ipairs(padded_lhs) do
    if entry.orig ~= nil then lhs_map[entry.orig] = i end
  end
  local rhs_map = {}
  for i, entry in ipairs(padded_rhs) do
    if entry.orig ~= nil then rhs_map[entry.orig] = i end
  end

  -- Mark padded rows that are changed
  local changed = {}
  for _, hunk in ipairs(diff_result.hunks or {}) do
    for _, entry in ipairs(hunk.entries) do
      if entry.lhs_line and lhs_map[entry.lhs_line] then
        changed[lhs_map[entry.lhs_line]] = true
      end
      if entry.rhs_line and rhs_map[entry.rhs_line] then
        changed[rhs_map[entry.rhs_line]] = true
      end
    end
  end

  -- Expand to include context lines
  local visible = {}
  for row in pairs(changed) do
    for i = math.max(1, row - context), math.min(n, row + context) do
      visible[i] = true
    end
  end

  -- Build collapsed arrays
  local col_lhs = {}
  local col_rhs = {}
  local i = 1
  while i <= n do
    if visible[i] then
      table.insert(col_lhs, padded_lhs[i])
      table.insert(col_rhs, padded_rhs[i])
      i = i + 1
    else
      -- Count consecutive hidden lines
      local start = i
      while i <= n and not visible[i] do
        i = i + 1
      end
      local hidden = i - start
      local fold_text = string.format("╶╶╶ %d lines ╶╶╶", hidden)
      table.insert(col_lhs, { text = fold_text, orig = nil, fold = true, hidden = hidden })
      table.insert(col_rhs, { text = fold_text, orig = nil, fold = true, hidden = hidden })
    end
  end

  return col_lhs, col_rhs
end

return M
