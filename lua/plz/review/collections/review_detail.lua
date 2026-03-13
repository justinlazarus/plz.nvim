local gh = require("plz.gh")
local icons = require("plz.dashboard.render").icons
local md = require("plz.review.markdown")

local M = {}

local ns = vim.api.nvim_create_namespace("plz_review_detail")

--- Reference to the shared review state table, set via M.setup().
local state

--- Store a reference to shared state.
--- @param state_ref table  The shared review state table
function M.setup(state_ref)
  state = state_ref
end

--- Return the namespace id used for review detail extmarks.
function M.ns()
  return ns
end

--- Pad or truncate a string to exactly `w` display columns.
local function fit(s, w)
  local dw = vim.fn.strdisplaywidth(s)
  if dw > w then
    return vim.fn.strcharpart(s, 0, w - 1) .. "…"
  end
  return s .. string.rep(" ", w - dw)
end

--- Fetch review submissions for the PR.
--- @param owner string
--- @param repo string
--- @param pr_number number
--- @param callback function|nil
function M.fetch_reviews(owner, repo, pr_number, callback)
  gh.run({
    "api", string.format("repos/%s/%s/pulls/%d/reviews?per_page=100", owner, repo, pr_number),
  }, function(reviews, err)
    if err then
      vim.notify("plz: reviews: " .. err, vim.log.levels.WARN)
      state.reviews = {}
      if callback then callback() end
      return
    end
    -- Filter out PENDING reviews
    local filtered = {}
    for _, r in ipairs(reviews or {}) do
      if r.state ~= "PENDING" then
        table.insert(filtered, r)
      end
    end
    state.reviews = filtered
    M.index_comments_by_review()

    -- Re-render if C2 is active
    if state.active_collection == 2 then
      local c = state.collections and state.collections[2]
      if c and c.top_buf and vim.api.nvim_buf_is_valid(c.top_buf) then
        M.render_reviews(c.top_buf, state.top_win)
      end
    end

    if callback then callback() end
  end)
end

--- Index review comments by pull_request_review_id.
function M.index_comments_by_review()
  state.comments_by_review = {}
  for _, c in ipairs(state.review_comments or {}) do
    local review_id = c.pull_request_review_id
    if review_id then
      if not state.comments_by_review[review_id] then
        state.comments_by_review[review_id] = {}
      end
      table.insert(state.comments_by_review[review_id], c)
    end
  end
end

