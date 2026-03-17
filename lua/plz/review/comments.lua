local gh = require("plz.gh")
local icons = require("plz.dashboard.render").icons
local md = require("plz.review.markdown")

local M = {}

local ns_comments = vim.api.nvim_create_namespace("plz_review_comments")

--- Reference to the shared review state table, set via M.setup().
local state

--- Store a reference to shared state.
--- @param state_ref table  The shared review state table
function M.setup(state_ref)
  state = state_ref
end

--- Return the namespace id used for comment extmarks.
function M.ns()
  return ns_comments
end

--- Fetch review comments for the PR.
--- @param owner string
--- @param repo string
--- @param pr_number number
function M.fetch_review_comments(owner, repo, pr_number)
  gh.run({
    "api", string.format("repos/%s/%s/pulls/%d/comments?per_page=100", owner, repo, pr_number),
  }, function(comments, err)
    if err then return end
    state.review_comments = comments or {}
    M.index_comments()
    -- Re-index comments by review and rebuild thread list (for C2)
    local ok, rd = pcall(require, "plz.review.collections.review_detail")
    if ok then
      rd.index_comments_by_review()
      rd.build_thread_list()
      -- Re-render C2 top and selected thread detail
      if state.active_collection == 2 then
        local c = state.collections and state.collections[2]
        if c and c.top_buf and vim.api.nvim_buf_is_valid(c.top_buf) then
          rd.render_reviews(c.top_buf, state.top_win)
        end
        rd.refresh_selected_thread()
      end
    end
    -- Re-render file list to show comment counts
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      local review_files = require("plz.review.files")
      review_files.render()
      if state.current_file_idx then
        review_files.highlight_active()
      end
    end
    -- If a diff is open, show comment indicators
    if state.diff_rhs_buf and vim.api.nvim_buf_is_valid(state.diff_rhs_buf) then
      M.show_comment_indicators()
    end
  end)
end

--- Index comments by file path and line for quick lookup.
function M.index_comments()
  state.comments_by_file = {}
  state.comments_by_file_left = {}

  -- Group threads: top-level comments and their replies
  local threads = {} -- in_reply_to_id or own id -> list of comments
  local top_level = {} -- ordered list of top-level comment ids

  for _, c in ipairs(state.review_comments) do
    local thread_id = c.in_reply_to_id or c.id
    if not threads[thread_id] then
      threads[thread_id] = {}
    end
    table.insert(threads[thread_id], c)
    if not c.in_reply_to_id then
      table.insert(top_level, c)
    end
  end

  for _, root in ipairs(top_level) do
    local path = root.path or ""
    local line = (type(root.line) == "number" and root.line)
      or (type(root.original_line) == "number" and root.original_line)
      or (type(root.original_position) == "number" and root.original_position)
      or nil
    local side = (type(root.side) == "string" and root.side) or "RIGHT"
    if line then
      local map = side == "LEFT" and state.comments_by_file_left or state.comments_by_file
      if not map[path] then map[path] = {} end
      if not map[path][line] then map[path][line] = {} end
      table.insert(map[path][line], {
        root = root,
        replies = threads[root.id] or { root },
      })
    end
  end
end

--- Get comment count for a file.
--- @param path string
--- @return number
function M.file_comment_count(path)
  local count = 0
  for _, threads in pairs(state.comments_by_file[path] or {}) do
    count = count + #threads
  end
  for _, threads in pairs(state.comments_by_file_left[path] or {}) do
    count = count + #threads
  end
  return count
end

