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
  -- PR state (from gh-dash constants.go)
  pr       = u(0xf407),  -- OpenIcon
  open     = u(0xf407),  -- OpenIcon
  draft    = u(0xebdb),  -- DraftIcon
  closed   = u(0xf4dc),  -- ClosedIcon
  merged   = u(0xf4c9),  -- MergedIcon
  -- CI status (from gh-dash prrow.go)
  ci_pass  = u(0xf058),  -- SuccessIcon
  ci_fail  = u(0xf0159), -- FailureIcon
  ci_wait  = u(0xe641),  -- WaitingIcon (used for CI pending too)
  ci_none  = u(0xeabd),  -- EmptyIcon
  -- Review status (from gh-dash prrow.go)
  approved = u(0xf012c), -- ApprovedIcon
  changes  = u(0xeb43),  -- ChangesRequestedIcon
  waiting  = u(0xe641),  -- WaitingIcon (no reviews yet)
  comment  = u(0xf27b),  -- CommentIcon (has reviews, undecided)
  -- Column headers (from gh-dash prssection.go)
  comments = u(0xf0e6),  -- CommentsIcon
  review_h = u(0xf0be2), -- review column header
  ci       = u(0xf45e),  -- CI column header
  lines    = u(0xf440),  -- lines column header
  updated  = u(0xf19bb), -- updated column header
  created  = u(0xf1862), -- created column header
  -- ADO (plz-specific)
  ado_bug   = u(0xeaaf),
  ado_story = u(0xf1a9e),
  ado_none  = u(0xf073a),
  ado_h     = u(0xf0ae),
  release   = u(0xf427),
  -- Git
  branch   = u(0xe725),
  -- Misc (from gh-dash constants.go)
  dot      = u(0xf444),  -- DotIcon
  person   = u(0xf415),  -- PersonIcon
}

-- ── Column layout ──

--- Compute column widths that fill the window evenly.
--- @param win_width number
--- @return table col_widths {state, number, title, author, review, ci, add, del, age}
function M.compute_columns(win_width)
  -- Fixed-width columns
  local state_w    = 3
  local author_w   = 24
  local comments_w = 5
  local review_w   = 4
  local ci_w       = 4
  local lines_w    = 12
  local updated_w  = 5
  local created_w  = 5
  local ado_w      = 4
  local release_w  = 7
  local base_w     = 20

  local fixed = state_w + author_w + comments_w + review_w + ci_w + lines_w + updated_w + created_w + ado_w + release_w + base_w
  local title_w = math.max(20, win_width - fixed)

  return {
    state    = state_w,
    title    = title_w,
    author   = author_w,
    comments = comments_w,
    review   = review_w,
    ci       = ci_w,
    lines    = lines_w,
    updated  = updated_w,
    created  = created_w,
    ado      = ado_w,
    release  = release_w,
    base     = base_w,
  }
