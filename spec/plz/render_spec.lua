describe("dashboard.render", function()
  local render

  setup(function()
    render = require("plz.dashboard.render")
  end)

  describe("compute_columns", function()
    it("returns expected column keys", function()
      local cols = render.compute_columns(120)
      local expected_keys = {
        "number", "state", "comments", "review",
        "ci", "files", "lines", "updated", "created", "ado",
      }
      for _, key in ipairs(expected_keys) do
        assert.is_not_nil(cols[key], "missing key: " .. key)
      end
    end)

    it("fixed columns stay constant across widths", function()
      local c1 = render.compute_columns(80)
      local c2 = render.compute_columns(200)
      assert.are.equal(c1.state, c2.state)
      assert.are.equal(c1.ci, c2.ci)
      assert.are.equal(c1.lines, c2.lines)
    end)
  end)

  describe("_format_number", function()
    it("returns plain number below 1000", function()
      assert.are.equal("0", render._format_number(0))
      assert.are.equal("999", render._format_number(999))
      assert.are.equal("42", render._format_number(42))
    end)

    it("formats thousands with k suffix", function()
      assert.are.equal("1.0k", render._format_number(1000))
      assert.are.equal("1.5k", render._format_number(1500))
      assert.are.equal("10.0k", render._format_number(10000))
    end)
  end)

  describe("_clean_title", function()
    it("strips bracket tags", function()
      assert.are.equal("Fix login bug", render._clean_title("[Bug] Fix login bug", ""))
    end)

    it("strips AB# references", function()
      assert.are.equal("Fix login", render._clean_title("AB#12345 Fix login", ""))
    end)

    it("strips branch name from title", function()
      assert.are.equal("Add feature", render._clean_title("feature/add-feature - Add feature", "feature/add-feature"))
    end)

    it("collapses multiple spaces", function()
      assert.are.equal("Fix bug", render._clean_title("Fix   bug", ""))
    end)

    it("strips leading/trailing dashes and dots", function()
      assert.are.equal("Fix bug", render._clean_title("-- Fix bug --", ""))
    end)

    it("handles empty title", function()
      assert.are.equal("", render._clean_title("", ""))
    end)

    it("handles title with only brackets", function()
      assert.are.equal("", render._clean_title("[Main]", ""))
    end)
  end)

  describe("_truncate", function()
    it("returns short strings unchanged", function()
      assert.are.equal("hello", render._truncate("hello", 10))
    end)

    it("truncates long strings with ellipsis", function()
      local result = render._truncate("hello world", 8)
      assert.are.equal(8, #result - 2) -- ellipsis is multi-byte
      assert.is_truthy(result:match("…$"))
    end)

    it("returns string at exact max length unchanged", function()
      assert.are.equal("hello", render._truncate("hello", 5))
    end)
  end)

  describe("_relative_time", function()
    it("returns ? for nil input", function()
      assert.are.equal("?", render._relative_time(nil))
    end)

    it("returns ? for invalid format", function()
      assert.are.equal("?", render._relative_time("not-a-date"))
    end)

    it("returns now for recent timestamps", function()
      -- _relative_time parses into local time via os.time(), so use local time format
      local now = os.date("%Y-%m-%dT%H:%M:%S")
      assert.are.equal("now", render._relative_time(now))
    end)

    it("returns minutes for timestamps under 1 hour", function()
      local t = os.time() - 300 -- 5 minutes ago
      local iso = os.date("%Y-%m-%dT%H:%M:%S", t)
      local result = render._relative_time(iso)
      assert.is_truthy(result:match("%d+m"))
    end)

    it("returns hours for timestamps under 1 day", function()
      local t = os.time() - 7200 -- 2 hours ago
      local iso = os.date("%Y-%m-%dT%H:%M:%S", t)
      local result = render._relative_time(iso)
      assert.is_truthy(result:match("%d+h"))
    end)
  end)

  describe("_format_time", function()
    it("returns ? for nil input", function()
      assert.are.equal("?", render._format_time(nil))
    end)

    it("returns ? for invalid format", function()
      assert.are.equal("?", render._format_time("not-a-date"))
    end)

    it("formats as MM/DD HH:MM", function()
      assert.are.equal("03/16 14:30", render._format_time("2026-03-16T14:30:00Z"))
    end)

    it("preserves leading zeros", function()
      assert.are.equal("01/05 09:02", render._format_time("2026-01-05T09:02:15Z"))
    end)
  end)

  describe("_review_icon", function()
    it("returns approved icon for APPROVED", function()
      local icon, hl = render._review_icon("APPROVED", {})
      assert.are.equal(render.icons.approved, icon)
      assert.are.equal("PlzSuccess", hl)
    end)

    it("returns changes icon for CHANGES_REQUESTED", function()
      local icon, hl = render._review_icon("CHANGES_REQUESTED", {})
      assert.are.equal(render.icons.changes, icon)
      assert.are.equal("PlzError", hl)
    end)

    it("returns comment icon when reviews exist but undecided", function()
      local icon, hl = render._review_icon(nil, { { id = 1 } })
      assert.are.equal(render.icons.comment, icon)
      assert.are.equal("PlzFaint", hl)
    end)

    it("returns waiting icon when no reviews", function()
      local icon, hl = render._review_icon(nil, {})
      assert.are.equal(render.icons.waiting, icon)
      assert.are.equal("PlzWarning", hl)
    end)
  end)

  describe("_ci_icon", function()
    it("returns none icon for empty rollup", function()
      local icon, hl = render._ci_icon({})
      assert.are.equal(render.icons.ci_none, icon)
      assert.are.equal("PlzFaint", hl)
    end)

    it("returns none icon for nil rollup", function()
      local icon, hl = render._ci_icon(nil)
      assert.are.equal(render.icons.ci_none, icon)
    end)

    it("returns fail icon when any check failed", function()
      local icon, hl = render._ci_icon({
        { conclusion = "SUCCESS" },
        { conclusion = "FAILURE" },
      })
      assert.are.equal(render.icons.ci_fail, icon)
      assert.are.equal("PlzError", hl)
    end)

    it("returns wait icon when checks in progress", function()
      local icon, hl = render._ci_icon({
        { conclusion = "SUCCESS", status = "COMPLETED" },
        { status = "IN_PROGRESS" },
      })
      assert.are.equal(render.icons.ci_wait, icon)
      assert.are.equal("PlzWarning", hl)
    end)

    it("returns pass icon when all checks pass", function()
      local icon, hl = render._ci_icon({
        { conclusion = "SUCCESS", status = "COMPLETED" },
        { conclusion = "SUCCESS", status = "COMPLETED" },
      })
      assert.are.equal(render.icons.ci_pass, icon)
      assert.are.equal("PlzSuccess", hl)
    end)
  end)

  describe("_lines_cell", function()
    it("combines add and del strings", function()
      assert.are.equal("+5 -3", render._lines_cell("+5", "-3"))
    end)
  end)

  describe("_lines_regions", function()
    it("returns add and del highlight regions", function()
      local regions = render._lines_regions("+123", "-45")
      assert.are.equal(2, #regions)
      assert.are.equal("PlzDiffAdd", regions[1][3])
      assert.are.equal("PlzDiffRemove", regions[2][3])
      -- add region: 0 to 4
      assert.are.equal(0, regions[1][1])
      assert.are.equal(4, regions[1][2])
      -- del region: 5 to 8
      assert.are.equal(5, regions[2][1])
      assert.are.equal(8, regions[2][2])
    end)
  end)

  describe("tab_line", function()
    it("renders section names with separators", function()
      local sections = {
        { name = "Tab1" },
        { name = "Tab2" },
      }
      local line, regions = render.tab_line(sections, 1)
      assert.is_truthy(line:match("Tab1"))
      assert.is_truthy(line:match("Tab2"))
      assert.is_true(#regions > 0)
    end)

    it("uses active highlight for selected tab", function()
      local sections = {
        { name = "Tab1" },
        { name = "Tab2" },
      }
      local _, regions = render.tab_line(sections, 1)
      -- First region (after any separator) should be PlzTabActive
      assert.are.equal("PlzTabActive", regions[1][3])
    end)

    it("uses inactive highlight for non-selected tabs", function()
      local sections = {
        { name = "Tab1" },
        { name = "Tab2" },
      }
      local _, regions = render.tab_line(sections, 1)
      -- After separator, second tab should be inactive
      -- regions: [Tab1=active, sep, Tab2=inactive, trailing_sep]
      assert.are.equal("PlzTabInactive", regions[3][3])
    end)
  end)

  describe("filter_line", function()
    it("includes the filter text", function()
      local line, _ = render.filter_line("is:pr is:open")
      assert.is_truthy(line:match("is:pr is:open"))
    end)

    it("returns highlight regions", function()
      local _, regions = render.filter_line("is:pr")
      assert.is_true(#regions > 0)
    end)
  end)
end)
