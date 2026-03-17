local gh = require("plz.gh")

local M = {}

--- Reference to the shared review state table, set via M.setup().
local state

--- Store a reference to shared state.
--- @param state_ref table  The shared review state table
function M.setup(state_ref)
  state = state_ref
end

--- Extract owner/repo from the current PR URL.
--- @return string|nil, string|nil
local function owner_repo()
  local pr = state and state.pr
  if not pr or not pr.url then return nil, nil end
  return pr.url:match("github%.com/([^/]+)/([^/]+)")
end

--- Submit a review on the current PR.
--- @param event string  APPROVE | REQUEST_CHANGES | COMMENT
--- @param body string|nil  Review body text
--- @param callback function|nil  Called after success
function M.submit_review(event, body, callback)
  local owner, repo = owner_repo()
  if not owner then
    vim.notify("plz: cannot determine repo", vim.log.levels.ERROR)
    return
  end

  local pr_number = state.pr.number
  local args = {
    "api", string.format("repos/%s/%s/pulls/%d/reviews", owner, repo, pr_number),
    "-X", "POST",
    "-f", "event=" .. event,
  }
  if body and body ~= "" then
    table.insert(args, "-f")
    table.insert(args, "body=" .. body)
  end

  gh.run(args, function(_data, err)
    if err then
      vim.notify("plz: failed to submit review", vim.log.levels.ERROR)
      return
    end
    local label = event:lower():gsub("_", " ")
    vim.notify("plz: review submitted — " .. label, vim.log.levels.INFO)

    -- Refresh reviews
    local review_detail = require("plz.review.collections.review_detail")
    review_detail.fetch_reviews(owner, repo, pr_number)
    review_detail.fetch_thread_resolution(owner, repo, pr_number)

    if callback then callback() end
  end)
end

--- Prompt user for a review body and submit.
--- @param event string  APPROVE | REQUEST_CHANGES | COMMENT
function M.prompt_submit_review(event)
  local label = event:lower():gsub("_", " ")
  local prompt_text = "Review body (" .. label .. ", empty to skip): "

  vim.ui.input({ prompt = prompt_text }, function(input)
    if input == nil then return end -- cancelled
    M.submit_review(event, input)
  end)
end

--- Add a top-level review comment (not inline, just a PR comment).
--- @param body string
--- @param callback function|nil
function M.add_comment(body, callback)
  local owner, repo = owner_repo()
  if not owner then
    vim.notify("plz: cannot determine repo", vim.log.levels.ERROR)
    return
  end

  local pr_number = state.pr.number
  gh.run({
    "api", string.format("repos/%s/%s/issues/%d/comments", owner, repo, pr_number),
    "-X", "POST",
    "-f", "body=" .. body,
  }, function(_data, err)
    if err then
      vim.notify("plz: failed to add comment", vim.log.levels.ERROR)
      return
    end
    vim.notify("plz: comment added", vim.log.levels.INFO)

    -- Refresh issue comments
    local review_detail = require("plz.review.collections.review_detail")
    review_detail.fetch_issue_comments(owner, repo, pr_number)

    if callback then callback() end
  end)
end

--- Edit a review comment.
--- @param comment_id number
--- @param new_body string
--- @param callback function|nil
function M.edit_review_comment(comment_id, new_body, callback)
  local owner, repo = owner_repo()
  if not owner then
    vim.notify("plz: cannot determine repo", vim.log.levels.ERROR)
    return
  end

  local pr_number = state.pr.number
  gh.run({
    "api", string.format("repos/%s/%s/pulls/comments/%d", owner, repo, comment_id),
    "-X", "PATCH",
    "-f", "body=" .. new_body,
  }, function(_data, err)
    if err then
      vim.notify("plz: failed to edit comment", vim.log.levels.ERROR)
      return
    end
    vim.notify("plz: comment updated", vim.log.levels.INFO)

    local comments_mod = require("plz.review.comments")
    comments_mod.fetch_review_comments(owner, repo, pr_number)

    local review_detail = require("plz.review.collections.review_detail")
    review_detail.fetch_reviews(owner, repo, pr_number)

    if callback then callback() end
  end)
end

