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

  -- Non-diff highlights — link to existing groups
  local highlights = {
    PlzThread = "Comment",
    PlzThreadResolved = "NonText",
    PlzThreadOutdated = "DiagnosticWarn",
    PlzCommentPending = "DiagnosticInfo",
    PlzGutterMark = "DiagnosticHint",
    PlzCIPass = "DiagnosticOk",
    PlzCIFail = "DiagnosticError",
    PlzCIPending = "DiagnosticWarn",
    PlzSectionTitle = "Title",
  }

  for group, link in pairs(highlights) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

return M
