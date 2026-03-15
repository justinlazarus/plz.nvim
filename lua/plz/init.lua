local M = {}

M.config = {
  diff = {
    layout = "side-by-side",
    context = 3,
  },
  worktree = {
    auto_create = true,
    auto_cleanup = true,
  },
  dashboard = {
    sections = {
      { name = "Review Requested", filter = "is:pr is:open review-requested:@me" },
      { name = "My PRs", filter = "is:pr is:open author:@me" },
      { name = "All Open", filter = "is:pr is:open" },
    },
  },
}

function M.setup(opts)
  M._did_setup = true
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Diff highlights — two levels matching difftastic terminal style
  -- Line-level: subtle fg for the whole changed line
  vim.api.nvim_set_hl(0, "PlzDiffAddLine", { fg = "#6e9670", default = true })
  vim.api.nvim_set_hl(0, "PlzDiffRemoveLine", { fg = "#9e6a74", default = true })
  -- Token-level: bold fg for the actual novel tokens
  vim.api.nvim_set_hl(0, "PlzDiffAdd", { fg = "#a6e3a1", bold = true, default = true })
  vim.api.nvim_set_hl(0, "PlzDiffRemove", { fg = "#f38ba8", bold = true, default = true })

  -- Dashboard highlights — matching gh-dash color scheme
  vim.api.nvim_set_hl(0, "PlzOpen", { fg = "#42A0FA", default = true })
  vim.api.nvim_set_hl(0, "PlzDraft", { fg = "#656C76", default = true })
  vim.api.nvim_set_hl(0, "PlzClosed", { fg = "#E06C75", default = true })
  vim.api.nvim_set_hl(0, "PlzMerged", { fg = "#A371F7", default = true })
  vim.api.nvim_set_hl(0, "PlzSuccess", { fg = "#3DF294", default = true })
  vim.api.nvim_set_hl(0, "PlzWarning", { fg = "#E5C07B", default = true })
  vim.api.nvim_set_hl(0, "PlzError", { fg = "#E06C75", default = true })
  vim.api.nvim_set_hl(0, "PlzFaint", { fg = "#656C76", default = true })
  vim.api.nvim_set_hl(0, "PlzAccent", { fg = "#42A0FA", default = true })
  vim.api.nvim_set_hl(0, "PlzTabActive", { fg = "#ABB2BF", bold = true, default = true })
  vim.api.nvim_set_hl(0, "PlzTabInactive", { fg = "#656C76", default = true })
  vim.api.nvim_set_hl(0, "PlzBorder", { fg = "#3E4452", default = true })
  vim.api.nvim_set_hl(0, "PlzFold", { fg = "#3E4452", italic = true, default = true })
  vim.api.nvim_set_hl(0, "PlzGreen", { fg = "#3DF294", default = true })
  vim.api.nvim_set_hl(0, "PlzRed", { fg = "#E06C75", default = true })
  vim.api.nvim_set_hl(0, "PlzYellow", { fg = "#E5C07B", default = true })
  vim.api.nvim_set_hl(0, "PlzHeader", { fg = "#656C76", default = true })
  vim.api.nvim_set_hl(0, "PlzPill", { fg = "#ABB2BF", bg = "#3E4452", default = true })
  vim.api.nvim_set_hl(0, "PlzCode", { fg = "#ABB2BF", bg = "#3E4452", default = true })
  vim.api.nvim_set_hl(0, "PlzLink", { fg = "#42A0FA", underline = true, default = true })
  vim.api.nvim_set_hl(0, "PlzBold", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "PlzItalic", { italic = true, default = true })
  local normal_bg = vim.api.nvim_get_hl(0, { name = "Normal" }).bg
  vim.api.nvim_set_hl(0, "PlzStatusLine", { fg = "#42A0FA", bg = normal_bg, default = true })
  vim.api.nvim_set_hl(0, "PlzStatusPill", { fg = "#ABB2BF", bg = "#3E4452", bold = true, default = true })
  vim.api.nvim_set_hl(0, "PlzStatusPillIcon", { fg = "#3DF294", bg = "#3E4452", default = true })

  vim.api.nvim_set_hl(0, "PlzStatusRepo", { fg = "#C0C8D4", bg = "#4E5565", default = true })
  vim.api.nvim_set_hl(0, "PlzStatusFaint", { fg = "#656C76", bg = normal_bg, default = true })

  -- Non-diff highlights — link to existing groups
  local highlights = {
    PlzThread = "Comment",
    PlzThreadResolved = "NonText",
    PlzThreadOutdated = "DiagnosticWarn",
    PlzCommentPending = "DiagnosticInfo",
    PlzGutterMark = "DiagnosticHint",
    PlzCIPass = "PlzSuccess",
    PlzCIFail = "PlzError",
    PlzCIPending = "PlzWarning",
    PlzSectionTitle = "Title",
  }

  for group, link in pairs(highlights) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end

  -- Plz statusline: disable statusline plugins while in plz buffers.
  -- Works universally by temporarily hiding lualine/etc. via their
  -- hide() API, falling back to a timer-based override.
  local plz_stl = "%#PlzStatusPillIcon# \xef\x93\x89 %#PlzStatusPill# plz %#PlzStatusLine#%="
  local stl_hidden = false

  local saved_laststatus

  local function show_plz_stl()
    if not stl_hidden then
      saved_laststatus = vim.o.laststatus
      -- Try lualine hide API (works for lualine; no-op if absent)
      local ok, lualine = pcall(require, "lualine")
      if ok and lualine.hide then
        pcall(lualine.hide)
      end
      stl_hidden = true
    end
    vim.o.laststatus = saved_laststatus or 2
    vim.wo.statusline = plz_stl
  end

  local function restore_stl()
    if stl_hidden then
      local ok, lualine = pcall(require, "lualine")
      if ok and lualine.hide then
        pcall(lualine.hide, { unhide = true })
      end
      stl_hidden = false
    end
  end

  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    callback = function()
      local ft = vim.bo.filetype or ""
      if ft:match("^plz") then
        show_plz_stl()
        -- Re-apply detailed statusline with repo name / position
        if ft == "plz-dashboard" then
          local ok, dash = pcall(require, "plz.dashboard")
          if ok and dash._update_statusline then dash._update_statusline() end
        elseif ft == "plz-review" or ft == "plz-diff" then
          local ok, layout = pcall(require, "plz.review.layout")
          if ok and layout.plz_statusline then
            vim.wo.statusline = layout.plz_statusline()
          end
        end
      else
        restore_stl()
      end
    end,
  })

  -- Force statusline redraw on cursor movement so "x of y" stays current
  vim.api.nvim_create_autocmd("CursorMoved", {
    callback = function()
      local ft = vim.bo.filetype or ""
      if ft:match("^plz") then
        vim.cmd("redrawstatus")
      end
    end,
  })
end

--- Provider function for external statusline plugins (lualine, etc.).
--- Returns the plz statusline string for the current buffer, or nil if not in a plz view.
--- Usage: require("plz").statusline()
function M.statusline()
  local ft = vim.bo.filetype or ""
  if ft == "plz-dashboard" then
    return _G.PlzDashboardStatusLine and _G.PlzDashboardStatusLine() or nil
  elseif ft == "plz-review" or ft == "plz-diff" then
    return _G.PlzReviewStatusLine and _G.PlzReviewStatusLine() or nil
  end
  return nil
end

return M
