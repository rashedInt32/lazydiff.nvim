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
local function capture_notify(fn)
  local msg
  local orig = vim.notify
  vim.notify = function(m)
    msg = m
  end
  local ok, err = pcall(fn)
  vim.notify = orig
  if not ok then
    error(err)
  end
  return msg
end

-- Selection is rendered synchronously so the spec can read the pane right
-- after moving the cursor; the debounced path gets its own test below.
-- context_lines = 1 so the small fixture file has foldable gaps.
local function configure(extra)
  require("lazydiff").setup(vim.tbl_deep_extend("force", {
    float = { select_debounce_ms = 0, context_lines = 1 },
  }, extra or {}))
end
configure()

local git = require("lazydiff.git")
local diff = require("lazydiff.diff")
local render = require("lazydiff.render")
local state = require("lazydiff.state")
local float = require("lazydiff.float")
local nav = require("lazydiff.nav")
local NS = render.namespace()

vim.cmd.cd(dirty)

-- ---------------------------------------------------------------------------
section("config validation")

local ok_bad = pcall(require("lazydiff.config").setup, { ref = 5 })
check("rejects a non-string ref", not ok_bad)
ok_bad = pcall(require("lazydiff.config").setup, { float = { width = "wide" } })
check("rejects a non-numeric float.width", not ok_bad)
check("accepts a valid table", pcall(require("lazydiff.config").setup, { ref = "HEAD" }))
configure()

-- ---------------------------------------------------------------------------
section("diff.compute")

local function hunk_sig(h)
  return ("%s %d,%d %d,%d"):format(h.kind, h.old_start, h.old_count, h.new_start, h.new_count)
end
local function first_hunk(old, new)
  local hs = diff.compute(old, new)
  return hs[1] and hunk_sig(hs[1]) or "none", #hs
end
local function expect_hunk(name, old, new, want)
  local got = first_hunk(old, new)
  check(name, got == want, ("want %s got %s"):format(want, got))
end

