local M = {}

--- Open a side-by-side diff view for two files using Neovim's :diffthis.
--- If treediff is installed, it will automatically enhance with token highlights.
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

  -- Detect filetype from file extension
  local ft = vim.filetype.match({ filename = old_path })
    or vim.filetype.match({ filename = new_path })
    or ""

  vim.cmd("tabnew")

  -- Create LHS buffer (old/base)
  local lhs_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(lhs_buf, 0, -1, false, old_lines)
  vim.bo[lhs_buf].buftype = "nofile"
  vim.bo[lhs_buf].bufhidden = "wipe"
  vim.bo[lhs_buf].modifiable = false
  if ft ~= "" then vim.bo[lhs_buf].filetype = ft end

  -- Create RHS buffer (new/head)
  local rhs_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(rhs_buf, 0, -1, false, new_lines)
  vim.bo[rhs_buf].buftype = "nofile"
  vim.bo[rhs_buf].bufhidden = "wipe"
  vim.bo[rhs_buf].modifiable = false
  if ft ~= "" then vim.bo[rhs_buf].filetype = ft end

  -- Set up windows
  local lhs_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(lhs_win, lhs_buf)

  vim.cmd("vsplit")
  local rhs_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(rhs_win, rhs_buf)

  -- Enable Neovim's built-in diff mode
  vim.api.nvim_win_call(lhs_win, function() vim.cmd("diffthis") end)
  vim.api.nvim_win_call(rhs_win, function() vim.cmd("diffthis") end)

  -- Blank filler lines
  vim.opt.fillchars:append("diff: ")

  -- Window options
  for _, win in ipairs({ lhs_win, rhs_win }) do
    vim.wo[win].wrap = false
    vim.wo[win].signcolumn = "no"
  end

  -- q to close
  for _, buf in ipairs({ lhs_buf, rhs_buf }) do
    vim.keymap.set("n", "q", function()
      vim.cmd("diffoff!")
      vim.cmd("tabclose")
    end, { buffer = buf, desc = "Close diff view" })
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
