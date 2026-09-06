#!/usr/bin/env bash
# Build the fixture repos the spec runs against.
#
#   fixture.sh <dir>
#
# Creates <dir>/dirty  -- one file per case the float has to handle
#         <dir>/clean  -- committed and untouched, for the empty-list path
set -euo pipefail

root="${1:?usage: fixture.sh <dir>}"
rm -rf "$root"
mkdir -p "$root/dirty" "$root/clean"

init_repo() {
  git -C "$1" init -q .
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name "lazydiff tests"
  git -C "$1" config commit.gpgsign false
}

# --- dirty repo -------------------------------------------------------------
d="$root/dirty"
init_repo "$d"

# A tracked file that will get two separate hunks -- this is the one the spec
# uses to prove float and inline rendering agree.
cat >"$d/modified.lua" <<'EOF'
local M = {}

function M.first()
  return 1
end

function M.middle()
  return 2
end

function M.last()
  return 3
end

return M
EOF

printf 'local M = {}\nfunction M.gone() return 0 end\nreturn M\n' >"$d/gone.lua"
printf 'local M = {}\nfunction M.orig() return 0 end\nreturn M\n' >"$d/original.lua"
printf 'local M = {}\nfunction M.spaced() return 0 end\nreturn M\n' >"$d/has space.lua"
printf 'local M = {}\nfunction M.same() return 0 end\nreturn M\n' >"$d/unchanged.lua"
head -c 2048 /dev/urandom >"$d/blob.bin"

git -C "$d" add -A
git -C "$d" commit -qm "fixture baseline"

# A second commit, so HEAD~1 is a real, different ref for the ref-override
# tests: second.lua exists at HEAD but not at HEAD~1.
printf 'local M = {}\nfunction M.second() return 2 end\nreturn M\n' >"$d/second.lua"
git -C "$d" add -A
git -C "$d" commit -qm "fixture second"

# Now dirty it, one case per file.
# modified.lua: edit the top and the bottom so two hunks fall out.
cat >"$d/modified.lua" <<'EOF'
local M = {}

function M.first()
  return 100
end

function M.middle()
  return 2
end

function M.last()
  return 300
end

return M
EOF

rm "$d/gone.lua"                                    # D  deleted
git -C "$d" mv original.lua renamed.lua             # R  renamed
printf '\n-- appended\n' >>"$d/has space.lua"       # M  path containing a space
head -c 2048 /dev/urandom >"$d/blob.bin"            # M  binary
printf 'local M = {}\nfunction M.new() return 42 end\nreturn M\n' >"$d/brand-new.lua"  # ?  untracked
head -c 2048 /dev/urandom >"$d/new.bin"             # ?  untracked binary
# unchanged.lua is deliberately left alone -- it must NOT appear in the list.

# --- clean repo -------------------------------------------------------------
c="$root/clean"
init_repo "$c"
echo "nothing to see here" >"$c/a.txt"
git -C "$c" add -A
git -C "$c" commit -qm "clean"

echo "$root"
