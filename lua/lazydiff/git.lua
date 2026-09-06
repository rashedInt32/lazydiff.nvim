local M = {}

-- Untracked files above this size are listed but not line-counted.
local MAX_COUNT_BYTES = 4 * 1024 * 1024

local function run(cwd, args)
  -- vim.system raises ENOENT rather than returning an error code when cwd does
  -- not exist, which happens for a buffer whose directory was deleted out from
  -- under it. Treat it as a plain git failure so callers can fall through.
  if not cwd or cwd == "" or vim.fn.isdirectory(cwd) == 0 then
    return 1, "", "no such directory: " .. tostring(cwd)
  end
  local ok, result = pcall(function()
    return vim.system({ "git", unpack(args) }, { cwd = cwd, text = true }):wait()
  end)
  if not ok then
    return 1, "", tostring(result)
  end
  return result.code, result.stdout or "", result.stderr or ""
end

local function trim(s)
  return (s:gsub("%s+$", ""))
end

-- Accepts a file path or a directory. Passing a directory used to strip it to
-- its parent via dirname(), so repo_root("/path/to/repo") returned nil.
function M.repo_root(path)
  if not path or path == "" then
    return nil
  end
  local dir = vim.fn.isdirectory(path) == 1 and path or vim.fs.dirname(path)
  local code, out = run(dir, { "rev-parse", "--show-toplevel" })
  if code ~= 0 then
    return nil
  end
  out = trim(out)
  if out == "" then
    return nil
  end
  return out
end

-- Absolute path of the repository's git directory. This is where HEAD and the
-- index live, so it is what the baseline watcher observes. Worktrees keep a
-- `.git` *file* at the root, which is why this asks git instead of guessing.
function M.git_dir(repo_root)
  local code, out = run(repo_root, { "rev-parse", "--absolute-git-dir" })
  if code ~= 0 then
    return nil
  end
  out = trim(out)
  return out ~= "" and out or nil
end

-- Directory to resolve the repo from. The current buffer's name is only
-- trusted when its parent directory actually exists: plugin buffers name
-- themselves with things shaped like paths -- oil://, term://, fugitive:// --
-- and dirname() on those yields a directory that isn't there.
function M.anchor_dir()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" then
    local dir = vim.fs.dirname(name)
    if dir and vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  return vim.fn.getcwd()
end

