local gh = require("plz.gh")
local comments = require("plz.review.comments")
local files = require("plz.review.files")
local layout = require("plz.review.layout")

local M = {}

local ns_active = vim.api.nvim_create_namespace("plz_review_active")

--- Reference to the shared review state table, set via M.setup().
local state

--- Store a reference to shared state.
--- @param state_ref table  The shared review state table
function M.setup(state_ref)
  state = state_ref
end

--- Toggle viewed state for a file via GitHub GraphQL mutation.
--- @param file_path string
function M.toggle_viewed(file_path)
  local pr = state.pr
  if not pr or not pr.id then return end

  local is_viewed = state.viewed[file_path]
  local mutation_name = is_viewed and "unmarkFileAsViewed" or "markFileAsViewed"

  local query = string.format([[
mutation {
  %s(input: { pullRequestId: "%s", path: "%s" }) {
    clientMutationId
  }
}]], mutation_name, pr.id, file_path:gsub('"', '\\"'))

  -- Optimistic update
  state.viewed[file_path] = not is_viewed
  files.render()
  if state.current_file_idx then
    files.highlight_active()
    files.update_diff_status()
  end

  gh.run({ "api", "graphql", "-f", "query=" .. query }, function(_data, err)
    if err then
      -- Revert on failure
      state.viewed[file_path] = is_viewed
      files.render()
      vim.notify("plz: failed to update viewed state", vim.log.levels.WARN)
    end
  end)
end

--- Create the vsplit diff area in the C3 bottom region.
function M.create_diff_split()
  -- Close the placeholder bottom window if it exists
  if state.bottom_win and vim.api.nvim_win_is_valid(state.bottom_win) then
    pcall(vim.api.nvim_win_close, state.bottom_win, true)
    state.bottom_win = nil
  end

  -- Focus file list (top window), split below
  vim.api.nvim_set_current_win(state.top_win or state.win)
  vim.cmd("botright split")
  state.diff_lhs_win = vim.api.nvim_get_current_win()

  -- Vsplit for RHS
  vim.cmd("vsplit")
  state.diff_rhs_win = vim.api.nvim_get_current_win()

  -- Even split between top and diff area
  vim.cmd("wincmd =")

  -- Keep focus on file list
  vim.api.nvim_set_current_win(state.top_win or state.win)
end

