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
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Diff highlights — fg only, matching difftastic terminal style
  vim.api.nvim_set_hl(0, "PlzDiffAdd", { fg = "#a6e3a1", bold = true, default = true })
  vim.api.nvim_set_hl(0, "PlzDiffRemove", { fg = "#f38ba8", bold = true, default = true })

  -- Dashboard highlights — matching gh-dash color scheme
  vim.api.nvim_set_hl(0, "PlzOpen", { fg = "#42A0FA", default = true })
  vim.api.nvim_set_hl(0, "PlzDraft", { fg = "#656C76", default = true })
  vim.api.nvim_set_hl(0, "PlzClosed", { fg = "#656C76", default = true })
  vim.api.nvim_set_hl(0, "PlzMerged", { fg = "#A371F7", default = true })
  vim.api.nvim_set_hl(0, "PlzSuccess", { fg = "#3DF294", default = true })
  vim.api.nvim_set_hl(0, "PlzWarning", { fg = "#E5C07B", default = true })
  vim.api.nvim_set_hl(0, "PlzError", { fg = "#E06C75", default = true })
  vim.api.nvim_set_hl(0, "PlzFaint", { fg = "#656C76", default = true })
  vim.api.nvim_set_hl(0, "PlzAccent", { fg = "#42A0FA", default = true })
  vim.api.nvim_set_hl(0, "PlzTabActive", { fg = "#ABB2BF", bold = true, default = true })
  vim.api.nvim_set_hl(0, "PlzTabInactive", { fg = "#656C76", default = true })
  vim.api.nvim_set_hl(0, "PlzBorder", { fg = "#3E4452", default = true })
  vim.api.nvim_set_hl(0, "PlzHeader", { fg = "#656C76", default = true })

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
end

return M
