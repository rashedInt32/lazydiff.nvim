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
  -- Two extmarks:
  --   1) inline virt_text with the + prefix (sits BEFORE buffer col 0)
  --   2) hl_group across the buffer text + hl_eol = true to extend to the
  --      right edge of the window
  --
  -- We use hl_group with end-of-line extension instead of line_hl_group on
  -- purpose. line_hl_group also paints the bg behind the inline virt_text
  -- region, which makes the + sign's fg sit on the same green tint as the
  -- band — invisible in colorschemes where DiffAdd's fg/bg luminance are
  -- close. Restricting the highlight to (col 0 → eol) leaves the prefix
  -- area on the buffer's normal bg so the marker stays vivid.
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, line_0based, 0, {
    virt_text = { { sign_text, "LazydiffAddSign" } },
    virt_text_pos = "inline",
    right_gravity = false,
    priority = 200,
  })
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, line_0based, 0, {
    end_row = line_0based + 1,
    end_col = 0,
    hl_group = "LazydiffAdd",
    hl_eol = true,
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
