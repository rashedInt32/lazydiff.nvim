local M = {}

local function complete_refs(arglead)
  local git = require("lazydiff.git")
  local repo = git.repo_root(git.anchor_dir())
  if not repo then
    return {}
  end
  return vim.tbl_filter(function(ref)
    return ref:sub(1, #arglead) == arglead
  end, git.refs(repo))
end

local function ref_arg(cmd)
  local ref = vim.trim(cmd.args or "")
  return ref ~= "" and ref or nil
end

function M.setup()
  local function cmd(name, fn, opts)
    vim.api.nvim_create_user_command(name, fn, opts)
  end

  cmd("Lazydiff", function(c)
    require("lazydiff").toggle(nil, ref_arg(c))
  end, {
    nargs = "?",
    complete = complete_refs,
    desc = "Toggle lazydiff overlay on the current buffer (optionally against a ref)",
  })

  cmd("LazydiffOff", function()
    require("lazydiff").disable()
  end, { desc = "Disable lazydiff overlay on the current buffer" })

  cmd("LazydiffRefresh", function()
    require("lazydiff").refresh(nil, { baseline = true })
  end, { desc = "Refetch the baseline and re-render the lazydiff overlay" })

  cmd("LazydiffNext", function()
    require("lazydiff").goto_next()
  end, { desc = "Jump to the next lazydiff hunk" })

  cmd("LazydiffPrev", function()
    require("lazydiff").goto_prev()
  end, { desc = "Jump to the previous lazydiff hunk" })

  cmd("LazydiffFirst", function()
    require("lazydiff").goto_first()
  end, { desc = "Jump to the first lazydiff hunk" })

  cmd("LazydiffReset", function()
    require("lazydiff").reset_hunk()
  end, { desc = "Revert the hunk under the cursor to the baseline" })

  cmd("LazydiffYank", function(c)
    local reg = vim.trim(c.args or "")
    require("lazydiff").yank_hunk(nil, reg ~= "" and reg or nil)
  end, { nargs = "?", desc = "Yank the deleted lines of the hunk under the cursor" })

  cmd("LazydiffFloat", function(c)
    require("lazydiff").toggle_float({ ref = ref_arg(c) })
  end, {
    nargs = "?",
    complete = complete_refs,
    desc = "Toggle the lazydiff float over all uncommitted files (optionally against a ref)",
  })

  cmd("LazydiffFloatOff", function()
    require("lazydiff").close_float()
  end, { desc = "Close the lazydiff float" })
end

return M
