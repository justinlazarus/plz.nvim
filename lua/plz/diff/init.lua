local M = {}

--- Check if treediff engine should be used for the given filetype.
local function use_treediff(ft)
  local plz_config = require("plz").config
  local engine = plz_config.diff and plz_config.diff.engine or "auto"
  if engine == "native" then return false end

  local ok, td = pcall(require, "treediff")
  if not ok or not td._native then return false end

  if engine == "treediff" then return true end

  if ft == "" then return false end
  local ft_map_ok, ft_map = pcall(require, "treediff.ft_map")
  local ts_lang = ft_map_ok and ft_map[ft] or ft
  local has_ts = pcall(vim.treesitter.language.inspect, ts_lang)
  return has_ts
end

--- Open a side-by-side diff view for two files.
--- Uses treediff for tree-aware alignment when available, otherwise Neovim's :diffthis.
--- @param old_path string Path to the old file
--- @param new_path string Path to the new file
function M.open(old_path, new_path)
  local old_lines = M._read_file(old_path)
  local new_lines = M._read_file(new_path)

  if not old_lines or not new_lines then
    vim.notify("plz: could not read files", vim.log.levels.ERROR)
    return
  end

  if table.concat(old_lines, "\n") == table.concat(new_lines, "\n") then
    vim.notify("plz: files are identical", vim.log.levels.INFO)
    return
  end

  local ft = vim.filetype.match({ filename = old_path })
    or vim.filetype.match({ filename = new_path })
    or ""

  if use_treediff(ft) then
    M._open_treediff(old_lines, new_lines, ft)
  else
    M._open_native(old_lines, new_lines, ft)
  end
end

--- Native diff path using :diffthis.
function M._open_native(old_lines, new_lines, ft)
  vim.cmd("tabnew")

  local lhs_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(lhs_buf, 0, -1, false, old_lines)
  vim.bo[lhs_buf].buftype = "nofile"
  vim.bo[lhs_buf].bufhidden = "wipe"
  vim.bo[lhs_buf].modifiable = false
  if ft ~= "" then vim.bo[lhs_buf].filetype = ft end

  local rhs_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(rhs_buf, 0, -1, false, new_lines)
  vim.bo[rhs_buf].buftype = "nofile"
  vim.bo[rhs_buf].bufhidden = "wipe"
  vim.bo[rhs_buf].modifiable = false
  if ft ~= "" then vim.bo[rhs_buf].filetype = ft end

  local lhs_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(lhs_win, lhs_buf)

  vim.cmd("vsplit")
  local rhs_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(rhs_win, rhs_buf)

  vim.api.nvim_win_call(lhs_win, function() vim.cmd("diffthis") end)
  vim.api.nvim_win_call(rhs_win, function() vim.cmd("diffthis") end)

  vim.opt.fillchars:append("diff: ")

  for _, win in ipairs({ lhs_win, rhs_win }) do
    vim.wo[win].wrap = false
    vim.wo[win].signcolumn = "no"
  end

  for _, buf in ipairs({ lhs_buf, rhs_buf }) do
    vim.keymap.set("n", "q", function()
      vim.cmd("diffoff!")
      vim.cmd("tabclose")
    end, { buffer = buf, desc = "Close diff view" })
  end
end

--- Treediff path: tree-aware alignment with token highlights.
function M._open_treediff(old_lines, new_lines, ft)
  local treediff = require("treediff")
  local align = require("treediff.align")
  local highlight = require("treediff.highlight")
  local ft_map = require("treediff.ft_map")
  local layout_mod = require("plz.diff.layout")

  local lang = ft_map[ft] or ft
  local lhs_text = table.concat(old_lines, "\n") .. "\n"
  local rhs_text = table.concat(new_lines, "\n") .. "\n"

  local result = treediff.diff(lhs_text, rhs_text, lang)
  if not result then
    M._open_native(old_lines, new_lines, ft)
    return
  end

  local aligned = align.build(old_lines, new_lines, result.anchors)
  local lhs_maps = align.build_maps(aligned.lhs_padded)
  local rhs_maps = align.build_maps(aligned.rhs_padded)

  -- Use layout.side_by_side for the window/buffer setup
  local view = layout_mod.side_by_side(aligned.lhs_padded, aligned.rhs_padded)

  -- Token highlights
  vim.api.nvim_set_hl(0, "TreeDiffDelete", { fg = "#ff6e6e", bold = true })
  vim.api.nvim_set_hl(0, "TreeDiffAdd", { fg = "#6eff6e", bold = true })
  vim.api.nvim_set_hl(0, "TreeDiffDeleteNr", { fg = "#ff6e6e", bold = true })
  vim.api.nvim_set_hl(0, "TreeDiffAddNr", { fg = "#6eff6e", bold = true })
  vim.api.nvim_set_hl(0, "TreeDiffFiller", { bg = "#1a1a2e", default = true })

  highlight.place_marks_mapped(view.lhs_buf, result.lhs_tokens or {}, "TreeDiffDelete", "TreeDiffDeleteNr", lhs_maps.file_to_buf)
  highlight.place_marks_mapped(view.rhs_buf, result.rhs_tokens or {}, "TreeDiffAdd", "TreeDiffAddNr", rhs_maps.file_to_buf)

  -- Highlight filler rows
  local ns = highlight.namespace()
  for i, entry in ipairs(aligned.lhs_padded) do
    if not entry.orig then
      pcall(vim.api.nvim_buf_set_extmark, view.lhs_buf, ns, i - 1, 0, {
        end_row = i - 1, end_col = 0, hl_eol = true,
        hl_group = "TreeDiffFiller", priority = 50,
      })
    end
  end
  for i, entry in ipairs(aligned.rhs_padded) do
    if not entry.orig then
      pcall(vim.api.nvim_buf_set_extmark, view.rhs_buf, ns, i - 1, 0, {
        end_row = i - 1, end_col = 0, hl_eol = true,
        hl_group = "TreeDiffFiller", priority = 50,
      })
    end
  end

  -- Stop treesitter/syntax
  for _, buf in ipairs({ view.lhs_buf, view.rhs_buf }) do
    pcall(vim.treesitter.stop, buf)
    vim.bo[buf].syntax = ""
  end
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
