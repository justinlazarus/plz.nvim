-- Ensure highlights are set up even without explicit setup() call
require("plz").setup()

vim.api.nvim_create_user_command("PlzDiff", function(args)
  local fargs = args.fargs
  if #fargs ~= 2 then
    vim.notify("Usage: :PlzDiff <old_file> <new_file>", vim.log.levels.ERROR)
    return
  end

  -- Expand paths (handles ~, relative paths, etc.)
  local old_path = vim.fn.expand(fargs[1])
  local new_path = vim.fn.expand(fargs[2])

  require("plz.diff").open(old_path, new_path)
end, {
  nargs = "*",
  complete = "file",
  desc = "Open difftastic side-by-side diff view",
})
