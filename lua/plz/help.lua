local M = {}

local help_win = nil
local help_buf = nil

--- Toggle a floating help popup. If already open, close it; otherwise show it.
--- @param lines string[] Help text lines
function M.toggle(lines)
  if help_win and vim.api.nvim_win_is_valid(help_win) then
    vim.api.nvim_win_close(help_win, true)
    help_win = nil
    help_buf = nil
    return
  end

  -- Compute dimensions from content
  local max_w = 0
  for _, l in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(l)
    if w > max_w then max_w = w end
  end
  local width = max_w + 4
  local height = #lines

  local editor_w = vim.o.columns
  local editor_h = vim.o.lines - vim.o.cmdheight - 1

  help_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[help_buf].buftype = "nofile"
  vim.bo[help_buf].bufhidden = "wipe"

  -- Pad lines for centering within the float
  local padded = {}
  for _, l in ipairs(lines) do
    table.insert(padded, "  " .. l)
  end
  vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, padded)
  vim.bo[help_buf].modifiable = false

  help_win = vim.api.nvim_open_win(help_buf, false, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((editor_w - width) / 2),
    row = math.floor((editor_h - height) / 2),
    style = "minimal",
    border = "rounded",
    zindex = 50,
  })
  vim.wo[help_win].winblend = 0

  -- Close on any key press in the help buffer
  vim.keymap.set("n", "?", function()
    M.toggle(lines)
  end, { buffer = help_buf, nowait = true })

  -- Also close if user leaves the window
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = help_buf,
    once = true,
    callback = function()
      if help_win and vim.api.nvim_win_is_valid(help_win) then
        vim.api.nvim_win_close(help_win, true)
        help_win = nil
        help_buf = nil
      end
    end,
  })
end

return M
