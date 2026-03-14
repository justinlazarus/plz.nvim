local gh = require("plz.gh")
local icons = require("plz.dashboard.render").icons

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

--- Return val if it is a real value (not nil, not vim.NIL), else fallback.
local function real(val, fallback)
  if val == nil or val == vim.NIL then return fallback end
  return val
end

--- Pad or truncate a string to exactly `w` display columns.
local function fit(s, w)
  local dw = vim.fn.strdisplaywidth(s)
  if dw > w then
    return vim.fn.strcharpart(s, 0, w - 1) .. "…"
  end
  return s .. string.rep(" ", w - dw)
end

--- Rotating author highlight groups for colored participants.
local author_hls = { "PlzAccent", "PlzSuccess", "PlzWarning", "PlzMerged", "PlzOpen", "PlzRed", "PlzYellow" }

--- Assigned color map: login -> highlight group.
--- Built once per build_thread_list() call from all unique participants.
local author_color_map = {}

--- Get the assigned highlight for an author login.
local function author_hl(login)
  return author_color_map[login] or "PlzFaint"
end

--- Assign colors to all unique logins, round-robin across the palette.
--- Called from build_thread_list() after collecting all participants.
local function assign_author_colors(logins)
  author_color_map = {}
  for i, login in ipairs(logins) do
    author_color_map[login] = author_hls[((i - 1) % #author_hls) + 1]
  end
end

--- Extract a short display name from a GitHub user object.
--- Tries user.name first (first word, or part before @), else login prefix before _.
local function display_name(user)
  if not user then return "?" end
  local name = real(user.name, nil)
  if name then
    -- Handle email-style names: take part before @
    local before_at = name:match("^([^@]+)")
    if before_at then name = before_at end
    -- Take first word (or part before _)
    return name:match("^([^_%s]+)") or name
  end
  -- Login fallback: strip org suffix (e.g. jtomko_costco -> jtomko)
  local login = user.login or "?"
  return login:match("^([^_]+)") or login
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
    M.build_thread_list()

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

--- Fetch thread resolution status via GraphQL.
--- @param owner string
--- @param repo string
--- @param pr_number number
function M.fetch_thread_resolution(owner, repo, pr_number)
  local query = string.format([[
query {
  repository(owner: "%s", name: "%s") {
    pullRequest(number: %d) {
      reviewThreads(first: 100) {
        nodes {
          isResolved
          comments(first: 1) {
            nodes { databaseId }
          }
        }
      }
    }
  }
}]], owner, repo, pr_number)

  gh.run({ "api", "graphql", "-f", "query=" .. query }, function(data, err)
    if err then return end
    local pr_data = (((data or {}).data or {}).repository or {}).pullRequest
    local thread_nodes = pr_data and pr_data.reviewThreads and pr_data.reviewThreads.nodes or {}
    state.thread_resolved = {}
    for _, t in ipairs(thread_nodes) do
      local comments = t.comments and t.comments.nodes or {}
      if #comments > 0 and comments[1].databaseId then
        state.thread_resolved[comments[1].databaseId] = t.isResolved == true
      end
    end
    -- Rebuild thread list to pick up resolved status, then re-render
    M.build_thread_list()
    if state.active_collection == 2 then
      local c = state.collections and state.collections[2]
      if c and c.top_buf and vim.api.nvim_buf_is_valid(c.top_buf) then
        M.render_reviews(c.top_buf, state.top_win)
      end
    end
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

--- Build a list of review-grouped items for C2's top buffer.
--- Each item represents a review, grouping its threads together.
--- Stored in state.c2_items.
function M.build_thread_list()
  local all_comments = state.review_comments or {}
  local reviews = state.reviews or {}
  local resolved = state.thread_resolved or {}

  -- 1) Build conversation threads from all review comments
  local threads = {}      -- root_id -> { comments = {...}, root = comment }
  local thread_order = {} -- ordered root_ids
  for _, c in ipairs(all_comments) do
    local root_id = c.in_reply_to_id or c.id
    if not threads[root_id] then
      threads[root_id] = { comments = {}, root = c }
      table.insert(thread_order, root_id)
    end
    table.insert(threads[root_id].comments, c)
  end

  -- Enrich each thread with metadata
  local enriched_threads = {}
  for _, root_id in ipairs(thread_order) do
    local thr = threads[root_id]
    local root = thr.root
    local participants = {}
    local participant_logins = {}
    local seen = {}
    local latest_at = ""
    for _, c in ipairs(thr.comments) do
      local login = (c.user and c.user.login) or "?"
      if not seen[login] then
        seen[login] = true
        table.insert(participant_logins, login)
        table.insert(participants, display_name(c.user))
      end
      local at = c.created_at or ""
      if at > latest_at then latest_at = at end
    end
    table.insert(enriched_threads, {
      root_id = root_id,
      comments = thr.comments,
      path = real(root.path, ""),
      line = real(root.line, real(root.original_line, "")),
      participants = participants,
      participant_logins = participant_logins,
      count = #thr.comments,
      latest_at = latest_at,
      resolved = resolved[root_id],
      review_id = root.pull_request_review_id,
    })
  end

  -- 2) Group threads by their root comment's review_id
  local threads_by_review = {} -- review_id -> list of threads
  local unattached = {}        -- threads with no review_id
  for _, thr in ipairs(enriched_threads) do
    if thr.review_id then
      if not threads_by_review[thr.review_id] then
        threads_by_review[thr.review_id] = {}
      end
      table.insert(threads_by_review[thr.review_id], thr)
    else
      table.insert(unattached, thr)
    end
  end

  -- 3) Build review-based items: one row per review
  local items = {}
  local used_review_ids = {}

  -- Index reviews by id for lookup
  local reviews_by_id = {}
  for _, r in ipairs(reviews) do
    reviews_by_id[r.id] = r
  end

  -- Process reviews in order (they come sorted by submitted_at from the API)
  for _, r in ipairs(reviews) do
    local review_threads = threads_by_review[r.id] or {}
    local has_threads = #review_threads > 0
    local has_body = r.body and r.body ~= ""
    local is_action = r.state == "APPROVED" or r.state == "CHANGES_REQUESTED"

    if has_threads or is_action or has_body then
      -- Aggregate stats across threads
      local total_msgs = 0
      local total_threads = #review_threads
      local all_resolved = total_threads > 0 and true or nil
      local any_unresolved = false
      local latest_at = r.submitted_at or ""
      local seen_p = {}
      local participants = {}
      local participant_logins = {}

      -- Add review author first
      local author_login = (r.user and r.user.login) or "?"
      seen_p[author_login] = true
      table.insert(participant_logins, author_login)
      table.insert(participants, display_name(r.user))

      for _, thr in ipairs(review_threads) do
        total_msgs = total_msgs + thr.count
        if thr.resolved == false then any_unresolved = true end
        if thr.resolved ~= true then all_resolved = false end
        if thr.latest_at > latest_at then latest_at = thr.latest_at end
        for _, login in ipairs(thr.participant_logins) do
          if not seen_p[login] then
            seen_p[login] = true
            table.insert(participant_logins, login)
            table.insert(participants, display_name(
              thr.comments[1] and thr.comments[1].user)) -- approximate
          end
        end
      end

      -- Find display names from actual user objects in threads
      -- (the above is approximate; fix participant names from thread data)
      participants = {}
      participant_logins = {}
      seen_p = {}
      -- Review author first
      seen_p[author_login] = true
      table.insert(participant_logins, author_login)
      table.insert(participants, display_name(r.user))
      for _, thr in ipairs(review_threads) do
        for j, login in ipairs(thr.participant_logins) do
          if not seen_p[login] then
            seen_p[login] = true
            table.insert(participant_logins, login)
            table.insert(participants, thr.participants[j])
          end
        end
      end

      -- Determine aggregate resolved status
      local resolved_status
      if total_threads == 0 then
        resolved_status = nil -- no threads, just a review action
      elseif all_resolved then
        resolved_status = true
      elseif any_unresolved then
        resolved_status = false
      end

      table.insert(items, {
        type = "review",
        review = r,
        threads = review_threads,
        thread_count = total_threads,
        msg_count = total_msgs,
        participants = participants,
        participant_logins = participant_logins,
        latest_at = latest_at,
        resolved = resolved_status,
      })
      used_review_ids[r.id] = true
    end
  end

  -- 4) Add unattached threads (no review_id) as individual items
  for _, thr in ipairs(unattached) do
    table.insert(items, {
      type = "thread",
      threads = { thr },
      thread_count = 1,
      msg_count = thr.count,
      participants = thr.participants,
      participant_logins = thr.participant_logins,
      latest_at = thr.latest_at,
      resolved = thr.resolved,
    })
  end

  -- Sort by latest activity (newest first)
  table.sort(items, function(a, b) return a.latest_at > b.latest_at end)

  -- Collect all unique logins and assign colors
  local seen_logins = {}
  local unique_logins = {}
  for _, c in ipairs(all_comments) do
    local login = (c.user and c.user.login) or "?"
    if not seen_logins[login] then
      seen_logins[login] = true
      table.insert(unique_logins, login)
    end
  end
  for _, r in ipairs(reviews) do
    local login = (r.user and r.user.login) or "?"
    if not seen_logins[login] then
      seen_logins[login] = true
      table.insert(unique_logins, login)
    end
  end
  assign_author_colors(unique_logins)

  state.c2_items = items
