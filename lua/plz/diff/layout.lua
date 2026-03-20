local M = {}

-- Registry for line number data, keyed by buffer handle.
-- Avoids buffer variable serialization issues with sparse tables.
M._line_nums = {} -- buf -> {lnum -> display_number}
M._line_hls = {}  -- buf -> {lnum -> hl_group}

--- Fold text for diff buffers: show line count.
function _G.PlzDiffFoldText()
  local count = vim.v.foldend - vim.v.foldstart + 1
  return "··· " .. count .. " lines ···"
end

--- Custom statuscolumn for aligned diff buffers.
--- Shows real line numbers for file lines, "·" for filler lines.
function _G.PlzDiffLineNr()
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.v.lnum
  local nums = M._line_nums[buf]
  local hls = M._line_hls[buf]

  if nums and nums[lnum] then
    local hl = (hls and hls[lnum]) or "LineNr"
    return string.format("%%#%s#%4d %%*", hl, nums[lnum])
  else
    return "%#NonText#   · %*"
  end
end

--- Set the highlight group for a specific line number in the statuscolumn.
--- @param buf number Buffer handle
--- @param lnum number 1-indexed line number in padded buffer
--- @param hl_group string Highlight group name
function M.set_line_hl(buf, lnum, hl_group)
  if not M._line_hls[buf] then M._line_hls[buf] = {} end
  M._line_hls[buf][lnum] = hl_group
end

--- Create a side-by-side diff layout with aligned buffers.
--- @param padded_lhs table[] Aligned lines from align.build ({text, orig})
--- @param padded_rhs table[] Aligned lines from align.build ({text, orig})
--- @param opts? { filetype?: string }
--- @return { lhs_buf: number, rhs_buf: number, lhs_win: number, rhs_win: number }
function M.side_by_side(padded_lhs, padded_rhs, opts)
  opts = opts or {}

  -- Extract text arrays and build line number maps
  local lhs_texts = {}
  local lhs_nums = {}
  for i, entry in ipairs(padded_lhs) do
    lhs_texts[i] = entry.text
    if entry.orig ~= nil then
      lhs_nums[i] = entry.orig + 1 -- 1-indexed display
    end
  end

  local rhs_texts = {}
  local rhs_nums = {}
  for i, entry in ipairs(padded_rhs) do
    rhs_texts[i] = entry.text
    if entry.orig ~= nil then
      rhs_nums[i] = entry.orig + 1
    end
  end

  vim.cmd("tabnew")

  -- Left buffer (old/base)
  local lhs_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(lhs_buf, 0, -1, false, lhs_texts)
  vim.bo[lhs_buf].modifiable = false
  vim.bo[lhs_buf].buftype = "nofile"
  vim.bo[lhs_buf].bufhidden = "wipe"
  M._line_nums[lhs_buf] = lhs_nums

  -- Right buffer (new/head)
  local rhs_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(rhs_buf, 0, -1, false, rhs_texts)
  vim.bo[rhs_buf].modifiable = false
  vim.bo[rhs_buf].buftype = "nofile"
  vim.bo[rhs_buf].bufhidden = "wipe"
  M._line_nums[rhs_buf] = rhs_nums

  -- Set up windows
  local lhs_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(lhs_win, lhs_buf)

  vim.cmd("vsplit")
  local rhs_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(rhs_win, rhs_buf)

  for _, win in ipairs({ lhs_win, rhs_win }) do
    vim.wo[win].scrollbind = true
    vim.wo[win].cursorbind = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    local ww = require("plz").config.diff.wordwrap
    vim.wo[win].wrap = ww
    vim.wo[win].linebreak = ww
    vim.wo[win].foldcolumn = "1"
    vim.wo[win].statuscolumn = "%{%v:lua.PlzDiffLineNr()%}"
  end

  vim.cmd("syncbind")

  -- Set up q to close the diff tab
  for _, buf in ipairs({ lhs_buf, rhs_buf }) do
    vim.keymap.set("n", "q", function()
      M.close({ lhs_buf = lhs_buf, rhs_buf = rhs_buf })
    end, { buffer = buf, desc = "Close diff view" })
  end

  return {
    lhs_buf = lhs_buf,
    rhs_buf = rhs_buf,
    lhs_win = lhs_win,
    rhs_win = rhs_win,
  }
end

--- Close a diff view, cleaning up buffers and registries.
--- @param state { lhs_buf: number, rhs_buf: number }
function M.close(state)
  -- Clean up registries
  for _, buf in ipairs({ state.lhs_buf, state.rhs_buf }) do
    M._line_nums[buf] = nil
    M._line_hls[buf] = nil
  end

  vim.cmd("tabclose")

  for _, buf in ipairs({ state.lhs_buf, state.rhs_buf }) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end

return M
