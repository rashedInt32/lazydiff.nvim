if vim.g.loaded_lazydiff then
  return
end
vim.g.loaded_lazydiff = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("lazydiff.nvim requires Neovim 0.10 or newer", vim.log.levels.WARN)
  return
end

require("lazydiff.commands").setup()