end

--- Render the C2 top buffer: one row per review (with grouped threads).
--- Column order: status | who | threads | msgs | age | what
--- @param buf number Buffer handle
--- @param win number|nil Window handle
function M.render_reviews(buf, win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  local render = require("plz.dashboard.render")
  local items = state.c2_items or {}
  local lines = {}
  local hl_regions = {}

  -- Fixed column widths
  local status_w  = 4
  local threads_w = 4
  local msgs_w    = 5
  local age_w     = 6

  -- PR author login for icon prefix
  local pr_author = state.pr and state.pr.author and state.pr.author.login or ""
  local pr_icon = "\xef\x93\x8a" -- U+F4CA

  -- First pass: build per-item people data and find max width
  local row_data = {}
  local max_people_w = 8 -- minimum
  for _, item in ipairs(items) do
    local parts = {}
    local regions = {}
    local pos = 0
    local total = #item.participants
    local show = math.min(2, total)
    for i = 1, show do
      if i > 1 then
        table.insert(parts, ", ")
        pos = pos + 2
      end
      local login = item.participant_logins[i] or ""
      local name = item.participants[i]
      if login == pr_author then
        table.insert(parts, pr_icon .. " ")
        pos = pos + #pr_icon + 1
      end
      table.insert(parts, name)
      table.insert(regions, { pos, pos + #name, author_hl(login) })
      pos = pos + #name
    end
    if total > 2 then
      local extra = ", +" .. (total - 2)
      table.insert(parts, extra)
      table.insert(regions, { pos, pos + #extra, "PlzFaint" })
    end
    local str = table.concat(parts)
    local w = vim.fn.strdisplaywidth(str)
    if w > max_people_w then max_people_w = w end
    table.insert(row_data, { item = item, people_str = str, people_regions = regions })
  end
  local people_w = max_people_w + 2 -- padding

  -- Winbar header with column icons
  local hdr = fit("\xf3\xb0\x90\x97", status_w)
    .. fit(icons.person or "", people_w)
    .. fit(icons.comments or "", threads_w)
    .. fit(icons.comments or "", msgs_w)
    .. fit(icons.updated or "", age_w)
    .. (icons.ci or "")
  local winbar = "%#PlzHeader#  " .. hdr:gsub("%%", "%%%%")
    .. "%=%#PlzFaint#Threads & Reviews  "
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].winbar = winbar
    vim.wo[win].cursorline = true
  end

  if #items == 0 then
    table.insert(lines, "  Loading…")
    table.insert(hl_regions, { { 2, 12, "PlzFaint" } })
  end

  -- Second pass: render rows
  for _, rd in ipairs(row_data) do
    local item = rd.item

    -- Status icon: aggregate resolved for reviews with threads, review state otherwise
    local status_icon, status_hl
    if item.thread_count and item.thread_count > 0 then
      if item.resolved == true then
        status_icon, status_hl = "●", "PlzSuccess"
      elseif item.resolved == false then
        status_icon, status_hl = "○", "PlzYellow"
      else
        status_icon, status_hl = " ", "PlzFaint"
      end
    elseif item.review then
      local rs = (item.review.state or "")
      if rs == "APPROVED" then
        status_icon, status_hl = "●", "PlzSuccess"
      elseif rs == "CHANGES_REQUESTED" then
        status_icon, status_hl = icons.changes, "PlzError"
      elseif rs == "DISMISSED" then
        status_icon, status_hl = icons.dismissed or "○", "PlzFaint"
      else
        status_icon, status_hl = icons.waiting, "PlzWarning"
      end
    else
      status_icon, status_hl = " ", "PlzFaint"
    end

    local people_col = fit(rd.people_str, people_w)

    -- Threads column
    local threads_str = item.thread_count and item.thread_count > 0
      and tostring(item.thread_count) or ""
    local threads_col = fit(threads_str, threads_w)

    -- Msgs column
    local msgs_str = item.msg_count and item.msg_count > 0
      and tostring(item.msg_count) or ""
    local msgs_col = fit(msgs_str, msgs_w)

    -- Age column
    local age_str = render._relative_time(item.latest_at)
    local age_col = fit(age_str, age_w)

    -- What column (last, no padding)
    local tail
    if item.review then
      local rs = (item.review.state or ""):lower():gsub("_", " ")
      if item.thread_count and item.thread_count > 0 then
        tail = rs
      else
        tail = rs
      end
    else
      -- Unattached thread
      local thr = item.threads and item.threads[1]
      if thr then
        tail = (thr.path:match("[^/]+$") or thr.path)
        if thr.line ~= "" then tail = tail .. ":" .. tostring(thr.line) end
      else
        tail = ""
      end
    end

    local status_col = fit(status_icon, status_w)
    local line = "  " .. status_col .. people_col .. threads_col .. msgs_col .. age_col .. tail
    table.insert(lines, line)

    -- Highlights
    local p = 2
    local p1 = p + #status_col
    local p_people_start = p1
    local p2 = p1 + #people_col
    local p3 = p2 + #threads_col
    local p4 = p3 + #msgs_col
    local p5 = p4 + #age_col

    local regions = {
      { p, p1, status_hl },
      { p2, p3, "PlzFaint" },
      { p3, p4, "PlzFaint" },
      { p4, p5, "PlzFaint" },
      { p5, #line, "PlzFaint" },
    }
    for _, pr in ipairs(rd.people_regions) do
      table.insert(regions, { p_people_start + pr[1], p_people_start + pr[2], pr[3] })
    end
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

--- Render detail for a selected C2 item in the bottom buffer.
--- Shows review body (if any) followed by all threads in the review.
--- @param buf number Buffer handle
--- @param win number|nil Window handle
--- @param item_idx number 1-indexed index into state.c2_items
function M.render_threads(buf, win, item_idx)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  local render = require("plz.dashboard.render")
  local items = state.c2_items or {}
  local item = items[item_idx]
  if not item then return end

  local lines = {}
  local hl_regions = {}

  -- Get window width for bordered boxes
  local win_w = 60
  if win and vim.api.nvim_win_is_valid(win) then
    win_w = vim.api.nvim_win_get_width(win) - 2
  end
  local box_w = math.max(30, win_w)

  --- Helper: add a bordered author header box
  local function add_author_box(login, user, time_ago)
    local name = display_name(user)
    local hl = author_hl(login)
    local inner = " " .. name .. "  " .. time_ago .. " "
    local inner_w = vim.fn.strdisplaywidth(inner)
    local pad_needed = math.max(0, box_w - 2 - inner_w)
    inner = inner .. string.rep(" ", pad_needed)

    local top = "╭" .. string.rep("─", box_w - 2) .. "╮"
    table.insert(lines, top)
    table.insert(hl_regions, { { 0, #top, "PlzBorder" } })

    local mid = "│" .. inner .. "│"
    table.insert(lines, mid)
    local name_start = #"│ "
    local name_end = name_start + #name
    local time_start = name_end + 2
    local time_end = time_start + #time_ago
    table.insert(hl_regions, {
      { 0, name_start, "PlzBorder" },
      { name_start, name_end, hl },
      { time_start, time_end, "PlzFaint" },
      { time_end, #mid, "PlzBorder" },
    })

    local bot = "╰" .. string.rep("─", box_w - 2) .. "╯"
    table.insert(lines, bot)
    table.insert(hl_regions, { { 0, #bot, "PlzBorder" } })
  end

  --- Helper: render a single thread's comments
  local function render_thread(thr, show_path)
    for ci, comment in ipairs(thr.comments) do
      local login = (comment.user and comment.user.login) or "?"
      local time_ago = render._relative_time(comment.created_at or "")

      if ci > 1 then
        table.insert(lines, "")
        table.insert(hl_regions, {})
      end

      add_author_box(login, comment.user, time_ago)

      -- File path reference (only on first comment of thread)
      if ci == 1 and show_path and thr.path ~= "" then
        table.insert(lines, "")
        table.insert(hl_regions, {})
        local path_ref = thr.path
        if thr.line ~= "" then
          path_ref = path_ref .. "#l" .. tostring(thr.line)
        end
        table.insert(lines, path_ref)
        table.insert(hl_regions, { { 0, #path_ref, "PlzFaint" } })
      end

      table.insert(lines, "")
      table.insert(hl_regions, {})

      local cbody = (comment.body or ""):gsub("\r", "")
      cbody = cbody:gsub("<!%-%-.-%-%->", "")
      cbody = vim.trim(cbody)
      if cbody ~= "" then
        for _, raw in ipairs(vim.split(cbody, "\n", { plain = true })) do
          table.insert(lines, raw)
          table.insert(hl_regions, {})
        end
      end

      table.insert(lines, "")
      table.insert(hl_regions, {})
    end
  end

  -- Review body (if present)
  local r = item.review
  if r then
    local login = (r.user and r.user.login) or "?"
    local review_state = r.state or ""
    local time_ago = render._relative_time(r.submitted_at or "")

    local icon, icon_hl
    if review_state == "APPROVED" then
      icon, icon_hl = icons.approved, "PlzSuccess"
    elseif review_state == "CHANGES_REQUESTED" then
      icon, icon_hl = icons.changes, "PlzError"
    elseif review_state == "COMMENTED" then
      icon, icon_hl = icons.comment, "PlzAccent"
    elseif review_state == "DISMISSED" then
      icon, icon_hl = icons.dismissed or "○", "PlzFaint"
    else
      icon, icon_hl = icons.waiting, "PlzWarning"
    end

    local name = display_name(r.user)
    local state_label = review_state:lower():gsub("_", " ")
    local status_line = icon .. " " .. name .. " " .. state_label .. " " .. time_ago
    table.insert(lines, status_line)
    local icon_end = #icon
    local name_start = icon_end + 1
    local name_end = name_start + #name
    table.insert(hl_regions, {
      { 0, icon_end, icon_hl },
      { name_start, name_end, author_hl(login) },
      { name_end, #status_line, "PlzFaint" },
    })

    local body = r.body or ""
    if body ~= "" then
      table.insert(lines, "")
      table.insert(hl_regions, {})
      body = body:gsub("\r", ""):gsub("<!%-%-.-%-%->", "")
      body = body:gsub("\n\n\n+", "\n\n")
      body = vim.trim(body)
      for _, raw in ipairs(vim.split(body, "\n", { plain = true })) do
        table.insert(lines, raw)
        table.insert(hl_regions, {})
      end
    end
  end

  -- Render each thread in this review
  local review_threads = item.threads or {}
  for ti, thr in ipairs(review_threads) do
    -- Separator between threads
    if ti > 1 or r then
      table.insert(lines, "")
      table.insert(hl_regions, {})
      local sep = string.rep("─", box_w)
      table.insert(lines, sep)
      table.insert(hl_regions, { { 0, #sep, "PlzBorder" } })
      table.insert(lines, "")
      table.insert(hl_regions, {})
    end

    render_thread(thr, true)
  end

  -- Winbar
  if win and vim.api.nvim_win_is_valid(win) then
    local wb
    if r then
      local name = display_name(r.user)
      local login = (r.user and r.user.login) or "?"
      local state_label = (r.state or ""):lower():gsub("_", " ")
      wb = "%#" .. author_hl(login) .. "#  " .. name:gsub("%%", "%%%%")
        .. "%#PlzFaint#  " .. state_label:gsub("%%", "%%%%")
      if item.thread_count and item.thread_count > 0 then
        wb = wb .. "  " .. item.thread_count .. " threads"
        .. "  " .. item.msg_count .. " msgs"
      end
    else
      wb = "%#PlzAccent#  thread"
    end
    if item.resolved == true then
      wb = wb .. " %#PlzSuccess#● resolved"
    elseif item.resolved == false then
      wb = wb .. " %#PlzYellow#○ unresolved"
    end
    vim.wo[win].winbar = wb
    vim.wo[win].cursorline = false
    vim.wo[win].wrap = true
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  pcall(vim.treesitter.start, buf, "markdown")

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
