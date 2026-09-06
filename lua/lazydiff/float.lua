-- Float mode: a lazygit-style popup listing every uncommitted file, with the
-- selected one rendered full-length using the same overlay as inline mode.
--
-- The rendering pipeline is entirely reused -- git.head_blob for the baseline,
-- diff.compute for the hunks, render.render for the extmarks. This module only
-- owns the window shell, the file list, and the selection.

local M = {}

local config = require("lazydiff.config")
local git = require("lazydiff.git")
local diff = require("lazydiff.diff")
local render = require("lazydiff.render")

local NS = vim.api.nvim_create_namespace("lazydiff_float")

-- Only one float exists at a time, so its state lives here rather than in
-- state.lua's per-buffer table.
local S = nil

local STATUS_HL = {
  M = "LazydiffStatusModified",
  A = "LazydiffStatusAdded",
  D = "LazydiffStatusDeleted",
  R = "LazydiffStatusRenamed",
  C = "LazydiffStatusRenamed",
  ["?"] = "LazydiffStatusUntracked",
}

local function notify(msg, level)
  vim.notify("lazydiff: " .. msg, level or vim.log.levels.INFO)
end

-- ---------------------------------------------------------------- geometry --

-- A value <= 1 is a fraction of `total`; anything larger is an absolute count.
local function resolve(value, total)
  if value <= 1 then
    return math.floor(total * value)
  end
  return math.floor(value)
end

-- Rows at the bottom of the editor that aren't ours to cover: the cmdline,
-- plus one for the global statusline when laststatus = 3. Everything above
-- that is available, so height = 1.0 fills the editor area exactly instead of
-- leaving an arbitrary margin.
local function reserved_rows()
  local n = vim.o.cmdheight
  if vim.o.laststatus == 3 then
    n = n + 1
  end
  return math.max(n, 1)
end

local function geometry()
  local cfg = config.options.float
  local ew, eh = vim.o.columns, vim.o.lines
  local avail_h = math.max(eh - reserved_rows(), 8)

  local width = math.min(math.max(resolve(cfg.width, ew), 40), math.max(ew - 2, 20))
  local height = math.min(math.max(resolve(cfg.height, eh), 10), avail_h)

  -- Each bordered window costs 2 columns and 2 lines beyond its content size,
  -- and two of them sit side by side inside the overall footprint.
  local inner_w = width - 4
  local inner_h = height - 2

  local list_w = resolve(cfg.sidebar, inner_w)
  list_w = math.min(math.max(list_w, 16), math.max(inner_w - 20, 16))
  local pane_w = math.max(inner_w - list_w, 10)

  -- Centred in the editor area, not the whole terminal, so the statusline
  -- doesn't push the float visually low.
  local top = math.max(math.floor((avail_h - height) / 2), 0)
  local left = math.max(math.floor((ew - width) / 2), 0)

  -- nvim_open_win's row/col place the window's *border* top-left, not its
  -- content, so no extra offset is added here. The two panes sit flush: the
  -- sidebar's footprint is list_w + 2 columns (content plus both borders),
  -- and the review pane starts immediately after it.
  return {
    list = { row = top, col = left, width = list_w, height = inner_h },
    pane = { row = top, col = left + list_w + 2, width = pane_w, height = inner_h },
  }
end

-- nvim_win_set_config rejects a partial table on a floating window, so both
-- open and retitle go through the same full config.
local function win_opts(rect, title)
  local cfg = config.options.float
  return {
    relative = "editor",
    row = rect.row,
    col = rect.col,
    width = rect.width,
    height = rect.height,
    style = "minimal",
    border = cfg.border,
    title = title,
    title_pos = "left",
    zindex = 50,
  }
end

-- ------------------------------------------------------------- file access --

-- Prefer a loaded buffer over the file on disk: if there are unsaved changes,
-- that is what the user expects to be reviewing.
local function loaded_buf_for(abspath)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == abspath then
      return buf
    end
  end
  return nil
end

local function file_lines(abspath)
  local buf = loaded_buf_for(abspath)
  if buf then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  local ok, lines = pcall(vim.fn.readfile, abspath)
  if ok and type(lines) == "table" then
    return lines
  end
  -- Deleted files land here: no content, so the whole file renders as a
  -- deletion against the baseline.
  return {}
