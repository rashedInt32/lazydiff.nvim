local M = {}

M.defaults = {
  ref = "HEAD",
  signs = {
    add = "+",        -- rendered in the sign column (max 2 cells)
    delete = "- ",    -- prefix on virt_lines for deleted content
    context = "  ",
  },
  show_hunk_header = true,
  read_only = false,
  auto_refresh = true,
  live_refresh = true,
  debounce_ms = 100,
  jump_on_enable = true,
  nav = {
    wrap = true,
    center = true,
  },
  -- Float mode: a lazygit-style popup listing every uncommitted file, with the
  -- selected one rendered full-length using the same overlay as inline mode.
  float = {
    width = 0.9,          -- fraction of the editor (>1 = absolute columns)
    height = 0.9,         -- fraction of the editor (>1 = absolute lines)
    sidebar = 0.3,        -- fraction of the float's width (>1 = absolute columns)
    border = "rounded",
    title = " lazydiff ",
    number = true,        -- line numbers in the review pane
    keys = {
      close = { "q", "<Esc>" },
      refresh = "R",
      open_file = "<CR>",
      next_hunk = "]h",
      prev_hunk = "[h",
      focus_list = "<C-h>",
      focus_pane = "<C-l>",
    },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
