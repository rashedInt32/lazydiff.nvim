local M = {}

function M.setup()
  vim.api.nvim_create_user_command("Lazydiff", function()
    require("lazydiff").toggle()
  end, { desc = "Toggle lazydiff overlay on the current buffer" })

  vim.api.nvim_create_user_command("LazydiffOff", function()
    require("lazydiff").disable()
  end, { desc = "Disable lazydiff overlay on the current buffer" })

  vim.api.nvim_create_user_command("LazydiffRefresh", function()
    require("lazydiff").refresh()
  end, { desc = "Refresh lazydiff overlay on the current buffer" })

  vim.api.nvim_create_user_command("LazydiffNext", function()
    require("lazydiff").goto_next()
  end, { desc = "Jump to the next lazydiff hunk" })

  vim.api.nvim_create_user_command("LazydiffPrev", function()
    require("lazydiff").goto_prev()
  end, { desc = "Jump to the previous lazydiff hunk" })

  vim.api.nvim_create_user_command("LazydiffFirst", function()
    require("lazydiff").goto_first()
  end, { desc = "Jump to the first lazydiff hunk" })
end

return M
