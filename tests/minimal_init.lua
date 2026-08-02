-- Minimal init for the test suite: the plugin and nothing else.
-- Repo root is derived from this file's own location so the suite runs from
-- any working directory.
local here = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(here, ":p:h:h")

vim.opt.rtp:prepend(root)
vim.g.lazydiff_test_root = root

require("lazydiff").setup({})
require("lazydiff.commands").setup()