--- Clean up old diff buffers after new ones are already displayed.
--- @param old_lhs number|nil Old LHS buffer handle
--- @param old_rhs number|nil Old RHS buffer handle
function M.cleanup_old_bufs(old_lhs, old_rhs)
  local layout_mod = require("plz.diff.layout")
  for _, buf in ipairs({ old_lhs, old_rhs }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      layout_mod._line_nums[buf] = nil
      layout_mod._line_hls[buf] = nil
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

--- Check if treediff engine should be used for the given filetype.
--- @param ft string filetype
--- @return boolean
local function use_treediff(ft)
  local plz_config = require("plz").config
  local engine = plz_config.diff and plz_config.diff.engine or "auto"
  if engine == "native" then return false end

  local ok, td = pcall(require, "treediff")
  if not ok or not td._native then return false end

  if engine == "treediff" then return true end

  -- "auto": use treediff if tree-sitter parser exists for this filetype
  if ft == "" then return false end
  -- Resolve ft → tree-sitter language name (e.g. "cs" → "c_sharp")
  local ft_map_ok, ft_map = pcall(require, "treediff.ft_map")
  local ts_lang = ft_map_ok and ft_map[ft] or ft
  local has_ts = pcall(vim.treesitter.language.inspect, ts_lang)
  return has_ts
end

--- Populate diff windows using Neovim's built-in :diffthis.
--- If treediff is installed, its auto_highlight will fire automatically
--- and overlay token-level red/green highlights.
--- @param base_lines string[] Lines of the base (old) version
--- @param head_lines string[] Lines of the head (new) version
--- @param filename string Original filename (for filetype detection)
function M.populate_diff(base_lines, head_lines, filename)
  local layout_mod = require("plz.diff.layout")

  -- Remember old buffers so we can clean them up AFTER swapping
  local old_lhs = state.diff_lhs_buf
  local old_rhs = state.diff_rhs_buf

  -- Detect filetype from filename
  local ft = vim.filetype.match({ filename = filename }) or ""

  if use_treediff(ft) then
    M._populate_diff_treediff(base_lines, head_lines, ft, old_lhs, old_rhs)
  else
    M._populate_diff_native(base_lines, head_lines, ft, old_lhs, old_rhs)
  end

  local diff_state = {
    lhs_buf = state.diff_lhs_buf,
    rhs_buf = state.diff_rhs_buf,
    lhs_win = state.diff_lhs_win,
    rhs_win = state.diff_rhs_win,
  }

  -- File navigation and keymaps on diff buffers
  M.setup_diff_keymaps(diff_state)

  -- Show file position (sets winbar) then resize top to fit content
  files.update_diff_status()
  layout.resize_top_to_content()

  -- Sync wrapped-line alignment AFTER layout is finalized (resize changes widths)
  local ok_render, td_render = pcall(require, "treediff.render")
  if ok_render and td_render.sync_wrap_alignment then
    local lw, rw, lb, rb = state.diff_lhs_win, state.diff_rhs_win, state.diff_lhs_buf, state.diff_rhs_buf
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(lw) and vim.api.nvim_win_is_valid(rw) then
        td_render.sync_wrap_alignment(lw, rw, lb, rb)
      end
    end)
    vim.api.nvim_create_autocmd("WinResized", {
      group = vim.api.nvim_create_augroup("plz_wrap_align", { clear = true }),
      callback = function()
        if vim.api.nvim_win_is_valid(lw) and vim.api.nvim_win_is_valid(rw) then
          td_render.sync_wrap_alignment(lw, rw, lb, rb)
        end
      end,
    })
  end

  -- Show comment indicators
  if not state._jump_comment_direction then
    state.expanded_comments = {}
  end
  comments.show_comment_indicators()

  -- Continue cross-file comment jump if pending
  comments.continue_jump_after_load()

  -- Jump to specific line if requested from C2
  if state._jump_to_line then
    local target_line = state._jump_to_line
    state._jump_to_line = nil
    state._jump_to_path = nil

    -- Find the buffer line for this file line (may differ with treediff alignment)
    local rhs_nums = layout_mod._line_nums[state.diff_rhs_buf] or {}
    local buf_line
    for bl, fl in pairs(rhs_nums) do
      if fl == target_line then
        buf_line = bl
        break
      end
    end
    buf_line = buf_line or target_line  -- fallback to identity

    local line_count = vim.api.nvim_buf_line_count(state.diff_rhs_buf)
    if buf_line >= 1 and buf_line <= line_count then
      -- Expand the comment at this line
      local side = "RIGHT"
      local key = side .. ":" .. state.diff_rhs_buf .. ":" .. buf_line
      state.expanded_comments[key] = true
      comments.show_comment_indicators()

      -- Move cursor to the line
      local rhs_win = state.diff_rhs_win
      if rhs_win and vim.api.nvim_win_is_valid(rhs_win) then
        pcall(vim.api.nvim_win_set_cursor, rhs_win, { buf_line, 0 })
        vim.api.nvim_set_current_win(rhs_win)
      end
    end
  end

  state._suppress_diff_focus = nil
end

