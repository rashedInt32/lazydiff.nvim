-- lazydiff.nvim test suite.
--
--   tests/run.sh
--
-- Runs against the fixture repos built by tests/fixture.sh, so results do not
-- depend on the state of this repo's own working tree.

local fixture = assert(vim.env.LAZYDIFF_FIXTURE, "LAZYDIFF_FIXTURE not set (use tests/run.sh)")
local dirty = fixture .. "/dirty"
local clean = fixture .. "/clean"

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(("  ok   %s"):format(name))
  else
    fail = fail + 1
    print(("  FAIL %s   %s"):format(name, detail or ""))
  end
end
local function section(title)
  print(("\n== %s =="):format(title))
end

local git = require("lazydiff.git")
local diff = require("lazydiff.diff")
local render = require("lazydiff.render")
local state = require("lazydiff.state")
local float = require("lazydiff.float")
local NS = render.namespace()

vim.cmd.cd(dirty)

-- ---------------------------------------------------------------------------
section("git.changed_files")

local files, err = git.changed_files(dirty, "HEAD")
check("returns a list", type(files) == "table", tostring(err))

local by_path = {}
for _, e in ipairs(files or {}) do
  by_path[e.path] = e
  print(("       %-4s %-16s +%-4d -%-4d binary=%-5s untracked=%s")
    :format(e.status, e.path, e.added, e.deleted, tostring(e.binary), tostring(e.untracked or false)))
end

