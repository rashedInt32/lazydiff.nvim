local M = {}

local groups = {
  LazydiffAdd = { link = "DiffAdd", default = true },
  LazydiffDelete = { link = "DiffDelete", default = true },
  LazydiffChange = { link = "DiffChange", default = true },
  LazydiffAddSign = { link = "LazydiffAdd", default = true },
  LazydiffDeleteSign = { link = "LazydiffDelete", default = true },
  LazydiffHunkHeader = { link = "Function", default = true },
}

function M.setup()
  for name, spec in pairs(groups) do
    vim.api.nvim_set_hl(0, name, spec)
  end

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("LazydiffHighlights", { clear = true }),
    callback = function()
      for name, spec in pairs(groups) do
        vim.api.nvim_set_hl(0, name, spec)
      end
    end,
  })
end

return M
