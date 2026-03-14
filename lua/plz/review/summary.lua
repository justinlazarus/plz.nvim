local ado = require("plz.ado")
local icons = require("plz.dashboard.render").icons
local md = require("plz.review.markdown")

local M = {}

local ns = vim.api.nvim_create_namespace("plz_review_summary")
--- Reference to the shared review state table, set via M.setup().
local state

--- Store a reference to shared state.
--- @param state_ref table  The shared review state table
function M.setup(state_ref)
  state = state_ref
end

--- Return the namespace id used for summary extmarks.
function M.ns()
  return ns
end

--- Render based on active collection.
function M.render()
  local ac = state.active_collection or 3
  if ac == 1 then
    local c = state.collections and state.collections[1]
    if c then
      M.render_commits_to(c.top_buf, state.top_win)
      M.render_detail_to(c.bottom_buf, state.bottom_win)
    end
  end
end

--- Render info view into a specific buffer/window.
--- @param buf number Buffer handle
--- @param win number|nil Window handle (for options)
function M.render_info_to(buf, win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  -- Temporarily set summary_buf so render_info writes to the right buffer
  local orig_buf = state.summary_buf
  state.summary_buf = buf
  M.render_info()
  state.summary_buf = orig_buf
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].cursorline = false
    vim.wo[win].winbar = nil
  end
end

--- Render commits view into a specific buffer/window.
--- @param buf number Buffer handle
--- @param win number|nil Window handle (for winbar/options)
function M.render_commits_to(buf, win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  -- Temporarily set summary_buf/win so render_commits writes to the right buffer
  local orig_buf = state.summary_buf
  local orig_win = state.summary_win
  state.summary_buf = buf
  state.summary_win = win
  M.render_commits()
  state.summary_buf = orig_buf
  state.summary_win = orig_win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].cursorline = true
  end
end

