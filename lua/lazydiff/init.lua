local M = {}

function M.setup(opts)
  require("lazydiff.config").setup(opts)
  require("lazydiff.highlights").setup()
end

local function state()
  return require("lazydiff.state")
end

-- All bufnr arguments default to the current buffer (nil or 0).

function M.toggle(bufnr, ref)
  return state().toggle(bufnr, ref)
end

function M.enable(bufnr, ref)
  return state().enable(bufnr, ref)
end

function M.disable(bufnr)
  return state().disable(bufnr)
end

-- opts.baseline = true refetches the blob from git first.
function M.refresh(bufnr, opts)
  return state().refresh(bufnr, opts)
end

function M.is_enabled(bufnr)
  return state().is_enabled(bufnr)
end

function M.reset_hunk(bufnr)
  return state().reset_hunk(bufnr)
end

function M.yank_hunk(bufnr, register)
  return state().yank_hunk(bufnr, register)
end

function M.status(bufnr)
  return state().status(bufnr)
end

function M.statusline(bufnr)
  return state().statusline(bufnr)
end

function M.goto_first(bufnr)
  return require("lazydiff.nav").goto_first(bufnr or vim.api.nvim_get_current_buf())
end

function M.goto_next(bufnr)
  return require("lazydiff.nav").goto_next(bufnr or vim.api.nvim_get_current_buf())
end

function M.goto_prev(bufnr)
  return require("lazydiff.nav").goto_prev(bufnr or vim.api.nvim_get_current_buf())
end

function M.open_float(opts)
  return require("lazydiff.float").open(opts)
end

function M.close_float()
  return require("lazydiff.float").close()
end

function M.toggle_float(opts)
  return require("lazydiff.float").toggle(opts)
end

return M