--- Re-sync diff scroll positions after virtual lines change.
--- Centers current cursor and forces both windows to the same topline.
function M._resync_scroll()
  local lhs_win = state.diff_lhs_win
  local rhs_win = state.diff_rhs_win
  if not lhs_win or not vim.api.nvim_win_is_valid(lhs_win) then return end
  if not rhs_win or not vim.api.nvim_win_is_valid(rhs_win) then return end

  -- Get the current window (where cursor is)
  local cur_win = vim.api.nvim_get_current_win()
  local other_win = cur_win == rhs_win and lhs_win or rhs_win

  -- Center cursor in current window
  vim.api.nvim_win_call(cur_win, function() vim.cmd("normal! zz") end)

  -- Read topline from current window and apply to other
  local topline = vim.fn.getwininfo(cur_win)[1].topline
  vim.api.nvim_win_call(other_win, function()
    vim.fn.winrestview({ topline = topline })
  end)
end

--- Show comment indicators (badges) on diff lines that have comments.
function M.show_comment_indicators()
  if not state.current_file_idx then return end
  local file = state.files[state.current_file_idx]
  if not file then return end
  local path = file.filename or file.path or ""
  local layout_mod = require("plz.diff.layout")

  -- Clear previous indicators
  if state.diff_rhs_buf and vim.api.nvim_buf_is_valid(state.diff_rhs_buf) then
    vim.api.nvim_buf_clear_namespace(state.diff_rhs_buf, ns_comments, 0, -1)
  end
  if state.diff_lhs_buf and vim.api.nvim_buf_is_valid(state.diff_lhs_buf) then
    vim.api.nvim_buf_clear_namespace(state.diff_lhs_buf, ns_comments, 0, -1)
  end

  -- Place indicators on RHS
  local rhs_comments = state.comments_by_file[path] or {}
  if state.diff_rhs_buf and vim.api.nvim_buf_is_valid(state.diff_rhs_buf) then
    local rhs_nums = layout_mod._line_nums[state.diff_rhs_buf] or {}
    for buf_line, orig_line in pairs(rhs_nums) do
      if rhs_comments[orig_line] then
        local thread_count = #rhs_comments[orig_line]
        local badge = " " .. icons.comment .. " " .. thread_count .. " "
        local key = "RIGHT:" .. state.diff_rhs_buf .. ":" .. buf_line
        if state.expanded_comments[key] then
          M.place_comment(state.diff_rhs_buf, state.diff_lhs_buf, buf_line, badge, rhs_comments[orig_line])
        else
          pcall(vim.api.nvim_buf_set_extmark, state.diff_rhs_buf, ns_comments, buf_line - 1, 0, {
            virt_text = { { badge, "PlzPill" } },
            virt_text_pos = "right_align",
          })
        end
      end
    end
  end

  -- Place indicators on LHS
  local lhs_comments = state.comments_by_file_left[path] or {}
  if state.diff_lhs_buf and vim.api.nvim_buf_is_valid(state.diff_lhs_buf) then
    local lhs_nums = layout_mod._line_nums[state.diff_lhs_buf] or {}
    for buf_line, orig_line in pairs(lhs_nums) do
      if lhs_comments[orig_line] then
        local thread_count = #lhs_comments[orig_line]
        local badge = " " .. icons.comment .. " " .. thread_count .. " "
        local key = "LEFT:" .. state.diff_lhs_buf .. ":" .. buf_line
        if state.expanded_comments[key] then
          M.place_comment(state.diff_lhs_buf, state.diff_rhs_buf, buf_line, badge, lhs_comments[orig_line])
        else
          pcall(vim.api.nvim_buf_set_extmark, state.diff_lhs_buf, ns_comments, buf_line - 1, 0, {
            virt_text = { { badge, "PlzPill" } },
            virt_text_pos = "right_align",
          })
        end
      end
    end
  end
end

--- Infer treesitter language from the current review file.
--- @return string|nil
local function infer_ts_lang()
  local file = state.files and state.files[state.current_file_idx]
  if not file then return nil end
  local filename = file.filename or ""
  return md.infer_ts_lang(filename)
end

