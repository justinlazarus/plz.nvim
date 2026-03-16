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

    it("handles swapped lines (crossed anchors)", function()
      local old = { "a", "B", "C", "d" }
      local new = { "a", "C", "B", "d" }
      -- Difftastic reports crossed anchors: lhs 1↔rhs 2, lhs 2↔rhs 1
      local diff = {
        hunks = { {
          entries = {
            { type = "change", lhs_line = 1, rhs_line = 2 },
            { type = "change", lhs_line = 2, rhs_line = 1 },
          },
        } },
      }

      local lhs, rhs = align.build(old, new, diff)
      assert.are.equal(#lhs, #rhs)
      -- Both sides must have monotonically increasing orig values
      -- (ignoring nil fillers)
      local prev_lhs = -1
      local prev_rhs = -1
      for i = 1, #lhs do
        if lhs[i].orig then
          assert.is_true(lhs[i].orig > prev_lhs,
            "LHS orig not monotonic at row " .. i)
          prev_lhs = lhs[i].orig
        end
        if rhs[i].orig then
          assert.is_true(rhs[i].orig > prev_rhs,
            "RHS orig not monotonic at row " .. i)
          prev_rhs = rhs[i].orig
        end
      end
      -- All 4 original lines from each side must appear
      local lhs_origs = {}
      local rhs_origs = {}
      for _, e in ipairs(lhs) do
        if e.orig then lhs_origs[e.orig] = true end
      end
      for _, e in ipairs(rhs) do
        if e.orig then rhs_origs[e.orig] = true end
      end
      for i = 0, 3 do
        assert.is_true(lhs_origs[i] ~= nil, "missing LHS orig " .. i)
        assert.is_true(rhs_origs[i] ~= nil, "missing RHS orig " .. i)
      end
    end)

    it("fills gaps in add_set for unreported blank lines", function()
      -- Simulates difftastic skipping a blank line (rhs line 2) within an insertion
      local old = { "a", "d" }
      local new = { "a", "b", "", "c", "d" }
      local diff = {
        hunks = { {
          entries = {
            { type = "add", rhs_line = 1 },  -- "b"
            -- rhs_line 2 ("") is NOT reported by difftastic
            { type = "add", rhs_line = 3 },  -- "c"
          },
        } },
      }

      local lhs, rhs = align.build(old, new, diff)
      assert.are.equal(#lhs, #rhs)
      -- "d" must align: find it on both sides at the same row
      local lhs_d_row, rhs_d_row
      for i = 1, #lhs do
        if lhs[i].text == "d" then lhs_d_row = i end
        if rhs[i].text == "d" then rhs_d_row = i end
      end
      assert.is_not_nil(lhs_d_row, "LHS must contain 'd'")
      assert.is_not_nil(rhs_d_row, "RHS must contain 'd'")
      assert.are.equal(lhs_d_row, rhs_d_row,
        "LHS 'd' and RHS 'd' must be on the same row")
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