-- Branch and tag names plus HEAD, for command completion.
function M.refs(repo_root)
  local list = { "HEAD" }
  local code, out = run(repo_root, { "for-each-ref", "--format=%(refname:short)" })
  if code ~= 0 then
    return list
  end
  for _, ref in ipairs(vim.split(out, "\n", { plain = true, trimempty = true })) do
    list[#list + 1] = ref
  end
  return list
end

function M.relpath(repo_root, abspath)
  if not repo_root or not abspath then
    return nil
  end
  local prefix = repo_root:gsub("/+$", "") .. "/"
  if abspath:sub(1, #prefix) ~= prefix then
    return nil
  end
  return abspath:sub(#prefix + 1)
end

function M.is_tracked(repo_root, relpath, ref)
  ref = ref or "HEAD"
  local code = run(repo_root, { "cat-file", "-e", ref .. ":" .. relpath })
  return code == 0
end

-- Returns the blob content, or nil + a message + a reason. `reason` is
-- "untracked" when the path simply doesn't exist at `ref`, so callers can
-- treat that as "everything is new" rather than as an error.
function M.head_blob(repo_root, relpath, ref)
  ref = ref or "HEAD"
  local code, out, err = run(repo_root, { "show", ref .. ":" .. relpath })
  if code ~= 0 then
    if err:find("does not exist", 1, true) or err:find("exists on disk, but not in", 1, true) then
      return nil, "file is not tracked at " .. ref, "untracked"
    end
    return nil, trim(err), "error"
  end
  return out, nil
end

function M.is_binary(content)
  if not content or content == "" then
    return false
  end
  return content:sub(1, 8000):find("\0", 1, true) ~= nil
end

-- Split git's -z output into records. -z is used throughout changed_files so
-- that paths containing spaces, quotes or UTF-8 arrive verbatim; without it
-- git backslash-escapes and quotes such paths and they no longer round-trip.
local function nul_tokens(out)
  local toks = vim.split(out, "\0", { plain = true })
  if toks[#toks] == "" then
    toks[#toks] = nil
  end
  return toks
end

-- git diff --name-status -z emits: STATUS \0 PATH \0
-- except for renames/copies, which emit: R100 \0 OLD \0 NEW \0
local function parse_name_status(out, upsert)
  local toks = nul_tokens(out)
  local i = 1
  while i <= #toks do
    local status = toks[i] or ""
    local letter = status:sub(1, 1)
    if letter == "R" or letter == "C" then
      local newpath = toks[i + 2]
      if newpath then
        local entry = upsert(newpath)
        entry.status = letter
        entry.old_path = toks[i + 1]
      end
      i = i + 3
    else
      local path = toks[i + 1]
      if path then
        upsert(path).status = letter
      end
      i = i + 2
    end
  end
end

-- git diff --numstat -z emits: "ADDED\tDELETED\tPATH" \0
-- except for renames, where the path field is empty and the old and new paths
-- follow as their own records: "ADDED\tDELETED\t" \0 OLD \0 NEW \0
-- Binary files report "-" for both counts.
local function parse_numstat(out, files)
  local toks = nul_tokens(out)
  local i = 1
  while i <= #toks do
    local added, deleted, path = (toks[i] or ""):match("^(%S+)\t(%S+)\t(.*)$")
    if not added then
      i = i + 1
    else
      if path == "" then
        path = toks[i + 2]
        i = i + 3
      else
        i = i + 1
      end
      local entry = path and files[path]
      if entry then
        entry.binary = added == "-"
        entry.added = tonumber(added) or 0
        entry.deleted = tonumber(deleted) or 0
      end
    end
  end
end

-- Untracked files have no blob to diff against, so numstat never sees them.
-- Read the file once: detect binaries by the same NUL rule git uses, and
-- count lines ourselves so the sidebar isn't blank. Returns (lines, binary).
local function inspect_untracked(abspath)
  local stat = vim.uv.fs_stat(abspath)
  if not stat or stat.type ~= "file" then
    return 0, false
  end
  local f = io.open(abspath, "rb")
  if not f then
    return 0, false
  end
  local head = f:read(8000) or ""
  if M.is_binary(head) then
    f:close()
    return 0, true
  end
  if stat.size > MAX_COUNT_BYTES then
    f:close()
    return 0, false
  end
  local content = head .. (f:read("*a") or "")
  f:close()
  if content == "" then
    return 0, false
  end
  local _, newlines = content:gsub("\n", "")
  if content:sub(-1) ~= "\n" then
    newlines = newlines + 1
  end
  return newlines, false
end

-- Every file differing from `ref` in the working tree, plus untracked files.
-- Returns an array sorted by path:
--   { path, status, added, deleted, binary, untracked, old_path }
-- `status` is git's letter: M A D R C, or "?" for untracked.
function M.changed_files(repo_root, ref)
  ref = ref or "HEAD"
  local files, order = {}, {}

  local function upsert(path)
    local entry = files[path]
    if not entry then
      entry = { path = path, status = "M", added = 0, deleted = 0, binary = false }
      files[path] = entry
      order[#order + 1] = path
    end
    return entry
  end

  local code, out, err = run(repo_root, { "diff", ref, "--name-status", "-z", "--" })
  if code ~= 0 then
    return nil, err ~= "" and trim(err) or ("git diff failed against " .. ref)
  end
  parse_name_status(out, upsert)

  local ncode, nout = run(repo_root, { "diff", ref, "--numstat", "-z", "--" })
  if ncode == 0 then
    parse_numstat(nout, files)
  end

  local ucode, uout = run(repo_root, { "ls-files", "--others", "--exclude-standard", "-z" })
  if ucode == 0 then
    for _, path in ipairs(nul_tokens(uout)) do
      if path ~= "" and not files[path] then
        local entry = upsert(path)
        entry.status = "?"
        entry.untracked = true
        entry.added, entry.binary = inspect_untracked(repo_root .. "/" .. path)
      end
    end
  end

  local list = {}
  for _, path in ipairs(order) do
    list[#list + 1] = files[path]
  end
  table.sort(list, function(a, b)
    return a.path < b.path
  end)
  return list
end

function M.split_lines(content)
  if not content or content == "" then
    return {}
  end
  local trailing_newline = content:sub(-1) == "\n"
  local lines = vim.split(content, "\n", { plain = true })
  if trailing_newline then
    lines[#lines] = nil
  end
  return lines
end

return M