--- Native diff path: uses Neovim's :diffthis with identity line maps.
function M._populate_diff_native(base_lines, head_lines, ft, old_lhs, old_rhs)
  local layout_mod = require("plz.diff.layout")

  local lhs_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(lhs_buf, 0, -1, false, base_lines)
  vim.bo[lhs_buf].buftype = "nofile"
  vim.bo[lhs_buf].bufhidden = "wipe"
  vim.bo[lhs_buf].modifiable = false
  if ft ~= "" then vim.bo[lhs_buf].filetype = ft end

  local rhs_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(rhs_buf, 0, -1, false, head_lines)
  vim.bo[rhs_buf].buftype = "nofile"
  vim.bo[rhs_buf].bufhidden = "wipe"
  vim.bo[rhs_buf].modifiable = false
  if ft ~= "" then vim.bo[rhs_buf].filetype = ft end

  -- Identity line maps (buf line N → file line N)
  local lhs_nums = {}
  for i = 1, #base_lines do lhs_nums[i] = i end
  layout_mod._line_nums[lhs_buf] = lhs_nums

  local rhs_nums = {}
  for i = 1, #head_lines do rhs_nums[i] = i end
  layout_mod._line_nums[rhs_buf] = rhs_nums

  vim.api.nvim_win_set_buf(state.diff_lhs_win, lhs_buf)
  vim.api.nvim_win_set_buf(state.diff_rhs_win, rhs_buf)
  M.cleanup_old_bufs(old_lhs, old_rhs)

  vim.api.nvim_win_call(state.diff_lhs_win, function() vim.cmd("diffthis") end)
  vim.api.nvim_win_call(state.diff_rhs_win, function() vim.cmd("diffthis") end)

  for _, win in ipairs({ state.diff_lhs_win, state.diff_rhs_win }) do
    local ww = require("plz").config.diff.wordwrap
    vim.wo[win].wrap = ww
    vim.wo[win].linebreak = ww
    vim.wo[win].signcolumn = "no"
    vim.wo[win].statuscolumn = "%{%v:lua.PlzDiffLineNr()%}"
    vim.wo[win].statusline = layout.plz_statusline()
  end

  vim.opt.fillchars:append("diff: ")

  state.diff_lhs_buf = lhs_buf
  state.diff_rhs_buf = rhs_buf
end