--- Render the review list in the top buffer.
--- @param buf number Buffer handle
--- @param win number|nil Window handle
function M.render_reviews(buf, win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  local render = require("plz.dashboard.render")
  local reviews = state.reviews or {}
  local lines = {}
  local hl_regions = {}

  local author_w = 24
  local state_w = 20
  local time_w = 8

  -- Winbar header
  if win and vim.api.nvim_win_is_valid(win) then
    local count_str = #reviews .. " reviews"
    local winbar = "%#PlzAccent#  " .. fit(count_str, author_w):gsub("%%", "%%%%")
      .. "%#PlzHeader#" .. fit("State", state_w):gsub("%%", "%%%%")
      .. fit(icons.updated or "", time_w):gsub("%%", "%%%%")
      .. "Comments"
    vim.wo[win].winbar = winbar
    vim.wo[win].cursorline = true
  end

  if #reviews == 0 then
    table.insert(lines, "  Loading…")
    table.insert(hl_regions, { { 2, 12, "PlzFaint" } })
  end

  for _, r in ipairs(reviews) do
    local author = (r.user and r.user.login) or "?"
    local review_state = r.state or ""
    local time_ago = render._relative_time(r.submitted_at or "")
    local review_id = r.id
    local comment_count = state.comments_by_review and state.comments_by_review[review_id]
      and #state.comments_by_review[review_id] or 0
    local has_body = r.body and r.body ~= ""

    local icon, hl
    if review_state == "APPROVED" then
      icon, hl = icons.approved, "PlzSuccess"
    elseif review_state == "CHANGES_REQUESTED" then
      icon, hl = icons.changes, "PlzError"
    elseif review_state == "COMMENTED" then
      icon, hl = icons.comment, "PlzAccent"
    elseif review_state == "DISMISSED" then
      icon, hl = icons.dismissed or "○", "PlzFaint"
    else
      icon, hl = icons.waiting, "PlzWarning"
    end

    local state_label = review_state:lower():gsub("_", " ")
    local state_col = fit(icon .. " " .. state_label, state_w)
    local author_col = fit("@" .. author, author_w)
    local time_col = fit(time_ago, time_w)
    local count_col = tostring(comment_count) .. " cmts"
    if has_body then count_col = count_col .. " + body" end

    local line = "  " .. author_col .. state_col .. time_col .. count_col
    table.insert(lines, line)

    local regions = {}
    local author_end = 2 + #author_col
    table.insert(regions, { 2, author_end, "Normal" })
    -- State icon color
    local icon_start = author_end
    local icon_end = icon_start + #icon
    table.insert(regions, { icon_start, icon_end, hl })
    -- Rest: faint
    table.insert(regions, { icon_end, #line, "PlzFaint" })
    table.insert(hl_regions, regions)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

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

--- Render threads for a selected review in the bottom buffer.
--- @param buf number Buffer handle
--- @param win number|nil Window handle
--- @param review_idx number 1-indexed review index
function M.render_threads(buf, win, review_idx)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  local render = require("plz.dashboard.render")
  local reviews = state.reviews or {}
  local review = reviews[review_idx]
  if not review then return end

  local lines = {}
  local hl_regions = {}
  local pad = "  "

  -- Show review body if present
  local body = review.body or ""
  if body ~= "" then
    body = body:gsub("\r", "")
    local in_code_block = false
    for _, raw in ipairs(vim.split(body, "\n", { plain = true })) do
      if raw:match("^```") then
        in_code_block = not in_code_block
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
    table.insert(lines, "")
    table.insert(hl_regions, {})
    local sep = pad .. string.rep("─", 40)
    table.insert(lines, sep)
    table.insert(hl_regions, { { 2, #sep, "PlzFaint" } })
    table.insert(lines, "")
    table.insert(hl_regions, {})
  end

  -- Show review comments (threads)
  local review_comments = state.comments_by_review
    and state.comments_by_review[review.id] or {}

  if #review_comments == 0 and body == "" then
    table.insert(lines, pad .. "No comments in this review.")
    table.insert(hl_regions, { { 2, 30, "PlzFaint" } })
  end

  -- Group into threads (top-level + replies)
  local threads = {}
  local thread_order = {}
  for _, c in ipairs(review_comments) do
    local thread_id = c.in_reply_to_id or c.id
    if not threads[thread_id] then
      threads[thread_id] = {}
      table.insert(thread_order, thread_id)
    end
    table.insert(threads[thread_id], c)
  end

  for _, thread_id in ipairs(thread_order) do
    local thread = threads[thread_id]
    local root = thread[1]

    -- File path header
    local path = root.path or ""
    local line_num = root.line or root.original_line or ""
    local path_line = pad .. (icons.file or "") .. " " .. path
    if line_num ~= "" then
      path_line = path_line .. ":" .. tostring(line_num)
    end
    table.insert(lines, path_line)
    table.insert(hl_regions, { { 2, #path_line, "PlzAccent" } })

    -- Each comment in the thread
    for _, comment in ipairs(thread) do
      local author = (comment.user and comment.user.login) or "?"
      local time_ago = render._relative_time(comment.created_at or "")
      local header = pad .. "  @" .. author .. "  " .. time_ago
      table.insert(lines, header)
      local author_end = #pad + 2 + 1 + #author
      table.insert(hl_regions, {
        { #pad + 2, author_end, "Normal" },
        { author_end, #header, "PlzFaint" },
      })

      -- Comment body
      local cbody = (comment.body or ""):gsub("\r", "")
      local in_code = false
      for _, raw in ipairs(vim.split(cbody, "\n", { plain = true })) do
        if raw:match("^```") then
          in_code = not in_code
          table.insert(lines, "")
          table.insert(hl_regions, {})
        elseif in_code then
          local display = pad .. "    " .. raw
          table.insert(lines, display)
          table.insert(hl_regions, { { #pad + 4, #display, "PlzCode" } })
        else
          local display, regions = md.parse_line(raw, #pad + 4)
          table.insert(lines, pad .. "    " .. display)
          table.insert(hl_regions, regions)
        end
      end
      table.insert(lines, "")
      table.insert(hl_regions, {})
    end

    -- Thread separator
    local tsep = pad .. string.rep("╌", 30)
    table.insert(lines, tsep)
    table.insert(hl_regions, { { 2, #tsep, "PlzFaint" } })
    table.insert(lines, "")
    table.insert(hl_regions, {})
  end

  -- Winbar
  if win and vim.api.nvim_win_is_valid(win) then
    local author = (review.user and review.user.login) or "?"
    local review_state = (review.state or ""):lower():gsub("_", " ")
    vim.wo[win].winbar = "%#PlzAccent#  @" .. author:gsub("%%", "%%%%")
      .. "%#PlzFaint#  " .. review_state:gsub("%%", "%%%%")
    vim.wo[win].cursorline = false
    vim.wo[win].wrap = true
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

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

return M
