#!/usr/bin/env bash
# Runs the checks that don't need Rex: the Lua tests against a fake rex, a
# syntax check of install.sh, and a lint of the scripts with shellcheck. Exits
# non-zero if any of them fails. CI runs this.
#
#   bash test/run.sh
#
# For the end-to-end test against a running Rex, run bash test/e2e.sh.

set -uo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root" || exit 1

failed=0

step() {  # step NAME COMMAND...
  echo "== $1"
  "${@:2}" || { echo "!! $1 failed"; failed=1; }
  echo
}

# Rex runs Lua 5.1, so use an interpreter that speaks it. Lua 5.2 and later
# treat some patterns differently.
lua=$(command -v luajit || command -v lua5.1 || true)
if [[ -z $lua ]]; then
  echo "!! no Lua 5.1 interpreter found (luajit or lua5.1)"
  failed=1
else
  step "broadcast_test.lua ($lua)" "$lua" test/broadcast_test.lua
fi

step "install.sh syntax" sh -n install.sh

if command -v shellcheck >/dev/null 2>&1; then
  # Warnings and errors only; info notes such as "function only called
  # indirectly" don't fail the build.
  step shellcheck shellcheck --severity=warning install.sh test/run.sh test/e2e.sh scripts/record-demo.sh
else
  echo "skip: shellcheck is not installed"
fi

exit $failed
