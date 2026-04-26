local M = {}

local function run(cwd, args)
  local result = vim.system({ "git", unpack(args) }, { cwd = cwd, text = true }):wait()
  return result.code, result.stdout or "", result.stderr or ""
end

function M.repo_root(path)
  if not path or path == "" then
    return nil
  end
  local dir = vim.fs.dirname(path)
  local code, out = run(dir, { "rev-parse", "--show-toplevel" })
  if code ~= 0 then
    return nil
  end
  out = out:gsub("%s+$", "")
  if out == "" then
    return nil
  end
  return out
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

function M.head_blob(repo_root, relpath, ref)
  ref = ref or "HEAD"
  local code, out, err = run(repo_root, { "show", ref .. ":" .. relpath })
  if code ~= 0 then
    return nil, err
  end
  return out, nil
end

function M.is_binary(content)
  if not content or content == "" then
    return false
  end
  return content:sub(1, 8000):find("\0", 1, true) ~= nil
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
