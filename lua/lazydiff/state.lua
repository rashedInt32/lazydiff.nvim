local M = {}

local config = require("lazydiff.config")
local git = require("lazydiff.git")
local diff = require("lazydiff.diff")
local render = require("lazydiff.render")
local highlights = require("lazydiff.highlights")

-- per-buffer state:
--   enabled, external, ref, repo, rel, git_dir, baseline (old lines), hunks,
--   saved_modifiable, signcolumn { win, value }, augroup, timer, watcher,
--   watch_timer
local buffers = {}

local function notify(msg, level)
  vim.notify("lazydiff: " .. msg, level or vim.log.levels.INFO)
end

-- Every Neovim API call takes 0 to mean "current buffer", so callers reasonably
-- pass it here too -- but 0 is truthy in Lua, so `bufnr or current()` keeps it
-- and the lookup lands on buffers[0], which is never populated. Normalize once.
local function resolve(bufnr)
  if not bufnr or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
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

-- Locate the buffer's file inside its repo. Returns { repo, rel } or nil + err.
local function locate(bufnr)
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
  return { repo = repo, rel = rel }
end

-- Fetch the reference blob. One git call: `git show` fails for untracked
-- paths, so the separate `cat-file -e` probe is unnecessary. Returns the
-- parsed old-lines array, or nil + an error string + a reason.
local function fetch_baseline(loc, ref)
  local blob, err, reason = git.head_blob(loc.repo, loc.rel, ref)
  if not blob then
    return nil, err or "failed to read blob", reason
  end
  if git.is_binary(blob) then
    return nil, "binary file", "binary"
  end
  return git.split_lines(blob)
end

local function recompute(bufnr, baseline)
  return diff.compute(baseline, buf_lines(bufnr))
end

local function close_timer(timer)
  if timer then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
  end
end

local function stop_timer(state)
  close_timer(state.timer)
  state.timer = nil
end

local function stop_watcher(state)
  close_timer(state.watch_timer)
  state.watch_timer = nil
  if state.watcher then
    pcall(state.watcher.stop, state.watcher)
    pcall(state.watcher.close, state.watcher)
    state.watcher = nil
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

-- Watch the git directory so a commit, checkout or reset made behind the
-- editor's back refetches the baseline. HEAD and the index are written via
-- rename, so the directory (not the files) is what's observed.
local WATCHED = { HEAD = true, index = true, ORIG_HEAD = true, ["packed-refs"] = true }

local function start_watcher(bufnr, state)
  stop_watcher(state)
  if not config.options.watch_git or not state.git_dir then
    return
  end
  local ok, watcher = pcall(vim.uv.new_fs_event)
  if not ok or not watcher then
    return
  end
  state.watcher = watcher
  local started = pcall(watcher.start, watcher, state.git_dir, {}, function(err, fname)
    if err or (fname and not WATCHED[fname]) then
      return
    end
    close_timer(state.watch_timer)
    state.watch_timer = vim.uv.new_timer()
    state.watch_timer:start(
      200,
      0,
      vim.schedule_wrap(function()
        close_timer(state.watch_timer)
        state.watch_timer = nil
        M.refresh(bufnr, { baseline = true })
      end)
    )
  end)
  if not started then
    stop_watcher(state)
  end
end

local function setup_autocmds(bufnr, state)
  teardown_autocmds(state)
  local group = vim.api.nvim_create_augroup("LazydiffBuf" .. bufnr, { clear = true })
  state.augroup = group

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.disable(bufnr)
    end,
  })

  if not config.options.auto_refresh then
    return
  end

  -- A save or an external reload is also when the baseline is most likely
  -- to have moved (commit from a terminal, then :w), so refetch it here.
  vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost", "BufReadPost" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.refresh(bufnr, { baseline = true })
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
end

