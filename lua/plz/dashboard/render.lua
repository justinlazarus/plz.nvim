local M = {}

local ns = vim.api.nvim_create_namespace("plz_dashboard")

-- ── gh-dash nerd font icons ──

-- Use utf8.char to ensure nerd font glyphs survive file encoding
local u = utf8 and utf8.char or function(cp)
  if cp < 0x80 then return string.char(cp)
  elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  else return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64, 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  end
end

M.icons = {
  -- PR state (nerd font codepoints)
  open     = u(0xe728),  --
  draft    = u(0xe729),  --
  closed   = u(0xe72d),  --
  merged   = u(0xe727),  --
  -- CI status
  ci_pass  = u(0xf058),  --
  ci_fail  = u(0xf0159), -- 󰅙
  ci_wait  = u(0xf110),  --
  ci_none  = u(0xf192),  --
  -- Review
  approved = u(0xf012c), -- 󰄬
  changes  = u(0xe737),  --
  waiting  = u(0xf110),  --
  comment  = u(0xf075),  --
  -- Column headers
  comments = u(0xf086),  --
  review   = u(0xf0be2), -- 󰯢
  ci       = u(0xf013),  --
  lines    = u(0xf120),  --
  updated  = u(0xf19bb), -- 󱦻
  -- Misc
  dot      = u(0x22c5),  -- ⋅
  person   = u(0xf007),  --
}

-- ── Column widths (compact mode, matching gh-dash) ──

local COL = {
  state   = 3,
  number  = 7,
  -- title is flexible (fills remaining)
  author  = 22,
  comments = 5,
  review  = 3,
  ci      = 3,
  lines   = 13,
  age     = 6,
}

