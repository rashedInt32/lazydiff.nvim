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

local function build_above_virt_lines(hunk, signs, show_header)
  local lines = {}
  if show_header then
    lines[#lines + 1] = { { diff_mod.format_hunk_header(hunk), "LazydiffHunkHeader" } }
  end
  for _, content in ipairs(hunk.old_lines) do
    lines[#lines + 1] = {
      { signs.delete, "LazydiffDeleteSign" },
      { content, "LazydiffDelete" },
    }
  end
  return lines
end

local function set_above(bufnr, anchor_0based, virt_lines)
  if #virt_lines == 0 then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, anchor_0based, 0, {
    virt_lines = virt_lines,
    virt_lines_above = true,
  })
end

local function set_below(bufnr, anchor_0based, virt_lines)
  if #virt_lines == 0 then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, anchor_0based, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
  })
end

local function mark_added_line(bufnr, line_0based, sign_text)
  -- Split into two extmarks: a high-priority inline virt_text for the +
  -- prefix, and a separate one for the line bg band. Keeping them on
  -- distinct extmarks avoids any rendering interaction between
  -- virt_text_pos="inline" and line_hl_group on the same mark, and makes
  -- the prefix priority obvious at a glance.
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, line_0based, 0, {
    virt_text = { { sign_text, "LazydiffAddSign" } },
    virt_text_pos = "inline",
    right_gravity = false,
    priority = 200,
  })
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, line_0based, 0, {
    line_hl_group = "LazydiffAdd",
    priority = 100,
  })
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
    local above_lines = build_above_virt_lines(hunk, signs, show_header)

    if hunk.new_count > 0 then
      -- Hunk has buffer-anchored content: place header+deletes ABOVE the first new line.
      local anchor = hunk.new_start - 1
      if anchor < 0 then
        anchor = 0
      end
      set_above(bufnr, anchor, above_lines)
      for i = 0, hunk.new_count - 1 do
        local line = hunk.new_start - 1 + i
        if line >= 0 and line < total_lines then
          mark_added_line(bufnr, line, signs.add)
        end
      end
    else
      -- Pure deletion: new_start is the buffer line AFTER which the deletion sits
      -- (0 if deleted from the top of the file).
      if hunk.new_start == 0 then
        if total_lines > 0 then
          set_above(bufnr, 0, above_lines)
        end
      else
        local anchor = hunk.new_start - 1
        if anchor >= total_lines then
          anchor = total_lines - 1
        end
        set_below(bufnr, anchor, above_lines)
      end
    end
  end
end

return M