end

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

  -- Trailing separator
  local sep = "│"
  table.insert(parts, sep)
  table.insert(regions, { pos, pos + #sep, "PlzBorder" })
  pos = pos + #sep

  return table.concat(parts), regions
end

--- Render the filter line (search bar style).
--- @param filter string
--- @return string line
--- @return table[] regions
function M.filter_line(filter)
  local icon = u(0xf002) -- nf-fa-search
  local text = " " .. icon .. " " .. filter
  return text, { { 0, #(" " .. icon), "PlzFaint" }, { #(" " .. icon), #text, "PlzFaint" } }
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
    if type(hl) == "string" then
      table.insert(regions, { pos, pos + #text, hl })
    elseif type(hl) == "table" then
      for _, r in ipairs(hl) do
        table.insert(regions, { pos + r[1], pos + r[2], r[3] })
      end
    end
    pos = pos + #text
  end

  return table.concat(parts), regions
end

--- Format a PR row and return the line + highlight regions.
--- @param pr table
--- @param cols table from compute_columns
--- @param ado_item table|nil  fetched ADO work item
--- @return string line
--- @return table[] regions
function M.format_row(pr, cols, ado_item)
  local rev_icon, rev_hl = M._review_icon(pr.reviewDecision, pr.reviews)
  local ci_icon, ci_hl = M._ci_icon(pr.statusCheckRollup)
  local add_str = string.format("+%s", M._format_number(pr.additions or 0))
  local del_str = string.format("-%s", M._format_number(pr.deletions or 0))
  local title = M._truncate(M._clean_title(pr.title or "", pr.headRefName or ""), cols.title - 1)
  local raw_name = (pr.author and (pr.author.name or pr.author.login)) or "?"
  local author = M._truncate(raw_name:gsub("%s*%[.-%]%s*$", ""), cols.author - 2)

  -- ADO column (icon only)
  local ado_str = M.icons.ado_none
  local ado_hl = "PlzError"
  local ab_id = ((pr.title or ""):match("AB#(%d+)") or (pr.body or ""):match("AB#(%d+)"))
  if ab_id then
    if ado_item then
      local is_bug = ado_item.type == "Bug"
      ado_str = is_bug and M.icons.ado_bug or M.icons.ado_story
      local item_state = (ado_item.state or ""):lower()
      if item_state == "new" or item_state == "active" then
        ado_hl = is_bug and "PlzError" or "PlzSuccess"
      else
        ado_hl = "PlzFaint"
      end
    else
      ado_str = M.icons.dot
      ado_hl = "PlzFaint"
    end
  end

  -- Release version (from ADO story tags)
  local release_str = ""
  if ado_item and ado_item.type ~= "Bug" and ado_item.tags and ado_item.tags ~= "" then
    for tag in ado_item.tags:gmatch("[^;]+") do
      local ver = vim.trim(tag):match("^[Rr]elease%s*(.+)")
      if ver then
        release_str = vim.trim(ver)
        break
      end
    end
  end

  -- PR icon: blue for open, gray for draft
  local pr_icon = M.icons.pr
  local pr_hl = "PlzOpen"
  if pr.isDraft then pr_icon = M.icons.draft; pr_hl = "PlzDraft"
  elseif (pr.state or "") == "MERGED" then pr_icon = M.icons.merged; pr_hl = "PlzMerged"
  elseif (pr.state or "") == "CLOSED" then pr_icon = M.icons.closed; pr_hl = "PlzClosed"
  end

  -- Comment count
  local comment_count = type(pr.comments) == "table" and #pr.comments or 0
  local comment_str = comment_count > 0 and tostring(comment_count) or ""

  return build_row({
    { " " .. pr_icon, cols.state, pr_hl },
    { " " .. ado_str, cols.ado, ado_hl },
    { release_str, cols.release, release_str ~= "" and "PlzFaint" or nil },
    { comment_str, cols.comments, comment_count > 0 and "PlzFaint" or nil },
    { " " .. rev_icon, cols.review, rev_hl },
    { " " .. ci_icon, cols.ci, ci_hl },
    { M._lines_cell(add_str, del_str), cols.lines, M._lines_regions(add_str, del_str) },
    { M._relative_time(pr.updatedAt), cols.updated, "PlzFaint" },
    { M._relative_time(pr.createdAt), cols.created, "PlzFaint" },
    { M._truncate(pr.baseRefName or "?", cols.base - 2), cols.base, "PlzFaint" },
    { author, cols.author, "PlzFaint" },
    { title, nil, "PlzFaint" },
  })
end

--- Format column header line.
--- @param cols table from compute_columns
--- @return string
--- @return table[] regions
function M.header_line(cols)
  return build_row({
    { "", cols.state, "PlzHeader" },
    { " " .. M.icons.ado_h, cols.ado, "PlzHeader" },
    { M.icons.release, cols.release, "PlzHeader" },
    { M.icons.comments, cols.comments, "PlzHeader" },
    { " " .. M.icons.review_h, cols.review, "PlzHeader" },
    { " " .. M.icons.ci, cols.ci, "PlzHeader" },
    { M.icons.lines, cols.lines, "PlzHeader" },
    { M.icons.updated, cols.updated, "PlzHeader" },
    { M.icons.created, cols.created, "PlzHeader" },
    { M.icons.branch, cols.base, "PlzHeader" },
    { "Author", cols.author, "PlzHeader" },
    { "Title", nil, "PlzHeader" },
  })
end

--- Format preview pane content for a PR.
--- @param pr table|nil
--- @param ado_item table|nil  Fetched ADO work item (nil = not yet loaded)
--- @return string[] lines
--- @return table[] line_regions (array of arrays of regions per line)
function M.format_preview(pr, ado_item)
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

  -- ADO work item
  local ado_id = (pr.title or ""):match("AB#(%d+)") or (pr.body or ""):match("AB#(%d+)")
  if ado_id then
    if ado_item then
      local type_icon = ado_item.type == "Bug" and M.icons.ado_bug or M.icons.ado_story
      local ado_line = string.format("  %s AB#%s · %s · %s",
        type_icon, ado_item.id, ado_item.state or "?", ado_item.assigned_to or "?")
      add(ado_line, { { 0, #ado_line, "PlzAccent" } })

      -- Tags as pills
      if ado_item.tags and ado_item.tags ~= "" then
        local tag_parts = {}
        local tag_regions = {}
        local pos = 2 -- starting after "  " indent
        table.insert(tag_parts, "  ")
        for tag in ado_item.tags:gmatch("[^;]+") do
          tag = vim.trim(tag)
          if tag ~= "" then
            local pill = " " .. tag .. " "
            if #tag_parts > 1 then
              table.insert(tag_parts, " ")
              pos = pos + 1
            end
            table.insert(tag_parts, pill)
            table.insert(tag_regions, { pos, pos + #pill, "PlzPill" })
            pos = pos + #pill
          end
        end
        if #tag_parts > 1 then
          add(table.concat(tag_parts), tag_regions)
        end
      end
    else
      add(string.format("  ADO AB#%s  loading...", ado_id), { { 0, 0, "PlzFaint" } })
    end
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

function M._lines_cell(add_str, del_str)
  return add_str .. " " .. del_str
end

function M._lines_regions(add_str, del_str)
  return {
    { 0, #add_str, "PlzDiffAdd" },
    { #add_str + 1, #add_str + 1 + #del_str, "PlzDiffRemove" },
  }
end

function M._clean_title(title, branch)
  -- Remove anything in brackets: [Main], [Bug], [Shipping Redesign], etc.
  title = title:gsub("%s*%[.-%]%s*", " ")
  -- Remove AB#12345 references
  title = title:gsub("%s*AB#%d+%s*", " ")
  -- Remove branch name if present (with slashes/dashes)
  if branch and branch ~= "" then
    -- Escape pattern special chars in branch name
    local escaped = branch:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    title = title:gsub("%s*" .. escaped .. "%s*", " ")
    -- Also try without the prefix (e.g. "feature/" removed, just the slug)
    local slug = branch:match("[^/]+$") or ""
    if slug ~= "" and slug ~= branch then
      local escaped_slug = slug:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
      title = title:gsub("%s*" .. escaped_slug .. "%s*", " ")
    end
  end
  -- Remove leading/trailing dashes, dots, colons, whitespace
  title = title:gsub("^[%s%-%.:–—]+", ""):gsub("[%s%-%.:–—]+$", "")
  -- Collapse multiple spaces
  title = title:gsub("%s+", " ")
  return title
end

function M._format_number(n)
  if n >= 1000 then
    return string.format("%.1fk", n / 1000)
  end
  return tostring(n)
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

function M._review_icon(decision, reviews)
  if decision == "APPROVED" then return M.icons.approved, "PlzSuccess"
  elseif decision == "CHANGES_REQUESTED" then return M.icons.changes, "PlzError"
  elseif type(reviews) == "table" and #reviews > 0 then return M.icons.comment, "PlzFaint"
  else return M.icons.waiting, "PlzWarning"
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
