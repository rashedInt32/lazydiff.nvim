local M = {}

M.defaults = {
  ref = "HEAD",
  signs = {
    add = "+", -- rendered in the sign column (max 2 cells)
    delete = "- ", -- prefix on virt_lines for deleted content
  },
  show_hunk_header = true,
  word_diff = true, -- highlight the changed words inside change hunks
  read_only = false,
  auto_refresh = true,
  live_refresh = true,
  debounce_ms = 100,
  watch_git = true, -- refetch the baseline when HEAD or the index change
  force_signcolumn = true, -- turn the sign column on while the overlay is active
  jump_on_enable = true,
  nav = {
    wrap = true,
    center = true,
  },
  -- Float mode: a lazygit-style popup listing every uncommitted file, with the
  -- selected one rendered full-length using the same overlay as inline mode.
  float = {
    width = 0.9, -- fraction of the editor (>1 = absolute columns)
    height = 0.9, -- fraction of the editor (>1 = absolute lines)
    sidebar = 0.3, -- fraction of the float's width (>1 = absolute columns)
    border = "rounded",
    title = " lazydiff ",
    number = true, -- line numbers in the review pane
    select_debounce_ms = 40, -- wait for the cursor to settle before rendering a file
    fold_context = false, -- start with unchanged regions folded
    context_lines = 3, -- lines kept visible around each hunk when folded
    keys = {
      close = { "q", "<Esc>" },
      refresh = "R",
      open_file = "<CR>",
      next_hunk = "]h",
      prev_hunk = "[h",
      next_file = "]f",
      prev_file = "[f",
      toggle_fold = "<Tab>",
      focus_list = "<C-h>",
      focus_pane = "<C-l>",
    },
  },
}

M.options = vim.deepcopy(M.defaults)

local function check(path, value, expected)
  if value == nil then
    return
  end
  local actual = type(value)
  if actual ~= expected then
    error(("lazydiff: option `%s` must be a %s, got %s"):format(path, expected, actual), 3)
  end
end

local function validate(opts)
  check("ref", opts.ref, "string")
  check("signs", opts.signs, "table")
  check("show_hunk_header", opts.show_hunk_header, "boolean")
  check("word_diff", opts.word_diff, "boolean")
  check("read_only", opts.read_only, "boolean")
  check("auto_refresh", opts.auto_refresh, "boolean")
  check("live_refresh", opts.live_refresh, "boolean")
  check("debounce_ms", opts.debounce_ms, "number")
  check("watch_git", opts.watch_git, "boolean")
  check("force_signcolumn", opts.force_signcolumn, "boolean")
  check("jump_on_enable", opts.jump_on_enable, "boolean")
  check("nav", opts.nav, "table")
  check("float", opts.float, "table")
  if type(opts.float) == "table" then
    check("float.width", opts.float.width, "number")
    check("float.height", opts.float.height, "number")
    check("float.sidebar", opts.float.sidebar, "number")
    check("float.number", opts.float.number, "boolean")
    check("float.select_debounce_ms", opts.float.select_debounce_ms, "number")
    check("float.fold_context", opts.float.fold_context, "boolean")
    check("float.context_lines", opts.float.context_lines, "number")
    check("float.keys", opts.float.keys, "table")
  end
end

function M.setup(opts)
  opts = opts or {}
  check("opts", opts, "table")
  validate(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
end

return M
