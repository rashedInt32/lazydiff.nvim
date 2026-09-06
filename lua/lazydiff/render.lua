local M = {}

local diff_mod = require("lazydiff.diff")
local config = require("lazydiff.config")

local NS = vim.api.nvim_create_namespace("lazydiff")

function M.namespace()
  return NS
end

function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  end
end

-- Word-level ranges for a change hunk whose lines pair up one-to-one.
-- Returns (old_ranges[i], new_ranges[i]) or nil when word diff doesn't apply.
local function word_ranges(hunk)
  if not config.options.word_diff or hunk.kind ~= "change" or hunk.old_count ~= hunk.new_count then
    return nil
  end
  local olds, news = {}, {}
  for i = 1, hunk.old_count do
    olds[i], news[i] = diff_mod.word_diff(hunk.old_lines[i], hunk.new_lines[i])
  end
  return olds, news
end

-- A deleted line as virt_text chunks: the sign, then the content split into
-- plain and emphasised spans.
local function delete_chunks(content, ranges, sign)
  local chunks = { { sign, "LazydiffDeleteSign" } }
  local pos = 0
  for _, r in ipairs(ranges or {}) do
    if r[1] > pos then
      chunks[#chunks + 1] = { content:sub(pos + 1, r[1]), "LazydiffDelete" }
    end
    chunks[#chunks + 1] = { content:sub(r[1] + 1, r[2]), "LazydiffDeleteWord" }
    pos = r[2]
  end
  if pos < #content then
    chunks[#chunks + 1] = { content:sub(pos + 1), "LazydiffDelete" }
  end
  return chunks
end

local function build_above_virt_lines(hunk, signs, show_header, old_word_ranges)
  local lines = {}
  if show_header then
    lines[#lines + 1] = { { diff_mod.format_hunk_header(hunk), "LazydiffHunkHeader" } }
  end
  for i, content in ipairs(hunk.old_lines) do
    lines[#lines + 1] = delete_chunks(content, old_word_ranges and old_word_ranges[i], signs.delete)
  end
  return lines
end

local function set_virt_lines(bufnr, anchor_0based, virt_lines, above)
  if #virt_lines == 0 then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, anchor_0based, 0, {
    virt_lines = virt_lines,
    virt_lines_above = above,
  })
end

local function mark_added_line(bufnr, line_0based, sign_text, word_ranges_for_line)
  -- The + marker goes in the sign column, not as inline virt_text. Three
  -- earlier attempts to render it inline failed in this user's colorscheme
  -- + plugin combination (line bg painted over the virt_text, or some other
  -- extmark plugin overlapped at col 0). Sign column has its own dedicated
  -- render path that no other plugin can paint over.
  --
  -- The hl_group + hl_eol on the same extmark paints the green band across
  -- the buffer text region only.
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, line_0based, 0, {
    sign_text = sign_text,
    sign_hl_group = "LazydiffAddSign",
    end_row = line_0based + 1,
    end_col = 0,
    hl_group = "LazydiffAdd",
    hl_eol = true,
    priority = 1000,
  })
  for _, r in ipairs(word_ranges_for_line or {}) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, line_0based, r[1], {
      end_col = r[2],
      hl_group = "LazydiffAddWord",
      priority = 1001,
    })
  end
end

function M.render(bufnr, hunks)
  M.clear(bufnr)
  if not hunks or #hunks == 0 then
    return
  end

  local cfg = config.options
  local signs = cfg.signs
  local show_header = cfg.show_hunk_header
  local total_lines = vim.api.nvim_buf_line_count(bufnr)

  for _, hunk in ipairs(hunks) do
    local old_words, new_words = word_ranges(hunk)
    local above_lines = build_above_virt_lines(hunk, signs, show_header, old_words)

    if hunk.new_count > 0 then
      -- Hunk has buffer-anchored content: place header+deletes ABOVE the first new line.
      local anchor = math.max(hunk.new_start - 1, 0)
      set_virt_lines(bufnr, anchor, above_lines, true)
      for i = 0, hunk.new_count - 1 do
        local line = hunk.new_start - 1 + i
        if line >= 0 and line < total_lines then
          mark_added_line(bufnr, line, signs.add, new_words and new_words[i + 1])
        end
      end
    else
      -- Pure deletion: new_start is the buffer line AFTER which the deletion sits
      -- (0 if deleted from the top of the file).
      if hunk.new_start == 0 then
        if total_lines > 0 then
          set_virt_lines(bufnr, 0, above_lines, true)
        end
      else
        local anchor = math.min(hunk.new_start - 1, total_lines - 1)
        set_virt_lines(bufnr, anchor, above_lines, false)
      end
    end
  end
end

return M