--- Place a comment badge + expanded virtual lines below a diff line.
--- @param buf number Buffer to show comments in
--- @param other_buf number The opposite side buffer (for padding)
--- @param buf_line number 1-indexed buffer line
--- @param badge string Badge text (e.g. " 💬 1 ")
--- @param threads table[] List of comment threads at this line
function M.place_comment(buf, other_buf, buf_line, badge, threads)
  local render = require("plz.dashboard.render")
  local virt_lines = {}
  local win_w = 80
  if buf == state.diff_rhs_buf and state.diff_rhs_win and vim.api.nvim_win_is_valid(state.diff_rhs_win) then
    win_w = vim.api.nvim_win_get_width(state.diff_rhs_win)
  elseif buf == state.diff_lhs_buf and state.diff_lhs_win and vim.api.nvim_win_is_valid(state.diff_lhs_win) then
    win_w = vim.api.nvim_win_get_width(state.diff_lhs_win)
  end

  local border = string.rep("─", win_w)
  table.insert(virt_lines, { { border, "PlzBorder" } })

  for _, thread in ipairs(threads) do
    for _, comment in ipairs(thread.replies) do
      local author = (comment.user and comment.user.login) or "?"
      local time_ago = render._relative_time(comment.created_at or "")
      local header = " @" .. author .. "  " .. time_ago
      table.insert(virt_lines, { { header, "PlzAccent" } })

      -- Render body as markdown with word-wrap
      local body = (comment.body or ""):gsub("\r", "")
      local in_code_block = false
      local code_block_lang = nil
      local code_block_lines = {}
      for _, raw_line in ipairs(vim.split(body, "\n", { plain = true })) do
        if raw_line:match("^```") then
          if not in_code_block then
            in_code_block = true
            code_block_lang = raw_line:match("^```(%S+)") or ""
            code_block_lines = {}
            if code_block_lang == "suggestion" then
              -- Show original line(s) as removals before showing the replacement
              local c_line = (type(comment.line) == "number" and comment.line)
                or (type(comment.original_line) == "number" and comment.original_line)
                or nil
              local c_start = (type(comment.start_line) == "number" and comment.start_line)
                or (type(comment.original_start_line) == "number" and comment.original_start_line)
                or c_line
              -- Try to read original lines from the diff buffer
              if c_line and buf and vim.api.nvim_buf_is_valid(buf) then
                local orig_lines = {}
                for orig = (c_start or c_line), c_line do
                  -- Find buffer line for this original line
                  for bl, ol in pairs(state._line_nums or {}) do
                    if ol == orig then
                      local ok, bline = pcall(vim.api.nvim_buf_get_lines, buf, bl - 1, bl, false)
                      if ok and bline[1] then
                        table.insert(orig_lines, bline[1])
                      end
                      break
                    end
                  end
                end
                for _, ol in ipairs(orig_lines) do
                  table.insert(virt_lines, { { " - ", "PlzDiffRemove" }, { vim.trim(ol), "PlzDiffRemoveLine" } })
                end
              end
            else
              local code_border = " " .. string.rep("╌", math.min(40, win_w - 4))
              table.insert(virt_lines, { { code_border, "PlzBorder" } })
            end
          else
            -- Closing fence — highlight collected code block
            in_code_block = false
            local ts_lang = code_block_lang
            if ts_lang == "suggestion" or ts_lang == "" then
              ts_lang = infer_ts_lang()
            end
            local is_suggestion = (code_block_lang == "suggestion")
            for _, cl in ipairs(code_block_lines) do
              if is_suggestion then
                table.insert(virt_lines, { { " + ", "PlzDiffAdd" }, { cl, "PlzDiffAddLine" } })
              else
                table.insert(virt_lines, { { " │ ", "PlzBorder" }, { cl, "Normal" } })
              end
            end
            local code_border = " " .. string.rep("╌", math.min(40, win_w - 4))
            table.insert(virt_lines, { { code_border, "PlzBorder" } })
            code_block_lang = nil
          end
        elseif in_code_block then
          table.insert(code_block_lines, raw_line)
        else
          -- Parse markdown for this line
          local display, regions = md.parse_line(raw_line, 1)
          local text = " " .. display
          -- Word wrap
          if vim.fn.strdisplaywidth(text) <= win_w then
            local segments = md.regions_to_segments(text, regions, 1)
            table.insert(virt_lines, segments)
          else
            local remaining = text
            while #remaining > 0 do
              if vim.fn.strdisplaywidth(remaining) <= win_w then
                table.insert(virt_lines, { { remaining, "Normal" } })
                break
              end
              local cut = win_w - 1
              local space = remaining:sub(1, cut):match(".*()%s")
              if space and space > 1 then cut = space end
              table.insert(virt_lines, { { remaining:sub(1, cut), "Normal" } })
              remaining = " " .. remaining:sub(cut + 1)
            end
          end
        end
      end
      table.insert(virt_lines, { { "", "Normal" } }) -- blank line between comments
    end
  end

  table.insert(virt_lines, { { border, "PlzBorder" } })

  -- Add badge + virtual lines in one extmark
  pcall(vim.api.nvim_buf_set_extmark, buf, ns_comments, buf_line - 1, 0, {
    virt_text = { { badge, "PlzPill" } },
    virt_text_pos = "right_align",
    virt_lines = virt_lines,
    virt_lines_above = false,
  })

  -- Add matching blank padding on the other side to keep alignment
  if other_buf and vim.api.nvim_buf_is_valid(other_buf) then
    local padding = {}
    for _ = 1, #virt_lines do
      table.insert(padding, { { "", "Normal" } })
    end
    pcall(vim.api.nvim_buf_set_extmark, other_buf, ns_comments, buf_line - 1, 0, {
      virt_lines = padding,
      virt_lines_above = false,
    })
  end
