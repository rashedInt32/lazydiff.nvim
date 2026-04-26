local M = {}

local function slice(lines, start_1based, count)
  local out = {}
  for i = 0, count - 1 do
    out[#out + 1] = lines[start_1based + i] or ""
  end
  return out
end

function M.compute(old_lines, new_lines)
  local old_text = table.concat(old_lines, "\n")
  local new_text = table.concat(new_lines, "\n")

  local raw = vim.diff(old_text, new_text, {
    result_type = "indices",
    algorithm = "histogram",
    ctxlen = 0,
  })

  if not raw or type(raw) ~= "table" then
    return {}
  end

  local hunks = {}
  for _, h in ipairs(raw) do
    local old_start, old_count, new_start, new_count = h[1], h[2], h[3], h[4]
    local kind
    if old_count == 0 then
      kind = "add"
    elseif new_count == 0 then
      kind = "delete"
    else
      kind = "change"
    end
    hunks[#hunks + 1] = {
      kind = kind,
      old_start = old_start,
      old_count = old_count,
      new_start = new_start,
      new_count = new_count,
      old_lines = old_count > 0 and slice(old_lines, old_start, old_count) or {},
      new_lines = new_count > 0 and slice(new_lines, new_start, new_count) or {},
    }
  end
  return hunks
end

function M.format_hunk_header(hunk)
  local function range(start, count)
    if count == 0 then
      return string.format("%d,0", start)
    elseif count == 1 then
      return tostring(start)
    else
      return string.format("%d,%d", start, count)
    end
  end
  return string.format(
    "@@ -%s +%s @@",
    range(hunk.old_start, hunk.old_count),
    range(hunk.new_start, hunk.new_count)
  )
end

return M