-- -uall, not plain --short: git collapses an untracked directory into a single
-- "?? dir/" line, but the float lists each file, matching `ls-files --others`.
local status_lines = vim.fn.systemlist("git -C " .. vim.fn.shellescape(dirty) .. " status --short -uall")
check("count matches git status --short -uall", #files == #status_lines,
  ("float=%d git=%d"):format(#files, #status_lines))

check("modified file listed as M", by_path["modified.lua"]
  and by_path["modified.lua"].status == "M")
check("modified file has non-zero counts", by_path["modified.lua"]
  and by_path["modified.lua"].added > 0 and by_path["modified.lua"].deleted > 0)
check("deleted file listed as D", by_path["gone.lua"] and by_path["gone.lua"].status == "D")
check("untracked file listed as ?", by_path["brand-new.lua"]
  and by_path["brand-new.lua"].status == "?")
check("untracked file has a real line count", by_path["brand-new.lua"]
  and by_path["brand-new.lua"].added == 3,
  by_path["brand-new.lua"] and tostring(by_path["brand-new.lua"].added) or "missing")
check("binary file flagged", by_path["blob.bin"] and by_path["blob.bin"].binary == true)
check("rename listed under the NEW path", by_path["renamed.lua"]
  and by_path["renamed.lua"].status == "R")
check("rename records old_path", by_path["renamed.lua"]
  and by_path["renamed.lua"].old_path == "original.lua",
  by_path["renamed.lua"] and tostring(by_path["renamed.lua"].old_path) or "nil")
check("rename's old path not listed separately", by_path["original.lua"] == nil)
check("path containing a space survives -z parsing", by_path["has space.lua"] ~= nil,
  table.concat(vim.tbl_keys(by_path), ", "))
check("unchanged tracked file is absent", by_path["unchanged.lua"] == nil)

-- ---------------------------------------------------------------------------
section("window shell")

local wins_before = #vim.api.nvim_list_wins()
float.open()
check("float reports open", float.is_open())
check("two windows added", #vim.api.nvim_list_wins() == wins_before + 2,
  ("before=%d now=%d"):format(wins_before, #vim.api.nvim_list_wins()))

local function list_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "lazydiff-files" then
      return w, vim.api.nvim_win_get_buf(w)
    end
  end
end
local function pane()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_win_get_config(w).relative ~= ""
      and vim.bo[b].filetype ~= "lazydiff-files" then
      return w, b
    end
  end
end
local function select_row(i)
  local w = list_win()
  vim.api.nvim_set_current_win(w)
  vim.api.nvim_win_set_cursor(w, { i, 0 })
  vim.cmd("doautocmd CursorMoved")
end

-- ---------------------------------------------------------------------------
section("sidebar")

local _, lbuf = list_win()
local rows = vim.api.nvim_buf_get_lines(lbuf, 0, -1, false)
check("one row per file", #rows == #files, ("rows=%d files=%d"):format(#rows, #files))
for _, r in ipairs(rows) do
  print(("       |%s|"):format(r))
end

local marks = vim.api.nvim_buf_get_extmarks(lbuf, vim.api.nvim_create_namespace("lazydiff_float"),
  0, -1, {})
check("sidebar rows are highlighted", #marks > 0, ("marks=%d"):format(#marks))

-- ---------------------------------------------------------------------------
section("review pane (core loop)")

local target
for i, e in ipairs(files) do
  if e.path == "modified.lua" then target = i end
end
select_row(target)

local pwin, pbuf = pane()
check("pane buffer exists", pbuf ~= nil)
check("pane is read-only", pbuf and vim.bo[pbuf].modifiable == false)
check("pane filetype detected (treesitter attaches)", pbuf and vim.bo[pbuf].filetype == "lua",
  pbuf and vim.bo[pbuf].filetype or "nil")
-- style="minimal" sets signcolumn=no, which would swallow render.lua's + marks.
check("pane signcolumn is on", pwin and vim.wo[pwin].signcolumn ~= "no",
  pwin and vim.wo[pwin].signcolumn or "nil")
check("render painted extmarks in the pane",
  pbuf and #vim.api.nvim_buf_get_extmarks(pbuf, NS, 0, -1, {}) > 0)

local float_hunks = state.get_hunks(pbuf)
check("state.attach registered hunks (nav works)", float_hunks and #float_hunks > 0,
  ("hunks=%s"):format(float_hunks and #float_hunks or "nil"))
check("modified.lua produced two hunks", float_hunks and #float_hunks == 2,
  ("got %s"):format(float_hunks and #float_hunks or "nil"))

-- ---------------------------------------------------------------------------
section("navigation")

local nav = require("lazydiff.nav")
vim.api.nvim_set_current_win(pwin)
vim.api.nvim_win_set_cursor(pwin, { 1, 0 })
nav.goto_next(pbuf)
local first = vim.api.nvim_win_get_cursor(pwin)[1]
nav.goto_next(pbuf)
local second = vim.api.nvim_win_get_cursor(pwin)[1]
check("]h advances through hunks", second > first, ("%d -> %d"):format(first, second))
nav.goto_prev(pbuf)
check("[h goes back", vim.api.nvim_win_get_cursor(pwin)[1] == first,
  ("expected %d"):format(first))

-- ---------------------------------------------------------------------------
section("refresh preserves selection by path")

-- "aaa-new.lua" sorts above modified.lua, so a row-index restore would slide
-- the selection onto the wrong file.
vim.fn.writefile({ "-- inserted above the selection" }, dirty .. "/aaa-new.lua")
float.refresh()
local _, lbuf2 = list_win()
check("new file picked up", #vim.api.nvim_buf_get_lines(lbuf2, 0, -1, false) == #files + 1)
local _, pbuf2 = pane()
check("still reviewing modified.lua",
  #(state.get_hunks(pbuf2) or {}) == 2,
  "selection moved to a different file")
vim.fn.delete(dirty .. "/aaa-new.lua")
float.refresh()

-- ---------------------------------------------------------------------------
section("every entry renders without throwing")

local current = git.changed_files(dirty, "HEAD")
for i, entry in ipairs(current) do
  local ok = pcall(select_row, i)
  local _, b = pane()
  local n = b and #vim.api.nvim_buf_get_extmarks(b, NS, 0, -1, {}) or -1
  check(("select %-16s (%s)"):format(entry.path, entry.status), ok and b ~= nil)
  print(("         lines=%d marks=%d ft=%s")
    :format(b and vim.api.nvim_buf_line_count(b) or -1, n, b and vim.bo[b].filetype or ""))

  if entry.path == "gone.lua" then
    check("deleted file paints its removed lines", n > 0)
  elseif entry.path == "brand-new.lua" then
    local h = state.get_hunks(b)
    check("untracked file is one big add hunk", h and #h == 1 and h[1].kind == "add",
      h and h[1] and h[1].kind or "none")
  elseif entry.path == "blob.bin" then
    local txt = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), " ")
    check("binary file shows a placeholder", txt:find("binary file") ~= nil, txt)
  end
end

-- ---------------------------------------------------------------------------
section("teardown")

float.close()
check("float reports closed", not float.is_open())
local leaked = 0
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == "lazydiff-files" then leaked = leaked + 1 end
end
check("no leaked sidebar buffers", leaked == 0, ("leaked=%d"):format(leaked))
check("window count restored", #vim.api.nvim_list_wins() == wins_before,
  ("before=%d now=%d"):format(wins_before, #vim.api.nvim_list_wins()))

-- ---------------------------------------------------------------------------
section("float and inline agree")

vim.cmd.edit(dirty .. "/modified.lua")
require("lazydiff").enable()
local inline_hunks = state.get_hunks(vim.api.nvim_get_current_buf())
check("inline overlay produced hunks", inline_hunks and #inline_hunks > 0)

local same = float_hunks and inline_hunks and #float_hunks == #inline_hunks
if same then
  for i = 1, #float_hunks do
    local a, b = float_hunks[i], inline_hunks[i]
    if a.kind ~= b.kind or a.old_start ~= b.old_start or a.old_count ~= b.old_count
      or a.new_start ~= b.new_start or a.new_count ~= b.new_count then
      same = false
      break
    end
  end
end
check("float hunks identical to inline hunks", same,
  ("float=%s inline=%s"):format(float_hunks and #float_hunks or "nil",
    inline_hunks and #inline_hunks or "nil"))
require("lazydiff").disable()

-- ---------------------------------------------------------------------------
section("bufnr 0 means current buffer")

-- Every Neovim API takes 0 for "current buffer", but 0 is truthy in Lua, so
-- `bufnr or current()` used to keep it and land on buffers[0].
require("lazydiff").enable()
check("get_hunks(0) resolves to the current buffer", state.get_hunks(0) ~= nil)
check("is_enabled(0) resolves to the current buffer", state.is_enabled(0))
require("lazydiff").disable()

-- ---------------------------------------------------------------------------
section("repo detection from non-file buffers")

-- Compared to each other rather than to `dirty`: on macOS $TMPDIR is a symlink
-- (/var/... -> /private/var/...) and git reports the resolved path.
local root_from_dir = git.repo_root(dirty)
local root_from_file = git.repo_root(dirty .. "/modified.lua")
check("repo_root accepts a directory, not just a file", root_from_dir ~= nil)
check("directory and file resolve to the same root", root_from_dir == root_from_file,
  ("dir=%s file=%s"):format(tostring(root_from_dir), tostring(root_from_file)))

-- Plugin buffers name themselves with things shaped like paths. dirname() on
-- these yields a directory that does not exist, which used to be reported as
-- "not in a git repository" from a terminal or file-explorer buffer.
for _, case in ipairs({
  { "oil.nvim", "oil://" .. dirty },
  { "toggleterm", "term://" .. dirty .. "//4242:zsh" },
  { "fugitive", "fugitive://" .. dirty .. "/.git//" },
  { "unnamed buffer", "" },
}) do
  local label, bufname = case[1], case[2]
  vim.cmd.cd(dirty)
  vim.cmd("enew!")
  if bufname ~= "" then
    pcall(vim.api.nvim_buf_set_name, 0, bufname)
  end
  local notified
  local orig = vim.notify
  vim.notify = function(m) notified = m end
  float.open()
  vim.notify = orig
  check(("float opens from a %s buffer"):format(label), float.is_open(),
    tostring(notified))
  float.close()
end

local ok_missing, res = pcall(git.repo_root, "/nonexistent-dir-xyz/file.lua")
check("repo_root does not throw on a missing directory", ok_missing, tostring(res))
check("repo_root returns nil outside a repo", ok_missing and res == nil)
check("changed_files fails cleanly outside a repo",
  select(1, git.changed_files("/nonexistent-dir-xyz", "HEAD")) == nil)

-- The repo is resolved from the current buffer, not from cwd (matching
-- gitsigns/fugitive), so the buffer has to move too -- a bare :cd would leave
-- us pointed at the dirty repo.
vim.cmd.cd(clean)
vim.cmd.edit(clean .. "/a.txt")
check("clean repo yields zero entries", #git.changed_files(clean, "HEAD") == 0)
local notified
local orig_notify = vim.notify
vim.notify = function(m) notified = m end
float.open()
vim.notify = orig_notify
check("float refuses to open with nothing to show", not float.is_open())
check("and explains why", notified and notified:find("no uncommitted changes") ~= nil,
  tostring(notified))

-- ---------------------------------------------------------------------------
print(("\n== %d passed, %d failed =="):format(pass, fail))
vim.cmd(fail == 0 and "qall!" or "cquit!")
