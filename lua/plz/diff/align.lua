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

  -- Filter out crossed anchors: both lhs and rhs must be monotonically
  -- increasing. When difftastic reports swapped lines (e.g. lhs 251↔rhs 252,
  -- lhs 252↔rhs 251), the crossed pair would break alignment. Demote
  -- crossed anchors to separate remove + add entries instead.
  local filtered = {}
  local max_rhs = -1
  for _, anchor in ipairs(anchors) do
    if anchor.rhs > max_rhs then
      table.insert(filtered, anchor)
      max_rhs = anchor.rhs
    else
      -- Crossed anchor: treat as independent remove + add
      rem_set[anchor.lhs] = true
      add_set[anchor.rhs] = true
    end
  end
  anchors = filtered

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
---
--- Uses a bounded lookahead when content doesn't match to find the
--- correct pairing, avoiding the misalignment caused by blindly
--- pairing lines or extending add/remove runs.
function M._fill_gap(p_lhs, p_rhs, old_lines, new_lines,
                     lhs_start, lhs_end, rhs_start, rhs_end,
                     rem_set, add_set)
  local li = lhs_start
  local ri = rhs_start

  local LOOKAHEAD = 50

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
      local lhs_text = old_lines[li + 1] or ""
      local rhs_text = new_lines[ri + 1] or ""
      if lhs_text == rhs_text
        or (lhs_text:match("^%s*(.-)%s*$") == rhs_text:match("^%s*(.-)%s*$")
            and #lhs_text:match("^%s*(.-)%s*$") >= 3) then
        -- Unchanged pair (exact or trimmed match for re-indented lines)
        table.insert(p_lhs, { text = lhs_text, orig = li })
        table.insert(p_rhs, { text = rhs_text, orig = ri })
        li = li + 1
        ri = ri + 1
      else
        -- Content mismatch: use lookahead to find where the match resumes.
        -- Look for lhs_text in upcoming RHS lines (it's an add run on RHS).
        -- Look for rhs_text in upcoming LHS lines (it's a remove run on LHS).
        -- Use trimmed comparison to handle re-indented lines.
        local lhs_trimmed = lhs_text:match("^%s*(.-)%s*$")
        local rhs_trimmed = rhs_text:match("^%s*(.-)%s*$")

        -- Skip trivial matches on very short trimmed content (braces, etc.)
        local min_trim_len = 3

        local rhs_match = nil
        for look = 1, math.min(LOOKAHEAD, rhs_end - ri) do
          local candidate = new_lines[ri + look + 1] or ""
          if not add_set[ri + look] then
            local cand_trimmed = candidate:match("^%s*(.-)%s*$")
            -- Only match on significant content (skip blank lines, braces)
            if #lhs_trimmed >= min_trim_len and (candidate == lhs_text or cand_trimmed == lhs_trimmed) then
              rhs_match = look
              break
            end
          end
        end

        local lhs_match = nil
        for look = 1, math.min(LOOKAHEAD, lhs_end - li) do
          local candidate = old_lines[li + look + 1] or ""
          if not rem_set[li + look] then
            local cand_trimmed = candidate:match("^%s*(.-)%s*$")
            -- Only match on significant content (skip blank lines, braces)
            if #rhs_trimmed >= min_trim_len and (candidate == rhs_text or cand_trimmed == rhs_trimmed) then
              lhs_match = look
              break
            end
          end
        end

        if rhs_match and (not lhs_match or rhs_match <= lhs_match) then
          -- RHS has intervening adds before the match: emit them
          for k = 0, rhs_match - 1 do
            table.insert(p_lhs, { text = "", orig = nil })
            table.insert(p_rhs, { text = new_lines[ri + 1] or "", orig = ri })
            ri = ri + 1
          end
        elseif lhs_match then
          -- LHS has intervening removes before the match: emit them
          for k = 0, lhs_match - 1 do
            table.insert(p_lhs, { text = old_lines[li + 1] or "", orig = li })
            table.insert(p_rhs, { text = "", orig = nil })
            li = li + 1
          end
        else
          -- No match found within lookahead: pair them as a change
          table.insert(p_lhs, { text = lhs_text, orig = li })
          table.insert(p_rhs, { text = rhs_text, orig = ri })
          li = li + 1
          ri = ri + 1
        end
      end
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
