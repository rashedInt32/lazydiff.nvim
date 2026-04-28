local M = {}

local config = require("lazydiff.config")
local git = require("lazydiff.git")
local diff = require("lazydiff.diff")
local render = require("lazydiff.render")
local highlights = require("lazydiff.highlights")

local highlights_ready = false
local function ensure_highlights()
  if not highlights_ready then
    highlights.setup()
    highlights_ready = true
  end
end

-- per-buffer state:
--   enabled, saved_modifiable, augroup, ref, baseline (old lines), timer
local buffers = {}

local function notify(msg, level)
  vim.notify("lazydiff: " .. msg, level or vim.log.levels.INFO)
end

local function buf_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return vim.fn.fnamemodify(name, ":p")
end

local function buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- Fetch the reference blob once per overlay session. Returns the parsed
-- old-lines array (cached on per-buffer state) or nil + an error string.
local function prepare_baseline(bufnr, ref)
  local path = buf_path(bufnr)
  if not path then
    return nil, "buffer has no file"
  end

  local repo = git.repo_root(path)
  if not repo then
    return nil, "not in a git repository"
  end

  local rel = git.relpath(repo, path)
  if not rel then
    return nil, "file is outside the repo root"
  end

  if not git.is_tracked(repo, rel, ref) then
    return nil, "file is not tracked at " .. ref
  end

  local blob, err = git.head_blob(repo, rel, ref)
  if not blob then
    return nil, err or "failed to read blob"
  end

  if git.is_binary(blob) then
    return nil, "binary file"
  end

  return git.split_lines(blob)
end

local function recompute(bufnr, baseline)
  return diff.compute(baseline, buf_lines(bufnr))
end

local function stop_timer(state)
  if state.timer then
    pcall(state.timer.stop, state.timer)
    pcall(state.timer.close, state.timer)
    state.timer = nil
  end
end

local function teardown_autocmds(state)
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
end

local function debounced_refresh(bufnr, state)
  if not config.options.live_refresh then
    return
  end
  stop_timer(state)
  state.timer = vim.uv.new_timer()
  local ms = config.options.debounce_ms or 100
  state.timer:start(
    ms,
    0,
    vim.schedule_wrap(function()
      stop_timer(state)
      M.refresh(bufnr)
    end)
  )
end

local function setup_autocmds(bufnr, state)
  teardown_autocmds(state)
  if not config.options.auto_refresh then
    return
  end
  local group = vim.api.nvim_create_augroup("LazydiffBuf" .. bufnr, { clear = true })
  state.augroup = group

  vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.refresh(bufnr)
    end,
  })

  if config.options.live_refresh then
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = group,
      buffer = bufnr,
      callback = function()
        debounced_refresh(bufnr, state)
      end,
    })
  end

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.disable(bufnr)
    end,
  })
end

function M.is_enabled(bufnr)
  local s = buffers[bufnr]
  return s ~= nil and s.enabled == true
end

function M.enable(bufnr, ref)
  ensure_highlights()
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  ref = ref or config.options.ref

  local baseline, err = prepare_baseline(bufnr, ref)
  if not baseline then
    notify(err or "no diff available", vim.log.levels.WARN)
    return
  end

  local hunks = recompute(bufnr, baseline)
  if #hunks == 0 then
    notify("no changes against " .. ref, vim.log.levels.INFO)
    return
  end

  local state = buffers[bufnr] or {}
  if not state.enabled then
    state.saved_modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr })
  end
  state.enabled = true
  state.ref = ref
  state.baseline = baseline
  state.hunks = hunks
  buffers[bufnr] = state

  render.render(bufnr, hunks)

  if config.options.read_only then
    vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  end

  setup_autocmds(bufnr, state)

  if config.options.jump_on_enable then
    local nav = require("lazydiff.nav")
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if not nav.cursor_in_hunk(bufnr, hunks[1], row) then
      nav.goto_first(bufnr)
    end
  end
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  if not state then
    return
  end

  stop_timer(state)

  if vim.api.nvim_buf_is_valid(bufnr) then
    render.clear(bufnr)
    if config.options.read_only and state.saved_modifiable ~= nil then
      vim.api.nvim_set_option_value("modifiable", state.saved_modifiable, { buf = bufnr })
    end
  end

  teardown_autocmds(state)
  buffers[bufnr] = nil
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.is_enabled(bufnr) then
    M.disable(bufnr)
  else
    M.enable(bufnr)
  end
end

function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  if not state or not state.enabled then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    M.disable(bufnr)
    return
  end

  local hunks = recompute(bufnr, state.baseline)
  state.hunks = hunks
  render.render(bufnr, hunks)
end

function M.get_hunks(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = buffers[bufnr]
  if not state or not state.enabled then
    return nil
  end
  return state.hunks
end

return M