end

-- Baselines are cached per path for the life of the float; R clears them.
local function baseline_for(entry)
  local key = entry.old_path or entry.path
  local cached = S.baselines[key]
  if cached then
    return cached
  end
  local lines = {}
  if not entry.untracked then
    local blob = git.head_blob(S.repo, key, S.ref)
    lines = blob and git.split_lines(blob) or {}
  end
  S.baselines[key] = lines
  return lines
end

-- SEAM: the only place that decides which buffer the review pane displays.
-- v1 returns a throwaway scratch buffer, which is what makes the pane
-- read-only. To make it editable later, return the real file's bufnr here --
-- nothing else in this module needs to change.
local function pane_buf(abspath, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  -- Setting filetype fires FileType, which is what attaches treesitter, so the
  -- pane gets real syntax highlighting instead of plain text.
  local ft = vim.filetype.match({ filename = abspath })
  if ft then
    vim.bo[buf].filetype = ft
  end
  return buf
end

-- ------------------------------------------------------------------ folds --

-- 1-based inclusive line ranges of at least two lines that no hunk (plus
-- `context` lines either side) touches.
function M.unchanged_regions(hunks, total, context)
  local keep = {}
  for _, h in ipairs(hunks) do
    local s, e
    if h.new_count > 0 then
      s, e = h.new_start, h.new_start + h.new_count - 1
    else
      -- A pure delete sits between new_start and new_start + 1; keep both.
      s, e = math.max(h.new_start, 1), h.new_start + 1
    end
    keep[#keep + 1] = { math.max(s - context, 1), math.min(e + context, total) }
  end
  table.sort(keep, function(a, b)
    return a[1] < b[1]
  end)

  local folds, pos = {}, 1
  for _, k in ipairs(keep) do
    if k[1] - pos >= 2 then
      folds[#folds + 1] = { pos, k[1] - 1 }
    end
    pos = math.max(pos, k[2] + 1)
  end
  if total - pos >= 1 then
    folds[#folds + 1] = { pos, total }
  end
  return folds
end

function M.foldtext()
  local n = vim.v.foldend - vim.v.foldstart + 1
  return ("··· %d unchanged line%s ···"):format(n, n == 1 and "" or "s")
end

local function apply_folds(win, buf, hunks)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.wo[win].foldmethod = "manual"
  vim.wo[win].foldtext = "v:lua.require'lazydiff.float'.foldtext()"
  vim.wo[win].fillchars = "fold: "
  vim.wo[win].foldenable = S.folded
  if not S.folded then
    return
  end
  local total = vim.api.nvim_buf_line_count(buf)
  local folds = M.unchanged_regions(hunks, total, config.options.float.context_lines or 3)
  vim.api.nvim_win_call(win, function()
    vim.cmd("silent! normal! zE")
    for _, f in ipairs(folds) do
      vim.cmd(("silent! %d,%dfold"):format(f[1], f[2]))
    end
    vim.cmd("silent! normal! zM")
  end)
end

-- ---------------------------------------------------------------- sidebar --

-- Trim from the left so the filename -- the part that identifies the row --
-- always survives.
local function fit_path(path, budget)
  if budget <= 1 then
    return ""
  end
  if vim.fn.strdisplaywidth(path) <= budget then
    return path
  end
  local chars = vim.fn.strchars(path)
  for keep = math.min(chars, budget - 1), 1, -1 do
    local tail = vim.fn.strcharpart(path, chars - keep)
    if vim.fn.strdisplaywidth(tail) <= budget - 1 then
      return "…" .. tail
    end
  end
  return "…"
end

local function build_row(entry, width)
  local letter = (entry.status or "M"):sub(1, 1)
  local prefix = " " .. letter .. " "
  local adds = entry.binary and "" or ("+" .. entry.added)
  local dels = entry.binary and "" or ("-" .. entry.deleted)
  local counts = entry.binary and "binary" or (adds .. " " .. dels)

  local budget = width - #prefix - vim.fn.strdisplaywidth(counts) - 2
  local path = fit_path(entry.path, budget)

  local used = #prefix + vim.fn.strdisplaywidth(path) + vim.fn.strdisplaywidth(counts)
  local gap = math.max(width - used - 1, 1)
  local line = prefix .. path .. string.rep(" ", gap) .. counts

  local counts_start = #line - #counts
  return line,
    {
      status = { 1, 2 },
      path = { #prefix, #prefix + #path },
      binary = entry.binary and { counts_start, #line } or nil,
      adds = (not entry.binary) and { counts_start, counts_start + #adds } or nil,
      dels = (not entry.binary) and { counts_start + #adds + 1, #line } or nil,
    }
end

local function render_list()
  local width = S.geo.list.width
  local lines, segs = {}, {}
  for _, entry in ipairs(S.files) do
    local line, seg = build_row(entry, width)
    lines[#lines + 1] = line
    segs[#segs + 1] = seg
  end

  vim.bo[S.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.list_buf, 0, -1, false, lines)
  vim.bo[S.list_buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(S.list_buf, NS, 0, -1)
  for i, seg in ipairs(segs) do
    local row = i - 1
    local function mark(range, hl)
      if not range or range[1] >= range[2] then
        return
      end
      pcall(vim.api.nvim_buf_set_extmark, S.list_buf, NS, row, range[1], {
        end_col = range[2],
        hl_group = hl,
      })
    end
    mark(seg.status, STATUS_HL[S.files[i].status] or "LazydiffStatusModified")
    mark(seg.path, "LazydiffFloatPath")
    mark(seg.binary, "LazydiffFloatDim")
    mark(seg.adds, "LazydiffCountAdd")
    mark(seg.dels, "LazydiffCountDelete")
  end
end

local function list_title()
  local n = #S.files
  local ref = S.ref ~= config.defaults.ref and (" vs " .. S.ref) or ""
  return string.format(
    "%s· %d file%s%s ",
    config.options.float.title,
    n,
    n == 1 and "" or "s",
    ref
  )
end

-- ---------------------------------------------------------------- keymaps --

local function map(buf, lhs, fn, desc)
  if type(lhs) == "table" then
    for _, key in ipairs(lhs) do
      map(buf, key, fn, desc)
    end
    return
  end
  if not lhs or lhs == "" then
    return
  end
  vim.keymap.set("n", lhs, fn, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = "lazydiff: " .. desc,
  })
end

local function open_file()
  if not S then
    return
  end
  local entry = S.files[S.index]
  if not entry then
    return
  end
  local abspath = S.repo .. "/" .. entry.path
  local ref = S.ref
  local line = 1
  if S.pane_win and vim.api.nvim_win_is_valid(S.pane_win) then
    line = vim.api.nvim_win_get_cursor(S.pane_win)[1]
  end

  M.close()

  if vim.fn.filereadable(abspath) == 0 then
    notify(entry.path .. " does not exist on disk", vim.log.levels.WARN)
    return
  end
  vim.cmd.edit(vim.fn.fnameescape(abspath))
  pcall(vim.api.nvim_win_set_cursor, 0, {
    math.min(line, vim.api.nvim_buf_line_count(0)),
    0,
  })
  require("lazydiff.state").enable(0, ref)
end

local function focus_win(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
end

local select_file

local function step_file(delta)
  if not S or #S.files == 0 then
    return
  end
  local index = S.index + delta
  if index < 1 then
    index = #S.files
  elseif index > #S.files then
    index = 1
  end
  select_file(index)
  pcall(vim.api.nvim_win_set_cursor, S.list_win, { index, 0 })
end

function M.next_file()
  step_file(1)
end

function M.prev_file()
  step_file(-1)
end

function M.toggle_fold()
  if not S then
    return
  end
  S.folded = not S.folded
  local hunks = require("lazydiff.state").get_hunks(S.pane_buf) or {}
  apply_folds(S.pane_win, S.pane_buf, hunks)
end

local function setup_shared_keys(buf)
  local keys = config.options.float.keys
  map(buf, keys.close, function()
    M.close()
  end, "close float")
  map(buf, keys.refresh, function()
    M.refresh()
  end, "refresh")
  map(buf, keys.open_file, open_file, "open file")
  map(buf, keys.next_file, M.next_file, "next file")
  map(buf, keys.prev_file, M.prev_file, "previous file")
  map(buf, keys.toggle_fold, M.toggle_fold, "toggle folding of unchanged lines")
end

local function setup_pane_keys(buf)
  local keys = config.options.float.keys
  local nav = require("lazydiff.nav")
  setup_shared_keys(buf)
  map(buf, keys.next_hunk, function()
    nav.goto_next(buf)
  end, "next hunk")
  map(buf, keys.prev_hunk, function()
    nav.goto_prev(buf)
  end, "previous hunk")
  map(buf, keys.focus_list, function()
    focus_win(S and S.list_win)
  end, "focus file list")
end

local function setup_list_keys(buf)
  local keys = config.options.float.keys
  setup_shared_keys(buf)
  map(buf, keys.focus_pane, function()
    focus_win(S and S.pane_win)
  end, "focus review pane")
end

-- -------------------------------------------------------------- selection --

select_file = function(index)
  if not S or #S.files == 0 then
    return
  end
  index = math.max(1, math.min(index, #S.files))
  local entry = S.files[index]
  S.index = index

  local abspath = S.repo .. "/" .. entry.path
  local state = require("lazydiff.state")

  -- Retire the outgoing pane buffer's nav registration before it is wiped.
  if S.pane_buf and vim.api.nvim_buf_is_valid(S.pane_buf) then
    state.disable(S.pane_buf)
  end

  local lines, baseline, hunks
  if entry.binary then
    lines = { "", "  binary file — no diff to show", "" }
    baseline, hunks = {}, {}
  else
    lines = file_lines(abspath)
    baseline = baseline_for(entry)
    hunks = diff.compute(baseline, lines)
  end

  local buf = pane_buf(abspath, lines)
  vim.api.nvim_win_set_buf(S.pane_win, buf)
  S.pane_buf = buf

  -- style = "minimal" sets signcolumn to "no", which would swallow the "+"
  -- markers render.lua puts in the sign column.
  vim.wo[S.pane_win].signcolumn = "yes:1"
  vim.wo[S.pane_win].number = config.options.float.number
  vim.wo[S.pane_win].wrap = false

  render.render(buf, hunks)
  state.attach(buf, { hunks = hunks, baseline = baseline, ref = S.ref })
  setup_pane_keys(buf)
  apply_folds(S.pane_win, buf, hunks)

  pcall(vim.api.nvim_win_set_config, S.pane_win, win_opts(S.geo.pane, " " .. entry.path .. " "))

  if #hunks > 0 then
    local target = require("lazydiff.nav").target_line(hunks[1])
    local total = vim.api.nvim_buf_line_count(buf)
    pcall(vim.api.nvim_win_set_cursor, S.pane_win, { math.max(math.min(target, total), 1), 0 })
  end
end

local function stop_select_timer()
  if S and S.select_timer then
    pcall(S.select_timer.stop, S.select_timer)
    pcall(S.select_timer.close, S.select_timer)
    S.select_timer = nil
  end
end

-- Holding j/k fires CursorMoved per row; rendering each one means a git call
-- and a full repaint per keystroke. Wait for the cursor to settle instead.
local function select_row_debounced(row)
  local ms = config.options.float.select_debounce_ms or 0
  if ms <= 0 then
    select_file(row)
    return
  end
  stop_select_timer()
  S.select_timer = vim.uv.new_timer()
  S.select_timer:start(
    ms,
    0,
    vim.schedule_wrap(function()
      stop_select_timer()
      if not S or not vim.api.nvim_win_is_valid(S.list_win) then
        return
      end
      local current = vim.api.nvim_win_get_cursor(S.list_win)[1]
      if current ~= S.index then
        select_file(current)
      end
    end)
  )
end

-- ------------------------------------------------------------- public API --

function M.is_open()
  return S ~= nil
end

function M.close()
  if not S or S.closing then
    return
  end
  S.closing = true
  stop_select_timer()
  local s = S
  S = nil

  if s.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
  end
  if s.pane_buf and vim.api.nvim_buf_is_valid(s.pane_buf) then
    require("lazydiff.state").disable(s.pane_buf)
  end
  for _, win in ipairs({ s.list_win, s.pane_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ s.list_buf, s.pane_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if s.prev_win and vim.api.nvim_win_is_valid(s.prev_win) then
    pcall(vim.api.nvim_set_current_win, s.prev_win)
  end
end

function M.resize()
  if not S then
    return
  end
  S.geo = geometry()
  local entry = S.files[S.index]
  pcall(vim.api.nvim_win_set_config, S.list_win, win_opts(S.geo.list, list_title()))
  pcall(
    vim.api.nvim_win_set_config,
    S.pane_win,
    win_opts(S.geo.pane, entry and (" " .. entry.path .. " ") or "")
  )
  render_list()
end

function M.refresh()
  if not S then
    return
  end
  local current = S.files[S.index]
  local keep = current and current.path

  local files, err = git.changed_files(S.repo, S.ref)
  if not files then
    notify(err or "failed to list changes", vim.log.levels.ERROR)
    return
  end
  if #files == 0 then
    notify("no uncommitted changes against " .. S.ref)
    M.close()
    return
  end

  S.files = files
  S.baselines = {}
  render_list()
  pcall(vim.api.nvim_win_set_config, S.list_win, win_opts(S.geo.list, list_title()))

  -- Restore the selection by path, not by row: a file appearing or vanishing
  -- above the cursor would otherwise silently switch which file you review.
  local index = 1
  for i, entry in ipairs(files) do
    if entry.path == keep then
      index = i
      break
    end
  end
  pcall(vim.api.nvim_win_set_cursor, S.list_win, { index, 0 })
  select_file(index)
end

local function setup_autocmds()
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = S.augroup,
    buffer = S.list_buf,
    callback = function()
      if not S then
        return
      end
      local row = vim.api.nvim_win_get_cursor(S.list_win)[1]
      if row ~= S.index then
        select_row_debounced(row)
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = S.augroup,
    callback = function()
      M.resize()
    end,
  })

  -- Closing either window tears down the whole float, so a stray :q or a
  -- window-manager plugin can't leave half of it on screen.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = S.augroup,
    callback = function(ev)
      local win = tonumber(ev.match)
      if S and (win == S.list_win or win == S.pane_win) then
        vim.schedule(function()
          M.close()
        end)
      end
    end,
  })
end

-- opts.ref overrides config.options.ref for this float. Opening while already
-- open focuses the list, unless a different ref is asked for, in which case
-- the float is rebuilt against it.
function M.open(opts)
  opts = opts or {}
  local ref = opts.ref or config.options.ref

  if S then
    if ref == S.ref then
      focus_win(S.list_win)
      return
    end
    M.close()
  end

  local repo = git.repo_root(git.anchor_dir())
  if not repo then
    notify("not in a git repository", vim.log.levels.WARN)
    return
  end

  local files, err = git.changed_files(repo, ref)
  if not files then
    notify(err or "failed to list changes", vim.log.levels.ERROR)
    return
  end
  if #files == 0 then
    notify("no uncommitted changes against " .. ref)
    return
  end

  S = {
    repo = repo,
    ref = ref,
    files = files,
    baselines = {},
    index = 0,
    folded = config.options.float.fold_context == true,
    prev_win = vim.api.nvim_get_current_win(),
    geo = geometry(),
  }

  S.list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[S.list_buf].bufhidden = "wipe"
  vim.bo[S.list_buf].filetype = "lazydiff-files"

  S.list_win = vim.api.nvim_open_win(S.list_buf, false, win_opts(S.geo.list, list_title()))
  vim.wo[S.list_win].cursorline = true
  vim.wo[S.list_win].wrap = false
  vim.wo[S.list_win].winhighlight = "CursorLine:LazydiffFloatSelected,FloatTitle:LazydiffFloatTitle"

  local placeholder = vim.api.nvim_create_buf(false, true)
  vim.bo[placeholder].bufhidden = "wipe"
  S.pane_win = vim.api.nvim_open_win(placeholder, false, win_opts(S.geo.pane, ""))
  vim.wo[S.pane_win].winhighlight = "Folded:LazydiffFold"

  S.augroup = vim.api.nvim_create_augroup("LazydiffFloat", { clear = true })
  setup_autocmds()
  setup_list_keys(S.list_buf)
  render_list()

  vim.api.nvim_set_current_win(S.list_win)
  pcall(vim.api.nvim_win_set_cursor, S.list_win, { 1, 0 })
  select_file(1)
end

function M.toggle(opts)
  opts = opts or {}
  if S and (opts.ref == nil or opts.ref == S.ref) then
    M.close()
  else
    M.open(opts)
  end
end

return M
