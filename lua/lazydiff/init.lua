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

return M
