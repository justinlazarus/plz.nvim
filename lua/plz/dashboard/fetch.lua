local gh = require("plz.gh")

local M = {}

M.PAGE_SIZE = 25

local PR_FIELDS = table.concat({
  "id", "number", "title", "author", "reviewDecision",
  "statusCheckRollup", "additions", "deletions",
  "updatedAt", "createdAt", "headRefName", "baseRefName",
  "isDraft", "url", "body", "changedFiles", "state", "comments", "reviews",
  "headRefOid", "baseRefOid", "reviewRequests",
}, ",")

--- Section definitions — each tab in the dashboard.
M.sections = {
  {
    name = "Review Requested",
    filter = "is:pr is:open review-requested:@me",
    args = { "pr", "list", "--state", "open", "--search", "review-requested:@me", "--json", PR_FIELDS, "--limit", tostring(M.PAGE_SIZE) },
  },
  {
    name = "My PRs",
    filter = "is:pr is:open author:@me",
    args = { "pr", "list", "--state", "open", "--author", "@me", "--json", PR_FIELDS, "--limit", tostring(M.PAGE_SIZE) },
  },
  {
    name = "All Open",
    filter = "is:pr is:open",
    args = { "pr", "list", "--state", "open", "--json", PR_FIELDS, "--limit", tostring(M.PAGE_SIZE) },
  },
}

--- Build gh args from a filter string.
--- @param filter string
--- @return string[]
function M.args_from_filter(filter, limit)
  limit = limit or M.PAGE_SIZE
  local args = { "pr", "list", "--json", PR_FIELDS, "--limit", tostring(limit) }
  -- Extract known qualifiers and map to gh flags
  local search_terms = {}
  local has_state = false
  for token in filter:gmatch("%S+") do
    if token == "is:open" or token == "is:closed" or token == "is:merged" or token == "is:all" then
      local st = token:match("is:(%w+)")
      table.insert(args, "--state")
      table.insert(args, st)
      has_state = true
    elseif token:match("^author:") then
      table.insert(args, "--author")
      table.insert(args, token:match("^author:(.+)"))
    elseif token == "is:pr" then
      -- implied, skip
    else
      table.insert(search_terms, token)
    end
  end
  if not has_state then
    table.insert(args, "--state")
    table.insert(args, "all")
  end
  if #search_terms > 0 then
    table.insert(args, "--search")
    table.insert(args, table.concat(search_terms, " "))
  end
  return args
end

--- Fetch PR data for a dashboard section.
--- @param section_idx number 1-indexed section
--- @param callback fun(prs: table[]|nil, err?: string)
function M.fetch_section(section_idx, callback)
  local section = M.sections[section_idx]
  if not section then
    callback(nil, "invalid section index: " .. tostring(section_idx))
    return
  end
  gh.run(section.args, callback)
end

return M
