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
function M.open(old_path, new_path)
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
      return
    end

    local ft = lang_to_ft[result.language]

    -- Build aligned line arrays
    local padded_lhs, padded_rhs = align.build(old_lines, new_lines, result)

    -- Create the layout with aligned content
    local state = layout.side_by_side(padded_lhs, padded_rhs, { filetype = ft })

    -- Apply difftastic highlights (pass padded data for line mapping)
    render.apply(state.lhs_buf, state.rhs_buf, result, padded_lhs, padded_rhs)

    -- Set up hunk navigation using padded row indices
    M._setup_hunk_navigation(state, result, padded_lhs, padded_rhs)
  end)
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