check("identical inputs yield no hunks", #diff.compute({ "a", "b" }, { "a", "b" }) == 0)
expect_hunk("add at end", { "a" }, { "a", "b" }, "add 1,0 2,1")
expect_hunk("add at top", { "b" }, { "a", "b" }, "add 0,0 1,1")
expect_hunk("delete at top", { "a", "b" }, { "b" }, "delete 1,1 0,0")
expect_hunk("delete at end", { "a", "b" }, { "a" }, "delete 2,1 1,0")
expect_hunk("change in the middle", { "a", "b", "c" }, { "a", "B", "c" }, "change 2,1 2,1")
expect_hunk("empty baseline is one add hunk", {}, { "x", "y" }, "add 0,0 1,2")
local ch = diff.compute({ "a", "b", "c" }, { "a", "B", "c" })[1]
check("hunk carries old and new lines", ch.old_lines[1] == "b" and ch.new_lines[1] == "B")
check(
  "hunk header format",
  diff.format_hunk_header(ch) == "@@ -2 +2 @@",
  diff.format_hunk_header(ch)
)

-- ---------------------------------------------------------------------------
section("diff.word_diff")

local olds, news = diff.word_diff("  return 1", "  return 100")
check(
  "old span covers the changed token",
  olds[1] and olds[1][1] == 9 and olds[1][2] == 10,
  vim.inspect(olds)
)
check(
  "new span covers the changed token",
  news[1] and news[1][1] == 9 and news[1][2] == 12,
  vim.inspect(news)
)
olds, news = diff.word_diff("same", "same")
check("identical lines yield no spans", #olds == 0 and #news == 0)
local _, news2 = diff.word_diff("foo(a, b)", "foo(a, c)")
check(
  "punctuation is not swept into the span",
  news2[1] and news2[1][1] == 7 and news2[1][2] == 8,
  vim.inspect(news2)
)

-- ---------------------------------------------------------------------------
section("git.changed_files")

local files, err = git.changed_files(dirty, "HEAD")
check("returns a list", type(files) == "table", tostring(err))

local by_path = {}
for _, e in ipairs(files or {}) do
  by_path[e.path] = e
  print(
    ("       %-4s %-16s +%-4d -%-4d binary=%-5s untracked=%s"):format(
      e.status,
      e.path,
      e.added,
      e.deleted,
      tostring(e.binary),
      tostring(e.untracked or false)
    )
  )
end

-- -uall, not plain --short: git collapses an untracked directory into a single
-- "?? dir/" line, but the float lists each file, matching `ls-files --others`.
local status_lines =
  vim.fn.systemlist("git -C " .. vim.fn.shellescape(dirty) .. " status --short -uall")
check(
  "count matches git status --short -uall",
  #files == #status_lines,
  ("float=%d git=%d"):format(#files, #status_lines)
)

check(
  "modified file listed as M",
  by_path["modified.lua"] and by_path["modified.lua"].status == "M"
)
check(
  "modified file has non-zero counts",
  by_path["modified.lua"]
    and by_path["modified.lua"].added > 0
    and by_path["modified.lua"].deleted > 0
)
check("deleted file listed as D", by_path["gone.lua"] and by_path["gone.lua"].status == "D")
check(
  "untracked file listed as ?",
  by_path["brand-new.lua"] and by_path["brand-new.lua"].status == "?"
)
check(
  "untracked file has a real line count",
  by_path["brand-new.lua"] and by_path["brand-new.lua"].added == 3,
  by_path["brand-new.lua"] and tostring(by_path["brand-new.lua"].added) or "missing"
)
check("binary file flagged", by_path["blob.bin"] and by_path["blob.bin"].binary == true)
check(
  "untracked binary flagged, not line-counted",
  by_path["new.bin"] and by_path["new.bin"].binary == true and by_path["new.bin"].added == 0,
  by_path["new.bin"] and vim.inspect(by_path["new.bin"]) or "missing"
)
check(
  "rename listed under the NEW path",
  by_path["renamed.lua"] and by_path["renamed.lua"].status == "R"
)
check(
  "rename records old_path",
  by_path["renamed.lua"] and by_path["renamed.lua"].old_path == "original.lua",
  by_path["renamed.lua"] and tostring(by_path["renamed.lua"].old_path) or "nil"
)
check("rename's old path not listed separately", by_path["original.lua"] == nil)
check(
  "path containing a space survives -z parsing",
  by_path["has space.lua"] ~= nil,
  table.concat(vim.tbl_keys(by_path), ", ")
)
check("unchanged tracked file is absent", by_path["unchanged.lua"] == nil)

local older = git.changed_files(dirty, "HEAD~1")
local second
for _, e in ipairs(older or {}) do
  if e.path == "second.lua" then
    second = e
  end
end
check("against HEAD~1 the second commit's file shows as A", second and second.status == "A")
check("refs() includes HEAD", vim.tbl_contains(git.refs(dirty), "HEAD"))
check(
  "git_dir() resolves",
  (git.git_dir(dirty) or ""):match("%.git$") ~= nil,
  tostring(git.git_dir(dirty))
)
local _, blob_err, reason = git.head_blob(dirty, "nope.lua", "HEAD")
check("head_blob reports untracked paths", reason == "untracked", tostring(blob_err))

-- ---------------------------------------------------------------------------
section("window shell")

local wins_before = #vim.api.nvim_list_wins()
float.open()
check("float reports open", float.is_open())
check(
  "two windows added",
  #vim.api.nvim_list_wins() == wins_before + 2,
  ("before=%d now=%d"):format(wins_before, #vim.api.nvim_list_wins())
)

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
    if vim.api.nvim_win_get_config(w).relative ~= "" and vim.bo[b].filetype ~= "lazydiff-files" then
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
local function row_of(path)
  for i, e in ipairs(git.changed_files(dirty, "HEAD")) do
    if e.path == path then
      return i
    end
  end
end

-- ---------------------------------------------------------------------------
section("sidebar")

local _, lbuf = list_win()
local rows = vim.api.nvim_buf_get_lines(lbuf, 0, -1, false)
check("one row per file", #rows == #files, ("rows=%d files=%d"):format(#rows, #files))
for _, r in ipairs(rows) do
  print(("       |%s|"):format(r))
end

local marks =
  vim.api.nvim_buf_get_extmarks(lbuf, vim.api.nvim_create_namespace("lazydiff_float"), 0, -1, {})
check("sidebar rows are highlighted", #marks > 0, ("marks=%d"):format(#marks))

-- ---------------------------------------------------------------------------
section("review pane (core loop)")

select_row(row_of("modified.lua"))

local pwin, pbuf = pane()
check("pane buffer exists", pbuf ~= nil)
check("pane is read-only", pbuf and vim.bo[pbuf].modifiable == false)
check(
  "pane filetype detected (treesitter attaches)",
  pbuf and vim.bo[pbuf].filetype == "lua",
  pbuf and vim.bo[pbuf].filetype or "nil"
)
-- style="minimal" sets signcolumn=no, which would swallow render.lua's + marks.
check(
  "pane signcolumn is on",
  pwin and vim.wo[pwin].signcolumn ~= "no",
  pwin and vim.wo[pwin].signcolumn or "nil"
)
check(
  "render painted extmarks in the pane",
  pbuf and #vim.api.nvim_buf_get_extmarks(pbuf, NS, 0, -1, {}) > 0
)

local float_hunks = state.get_hunks(pbuf)
check(
  "state.attach registered hunks (nav works)",
  float_hunks and #float_hunks > 0,
  ("hunks=%s"):format(float_hunks and #float_hunks or "nil")
)
check(
  "modified.lua produced two hunks",
  float_hunks and #float_hunks == 2,
  ("got %s"):format(float_hunks and #float_hunks or "nil")
)

-- ---------------------------------------------------------------------------
section("navigation")

vim.api.nvim_set_current_win(pwin)
vim.api.nvim_win_set_cursor(pwin, { 1, 0 })
nav.goto_next(pbuf)
local first = vim.api.nvim_win_get_cursor(pwin)[1]
nav.goto_next(pbuf)
local second_line = vim.api.nvim_win_get_cursor(pwin)[1]
check("]h advances through hunks", second_line > first, ("%d -> %d"):format(first, second_line))
nav.goto_prev(pbuf)
check("[h goes back", vim.api.nvim_win_get_cursor(pwin)[1] == first, ("expected %d"):format(first))
nav.goto_prev(pbuf)
check("[h wraps to the last hunk", vim.api.nvim_win_get_cursor(pwin)[1] == second_line)
nav.goto_next(pbuf)
check("]h wraps to the first hunk", vim.api.nvim_win_get_cursor(pwin)[1] == first)

-- ---------------------------------------------------------------------------
section("next / previous file from the pane")

local start_row = row_of("modified.lua")
float.next_file()
local _, pb = pane()
check("]f moves to the next file", state.get_hunks(pb) ~= float_hunks)
check("sidebar cursor follows", vim.api.nvim_win_get_cursor((list_win()))[1] == start_row + 1)
float.prev_file()
check("[f moves back", vim.api.nvim_win_get_cursor((list_win()))[1] == start_row)
local _, pb2 = pane()
check("back on modified.lua", #(state.get_hunks(pb2) or {}) == 2)
for _ = 1, #files do
  float.next_file()
end
check("]f wraps around the list", vim.api.nvim_win_get_cursor((list_win()))[1] == start_row)

-- ---------------------------------------------------------------------------
section("folding unchanged context")

local pw, pbf = pane()
check("folds start disabled", vim.wo[pw].foldenable == false)
float.toggle_fold()
local closed = vim.api.nvim_win_call(pw, function()
  return vim.fn.foldclosed(1)
end)
check("toggle enables folding", vim.wo[pw].foldenable == true)
check("unchanged lines at the top are folded", closed == 1, ("foldclosed(1)=%d"):format(closed))
local hunk_open = vim.api.nvim_win_call(pw, function()
  return vim.fn.foldclosed(state.get_hunks(pbf)[1].new_start)
end)
check("hunk lines stay visible", hunk_open == -1)
float.next_file()
float.prev_file()
pw = pane()
check("fold state survives switching files", vim.wo[pw].foldenable == true)
float.toggle_fold()
pw = pane()
check("toggle again disables folding", vim.wo[pw].foldenable == false)
local regions = float.unchanged_regions({ { new_start = 5, new_count = 1 } }, 20, 2)
check(
  "unchanged_regions leaves context around the hunk",
  #regions == 2
    and regions[1][1] == 1
    and regions[1][2] == 2
    and regions[2][1] == 8
    and regions[2][2] == 20,
  vim.inspect(regions)
)

-- ---------------------------------------------------------------------------
section("refresh preserves selection by path")

select_row(row_of("modified.lua"))
-- "aaa-new.lua" sorts above modified.lua, so a row-index restore would slide
-- the selection onto the wrong file.
vim.fn.writefile({ "-- inserted above the selection" }, dirty .. "/aaa-new.lua")
float.refresh()
local _, lbuf2 = list_win()
check("new file picked up", #vim.api.nvim_buf_get_lines(lbuf2, 0, -1, false) == #files + 1)
local _, pbuf2 = pane()
check(
  "still reviewing modified.lua",
  #(state.get_hunks(pbuf2) or {}) == 2,
  "selection moved to a different file"
)
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
  print(
    ("         lines=%d marks=%d ft=%s"):format(
      b and vim.api.nvim_buf_line_count(b) or -1,
      n,
      b and vim.bo[b].filetype or ""
    )
  )

  if entry.path == "gone.lua" then
    check("deleted file paints its removed lines", n > 0)
  elseif entry.path == "brand-new.lua" then
    local h = state.get_hunks(b)
    check(
      "untracked file is one big add hunk",
      h and #h == 1 and h[1].kind == "add",
      h and h[1] and h[1].kind or "none"
    )
  elseif entry.binary then
    local txt = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), " ")
    check(("%s shows a placeholder"):format(entry.path), txt:find("binary file") ~= nil, txt)
  end
end

-- ---------------------------------------------------------------------------
section("debounced selection settles")

configure({ float = { select_debounce_ms = 20 } })
select_row(row_of("modified.lua"))
local _, immediate = pane()
check("pane not rendered synchronously", #(state.get_hunks(immediate) or {}) ~= 2)
local settled = vim.wait(1000, function()
  local _, b = pane()
  return #(state.get_hunks(b) or {}) == 2
end, 10)
check("pane rendered after the debounce", settled)
configure()

-- ---------------------------------------------------------------------------
section("teardown")

float.close()
check("float reports closed", not float.is_open())
local leaked = 0
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == "lazydiff-files" then
    leaked = leaked + 1
  end
end
check("no leaked sidebar buffers", leaked == 0, ("leaked=%d"):format(leaked))
check(
  "window count restored",
  #vim.api.nvim_list_wins() == wins_before,
  ("before=%d now=%d"):format(wins_before, #vim.api.nvim_list_wins())
)

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
    if
      a.kind ~= b.kind
      or a.old_start ~= b.old_start
      or a.old_count ~= b.old_count
      or a.new_start ~= b.new_start
      or a.new_count ~= b.new_count
    then
      same = false
      break
    end
  end
end
check(
  "float hunks identical to inline hunks",
  same,
  ("float=%s inline=%s"):format(
    float_hunks and #float_hunks or "nil",
    inline_hunks and #inline_hunks or "nil"
  )
)

-- ---------------------------------------------------------------------------
section("render anchoring and word diff")

local buf = vim.api.nvim_get_current_buf()
local details = vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })
local above_at, add_word, del_word
for _, m in ipairs(details) do
  local row, col, d = m[2], m[3], m[4]
  if d.virt_lines and d.virt_lines_above and row == inline_hunks[1].new_start - 1 then
    above_at = true
    for _, line in ipairs(d.virt_lines) do
      for _, chunk in ipairs(line) do
        if chunk[2] == "LazydiffDeleteWord" then
          del_word = chunk[1]
        end
      end
    end
  end
  if d.hl_group == "LazydiffAddWord" and row == inline_hunks[1].new_start - 1 then
    add_word = { col, d.end_col }
  end
end
check("deleted lines sit directly above the first changed line", above_at == true)
check("deleted virt line emphasises the changed word", del_word == "1", tostring(del_word))
check(
  "added line emphasises the changed word",
  add_word and add_word[1] == 9 and add_word[2] == 12,
  vim.inspect(add_word)
)

-- ---------------------------------------------------------------------------
section("status, yank, reset")

local unnamed = '"'
vim.api.nvim_win_set_cursor(0, { inline_hunks[1].new_start, 0 })
local st = require("lazydiff").status()
check(
  "status reports the hunk under the cursor",
  st and st.hunks == 2 and st.current == 1,
  vim.inspect(st)
)
check(
  "statusline text",
  require("lazydiff").statusline() == "lazydiff: hunk 1/2",
  require("lazydiff").statusline()
)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
check(
  "statusline off-hunk",
  require("lazydiff").statusline() == "lazydiff: 2 hunks",
  require("lazydiff").statusline()
)

vim.api.nvim_win_set_cursor(0, { inline_hunks[1].new_start, 0 })
vim.fn.setreg(unnamed, "")
check("yank_hunk succeeds", require("lazydiff").yank_hunk())
local yanked = vim.fn.getreg(unnamed, 1, 1)
check("register holds the deleted line", yanked[1] == "  return 1", vim.inspect(yanked))
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local yank_msg = capture_notify(function()
  return require("lazydiff").yank_hunk()
end)
check(
  "yank_hunk off a hunk fails cleanly",
  yank_msg and yank_msg:find("no hunk") ~= nil,
  tostring(yank_msg)
)

vim.api.nvim_win_set_cursor(0, { inline_hunks[1].new_start, 0 })
check("reset_hunk succeeds", require("lazydiff").reset_hunk())
local reverted = vim.api.nvim_buf_get_lines(
  buf,
  inline_hunks[1].new_start - 1,
  inline_hunks[1].new_start,
  false
)[1]
check("line reverted to the baseline", reverted == "  return 1", tostring(reverted))
check(
  "one hunk remains",
  #(state.get_hunks(buf) or {}) == 1,
  tostring(#(state.get_hunks(buf) or {}))
)
vim.api.nvim_win_set_cursor(0, { state.get_hunks(buf)[1].new_start, 0 })
require("lazydiff").reset_hunk()
check("resetting the last hunk leaves none", #(state.get_hunks(buf) or {}) == 0)
vim.cmd("edit!")
check(
  "overlay survives :edit! and repaints",
  state.is_enabled(buf) and #(state.get_hunks(buf) or {}) == 2
)
require("lazydiff").disable()

-- ---------------------------------------------------------------------------
section("ref argument")

vim.cmd("Lazydiff HEAD~1")
check(
  "enabled against HEAD~1",
  state.is_enabled(0) and require("lazydiff").status().ref == "HEAD~1"
)
vim.cmd("Lazydiff HEAD~1")
check("same ref twice toggles off", not state.is_enabled(0))
vim.cmd("Lazydiff HEAD~1")
vim.cmd("Lazydiff")
check("bare :Lazydiff toggles off whatever ref is active", not state.is_enabled(0))
vim.cmd("Lazydiff")
vim.cmd("Lazydiff HEAD~1")
check(
  "a new ref switches an active overlay",
  state.is_enabled(0) and require("lazydiff").status().ref == "HEAD~1"
)
require("lazydiff").disable()
local completions = vim.fn.getcompletion("Lazydiff HE", "cmdline")
check("ref completion offers HEAD", vim.tbl_contains(completions, "HEAD"), vim.inspect(completions))

float.open({ ref = "HEAD~1" })
local _, lb = list_win()
local listed = table.concat(vim.api.nvim_buf_get_lines(lb, 0, -1, false), "\n")
check("float against HEAD~1 lists second.lua", listed:find("second.lua", 1, true) ~= nil)
float.open()
_, lb = list_win()
listed = table.concat(vim.api.nvim_buf_get_lines(lb, 0, -1, false), "\n")
check(
  "reopening against HEAD rebuilds the list",
  float.is_open() and listed:find("second.lua", 1, true) == nil
)
float.close()

-- ---------------------------------------------------------------------------
section("enable on a clean file, signcolumn, baseline refetch")

vim.cmd.cd(clean)
vim.cmd.edit(clean .. "/a.txt")
vim.wo.signcolumn = "no"
local msg = capture_notify(function()
  require("lazydiff").enable()
end)
check("clean file enables anyway", state.is_enabled(0), tostring(msg))
check("and says so", msg and msg:find("no changes") ~= nil, tostring(msg))
check("zero hunks", #(state.get_hunks(0) or {}) == 0)
check("signcolumn forced on", vim.wo.signcolumn == "yes:1", vim.wo.signcolumn)

vim.api.nvim_buf_set_lines(0, -1, -1, false, { "a new line" })
require("lazydiff").refresh()
check("overlay appears once the buffer diverges", #(state.get_hunks(0) or {}) == 1)
vim.cmd("silent write")
check("still one hunk after save", #(state.get_hunks(0) or {}) == 1)

vim.fn.system({ "git", "-C", clean, "commit", "-qam", "commit behind the editor" })
require("lazydiff").refresh(nil, { baseline = true })
check("explicit baseline refetch clears the hunk after a commit", #(state.get_hunks(0) or {}) == 0)

vim.api.nvim_buf_set_lines(0, -1, -1, false, { "another line" })
vim.cmd("silent write")
check("write repaints", #(state.get_hunks(0) or {}) == 1)
vim.fn.system({ "git", "-C", clean, "commit", "-qam", "second commit behind the editor" })
local watched = vim.wait(3000, function()
  return #(state.get_hunks(0) or {}) == 0
end, 50)
check("git watcher refetches the baseline after a commit", watched)

require("lazydiff").disable()
check("signcolumn restored", vim.wo.signcolumn == "no", vim.wo.signcolumn)

-- ---------------------------------------------------------------------------
section("bufnr 0 means current buffer")

vim.cmd.cd(dirty)
vim.cmd.edit(dirty .. "/modified.lua")
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
check(
  "directory and file resolve to the same root",
  root_from_dir == root_from_file,
  ("dir=%s file=%s"):format(tostring(root_from_dir), tostring(root_from_file))
)

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
  local notified = capture_notify(float.open)
  check(("float opens from a %s buffer"):format(label), float.is_open(), tostring(notified))
  float.close()
end

local ok_missing, res = pcall(git.repo_root, "/nonexistent-dir-xyz/file.lua")
check("repo_root does not throw on a missing directory", ok_missing, tostring(res))
check("repo_root returns nil outside a repo", ok_missing and res == nil)
check(
  "changed_files fails cleanly outside a repo",
  select(1, git.changed_files("/nonexistent-dir-xyz", "HEAD")) == nil
)

-- The repo is resolved from the current buffer, not from cwd (matching
-- gitsigns/fugitive), so the buffer has to move too -- a bare :cd would leave
-- us pointed at the dirty repo.
vim.cmd.cd(clean)
vim.cmd.edit(clean .. "/a.txt")
check("clean repo yields zero entries", #git.changed_files(clean, "HEAD") == 0)
local notified = capture_notify(float.open)
check("float refuses to open with nothing to show", not float.is_open())
check(
  "and explains why",
  notified and notified:find("no uncommitted changes") ~= nil,
  tostring(notified)
)

-- ---------------------------------------------------------------------------
section("health")

check("checkhealth runs without throwing", pcall(require("lazydiff.health").check))

-- ---------------------------------------------------------------------------
print(("\n== %d passed, %d failed =="):format(pass, fail))
vim.cmd(fail == 0 and "qall!" or "cquit!")