--- Edit an issue (timeline) comment.
--- @param comment_id number
--- @param new_body string
--- @param callback function|nil
function M.edit_issue_comment(comment_id, new_body, callback)
  local owner, repo = owner_repo()
  if not owner then
    vim.notify("plz: cannot determine repo", vim.log.levels.ERROR)
    return
  end

  local pr_number = state.pr.number
  gh.run({
    "api", string.format("repos/%s/%s/issues/comments/%d", owner, repo, comment_id),
    "-X", "PATCH",
    "-f", "body=" .. new_body,
  }, function(_data, err)
    if err then
      vim.notify("plz: failed to edit comment", vim.log.levels.ERROR)
      return
    end
    vim.notify("plz: comment updated", vim.log.levels.INFO)

    local review_detail = require("plz.review.collections.review_detail")
    review_detail.fetch_issue_comments(owner, repo, pr_number)

    if callback then callback() end
  end)
end

--- Prompt user and add a top-level comment.
function M.prompt_add_comment()
  vim.ui.input({ prompt = "Comment: " }, function(input)
    if not input or input == "" then return end
    M.add_comment(input)
  end)
end

--- Add an inline review comment on a specific file and line.
--- @param path string  File path
--- @param line number  Line number (on the diff side)
--- @param side string  "RIGHT" or "LEFT"
--- @param body string  Comment body
--- @param callback function|nil
function M.add_inline_comment(path, line, side, body, callback)
  local owner, repo = owner_repo()
  if not owner then
    vim.notify("plz: cannot determine repo", vim.log.levels.ERROR)
    return
  end

  local pr_number = state.pr.number
  local args = {
    "api", string.format("repos/%s/%s/pulls/%d/comments", owner, repo, pr_number),
    "-X", "POST",
    "-f", "body=" .. body,
    "-f", "commit_id=" .. state.head_sha,
    "-f", "path=" .. path,
    "-F", "line=" .. tostring(line),
    "-f", "side=" .. side,
  }

  gh.run(args, function(_data, err)
    if err then
      vim.notify("plz: failed to add inline comment", vim.log.levels.ERROR)
      return
    end
    vim.notify("plz: inline comment added", vim.log.levels.INFO)

    -- Refresh comments
    local comments = require("plz.review.comments")
    comments.fetch_review_comments(owner, repo, pr_number)

    if callback then callback() end
  end)
end

--- Reply to an existing review comment thread.
--- @param comment_id number  The root comment ID to reply to
--- @param body string  Reply body
--- @param callback function|nil
function M.reply_to_comment(comment_id, body, callback)
  local owner, repo = owner_repo()
  if not owner then
    vim.notify("plz: cannot determine repo", vim.log.levels.ERROR)
    return
  end

  local pr_number = state.pr.number
  gh.run({
    "api", string.format("repos/%s/%s/pulls/%d/comments/%d/replies", owner, repo, pr_number, comment_id),
    "-X", "POST",
    "-f", "body=" .. body,
  }, function(_data, err)
    if err then
      vim.notify("plz: failed to reply", vim.log.levels.ERROR)
      return
    end
    vim.notify("plz: reply added", vim.log.levels.INFO)

    -- Refresh comments
    local comments = require("plz.review.comments")
    comments.fetch_review_comments(owner, repo, pr_number)

    -- Refresh review detail
    local review_detail = require("plz.review.collections.review_detail")
    review_detail.fetch_reviews(owner, repo, pr_number)
    review_detail.fetch_thread_resolution(owner, repo, pr_number)

    if callback then callback() end
  end)
end

--- Delete a review comment.
--- @param comment_id number
--- @param callback function|nil
function M.delete_comment(comment_id, callback)
  local owner, repo = owner_repo()
  if not owner then
    vim.notify("plz: cannot determine repo", vim.log.levels.ERROR)
    return
  end

  local pr_number = state.pr.number
  gh.run({
    "api", string.format("repos/%s/%s/pulls/comments/%d", owner, repo, comment_id),
    "-X", "DELETE",
  }, function(_data, err)
    if err then
      vim.notify("plz: failed to delete comment", vim.log.levels.ERROR)
      return
    end
    vim.notify("plz: comment deleted", vim.log.levels.INFO)

    -- Refresh comments
    local comments = require("plz.review.comments")
    comments.fetch_review_comments(owner, repo, pr_number)

    -- Refresh review detail
    local review_detail = require("plz.review.collections.review_detail")
    review_detail.fetch_reviews(owner, repo, pr_number)
    review_detail.fetch_thread_resolution(owner, repo, pr_number)

    if callback then callback() end
  end)