end

--- Toggle comment expansion at the cursor line.
function M.toggle_comment_at_cursor()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local cursor_line = vim.api.nvim_win_get_cursor(win)[1] -- 1-indexed

  if buf ~= state.diff_lhs_buf and buf ~= state.diff_rhs_buf then return end

  local side = buf == state.diff_rhs_buf and "RIGHT" or "LEFT"
  local key = side .. ":" .. buf .. ":" .. cursor_line

  -- Check if this line has comments
  if not state.current_file_idx then return end
  local file = state.files[state.current_file_idx]
  if not file then return end
  local path = file.filename or file.path or ""
  local layout_mod = require("plz.diff.layout")
  local line_nums = layout_mod._line_nums[buf] or {}
  local orig_line = line_nums[cursor_line]
  if not orig_line then return end

  local map = side == "LEFT" and state.comments_by_file_left or state.comments_by_file
  local threads = (map[path] or {})[orig_line]
  if not threads or #threads == 0 then return end

  -- Toggle
  state.expanded_comments[key] = not state.expanded_comments[key]

  -- Re-render all indicators (clears and re-applies)
  M.show_comment_indicators()
  M._resync_scroll()
end

--- Check if a file has any comments (either side).
--- @param file_idx number
--- @return boolean
local function file_has_comments(file_idx)
  local file = state.files[file_idx]
  if not file then return false end
  local path = file.filename or file.path or ""
  local rhs = state.comments_by_file[path]
  local lhs = state.comments_by_file_left[path]
  return (rhs and not vim.tbl_isempty(rhs)) or (lhs and not vim.tbl_isempty(lhs))
end

--- Build sorted list of commented buffer lines for the current diff.
--- @return number[] commented_lines, string side, number buf
local function get_commented_lines_in_diff()
  if not state.diff_rhs_buf or not vim.api.nvim_buf_is_valid(state.diff_rhs_buf) then
    return {}, "RIGHT", 0
  end
  if not state.current_file_idx then return {}, "RIGHT", 0 end

  local file = state.files[state.current_file_idx]
  if not file then return {}, "RIGHT", 0 end
  local path = file.filename or file.path or ""

  local layout_mod = require("plz.diff.layout")

  -- Prefer RHS comments, fall back to LHS
  local side = "RIGHT"
  local buf = state.diff_rhs_buf
  local map = state.comments_by_file
  local file_comments = map[path] or {}

  if vim.tbl_isempty(file_comments) then
    side = "LEFT"
    buf = state.diff_lhs_buf
    map = state.comments_by_file_left
    file_comments = map[path] or {}
  end

  if vim.tbl_isempty(file_comments) then return {}, side, buf end

  local line_nums = layout_mod._line_nums[buf] or {}
  local commented_lines = {}
  for buf_line, orig_line in pairs(line_nums) do
    if file_comments[orig_line] then
      table.insert(commented_lines, buf_line)
    end
  end
  table.sort(commented_lines)
  return commented_lines, side, buf
