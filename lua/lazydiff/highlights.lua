local M = {}

local fallbacks = {
  add = 0xa6e3a1,
  delete = 0xf38ba8,
  change = 0xf9e2af,
  header = 0xcba6f7,
}

local function fg_of(name, fallback)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and hl and hl.fg then
    return hl.fg
  end
  return fallback
end

local function apply()
  local add = fg_of("DiffAdd", fallbacks.add)
  local del = fg_of("DiffDelete", fallbacks.delete)
  local chg = fg_of("DiffChange", fallbacks.change)
  local hdr = fg_of("Function", fallbacks.header)

  local groups = {
    LazydiffAdd = { fg = add, bg = "NONE", default = true },
    LazydiffDelete = { fg = del, bg = "NONE", default = true },
    LazydiffChange = { fg = chg, bg = "NONE", default = true },
    LazydiffAddSign = { fg = add, bg = "NONE", bold = true, default = true },
    LazydiffDeleteSign = { fg = del, bg = "NONE", bold = true, default = true },
    LazydiffHunkHeader = { fg = hdr, bg = "NONE", default = true },
  }

  for name, spec in pairs(groups) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

function M.setup()
  apply()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("LazydiffHighlights", { clear = true }),
    callback = apply,
  })
end

return M
