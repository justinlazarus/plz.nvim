local icons = require("plz.dashboard.render").icons

local M = {}

--- Parse a markdown line into display text and highlight regions.
--- @param raw string Raw markdown line
--- @param offset number Column offset (e.g. 2 for "  " prefix)
--- @return string display_line
--- @return table[] regions
function M.parse_line(raw, offset)
  local regions = {}
  local line = raw

  -- Heading lines: # ## ### etc
  local hashes, heading_text = line:match("^(#+)%s+(.*)")
  if hashes then
    local display = string.rep("  ", #hashes - 1) .. heading_text
    table.insert(regions, { offset, offset + #display, #hashes <= 2 and "PlzAccent" or "PlzHeader" })
    return display, regions
  end

  -- Horizontal rules
  if line:match("^%-%-%-+$") or line:match("^%*%*%*+$") or line:match("^___+$") then
    local display = "─────"
    table.insert(regions, { offset, offset + #display, "PlzBorder" })
    return display, regions
  end

  -- Checkbox list items
  local indent, checked, rest = line:match("^(%s*)%- %[([ xX])%]%s*(.*)")
  if indent then
    local is_checked = checked ~= " "
    local check_icon = is_checked and icons.ci_pass or "○"
    local prefix = indent .. check_icon .. " "
    -- Process inline markdown on the rest
    local inner_display, inner_regions = M.parse_line(rest, offset + #prefix)
    local display = prefix .. inner_display
    local check_hl = is_checked and "PlzSuccess" or "PlzFaint"
    table.insert(regions, { offset + #indent, offset + #indent + #check_icon, check_hl })
    for _, r in ipairs(inner_regions) do
      table.insert(regions, r)
    end
    if is_checked then
      -- Strikethrough effect: dim the text
      table.insert(regions, { offset + #prefix, offset + #display, "PlzFaint" })
    end
    return display, regions
  end

  -- Bullet list items: - or *
  local list_indent, list_rest = line:match("^(%s*)[%-%*]%s+(.*)")
  if list_indent then
    local bullet = list_indent .. "• "
    local inner_display, inner_regions = M.parse_line(list_rest, offset + #bullet)
    return bullet .. inner_display, vim.list_extend(regions, inner_regions)
  end

  -- Inline rendering: process **bold**, *italic*, `code`, [links](url)
  local display = ""
  local pos = offset
  local i = 1
  while i <= #line do
    -- Bold: **text**
    if line:sub(i, i + 1) == "**" then
      local close = line:find("**", i + 2, true)
      if close then
        local inner = line:sub(i + 2, close - 1)
        table.insert(regions, { pos, pos + #inner, "PlzBold" })
        display = display .. inner
        pos = pos + #inner
        i = close + 2
        goto continue
      end
    end
    -- Inline code: `text`
    if line:sub(i, i) == "`" and line:sub(i, i + 2) ~= "```" then
      local close = line:find("`", i + 1, true)
      if close then
        local inner = line:sub(i + 1, close - 1)
        local padded = " " .. inner .. " "
        table.insert(regions, { pos, pos + #padded, "PlzCode" })
        display = display .. padded
        pos = pos + #padded
        i = close + 1
        goto continue
      end
    end
    -- Link: [text](url)
    if line:sub(i, i) == "[" then
      local text_end = line:find("]", i + 1, true)
      if text_end and line:sub(text_end + 1, text_end + 1) == "(" then
        local url_end = line:find(")", text_end + 2, true)
        if url_end then
          local link_text = line:sub(i + 1, text_end - 1)
          table.insert(regions, { pos, pos + #link_text, "PlzLink" })
          display = display .. link_text
          pos = pos + #link_text
          i = url_end + 1
          goto continue
        end
      end
    end
    -- Italic: *text* (single asterisk, not bold)
    if line:sub(i, i) == "*" and line:sub(i, i + 1) ~= "**" then
      local close = line:find("%*", i + 1)
      if close and line:sub(close, close + 1) ~= "**" then
        local inner = line:sub(i + 1, close - 1)
        table.insert(regions, { pos, pos + #inner, "PlzItalic" })
        display = display .. inner
        pos = pos + #inner
        i = close + 1
        goto continue
      end
    end
    -- Regular character
    display = display .. line:sub(i, i)
    pos = pos + 1
    i = i + 1
    ::continue::
  end

  return display, regions
end

--- Convert highlight regions into virt_line segments.
--- @param text string Display text
--- @param regions table[] List of {start, end, hl_group}
--- @param offset number Column offset
--- @return table[] virt_line segments
function M.regions_to_segments(text, regions, offset)
  if #regions == 0 then
    return { { text, "Normal" } }
  end
  -- Sort regions by start position
  local sorted = vim.deepcopy(regions)
  table.sort(sorted, function(a, b) return a[1] < b[1] end)
  local segments = {}
  local pos = 1
  for _, r in ipairs(sorted) do
    local r_start = r[1] + offset
    local r_end = r[2] + offset
    if r_start > #text or r_end < 1 then goto skip end
    r_start = math.max(1, r_start)
    r_end = math.min(#text, r_end)
    if pos < r_start then
      table.insert(segments, { text:sub(pos, r_start - 1), "Normal" })
    end
    table.insert(segments, { text:sub(r_start, r_end), r[3] })
    pos = r_end + 1
    ::skip::
  end
  if pos <= #text then
    table.insert(segments, { text:sub(pos), "Normal" })
  end
  return segments
end

--- Highlight a code block using treesitter, returning per-line highlight info.
--- @param lines string[] Code lines
--- @param lang string Treesitter language name
--- @return table[]|nil Per-line list of {start_col, end_col, hl_group} or nil on failure
function M.highlight_code_block(lines, lang)
  local source = table.concat(lines, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
  if not ok or not parser then return nil end
  local ok2 = pcall(function() parser:parse() end)
  if not ok2 then return nil end
  local tree = parser:trees()[1]
  if not tree then return nil end
  local ok3, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not ok3 or not query then return nil end

  local line_hls = {}
  for i = 1, #lines do line_hls[i] = {} end
  for id, node in query:iter_captures(tree:root(), source, 0, #lines) do
    local name = query.captures[id]
    local sr, sc, er, ec = node:range()
    for row = sr, er do
      local s = (row == sr) and sc or 0
      local e = (row == er) and ec or #lines[row + 1]
      if row + 1 <= #lines then
        table.insert(line_hls[row + 1], { s, e, "@" .. name })
      end
    end
  end
  return line_hls
end

--- Build virt_line segments for a code line with treesitter highlights.
--- @param line string The code line
--- @param hls table[] List of {start_col, end_col, hl_group}
--- @return table[] virt_line segments
function M.build_code_segments(line, hls)
  table.sort(hls, function(a, b) return a[1] < b[1] end)
  local segments = { { "   ", "PlzCode" } }
  local pos = 0
  for _, hl in ipairs(hls) do
    local s, e, group = hl[1], hl[2], hl[3]
    if s > pos then
      segments[#segments + 1] = { line:sub(pos + 1, s), "PlzCode" }
    end
    segments[#segments + 1] = { line:sub(s + 1, e), group }
    pos = e
  end
  if pos < #line then
    segments[#segments + 1] = { line:sub(pos + 1), "PlzCode" }
  end
  return segments
end

--- Infer treesitter language from a filename.
--- @param filename string The filename to infer language for
--- @return string|nil
function M.infer_ts_lang(filename)
  if not filename or filename == "" then return nil end
  local ok, ft = pcall(vim.filetype.match, { filename = filename })
  if not ok or not ft then return nil end
  -- Map filetype to treesitter lang (they sometimes differ)
  local ok2, ts_lang = pcall(vim.treesitter.language.get_lang, ft)
  if ok2 and ts_lang then return ts_lang end
  return ft -- fallback: often the same
end

return M
