describe("diff.align", function()
  local align

  setup(function()
    align = require("plz.diff.align")
  end)

  describe("build", function()
    it("aligns identical files with no diff", function()
      local old = { "line1", "line2", "line3" }
      local new = { "line1", "line2", "line3" }
      local diff = { hunks = {} }

      local lhs, rhs = align.build(old, new, diff)
      assert.are.equal(3, #lhs)
      assert.are.equal(3, #rhs)
      for i = 1, 3 do
        assert.are.equal(old[i], lhs[i].text)
        assert.are.equal(new[i], rhs[i].text)
        assert.are.equal(i - 1, lhs[i].orig)
        assert.are.equal(i - 1, rhs[i].orig)
      end
    end)

    it("inserts filler for added lines", function()
      local old = { "line1", "line3" }
      local new = { "line1", "line2", "line3" }
      local diff = {
        hunks = { {
          entries = {
            { type = "add", rhs_line = 1 }, -- line2 added at index 1 (0-based)
            { type = "change", lhs_line = 1, rhs_line = 2 }, -- line3 anchored
          },
        } },
      }

      local lhs, rhs = align.build(old, new, diff)
      -- Should have a filler on lhs where rhs has the added line
      local found_filler = false
      for _, entry in ipairs(lhs) do
        if entry.orig == nil and entry.text == "" then
          found_filler = true
          break
        end
      end
      assert.is_true(found_filler, "expected filler line on LHS for added line")
    end)

    it("inserts filler for removed lines", function()
      local old = { "line1", "line2", "line3" }
      local new = { "line1", "line3" }
      local diff = {
        hunks = { {
          entries = {
            { type = "remove", lhs_line = 1 }, -- line2 removed at index 1
            { type = "change", lhs_line = 2, rhs_line = 1 }, -- line3 anchored
          },
        } },
      }

      local lhs, rhs = align.build(old, new, diff)
      local found_filler = false
      for _, entry in ipairs(rhs) do
        if entry.orig == nil and entry.text == "" then
          found_filler = true
          break
        end
      end
      assert.is_true(found_filler, "expected filler line on RHS for removed line")
    end)

    it("produces equal-length output arrays", function()
      local old = { "a", "b", "c", "d" }
      local new = { "a", "x", "y", "d" }
      local diff = {
        hunks = { {
          entries = {
            { type = "change", lhs_line = 1, rhs_line = 1 },
            { type = "change", lhs_line = 2, rhs_line = 2 },
          },
        } },
      }

      local lhs, rhs = align.build(old, new, diff)
      assert.are.equal(#lhs, #rhs)
    end)

    it("handles empty diff result", function()
      local old = { "a", "b" }
      local new = { "a", "b" }
      local diff = {}

      local lhs, rhs = align.build(old, new, diff)
      assert.are.equal(2, #lhs)
      assert.are.equal(2, #rhs)
    end)
  end)

  describe("collapse", function()
    it("returns input unchanged when all lines are changed", function()
      local lhs = {
        { text = "a", orig = 0 },
        { text = "b", orig = 1 },
      }
      local rhs = {
        { text = "x", orig = 0 },
        { text = "y", orig = 1 },
      }
      local diff = {
        hunks = { {
          entries = {
            { type = "change", lhs_line = 0, rhs_line = 0 },
            { type = "change", lhs_line = 1, rhs_line = 1 },
          },
        } },
      }

      local cl, cr = align.collapse(lhs, rhs, diff, 3)
      assert.are.equal(2, #cl)
      assert.are.equal(2, #cr)
    end)

    it("creates fold entries for large unchanged regions", function()
      -- 20 lines, only line 10 changed
      local lhs, rhs = {}, {}
      for i = 0, 19 do
        table.insert(lhs, { text = "line" .. i, orig = i })
        table.insert(rhs, { text = "line" .. i, orig = i })
      end
      local diff = {
        hunks = { {
          entries = {
            { type = "change", lhs_line = 10, rhs_line = 10 },
          },
        } },
      }

      local cl, cr = align.collapse(lhs, rhs, diff, 3)
      -- Should have fold entries for lines 0-6 and 14-19
      local fold_count = 0
      for _, entry in ipairs(cl) do
        if entry.fold then fold_count = fold_count + 1 end
      end
      assert.is_true(fold_count >= 1, "expected at least one fold entry")
    end)

    it("preserves context lines around changes", function()
      -- 20 lines, only line 10 changed, context=2
      local lhs, rhs = {}, {}
      for i = 0, 19 do
        table.insert(lhs, { text = "line" .. i, orig = i })
        table.insert(rhs, { text = "line" .. i, orig = i })
      end
      local diff = {
        hunks = { {
          entries = {
            { type = "change", lhs_line = 10, rhs_line = 10 },
          },
        } },
      }

      local cl, _ = align.collapse(lhs, rhs, diff, 2)
      -- Lines 8-12 (indices 9-13 in 1-based) should be visible
      -- Count non-fold entries
      local visible = 0
      for _, entry in ipairs(cl) do
        if not entry.fold then visible = visible + 1 end
      end
      assert.are.equal(5, visible) -- 2 before + change + 2 after
    end)

    it("handles empty input", function()
      local cl, cr = align.collapse({}, {}, { hunks = {} }, 3)
      assert.are.equal(0, #cl)
      assert.are.equal(0, #cr)
    end)
  end)
end)
