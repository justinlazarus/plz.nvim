local M = {}

-- Session-level error deduplication: show one consolidated error per session.
local error_gen = 0
local error_shown_gen = -1

--- Begin a new API session. Call this before firing parallel gh requests.
--- Resets the per-session error flag so the first failure gets reported.
function M.begin_session()
  error_gen = error_gen + 1
end

--- Report a gh error, suppressing duplicates within the same session.
--- @return boolean true if the error was shown (first in session)
local function report_error(err)
  if error_shown_gen == error_gen then return false end
  error_shown_gen = error_gen
  local msg = err:gsub("^gh: ", ""):gsub("\n.*", "")
  vim.notify("plz: gh error — " .. msg .. ". Check `gh auth status`.", vim.log.levels.ERROR)
  return true
end

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
          local err = (obj.stderr or ""):gsub("%s+$", "") or "gh command failed"
          report_error(err)
          callback(nil, err)
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

--- Run a gh CLI command and return raw stdout (no JSON parsing).
--- @param args string[] Arguments to pass to gh
--- @param callback fun(stdout: string, err?: string)
function M.run_raw(args, callback)
  vim.system(
    vim.list_extend({ "gh" }, args),
    { text = true },
    function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          local err = (obj.stderr or ""):gsub("%s+$", "") or "gh command failed"
          report_error(err)
          callback("", err)
          return
        end
        callback(obj.stdout or "")
      end)
    end
  )
end

return M
