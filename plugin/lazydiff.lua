if vim.g.loaded_lazydiff then
  return
end
vim.g.loaded_lazydiff = true

require("lazydiff.commands").setup()