end

--- Delete a review submission. Falls back to dismiss if delete fails.
--- @param review_id number
--- @param callback function|nil
function M.delete_review(review_id, callback)
  local owner, repo = owner_repo()
  if not owner then
    vim.notify("plz: cannot determine repo", vim.log.levels.ERROR)
    return
  end

  local pr_number = state.pr.number
  local endpoint = string.format("repos/%s/%s/pulls/%d/reviews/%d", owner, repo, pr_number, review_id)

  -- Try DELETE first (works for own reviews without threads)
  gh.run({ "api", endpoint, "-X", "DELETE" }, function(_data, err)
    if not err then
      vim.notify("plz: review deleted", vim.log.levels.INFO)
      local review_detail = require("plz.review.collections.review_detail")
      review_detail.fetch_reviews(owner, repo, pr_number)
      review_detail.fetch_thread_resolution(owner, repo, pr_number)
      if callback then callback() end
      return
    end

    -- Fallback: dismiss
    gh.run({
      "api", endpoint .. "/dismissals",
      "-X", "PUT",
      "-f", "message=Dismissed",
    }, function(_data2, err2)
      if err2 then
        vim.notify("plz: failed to delete or dismiss review", vim.log.levels.ERROR)
        return
      end
      vim.notify("plz: review dismissed", vim.log.levels.INFO)
      local review_detail = require("plz.review.collections.review_detail")
      review_detail.fetch_reviews(owner, repo, pr_number)
      review_detail.fetch_thread_resolution(owner, repo, pr_number)
      if callback then callback() end
    end)
  end)
end

--- Delete an issue (timeline) comment.
--- @param comment_id number
--- @param callback function|nil
function M.delete_issue_comment(comment_id, callback)
  local owner, repo = owner_repo()
  if not owner then
    vim.notify("plz: cannot determine repo", vim.log.levels.ERROR)
    return
  end

  local pr_number = state.pr.number
  gh.run({
    "api", string.format("repos/%s/%s/issues/comments/%d", owner, repo, comment_id),
    "-X", "DELETE",
  }, function(_data, err)
    if err then
      vim.notify("plz: failed to delete comment", vim.log.levels.ERROR)
      return
    end
    vim.notify("plz: comment deleted", vim.log.levels.INFO)

    -- Refresh issue comments
    local review_detail = require("plz.review.collections.review_detail")
    review_detail.fetch_issue_comments(owner, repo, pr_number)

    if callback then callback() end
  end)
end

--- Resolve or unresolve a review thread via GraphQL.
--- @param thread_id string  The GraphQL node ID of the review thread
--- @param resolve boolean  true to resolve, false to unresolve
--- @param callback function|nil
function M.toggle_thread_resolved(thread_id, resolve, callback)
  local owner, repo = owner_repo()
  if not owner then
    vim.notify("plz: cannot determine repo", vim.log.levels.ERROR)
    return
  end

  local mutation = resolve and "resolveReviewThread" or "unresolveReviewThread"
  local query = string.format([[
mutation {
  %s(input: { threadId: "%s" }) {
    thread { isResolved }
  }
}]], mutation, thread_id)

  local pr_number = state.pr.number

  gh.run({ "api", "graphql", "-f", "query=" .. query }, function(_data, err)
    if err then
      vim.notify("plz: failed to " .. (resolve and "resolve" or "unresolve") .. " thread", vim.log.levels.ERROR)
      return
    end
    vim.notify("plz: thread " .. (resolve and "resolved" or "unresolved"), vim.log.levels.INFO)

    -- Refresh thread resolution status
    local review_detail = require("plz.review.collections.review_detail")
    review_detail.fetch_thread_resolution(owner, repo, pr_number)

    if callback then callback() end
  end)
end

return M
