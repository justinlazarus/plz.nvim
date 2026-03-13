local difftastic = require("plz.diff.difftastic")
local align = require("plz.diff.align")
local render = require("plz.diff.render")
local layout = require("plz.diff.layout")

local M = {}

--- Map difftastic language names to Neovim filetypes.
local lang_to_ft = {
  TypeScript = "typescript",
  JavaScript = "javascript",
  Python = "python",
  Lua = "lua",
  Rust = "rust",
  Go = "go",
  C = "c",
  ["C++"] = "cpp",
  ["C#"] = "cs",
  Java = "java",
  Ruby = "ruby",
  JSON = "json",
  YAML = "yaml",
  TOML = "toml",
  HTML = "html",
  CSS = "css",
  Bash = "bash",
  Markdown = "markdown",
}

--- Open a difftastic side-by-side diff view for two files.
--- @param old_path string Path to the old file
--- @param new_path string Path to the new file
--- @param opts? { on_ready?: fun(state: table) }
function M.open(old_path, new_path, opts)
  opts = opts or {}
  local old_lines = M._read_file(old_path)
  local new_lines = M._read_file(new_path)

  if not old_lines or not new_lines then
    vim.notify("plz: could not read files", vim.log.levels.ERROR)
    return
  end

  difftastic.run(old_path, new_path, function(result, err)
    if err then
      vim.notify("plz: " .. err, vim.log.levels.ERROR)
      return
    end

    if result.status == "unchanged" then
      vim.notify("plz: files are identical", vim.log.levels.INFO)
      if opts.on_ready then opts.on_ready(nil) end
      return
    end

    local ft = lang_to_ft[result.language]

    -- Build aligned line arrays (full, no collapsing)
    local padded_lhs, padded_rhs = align.build(old_lines, new_lines, result)

    -- Create the layout with aligned content
    local diff_state = layout.side_by_side(padded_lhs, padded_rhs, { filetype = ft })

    -- Apply difftastic highlights (pass padded data for line mapping)
    render.apply(diff_state.lhs_buf, diff_state.rhs_buf, result, padded_lhs, padded_rhs)

    -- Fold unchanged regions (native vim folds — zo/zc/za/zR/zM all work)
    M._setup_folds(diff_state, padded_lhs, padded_rhs, result, 3)

    -- Set up hunk navigation using padded row indices
    M._setup_hunk_navigation(diff_state, result, padded_lhs, padded_rhs)

    if opts.on_ready then opts.on_ready(diff_state) end
  end)
end

--- Custom foldtext for diff buffers.
function _G.PlzDiffFoldText()
  local start = vim.v.foldstart
  local end_ = vim.v.foldend
  local count = end_ - start + 1
  return string.format(" ╶╶╶ %d lines ╶╶╶", count)
end

--- Create native vim folds over unchanged regions.
--- @param diff_state table {lhs_buf, rhs_buf, lhs_win, rhs_win}
--- @param padded_lhs table[] Full aligned LHS
--- @param padded_rhs table[] Full aligned RHS
--- @param diff_result table Normalized difftastic output
--- @param context number Lines of context around changes
--- @param comment_lines table|nil {lhs={orig_line=true}, rhs={orig_line=true}}
function M._setup_folds(diff_state, padded_lhs, padded_rhs, diff_result, context, comment_lines)
  context = context or 3
  local n = #padded_lhs
  if n == 0 then return end

  -- Build orig → padded-index maps
  local lhs_map = {}
  for i, entry in ipairs(padded_lhs) do
    if entry.orig ~= nil then lhs_map[entry.orig] = i end
  end
  local rhs_map = {}
  for i, entry in ipairs(padded_rhs) do
    if entry.orig ~= nil then rhs_map[entry.orig] = i end
  end

  -- Mark changed rows
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

  -- Mark rows with comments
  if comment_lines then
    for orig_line in pairs(comment_lines.lhs or {}) do
      if lhs_map[orig_line] then changed[lhs_map[orig_line]] = true end
    end
    for orig_line in pairs(comment_lines.rhs or {}) do
      if rhs_map[orig_line] then changed[rhs_map[orig_line]] = true end
    end
  end

  -- Expand to context
  local visible = {}
  for row in pairs(changed) do
    for i = math.max(1, row - context), math.min(n, row + context) do
      visible[i] = true
    end
  end

  -- Collect fold ranges (contiguous non-visible regions)
  local folds = {}
  local i = 1
  while i <= n do
    if not visible[i] then
      local start = i
      while i <= n and not visible[i] do
        i = i + 1
      end
      -- Only fold if the hunk is at least 5 lines
      if i - 1 - start + 1 >= 5 then
        table.insert(folds, { start, i - 1 })
      end
    else
      i = i + 1
    end
  end

  -- Apply folds to both windows
  for _, win in ipairs({ diff_state.lhs_win, diff_state.rhs_win }) do
    vim.wo[win].foldmethod = "manual"
    vim.wo[win].foldenable = true
    vim.wo[win].foldminlines = 0
    vim.wo[win].foldtext = "v:lua.PlzDiffFoldText()"
    vim.wo[win].fillchars = "fold: "

    vim.api.nvim_win_call(win, function()
      -- Clear any existing folds
      vim.cmd("normal! zE")
      for _, range in ipairs(folds) do
        vim.cmd(range[1] .. "," .. range[2] .. "fold")
      end
    end)
  end
