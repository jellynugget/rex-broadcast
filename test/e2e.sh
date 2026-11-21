#!/usr/bin/env bash
# End-to-end test against the real Rex server, with the config installed.
#
#   bash test/e2e.sh
#
# Makes a throwaway session with three panes, presses keys there with
# `rex send-key` (which runs the Lua key bindings, as a real key press does),
# checks what each pane shows, then kills the session. The Rex app keeps
# showing whatever it showed before; the session only appears in its list
# while the test runs.
#
# Needs a running Rex server with broadcast.lua installed (./install.sh), and
# broadcasting turned off, since this test turns it on and off.

set -uo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/rex"
state_file="$config_dir/.broadcast-state.json"

rex=$(command -v rex || true)
app_rex="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
if [[ -z $rex && -x $app_rex ]]; then rex=$app_rex; fi
if [[ -z $rex ]]; then echo "skip: the rex command is not installed"; exit 0; fi
if ! "$rex" --autostart=false ls >/dev/null 2>&1; then echo "skip: no Rex server is running"; exit 0; fi
if ! grep -q 'require("broadcast")' "$config_dir/init.lua" 2>/dev/null; then
  echo "skip: broadcast.lua is not installed; run ./install.sh first"; exit 0
fi
if [[ -e $state_file ]]; then
  echo "Broadcasting is on in some tab. Turn it off, then run this again."; exit 1
fi

failed=0
check() {  # check NAME COMMAND...
  if "${@:2}"; then echo "  ok   $1"; else echo "  FAIL $1"; failed=1; fi
}

work=$(mktemp -d "${TMPDIR:-/tmp}/rex-broadcast-e2e.XXXXXX")
label="rex-broadcast-e2e-$$"
session=""

cleanup() {
  if [[ -n $session ]]; then
    if grep -qF "$session" "$state_file" 2>/dev/null; then
      "$rex" send-key -s "$session" cmd+shift+i >/dev/null 2>&1
    fi
    "$rex" kill "$session" >/dev/null 2>&1
  fi
  # Remove state left behind if the test stopped while broadcasting.
  if [[ -n $session ]] && grep -qF "$session" "$state_file" 2>/dev/null; then rm -f "$state_file"; fi
  rm -rf "$work"
}
trap cleanup EXIT

# The session's block IDs, one per line.
blocks() {
  "$rex" block ls 2>/dev/null | awk -v s="$label" '$1 == s { print $3 }'
}

# The labels of the session's blocks, one per line.
labels() {
  "$rex" block ls 2>/dev/null | awk -v s="$label" '$1 == s { $1=$2=$3=$4=""; sub(/^ +/, ""); sub(/ +placed.*$/, ""); print }'
}

# wait_for COMMAND...: retry for up to 5 seconds until COMMAND succeeds.
wait_for() {
  local i
  for i in $(seq 1 50); do "$@" && return 0; sleep 0.1; done
  return 1
}

# type TEXT: press the key for each letter or space, one at a time, as typing
# does. Only lowercase letters, digits and spaces are supported.
type_text() {
  local text=$1 i ch
  for (( i = 0; i < ${#text}; i++ )); do
    ch=${text:i:1}
    [[ $ch == " " ]] && ch=space
    "$rex" send-key -s "$session" "$ch" >/dev/null || return 1
  done
}

# How many of the session's panes show a line that is exactly TEXT.
panes_showing() {
  local count=0 b
  for b in $(blocks); do
    if "$rex" capture -b "$b" --trim 2>/dev/null | grep -qx "$1"; then count=$((count + 1)); fi
  done
  echo "$count"
}

all_labels_mark() { [[ $(labels | grep -c 'Broadcasting') -eq 3 ]]; }
no_label_marks() { [[ $(labels | grep -c 'Broadcasting') -eq 0 && $(labels | wc -l) -eq 3 ]]; }
showing() { [[ $(panes_showing "$1") -eq $2 ]]; }

echo "Rex's own Lua"
# Rex runs its own Lua 5.1, not LuaJIT; check the UTF-8 handling there too.
long_label_chars() {
  [[ $("$rex" do -e "local M = dofile('$root/broadcast.lua')
    local label = M.marked_label(string.rep('\\228\\184\\173', 200))
    local n = 0
    for _ in label:gmatch('[%z\\1-\\127\\194-\\244][\\128-\\191]*') do n = n + 1 end
    return n" 2>&1) == 128 ]]
}
check "a long multibyte name is shortened to 128 characters" long_label_chars

echo "setting up a throwaway session"
# zsh -f reads no startup files, so your shell plugins and settings don't
# change what the panes do with the keys.
out=$("$rex" new "$label" --json -c "$work" -- zsh -f) || { echo "could not create a session"; exit 1; }
session=$(printf '%s\n' "$out" | sed -n 's/.*"session_id": *"\([^"]*\)".*/\1/p' | head -1)
[[ -n $session ]] || { echo "could not read the session ID"; exit 1; }
"$rex" split -s "$session" --focus=false -- zsh -f >/dev/null || exit 1
"$rex" split -s "$session" --focus=false -- zsh -f >/dev/null || exit 1
check "the session has three panes" wait_for test "$(blocks | wc -l | tr -d ' ')" -eq 3

echo "starting"
"$rex" send-key -s "$session" cmd+shift+i >/dev/null
check "every pane's header shows Broadcasting" wait_for all_labels_mark
check "the state file is written" test -f "$state_file"

echo "typing"
type_text "echo broadcast 1" && "$rex" send-key -s "$session" enter >/dev/null
check "every pane runs the command" wait_for showing "broadcast 1" 3

echo "Escape while broadcasting"
"$rex" send-key -s "$session" escape >/dev/null
sleep 0.5
check "Escape doesn't stop broadcasting" all_labels_mark
# Escape reached the shells; in vi mode it leaves insert mode. Ctrl-C gives
# each pane a fresh prompt.
"$rex" send-key -s "$session" ctrl+c >/dev/null

echo "stopping with cmd+shift+i"
"$rex" send-key -s "$session" cmd+shift+i >/dev/null
check "the headers go back to normal" wait_for no_label_marks
check "the state file is removed" wait_for test ! -e "$state_file"

echo "typing after stopping"
type_text "echo focused 2" && "$rex" send-key -s "$session" enter >/dev/null
check "only the focused pane runs the command" wait_for showing "focused 2" 1

echo "starting again"
"$rex" send-key -s "$session" cmd+shift+i >/dev/null
check "cmd+shift+i starts" wait_for all_labels_mark
"$rex" send-key -s "$session" cmd+shift+i >/dev/null
check "cmd+shift+i again stops" wait_for no_label_marks

echo
if [[ $failed -eq 0 ]]; then echo "all checks passed"; else echo "some checks failed"; fi
exit $failed
