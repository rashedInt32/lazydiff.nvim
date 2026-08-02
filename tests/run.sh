#!/usr/bin/env bash
# Run the lazydiff test suite.
#
#   tests/run.sh              build fresh fixtures, run, clean up
#   KEEP=1 tests/run.sh       leave the fixtures behind for poking at
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/lazydiff-fixture.XXXXXX")"

cleanup() {
  if [ -n "${KEEP:-}" ]; then
    echo "fixtures kept at $fixture"
  else
    rm -rf "$fixture"
  fi
}
trap cleanup EXIT

bash "$here/fixture.sh" "$fixture" >/dev/null

LAZYDIFF_FIXTURE="$fixture" nvim --headless --clean \
  -u "$here/minimal_init.lua" \
  -l "$here/spec.lua"
