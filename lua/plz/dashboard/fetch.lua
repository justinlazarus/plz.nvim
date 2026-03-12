local gh = require("plz.gh")

local M = {}

local PR_FIELDS = table.concat({
  "number", "title", "author", "reviewDecision",
  "statusCheckRollup", "additions", "deletions",
  "updatedAt", "headRefName", "baseRefName",
  "isDraft", "url", "body", "changedFiles", "state",
}, ",")

--- Section definitions — each tab in the dashboard.
M.sections = {
  {
    name = "Review Requested",
    args = { "pr", "list", "--state", "open", "--search", "review-requested:@me", "--json", PR_FIELDS, "--limit", "50" },
  },
  {
    name = "My PRs",
    args = { "pr", "list", "--state", "open", "--author", "@me", "--json", PR_FIELDS, "--limit", "50" },
  },
  {
    name = "All Open",
    args = { "pr", "list", "--state", "open", "--json", PR_FIELDS, "--limit", "50" },
  },
}

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
