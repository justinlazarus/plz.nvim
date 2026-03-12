local M = {}

--- Run a gh CLI command asynchronously.
--- @param args string[] Arguments to pass to gh
--- @param callback fun(result: any, err?: string)
function M.run(args, callback)
  vim.system(
    vim.list_extend({ "gh" }, args),
    { text = true },
    function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          callback(nil, (obj.stderr or ""):gsub("%s+$", "") or "gh command failed")
          return
        end
        local stdout = obj.stdout or ""
        if stdout == "" then
          callback({})
          return
        end
        local ok, parsed = pcall(vim.json.decode, stdout)
        if not ok then
          callback(nil, "failed to parse gh JSON: " .. tostring(parsed))
          return
        end
        callback(parsed)
      end)
    end
  )
end

return M
