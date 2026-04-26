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
end

return M