--- Treediff path: tree-aware alignment with token highlights.
function M._populate_diff_treediff(base_lines, head_lines, ft, old_lhs, old_rhs)
  local layout_mod = require("plz.diff.layout")
  local treediff = require("treediff")
  local align = require("treediff.align")
  local highlight = require("treediff.highlight")
  local ft_map = require("treediff.ft_map")

  local lang = ft_map[ft] or ft
  local lhs_text = table.concat(base_lines, "\n") .. "\n"
  local rhs_text = table.concat(head_lines, "\n") .. "\n"

  -- Run structural diff
  local result = treediff.diff(lhs_text, rhs_text, lang)
  if not result then
    -- Fallback to native if diff fails
    M._populate_diff_native(base_lines, head_lines, ft, old_lhs, old_rhs)
    return
  end

  -- Build aligned padded arrays
  local aligned = align.build(base_lines, head_lines, result.anchors)
  local lhs_maps = align.build_maps(aligned.lhs_padded)
  local rhs_maps = align.build_maps(aligned.rhs_padded)

  -- Extract text arrays and build line number maps for Plz's comment system
  -- layout._line_nums expects: buf_lnum (1-indexed) → file_line (1-indexed)
  local lhs_texts = {}
  local lhs_nums = {}
  for i, entry in ipairs(aligned.lhs_padded) do
    lhs_texts[i] = entry.text
    if entry.orig ~= nil then
      lhs_nums[i] = entry.orig + 1  -- 0-indexed → 1-indexed
    end
  end

  local rhs_texts = {}
  local rhs_nums = {}
  for i, entry in ipairs(aligned.rhs_padded) do
    rhs_texts[i] = entry.text
    if entry.orig ~= nil then
      rhs_nums[i] = entry.orig + 1
    end
  end

  -- Create LHS buffer
  local lhs_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(lhs_buf, 0, -1, false, lhs_texts)
  vim.bo[lhs_buf].buftype = "nofile"
  vim.bo[lhs_buf].bufhidden = "wipe"
  vim.bo[lhs_buf].modifiable = false
  layout_mod._line_nums[lhs_buf] = lhs_nums
  vim.b[lhs_buf].treediff_buf_to_file = lhs_maps.buf_to_file

  -- Create RHS buffer
  local rhs_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(rhs_buf, 0, -1, false, rhs_texts)
  vim.bo[rhs_buf].buftype = "nofile"
  vim.bo[rhs_buf].bufhidden = "wipe"
  vim.bo[rhs_buf].modifiable = false
  layout_mod._line_nums[rhs_buf] = rhs_nums
  vim.b[rhs_buf].treediff_buf_to_file = rhs_maps.buf_to_file

  -- Set buffers in windows
  vim.api.nvim_win_set_buf(state.diff_lhs_win, lhs_buf)
  vim.api.nvim_win_set_buf(state.diff_rhs_win, rhs_buf)
  M.cleanup_old_bufs(old_lhs, old_rhs)

  -- Token highlights
  vim.api.nvim_set_hl(0, "TreeDiffDelete", { fg = "#ff6e6e", bold = true })
  vim.api.nvim_set_hl(0, "TreeDiffAdd", { fg = "#6eff6e", bold = true })
  vim.api.nvim_set_hl(0, "TreeDiffDeleteNr", { fg = "#ff6e6e", bold = true })
  vim.api.nvim_set_hl(0, "TreeDiffAddNr", { fg = "#6eff6e", bold = true })
  vim.api.nvim_set_hl(0, "TreeDiffFiller", { bg = "#1a1a2e", default = true })

  -- Place token extmarks with coordinate translation
  highlight.place_marks_mapped(lhs_buf, result.lhs_tokens or {}, "TreeDiffDelete", "TreeDiffDeleteNr", lhs_maps.file_to_buf)
  highlight.place_marks_mapped(rhs_buf, result.rhs_tokens or {}, "TreeDiffAdd", "TreeDiffAddNr", rhs_maps.file_to_buf)

  -- Highlight filler rows
  local ns = highlight.namespace()
  for i, entry in ipairs(aligned.lhs_padded) do
    if not entry.orig then
      pcall(vim.api.nvim_buf_set_extmark, lhs_buf, ns, i - 1, 0, {
        end_row = i - 1, end_col = 0, hl_eol = true,
        hl_group = "TreeDiffFiller", priority = 50,
      })
    end
  end
  for i, entry in ipairs(aligned.rhs_padded) do
    if not entry.orig then
      pcall(vim.api.nvim_buf_set_extmark, rhs_buf, ns, i - 1, 0, {
        end_row = i - 1, end_col = 0, hl_eol = true,
        hl_group = "TreeDiffFiller", priority = 50,
      })
    end
  end

  -- Window options: scrollbind instead of diffthis
  for _, win in ipairs({ state.diff_lhs_win, state.diff_rhs_win }) do
    vim.wo[win].scrollbind = true
    vim.wo[win].cursorbind = true
    local ww = require("plz").config.diff.wordwrap
    vim.wo[win].wrap = ww
    vim.wo[win].linebreak = ww
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].foldlevel = 0
    vim.wo[win].foldtext = "v:lua.PlzDiffFoldText()"
    vim.wo[win].foldminlines = 1
    vim.wo[win].statuscolumn = "%{%v:lua.PlzDiffLineNr()%}"
    vim.wo[win].statusline = layout.plz_statusline()
  end
  vim.cmd("syncbind")

  -- Stop treesitter/syntax so token highlights are clean
  for _, buf in ipairs({ lhs_buf, rhs_buf }) do
    pcall(vim.treesitter.stop, buf)
    vim.bo[buf].syntax = ""
  end

  -- Fold unchanged regions (keep 3 context lines around changes)
  local context = 3
  local total_lines = #aligned.lhs_padded

  -- Collect "interesting" rows: filler lines or lines with novel tokens
  local interesting = {}
  for i, e in ipairs(aligned.lhs_padded) do
    if not e.orig then interesting[i] = true end
  end
  for i, e in ipairs(aligned.rhs_padded) do
    if not e.orig then interesting[i] = true end
  end
  -- Mark rows with token highlights
  for _, tok in ipairs(result.lhs_tokens or {}) do
    local br = lhs_maps.file_to_buf[tok.line]
    if br then interesting[br] = true end
  end
  for _, tok in ipairs(result.rhs_tokens or {}) do
    local br = rhs_maps.file_to_buf[tok.line]
    if br then interesting[br] = true end
  end
  -- Mark rows with comments so they're never folded
  local file = state.files and state.files[state.current_file_idx]
  local cpath = file and (file.filename or file.path) or ""
  for _, side_map in ipairs({
    { comments = state.comments_by_file or {}, nums = rhs_nums },
    { comments = state.comments_by_file_left or {}, nums = lhs_nums },
  }) do
    local file_comments = side_map.comments[cpath] or {}
    for orig_line, _ in pairs(file_comments) do
      for buf_line, file_line in pairs(side_map.nums) do
        if file_line == orig_line then
          interesting[buf_line] = true
          break
        end
      end
    end
  end

  -- Build sorted list of interesting rows
  local changed_rows = {}
  for r in pairs(interesting) do changed_rows[#changed_rows + 1] = r end
  table.sort(changed_rows)

  -- Compute fold ranges: gaps between interesting rows minus context
  local fold_ranges = {}
  local prev_end = 0  -- last row covered by previous interesting block + context

  for _, r in ipairs(changed_rows) do
    local block_start = r - context
    if block_start > prev_end + 1 then
      -- There's a foldable gap: from prev_end+1 to block_start-1
      local fs = prev_end + 1
      local fe = block_start - 1
      if fe >= fs then
        fold_ranges[#fold_ranges + 1] = { fs, fe }
      end
    end
    prev_end = math.max(prev_end, r + context)
  end
  -- Trailing unchanged region
  if prev_end < total_lines then
    local fs = prev_end + 1
    local fe = total_lines
    if fe >= fs then
      fold_ranges[#fold_ranges + 1] = { fs, fe }
    end
  end

  -- Apply folds to both windows
  for _, win in ipairs({ state.diff_lhs_win, state.diff_rhs_win }) do
    vim.api.nvim_win_call(win, function()
      for _, range in ipairs(fold_ranges) do
        pcall(vim.cmd, range[1] .. "," .. range[2] .. "fold")
      end
    end)
  end

  state.diff_lhs_buf = lhs_buf
  state.diff_rhs_buf = rhs_buf
end

--- Refresh the statusline after diff state changes.
function M.clear_diff_status()
  vim.cmd("redrawstatus")
end

--- Set up keymaps on diff buffers (file nav, q, hunk nav, comments, etc).
function M.setup_diff_keymaps(diff_state)
  for _, buf in ipairs({ diff_state.lhs_buf, diff_state.rhs_buf }) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.keymap.set("n", "]f", function()
        if state.current_file_idx and state.current_file_idx < #state.files then
          M.open_diff(state.current_file_idx + 1)
        else
          vim.notify("plz: last file", vim.log.levels.INFO)
        end
      end, { buffer = buf, desc = "Next file" })

      vim.keymap.set("n", "[f", function()
        if state.current_file_idx and state.current_file_idx > 1 then
          M.open_diff(state.current_file_idx - 1)
        else
          vim.notify("plz: first file", vim.log.levels.INFO)
        end
      end, { buffer = buf, desc = "Previous file" })

      -- Hunk navigation: use Neovim's built-in diff ]c/[c
      vim.keymap.set("n", "]h", "]c", { buffer = buf, remap = true, desc = "Next hunk" })
      vim.keymap.set("n", "[h", "[c", { buffer = buf, remap = true, desc = "Previous hunk" })

      vim.keymap.set("n", "q", function()
        local review = require("plz.review")
        review.close()
      end, { buffer = buf, desc = "Close review" })

      vim.keymap.set("n", "v", function()
        if state.current_file_idx then
          local file = state.files[state.current_file_idx]
          if file then
            M.toggle_viewed(file.filename or file.path)
          end
        end
      end, { buffer = buf, desc = "Toggle viewed" })

      vim.keymap.set("n", "c", function()
        comments.toggle_comment_at_cursor()
      end, { buffer = buf, desc = "Toggle comment" })

      vim.keymap.set("n", "]c", function()
        comments.jump_comment(1)
      end, { buffer = buf, desc = "Next comment" })

      vim.keymap.set("n", "[c", function()
        comments.jump_comment(-1)
      end, { buffer = buf, desc = "Previous comment" })

      -- Review action keymaps on diff buffers
      local actions = require("plz.review.actions")
      vim.keymap.set("n", "A", function()
        actions.prompt_submit_review("APPROVE")
      end, { buffer = buf, desc = "Approve PR" })

      vim.keymap.set("n", "X", function()
        actions.prompt_submit_review("REQUEST_CHANGES")
      end, { buffer = buf, desc = "Request changes" })

      vim.keymap.set("n", "C", function()
        actions.prompt_submit_review("COMMENT")
      end, { buffer = buf, desc = "Submit comment review" })

      vim.keymap.set("n", "gc", function()
        actions.prompt_add_comment()
      end, { buffer = buf, desc = "Add PR comment" })

      -- Inline comment at cursor
      vim.keymap.set("n", "cc", function()
        local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
        local cur_buf = vim.api.nvim_get_current_buf()
        local layout_mod = require("plz.diff.layout")
        local line_nums = layout_mod._line_nums[cur_buf] or {}
        local orig_line = line_nums[cursor_lnum] or cursor_lnum
        local side = (cur_buf == diff_state.lhs_buf) and "LEFT" or "RIGHT"
        local file = state.files[state.current_file_idx]
        if not file then return end
        local path = file.filename or file.path
        vim.ui.input({ prompt = "Inline comment: " }, function(input)
          if not input or input == "" then return end
          actions.add_inline_comment(path, orig_line, side, input)
        end)
      end, { buffer = buf, desc = "Add inline comment" })

      vim.keymap.set("n", "?", function()
        if M._build_help then
          require("plz.help").toggle(M._build_help())
        end
      end, { buffer = buf, desc = "Toggle help" })

      layout.set_collection_keymaps(buf)
    end
  end
end

--- Open diff for a file below the file list.
--- Fetches base/head content via git and uses Neovim's :diffthis.
function M.open_diff(file_idx)
  local file = state.files[file_idx]
  local path = file.filename or file.path
  local prev_path = file.previous_filename or path
  state.current_file_idx = file_idx

  -- Generation counter: ignore stale callbacks from prior open_diff calls
  state.diff_gen = (state.diff_gen or 0) + 1
  local gen = state.diff_gen

  -- Update active file indicator
  files.highlight_active()

  -- Move file list cursor to match and ensure no trailing blank lines
  local file_win = state.top_win or state.win
  if file_win and vim.api.nvim_win_is_valid(file_win) then
    pcall(vim.api.nvim_win_set_cursor, file_win, { file_idx, 0 })
    vim.api.nvim_win_call(file_win, function()
      local win_h = vim.api.nvim_win_get_height(file_win)
      local total = #state.files
      if total > 0 and total <= win_h then
        vim.fn.winrestview({ topline = 1 })
      elseif file_idx > total - win_h + 1 then
        vim.fn.winrestview({ topline = math.max(1, total - win_h + 1) })
      end
    end)
  end

  local pending = 2
  local base_content = ""
  local head_content = ""

  --- Guard: abort if generation changed or no longer in C3.
  local function is_stale()
    return state.diff_gen ~= gen or state.active_collection ~= 3
  end

  local function on_ready()
    pending = pending - 1
    if pending > 0 then return end
    if is_stale() then return end

    -- Ensure diff split exists
    if not state.diff_lhs_win or not vim.api.nvim_win_is_valid(state.diff_lhs_win) then
      M.create_diff_split()
    end

    -- Split content into lines
    local base_lines = vim.split(base_content, "\n", { plain = true })
    local head_lines = vim.split(head_content, "\n", { plain = true })
    -- Remove trailing empty line from git output
    if #base_lines > 0 and base_lines[#base_lines] == "" then table.remove(base_lines) end
    if #head_lines > 0 and head_lines[#head_lines] == "" then table.remove(head_lines) end

    -- For identical files, just notify
    if base_content == head_content then
      vim.notify("plz: " .. vim.fn.fnamemodify(path, ":t") .. " — files are identical", vim.log.levels.INFO)
    end

    M.populate_diff(base_lines, head_lines, path)
  end

  -- Fetch base version
  if state.base_sha then
    M.git_show(state.base_sha, prev_path, function(content)
      if is_stale() then return end
      base_content = content
      on_ready()
    end)
  else
    base_content = ""
    on_ready()
  end

  -- Fetch head version
  M.git_show(state.head_sha, path, function(content)
    if is_stale() then return end
    head_content = content
    on_ready()
  end)
end

--- Get file content at a specific commit.
function M.git_show(sha, path, callback)
  vim.system({ "git", "show", sha .. ":" .. path }, { text = true }, function(obj)
    vim.schedule(function()
      callback(obj.code == 0 and obj.stdout or "")
    end)
  end)
end

--- Close the diff area, return focus to file list.
function M.close_diff()
  -- Turn off diff mode / scrollbind before closing
  for _, win in ipairs({ state.diff_lhs_win, state.diff_rhs_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        pcall(vim.cmd, "diffoff")
        vim.wo[win].scrollbind = false
        vim.wo[win].cursorbind = false
      end)
    end
  end

  -- Safe to delete buffers here — we're closing the windows right after
  M.cleanup_old_bufs(state.diff_lhs_buf, state.diff_rhs_buf)
  state.diff_lhs_buf = nil
  state.diff_rhs_buf = nil

  if state.diff_lhs_win and vim.api.nvim_win_is_valid(state.diff_lhs_win) then
    pcall(vim.api.nvim_win_close, state.diff_lhs_win, true)
  end
  if state.diff_rhs_win and vim.api.nvim_win_is_valid(state.diff_rhs_win) then
    pcall(vim.api.nvim_win_close, state.diff_rhs_win, true)
  end

  M.clear_diff_status()

  state.diff_lhs_win = nil
  state.diff_rhs_win = nil
  state.current_file_idx = nil

  -- Remove active file highlight
  local c3 = state.collections and state.collections[3]
  local file_buf = c3 and c3.top_buf or state.buf
  if file_buf and vim.api.nvim_buf_is_valid(file_buf) then
    vim.api.nvim_buf_clear_namespace(file_buf, ns_active, 0, -1)
  end

  -- Recreate placeholder bottom window and focus top
  local top = state.top_win or state.win
  if top and vim.api.nvim_win_is_valid(top) then
    vim.api.nvim_set_current_win(top)
    vim.cmd("botright split")
    state.bottom_win = vim.api.nvim_get_current_win()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].buftype = "nofile"
    vim.bo[scratch].bufhidden = "wipe"
    vim.api.nvim_win_set_buf(state.bottom_win, scratch)
    vim.cmd("wincmd =")
    vim.api.nvim_set_current_win(top)
  end
end

--- Set up C3 file list keymaps.
--- @param review table  The plz.review module (to avoid circular require at load time)
function M.setup_file_keymaps(review)
  local c3 = state.collections and state.collections[3]
  local buf = c3 and c3.top_buf or state.buf
  local opts = { buffer = buf, nowait = true }

  vim.keymap.set("n", "<CR>", function()
    local top = state.top_win or state.win
    if not top or not vim.api.nvim_win_is_valid(top) then return end
    local idx = vim.api.nvim_win_get_cursor(top)[1]
    if idx >= 1 and idx <= #state.files then
      M.open_diff(idx)
    end
  end, vim.tbl_extend("force", opts, { desc = "Open file diff" }))

  vim.keymap.set("n", "o", function()
    if state.pr and state.pr.url then
      vim.ui.open(state.pr.url .. "/files")
    end
  end, vim.tbl_extend("force", opts, { desc = "Open PR files in browser" }))

  vim.keymap.set("n", "q", function()
    if state.commit_mode then
      review._exit_commit_mode()
    else
      review.close()
    end
  end, vim.tbl_extend("force", opts, { desc = "Close review / exit commit mode" }))

  vim.keymap.set("n", "<BS>", function()
    if state.commit_mode then
      review._exit_commit_mode()
    end
  end, vim.tbl_extend("force", opts, { desc = "Back to full PR view" }))

  vim.keymap.set("n", "v", function()
    local top = state.top_win or state.win
    if not top or not vim.api.nvim_win_is_valid(top) then return end
    local idx = vim.api.nvim_win_get_cursor(top)[1]
    local file = state.files[idx]
    if file then
      M.toggle_viewed(file.filename or file.path)
    end
  end, vim.tbl_extend("force", opts, { desc = "Toggle viewed" }))

  vim.keymap.set("n", "]c", function()
    comments.jump_comment(1)
  end, vim.tbl_extend("force", opts, { desc = "Next comment" }))

  vim.keymap.set("n", "[c", function()
    comments.jump_comment(-1)
  end, vim.tbl_extend("force", opts, { desc = "Previous comment" }))

  -- Review action keymaps on file list
  local actions = require("plz.review.actions")
  vim.keymap.set("n", "A", function()
    actions.prompt_submit_review("APPROVE")
  end, vim.tbl_extend("force", opts, { desc = "Approve PR" }))

  vim.keymap.set("n", "X", function()
    actions.prompt_submit_review("REQUEST_CHANGES")
  end, vim.tbl_extend("force", opts, { desc = "Request changes" }))

  vim.keymap.set("n", "C", function()
    actions.prompt_submit_review("COMMENT")
  end, vim.tbl_extend("force", opts, { desc = "Submit comment review" }))

  vim.keymap.set("n", "gc", function()
    actions.prompt_add_comment()
  end, vim.tbl_extend("force", opts, { desc = "Add PR comment" }))

  --- Build context-dependent help lines based on active collection.
  local function build_help()
    local ac = state.active_collection or 3
    local lines = {
      "plz review",
      "",
      "Navigation",
      "  <Tab>/<S-Tab>   cycle collections",
      "  1/2/3           jump to collection",
      "  <C-w><C-w>      switch focus between top/bottom panes",
      "",
    }
    if ac == 1 then
      vim.list_extend(lines, {
        "C1 — PR Detail (info + description / commits)",
        "  <CR>            select commit → enter commit mode",
        "  <BS>            exit commit mode → return to PR",
        "  o               open PR in browser",
      })
    elseif ac == 2 then
      vim.list_extend(lines, {
        "C2 — Reviews (review list / threads)",
        "  <CR>            select review / go to comment in diff",
        "  g               go to thread in diff (from top)",
        "  r               reply to thread",
        "  e               edit comment",
        "  dd              delete review / comment",
        "  R               resolve/unresolve thread",
        "  o               open review in browser",
      })
    else
      vim.list_extend(lines, {
        "C3 — Changes (file list / diff)",
        "  <CR>            open diff for selected file",
        "  ]f / [f         next/prev file (in diff)",
        "  ]h / [h         next/prev hunk (in diff)",
        "  ]c / [c         next/prev comment (cross-file)",
        "  c               toggle comment at cursor (in diff)",
        "  cc              add inline comment at cursor (in diff)",
        "  v               toggle file viewed",
        "  o               open PR files in browser",
      })
    end
    vim.list_extend(lines, {
      "",
      "Review Actions",
      "  A               approve PR",
      "  X               request changes",
      "  C               submit comment review",
      "  gc              add PR comment",
      "",
      "General",
      "  q               close",
      "  <BS>            back (commit mode → PR view)",
      "  ?               toggle this help",
    })
    return lines
  end

  vim.keymap.set("n", "?", function()
    require("plz.help").toggle(build_help())
  end, vim.tbl_extend("force", opts, { desc = "Toggle help" }))

  -- Store builder so other collections can use it
  M._build_help = build_help
end

return M