end

--- Jump to the next or previous comment, crossing file boundaries.
--- Works from either the file list buffer or a diff buffer.
--- @param direction number 1 for next, -1 for previous
function M.jump_comment(direction)
  local change_detail = require("plz.review.collections.change_detail")
  local win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(win)

  local in_diff = cur_buf == state.diff_lhs_buf or cur_buf == state.diff_rhs_buf
  local cursor_line = in_diff and vim.api.nvim_win_get_cursor(win)[1] or 0

  -- Try to find next/prev comment in current file's diff
  if in_diff and state.current_file_idx then
    local commented_lines, side, buf = get_commented_lines_in_diff()
    if #commented_lines > 0 then
      local target
      if direction > 0 then
        for _, line in ipairs(commented_lines) do
          if line > cursor_line then target = line; break end
        end
      else
        for i = #commented_lines, 1, -1 do
          if commented_lines[i] < cursor_line then target = commented_lines[i]; break end
        end
      end

      if target then
        -- Close current expanded comment
        local current_key = side .. ":" .. buf .. ":" .. cursor_line
        if state.expanded_comments[current_key] then
          state.expanded_comments[current_key] = false
        end
        -- Open target
        state.expanded_comments[side .. ":" .. buf .. ":" .. target] = true
        M.show_comment_indicators()
        local diff_win = buf == state.diff_rhs_buf and state.diff_rhs_win or state.diff_lhs_win
        if diff_win and vim.api.nvim_win_is_valid(diff_win) then
          pcall(vim.api.nvim_win_set_cursor, diff_win, { target, 0 })
        end
        M._resync_scroll()
        return
      end
    end
  end

  -- No more comments in current file in this direction — cross to next/prev file
  local start_idx = state.current_file_idx or 1
  local total = #state.files
  if total == 0 then
    vim.notify("plz: no comments", vim.log.levels.INFO)
    return
  end

  -- Search for next file with comments
  local idx = start_idx
  for _ = 1, total do
    idx = idx + direction
    if idx > total then idx = 1
    elseif idx < 1 then idx = total end

    if file_has_comments(idx) then
      -- Close any expanded comment in current diff
      state.expanded_comments = {}

      -- Open the diff for this file (async — comment jump happens in callback)
      state._jump_comment_direction = direction
      change_detail.open_diff(idx)
      return
    end
  end

  vim.notify("plz: no comments", vim.log.levels.INFO)
end

--- Called after a diff loads to continue a cross-file comment jump.
function M.continue_jump_after_load()
  local direction = state._jump_comment_direction
  state._jump_comment_direction = nil
  if not direction then return end

  local commented_lines, side, buf = get_commented_lines_in_diff()
  if #commented_lines == 0 then return end

  local target
  if direction > 0 then
    target = commented_lines[1]
  else
    target = commented_lines[#commented_lines]
  end
  if not target then return end

  state.expanded_comments[side .. ":" .. buf .. ":" .. target] = true
  M.show_comment_indicators()
  local diff_win = buf == state.diff_rhs_buf and state.diff_rhs_win or state.diff_lhs_win
  if diff_win and vim.api.nvim_win_is_valid(diff_win) then
    vim.api.nvim_set_current_win(diff_win)
    pcall(vim.api.nvim_win_set_cursor, diff_win, { target, 0 })
  end
  M._resync_scroll()
end

return M