end

--- Set up ]h / [h to jump between hunks.
--- @param state table Layout state with buf/win handles
--- @param result table Normalized difftastic result
--- @param padded_lhs table[] Aligned LHS lines
--- @param padded_rhs table[] Aligned RHS lines
function M._setup_hunk_navigation(state, result, padded_lhs, padded_rhs)
  local lhs_map = render._build_line_map(padded_lhs)
  local rhs_map = render._build_line_map(padded_rhs)

  -- Collect padded row numbers (1-indexed for cursor) for each side
  local rhs_hunk_rows = {}
  local lhs_hunk_rows = {}

  for _, hunk in ipairs(result.hunks or {}) do
    for _, entry in ipairs(hunk.entries) do
      if entry.rhs_line and rhs_map[entry.rhs_line] then
        rhs_hunk_rows[rhs_map[entry.rhs_line] + 1] = true -- +1 for 1-indexed cursor
      end
      if entry.lhs_line and lhs_map[entry.lhs_line] then
        lhs_hunk_rows[lhs_map[entry.lhs_line] + 1] = true
      end
    end
  end

  local rhs_sorted = vim.tbl_keys(rhs_hunk_rows)
  table.sort(rhs_sorted)
  local lhs_sorted = vim.tbl_keys(lhs_hunk_rows)
  table.sort(lhs_sorted)

  local function jump_next(sorted_lines, win)
    return function()
      local current_line = vim.api.nvim_win_get_cursor(win)[1]
      for _, line in ipairs(sorted_lines) do
        if line > current_line then
          vim.api.nvim_win_set_cursor(win, { line, 0 })
          return
        end
      end
    end
  end

  local function jump_prev(sorted_lines, win)
    return function()
      local current_line = vim.api.nvim_win_get_cursor(win)[1]
      for i = #sorted_lines, 1, -1 do
        if sorted_lines[i] < current_line then
          vim.api.nvim_win_set_cursor(win, { sorted_lines[i], 0 })
          return
        end
      end
    end
  end

  local map_opts = { desc = "Next hunk" }
  vim.keymap.set("n", "]h", jump_next(rhs_sorted, state.rhs_win), vim.tbl_extend("force", map_opts, { buffer = state.rhs_buf }))
  vim.keymap.set("n", "]h", jump_next(lhs_sorted, state.lhs_win), vim.tbl_extend("force", map_opts, { buffer = state.lhs_buf }))

  map_opts = { desc = "Previous hunk" }
  vim.keymap.set("n", "[h", jump_prev(rhs_sorted, state.rhs_win), vim.tbl_extend("force", map_opts, { buffer = state.rhs_buf }))
  vim.keymap.set("n", "[h", jump_prev(lhs_sorted, state.lhs_win), vim.tbl_extend("force", map_opts, { buffer = state.lhs_buf }))
end

--- Compute diff data without creating any layout.
--- Returns aligned arrays and diff result for the caller to render.
--- @param old_path string
--- @param new_path string
--- @param callback fun(data: table|nil, err: string|nil, unchanged: boolean|nil)
function M.compute(old_path, new_path, callback)
  local old_lines = M._read_file(old_path)
  local new_lines = M._read_file(new_path)

  if not old_lines or not new_lines then
    callback(nil, "could not read files")
    return
  end

  difftastic.run(old_path, new_path, function(result, err)
    if err then
      callback(nil, err)
      return
    end

    if result.status == "unchanged" then
      callback(nil, nil, true)
      return
    end

    local ft = lang_to_ft[result.language]
    local padded_lhs, padded_rhs = align.build(old_lines, new_lines, result)

    callback({
      padded_lhs = padded_lhs,
      padded_rhs = padded_rhs,
      result = result,
      ft = ft,
    })
  end)
end

--- Read a file into a table of lines.
--- @param path string
--- @return string[]|nil
function M._read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local lines = vim.split(content, "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

return M
