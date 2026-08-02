local M = {}

local fallbacks = {
  add = 0xa6e3a1,
  delete = 0xf38ba8,
  change = 0xf9e2af,
  header = 0xcba6f7,
  dim = 0x6c7086,
}

local function source_hl(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and hl then
    return hl
  end
  return {}
end

-- First non-nil fg across `names`, else `fallback`. The diff-oriented groups
-- (DiffAdd etc.) are frequently bg-only, so the float's status letters and
-- counts -- which are fg-only text -- source from Added/Removed/Changed first.
local function first_fg(names, fallback)
  for _, name in ipairs(names) do
    local hl = source_hl(name)
    if hl.fg then
      return hl.fg
    end
  end
  return fallback
end

-- First non-nil bg across `names`, else nil.
local function first_bg(names)
  for _, name in ipairs(names) do
    local hl = source_hl(name)
    if hl.bg then
      return hl.bg
    end
  end
  return nil
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

  -- Float mode. Status letters and counts are fg-only text in the sidebar, so
  -- they source from the fg-carrying groups first (see first_fg).
  local add_fg = first_fg({ "Added", "GitSignsAdd", "DiffAdd" }, fallbacks.add)
  local del_fg = first_fg({ "Removed", "GitSignsDelete", "DiffDelete" }, fallbacks.delete)
  local chg_fg = first_fg({ "Changed", "GitSignsChange", "DiffChange" }, fallbacks.change)
  local dim_fg = first_fg({ "Comment", "NonText" }, fallbacks.dim)

  groups.LazydiffStatusModified = { fg = chg_fg, default = true }
  groups.LazydiffStatusAdded = { fg = add_fg, default = true }
  groups.LazydiffStatusDeleted = { fg = del_fg, default = true }
  groups.LazydiffStatusRenamed = { fg = fn.fg or fallbacks.header, default = true }
  groups.LazydiffStatusUntracked = { fg = dim_fg, default = true }
  groups.LazydiffCountAdd = { fg = add_fg, default = true }
  groups.LazydiffCountDelete = { fg = del_fg, default = true }
  groups.LazydiffFloatPath = { fg = nm.fg, default = true }
  groups.LazydiffFloatDim = { fg = dim_fg, default = true }
  groups.LazydiffFloatTitle = { fg = fn.fg or fallbacks.header, bold = true, default = true }
  groups.LazydiffFloatSelected = {
    bg = first_bg({ "CursorLine", "Visual" }),
    bold = true,
    default = true,
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