-- The + markers live in the sign column; with signcolumn=no they are simply
-- invisible. Turn it on for the window showing the buffer and remember what
-- to put back.
local function apply_signcolumn(bufnr, state)
  if not config.options.force_signcolumn or state.signcolumn then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end
  local value = vim.wo[win].signcolumn
  if value == "no" then
    state.signcolumn = { win = win, value = value }
    vim.wo[win].signcolumn = "yes:1"
  end
end

local function restore_signcolumn(state)
  local saved = state.signcolumn
  state.signcolumn = nil
  if saved and vim.api.nvim_win_is_valid(saved.win) and vim.wo[saved.win].signcolumn == "yes:1" then
    vim.wo[saved.win].signcolumn = saved.value
  end
end

function M.is_enabled(bufnr)
  local s = buffers[resolve(bufnr)]
  return s ~= nil and s.enabled == true
end

function M.enable(bufnr, ref)
  highlights.setup()
  bufnr = resolve(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  ref = ref or config.options.ref

  local loc, err = locate(bufnr)
  if not loc then
    notify(err, vim.log.levels.WARN)
    return false
  end

  local baseline, berr, reason = fetch_baseline(loc, ref)
  if not baseline then
    notify(berr, vim.log.levels.WARN)
    return false
  end

  local hunks = recompute(bufnr, baseline)

  local state = buffers[bufnr] or {}
  if not state.enabled then
    state.saved_modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr })
  end
  state.enabled = true
  state.external = nil
  state.ref = ref
  state.repo = loc.repo
  state.rel = loc.rel
  state.git_dir = state.git_dir or git.git_dir(loc.repo)
  state.baseline = baseline
  state.hunks = hunks
  buffers[bufnr] = state

  render.render(bufnr, hunks)

  if config.options.read_only then
    vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  end

  apply_signcolumn(bufnr, state)
  setup_autocmds(bufnr, state)
  start_watcher(bufnr, state)

  if #hunks == 0 then
    -- Stay enabled: the overlay appears as soon as the buffer diverges.
    notify("no changes against " .. ref .. " yet; overlay is on", vim.log.levels.INFO)
  elseif config.options.jump_on_enable then
    local nav = require("lazydiff.nav")
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if not nav.cursor_in_hunk(hunks[1], row) then
      nav.goto_first(bufnr)
    end
  end
  return true, reason
end

function M.disable(bufnr)
  bufnr = resolve(bufnr)
  local state = buffers[bufnr]
  if not state then
    return
  end

  stop_timer(state)
  stop_watcher(state)

  if vim.api.nvim_buf_is_valid(bufnr) then
    render.clear(bufnr)
    if config.options.read_only and state.saved_modifiable ~= nil then
      vim.api.nvim_set_option_value("modifiable", state.saved_modifiable, { buf = bufnr })
    end
  end
  restore_signcolumn(state)

  teardown_autocmds(state)
  buffers[bufnr] = nil
end

-- Without `ref`: plain on/off. With `ref`: turn on against that ref, or
-- switch to it if already on against a different one.
function M.toggle(bufnr, ref)
  bufnr = resolve(bufnr)
  local state = buffers[bufnr]
  if state and state.enabled and (ref == nil or ref == state.ref) then
    M.disable(bufnr)
  else
    M.enable(bufnr, ref)
  end
end

-- opts.baseline = true refetches the blob from git before recomputing, which
-- is what makes a commit or checkout under a live overlay show up.
function M.refresh(bufnr, opts)
  bufnr = resolve(bufnr)
  opts = opts or {}
  local state = buffers[bufnr]
  if not state or not state.enabled then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    M.disable(bufnr)
    return
  end

  if opts.baseline and not state.external then
    local loc = locate(bufnr)
    if loc then
      local baseline, _, reason = fetch_baseline(loc, state.ref)
      if baseline then
        state.baseline = baseline
      elseif reason == "untracked" then
        -- The file vanished from `ref` (e.g. checkout of an older branch):
        -- everything in the buffer is now new.
        state.baseline = {}
      end
      -- Any other failure keeps the last known baseline.
    end
  end

  local hunks = recompute(bufnr, state.baseline)
  state.hunks = hunks
  render.render(bufnr, hunks)
