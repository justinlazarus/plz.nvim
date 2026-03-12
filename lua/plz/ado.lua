local M = {}

--- Extract ADO work item ID from a PR title (e.g., "AB#1470925" or "AB#1470925:").
--- @param text string
--- @return string|nil work_item_id
function M.extract_id(text)
  return text:match("AB#(%d+)")
end

--- Fetch a work item summary from ADO REST API.
--- Requires ADO_PAT env var and ado config in plz setup.
--- @param id string Work item ID
--- @param callback fun(item: table|nil, err?: string)
function M.fetch_work_item(id, callback)
  local config = require("plz").config.ado or {}
  local org = config.org
  local project = config.project
  local pat_env = config.pat_env or "ADO_PAT"
  local pat = os.getenv(pat_env)

  if not org or not project then
    callback(nil, "ado.org and ado.project must be set in plz config")
    return
  end
  if not pat then
    callback(nil, pat_env .. " not set")
    return
  end

  local url = string.format(
    "https://dev.azure.com/%s/%s/_apis/wit/workitems/%s?$select=System.WorkItemType,System.Title,System.State,System.AssignedTo,System.Tags&api-version=7.0",
    org, project, id)

  vim.system(
    { "curl", "-s", "-u", ":" .. pat, url },
    { text = true },
    function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          callback(nil, "curl failed")
          return
        end
        local ok, parsed = pcall(vim.json.decode, obj.stdout or "")
        if not ok or not parsed or not parsed.fields then
          callback(nil, "failed to parse ADO response")
          return
        end

        local fields = parsed.fields
        local item = {
          id = id,
          type = fields["System.WorkItemType"] or "?",
          title = fields["System.Title"] or "",
          state = fields["System.State"] or "?",
          assigned_to = (fields["System.AssignedTo"] or {}).displayName or "Unassigned",
          tags = fields["System.Tags"] or "",
          url = string.format("https://dev.azure.com/%s/%s/_workitems/edit/%s", org, project, id),
        }
        callback(item)
      end)
    end
  )
end

--- Format a one-line summary for the preview pane.
--- @param item table Work item from fetch_work_item
--- @return string
function M.format_line(item)
  local parts = {}
  -- Type icon
  local type_icon = item.type == "Bug" and "🐛" or "📋"
  table.insert(parts, string.format("%s AB#%s", type_icon, item.id))
  table.insert(parts, item.state)
  table.insert(parts, item.assigned_to)
  if item.tags and item.tags ~= "" then
    table.insert(parts, item.tags)
  end
  return "  " .. table.concat(parts, " · ")
end

return M
