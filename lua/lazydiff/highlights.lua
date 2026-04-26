local M = {}

local fallbacks = {
  add = 0xa6e3a1,
  delete = 0xf38ba8,
  change = 0xf9e2af,
  header = 0xcba6f7,
}

local function source_hl(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and hl then
    return hl
  end
  return {}
end

local function apply()
  local da = source_hl("DiffAdd")
  local dd = source_hl("DiffDelete")
  local dc = source_hl("DiffChange")
  local fn = source_hl("Function")
  local nm = source_hl("Normal")

  -- LazydiffAdd / Change paint the in-buffer added line via hl_group + hl_eol;
  -- they're bg-only so they don't fight treesitter syntax fg.
  -- LazydiffDelete paints virtual deleted lines (no syntax to preserve), so it
  -- carries fg + bg.
  --
  -- Sign groups (+/- prefix) explicitly carry bg = Normal.bg so the prefix
  -- always sits on the buffer's natural background, regardless of how the
  -- surrounding line band is painted. Without this, some Neovim builds /
  -- colorschemes paint the line bg over the virt_text region too, swallowing
  -- the marker.
  local groups = {
    LazydiffAdd = { bg = da.bg, default = true },
    LazydiffChange = { bg = dc.bg, default = true },
    LazydiffDelete = { fg = dd.fg or fallbacks.delete, bg = dd.bg, default = true },
    LazydiffAddSign = { fg = da.fg or fallbacks.add, bg = nm.bg, bold = true, default = true },
    LazydiffDeleteSign = { fg = dd.fg or fallbacks.delete, bg = nm.bg, bold = true, default = true },
    LazydiffHunkHeader = { fg = fn.fg or fallbacks.header, default = true },
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