--- Render the tab bar line and return highlight regions.
--- @param sections table[]
--- @param active_idx number
--- @return string line
--- @return table[] regions {{col_start, col_end, hl_group}, ...}
function M.tab_line(sections, active_idx)
  local parts = {}
  local regions = {}
  local pos = 0

  for i, section in ipairs(sections) do
    if i > 1 then
      local sep = " │ "
      table.insert(parts, sep)
      table.insert(regions, { pos, pos + #sep, "PlzBorder" })
      pos = pos + #sep
    end

    local label
    if i == active_idx then
      label = " " .. section.name .. " "
      table.insert(regions, { pos, pos + #label, "PlzTabActive" })
    else
      label = " " .. section.name .. " "
      table.insert(regions, { pos, pos + #label, "PlzTabInactive" })
    end
    table.insert(parts, label)
    pos = pos + #label
  end

  return table.concat(parts), regions
end

--- Build a row using a shared column structure.
--- Each column is { text, display_width, hl_group? }.
--- Returns the padded line and highlight regions.
local function build_row(columns)
  local parts = {}
  local regions = {}
  local pos = 0 -- byte position

  for _, col in ipairs(columns) do
    local text = col[1]
    local width = col[2]
    local hl = col[3]

    -- Pad to display width
    local dw = vim.fn.strdisplaywidth(text)
    if width and dw < width then
      text = text .. string.rep(" ", width - dw)
    end

    table.insert(parts, text)
    if hl then
      table.insert(regions, { pos, pos + #text, hl })
    end
    pos = pos + #text
  end

  return table.concat(parts), regions
end

--- Format a PR row and return the line + highlight regions.
--- @param pr table
--- @param title_width number
--- @return string line
--- @return table[] regions
function M.format_row(pr, title_width)
  title_width = title_width or 40

  local state_icon, state_hl = M._state_icon(pr)
  local rev_icon, rev_hl = M._review_icon(pr.reviewDecision)
  local ci_icon, ci_hl = M._ci_icon(pr.statusCheckRollup)
  local add_str = string.format("+%d", pr.additions or 0)
  local del_str = string.format("-%d", pr.deletions or 0)
  local title = M._truncate(pr.title or "", title_width)
  local author = M._truncate((pr.author and pr.author.login) or "?", COL.author - 2)

  return build_row({
    { " " .. state_icon, 3, state_hl },
    { string.format("#%-5d", pr.number), 7, "PlzFaint" },
    { title, title_width + 1 },
    { author, COL.author, "PlzFaint" },
    { rev_icon, 3, rev_hl },
    { ci_icon, 3, ci_hl },
    { add_str, #add_str + 1, "PlzDiffAdd" },
    { del_str, 8, "PlzDiffRemove" },
    { M._relative_time(pr.updatedAt), nil, "PlzFaint" },
  })
end

--- Format column header line.
--- @param title_width number
--- @return string
--- @return table[] regions
function M.header_line(title_width)
  title_width = title_width or 40

  return build_row({
    { "", 3, "PlzHeader" },
    { "#", 7, "PlzHeader" },
    { "Title", title_width + 1, "PlzHeader" },
    { "Author", COL.author, "PlzHeader" },
    { M.icons.review, 3, "PlzHeader" },
    { M.icons.ci, 3, "PlzHeader" },
    { "+/-", 9, "PlzHeader" },
    { M.icons.updated, nil, "PlzHeader" },
  })
end

--- Format preview pane content for a PR.
--- @param pr table|nil
--- @return string[] lines
--- @return table[] line_regions (array of arrays of regions per line)
function M.format_preview(pr)
  if not pr then
    return { "", "  Select a PR to see details" }, {}
  end

  local lines = {}
  local line_regions = {}

  local function add(text, regions)
    table.insert(lines, text)
    table.insert(line_regions, regions or {})
  end

  -- Branch + author
  local branch_line = string.format("  %s %s  %s → %s",
    M.icons.person,
    (pr.author and pr.author.login) or "?",
    pr.headRefName or "?",
    pr.baseRefName or "?")
  add(branch_line, { { 0, #branch_line, "PlzFaint" } })

  -- Status
  local status_parts = {}
  if pr.isDraft then table.insert(status_parts, "DRAFT") end
  local decision = pr.reviewDecision or "PENDING"
  table.insert(status_parts, decision)
  add("  " .. table.concat(status_parts, " · "))
  add("")

  -- CI
  local rollup = pr.statusCheckRollup or {}
  if #rollup > 0 then
    local pass, fail, pending = 0, 0, 0
    for _, check in ipairs(rollup) do
      local c = check.conclusion or ""
      local s = check.status or ""
      if c == "SUCCESS" then pass = pass + 1
      elseif c == "FAILURE" or c == "CANCELLED" then fail = fail + 1
      elseif s == "IN_PROGRESS" or s == "QUEUED" or s == "PENDING" then pending = pending + 1
      else pass = pass + 1
      end
    end
    local ci_line = string.format("  %s CI: %d/%d passed", M.icons.ci, pass, #rollup)
    if fail > 0 then ci_line = ci_line .. string.format(", %d failed", fail) end
    if pending > 0 then ci_line = ci_line .. string.format(", %d in progress", pending) end
    add(ci_line)
  end

  -- ADO work item (placeholder — fetched async when wired up)
  local ado_id = (pr.title or ""):match("AB#(%d+)") or (pr.body or ""):match("AB#(%d+)")
  if ado_id then
    -- Will be replaced with real data: type · AB#id · state · assignee · tags
    add(string.format("  ADO AB#%s  —  type · state · assignee · tags", ado_id), { { 0, 0, "PlzFaint" } })
  end

  add("")

  -- Placeholders for future sections
  add("  Reviewers: —")
  add("  Threads:   —")

  return lines, line_regions
end

--- Apply highlight regions to a buffer line.
--- @param buf number
--- @param row number 0-indexed
--- @param regions table[] {{col_start, col_end, hl_group}, ...}
function M.apply_regions(buf, row, regions)
  for _, r in ipairs(regions or {}) do
    if r[3] then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, r[1], {
        end_col = r[2],
        hl_group = r[3],
        priority = 100,
      })
    end
  end
end

--- Clear dashboard highlights.
function M.clear(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

-- ── Helpers ──

function M._pad(str, width)
  local len = vim.fn.strdisplaywidth(str)
  if len >= width then return str end
  return str .. string.rep(" ", width - len)
end

function M._truncate(str, max)
  if #str <= max then return str end
  return string.sub(str, 1, max - 1) .. "…"
end

function M._state_icon(pr)
  if pr.isDraft then return M.icons.draft, "PlzDraft" end
  local state = pr.state or "OPEN"
  if state == "MERGED" then return M.icons.merged, "PlzMerged"
  elseif state == "CLOSED" then return M.icons.closed, "PlzClosed"
  else return M.icons.open, "PlzOpen"
  end
end

function M._review_icon(decision)
  if decision == "APPROVED" then return M.icons.approved, "PlzSuccess"
  elseif decision == "CHANGES_REQUESTED" then return M.icons.changes, "PlzError"
  elseif decision == "REVIEW_REQUIRED" then return M.icons.waiting, "PlzWarning"
  else return " ", nil
  end
end

function M._ci_icon(rollup)
  if not rollup or #rollup == 0 then return M.icons.ci_none, "PlzFaint" end
  for _, check in ipairs(rollup) do
    if (check.conclusion or "") == "FAILURE" then return M.icons.ci_fail, "PlzError" end
  end
  for _, check in ipairs(rollup) do
    local s = check.status or ""
    if s == "IN_PROGRESS" or s == "QUEUED" or s == "PENDING" then
      return M.icons.ci_wait, "PlzWarning"
    end
  end
  return M.icons.ci_pass, "PlzSuccess"
end

function M._relative_time(iso_str)
  if not iso_str then return "?" end
  local y, mo, d, h, mi, s = iso_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return "?" end
  local ts = os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
  })
  local diff = os.difftime(os.time(), ts)
  if diff < 60 then return "now"
  elseif diff < 3600 then return math.floor(diff / 60) .. "m"
  elseif diff < 86400 then return math.floor(diff / 3600) .. "h"
  elseif diff < 604800 then return math.floor(diff / 86400) .. "d"
  elseif diff < 2592000 then return math.floor(diff / 604800) .. "w"
  else return math.floor(diff / 2592000) .. "mo"
  end
end

return M
