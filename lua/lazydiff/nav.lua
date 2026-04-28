local M = {}

local config = require("lazydiff.config")

local function notify(msg, level)
  vim.notify("lazydiff: " .. msg, level or vim.log.levels.INFO)
end

local function get_hunks(bufnr)
  return require("lazydiff.state").get_hunks(bufnr)
end

local function clamp_line(bufnr, line)
  local total = vim.api.nvim_buf_line_count(bufnr)
  if line < 1 then
    return 1
  end
  if line > total then
    return total
  end
  return line
end

-- 1-based buffer line where the cursor should land for a given hunk.
-- For add/change: the first new/changed line.
-- For pure deletes: new_start is the line BEFORE the deletion gap, so we
-- aim at the line after it (clamped to the buffer).
function M.target_line(hunk)
  if hunk.new_count > 0 then
    return hunk.new_start
  end
  return math.max(hunk.new_start, 1)
end

-- True when the cursor row sits anywhere inside `hunk`'s new-side range.
-- Used to skip the auto-jump when the user is already on the first hunk.
function M.cursor_in_hunk(bufnr, hunk, cursor_row)
  if hunk.new_count > 0 then
    local first = hunk.new_start
    local last = hunk.new_start + hunk.new_count - 1
    return cursor_row >= first and cursor_row <= last
  end
  -- Pure delete: treat the line above and below the gap as "in" the hunk so
  -- repeated `]h` doesn't snap back to the same place.
  local target = M.target_line(hunk)
  return cursor_row == target or cursor_row == math.max(target - 1, 1)
end

local function jump_to(bufnr, line)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end
  line = clamp_line(bufnr, line)
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  if config.options.nav and config.options.nav.center then
    vim.cmd("normal! zz")
  end
end

local function with_hunks(bufnr, fn)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local hunks = get_hunks(bufnr)
  if not hunks or #hunks == 0 then
    notify("no hunks to navigate", vim.log.levels.INFO)
    return
  end
  fn(bufnr, hunks)
end

function M.goto_first(bufnr)
  with_hunks(bufnr, function(b, hunks)
    jump_to(b, M.target_line(hunks[1]))
  end)
end

function M.goto_last(bufnr)
  with_hunks(bufnr, function(b, hunks)
    jump_to(b, M.target_line(hunks[#hunks]))
  end)
end

function M.goto_next(bufnr)
  with_hunks(bufnr, function(b, hunks)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    for _, h in ipairs(hunks) do
      if M.target_line(h) > row then
        jump_to(b, M.target_line(h))
        return
      end
    end
    if config.options.nav and config.options.nav.wrap then
      jump_to(b, M.target_line(hunks[1]))
    end
  end)
end

function M.goto_prev(bufnr)
  with_hunks(bufnr, function(b, hunks)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    for i = #hunks, 1, -1 do
      if M.target_line(hunks[i]) < row then
        jump_to(b, M.target_line(hunks[i]))
        return
      end
    end
    if config.options.nav and config.options.nav.wrap then
      jump_to(b, M.target_line(hunks[#hunks]))
    end
  end)
end

return M
