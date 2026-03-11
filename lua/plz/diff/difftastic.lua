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
        normalized.lhs_changes = M._extract_positions(entry.lhs.changes)
        normalized.rhs_changes = M._extract_positions(entry.rhs.changes)
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

return M