--- Render the commits view in the summary buffer.
function M.render_commits()
  local render = require("plz.dashboard.render")
  local commits = state.commits or {}
  local lines = {}
  local hl_regions = {}

  -- Fixed column widths
  local sha_w     = 12
  local author_w  = 24
  local lines_w   = 14
  local time_w    = 6
  local ci_w      = 10

  local has_checks = false
  for _, c in ipairs(commits) do
    if c.checks_total > 0 then has_checks = true; break end
  end

  local win_w = state.summary_win and vim.api.nvim_win_is_valid(state.summary_win)
    and vim.api.nvim_win_get_width(state.summary_win) or 90

  --- Pad or truncate a string to exactly `w` display columns.
  local function fit(s, w)
    local dw = vim.fn.strdisplaywidth(s)
    if dw > w then
      return vim.fn.strcharpart(s, 0, w - 1) .. "…"
    end
    return s .. string.rep(" ", w - dw)
  end

  -- Column order: SHA, Author, +/-, Age, [Checks], Message
  -- Header row with icon labels
  local left_fixed = sha_w + author_w + lines_w + time_w + (has_checks and ci_w or 0)
  local msg_w = math.max(10, win_w - 2 - left_fixed)

  -- Build sticky header via winbar (statusline format)
  local count_str = #commits .. " cmts"
  local count_col = fit(count_str, sha_w):gsub("%%", "%%%%")
  local rest = fit(icons.person or "", author_w)
    .. fit(icons.lines or "", lines_w)
    .. fit(icons.updated or "", time_w)
  if has_checks then
    rest = rest .. fit(icons.ci or "", ci_w)
  end
  rest = rest .. (icons.commit or "")
  local winbar = "%#PlzAccent#  " .. count_col .. "%#PlzHeader#" .. rest:gsub("%%", "%%%%")
    .. "%=%#PlzFaint#PR Detail  "
  if state.summary_win and vim.api.nvim_win_is_valid(state.summary_win) then
    vim.wo[state.summary_win].winbar = winbar
  end

  if #commits == 0 then
    table.insert(lines, "  Loading…")
    table.insert(hl_regions, { { 2, 12, "PlzFaint" } })
  end

  for _, c in ipairs(commits) do
    local time_ago = render._relative_time(c.date)

    local sha_col    = fit(c.short_oid, sha_w)
    local author_col = fit("@" .. c.author, author_w)
    local add_str = "+" .. render._format_number(c.additions)
    local del_str = "-" .. render._format_number(c.deletions)
    local lines_col  = fit(add_str .. " " .. del_str, lines_w)
    local time_col   = fit(time_ago, time_w)

    local ci_col = ""
    local ci_icon_str = ""
    if has_checks then
      if c.checks_total > 0 then
        if c.check_state == "SUCCESS" then
          ci_icon_str = icons.ci_pass
        elseif c.check_state == "FAILURE" or c.check_state == "ERROR" then
          ci_icon_str = icons.ci_fail
        else
          ci_icon_str = icons.ci_wait
        end
        ci_col = fit(ci_icon_str .. " " .. c.checks_passed .. "/" .. c.checks_total, ci_w)
      else
        ci_col = fit("", ci_w)
      end
    end

    local msg = c.message
    if vim.fn.strdisplaywidth(msg) > msg_w then
      msg = vim.fn.strcharpart(msg, 0, msg_w - 1) .. "…"
    end

    local line = "  " .. sha_col .. author_col .. lines_col .. time_col .. ci_col .. msg

    table.insert(lines, line)

    -- Highlights
    local regions = {}
    -- Left columns (SHA, author): faint
    local faint1_end = 2 + #sha_col + #author_col
    table.insert(regions, { 2, faint1_end, "PlzFaint" })
    -- +/- with color
    local add_start = faint1_end
    local add_end = add_start + #add_str
    table.insert(regions, { add_start, add_end, "PlzDiffAdd" })
    local del_start = add_end + 1
    local del_end = del_start + #del_str
    table.insert(regions, { del_start, del_end, "PlzDiffRemove" })
    -- Rest of lines_col + time + ci: faint
    local left_end = faint1_end + #lines_col + #time_col + #ci_col
    table.insert(regions, { del_end, left_end, "PlzFaint" })
    -- CI icon color override
    if has_checks and c.checks_total > 0 and ci_icon_str ~= "" then
      local ci_pos = line:find(ci_icon_str, 2, true)
      if ci_pos then
        local ci_hl = c.check_state == "SUCCESS" and "PlzSuccess"
          or (c.check_state == "FAILURE" or c.check_state == "ERROR") and "PlzError"
          or "PlzWarning"
        table.insert(regions, { ci_pos - 1, ci_pos - 1 + #ci_icon_str, ci_hl })
      end
    end

    table.insert(hl_regions, regions)
  end

  vim.bo[state.summary_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.summary_buf, 0, -1, false, lines)
  vim.bo[state.summary_buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.summary_buf, ns, 0, -1)
  for i, regions in ipairs(hl_regions) do
    for _, r in ipairs(regions) do
      if r[1] < r[2] and r[1] < #lines[i] then
        pcall(vim.api.nvim_buf_set_extmark, state.summary_buf, ns, i - 1, r[1], {
          end_col = math.min(r[2], #lines[i]),
          hl_group = r[3],
        })
      end
    end
  end
end

--- Render the description view in the summary buffer.
function M.render_description()
  local pr = state.pr
  local body = pr.body or ""
  local lines = {}
  local hl_regions = {}

  body = body:gsub("\r", "")
  local pad = "  "
  local in_code_block = false

  if body == "" then
    table.insert(lines, pad .. "No description provided.")
    table.insert(hl_regions, { { 2, 28, "PlzFaint" } })
  else
    for _, raw in ipairs(vim.split(body, "\n", { plain = true })) do
      -- Code fence toggle
      if raw:match("^```") then
        in_code_block = not in_code_block
        -- Skip the fence line itself
        table.insert(lines, "")
        table.insert(hl_regions, {})
      elseif in_code_block then
        local display = pad .. "  " .. raw
        table.insert(lines, display)
        table.insert(hl_regions, { { #pad, #display, "PlzCode" } })
      else
        local display, regions = md.parse_line(raw, #pad)
        table.insert(lines, pad .. display)
        table.insert(hl_regions, regions)
      end
    end
  end

  vim.bo[state.summary_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.summary_buf, 0, -1, false, lines)
  vim.bo[state.summary_buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.summary_buf, ns, 0, -1)
  for i, regions in ipairs(hl_regions) do
    for _, r in ipairs(regions) do
      if r[1] < r[2] and r[1] < #lines[i] then
        pcall(vim.api.nvim_buf_set_extmark, state.summary_buf, ns, i - 1, r[1], {
          end_col = math.min(r[2], #lines[i]),
          hl_group = r[3],
        })
      end
    end
  end
end

--- Render the summary buffer (fixed header) — the "info" view.
function M.render_info()
  local pr = state.pr
  local render = require("plz.dashboard.render")
  local lines = {}
  local hl_regions = {}

  -- Line 1: PR title
  local title_line = string.format("  PR #%d: %s", pr.number, pr.title or "")
  table.insert(lines, title_line)
  local pr_num_str = "  PR #" .. tostring(pr.number)
  table.insert(hl_regions, {
    { 0, #pr_num_str, "PlzAccent" },
  })

  -- Line 2: Status pill + branches
  local state_icon, state_hl, state_label
  if pr.isDraft then
    state_icon, state_hl, state_label = icons.draft, "PlzDraft", "Draft"
  elseif (pr.state or "") == "MERGED" then
    state_icon, state_hl, state_label = icons.merged, "PlzMerged", "Merged"
  elseif (pr.state or "") == "CLOSED" then
    state_icon, state_hl, state_label = icons.closed, "PlzClosed", "Closed"
  else
    state_icon, state_hl, state_label = icons.open, "PlzOpen", "Open"
  end
  local pill = string.format(" %s %s ", state_icon, state_label)
  local branch_line = string.format("  %s  %s ← %s",
    pill, pr.baseRefName or "?", pr.headRefName or "?")
  table.insert(lines, branch_line)
  local pill_start = 2
  local pill_end = pill_start + #pill
  table.insert(hl_regions, {
    { pill_start, pill_end, "PlzPill" },
    { pill_start, pill_end, state_hl },
    { pill_end, #branch_line, "PlzFaint" },
  })

  -- Line 3: Author + time + file count + additions/deletions
  local author_name = (pr.author and (pr.author.name or pr.author.login)) or "?"
  local time_ago = render._relative_time(pr.createdAt) .. " ago"
  local total_adds, total_dels = 0, 0
  for _, file in ipairs(state.files) do
    total_adds = total_adds + (file.additions or 0)
    total_dels = total_dels + (file.deletions or 0)
  end
  local stats = string.format("%d files", #state.files)
  if total_adds > 0 then stats = stats .. string.format("  +%d", total_adds) end
  if total_dels > 0 then stats = stats .. string.format("  -%d", total_dels) end
  local meta_line = string.format("  by @%s · %s · %s", author_name, time_ago, stats)
  table.insert(lines, meta_line)
  -- Highlight: author bold, rest faint, +/- colored
  local author_start = 2
  local author_end = author_start + #("by @" .. author_name)
  local meta_regions = {
    { author_start, author_end, "Normal" },
    { author_end, #meta_line, "PlzFaint" },
  }
  if total_adds > 0 then
    local p = meta_line:find("+" .. tostring(total_adds))
    if p then table.insert(meta_regions, { p - 1, p - 1 + #("+" .. tostring(total_adds)), "PlzGreen" }) end
  end
  if total_dels > 0 then
    local p = meta_line:find("-" .. tostring(total_dels))
    if p then table.insert(meta_regions, { p - 1, p - 1 + #("-" .. tostring(total_dels)), "PlzRed" }) end
  end
  table.insert(hl_regions, meta_regions)

  -- Line 4: Reviewers
  local reviewer_line, reviewer_regions = M._build_reviewer_line(pr)
  table.insert(lines, reviewer_line)
  table.insert(hl_regions, reviewer_regions)

  -- Line 5: ADO work item
  local ado_line, ado_regions = M.build_ado_line(pr)
  table.insert(lines, ado_line)
  table.insert(hl_regions, ado_regions)

  vim.bo[state.summary_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.summary_buf, 0, -1, false, lines)
  vim.bo[state.summary_buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.summary_buf, ns, 0, -1)
  for i, regions in ipairs(hl_regions) do
    for _, r in ipairs(regions) do
      if r[1] < r[2] then
        pcall(vim.api.nvim_buf_set_extmark, state.summary_buf, ns, i - 1, r[1], {
          end_col = math.min(r[2], #lines[i]),
          hl_group = r[3],
        })
      end
    end
  end
end

--- Build the reviewer line with status icons.
--- @param pr table PR data
--- @return string line
--- @return table[] hl_regions
function M._build_reviewer_line(pr)
  local parts = {}
  local regions = {}
  local pos = 2 -- start after "  "
  local seen = {}

  -- Completed reviews (latest per author)
  local latest = {}
  for _, review in ipairs(pr.reviews or {}) do
    local login = review.author and review.author.login
    if login then
      latest[login] = review.state
    end
  end

  for login, review_state in pairs(latest) do
    seen[login] = true
    local icon, hl
    if review_state == "APPROVED" then
      icon, hl = icons.approved, "PlzSuccess"
    elseif review_state == "CHANGES_REQUESTED" then
      icon, hl = icons.changes, "PlzError"
    elseif review_state == "COMMENTED" then
      icon, hl = icons.comment, "PlzFaint"
    else
      icon, hl = icons.waiting, "PlzWarning"
    end

    if #parts > 0 then
      table.insert(parts, ", ")
      pos = pos + 2
    end
    local entry = string.format("%s @%s", icon, login)
    table.insert(parts, entry)
    -- Icon highlight
    local icon_len = #icon
    table.insert(regions, { pos, pos + icon_len, hl })
    pos = pos + #entry
  end

  -- Pending review requests (not yet reviewed)
  for _, req in ipairs(pr.reviewRequests or {}) do
    local login = (req.login) or (req.name) or (req.slug)
    if login and not seen[login] then
      seen[login] = true
      if #parts > 0 then
        table.insert(parts, ", ")
        pos = pos + 2
      end
      local entry = string.format("%s @%s", icons.waiting, login)
      table.insert(parts, entry)
      local icon_len = #icons.waiting
      table.insert(regions, { pos, pos + icon_len, "PlzWarning" })
      pos = pos + #entry
    end
  end

  local line = "  " .. table.concat(parts)
  if #parts == 0 then
    line = "  No reviewers"
    regions = { { 2, #line, "PlzFaint" } }
  end
  return line, regions
end

--- Build the ADO work item line.
--- @param pr table PR data
--- @return string line
--- @return table[] hl_regions
function M.build_ado_line(pr)
  local body = (pr.body or ""):gsub("<!%-%-.-%-%->", "")
  local ab_id = ((pr.title or ""):match("AB#(%d+)") or body:match("AB#(%d+)"))
  if not ab_id then
    return "", {}
  end

  -- Check if we already have cached ADO data
  if state.ado_item then
    if state.ado_item.not_found then
      return "", {}
    end
    return M.format_ado_line(state.ado_item)
  end

  -- Kick off async fetch, show placeholder for now
  local line = "  AB#" .. ab_id .. " loading…"
  ado.fetch_work_item(ab_id, function(item, err)
    if item then
      state.ado_item = item
    else
      state.ado_item = { not_found = true }
    end
    -- Re-render detail view if C1 is active
    if state.active_collection == 1 then
      local c = state.collections and state.collections[1]
      if c and c.bottom_buf and vim.api.nvim_buf_is_valid(c.bottom_buf) then
        M.render_detail_to(c.bottom_buf, state.bottom_win)
      end
    end
  end)
  return line, { { 2, #line, "PlzFaint" } }
end

--- Format a resolved ADO work item line.
--- @param item table ADO work item
--- @return string line
--- @return table[] hl_regions
function M.format_ado_line(item)
  local ado_type = item.type or ""
  local icon = ado_type == "Bug" and icons.ado_bug
    or ado_type == "Task" and icons.ado_task
    or icons.ado_story
  local item_state = (item.state or ""):lower()
  local icon_hl = item_state == "new" and "PlzDraft"
    or item_state == "active" and "PlzOpen"
    or (item_state == "resolved" or item_state == "closed") and "PlzMerged"
    or "PlzFaint"

  local prefix = icon .. " AB#" .. item.id
  local parts = { prefix, item.state, item.assigned_to }
  local line = "  " .. table.concat(parts, " · ")
  local regions = {
    { 2, 2 + #icon, icon_hl },
    { 2 + #icon, #line, "PlzFaint" },
  }

  -- Render tags as pills
  if item.tags and item.tags ~= "" then
    local tag_list = vim.split(item.tags, ";%s*")
    for _, tag in ipairs(tag_list) do
      local trimmed = vim.trim(tag)
      if trimmed ~= "" then
        local tag_pill = " " .. trimmed .. " "
        line = line .. "  " .. tag_pill
        local pill_start = #line - #tag_pill
        local pill_end = #line
        table.insert(regions, { pill_start, pill_end, "PlzPill" })
        table.insert(regions, { pill_start, pill_end, "PlzFaint" })
      end
    end
  end

  return line, regions
end

--- Build the info lines (PR header) without writing to buffer.
--- @return string[] lines
--- @return table[] hl_regions
function M._build_info_lines()
  local pr = state.pr
  local render = require("plz.dashboard.render")
  local lines = {}
  local hl_regions = {}

  -- Line 1: PR title
  local title_line = string.format("  PR #%d: %s", pr.number, pr.title or "")
  table.insert(lines, title_line)
  local pr_num_str = "  PR #" .. tostring(pr.number)
  table.insert(hl_regions, {
    { 0, #pr_num_str, "PlzAccent" },
  })

  -- Line 2: Status pill + branches
  local state_icon, state_hl, state_label
  if pr.isDraft then
    state_icon, state_hl, state_label = icons.draft, "PlzDraft", "Draft"
  elseif (pr.state or "") == "MERGED" then
    state_icon, state_hl, state_label = icons.merged, "PlzMerged", "Merged"
  elseif (pr.state or "") == "CLOSED" then
    state_icon, state_hl, state_label = icons.closed, "PlzClosed", "Closed"
  else
    state_icon, state_hl, state_label = icons.open, "PlzOpen", "Open"
  end
  local pill = string.format(" %s %s ", state_icon, state_label)
  local branch_line = string.format("  %s  %s ← %s",
    pill, pr.baseRefName or "?", pr.headRefName or "?")
  table.insert(lines, branch_line)
  local pill_start = 2
  local pill_end = pill_start + #pill
  table.insert(hl_regions, {
    { pill_start, pill_end, "PlzPill" },
    { pill_start, pill_end, state_hl },
    { pill_end, #branch_line, "PlzFaint" },
  })

  -- Line 3: Author + time + file count + additions/deletions
  local author_name = (pr.author and (pr.author.name or pr.author.login)) or "?"
  local time_ago = render._relative_time(pr.createdAt) .. " ago"
  local total_adds, total_dels = 0, 0
  for _, file in ipairs(state.files) do
    total_adds = total_adds + (file.additions or 0)
    total_dels = total_dels + (file.deletions or 0)
  end
  local stats = string.format("%d files", #state.files)
  if total_adds > 0 then stats = stats .. string.format("  +%d", total_adds) end
  if total_dels > 0 then stats = stats .. string.format("  -%d", total_dels) end
  local meta_line = string.format("  by @%s · %s · %s", author_name, time_ago, stats)
  table.insert(lines, meta_line)
  local author_start = 2
  local author_end = author_start + #("by @" .. author_name)
  local meta_regions = {
    { author_start, author_end, "Normal" },
    { author_end, #meta_line, "PlzFaint" },
  }
  if total_adds > 0 then
    local p = meta_line:find("+" .. tostring(total_adds))
    if p then table.insert(meta_regions, { p - 1, p - 1 + #("+" .. tostring(total_adds)), "PlzGreen" }) end
  end
  if total_dels > 0 then
    local p = meta_line:find("-" .. tostring(total_dels))
    if p then table.insert(meta_regions, { p - 1, p - 1 + #("-" .. tostring(total_dels)), "PlzRed" }) end
  end
  table.insert(hl_regions, meta_regions)

  -- Line 4: Reviewers
  local reviewer_line, reviewer_regions = M._build_reviewer_line(pr)
  table.insert(lines, reviewer_line)
  table.insert(hl_regions, reviewer_regions)

  -- Line 5: ADO work item
  local ado_line, ado_regions = M.build_ado_line(pr)
  table.insert(lines, ado_line)
  table.insert(hl_regions, ado_regions)

  return lines, hl_regions
end

--- Build the description lines without writing to buffer.
--- @return string[] lines
--- @return table[] hl_regions
--- Render combined info + description into the summary buffer.
function M.render_detail()
  local info_lines, info_hl = M._build_info_lines()

  local lines = {}
  local hl_regions = {}

  -- Info
  vim.list_extend(lines, info_lines)
  vim.list_extend(hl_regions, info_hl)

  -- Separator
  table.insert(lines, "")
  table.insert(hl_regions, {})
  local sep = "  " .. string.rep("─", 40)
  table.insert(lines, sep)
  table.insert(hl_regions, { { 2, #sep, "PlzFaint" } })
  table.insert(lines, "")
  table.insert(hl_regions, {})

  -- Description: raw markdown with HTML comments stripped
  local body = (state.pr.body or ""):gsub("\r", "")
  body = body:gsub("<!%-%-.-%-%->", "")
  -- Collapse runs of 3+ blank lines into 2
  body = body:gsub("\n\n\n+", "\n\n")
  body = vim.trim(body)
  if body == "" then
    table.insert(lines, "No description provided.")
    table.insert(hl_regions, { { 0, 26, "PlzFaint" } })
  else
    for _, raw in ipairs(vim.split(body, "\n", { plain = true })) do
      table.insert(lines, raw)
      table.insert(hl_regions, {})
    end
  end

  -- Write
  local buf = state.summary_buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Start treesitter markdown highlighting on the buffer
  pcall(vim.treesitter.start, buf, "markdown")

  -- Apply info section highlights (above separator only)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, regions in ipairs(hl_regions) do
    for _, r in ipairs(regions) do
      if r[1] < r[2] and r[1] < #lines[i] then
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, r[1], {
          end_col = math.min(r[2], #lines[i]),
          hl_group = r[3],
        })
      end
    end
  end
end

--- Render combined info + description into a specific buffer/window.
--- @param buf number Buffer handle
--- @param win number|nil Window handle
function M.render_detail_to(buf, win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local orig_buf = state.summary_buf
  state.summary_buf = buf
  M.render_detail()
  state.summary_buf = orig_buf
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].cursorline = false
    vim.wo[win].wrap = true
    vim.wo[win].winbar = nil
  end
end

return M
