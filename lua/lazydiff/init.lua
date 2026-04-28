local M = {}

function M.setup(opts)
  require("lazydiff.config").setup(opts)
  require("lazydiff.highlights").setup()
end

function M.toggle(bufnr)
  return require("lazydiff.state").toggle(bufnr or vim.api.nvim_get_current_buf())
end

function M.enable(bufnr)
  return require("lazydiff.state").enable(bufnr or vim.api.nvim_get_current_buf())
end

function M.disable(bufnr)
  return require("lazydiff.state").disable(bufnr or vim.api.nvim_get_current_buf())
end

function M.refresh(bufnr)
  return require("lazydiff.state").refresh(bufnr or vim.api.nvim_get_current_buf())
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

return M
