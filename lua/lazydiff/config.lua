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
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
