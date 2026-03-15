describe("dashboard.fetch", function()
  local fetch

  setup(function()
    -- Stub require("plz").config so get_sections() works without full setup
    package.loaded["plz"] = {
      config = {
        dashboard = {
          sections = {
            { name = "Review Requested", filter = "is:pr is:open review-requested:@me" },
            { name = "My PRs", filter = "is:pr is:open author:@me" },
            { name = "All Open", filter = "is:pr is:open" },
          },
        },
      },
    }
    -- Stub plz.gh to avoid real CLI calls
    package.loaded["plz.gh"] = { run = function() end }
    fetch = require("plz.dashboard.fetch")
  end)

  teardown(function()
    package.loaded["plz"] = nil
    package.loaded["plz.gh"] = nil
    package.loaded["plz.dashboard.fetch"] = nil
  end)

  describe("args_from_filter", function()
    it("parses is:open state", function()
      local args = fetch.args_from_filter("is:pr is:open")
      assert.is_true(vim.tbl_contains(args, "--state"))
      assert.is_true(vim.tbl_contains(args, "open"))
    end)

    it("parses author qualifier", function()
      local args = fetch.args_from_filter("is:pr is:open author:@me")
      assert.is_true(vim.tbl_contains(args, "--author"))
      assert.is_true(vim.tbl_contains(args, "@me"))
    end)

    it("defaults to --state all when no state given", function()
      local args = fetch.args_from_filter("is:pr author:@me")
      assert.is_true(vim.tbl_contains(args, "--state"))
      assert.is_true(vim.tbl_contains(args, "all"))
    end)

    it("puts unknown tokens into --search", function()
      local args = fetch.args_from_filter("is:pr is:open review-requested:@me")
      assert.is_true(vim.tbl_contains(args, "--search"))
      assert.is_true(vim.tbl_contains(args, "review-requested:@me"))
    end)

    it("respects custom limit", function()
      local args = fetch.args_from_filter("is:pr is:open", 50)
      assert.is_true(vim.tbl_contains(args, "--limit"))
      assert.is_true(vim.tbl_contains(args, "50"))
    end)

    it("uses default PAGE_SIZE when no limit given", function()
      local args = fetch.args_from_filter("is:pr is:open")
      assert.is_true(vim.tbl_contains(args, "--limit"))
      assert.is_true(vim.tbl_contains(args, tostring(fetch.PAGE_SIZE)))
    end)

    it("starts with pr list subcommand", function()
      local args = fetch.args_from_filter("is:pr is:open")
      assert.are.equal("pr", args[1])
      assert.are.equal("list", args[2])
    end)

    it("includes --json with PR fields", function()
      local args = fetch.args_from_filter("is:pr is:open")
      assert.is_true(vim.tbl_contains(args, "--json"))
      -- The field list should be at the position after --json
      for i, v in ipairs(args) do
        if v == "--json" then
          assert.is_truthy(args[i + 1]:match("number"))
          assert.is_truthy(args[i + 1]:match("title"))
          break
        end
      end
    end)

    it("parses is:merged state", function()
      local args = fetch.args_from_filter("is:pr is:merged")
      assert.is_true(vim.tbl_contains(args, "--state"))
      assert.is_true(vim.tbl_contains(args, "merged"))
    end)

    it("parses is:closed state", function()
      local args = fetch.args_from_filter("is:pr is:closed")
      assert.is_true(vim.tbl_contains(args, "--state"))
      assert.is_true(vim.tbl_contains(args, "closed"))
    end)
  end)

  describe("get_sections", function()
    it("returns configured sections", function()
      local sections = fetch.get_sections()
      assert.are.equal(3, #sections)
      assert.are.equal("Review Requested", sections[1].name)
    end)
  end)
end)
