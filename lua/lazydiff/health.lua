local M = {}

function M.check()
  vim.health.start("lazydiff")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.10 or newer is required (vim.system, vim.diff indices)")
  end

  if vim.fn.executable("git") == 1 then
    local out = vim.fn.systemlist({ "git", "--version" })
    vim.health.ok(out[1] or "git found on $PATH")
  else
    vim.health.error("git not found on $PATH")
  end

  local ok, err = pcall(function()
    require("lazydiff.config").setup(require("lazydiff.config").options)
  end)
  if ok then
    vim.health.ok("configuration is valid")
  else
    vim.health.error("configuration error: " .. tostring(err))
  end
end

return M