end

-- Register hunks computed elsewhere (the float's scratch pane) so nav.lua can
-- navigate the buffer. Deliberately skips what enable() does around it: no
-- autocmds and no timers, because the float refreshes manually, and no
-- baseline fetch, because locate() derives the blob from the buffer's
-- filename and a scratch buffer has none. (Naming the scratch buffer after
-- the real file isn't an option -- duplicate buffer names raise E95.)
function M.attach(bufnr, opts)
  bufnr = resolve(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  highlights.setup()
  buffers[bufnr] = {
    enabled = true,
    external = true,
    ref = opts.ref,
    baseline = opts.baseline,
    hunks = opts.hunks,
  }
end

function M.get_hunks(bufnr)
  bufnr = resolve(bufnr)
  local state = buffers[bufnr]
  if not state or not state.enabled then
    return nil
  end
  return state.hunks
end

-- Hunk under the cursor of the current window, when it shows `bufnr`.
local function hunk_under_cursor(bufnr)
  local state = buffers[bufnr]
  if not state or not state.enabled then
    return nil, "overlay is not enabled"
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return nil, "buffer is not in the current window"
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local index, hunk = require("lazydiff.nav").hunk_at(state.hunks, row)
  if not hunk then
    return nil, "no hunk under cursor"
  end
  return hunk, nil, index, state
end

-- Put the baseline's lines back in place of the hunk under the cursor: the
-- "reject this change" action when reviewing a patch.
function M.reset_hunk(bufnr)
  bufnr = resolve(bufnr)
  local hunk, err, _, state = hunk_under_cursor(bufnr)
  if not hunk then
    notify(err, vim.log.levels.WARN)
    return false
  end
  if state.external then
    notify("review pane is read-only; open the file with <CR> to edit", vim.log.levels.WARN)
    return false
  end

  -- 0-based, end-exclusive range of the new-side lines. A pure delete has
  -- no new lines; its old lines are inserted after line new_start.
  local first = hunk.new_count > 0 and hunk.new_start - 1 or hunk.new_start
  local last = first + hunk.new_count

  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, first, last, false, hunk.old_lines)
  vim.bo[bufnr].modifiable = was_modifiable

  M.refresh(bufnr)
  return true
end

-- Yank the hunk's deleted lines (the red virtual lines, which `y` can't
-- reach) into `register`, linewise. Defaults to the unnamed register.
function M.yank_hunk(bufnr, register)
  bufnr = resolve(bufnr)
  local hunk, err = hunk_under_cursor(bufnr)
  if not hunk then
    notify(err, vim.log.levels.WARN)
    return false
  end
  if #hunk.old_lines == 0 then
    notify("hunk has no deleted lines to yank", vim.log.levels.INFO)
    return false
  end
  register = register or '"'
  vim.fn.setreg(register, hunk.old_lines, "l")
  notify(("yanked %d deleted line%s"):format(#hunk.old_lines, #hunk.old_lines == 1 and "" or "s"))
  return true
end

-- For statuslines: { ref, hunks = n, current = i or nil } or nil when off.
function M.status(bufnr)
  bufnr = resolve(bufnr)
  local state = buffers[bufnr]
  if not state or not state.enabled then
    return nil
  end
  local current
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local row = vim.api.nvim_win_get_cursor(win)[1]
    current = require("lazydiff.nav").hunk_at(state.hunks, row)
    if current then
      break
    end
  end
  return { ref = state.ref, hunks = #state.hunks, current = current }
end

function M.statusline(bufnr)
  local s = M.status(bufnr)
  if not s then
    return ""
  end
  if s.hunks == 0 then
    return "lazydiff: no changes"
  end
  if s.current then
    return ("lazydiff: hunk %d/%d"):format(s.current, s.hunks)
  end
  return ("lazydiff: %d hunk%s"):format(s.hunks, s.hunks == 1 and "" or "s")
end

return M
