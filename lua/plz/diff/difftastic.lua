local M = {}

--- Run difftastic on two files and return parsed JSON.
--- @param old_path string Absolute path to the old file
--- @param new_path string Absolute path to the new file
--- @param callback fun(result: table|nil, err: string|nil)
function M.run(old_path, new_path, callback)
  vim.system(
    { "difft", "--display=json", old_path, new_path },
    { text = true, env = { DFT_UNSTABLE = "yes" } },
    function(obj)
      vim.schedule(function()
        if obj.code ~= 0 and obj.code ~= 1 then
          -- difft returns 1 when files differ, 0 when identical
          callback(nil, "difft failed: " .. (obj.stderr or "unknown error"))
          return
        end

        local ok, parsed = pcall(vim.json.decode, obj.stdout)
        if not ok then
          callback(nil, "failed to parse difft JSON: " .. tostring(parsed))
          return
        end

        callback(M.normalize(parsed))
      end)
    end
  )
end

--- Normalize difftastic JSON into a structure easier to render.
---
--- Input format from difft --display=json:
--- {
---   chunks: [ [ {lhs?, rhs?} ... ] ... ],
---   language: "TypeScript",
---   status: "changed"
--- }
---
--- Each entry in a chunk can have:
---   - lhs only (deleted line/tokens)
---   - rhs only (added line/tokens)
---   - both lhs and rhs (changed tokens on matching lines)
---
--- Output format:
--- {
---   language = "TypeScript",
---   status = "changed",
---   hunks = {
---     {
---       entries = {
---         { type = "add", rhs_line = N, rhs_changes = {{start, end}} },
---         { type = "remove", lhs_line = N, lhs_changes = {{start, end}} },
---         { type = "change", lhs_line = N, rhs_line = N, lhs_changes = {}, rhs_changes = {} },
---       }
---     }
---   }
--- }
--- @param raw table Raw difftastic JSON
--- @return table Normalized result
function M.normalize(raw)
  local result = {
    language = raw.language,
    status = raw.status,
    hunks = {},
  }

  for _, chunk in ipairs(raw.chunks or {}) do
    local entries = {}
    for _, entry in ipairs(chunk) do
      local normalized = {}

      if entry.lhs and entry.rhs then
        normalized.type = "change"
        normalized.lhs_line = entry.lhs.line_number
        normalized.rhs_line = entry.rhs.line_number
        normalized.lhs_changes = M._novel_positions(entry.lhs.changes, entry.rhs.changes)
        normalized.rhs_changes = M._novel_positions(entry.rhs.changes, entry.lhs.changes)
      elseif entry.rhs then
        normalized.type = "add"
        normalized.rhs_line = entry.rhs.line_number
        normalized.rhs_changes = M._extract_positions(entry.rhs.changes)
      elseif entry.lhs then
        normalized.type = "remove"
        normalized.lhs_line = entry.lhs.line_number
        normalized.lhs_changes = M._extract_positions(entry.lhs.changes)
      end

      if normalized.type then
        table.insert(entries, normalized)
      end
    end

    if #entries > 0 then
      table.insert(result.hunks, { entries = entries })
    end
  end

  return result
end

--- Extract {start, end} positions from difft changes array.
--- Used for add/remove entries where all tokens are novel.
--- @param changes table[] Array of {start, end, content, highlight}
--- @return table[] Array of {start, end_col} (0-indexed byte offsets)
function M._extract_positions(changes)
  local positions = {}
  for _, change in ipairs(changes or {}) do
    table.insert(positions, {
      start = change.start,
      end_col = change["end"],
    })
  end
  return positions
end

--- Find novel token positions by LCS-diffing two token sequences.
--- Difftastic JSON includes ALL tokens for changed lines (not just novel ones).
--- We diff the content sequences to find which tokens are actually new.
--- @param side table[] Changes array from the side we want to highlight
--- @param other table[] Changes array from the other side
--- @return table[] Array of {start, end_col} for novel tokens only
function M._novel_positions(side, other)
  side = side or {}
  other = other or {}

  -- Extract content sequences
  local side_contents = {}
  for _, c in ipairs(side) do
    side_contents[#side_contents + 1] = c.content
  end
  local other_contents = {}
  for _, c in ipairs(other) do
    other_contents[#other_contents + 1] = c.content
  end

  -- Find which indices in side are part of the LCS (i.e. unchanged)
  local in_lcs = M._lcs_indices(side_contents, other_contents)

  -- Return positions of tokens NOT in the LCS (novel tokens)
  local positions = {}
  for i, c in ipairs(side) do
    if not in_lcs[i] then
      positions[#positions + 1] = {
        start = c.start,
        end_col = c["end"],
      }
    end
  end
  return positions
end

--- Compute LCS and return the set of indices in `a` that participate.
--- @param a string[] Token content sequence
--- @param b string[] Token content sequence
--- @return table<number, boolean> Set of 1-indexed positions in `a` that are in the LCS
function M._lcs_indices(a, b)
  local m, n = #a, #b
  -- DP table
  local dp = {}
  for i = 0, m do
    dp[i] = {}
    for j = 0, n do
      if i == 0 or j == 0 then
        dp[i][j] = 0
      elseif a[i] == b[j] then
        dp[i][j] = dp[i - 1][j - 1] + 1
      else
        dp[i][j] = math.max(dp[i - 1][j], dp[i][j - 1])
      end
    end
  end

  -- Backtrack to find which indices in `a` are in the LCS
  local in_lcs = {}
  local i, j = m, n
  while i > 0 and j > 0 do
    if a[i] == b[j] then
      in_lcs[i] = true
      i = i - 1
      j = j - 1
    elseif dp[i - 1][j] > dp[i][j - 1] then
      i = i - 1
    else
      j = j - 1
    end
  end

  return in_lcs
end

return M
